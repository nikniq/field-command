"""Crystals, units and buildings (pure simulation, no pygame). Logic mirrors the macOS edition's Entities.swift.

`team` is the owning player's slot (0-3). Visual side effects are reported to the world as events.

Orders are tuples:
    ("idle",) ("move", x, y) ("amove", x, y) ("attack", entity) ("gather", crystal) ("return",) ("build", kind, x, y)
    ("rebuild", bridge) ("repair", building)
"""
import math
import random

from .defs import (BRIDGE_COST, BRIDGE_HP, BRIDGE_REBUILD_TIME, BUILDINGS, REPAIR_COST_RATIO, REPAIR_TIME,
                   UNITS, angle_lerp, rect_distance, square_rect)

IDLE = ("idle",)


class Crystal:
    radius = 18

    def __init__(self, x, y, amount, variant, id=0):
        self.id = id
        self.x, self.y = x, y
        self.amount = self.max_amount = amount
        self.variant = variant % 3
        self.dead = False
        self.flip = random.random() < 0.5
        self.phase = random.uniform(0, 6)

    @property
    def scale(self):
        return 0.55 + 0.45 * self.amount / self.max_amount

    def extract(self, n):
        a = min(n, self.amount)
        self.amount -= a
        if self.amount <= 0:
            self.dead = True
        return a


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
        self.hp -= amount
        if self.hp <= 0:
            self.hp = 0
            self.dead = True
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
        self.scan = random.uniform(0, 0.3)
        self.blocked = None
        self.slide_sign = 0
        self.angle = random.uniform(0, 2 * math.pi)
        self.gun_angle = self.angle
        # Pathfinding state
        self.path = None
        self.path_goal = None
        self.path_version = -1
        self.repath = 0.0
        self.shortcut = 0.0

    @property
    def name(self):
        return self.stats.name

    @property
    def ghosting(self):
        return self.kind == "worker" and self.order[0] in ("gather", "return")

    @property
    def idle_worker(self):
        return self.kind == "worker" and self.order[0] == "idle" and not self.queued

    def status_text(self):
        o = self.order[0]
        if o == "idle":
            return "Idle"
        if o == "move":
            return "Moving"
        if o == "amove":
            return "Attack-moving"
        if o == "attack":
            return f"Engaging {self.order[1].name}"
        if o == "gather":
            return "Returning cargo" if self.carrying else "Mining crystal"
        if o == "return":
            return "Returning cargo"
        if o == "rebuild":
            return "Rebuilding a bridge"
        if o == "repair":
            return f"Repairing {self.order[1].name}"
        if o == "build":
            return f"Heading to build {BUILDINGS[self.order[1]].name}"
        return "Busy"

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
        self.scan -= dt
        moved = math.hypot(self.x - self.last_x, self.y - self.last_y)
        if self.was_moving and moved < self.stats.speed * dt * 0.3:
            self.stuck += dt
        else:
            self.stuck = max(0.0, self.stuck - dt * 2)
        self.last_x, self.last_y = self.x, self.y
        self.was_moving = False
        target = None
        o = self.order
        kind = o[0]

        if kind == "idle":
            if self.kind != "worker" and self.scan <= 0 and not self.queued:
                self.scan = 0.3
                t = g.find_target(self, self.stats.sight)
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
                t = g.find_target(self, self.stats.sight)
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

        elif kind == "attack":
            t = o[1]
            if t.dead or not t.targetable_by(self.team):
                self._finish_attack()
            else:
                switched = False
                if self.scan <= 0 and self.kind != "worker":
                    self.scan = 0.4
                    armed = isinstance(t, Unit) and t.kind != "worker"
                    if not armed:
                        better = g.find_target(self, self.stats.range + 20)
                        if isinstance(better, Unit) and better.kind != "worker":
                            self.order = ("attack", better)
                            switched = True
                if not switched:
                    if self.distance_to(t) > self.stats.range:
                        target = (t.x, t.y)
                    else:
                        self._aim(t.x, t.y, dt)
                        if self.cooldown <= 0:
                            self._fire(t)

        elif kind == "gather":
            c = o[1]
            if self.carrying >= 8:
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
                b.progress = min(1.0, b.progress + dt / BRIDGE_REBUILD_TIME)
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
            b = o[1]
            if b.dead or b.hp >= b.max_hp or not g.allied(b.team, self.team):
                self._after_work()
            elif self.stuck > 3:
                self._after_work()
                g.emit("msg", self.team, "An Engineer couldn't reach the building", "bad")
            elif b.surface_distance(self.x, self.y) - self.radius > 12:
                target = (b.x, b.y)
            else:
                heal = min(b.max_hp - b.hp, b.max_hp * dt / REPAIR_TIME)
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
        if target:
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
            return self.order[1].half + 30
        if k == "gather":
            return 40
        if k == "return":
            return 120
        return 0

    def _navigate(self, tx, ty, dt):
        """Walks straight at the goal when the way is clear, otherwise follows an A* path around obstacles."""
        g = self.game
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
        step = min(d, self.stats.speed * dt)
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
        self.cooldown = self.stats.cooldown
        d = max(1e-3, math.hypot(t.x - self.x, t.y - self.y))
        ux, uy = (t.x - self.x) / d, (t.y - self.y) / d
        ang = math.atan2(uy, ux)
        jx, jy = random.uniform(-6, 6), random.uniform(-6, 6)
        g.emit("recoil", self.id)
        if self.kind == "tank":
            mx, my = self.x + ux * 33, self.y + uy * 33
            g.launch_shell(mx, my, t.x + jx, t.y + jy, self.stats.damage, self.stats.splash, self.team, self)
            g.emit("muzzle", mx, my, ang, 26)
            g.emit("smoke", mx, my, 8)
            g.emit("sound", "cannon", self.x, self.y)
        elif self.kind == "sniper":
            mx, my = self.x + ux * 26 + uy * 3, self.y + uy * 26 - ux * 3
            t.take_damage(self.stats.damage, self)
            g.emit("tracer", mx, my, t.x, t.y, 2)
            g.emit("muzzle", mx, my, ang, 18)
            g.emit("sparks", t.x, t.y, 6, 90, "hit")
            g.emit("sound", "snipe", self.x, self.y)
        elif self.kind == "marine":
            mx, my = self.x + ux * 20 + uy * 4.5, self.y + uy * 20 - ux * 4.5
            t.take_damage(self.stats.damage, self)
            g.emit("tracer", mx, my, t.x + jx, t.y + jy, 0)
            g.emit("muzzle", mx, my, ang, 12)
            if random.random() < 0.5:
                g.emit("sparks", t.x + jx, t.y + jy, 4, 60, "hit")
            g.emit("sound", "rifle", self.x, self.y)
        else:
            t.take_damage(self.stats.damage, self)
            g.emit("sparks", self.x + ux * (self.radius + 5), self.y + uy * (self.radius + 5), 3, 35, "amber")

    def on_damaged(self, attacker):
        if attacker is None or attacker.dead or attacker.team == self.team or self.kind == "worker":
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
        self.gun_angle = random.uniform(0, 2 * math.pi)
        self.dish_angle = random.uniform(0, 2 * math.pi)
        if not built:
            self.hp = self.max_hp * 0.1

    @property
    def name(self):
        return self.stats.name

    def surface_distance(self, px, py):
        return rect_distance(self.rect, px, py)

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
            self.queue_progress += dt / UNITS[k].build_time
            if self.queue_progress >= 1:
                self.queue_progress = 0.0
                self.queue.pop(0)
                g.spawn_unit(k, self)

        if self.kind == "turret":
            self._update_turret(dt)
        elif self.kind == "radar":
            self.gun_angle = (self.gun_angle + dt * 0.8) % (2 * math.pi)

    def _update_turret(self, dt):
        g = self.game
        self.cooldown = max(0.0, self.cooldown - dt)
        self.scan -= dt
        t = self.turret_target
        if t and (t.dead or self.distance_to(t) > self.stats.range or not t.targetable_by(self.team)):
            self.turret_target = t = None
        if t is None and self.scan <= 0:
            self.scan = 0.3
            self.turret_target = t = g.find_target(self, self.stats.range)
        if t is None:
            return
        a = math.atan2(t.y - self.y, t.x - self.x)
        self.gun_angle = angle_lerp(self.gun_angle, a, dt * 10)
        if self.cooldown <= 0:
            self.cooldown = self.stats.cooldown
            t.take_damage(self.stats.damage, self)
            ux, uy = math.cos(a), math.sin(a)
            side = 4.5 if random.random() < 0.5 else -4.5
            mx, my = self.x + ux * 36 + uy * side, self.y + uy * 36 - ux * side
            g.emit("tracer", mx, my, t.x, t.y, 1)
            g.emit("muzzle", mx, my, a, 16)
            g.emit("sparks", t.x, t.y, 4, 60, "hit")
            g.emit("sound", "turret", self.x, self.y)
