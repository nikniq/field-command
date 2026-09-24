"""Crystals, units and buildings (pure simulation, no pygame). Logic mirrors the macOS edition's Entities.swift.

`team` is the owning player's slot (0-3). Visual side effects are reported to the world as events.

Orders are tuples:
    ("idle",) ("move", x, y) ("amove", x, y) ("attack", entity) ("gather", crystal) ("return",) ("build", kind, x, y)
    ("rebuild", bridge) ("repair", building or tank) ("heal", unit)
"""
import math
import random

from .defs import AIR_GUNS, CARRY_CAP, HIGH_RANGE, HIGH_SIGHT
from .defs import (ARMOR_FACTOR, DEPOT_UPGRADED_SUPPLY, TOWER_CAPTURE_TIME, TOWER_HALF, TOWER_RADIUS, TOWER_SIGHT,
                   TURRET_UPGRADED_DAMAGE, TURRET_UPGRADED_RANGE, UPGRADES, VET_BONUS, VET_THRESHOLDS,
                   upgrade_applies, upgrade_cost)
from .defs import (BRIDGE_COST, BRIDGE_HP, BRIDGE_REBUILD_TIME, BUILDINGS, MODE_MOBILE, MODE_SIEGED,
                   ARTILLERY_MIN_RANGE, ARTILLERY_SPLASH, CRATE_RADIUS, HEAL_RANGE, HEAL_RATE, HQ_GUN_COOLDOWN, HQ_GUN_DAMAGE,
                   HQ_GUN_RANGE, SHIELD_DELAY, SHIELD_MAX, SHIELD_REGEN,
                   MODE_SIEGING, MODE_UNSIEGING, REPAIR_COST_RATIO, REPAIR_TIME, SIEGE_COOLDOWN, SIEGE_DAMAGE,
                   SIEGE_MIN_RANGE, SIEGE_RANGE, SIEGE_SIGHT, SIEGE_SPLASH, SIEGE_TRANSITION, UNITS, angle_diff, angle_lerp,
                   rect_distance, square_rect)

IDLE = ("idle",)


class Crystal:
    radius = 18

    def __init__(self, x, y, amount, variant, id=0):
        self.id = id
        self.x, self.y = x, y
        self.amount = self.max_amount = amount
        self.variant = variant % 4          # 3 is gold
        self.dead = False
        self.flip = random.random() < 0.5
        self.phase = random.uniform(0, 6)

    @property
    def gold(self):
        return self.variant == 3

    @property
    def scale(self):
        return 0.55 + 0.45 * self.amount / self.max_amount

    def extract(self, n):
        a = min(n, self.amount)
        self.amount -= a
        if self.amount <= 0:
            self.dead = True
        return a


class Crate:
    """A supply drop on the field: `kind` is a CRATE_KINDS entry, `amount` the crystal it holds."""
    is_building = False
    radius = CRATE_RADIUS
    name = "Supply crate"
    team = None
    dead = False

    def __init__(self, id, x, y, kind, amount, born):
        self.id, self.x, self.y, self.kind, self.amount, self.born = id, x, y, kind, amount, born
        self.selected = self.hovered = False


class Entity:
    is_building = False
    body_radius = 0.0

    def __init__(self, game, team, max_hp, sight, x, y):
        self.game = game
        self.id = game.next_id()
        self.team = team
        self.hp = self.max_hp = max_hp
        self.sight = sight
        self.x, self.y = x, y
        self.dead = False
        self.vis_mask = 0       # alliances that currently see this entity (bitmask)
        self.revealed_mask = 0  # alliances that have ever seen this building
        # Client-side presentation state (used when the world is rendered in-process)
        self.selected = False
        self.hovered = False
        self.recoil = 0.0
        self.pulse = 0.0

    def surface_distance(self, px, py):
        return math.hypot(px - self.x, py - self.y)

    def distance_to(self, other):
        return other.surface_distance(self.x, self.y) - self.body_radius

    def targetable_by(self, slot):
        w = self.game
        if w.is_ai(slot) or w.allied(self.team, slot):
            return True
        bit = w.alliance_bit(slot)
        return bool(self.vis_mask & bit) or (self.is_building and bool(self.revealed_mask & bit))

    def take_damage(self, amount, attacker):
        if self.dead:
            return
        amount = self.game.modify_damage(self, amount, attacker)
        self.hp -= amount
        if self.hp <= 0:
            self.hp = 0
            self.dead = True
            if isinstance(attacker, Unit) and not attacker.dead and attacker.team != self.team:
                attacker.credit_kill()
        if attacker is not None:
            self.game.reveal(attacker, self.team)
        self.game.alert_attack(self.team, self.x, self.y)
        self.on_damaged(attacker)

    def on_damaged(self, attacker):
        pass


