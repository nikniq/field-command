"""The authoritative game simulation. Pure Python + numpy (no pygame), so it runs in the client for
single-player games and headless on a multiplayer server.

Players occupy slots 0-3; each has an alliance `team`. Entities record their owner slot in `.team`.
Player input arrives as JSON-friendly command lists via `apply(slot, cmd)`; everything that should be
seen or heard is appended to `events` for the presentation layer (or the network) to consume.
"""
import math
import random

from .ai import AI
from . import defs
from .defs import (ARTILLERY_SHELL_SPEED, CRATE_CRYSTAL, MISSION_BY_ID, START_CRYSTAL, CRATE_FIRST, CRATE_INTERVAL, CRATE_KINDS, CRATE_LIFE, CRATE_MAX,
                   CRATE_SQUAD, SHIELD_RADIUS, TANK_SHELL_SPEED)
from .defs import (BRIDGE_COST, BUILDINGS, KITS, KIT_BY_ID, REVEAL_RADIUS, REVEAL_TIME, TOWER_HALF, TOWER_SIGHT,
                   UNITS, clamp, rect_distance, rects_intersect, square_rect, upgrade_cost)
from .entities import IDLE, Bridge, Building, Crate, Crystal, Unit, Watchtower
from .fog import FogGrid
from .nav import NavGrid


class PlayerInfo:
    def __init__(self, slot, name, team, is_ai=False, start=None):
        self.slot = slot
        self.name = name
        self.team = team
        self.is_ai = is_ai
        self.start = slot if start is None else start
        self.ai = None
        self.alive = True
        self.connected = True


