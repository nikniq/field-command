"""Sessions connect the client scene to a game: `LocalSession` wraps an in-process World (single player),
`NetSession` mirrors a remote server from snapshots. Both expose the same view interface:

    slot, players, map, units, buildings, crystals, bridges, obstacles, resources, supply_used, supply_cap, elapsed,
    fog (FogGrid for my alliance), game_over, winner_team, can_pause, difficulty,
    send(cmd), update(dt) -> events, shown(e), mine(e), friendly(e), has_built(kind), order_points(u), stats()
"""
import math
import time

from . import mapgen
from . import defs
from .defs import KIT_IDS
from .defs import (BRIDGE_HP, BUILDINGS, BUILDING_KINDS, DEPOT_UPGRADED_SUPPLY, DIFFICULTIES, MODE_SIEGED,
                   MODE_SIEGING, MODE_UNSIEGING, TOWER_HALF, UNITS, UNIT_KINDS, UPGRADES, UPGRADE_KINDS,
                   VET_BONUS, angle_lerp, rect_distance, rects_intersect, square_rect, upgrade_applies)
from .fog import FogGrid
from .net import STATUS, event_visible, order_points as world_order_points
from .settings import settings
from .world import PlayerInfo, World

STATUS_NAMES = {v: k for k, v in STATUS.items()}


def team_of(slot, teams):
    """The alliance a slot plays for: its own in a free-for-all (teams 0), otherwise dealt round-robin into
    `teams` alliances — the same rule as the multiplayer lobby's presets."""
    return slot % teams + 1 if teams >= 2 else slot + 1


def lineup_names(opponents):
    return ["You"] + [f"Computer {i}" if opponents > 1 else "Computer" for i in range(1, opponents + 1)]


def lineup_text(opponents, teams):
    """Who plays with whom, for the title screen: "You + Computer 2  vs  Computer 1 + Computer 3"."""
    names = lineup_names(opponents)
    if teams < 2:
        return "Free-for-all: everyone for themselves"
    sides = {}
    for i, n in enumerate(names):
        sides.setdefault(team_of(i, teams), []).append(n)
    full = "  vs  ".join(" + ".join(members) for _t, members in sorted(sides.items()))
    if len(full) <= 80:
        return full
    # Big games: say it in numbers rather than names so the line fits the screen.
    mine = sides.pop(team_of(0, teams))
    others = [len(m) for _t, m in sorted(sides.items())]
    allies = len(mine) - 1
    sizes = str(others[0]) if len(set(others)) == 1 else "/".join(map(str, others))
    return (f"You + {allies} {'ally' if allies == 1 else 'allies'}  vs  "
            f"{len(others)} {'team' if len(others) == 1 else 'teams'} of {sizes}")


class _Base:
    can_pause = False

    def mine(self, e):
        return e.team == self.slot

    def friendly(self, e):
        return self.allied(e.team, self.slot)

    def allied(self, a, b):
        pa, pb = self.players.get(a), self.players.get(b)
        return pa is not None and pb is not None and pa.team == pb.team

    def my_team(self):
        return self.players[self.slot].team

    def idle_workers(self):
        return [u for u in self.units if u.team == self.slot and u.idle_worker]

    def army(self):
        return [u for u in self.units if u.team == self.slot and u.kind != "worker"]

    def crystal_at(self, x, y):
        for c in self.crystals:
            if not c.dead and math.hypot(c.x - x, c.y - y) < c.radius + 10:
                return c
        return None

    def nearby_obstacles(self, x, y):
        return [o for o in self.obstacles if abs(o[0] - x) < 200 and abs(o[1] - y) < 200]

    def can_place(self, kind, x, y, margin=4):
        """Client-side placement check (the server re-validates)."""
        r = square_rect(x, y, BUILDINGS[kind].half)
        if r[0] < 30 or r[1] < 30 or r[2] > defs.WORLD_W - 30 or r[3] > defs.WORLD_H - 30:
            return False
        rm = (r[0] - margin, r[1] - margin, r[2] + margin, r[3] + margin)
        if any(not b.dead and rects_intersect(b.rect, rm) for b in self.buildings):
            return False
        if any(rects_intersect(tuple(w[:4]), rm) for w in self.map.get("walls", [])):
            return False
        if any(not c.dead and rect_distance(rm, c.x, c.y) < c.radius + 20 for c in self.crystals):
            return False
        if any(rect_distance(rm, o[0], o[1]) < o[2] for o in self.nearby_obstacles(x, y)):
            return False
        for u in self.units:
            if u.team != self.slot:
                continue
            for code, px, py, k in self.order_points(u, with_kind=True):
                if code == STATUS["build"] and k and rects_intersect(square_rect(px, py, BUILDINGS[k].half), rm):
                    return False
        return True

    def player_name(self, slot):
        p = self.players.get(slot)
        return p.name if p else "?"