class Bridge(Entity):
    """A crossing the map ships with. Nobody owns it: any player can shell it down and any Engineer can
    rebuild it. While it stands it is pure decoration — the water simply is not there. Once it falls, its
    footprint blocks movement and line of fire exactly like the stream it spans, which is what makes
    holding or breaking a crossing worth doing."""

    is_building = False

    def __init__(self, game, rect):
        x0, y0, x1, y1 = rect
        super().__init__(game, None, BRIDGE_HP, 0, (x0 + x1) / 2, (y0 + y1) / 2)
        self.rect = (x0, y0, x1, y1)
        self.intact = True
        self.progress = 0.0        # rebuild progress, 0..1
        self.horizontal = (x1 - x0) >= (y1 - y0)

    @property
    def name(self):
        return "Bridge"

    def surface_distance(self, px, py):
        return rect_distance(self.rect, px, py)

    def targetable_by(self, slot):
        return self.intact        # ruins are rebuilt, not shot at again

    def take_damage(self, amount, attacker):
        """Neutral, so no owner is alerted — but everyone is told when a crossing goes down."""
        if not self.intact:
            return
        self.hp -= amount
        if self.hp <= 0:
            self.hp = 0.0
            self.intact = False
            self.progress = 0.0
            g = self.game
            g.emit("explode", self.x, self.y, 34, 1, 0)
            g.emit("smoke", self.x, self.y, 30)
            g.emit("sound", "explosion", self.x, self.y)
            g.emit("bridge", self.id, 0, self.x, self.y)
            g.bridges_changed()

    def restore(self):
        self.intact = True
        self.hp = self.max_hp
        self.progress = 0.0
        g = self.game
        g.emit("flash", self.x, self.y, 90, "build")
        g.emit("sound", "complete", self.x, self.y)
        g.emit("bridge", self.id, 1, self.x, self.y)
        g.bridges_changed()


class Watchtower:
    """A neutral control point. Troops of one alliance alone inside its radius for TOWER_CAPTURE_TIME take
    it; the owner then sees TOWER_SIGHT around it. It is never damaged, only taken."""
    is_building = False
    dead = False
    team = None
    name = "Watchtower"

    def __init__(self, game, x, y):
        self.game = game
        self.id = game.next_id()
        self.x, self.y = x, y
        self.half = TOWER_HALF
        self.rect = square_rect(x, y, TOWER_HALF)
        self.owner = None          # slot of the player who holds it
        self.capturing = None      # slot whose troops are taking it
        self.progress = 0.0
        self.selected = self.hovered = False

    def surface_distance(self, px, py):
        return rect_distance(self.rect, px, py)

    def targetable_by(self, slot):
        return False

    def update(self, dt):
        g = self.game
        present = {}
        for u in g.units:
            if u.dead or math.hypot(u.x - self.x, u.y - self.y) > TOWER_RADIUS:
                continue
            present.setdefault(g.players[u.team].team, u.team)
        owner_alliance = g.players[self.owner].team if self.owner is not None else None
        if len(present) == 1:
            alliance, slot = next(iter(present.items()))
            if alliance == owner_alliance:
                self.capturing, self.progress = None, 0.0
            else:
                if self.capturing is None or g.players[self.capturing].team != alliance:
                    self.capturing, self.progress = slot, 0.0
                self.progress += dt / TOWER_CAPTURE_TIME
                if self.progress >= 1.0:
                    self.owner, self.capturing, self.progress = slot, None, 0.0
                    g.emit("flash", self.x, self.y, 80, f"team{slot}")
                    g.emit("sound", "complete", self.x, self.y)
                    g.emit("tower", slot, self.id, self.x, self.y)
        else:
            # Nobody, or a contested ring: the clock winds back.
            self.progress = max(0.0, self.progress - dt / TOWER_CAPTURE_TIME)
            if self.progress == 0.0:
                self.capturing = None