class World:
    def __init__(self, map_spec, players, difficulty, mission=None):
        self.map = map_spec
        self.difficulty = difficulty
        self.players = {p.slot: p for p in players}
        self._next_id = 1
        self.units, self.buildings, self.crystals = [], [], []
        self.by_id = {}
        self.events = []
        self.elapsed = 0.0
        self.game_over = False
        self.winner_team = None
        self.shells = []
        self.resources = {s: float(START_CRYSTAL) for s in self.players}
        self.units_trained = {s: 0 for s in self.players}
        self.units_lost = {s: 0 for s in self.players}
        self.crystals_mined = {s: 0 for s in self.players}
        self.trained_kinds = {s: {} for s in self.players}
        self._alert_time = {s: -100.0 for s in self.players}
        # A campaign mission (defs.Mission) or None; `mission_timer` is the hold time run up so far.
        self.mission = MISSION_BY_ID.get(mission) if isinstance(mission, str) else mission
        self.mission_timer = 0.0
        # Supply crates on the field, and when the next one drops.
        self.crates = []
        self.next_crate = CRATE_FIRST
        # Alert points: a player marks a spot and every ally is shown it; computer allies send troops.
        self.pings = []                  # [(slot, x, y, elapsed)], the last 30 seconds' worth
        self._ping_time = {s: -100.0 for s in self.players}
        self._fog_timer = 0.0
        defs.set_world_size(map_spec.get("w", defs.DEFAULT_WORLD[0]), map_spec.get("h", defs.DEFAULT_WORLD[1]))
        teams = sorted({p.team for p in players})
        self.alliance_index = {t: i for i, t in enumerate(teams)}
        self.fog = {t: FogGrid() for t in teams}
        self.reveals = {t: {} for t in teams}    # alliance -> {attacker id: revealed until (elapsed seconds)}
        self.kits = {p.slot: set() for p in players}    # slot -> kit ids bought from the Armory

        self.map_walls = [tuple(w[:4]) for w in map_spec.get("walls", [])]
        self.bridges = []
        self.walls = list(self.map_walls)
        self.nav = NavGrid()
        self._nav_dirty = True
        self.path_budget = 0
        self.obstacles = [tuple(t) for t in map_spec["trees"]]
        self._obstacle_grid = {}
        for i, (x, y, *_r) in enumerate(self.obstacles):
            self._obstacle_grid.setdefault((int(x // 128), int(y // 128)), []).append(i)
        for rect in map_spec.get("bridges", []):
            b = Bridge(self, tuple(rect))
            self.bridges.append(b)
            self.by_id[b.id] = b
        self.towers = []          # filled once crystals and trees exist; then bridges_changed() adds them to walls
        for (x, y, amount, variant) in map_spec["crystals"]:
            c = Crystal(x, y, amount, variant, self.next_id())
            self.crystals.append(c)
            self.by_id[c.id] = c
        for x, y in self._tower_sites():
            t = Watchtower(self, x, y)
            self.towers.append(t)
            self.by_id[t.id] = t
        self.bridges_changed()
        for p in players:
            sx, sy, base = map_spec["starts"][p.start]
            self._add(Building(self, "hq", p.slot, sx, sy, True))
            line = self.crystals[p.start * 8:p.start * 8 + 8]
            for i in range(5):
                a = base + math.pi / 4 + (i - 2) * 0.28
                u = Unit(self, "worker", p.slot, sx + math.cos(a) * 130, sy + math.sin(a) * 130)
                u.order = ("gather", line[(i * 2 + 1) % len(line)])
                self._add(u)
            if p.is_ai:
                p.ai = AI(self, p.slot)
        self.update_visibility()

    # ------------------------------------------------------------ identity & alliances

    def next_id(self):
        i = self._next_id
        self._next_id += 1
        return i

    def _add(self, e):
        (self.buildings if e.is_building else self.units).append(e)
        self.by_id[e.id] = e
        if e.is_building:
            self._nav_dirty = True

    # ------------------------------------------------------------ the Armory

    def kit_bonus(self, slot, unit_kind, key):
        """The summed effect `key` of every kit `slot` has bought for `unit_kind`."""
        owned = self.kits.get(slot)
        if not owned:
            return 0.0
        return sum(k.bonus(key) for k in KITS if k.unit == unit_kind and k.id in owned)

    def buy_kit(self, slot, kit_id):
        kit = KIT_BY_ID.get(kit_id)
        if kit is None or slot not in self.kits or kit_id in self.kits[slot]:
            return False
        if self.resources[slot] < kit.cost:
            self.emit("msg", slot, "Not enough crystal", "bad")
            return False
        self.resources[slot] -= kit.cost
        self.kits[slot].add(kit_id)
        # Kit is worn at once: units already in the field get the extra health, not just a taller bar.
        hp = kit.bonus("hp")
        if hp:
            for u in self.units:
                if not u.dead and u.team == slot and u.kind == kit.unit:
                    added = u.stats.hp * hp
                    u.max_hp += added
                    u.hp += added
        self.emit("kit", slot, kit_id)
        return True

    def reveal(self, attacker, victim_slot):
        """Whoever just hit `victim_slot` shows itself to that player's alliance for a moment."""
        team = getattr(attacker, "team", None)
        if team is None or victim_slot not in self.players or self.allied(team, victim_slot):
            return
        self.reveals[self.players[victim_slot].team][attacker.id] = self.elapsed + REVEAL_TIME

    def _tower_sites(self):
        """Centre and the two flanks, each nudged to the nearest open ground. The Mac edition runs the same
        search over the same map data, so both place the towers identically."""
        w, h = defs.WORLD_W, defs.WORLD_H
        sites = []
        for cx, cy in ((w / 2, h / 2), (w / 4, h / 2), (3 * w / 4, h / 2)):
            spot = self._open_ground_near(cx, cy)
            if spot is not None:
                sites.append(spot)
        return sites

    def _open_ground_near(self, cx, cy):
        """Spirals outwards in 40-unit steps for a square of TOWER_HALF clear of water, cliffs, crystals,
        trees, buildings and other towers."""
        for ring in range(0, 12):
            step = 40 * ring
            candidates = [(cx, cy)] if ring == 0 else [
                (cx + dx * step, cy + dy * step) for dx in (-1, 0, 1) for dy in (-1, 0, 1) if dx or dy]
            for x, y in candidates:
                x, y = self.snapped(x, y)
                r = square_rect(x, y, TOWER_HALF + 20)
                if r[0] < 60 or r[1] < 60 or r[2] > defs.WORLD_W - 60 or r[3] > defs.WORLD_H - 60:
                    continue
                if any(rects_intersect(wl, r) for wl in self.map_walls):
                    continue
                if any(rect_distance(r, c.x, c.y) < c.radius + 30 for c in self.crystals):
                    continue
                if any(rect_distance(r, o[0], o[1]) < o[2] + 10 for o in self.nearby_obstacles(x, y)):
                    continue
                if any(rects_intersect(b.rect, r) for b in self.buildings):
                    continue
                if any(math.hypot(t.x - x, t.y - y) < 300 for t in self.towers):
                    continue
                return x, y
        return None

    def bridges_changed(self):
        """A fallen bridge blocks its span exactly like the water it crossed; a rebuilt one opens it again.
        Everything that consults `walls` — navigation, collision and building placement — follows from this."""
        self.walls = self.map_walls + [b.rect for b in self.bridges if not b.intact] + [t.rect for t in self.towers]
        self._nav_dirty = True

    def bridge_at(self, x, y, slack=0.0):
        for b in self.bridges:
            if rect_distance(b.rect, x, y) <= slack:
                return b
        return None

    def _rebuild_nav(self):
        rects = list(self.walls) + [b.rect for b in self.buildings if not b.dead]
        circles = [(o[0], o[1], o[2]) for o in self.obstacles] + [(c.x, c.y, c.radius) for c in self.crystals if not c.dead]
        self.nav.rebuild(rects, circles)
        self._nav_dirty = False

    def is_ai(self, slot):
        p = self.players.get(slot)
        return bool(p and p.is_ai)

    def allied(self, a, b):
        return self.players[a].team == self.players[b].team

    def enemies(self, a, b):
        return not self.allied(a, b)

    def alliance_bit(self, slot):
        return 1 << self.alliance_index[self.players[slot].team]

    def fog_for(self, slot):
        return self.fog[self.players[slot].team]

    def sees(self, slot, e):
        """True if `slot` can currently see entity `e` (own/allied entities always)."""
        if self.allied(e.team, slot):
            return True
        bit = self.alliance_bit(slot)
        return bool(e.vis_mask & bit) or (e.is_building and bool(e.revealed_mask & bit))

    def emit(self, *event):
        self.events.append(event)

    # ------------------------------------------------------------ simulation

    def step(self, dt):
        if self.game_over:
            return
        self.elapsed += dt
        if self._nav_dirty:
            self._rebuild_nav()
        self.path_budget = 6
        for u in self.units:
            if not u.dead:
                u.update(dt)
        self._resolve_collisions()
        self._update_shields()
        for b in self.buildings:
            if not b.dead:
                b.update(dt)
        self._update_shells(dt)
        self._update_crates()
        for t in self.towers:
            t.update(dt)
        self._check_mission(dt)
        for p in self.players.values():
            if p.ai and p.alive:
                p.ai.update(dt)
        self._cleanup_dead()
        self._fog_timer -= dt
        if self._fog_timer <= 0:
            self._fog_timer = 0.1
            self.update_visibility()
        self._check_victory()

    def update_visibility(self):
        for team, grid in self.fog.items():
            viewers = [(e.x, e.y, e.sight) for e in self.units + self.buildings if self.players[e.team].team == team]
            viewers += [(t.x, t.y, TOWER_SIGHT) for t in self.towers
                        if t.owner is not None and self.players[t.owner].team == team]
            active = self.reveals[team]
            for eid in [i for i, until in active.items() if until <= self.elapsed]:
                del active[eid]
            for eid in list(active):
                e = self.by_id.get(eid)
                if e is None or e.dead:
                    del active[eid]
                else:
                    viewers.append((e.x, e.y, REVEAL_RADIUS))
            grid.recompute(viewers)
        for e in self.units + self.buildings:
            mask = 0
            owner_team = self.players[e.team].team
            for team, grid in self.fog.items():
                bit = 1 << self.alliance_index[team]
                if team == owner_team:
                    mask |= bit
                elif (grid.any_visible(e.rect) if e.is_building else grid.is_visible(e.x, e.y)):
                    mask |= bit
            e.vis_mask = mask
            if e.is_building:
                e.revealed_mask |= mask

    def _resolve_collisions(self):
        units = self.units
        grid = {}
        for u in units:
            u.blocked = None
            grid.setdefault((int(u.x // 48), int(u.y // 48)), []).append(u)
        for (gx, gy), cell in grid.items():
            neighbours = []
            for ox, oy in ((0, 1), (1, -1), (1, 0), (1, 1)):
                n = grid.get((gx + ox, gy + oy))
                if n:
                    neighbours.extend(n)
            for i, a in enumerate(cell):
                for b in cell[i + 1:] + neighbours:
                    dx, dy = b.x - a.x, b.y - a.y
                    min_d = a.radius + b.radius
                    if abs(dx) > min_d or abs(dy) > min_d:
                        continue
                    d2 = dx * dx + dy * dy
                    if d2 >= min_d * min_d or (a.ghosting and b.ghosting):
                        continue
                    d = math.sqrt(d2)
                    nx, ny = (dx / d, dy / d) if d > 0.01 else (1.0, 0.0)
                    overlap = min_d - d
                    wa = 0.5
                    if a.was_moving and not b.was_moving:
                        wa = 0.2
                    elif b.was_moving and not a.was_moving:
                        wa = 0.8
                    a.x -= nx * overlap * wa
                    a.y -= ny * overlap * wa
                    b.x += nx * overlap * (1 - wa)
                    b.y += ny * overlap * (1 - wa)
        rects = [b.rect for b in self.buildings] + self.walls
        for u in units:
            r = u.radius
            for rect in rects:
                x0, y0, x1, y1 = rect
                if u.x < x0 - r or u.x > x1 + r or u.y < y0 - r or u.y > y1 + r:
                    continue
                cx, cy = clamp(u.x, x0, x1), clamp(u.y, y0, y1)
                dx, dy = u.x - cx, u.y - cy
                d2 = dx * dx + dy * dy
                if d2 >= r * r:
                    continue
                if d2 > 1e-4:
                    d = math.sqrt(d2)
                    nx, ny = dx / d, dy / d
                    u.x += nx * (r - d)
                    u.y += ny * (r - d)
                    u.blocked = (nx, ny)
                else:
                    m = min(u.x - x0, x1 - u.x, u.y - y0, y1 - u.y)
                    if m == u.x - x0:
                        u.x, u.blocked = x0 - r, (-1.0, 0.0)
                    elif m == x1 - u.x:
                        u.x, u.blocked = x1 + r, (1.0, 0.0)
                    elif m == u.y - y0:
                        u.y, u.blocked = y0 - r, (0.0, -1.0)
                    else:
                        u.y, u.blocked = y1 + r, (0.0, 1.0)
            circles = [(c.x, c.y, c.radius) for c in self.crystals if abs(c.x - u.x) < 60 and abs(c.y - u.y) < 60]
            circles += [(o[0], o[1], o[2]) for o in self.nearby_obstacles(u.x, u.y)]
            for cx, cy, cr in circles:
                min_d = r + cr
                dx, dy = u.x - cx, u.y - cy
                if abs(dx) > min_d or abs(dy) > min_d:
                    continue
                d = math.hypot(dx, dy)
                if d >= min_d:
                    continue
                nx, ny = (dx / d, dy / d) if d > 0.01 else (0.0, -1.0)
                u.x += nx * (min_d - d)
                u.y += ny * (min_d - d)
                if u.blocked is None:
                    u.blocked = (nx, ny)
            u.x = clamp(u.x, r + 4, defs.WORLD_W - r - 4)
            u.y = clamp(u.y, r + 4, defs.WORLD_H - r - 4)

    def nearby_obstacles(self, x, y):
        bx, by = int(x // 128), int(y // 128)
        out = []
        for gx in (bx - 1, bx, bx + 1):
            for gy in (by - 1, by, by + 1):
                for i in self._obstacle_grid.get((gx, gy), ()):
                    out.append(self.obstacles[i])
        return out

    def _cleanup_dead(self):
        if any(u.dead for u in self.units):
            for u in self.units:
                if not u.dead:
                    continue
                self.emit("explode", u.x, u.y, 30 if u.kind == "tank" else u.radius * 1.3, 1 if u.kind == "tank" else 0, 0)
                if u.kind == "tank":
                    self.emit("wreck", u.x, u.y, math.degrees(u.angle), u.team)
                    self.emit("sound", "explosion", u.x, u.y)
                u.refund_builds(True)
                self.units_lost[u.team] += 1
                self.by_id.pop(u.id, None)
            self.units = [u for u in self.units if not u.dead]
        if any(b.dead for b in self.buildings):
            for b in self.buildings:
                if not b.dead:
                    continue
                self.emit("explode", b.x, b.y, b.half * 0.9, 1, 0)
                for i in range(5):
                    self.emit("explode", b.x + random.uniform(-b.half, b.half), b.y + random.uniform(-b.half, b.half),
                              b.half * 0.5, 0, i * 0.12 + 0.05)
                self.emit("rubble", b.x, b.y, b.half * 2.4)
                self.emit("sound", "explosion", b.x, b.y)
                self.emit("shake", b.x, b.y, min(10, b.half * 0.15))
                self.emit("bdead", b.team, b.kind, b.x, b.y)
                self.by_id.pop(b.id, None)
            self.buildings = [b for b in self.buildings if not b.dead]
            self._nav_dirty = True
        if any(c.dead for c in self.crystals):
            for c in self.crystals:
                if c.dead:
                    self.by_id.pop(c.id, None)
            self.crystals = [c for c in self.crystals if not c.dead]
            self._nav_dirty = True

    def mission_progress(self):
        """Seconds toward a timed objective (survive: the clock; hold: time held in a row), else 0."""
        m = self.mission
        if m is None or m.win == "destroy":
            return 0.0
        return self.elapsed if m.win == "survive" else self.mission_timer

    def _check_mission(self, dt):
        """A timed mission ends in victory for the player's side when its clock or its hold is done."""
        m = self.mission
        if m is None or self.game_over or m.win == "destroy":
            return
        me = self.players[0]
        if not me.alive:
            return
        if m.win == "hold":
            hx, hy, hr = m.hold
            mine = any(not e.dead and self.allied(e.team, 0) and math.hypot(e.x - hx, e.y - hy) <= hr
                       for e in self.units + self.buildings)
            enemy = any(not u.dead and self.enemies(u.team, 0) and math.hypot(u.x - hx, u.y - hy) <= hr for u in self.units)
            self.mission_timer = self.mission_timer + dt if (mine and not enemy) else 0.0
        if self.mission_progress() >= m.seconds:
            self.game_over = True
            self.winner_team = me.team
            self.emit("gameover", me.team)

    def _check_victory(self):
        for p in self.players.values():
            if p.alive and not any(b.team == p.slot for b in self.buildings):
                p.alive = False
                for u in self.units:
                    if u.team == p.slot:
                        u.dead = True
                self.emit("elim", p.slot, p.name)
        teams = {p.team for p in self.players.values() if p.alive}
        if len(teams) <= 1 and not self.game_over:
            self.game_over = True
            self.winner_team = next(iter(teams), None)
            self.emit("gameover", -1 if self.winner_team is None else self.winner_team)

    # ------------------------------------------------------------ commands

    def apply(self, slot, cmd):
        """Applies a player command. Commands are lists so they can travel as JSON:
            ["move", ids, x, y, queue, attack]      ["attack", ids, target_id, queue]
            ["gather", ids, crystal_id, queue]      ["return", ids, queue]      ["stop", ids]
            ["build", worker_id, kind, x, y, queue] ["train", building_ids, kind]
            ["rebuild", worker_id, bridge_id, queue]  ["repair", unit_ids, target_id, queue]
            (repair: Engineers mend a building or a Siege Tank, Medics treat anyone on foot)
            ["siege", ids, on]                      ["upgrade", building_ids, kind]  ["cancelup", building_id]
            ["buy", kit_id]
            ["cancel", building_id, index]          ["rally", building_ids, x, y]
        Invalid or foreign references are ignored."""
        if self.game_over or slot not in self.players or not self.players[slot].alive or not cmd:
            return
        try:
            op = cmd[0]
            if op == "move":
                us = self._own_units(slot, cmd[1])
                if us:
                    self.move_group(us, float(cmd[2]), float(cmd[3]), bool(cmd[5]), bool(cmd[4]))
            elif op == "attack":
                t = self.by_id.get(cmd[2])
                neutral = isinstance(t, Bridge) and t.intact      # anyone may bring a crossing down
                if t is not None and not isinstance(t, Crystal) and not t.dead \
                        and (neutral or self.enemies(t.team, slot)):
                    for u in self._own_units(slot, cmd[1]):
                        if u.kind == "medic":
                            self._give(u, ("amove", t.x, t.y), bool(cmd[3]))     # unarmed: it goes along to treat
                        elif u.kind != "worker" or not neutral:
                            self._give(u, ("attack", t), bool(cmd[3]))
            elif op == "gather":
                c = self.by_id.get(cmd[2])
                if isinstance(c, Crystal) and not c.dead:
                    us = self._own_units(slot, cmd[1])
                    for w in us:
                        if w.kind == "worker":
                            w.home_crystal = c
                            self._give(w, ("gather", c), bool(cmd[3]))
                    others = [u for u in us if u.kind != "worker"]
                    if others:
                        self.move_group(others, c.x, c.y, False, bool(cmd[3]))
            elif op == "return":
                for u in self._own_units(slot, cmd[1]):
                    if u.kind == "worker" and u.carrying:
                        self._give(u, ("return",), bool(cmd[2]))
            elif op == "stop":
                for u in self._own_units(slot, cmd[1]):
                    u.command(IDLE)
            elif op == "build":
                self._build(slot, cmd[1], cmd[2], float(cmd[3]), float(cmd[4]), bool(cmd[5]))
            elif op == "upgrade":
                self._upgrade(slot, self._own_buildings(slot, cmd[1]), cmd[2])
            elif op == "cancelup":
                for b in self._own_buildings(slot, [cmd[1]]):
                    b.cancel_upgrade()
            elif op == "buy":
                self.buy_kit(slot, cmd[1])
            elif op == "siege":
                for u in self._own_units(slot, cmd[1]):
                    u.set_siege(bool(cmd[2]))
            elif op == "ping":
                self.place_ping(slot, float(cmd[1]), float(cmd[2]), int(cmd[3]) if len(cmd) > 3 else 0)
            elif op == "repair":
                b = self.by_id.get(cmd[2])
                queue = bool(cmd[3]) if len(cmd) > 3 else False
                if b is not None and not b.dead and self.allied(b.team, slot):
                    mendable = (isinstance(b, Building) and b.built) or (isinstance(b, Unit) and b.kind == "tank")
                    treatable = isinstance(b, Unit) and b.kind != "tank"
                    for u in self._own_units(slot, cmd[1]):
                        if u.kind == "worker" and mendable:
                            u.order_repair(b, queue)
                        elif u.kind == "medic" and treatable and u is not b:
                            u.order_heal(b, queue)
            elif op == "rebuild":
                self._rebuild_bridge(slot, cmd[1], cmd[2], bool(cmd[3]) if len(cmd) > 3 else False)
            elif op == "train":
                if cmd[2] in UNITS:
                    self.train(cmd[2], self._own_buildings(slot, cmd[1]), slot)
            elif op == "cancel":
                bs = self._own_buildings(slot, [cmd[1]])
                if bs:
                    self.cancel_queue(bs[0], int(cmd[2]))
            elif op == "rally":
                for b in self._own_buildings(slot, cmd[1]):
                    if b.stats.produces:
                        b.rally = (float(cmd[2]), float(cmd[3]))
        except (IndexError, TypeError, ValueError, KeyError):
            pass

    def _own_units(self, slot, ids):
        out = []
        for i in ids or ():
            e = self.by_id.get(i)
            if isinstance(e, Unit) and e.team == slot and not e.dead:
                out.append(e)
        return out

    def _own_buildings(self, slot, ids):
        out = []
        for i in ids or ():
            e = self.by_id.get(i)
            if isinstance(e, Building) and e.team == slot and not e.dead:
                out.append(e)
        return out

    @staticmethod
    def _give(u, o, queue):
        if queue:
            u.enqueue(o)
        else:
            u.command(o)

    def move_group(self, us, x, y, attack, queue=False):
        kind = "amove" if attack else "move"
        if len(us) == 1:
            self._give(us[0], (kind, x, y), queue)
            return
        cols = int(math.ceil(math.sqrt(len(us))))
        rows = (len(us) + cols - 1) // cols
        spacing = max(u.radius for u in us) * 2 + 8
        by_y = sorted(us, key=lambda u: -u.y)
        ordered = []
        for i in range(0, len(by_y), cols):
            ordered += sorted(by_y[i:i + cols], key=lambda u: u.x)
        for idx, u in enumerate(ordered):
            r, c = divmod(idx, cols)
            tx = clamp(x + (c - (cols - 1) / 2) * spacing, 20, defs.WORLD_W - 20)
            ty = clamp(y + ((rows - 1) / 2 - r) * spacing, 20, defs.WORLD_H - 20)
            self._give(u, (kind, tx, ty), queue)

    def _build(self, slot, worker_id, kind, x, y, queue):
        s = BUILDINGS.get(kind)
        workers = self._own_units(slot, [worker_id])
        if s is None or not workers or workers[0].kind != "worker":
            return
        x, y = self.snapped(x, y)
        if s.requires and not self.has_built(s.requires, slot):
            self.emit("msg", slot, f"Requires {BUILDINGS[s.requires].name}", "bad")
        elif not self.fog_for(slot).is_explored(x, y):
            self.emit("msg", slot, "Can't build in unexplored territory", "bad")
        elif not self.can_place(kind, x, y):
            self.emit("msg", slot, "Can't build there", "bad")
        elif self.resources[slot] < s.cost:
            self.emit("msg", slot, "Not enough crystal", "bad")
        else:
            self.resources[slot] -= s.cost
            workers[0].order_build(kind, x, y, queue=queue)

    def _upgrade(self, slot, bs, kind):
        """Starts `kind` on every selected building that can take it, one price each, stopping when the
        crystal runs out."""
        for b in bs:
            if not b.can_upgrade(kind):
                continue
            cost = upgrade_cost(kind, b.kind)
            if self.resources[slot] < cost:
                self.emit("msg", slot, "Not enough crystal", "bad")
                return
            self.resources[slot] -= cost
            b.start_upgrade(kind)

    def _rebuild_bridge(self, slot, worker_id, bridge_id, queue):
        b = self.by_id.get(bridge_id)
        workers = self._own_units(slot, [worker_id])
        if not isinstance(b, Bridge) or not workers or workers[0].kind != "worker":
            return
        if b.intact:
            return
        if self.resources[slot] < BRIDGE_COST:
            self.emit("msg", slot, "Not enough crystal", "bad")
            return
        self.resources[slot] -= BRIDGE_COST
        self._give(workers[0], ("rebuild", b), queue)

    # ------------------------------------------------------------ construction & production

    def has_built(self, kind, team):
        return any(b.team == team and b.kind == kind and b.built for b in self.buildings)

    @staticmethod
    def snapped(x, y):
        # floor(v + 0.5) rounds halves up, as Swift's .rounded() does; Python's round() would send 62.5 to 62
        # and put a watchtower 16 units from where the Mac edition puts it.
        return (math.floor(x / 16 + 0.5) * 16, math.floor(y / 16 + 0.5) * 16)

    def can_place(self, kind, x, y, margin=4, ignoring=None):
        r = square_rect(x, y, BUILDINGS[kind].half)
        if r[0] < 30 or r[1] < 30 or r[2] > defs.WORLD_W - 30 or r[3] > defs.WORLD_H - 30:
            return False
        rm = (r[0] - margin, r[1] - margin, r[2] + margin, r[3] + margin)
        for b in self.buildings:
            if not b.dead and rects_intersect(b.rect, rm):
                return False
        for w in self.walls:
            if rects_intersect(w, rm):
                return False
        for c in self.crystals:
            if not c.dead and rect_distance(rm, c.x, c.y) < c.radius + 20:
                return False
        for o in self.nearby_obstacles(x, y):
            if rect_distance(rm, o[0], o[1]) < o[2]:
                return False
        for u in self.units:
            if u is ignoring:
                continue
            for o in [u.order] + u.queued:
                if o[0] == "build" and rects_intersect(square_rect(o[2], o[3], BUILDINGS[o[1]].half), rm):
                    return False
        return True

    def start_building(self, kind, x, y, team):
        b = Building(self, kind, team, x, y, False)
        self._add(b)
        self.emit("smoke", x, y, BUILDINGS[kind].half * 0.6)
        return b

    def building_completed(self, b):
        self.emit("built", b.team, b.kind, b.id)

    def refund(self, amount, team):
        self.resources[team] += amount

    def supply_used(self, team):
        return (sum(u.stats.supply for u in self.units if u.team == team)
                + sum(UNITS[k].supply for b in self.buildings if b.team == team for k in b.queue))

    def supply_cap(self, team):
        return min(200, sum(b.supply for b in self.buildings if b.team == team and b.built))

    def train(self, kind, bs, team):
        s = UNITS[kind]
        if s.requires and not self.has_built(s.requires, team):
            self.emit("msg", team, f"Requires {BUILDINGS[s.requires].name}", "bad")
            return False
        cands = [b for b in bs if b.built and not b.dead and kind in b.stats.produces and len(b.queue) < 5]
        if not cands:
            self.emit("msg", team, "Production queue full", "bad")
            return False
        b = min(cands, key=lambda b: len(b.queue))
        if self.resources[team] < s.cost:
            self.emit("msg", team, "Not enough crystal", "bad")
            return False
        if self.supply_used(team) + s.supply > self.supply_cap(team):
            self.emit("msg", team, "Not enough supply — build a Supply Depot (E)", "bad")
            return False
        self.resources[team] -= s.cost
        b.queue.append(kind)
        return True

    def cancel_queue(self, b, index):
        if 0 <= index < len(b.queue):
            k = b.queue.pop(index)
            if index == 0:
                b.queue_progress = 0.0
            self.refund(UNITS[k].cost, b.team)

    def spawn_unit(self, kind, b):
        tx, ty = b.rally if b.rally else (b.x, b.y - 1)
        dx, dy = tx - b.x, ty - b.y
        d = math.hypot(dx, dy)
        ux, uy = (dx / d, dy / d) if d > 1e-3 else (0.0, -1.0)
        off = b.half + UNITS[kind].radius + 4
        u = Unit(self, kind, b.team, b.x + ux * off, b.y + uy * off)
        u.angle = u.gun_angle = math.atan2(uy, ux)
        self._add(u)
        self.units_trained[b.team] += 1
        tk = self.trained_kinds[b.team]
        tk[kind] = tk.get(kind, 0) + 1
        self.emit("trained", b.team, kind)
        if b.rally:
            c = self.crystal_at(*b.rally) if kind == "worker" else None
            u.order = ("gather", c) if c else ("move", *b.rally)
        elif kind == "worker":
            c = self.nearest_crystal(b.x, b.y, 700)
            if c:
                u.order = ("gather", c)

    def crystal_at(self, x, y):
        for c in self.crystals:
            if not c.dead and math.hypot(c.x - x, c.y - y) < c.radius + 10:
                return c
        return None

    def deposit(self, amount, team, x, y):
        mult = self.difficulty.income if self.is_ai(team) else 1.0
        self.resources[team] += amount * mult
        self.crystals_mined[team] += amount
        self.emit("income", team, x, y, amount)

    def nearest_crystal(self, x, y, within):
        best, best_d = None, within
        for c in self.crystals:
            if not c.dead:
                d = math.hypot(c.x - x, c.y - y)
                if d < best_d:
                    best, best_d = c, d
        return best

    def nearest_dropoff(self, team, x, y):
        hqs = [b for b in self.buildings if b.team == team and b.kind == "hq" and b.built and not b.dead]
        return min(hqs, key=lambda b: math.hypot(b.x - x, b.y - y)) if hqs else None

    def find_wounded(self, e, radius):
        """The ally on foot most worth a Medic's attention within `radius`: near and badly hurt."""
        best, best_score = None, 1e9
        lim = radius + 40
        for u in self.units:
            if u is e or u.dead or u.kind == "tank" or u.hp >= u.max_hp or not self.allied(u.team, e.team) \
                    or abs(u.x - e.x) > lim or abs(u.y - e.y) > lim:
                continue
            d = e.distance_to(u)
            if d > radius:
                continue
            score = d * (0.4 + 0.6 * u.hp / u.max_hp)
            if score < best_score:
                best, best_score = u, score
        return best

    def find_target(self, e, radius, min_range=0.0):
        """The best enemy within `radius` of `e` — and, for a sieged tank, no closer than `min_range`."""
        best, best_score = None, 1e9
        lim = radius + 40
        for u in self.units:
            if u.dead or self.allied(u.team, e.team) or abs(u.x - e.x) > lim or abs(u.y - e.y) > lim:
                continue
            d = e.distance_to(u)
            if d > radius or d < min_range or not u.targetable_by(e.team):
                continue
            score = d + (60 if u.kind == "worker" else 0)
            if score < best_score:
                best, best_score = u, score
        for b in self.buildings:
            if b.dead or self.allied(b.team, e.team):
                continue
            d = e.distance_to(b)
            if d > radius or d < min_range or not b.targetable_by(e.team):
                continue
            score = d + (30 if b.kind == "turret" else 200)
            if score < best_score:
                best, best_score = b, score
        return best

    def primary_target(self, team, x, y):
        """The nearest enemy building — unless a Shield Generator covers it, in which case the generator: drop
        the field first and the rest comes down."""
        bs = [b for b in self.buildings if not b.dead and self.enemies(b.team, team)]
        if bs:
            near = min(bs, key=lambda b: math.hypot(b.x - x, b.y - y))
            gens = [g for g in bs if g.kind == "shield" and g.team == near.team and g.built
                    and math.hypot(g.x - near.x, g.y - near.y) <= SHIELD_RADIUS]
            return min(gens, key=lambda g: math.hypot(g.x - x, g.y - y)) if gens else near
        us = [u for u in self.units if not u.dead and self.enemies(u.team, team)]
        return min(us, key=lambda u: math.hypot(u.x - x, u.y - y)) if us else None

    def place_ping(self, slot, x, y, kind=0):
        """An alert point — kind 0 "attack here", 1 "help here" — shown to the whole alliance and answered by
        its computer players. One every 3 seconds."""
        if self.elapsed - self._ping_time.get(slot, -100) < 3.0:
            return
        x = clamp(x, 0.0, defs.WORLD_W)
        y = clamp(y, 0.0, defs.WORLD_H)
        kind = 1 if kind else 0
        self._ping_time[slot] = self.elapsed
        self.pings = [p for p in self.pings if self.elapsed - p[3] < 30.0] + [(slot, x, y, self.elapsed, kind)]
        self.emit("ping", slot, x, y, kind)

    def alert_attack(self, team, x, y):
        if self.elapsed - self._alert_time.get(team, -100) > 1.0:
            self._alert_time[team] = self.elapsed
            self.emit("alert", team, x, y)

    def wave_launched(self, team, target):
        for s, p in self.players.items():
            if not p.is_ai and self.enemies(s, team):
                self.emit("wave", s)

    # ------------------------------------------------------------ shells

    def launch_shell(self, x0, y0, x1, y1, damage, splash, team, attacker, arc=False):
        """A shell in flight. Artillery shells (`arc`) fly slowly in a high arc that the clients draw."""
        dur = max(0.05, math.hypot(x1 - x0, y1 - y0) / (ARTILLERY_SHELL_SPEED if arc else TANK_SHELL_SPEED))
        self.shells.append([x0, y0, x1, y1, dur, 0.0, damage, splash, team, attacker])
        self.emit("shell", x0, y0, x1, y1, dur, team, 1 if arc else 0)

    # ------------------------------------------------------------ supply crates

    def _update_crates(self):
        """Drops a crate now and then, retires old ones, and hands a crate to the first unit to reach it."""
        if self.elapsed >= self.next_crate:
            self.next_crate = self.elapsed + CRATE_INTERVAL
            if len(self.crates) < CRATE_MAX:
                self.drop_crate()
        if not self.crates:
            return
        for c in list(self.crates):
            if self.elapsed - c.born > CRATE_LIFE:
                self._remove_crate(c)
                continue
            taker = None
            for u in self.units:
                if not u.dead and abs(u.x - c.x) < 60 and abs(u.y - c.y) < 60 \
                        and math.hypot(u.x - c.x, u.y - c.y) <= c.radius + u.radius:
                    taker = u
                    break
            if taker is not None:
                self.collect_crate(c, taker.team)

    def drop_crate(self, kind=None):
        """A crate somewhere open: clear of water and cliffs, away from every base and every mineral field."""
        for _ in range(60):
            x = random.uniform(200, defs.WORLD_W - 200)
            y = random.uniform(200, defs.WORLD_H - 200)
            if self.nav.is_blocked(int(x // 40), int(y // 40)):
                continue
            if any(math.hypot(b.x - x, b.y - y) < 600 for b in self.buildings if not b.dead):
                continue
            if any(math.hypot(c.x - x, c.y - y) < 120 for c in self.crystals if not c.dead):
                continue
            if any(rect_distance(w, x, y) < 40 for w in self.walls):
                continue
            k = kind or random.choices(CRATE_KINDS, weights=(50, 35, 15))[0]
            amount = random.choice(CRATE_CRYSTAL) if k == "crystal" else 0
            c = Crate(self.next_id(), x, y, k, amount, self.elapsed)
            self.crates.append(c)
            self.by_id[c.id] = c
            return c
        return None

    def _remove_crate(self, c):
        c.dead = True
        self.crates.remove(c)
        self.by_id.pop(c.id, None)

    def collect_crate(self, c, team):
        """The gift: crystal into the bank, or troops spawned around the crate for that side."""
        if c.kind == "crystal":
            self.resources[team] += c.amount
        else:
            kinds = ["marine"] * CRATE_SQUAD if c.kind == "squad" else ["tank"]
            for i, k in enumerate(kinds):
                a = i / len(kinds) * 2 * math.pi
                u = Unit(self, k, team, c.x + math.cos(a) * 26, c.y + math.sin(a) * 26)
                self._add(u)
        self.emit("crate", team, c.x, c.y, c.kind, c.amount)
        self._remove_crate(c)

    def _update_shields(self):
        """Every building within SHIELD_RADIUS of a finished friendly Shield Generator carries a shield."""
        gens = [b for b in self.buildings if b.kind == "shield" and b.built and not b.dead]
        for b in self.buildings:
            b.shielded = b.built and not b.dead and any(
                g.team == b.team and math.hypot(g.x - b.x, g.y - b.y) <= SHIELD_RADIUS for g in gens)

    def _update_shells(self, dt):
        if not self.shells:
            return
        landed = []
        for s in self.shells:
            s[5] += dt
            if s[5] >= s[4]:
                landed.append(s)
        if landed:
            self.shells = [s for s in self.shells if s[5] < s[4]]
            for s in landed:
                x, y = s[2], s[3]
                self.emit("explode", x, y, s[7] * 0.55, 1, 0)
                self.emit("sound", "explosion", x, y)
                self._splash(x, y, s[7], s[6], s[8], s[9])

    def _splash(self, x, y, radius, damage, team, attacker):
        for u in self.units:
            if not u.dead and self.enemies(u.team, team):
                d = math.hypot(u.x - x, u.y - y) - u.radius
                if d <= radius:
                    u.take_damage(damage * (1 - 0.5 * max(0.0, d) / radius), attacker)
        for b in self.buildings:
            if not b.dead and self.enemies(b.team, team) and rect_distance(b.rect, x, y) <= radius * 0.5:
                b.take_damage(damage, attacker)
        # Bridges belong to nobody, so shells hit them whoever fired: a tank shelling a crossing is the
        # ordinary way to break one.
        for br in self.bridges:
            if br.intact and rect_distance(br.rect, x, y) <= radius * 0.5:
                br.take_damage(damage, attacker)