# ---------------------------------------------------------------- local (single player)

class LocalSession(_Base):
    can_pause = True

    def __init__(self, difficulty, autoplay=False, map_id=None, opponents=1, players=None, slot=0, teams=0,
                 world=None):
        self.difficulty = difficulty
        self.slot = slot
        if world is not None:
            # A loaded game: the world is already built, and its map says what "Play again" should restart.
            spec = world.map
            opponents = len(world.players) - 1
        else:
            spec = mapgen.resolve(map_id or "auto", 1 + opponents)
            opponents = min(opponents, spec["players"] - 1)
        # Remember the setup so "Play again" starts the same game, not a default one.
        self.skirmish = (spec["id"] if world is not None else map_id, opponents, teams)
        if world is None and players is None:
            players = [PlayerInfo(i, name, team_of(i, teams), is_ai=(i > 0 or autoplay))
                       for i, name in enumerate(lineup_names(opponents))]
        self.world = world if world is not None else World(spec, players, difficulty)
        self.autosave_at = self.world.elapsed + 300
        self.map = self.world.map
        self.players = self.world.players
        self.obstacles = self.world.obstacles
        self.fog = self.world.fog_for(slot)
        self.time_scale = 1

    # saving
    def save(self, name, label=""):
        from .save import write_save
        return write_save(self.world, name, label)

    @classmethod
    def load(cls, name, autoplay=False):
        from .save import read_save
        w = read_save(name)
        me = w.players[0]
        me.is_ai = autoplay
        if autoplay and me.ai is None:
            from .ai import AI
            me.ai = AI(w, 0)
        return cls(w.difficulty, world=w)

    # view
    units = property(lambda self: self.world.units)
    buildings = property(lambda self: self.world.buildings)
    crystals = property(lambda self: self.world.crystals)
    bridges = property(lambda self: self.world.bridges)
    towers = property(lambda self: self.world.towers)
    kits = property(lambda self: self.world.kits[self.slot])
    elapsed = property(lambda self: self.world.elapsed)
    game_over = property(lambda self: self.world.game_over)
    winner_team = property(lambda self: self.world.winner_team)
    resources = property(lambda self: self.world.resources[self.slot])
    supply_used = property(lambda self: self.world.supply_used(self.slot))
    supply_cap = property(lambda self: self.world.supply_cap(self.slot))
    trained_kinds = property(lambda self: self.world.trained_kinds[self.slot])

    def shown(self, e):
        return self.world.sees(self.slot, e)

    def has_built(self, kind):
        return self.world.has_built(kind, self.slot)

    def by_id(self, i):
        return self.world.by_id.get(i)

    def order_points(self, u, with_kind=False):
        pts = world_order_points(u)
        if not with_kind:
            return pts
        kinds = [o[1] for o in [u.order] + u.queued if o[0] == "build"]
        out, ki = [], 0
        for code, x, y in pts:
            k = None
            if code == STATUS["build"] and ki < len(kinds):
                k = kinds[ki]
                ki += 1
            out.append((code, x, y, k))
        return out

    def send(self, cmd):
        self.world.apply(self.slot, cmd)

    def update(self, dt, paused=False):
        if not paused and not self.world.game_over:
            sdt = dt * settings.game_speed
            for _ in range(self.time_scale):
                self.world.step(sdt)
                if self.world.game_over:
                    break
        events = [ev for ev in self.world.events if event_visible(self.world, self.slot, ev)]
        self.world.events = []
        return events

    def stats(self):
        w = self.world
        return {s: {"name": p.name, "team": p.team, "trained": w.units_trained[s], "lost": w.units_lost[s],
                    "mined": w.crystals_mined[s], "alive": p.alive} for s, p in w.players.items()}

    def leave(self):
        pass


# ---------------------------------------------------------------- network

class _ProxyCrystal:
    radius = 18

    def __init__(self, id, x, y, amount, variant):
        self.id, self.x, self.y = id, x, y
        self.amount = self.max_amount = amount
        self.variant = variant % 3
        self.dead = False
        self.flip = (id * 7) % 2 == 0
        self.phase = (id * 1.37) % 6

    @property
    def scale(self):
        return 0.55 + 0.45 * self.amount / self.max_amount