class Unit(Entity):
    def __init__(self, game, kind, team, x, y):
        s = UNITS[kind]
        super().__init__(game, team, s.hp, s.sight, x, y)
        self.kind = kind
        self.stats = s
        self.radius = self.body_radius = s.radius
        self.order = IDLE
        self.queued = []
        self.resume_point = None
        self.cooldown = 0.0
        self.carrying = 0
        self.home_crystal = None
        self.resume_gather = None
        self.mine_timer = 0.0
        self.build_timer = 0.0
        self.stuck = 0.0
        self.last_x, self.last_y = x, y
        self.was_moving = False
        self.scan = game.rng.uniform(0, 0.3)
        self.blocked = None
        self.slide_sign = 0
        self.angle = game.rng.uniform(0, 2 * math.pi)
        self.gun_angle = self.angle
        # Siege mode (tanks only): MODE_* and the time left in a transition.
        self.mode = MODE_MOBILE
        self.mode_timer = 0.0
        # Veterancy: kills so far and the rank they have earned.
        self.kills = 0
        self.rank = 0
        # The kind's ability (defs.ABILITIES): seconds until it can be used again, and how long this unit
        # stays marked by a Sniper.
        self.ability_cd = 0.0
        self.marked_until = -1e9
        # Kit bought from the Armory is worn from the moment the unit exists.
        hp_bonus = s.hp * self._kit("hp")
        self.max_hp += hp_bonus
        self.hp = self.max_hp
        # Pathfinding state
        self.path = None
        self.path_goal = None
        self.path_version = -1
        self.repath = 0.0
        self.shortcut = 0.0

    @property
    def name(self):
        return self.stats.name

    # ------------------------------------------------------------ the Armory

    def _kit(self, key):
        return self.game.kit_bonus(self.team, self.kind, key)

    @property
    def speed(self):
        return self.stats.speed * (1 + self._kit("speed"))

    @property
    def carry_cap(self):
        return CARRY_CAP + int(self._kit("carry"))

    @property
    def work_mult(self):
        return 1 + self._kit("work")

    # ------------------------------------------------------------ veterancy

    @property
    def vet_mult(self):
        """Damage multiplier: veterancy and kit together."""
        return (1.0 + VET_BONUS * self.rank) * (1 + self._kit("damage"))

    def credit_kill(self):
        self.kills += 1
        rank = sum(1 for t in VET_THRESHOLDS if self.kills >= t)
        if rank > self.rank:
            added = self.stats.hp * VET_BONUS * (rank - self.rank)
            self.rank = rank
            self.max_hp += added
            self.hp = min(self.max_hp, self.hp + added)
            self.game.emit("flash", self.x, self.y, 40, f"team{self.team}")
            self.game.emit("rank", self.team, self.id, rank, self.x, self.y)

    # ------------------------------------------------------------ siege mode

    @property
    def sieged(self):
        return self.mode == MODE_SIEGED

    @property
    def can_siege(self):
        return self.kind == "tank"

    def set_siege(self, on):
        """Starts digging in or packing up; a no-op if already there or on the way."""
        if not self.can_siege:
            return
        if on and self.mode in (MODE_MOBILE, MODE_UNSIEGING):
            self.mode, self.mode_timer = MODE_SIEGING, SIEGE_TRANSITION
            self.path = self.path_goal = None
        elif not on and self.mode in (MODE_SIEGED, MODE_SIEGING):
            self.mode, self.mode_timer = MODE_UNSIEGING, SIEGE_TRANSITION

    @property
    def sight(self):
        base = SIEGE_SIGHT if self.sieged else self._sight
        return base * (HIGH_SIGHT if self.game.on_high(self.x, self.y) else 1.0)

    @sight.setter
    def sight(self, v):
        self._sight = v

    @property
    def attack_range(self):
        return ((SIEGE_RANGE if self.sieged else self.stats.range) + self._kit("range")
                + (HIGH_RANGE if self.game.on_high(self.x, self.y) else 0.0))

    @property
    def min_range(self):
        return SIEGE_MIN_RANGE if self.sieged else 0.0

    def in_range(self, t):
        d = self.distance_to(t)
        return self.min_range <= d <= self.attack_range

    @property
    def ghosting(self):
        return self.kind == "worker" and self.order[0] in ("gather", "return")

    @property
    def idle_worker(self):
        return self.kind == "worker" and self.order[0] == "idle" and not self.queued

    def status_text(self):
        o = self.order[0]
        if self.mode == MODE_SIEGING:
            return "Digging in"
        if self.mode == MODE_UNSIEGING:
            return "Packing up"
        if o == "idle":
            return ("Sieged" if self.sieged else "Idle") + self._rank_tag()
        if o == "move":
            return "Moving"
        if o == "amove":
            return "Attack-moving"
        if o == "attack":
            return ("Sieged — engaging " if self.sieged else "Engaging ") + self.order[1].name + self._rank_tag()
        if o == "gather":
            return "Returning cargo" if self.carrying else "Mining crystal"
        if o == "return":
            return "Returning cargo"
        if o == "rebuild":
            return "Rebuilding a bridge"
        if o == "repair":
            return f"Repairing {self.order[1].name}"
        if o == "heal":
            return f"Treating {self.order[1].name}"
        if o == "build":
            return f"Heading to build {BUILDINGS[self.order[1]].name}"
        return "Busy"

    def _rank_tag(self):
        return f"  ·  Rank {self.rank} ({self.kills} kills)" if self.rank else ""

    def surface_distance(self, px, py):
        return math.hypot(px - self.x, py - self.y) - self.radius

    # ------------------------------------------------------------ orders

    def command(self, o):
        self.refund_builds(True)
        self.queued = []
        self.order = o
        self.resume_point = None
        self.stuck = 0.0
        self.mine_timer = 0.0
        self.build_timer = 0.0

    def enqueue(self, o):
        if self.order[0] == "idle" and not self.queued:
            self.command(o)
        else:
            self.queued.append(o)

    def refund_builds(self, include_current):
        if include_current and self.order[0] == "build":
            self.game.refund(BUILDINGS[self.order[1]].cost, self.team)
        if include_current and self.order[0] == "rebuild":
            self.game.refund(BRIDGE_COST, self.team)
        for q in self.queued:
            if q[0] == "build":
                self.game.refund(BUILDINGS[q[1]].cost, self.team)
            elif q[0] == "rebuild":
                self.game.refund(BRIDGE_COST, self.team)

    def order_build(self, kind, x, y, queue=False):
        if queue and not (self.order[0] == "idle" and not self.queued):
            self.queued.append(("build", kind, x, y))
            return
        o = self.order[0]
        self.resume_gather = self.order[1] if o == "gather" else self.home_crystal if o == "return" else None
        self.command(("build", kind, x, y))

    def _after_work(self):
        rg = self.resume_gather
        self.resume_gather = None
        if self.queued:
            self.order = IDLE
        elif self.carrying:
            self.order = ("return",)
        elif rg and not rg.dead:
            self.order = ("gather", rg)
        else:
            self.order = IDLE

    def order_heal(self, unit, queue=False):
        if queue and not (self.order[0] == "idle" and not self.queued):
            self.queued.append(("heal", unit))
            return
        self.command(("heal", unit))

    def _finish_heal(self):
        self._finish_attack()       # back to the attack-move it was on, or idle

    def order_repair(self, building, queue=False):
        if queue and not (self.order[0] == "idle" and not self.queued):
            self.queued.append(("repair", building))
            return
        o = self.order[0]
        self.resume_gather = self.order[1] if o == "gather" else self.home_crystal if o == "return" else None
        self.command(("repair", building))

    def _finish_attack(self):
        if self.resume_point:
            self.order = ("amove", *self.resume_point)
            self.resume_point = None
        else:
            self.order = IDLE

    def _close_enough(self, px, py, slack):
        d = math.hypot(px - self.x, py - self.y)
        return d < slack or (self.stuck > 0.5 and d < self.radius * 4 + 30) or self.stuck > 3

    # ------------------------------------------------------------ update

    def update(self, dt):
        g = self.game
        self.cooldown = max(0.0, self.cooldown - dt)
        self.ability_cd = max(0.0, self.ability_cd - dt)
        self.scan -= dt
        moved = math.hypot(self.x - self.last_x, self.y - self.last_y)
        if self.was_moving and moved < self.speed * dt * 0.3:
            self.stuck += dt
        else:
            self.stuck = max(0.0, self.stuck - dt * 2)
        self.last_x, self.last_y = self.x, self.y
        self.was_moving = False
        if self.mode in (MODE_SIEGING, MODE_UNSIEGING):
            self.mode_timer -= dt
            if self.mode_timer <= 0:
                self.mode = MODE_SIEGED if self.mode == MODE_SIEGING else MODE_MOBILE
                self.mode_timer = 0.0
                if self.mode == MODE_SIEGED:
                    g.emit("sound", "siege", self.x, self.y)
            return          # switching: no orders, no shots
        target = None
        o = self.order
        kind = o[0]

        if kind == "idle":
            if self.kind == "medic":
                if self.scan <= 0 and not self.queued:
                    self.scan = 0.3
                    w = g.find_wounded(self, self.sight)
                    if w:
                        self.order = ("heal", w)
            elif self.kind != "worker" and self.scan <= 0 and not self.queued:
                self.scan = 0.3
                t = g.find_target(self, self.sight, min_range=self.min_range)
                if t:
                    self.order = ("attack", t)

        elif kind == "move":
            if self._close_enough(o[1], o[2], 5):
                self.order = IDLE
                self.stuck = 0
            else:
                target = (o[1], o[2])

        elif kind == "amove":
            engaged = False
            if self.scan <= 0:
                self.scan = 0.25
                if self.kind == "medic":
                    # A Medic on attack-move advances with the line and stops for anyone wounded on the way.
                    w = g.find_wounded(self, self.sight)
                    if w:
                        self.resume_point = (o[1], o[2])
                        self.order = ("heal", w)
                        engaged = True
                else:
                    t = g.find_target(self, self.sight, min_range=self.min_range)
                    if t:
                        self.resume_point = (o[1], o[2])
                        self.order = ("attack", t)
                        engaged = True
            if not engaged:
                if self._close_enough(o[1], o[2], 8):
                    self.order = IDLE
                    self.stuck = 0
                else:
                    target = (o[1], o[2])

        elif kind == "heal":
            w = o[1]
            if w.dead or w.hp >= w.max_hp or not g.allied(w.team, self.team):
                self._finish_heal()
            elif self.stuck > 3:
                self._finish_heal()
            elif self.distance_to(w) - w.radius - self.radius > HEAL_RANGE:
                target = (w.x, w.y)       # keeps up with a patient on the move
            else:
                self._aim(w.x, w.y, dt)
                w.hp = min(w.max_hp, w.hp + HEAL_RATE * (1 + self._kit("heal")) * dt)
                self.mine_timer += dt
                if self.mine_timer > 0.45:
                    self.mine_timer = 0.0
                    g.emit("pulse", self.id)
                    g.emit("sparks", w.x, w.y, 3, 30, "heal")
                if w.hp >= w.max_hp:
                    self._finish_heal()

        elif kind == "attack":
            t = o[1]
            if t.dead or not t.targetable_by(self.team) or self.kind == "medic":
                self._finish_attack()
            else:
                switched = False
                if self.scan <= 0 and self.kind != "worker":
                    self.scan = 0.4
                    armed = isinstance(t, Unit) and t.kind != "worker"
                    if not armed:
                        better = g.find_target(self, self.attack_range + 20, min_range=self.min_range)
                        if isinstance(better, Unit) and better.kind != "worker":
                            self.order = ("attack", better)
                            switched = True
                if not switched:
                    if self.in_range(t):
                        self._aim(t.x, t.y, dt)
                        if self.cooldown <= 0:
                            self._fire(t)
                    elif self.sieged:
                        # Dug in: hold and wait for it to come into the ring rather than chase it.
                        if self.distance_to(t) < self.min_range and self.scan <= 0:
                            self.scan = 0.4
                            other = g.find_target(self, self.attack_range, min_range=self.min_range)
                            if other is not None:
                                self.order = ("attack", other)
                    else:
                        target = (t.x, t.y)

        elif kind == "gather":
            c = o[1]
            if self.carrying >= self.carry_cap:
                self.order = ("return",)
            elif c.dead:
                n = g.nearest_crystal(c.x, c.y, 500)
                self.order = ("gather", n) if n else (("return",) if self.carrying else IDLE)
            else:
                self.home_crystal = c
                d = math.hypot(c.x - self.x, c.y - self.y) - c.radius - self.radius
                if d > 4:
                    target = (c.x, c.y)
                    self.mine_timer = 0
                else:
                    self._aim(c.x, c.y, dt)
                    before = self.mine_timer
                    self.mine_timer += dt
                    if int(before / 0.45) != int(self.mine_timer / 0.45):
                        k = (self.radius + 4) / max(1e-3, math.hypot(c.x - self.x, c.y - self.y))
                        g.emit("pulse", self.id)
                        g.emit("sparks", self.x + (c.x - self.x) * k, self.y + (c.y - self.y) * k, 3, 35, "crystal")
                    if self.mine_timer >= 1.6:
                        self.mine_timer = 0
                        self.carrying = c.extract(8)
                        self.order = ("return",)

        elif kind == "return":
            if self.carrying <= 0:
                hc = self.home_crystal
                self.order = ("gather", hc) if hc and not hc.dead else IDLE
            else:
                hq = g.nearest_dropoff(self.team, self.x, self.y)
                if hq is None:
                    self.order = IDLE
                elif self.distance_to(hq) > 6:
                    target = (hq.x, hq.y)
                else:
                    g.deposit(self.carrying, self.team, self.x, self.y)
                    self.carrying = 0
                    hc = self.home_crystal
                    if self.queued:
                        self.order = IDLE
                    elif hc and not hc.dead:
                        self.order = ("gather", hc)
                    else:
                        n = g.nearest_crystal(self.x, self.y, 700)
                        self.order = ("gather", n) if n else IDLE

        elif kind == "build":
            bk, sx, sy = o[1], o[2], o[3]
            r = square_rect(sx, sy, BUILDINGS[bk].half)
            self.build_timer += dt
            if self.stuck > 3 or self.build_timer > 45:
                # Site unreachable (boxed in by trees or buildings): give up and refund.
                g.refund(BUILDINGS[bk].cost, self.team)
                self.order = IDLE
                self.build_timer = 0.0
                g.emit("msg", self.team, "An Engineer couldn't reach the build site", "bad")
            elif rect_distance(r, self.x, self.y) - self.radius > 10:
                target = (sx, sy)
            elif g.can_place(bk, sx, sy, ignoring=self):
                g.start_building(bk, sx, sy, self.team)
                rg = self.resume_gather
                if self.queued:
                    self.order = IDLE
                elif self.carrying:
                    self.order = ("return",)
                elif rg and not rg.dead:
                    self.order = ("gather", rg)
                else:
                    self.order = IDLE
                self.resume_gather = None
            else:
                g.refund(BUILDINGS[bk].cost, self.team)
                self.order = IDLE
                g.emit("msg", self.team, "Build site blocked", "bad")

        elif kind == "rebuild":
            b = o[1]
            self.build_timer += dt
            if b.intact:
                # Someone else finished it first; the crystal goes back.
                g.refund(BRIDGE_COST, self.team)
                self.order = IDLE
                self.build_timer = 0.0
            elif self.stuck > 3 or self.build_timer > 60:
                g.refund(BRIDGE_COST, self.team)
                self.order = IDLE
                self.build_timer = 0.0
                g.emit("msg", self.team, "An Engineer couldn't reach the bridge", "bad")
            elif b.surface_distance(self.x, self.y) - self.radius > 12:
                target = (b.x, b.y)
            else:
                b.progress = min(1.0, b.progress + dt * self.work_mult / BRIDGE_REBUILD_TIME)
                self.mine_timer += dt
                if self.mine_timer > 0.45:      # reuse the mining bob so the work reads at a glance
                    self.mine_timer = 0.0
                    g.emit("pulse", self.id)
                    g.emit("sparks", self.x, self.y, 2, 30, "amber")
                if b.progress >= 1.0:
                    b.restore()
                    self.order = IDLE
                    self.build_timer = 0.0

        elif kind == "repair":
            b = o[1]                      # a building, or a Siege Tank
            if b.dead or b.hp >= b.max_hp or not g.allied(b.team, self.team):
                self._after_work()
            elif self.stuck > 3:
                self._after_work()
                g.emit("msg", self.team, "An Engineer couldn't reach the " + ("tank" if not b.is_building else "building"), "bad")
            elif b.surface_distance(self.x, self.y) - self.radius > 12:
                target = (b.x, b.y)
            else:
                heal = min(b.max_hp - b.hp, b.max_hp * dt * self.work_mult / REPAIR_TIME)
                price = heal / b.max_hp * b.stats.cost * REPAIR_COST_RATIO
                if g.resources[self.team] < price:
                    # Out of crystal: stop rather than repair on credit.
                    self._after_work()
                    g.emit("msg", self.team, "Not enough crystal to keep repairing", "bad")
                else:
                    g.resources[self.team] -= price
                    b.hp += heal
                    self.mine_timer += dt
                    if self.mine_timer > 0.45:      # the same work bob as mining and rebuilding
                        self.mine_timer = 0.0
                        g.emit("pulse", self.id)
                        g.emit("sparks", self.x, self.y, 2, 30, "amber")
                    if b.hp >= b.max_hp:
                        b.hp = b.max_hp
                        self._after_work()

        if self.order[0] == "idle" and self.queued:
            self.order = self.queued.pop(0)
            self.stuck = 0
            self.build_timer = 0.0
        if target and self.sieged:
            self.set_siege(False)       # an order to go somewhere packs the tank up first
        elif target:
            self._navigate(target[0], target[1], dt)
        else:
            self.path = None
            self.path_goal = None

    def _goal_clearance(self):
        """How much of the approach line to ignore: the target's own footprint is solid by design."""
        k = self.order[0]
        if k == "attack":
            t = self.order[1]
            return t.half + 30 if t.is_building else 30
        if k == "rebuild":
            return 40
        if k == "repair":
            return getattr(self.order[1], "half", 0) + 30
        if k == "heal":
            return 30
        if k == "gather":
            return 40
        if k == "return":
            return 120
        return 0

    @property
    def hits_air(self):
        return self.stats.hits_air

    def _navigate(self, tx, ty, dt):
        """Walks straight at the goal when the way is clear, otherwise follows an A* path around obstacles.
        Aircraft fly straight: nothing on the ground is in their way."""
        g = self.game
        if self.stats.flies:
            self.path = None
            self._move_toward(tx, ty, dt)
            return
        nav = g.nav
        self.repath -= dt
        goal_moved = self.path_goal is None or math.hypot(tx - self.path_goal[0], ty - self.path_goal[1]) > 60
        need = goal_moved or self.path_version != nav.version or (self.stuck > 0.7 and self.path is not None)
        if need and self.repath <= 0:
            if nav.line_clear(self.x, self.y, tx, ty, self._goal_clearance()):
                self.path = None
                self.repath = 0.3
            elif g.path_budget > 0:
                g.path_budget -= 1
                self.path = nav.find_path(self.x, self.y, tx, ty) or None
                self.repath = 1.0
                self.stuck = 0.0
            else:
                self.repath = 0.05  # out of pathfinding budget this tick; retry shortly
            if self.repath >= 0.3:
                self.path_goal = (tx, ty)
                self.path_version = nav.version
        sx, sy = tx, ty
        path = self.path
        if path:
            while len(path) > 1 and math.hypot(path[0][0] - self.x, path[0][1] - self.y) < 28:
                path.pop(0)
            self.shortcut -= dt
            if self.shortcut <= 0:
                self.shortcut = 0.3
                if len(path) > 1 and nav.line_clear(self.x, self.y, path[1][0], path[1][1]):
                    path.pop(0)
                elif not nav.line_clear(self.x, self.y, path[0][0], path[0][1]):
                    # Pushed off course (e.g. by other units): the next waypoint is hidden, so re-plan.
                    self.path_goal = None
                    self.repath = 0.0
            sx, sy = path[0]
            if len(path) == 1 and math.hypot(sx - tx, sy - ty) > 60:
                sx, sy = path[0]  # partial path toward an unreachable goal
            elif len(path) == 1:
                sx, sy = tx, ty
        self._move_toward(sx, sy, dt)

    def _move_toward(self, px, py, dt):
        dx, dy = px - self.x, py - self.y
        d = math.hypot(dx, dy)
        if d < 0.5:
            return
        ux, uy = dx / d, dy / d
        if self.blocked:
            nx, ny = self.blocked
            dot = ux * nx + uy * ny
            if dot < 0:
                if self.slide_sign == 0:
                    self.slide_sign = 1 if nx * uy - ny * ux >= 0 else -1
                tx, ty = ux - nx * dot, uy - ny * dot
                tl = math.hypot(tx, ty)
                if tl < 0.35:
                    ux, uy = -ny * self.slide_sign, nx * self.slide_sign
                else:
                    ux, uy = tx / tl, ty / tl
        else:
            self.slide_sign = 0
        step = min(d, self.speed * dt)
        self.x += ux * step
        self.y += uy * step
        self.angle = angle_lerp(self.angle, math.atan2(uy, ux), dt * 10)
        if self.kind == "tank" and self.order[0] != "attack":
            self.gun_angle = angle_lerp(self.gun_angle, self.angle, dt * 6)
        self.was_moving = True

    def _aim(self, px, py, dt):
        a = math.atan2(py - self.y, px - self.x)
        if self.kind == "tank":
            self.gun_angle = angle_lerp(self.gun_angle, a, dt * 8)
        else:
            self.angle = angle_lerp(self.angle, a, dt * 14)

    def _fire(self, t):
        g = self.game
        self.cooldown = (SIEGE_COOLDOWN if self.sieged else self.stats.cooldown) * (1 - self._kit("cooldown"))
        d = max(1e-3, math.hypot(t.x - self.x, t.y - self.y))
        ux, uy = (t.x - self.x) / d, (t.y - self.y) / d
        ang = math.atan2(uy, ux)
        jx, jy = g.rng.uniform(-6, 6), g.rng.uniform(-6, 6)
        g.emit("recoil", self.id)
        if self.kind == "tank":
            mx, my = self.x + ux * 33, self.y + uy * 33
            damage = (SIEGE_DAMAGE if self.sieged else self.stats.damage) * self.vet_mult
            splash = SIEGE_SPLASH if self.sieged else self.stats.splash
            g.launch_shell(mx, my, t.x + jx, t.y + jy, damage, splash, self.team, self)
            g.emit("muzzle", mx, my, ang, 32 if self.sieged else 26)
            g.emit("smoke", mx, my, 11 if self.sieged else 8)
            g.emit("sound", "cannon", self.x, self.y)
        elif self.kind == "sniper":
            mx, my = self.x + ux * 26 + uy * 3, self.y + uy * 26 - ux * 3
            t.take_damage(self.stats.damage * self.vet_mult, self)
            g.emit("tracer", mx, my, t.x, t.y, 2)
            g.emit("muzzle", mx, my, ang, 18)
            g.emit("sparks", t.x, t.y, 6, 90, "hit")
            g.emit("sound", "snipe", self.x, self.y)
        elif self.kind == "marine":
            mx, my = self.x + ux * 20 + uy * 4.5, self.y + uy * 20 - ux * 4.5
            t.take_damage(self.stats.damage * self.vet_mult, self)
            g.emit("tracer", mx, my, t.x + jx, t.y + jy, 0)
            g.emit("muzzle", mx, my, ang, 12)
            if g.rng.random() < 0.5:
                g.emit("sparks", t.x + jx, t.y + jy, 4, 60, "hit")
            g.emit("sound", "rifle", self.x, self.y)
        elif self.kind == "gunship":
            # The chain gun under the nose: a bright tracer and a spark on every hit.
            mx, my = self.x + ux * 16, self.y + uy * 16
            t.take_damage(self.stats.damage * self.vet_mult, self)
            g.emit("tracer", mx, my, t.x + jx, t.y + jy, 1)
            g.emit("muzzle", mx, my, ang, 10)
            g.emit("sparks", t.x + jx, t.y + jy, 3, 50, "hit")
            g.emit("sound", "turret", self.x, self.y)
        else:
            t.take_damage(self.stats.damage * self.vet_mult, self)
            g.emit("sparks", self.x + ux * (self.radius + 5), self.y + uy * (self.radius + 5), 3, 35, "amber")

    def on_damaged(self, attacker):
        if attacker is None or attacker.dead or attacker.team == self.team or self.kind in ("worker", "medic"):
            return
        if self.order[0] == "idle" and not self.queued:
            self.order = ("attack", attacker)


