"""Computer player: economy, timed build plan, expansion, defence and escalating attack waves.

Works for any slot; enemies are every player outside its alliance."""
import math
import random

from . import defs
from .defs import BRIDGE_COST, BUILDINGS, rect_distance, square_rect


class AI:
    def __init__(self, game, team):
        self.game = game
        self.team = team
        self.think = 1.0
        d = game.difficulty
        self.wave_size = d.initial_wave
        self.next_wave = d.first_attack
        self.attackers = []

    @property
    def diff(self):
        return self.game.difficulty

    def update(self, dt):
        self.think -= dt
        if self.think > 0:
            return
        self.think = 0.5
        g = self.game
        mine = [u for u in g.units if u.team == self.team]
        bases = [b for b in g.buildings if b.team == self.team]
        if not bases:
            return
        hq = next((b for b in bases if b.kind == "hq"), bases[0])
        workers = [u for u in mine if u.kind == "worker"]
        army = [u for u in mine if u.kind != "worker"]
        self.attackers = [u for u in self.attackers if not u.dead]
        attacking = set(id(u) for u in self.attackers)
        home = [u for u in army if id(u) not in attacking]

        dropoffs = [b for b in bases if b.kind == "hq" and b.built]
        for w in workers:
            if w.order[0] != "idle":
                continue
            served = [c for c in g.crystals if not c.dead and any(math.hypot(d.x - c.x, d.y - c.y) < 700 for d in dropoffs)]
            c = min(served, key=lambda c: math.hypot(c.x - w.x, c.y - w.y)) if served else g.nearest_crystal(w.x, w.y, 6000)
            if c:
                w.command(("gather", c))

        reserve = self._construct(hq, bases, workers)
        self._produce(hq, bases, workers, reserve)
        self._rebuild_bridges(hq, workers)
        self._repair(bases, workers)
        self._defend(bases, home)
        self._attack(hq, home)

    @staticmethod
    def _pending(kind, workers):
        n = 0
        for w in workers:
            for o in [w.order] + w.queued:
                if o[0] == "build" and o[1] == kind:
                    n += 1
        return n

    def _construct(self, hq, bases, workers):
        g = self.game
        t = g.elapsed / self.diff.pace

        def count(k):
            return sum(1 for b in bases if b.kind == k) + self._pending(k, workers)

        used = g.supply_used(self.team)
        pending_supply = sum(b.stats.supply for b in bases if not b.built) + self._pending("depot", workers) * 8
        cap = g.supply_cap(self.team) + pending_supply
        producers = sum(1 for b in bases if b.kind in ("barracks", "factory", "hq"))
        bank = g.resources[self.team]

        want, site = None, None
        if cap < 200 and cap - used < 4 + producers * 3 and self._pending("depot", workers) < (2 if bank > 400 else 1):
            want = "depot"
        elif count("hq") < 3 and (t > 300 or self._home_crystal_left(bases) < 5000):
            e = self._expansion_site(hq.x, hq.y)
            if e:
                want, site = "hq", e
        if want is None:
            plan = [("barracks", 1 if t > 35 else 0), ("turret", 1 if t > 140 else 0), ("factory", 1 if t > 170 else 0),
                    ("barracks", 2 if t > 230 else 0), ("radar", 1 if t > 260 else 0), ("turret", 2 if t > 300 else 0),
                    ("factory", 2 if t > 420 else 0), ("barracks", 3 if t > 520 else 0), ("turret", 4 if t > 560 else 0)]
            for k, n in plan:
                if n > 0 and count(k) < n:
                    req = BUILDINGS[k].requires
                    if req and not g.has_built(req, self.team):
                        continue
                    want = k
                    break
            # Floating crystal: add production so income gets spent.
            if want is None and bank > 450 and g.has_built("barracks", self.team):
                if count("factory") < 3 and count("factory") * 2 < count("barracks"):
                    want = "factory"
                elif count("barracks") < 6:
                    want = "barracks"
        if want is None or not workers:
            return 0
        cost = BUILDINGS[want].cost
        if bank < cost:
            return cost
        candidates = [w for w in workers if w.order[0] != "build"]
        if not candidates:
            return 0
        builder = min(candidates, key=lambda w: math.hypot(w.x - hq.x, w.y - hq.y))
        spot = site or self._find_spot(want, hq.x, hq.y)
        if spot is None:
            return 0
        g.resources[self.team] -= cost
        builder.order_build(want, spot[0], spot[1])
        return 0

    def _rebuild_bridges(self, hq, workers):
        """A fallen crossing near home is worth putting back: it is the road its attacks travel on.
        One Engineer at a time, and only with crystal to spare, so this never starves the army."""
        g = self.game
        if g.resources[self.team] < BRIDGE_COST + 250:
            return
        if any(w.order[0] == "rebuild" for w in workers):
            return
        down = [b for b in g.bridges if not b.intact and math.hypot(b.x - hq.x, b.y - hq.y) < 2200]
        if not down:
            return
        b = min(down, key=lambda b: math.hypot(b.x - hq.x, b.y - hq.y))
        free = [w for w in workers if w.order[0] in ("idle", "gather")]
        if not free:
            return
        builder = min(free, key=lambda w: math.hypot(w.x - b.x, w.y - b.y))
        g.resources[self.team] -= BRIDGE_COST
        builder.command(("rebuild", b))

    def _repair(self, bases, workers):
        """Send one Engineer to the worst-hit building below 70%, if there is crystal to spare. One at a time,
        so the economy keeps running while the base is patched up."""
        g = self.game
        if g.resources[self.team] < 150 or any(w.order[0] == "repair" for w in workers):
            return
        hurt = [b for b in bases if b.built and not b.dead and b.hp < b.max_hp * 0.7]
        if not hurt:
            return
        b = min(hurt, key=lambda b: b.hp / b.max_hp)
        free = [w for w in workers if w.order[0] in ("idle", "gather")]
        if free:
            min(free, key=lambda w: math.hypot(w.x - b.x, w.y - b.y)).order_repair(b)

    def _home_crystal_left(self, bases):
        hqs = [b for b in bases if b.kind == "hq"]
        return sum(c.amount for c in self.game.crystals
                   if not c.dead and any(math.hypot(h.x - c.x, h.y - c.y) < 700 for h in hqs))

    def _expansion_site(self, hx, hy):
        g = self.game
        claimed = [b for b in g.buildings if b.kind == "hq"]
        pending = [(o[2], o[3]) for u in g.units for o in [u.order] + u.queued if o[0] == "build" and o[1] == "hq"]
        free = [c for c in g.crystals if not c.dead
                and not any(math.hypot(b.x - c.x, b.y - c.y) < 800 for b in claimed)
                and not any(math.hypot(px - c.x, py - c.y) < 800 for px, py in pending)]
        if not free:
            return None
        target = min(free, key=lambda c: math.hypot(c.x - hx, c.y - hy))
        field = [c for c in free if math.hypot(c.x - target.x, c.y - target.y) < 250]
        cx = sum(c.x for c in field) / len(field)
        cy = sum(c.y for c in field) / len(field)
        to_home = math.atan2(hy - cy, hx - cx)
        for i in range(16):
            a = to_home + ((i + 1) // 2) * (0.35 if i % 2 == 0 else -0.35)
            for d in (250, 290, 330):
                p = g.snapped(cx + math.cos(a) * d, cy + math.sin(a) * d)
                if g.can_place("hq", p[0], p[1], margin=10):
                    return p
        return None

    def _find_spot(self, kind, cx, cy):
        g = self.game
        to_center = math.atan2(defs.WORLD_H / 2 - cy, defs.WORLD_W / 2 - cx)
        half = BUILDINGS[kind].half
        for attempt in range(90):
            spread = 0.7 if kind == "turret" else (math.pi * 0.65 if attempt < 30 else math.pi)
            a = to_center + random.uniform(-spread, spread)
            d = random.uniform(190, 260 + attempt * 8) + (90 if kind == "turret" else 0)
            p = g.snapped(cx + math.cos(a) * d, cy + math.sin(a) * d)
            r = square_rect(p[0], p[1], half)
            if all(rect_distance(r, c.x, c.y) > 90 for c in g.crystals) and g.can_place(kind, p[0], p[1], margin=26 if attempt < 45 else 14):
                return p
        return None

    def _produce(self, hq, bases, workers, reserve):
        g = self.game
        money = lambda: g.resources[self.team] - reserve
        queued_workers = sum(1 for k in hq.queue if k == "worker")
        if hq.kind == "hq" and hq.built and len(workers) + queued_workers < self.diff.worker_target and len(hq.queue) < 2:
            if len(workers) < 8 or money() >= 50:
                g.train("worker", [hq], self.team)
        tx, ty = defs.WORLD_W / 2 - hq.x, defs.WORLD_H / 2 - hq.y
        tl = math.hypot(tx, ty) or 1
        for b in bases:
            if not b.built or b.queue:
                continue
            if b.rally is None and b.kind in ("barracks", "factory"):
                b.rally = (hq.x + tx / tl * 260, hq.y + ty / tl * 260)
            if b.kind == "barracks":
                snipers = sum(1 for u in g.units if u.team == self.team and u.kind == "sniper")
                rangers = sum(1 for u in g.units if u.team == self.team and u.kind == "marine")
                if money() >= 125 and g.has_built("factory", self.team) and snipers * 3 < rangers:
                    g.train("sniper", [b], self.team)
                elif money() >= 50:
                    g.train("marine", [b], self.team)
            elif b.kind == "factory" and money() >= 150:
                g.train("tank", [b], self.team)

    def _defend(self, bases, home):
        g = self.game
        threat = None
        for u in g.units:
            if not g.enemies(u.team, self.team):
                continue
            if any(math.hypot(b.x - u.x, b.y - u.y) < 650 for b in bases):
                threat = u
                break
        if threat is None:
            return
        for u in home:
            if u.order[0] in ("idle", "move"):
                u.command(("amove", threat.x, threat.y))

    def _attack(self, hq, home):
        g = self.game
        overdue = g.elapsed > self.next_wave + 120 and len(home) >= 4
        if g.elapsed >= self.next_wave and (len(home) >= self.wave_size or overdue):
            target = g.primary_target(self.team, hq.x, hq.y)
            if target:
                for u in home:
                    u.command(("amove", target.x, target.y))
                self.attackers += home
                self.wave_size = min(40, self.wave_size + 2 + self.diff.index * 2)
                self.next_wave = g.elapsed + 50
                g.wave_launched(self.team, target)
        for u in self.attackers:
            if u.order[0] == "idle":
                t = g.primary_target(self.team, u.x, u.y)
                if t:
                    u.command(("amove", t.x, t.y))