class _ProxyBridge:
    """Client-side bridge. The footprint comes from the map, the condition from each snapshot."""
    is_building = False
    dead = False
    team = None
    name = "Bridge"

    def __init__(self, id, rect):
        x0, y0, x1, y1 = rect
        self.id = id
        self.rect = (x0, y0, x1, y1)
        self.x, self.y = (x0 + x1) / 2, (y0 + y1) / 2
        self.horizontal = (x1 - x0) >= (y1 - y0)
        self.intact = True
        self.hp = self.max_hp = BRIDGE_HP
        self.progress = 0.0
        self.selected = self.hovered = False

    def surface_distance(self, px, py):
        return rect_distance(self.rect, px, py)

    def targetable_by(self, slot):
        return self.intact


class _ProxyTower:
    is_building = False
    dead = False
    team = None
    name = "Watchtower"

    def __init__(self, id, x, y):
        self.id, self.x, self.y = id, x, y
        self.half = TOWER_HALF
        self.rect = square_rect(x, y, TOWER_HALF)
        self.owner = self.capturing = None
        self.progress = 0.0
        self.selected = self.hovered = False

    def surface_distance(self, px, py):
        return rect_distance(self.rect, px, py)

    def targetable_by(self, slot):
        return False


class _ProxyUnit:
    is_building = False

    def __init__(self, id, team, kind):
        self.id, self.team, self.kind = id, team, kind
        self.stats = UNITS[kind]
        self.radius = self.body_radius = self.stats.radius
        self.max_hp = self.stats.hp
        self.sight = self.stats.sight
        self.name = self.stats.name
        self.hp = self.max_hp
        self.carrying = 0
        self.status = 0
        self.queued = []
        self.pts = []
        self.dead = False
        self.selected = self.hovered = False
        self.recoil = self.pulse = 0.0
        self.x = self.y = self.angle = self.gun_angle = 0.0
        self.mode = 0
        self.rank = 0
        self.kills = 0
        self._from = self._to = None

    @property
    def idle_worker(self):
        return self.kind == "worker" and self.status == 0 and not self.queued

    @property
    def sieged(self):
        return self.mode == MODE_SIEGED

    @property
    def can_siege(self):
        return self.kind == "tank"

    def status_text(self):
        if self.mode == MODE_SIEGING:
            return "Digging in"
        if self.mode == MODE_UNSIEGING:
            return "Packing up"
        tag = f"  ·  Rank {self.rank}" if self.rank else ""
        if self.sieged:
            return ("Sieged — engaging target" if self.status == 3 else "Sieged") + tag
        k = STATUS_NAMES.get(self.status, "idle")
        # .get with a default: a status this client does not know must never take the HUD down.
        return {"idle": "Idle", "move": "Moving", "amove": "Attack-moving", "attack": "Engaging target",
                "gather": "Returning cargo" if self.carrying else "Mining crystal", "return": "Returning cargo",
                "build": "Heading to build", "rebuild": "Rebuilding a bridge",
                "repair": "Repairing", "heal": "Treating a casualty"}.get(k, "Busy")

    def surface_distance(self, px, py):
        return math.hypot(px - self.x, py - self.y) - self.radius


class _ProxyBuilding:
    is_building = True

    def __init__(self, id, team, kind, x, y):
        self.id, self.team, self.kind = id, team, kind
        self.stats = BUILDINGS[kind]
        self.half = self.stats.half
        self.max_hp = self.stats.hp
        self.sight = self.stats.sight
        self.name = self.stats.name
        self.x, self.y = x, y
        self.rect = square_rect(x, y, self.half)
        self.hp = self.max_hp
        self.built = True
        self.progress = 1.0
        self.queue = []
        self.queue_progress = 0.0
        self.rally = None
        self.gun_angle = 0.0
        self.upgrades = set()
        self.upgrading = None
        self.upgrade_progress = 0.0
        self.dish_angle = (id * 0.7) % 6.28
        self.dead = False
        self.selected = self.hovered = False

    def surface_distance(self, px, py):
        return rect_distance(self.rect, px, py)

    def can_upgrade(self, kind):
        return (self.built and not self.dead and upgrade_applies(kind, self.kind) and kind not in self.upgrades
                and self.upgrading is None)

    @property
    def supply(self):
        return self.stats.supply + (DEPOT_UPGRADED_SUPPLY if "supply" in self.upgrades else 0)