class Building(Entity):
    is_building = True

    def __init__(self, game, kind, team, x, y, built):
        s = BUILDINGS[kind]
        super().__init__(game, team, s.hp, s.sight, x, y)
        self.kind = kind
        self.stats = s
        self.half = s.half
        self.rect = square_rect(x, y, s.half)
        self.built = built
        self.progress = 1.0 if built else 0.0
        self.queue = []
        self.queue_progress = 0.0
        self.rally = None
        self.cooldown = 0.0
        self.scan = 0.0
        self.turret_target = None
        self.gun_angle = game.rng.uniform(0, 2 * math.pi)
        self.dish_angle = game.rng.uniform(0, 2 * math.pi)
        # Shield points from a generator in range (see World.step), and when they were last hit.
        self.shield = 0.0
        self.marked_until = -1e9
        self.shield_hit = -100.0
        self.shielded = False
        # Upgrades: the set installed, and the one being researched (kind, progress 0..1) if any.
        self.upgrades = set()
        self.upgrading = None
        self.upgrade_progress = 0.0
        if not built:
            self.hp = self.max_hp * 0.1

    @property
    def name(self):
        return self.stats.name

    def surface_distance(self, px, py):
        return rect_distance(self.rect, px, py)

    # ------------------------------------------------------------ upgrades

    def can_upgrade(self, kind):
        return (self.built and not self.dead and kind in UPGRADES and upgrade_applies(kind, self.kind)
                and kind not in self.upgrades and self.upgrading is None)

    def start_upgrade(self, kind):
        self.upgrading, self.upgrade_progress = kind, 0.0

    def cancel_upgrade(self):
        """Stops the research and hands the crystal back."""
        if self.upgrading is None:
            return
        self.game.refund(upgrade_cost(self.upgrading, self.kind), self.team)
        self.upgrading, self.upgrade_progress = None, 0.0

    def _install(self, kind):
        self.upgrades.add(kind)
        if kind == "hp":
            added = self.max_hp
            self.max_hp *= 2
            self.hp += added         # the new structure is sound
        self.game.emit("flash", self.x, self.y, self.half * 2.6, f"team{self.team}")
        self.game.emit("upgraded", self.team, self.kind, kind, self.id)

    @property
    def supply(self):
        return self.stats.supply + (DEPOT_UPGRADED_SUPPLY if "supply" in self.upgrades else 0)

    @property
    def train_speed(self):
        return 2.0 if "prod" in self.upgrades else 1.0

    @property
    def turret_range(self):
        if self.kind == "hq":
            return HQ_GUN_RANGE
        return ((TURRET_UPGRADED_RANGE if "guns" in self.upgrades else self.stats.range)
                + (HIGH_RANGE if self.game.on_high(self.x, self.y) else 0.0))

    @property
    def turret_damage(self):
        if self.kind == "hq":
            return HQ_GUN_DAMAGE
        return TURRET_UPGRADED_DAMAGE if "guns" in self.upgrades else self.stats.damage

    def take_damage(self, amount, attacker):
        amount = self.game.modify_damage(self, amount, attacker)
        if "armor" in self.upgrades:
            amount *= ARMOR_FACTOR
        if self.shield > 0 and amount > 0:
            soaked = min(self.shield, amount)
            self.shield -= soaked
            amount -= soaked
            self.shield_hit = self.game.elapsed
            self.game.emit("flash", self.x, self.y, self.half * 2.4, "shield")
        super().take_damage(amount, attacker)

    def update(self, dt):
        g = self.game
        if not self.built:
            self.progress += dt / self.stats.build_time
            self.hp = min(self.max_hp, self.hp + self.max_hp * 0.9 * dt / self.stats.build_time)
            if self.progress >= 1:
                self.built = True
                self.progress = 1.0
                g.emit("flash", self.x, self.y, self.half * 3, f"team{self.team}")
                g.building_completed(self)
            return

        if self.queue:
            k = self.queue[0]
            self.queue_progress += dt * self.train_speed / UNITS[k].build_time
            if self.queue_progress >= 1:
                self.queue_progress = 0.0
                self.queue.pop(0)
                g.spawn_unit(k, self)
        if self.upgrading is not None:
            self.upgrade_progress += dt / UPGRADES[self.upgrading].time
            if self.upgrade_progress >= 1:
                kind, self.upgrading, self.upgrade_progress = self.upgrading, None, 0.0
                self._install(kind)

        if self.shielded:
            if g.elapsed - self.shield_hit >= SHIELD_DELAY:
                self.shield = min(SHIELD_MAX, self.shield + SHIELD_REGEN * dt)
        elif self.shield > 0:
            self.shield = max(0.0, self.shield - 60 * dt)      # the generator is gone: the field collapses

        if self.armed:
            self._update_gun(dt)
        elif self.kind == "radar":
            self.gun_angle = (self.gun_angle + dt * 0.8) % (2 * math.pi)

    @property
    def armed(self):
        """Turrets and artillery always; a Command Center once it has its point-defence gun."""
        return self.kind in ("turret", "artillery") or (self.kind == "hq" and "defense" in self.upgrades)

    @property
    def min_range(self):
        return ARTILLERY_MIN_RANGE if self.kind == "artillery" else 0.0

    @property
    def hits_air(self):
        return self.kind in AIR_GUNS

    def _update_gun(self, dt):
        """Turrets and artillery: acquire, turn, fire. Artillery lobs shells and cannot hit inside its
        minimum range; its reach exceeds its sight, so what it can shoot is what its side can see."""
        g = self.game
        self.cooldown = max(0.0, self.cooldown - dt)
        self.scan -= dt
        t = self.turret_target
        if t and (t.dead or not (self.min_range <= self.distance_to(t) <= self.turret_range) or not t.targetable_by(self.team)):
            self.turret_target = t = None
        if t is None and self.scan <= 0:
            self.scan = 0.3
            self.turret_target = t = g.find_target(self, self.turret_range, min_range=self.min_range)
        if t is None:
            return
        a = math.atan2(t.y - self.y, t.x - self.x)
        self.gun_angle = angle_lerp(self.gun_angle, a, dt * (4 if self.kind == "artillery" else 10))
        if self.cooldown > 0:
            return
        self.cooldown = HQ_GUN_COOLDOWN if self.kind == "hq" else self.stats.cooldown
        ux, uy = math.cos(a), math.sin(a)
        if self.kind == "artillery":
            if abs(angle_diff(self.gun_angle, a)) > 0.35:
                self.cooldown = 0.2          # still traversing: wait for the barrel
                return
            mx, my = self.x + ux * 44, self.y + uy * 44
            jx, jy = g.rng.uniform(-14, 14), g.rng.uniform(-14, 14)
            g.launch_shell(mx, my, t.x + jx, t.y + jy, self.stats.damage, ARTILLERY_SPLASH, self.team, self, arc=True)
            g.emit("muzzle", mx, my, a, 34)
            g.emit("smoke", mx, my, 14)
            g.emit("sound", "cannon", self.x, self.y)
            return
        t.take_damage(self.turret_damage, self)
        side = 4.5 if g.rng.random() < 0.5 else -4.5
        mx, my = self.x + ux * 36 + uy * side, self.y + uy * 36 - ux * side
        g.emit("tracer", mx, my, t.x, t.y, 1)
        g.emit("muzzle", mx, my, a, 16)
        g.emit("sparks", t.x, t.y, 4, 60, "hit")
        g.emit("sound", "turret", self.x, self.y)