class _Player:
    def __init__(self, slot, name, team, ai):
        self.slot, self.name, self.team, self.is_ai = slot, name, team, ai
        self.alive = True


class NetSession(_Base):
    """Client-side mirror of a server game, built from snapshots and interpolated between them."""

    def __init__(self, conn, start_msg):
        self.conn = conn
        self.slot = start_msg["slot"]
        self.map = start_msg["map"]
        defs.set_world_size(self.map.get("w", defs.DEFAULT_WORLD[0]), self.map.get("h", defs.DEFAULT_WORLD[1]))
        self.difficulty = DIFFICULTIES[start_msg.get("difficulty", 1)]
        self.players = {p["slot"]: _Player(p["slot"], p["name"], p["team"], p["ai"]) for p in start_msg["players"]}
        self.obstacles = [tuple(t) for t in self.map["trees"]]
        self.crystals = [_ProxyCrystal(*c) for c in start_msg["crystals"]]
        self.bridges = []
        self._bridges_by_id = {}
        self.towers = []
        self._towers_by_id = {}
        self.kits = set()
        self._crystals_by_id = {c.id: c for c in self.crystals}
        self._units, self._buildings = {}, {}
        self.units, self.buildings = [], []
        self.fog = FogGrid()
        self._fog_timer = 0.0
        self.elapsed = 0.0
        self.resources = 250
        self.supply_used, self.supply_cap = 0, 10
        self.game_over = False
        self.winner_team = None
        self.final_stats = None
        self.disconnected = None
        self.trained_kinds = {}
        self._snap_time = None
        self._interval = 0.1
        self._pending_events = []
        self.lobby_msg = None

    def shown(self, e):
        return True  # the server only sends what we may see

    def has_built(self, kind):
        return any(b.team == self.slot and b.kind == kind and b.built for b in self.buildings)

    def by_id(self, i):
        return (self._units.get(i) or self._buildings.get(i) or self._crystals_by_id.get(i)
                or self._bridges_by_id.get(i))

    def order_points(self, u, with_kind=False):
        pts = u.pts if u.team == self.slot else []
        return [(c, x, y, None) for c, x, y in pts] if with_kind else pts

    def send(self, cmd):
        self.conn.send({"t": "cmd", "c": cmd})

    def chat(self, text):
        self.conn.send({"t": "chat", "text": text})

    def leave(self):
        try:
            self.conn.send({"t": "leave"})
            self.conn.close()
        except Exception:  # noqa: BLE001
            pass

    def stats(self):
        if self.final_stats:
            return {int(k): v for k, v in self.final_stats.items()}
        return {s: {"name": p.name, "team": p.team, "trained": 0, "lost": 0, "mined": 0, "alive": p.alive}
                for s, p in self.players.items()}

    # ------------------------------------------------------------ snapshots

    def _apply_snapshot(self, m):
        now = time.perf_counter()
        if self._snap_time is not None:
            self._interval = max(0.05, min(0.3, 0.8 * self._interval + 0.2 * (now - self._snap_time)))
        self._snap_time = now
        self.elapsed = m["time"]
        self.resources = m["res"]
        mask = m.get("kit", 0)
        self.kits = {k for i, k in enumerate(KIT_IDS) if mask & (1 << i)}
        self.supply_used, self.supply_cap = m["sup"]
        seen = set()
        orders = m.get("o", {})
        for (i, team, k, x, y, a, g, hp, carrying, mode, rank) in m["u"]:
            seen.add(i)
            u = self._units.get(i)
            ra, rg = math.radians(a), math.radians(g)
            if u is None:
                u = _ProxyUnit(i, team, UNIT_KINDS[k])
                u.x, u.y, u.angle, u.gun_angle = x, y, ra, rg
                u._from = (x, y, ra, rg)
                self._units[i] = u
            else:
                u._from = (u.x, u.y, u.angle, u.gun_angle)
            u._to = (x, y, ra, rg)
            u.hp, u.carrying, u.mode, u.rank = hp, carrying, mode, rank
            u.max_hp = UNITS[u.kind].hp * (1 + VET_BONUS * rank)
            o = orders.get(str(i))
            if o:
                u.status = o[0]
                u.queued = [None] * o[1]
                p = o[2]
                u.pts = [(p[j], p[j + 1], p[j + 2]) for j in range(0, len(p), 3)]
        for i in [i for i in self._units if i not in seen]:
            self._units.pop(i).dead = True
        seen = set()
        for (i, team, k, x, y, hp, built, prog, qprog, gun, queue, rally, ups, upg) in m["b"]:
            seen.add(i)
            b = self._buildings.get(i)
            if b is None:
                b = _ProxyBuilding(i, team, BUILDING_KINDS[k], x, y)
                b.gun_angle = math.radians(gun)
                self._buildings[i] = b
            b.hp, b.built, b.progress, b.queue_progress = hp, bool(built), prog / 100, qprog / 100
            b._gun_to = math.radians(gun)
            b.queue = [UNIT_KINDS[q] for q in queue]
            b.rally = tuple(rally) if rally else None
            b.upgrades = {UPGRADE_KINDS[j] for j in range(len(UPGRADE_KINDS)) if ups & (1 << j)}
            b.upgrading = UPGRADE_KINDS[upg[0]] if upg else None
            b.upgrade_progress = upg[1] / 100 if upg else 0.0
        for i in [i for i in self._buildings if i not in seen]:
            self._buildings.pop(i).dead = True
        for (i, intact, hp, prog) in m.get("br", ()):
            b = self._bridges_by_id.get(i)
            if b is None:
                # Bridges arrive in map order, so the nth id belongs to the nth footprint.
                rects = self.map.get("bridges", [])
                if len(self.bridges) >= len(rects):
                    continue
                b = _ProxyBridge(i, tuple(rects[len(self.bridges)]))
                self.bridges.append(b)
                self._bridges_by_id[i] = b
            b.intact, b.hp, b.progress = bool(intact), hp, prog / 100
        for (i, x, y, owner, capturing, prog) in m.get("tw", ()):
            t = self._towers_by_id.get(i)
            if t is None:
                t = _ProxyTower(i, x, y)
                self.towers.append(t)
                self._towers_by_id[i] = t
            t.owner = None if owner < 0 else owner
            t.capturing = None if capturing < 0 else capturing
            t.progress = prog / 100
        amounts = {i: a for i, a in m["c"]}
        for c in self.crystals:
            if c.id in amounts:
                c.amount = amounts[c.id]
            else:
                c.dead = True
        self.crystals = [c for c in self.crystals if not c.dead]
        for s, alive in m.get("p", {}).items():
            if int(s) in self.players:
                self.players[int(s)].alive = bool(alive)
        self.units = list(self._units.values())
        self.buildings = list(self._buildings.values())
        for ev in m.get("e", ()):
            ev = tuple(ev)
            if ev[0] == "trained" and ev[1] == self.slot:
                self.trained_kinds[ev[2]] = self.trained_kinds.get(ev[2], 0) + 1
            if ev[0] == "gameover":
                self.game_over = True
                self.winner_team = None if ev[1] == -1 else ev[1]
            self._pending_events.append(ev)

    def update(self, dt, paused=False):
        for m in self.conn.messages():
            t = m.get("t")
            if t == "snap":
                self._apply_snapshot(m)
            elif t == "end":
                self.game_over = True
                self.winner_team = m.get("winner_team")
                self.final_stats = m.get("stats")
            elif t == "lobby":
                self.lobby_msg = m
            elif t == "chat":
                self._pending_events.append(("chat", m.get("slot", -1), m.get("text", "")))
            elif t == "disconnected":
                self.disconnected = m.get("text", "Disconnected")
        # Interpolate toward the latest snapshot.
        if self._snap_time is not None:
            k = min(1.0, (time.perf_counter() - self._snap_time) / self._interval)
            for u in self.units:
                if u._from and u._to:
                    fx, fy, fa, fg = u._from
                    tx, ty, ta, tg = u._to
                    u.x = fx + (tx - fx) * k
                    u.y = fy + (ty - fy) * k
                    u.angle = angle_lerp(fa, ta, k)
                    u.gun_angle = angle_lerp(fg, tg, k)
            for b in self.buildings:
                b.gun_angle = angle_lerp(b.gun_angle, getattr(b, "_gun_to", b.gun_angle), min(1.0, dt * 12))
        self._fog_timer -= dt
        if self._fog_timer <= 0:
            self._fog_timer = 0.1
            viewers = [(e.x, e.y, e.sight) for e in self.units + self.buildings if self.friendly(e)]
            self.fog.recompute(viewers)
        events, self._pending_events = self._pending_events, []
        return events
