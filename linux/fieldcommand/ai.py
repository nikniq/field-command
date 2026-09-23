"""Computer player: economy, timed build plan, expansion, defence and escalating attack waves — and, from
1.9, an opponent that watches what it is up against and answers it.

It keeps a decaying tally of every enemy unit its side can see (`seen`) and turns that into a composition
to build towards: tanks answer massed Rangers, Snipers answer tanks, tanks and Rangers together answer
Snipers. Snipers in a wave hang back behind the main body so they fight at their range, and between waves
a couple of troops raid the enemy's nearest outlying building.

Works for any slot; enemies are every player outside its alliance."""
import math
import random

from . import defs
from .defs import (BRIDGE_COST, BUILDINGS, KITS, SIEGE_MIN_RANGE, SIEGE_RANGE, rect_distance, square_rect,
                   upgrade_cost)


class AI:
    def __init__(self, game, team):
        self.game = game
        self.team = team
        self.think = 1.0
        d = game.difficulty
        self.wave_size = d.initial_wave
        self.next_wave = d.first_attack
        self.attackers = []
        self.seen = {"marine": 0.0, "sniper": 0.0, "tank": 0.0}     # decaying count of enemy units seen
        self.answered_ping = -1.0        # time of the last allied alert point this side sent troops to
        # The route to the enemy: checked every few seconds; when it is cut, the crossing that reopens it.
        self.route_open = True
        self._next_route = 0.0
        self.route_bridge = None
        self.next_raid = 240.0

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

        self._observe()
        reserve = self._construct(hq, bases, workers)
        self._produce(hq, bases, workers, reserve)
        self._rebuild_bridges(hq, workers)
        self._repair(bases, workers)
        self._upgrade(hq, bases)
        self._shop(army)
        self._defend(bases, home)
        self._grab_crates(hq, home)
        self._open_route(hq, home, workers)
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
                    ("shield", 1 if t > 380 else 0), ("factory", 2 if t > 420 else 0), ("artillery", 1 if t > 480 else 0),
                    ("barracks", 3 if t > 520 else 0), ("turret", 4 if t > 560 else 0), ("artillery", 2 if t > 720 else 0)]
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

    def _upgrade(self, hq, bases):
        """With crystal to spare: production first, then armour on the Command Center, then the guns."""
        g = self.game
        if g.resources[self.team] < 500 or any(b.upgrading for b in bases):
            return
        wants = [(b, "prod") for b in bases if b.kind in ("barracks", "factory")]
        wants += [(hq, "armor"), (hq, "hp")]
        wants += [(b, "guns") for b in bases if b.kind == "turret"]
        wants += [(b, "defense") for b in bases if b.kind == "hq"]
        wants += [(b, "supply") for b in bases if b.kind == "depot"]
        for b, k in wants:
            if b.can_upgrade(k) and g.resources[self.team] >= upgrade_cost(k, b.kind) + 300:
                g.apply(self.team, ["upgrade", [b.id], k])
                return

    def _shop(self, army):
        """Sitting on crystal after the opening, buy the cheapest kit for whatever it fields most of."""
        g = self.game
        if g.elapsed < 240 or g.resources[self.team] < 800 or not army:
            return
        counts = {}
        for u in army:
            counts[u.kind] = counts.get(u.kind, 0) + 1
        kind = max(counts, key=counts.get)
        owned = g.kits[self.team]
        options = sorted((k for k in KITS if k.unit == kind and k.id not in owned), key=lambda k: k.cost)
        if options:
            g.buy_kit(self.team, options[0].id)

    def _repair(self, bases, workers):
        """Send one Engineer to the worst-hit building below 70% — or a tank below 60% resting at home — if there
        is crystal to spare. One at a time, so the economy keeps running while the base is patched up."""
        g = self.game
        if g.resources[self.team] < 150 or any(w.order[0] == "repair" for w in workers):
            return
        hurt = [b for b in bases if b.built and not b.dead and b.hp < b.max_hp * 0.7]
        hurt += [u for u in g.units if u.team == self.team and u.kind == "tank" and not u.dead
                 and u.hp < u.max_hp * 0.6 and u.order[0] == "idle"
                 and any(math.hypot(b.x - u.x, b.y - u.y) < 400 for b in bases)]
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
            guns = kind in ("turret", "artillery")
            spread = 0.7 if guns else (math.pi * 0.65 if attempt < 30 else math.pi)
            a = to_center + random.uniform(-spread, spread)
            d = random.uniform(190, 260 + attempt * 8) + (90 if guns else 0)
            p = g.snapped(cx + math.cos(a) * d, cy + math.sin(a) * d)
            r = square_rect(p[0], p[1], half)
            if all(rect_distance(r, c.x, c.y) > 90 for c in g.crystals) and g.can_place(kind, p[0], p[1], margin=26 if attempt < 45 else 14):
                return p
        return None

    # ------------------------------------------------------------ intelligence

    def _observe(self):
        """A decaying tally of the enemy army this side can currently see."""
        g = self.game
        for k in self.seen:
            self.seen[k] *= 0.85
        for u in g.units:
            if u.dead or u.kind not in self.seen or not g.enemies(u.team, self.team):
                continue
            if g.sees(self.team, u):
                self.seen[u.kind] += 1.0

    def _composition(self):
        """Target shares by unit kind, from a base mix bent by what has been seen: tanks answer massed
        Rangers, Snipers answer tanks, tanks and Rangers together answer Snipers."""
        w = {"marine": 3.0, "sniper": 1.0, "tank": 2.0}
        total = sum(self.seen.values())
        if total >= 3:
            share = {k: v / total for k, v in self.seen.items()}
            w["sniper"] += 3.0 * share["tank"]
            w["tank"] += 2.0 * share["marine"] + 1.0 * share["sniper"]
            w["marine"] += 1.5 * share["sniper"]
        s = sum(w.values())
        return {k: v / s for k, v in w.items()}

    def _wanted(self, army):
        """The unit kind furthest below its target share; None when the army already matches."""
        counts = {"marine": 0, "sniper": 0, "tank": 0}
        for u in army:
            if u.kind in counts:
                counts[u.kind] += 1
        n = max(1, sum(counts.values()))
        comp = self._composition()
        deficit = {k: comp[k] * (n + 1) - counts[k] for k in counts}
        return max(deficit, key=deficit.get)

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
            army = [u for u in g.units if u.team == self.team and u.kind != "worker" and not u.dead]
            want = self._wanted(army)
            if b.kind == "barracks":
                foot = sum(1 for u in army if u.kind in ("marine", "sniper"))
                medics = sum(1 for u in army if u.kind == "medic")
                if foot >= 4 and medics * 4 < foot and money() >= 75:
                    g.train("medic", [b], self.team)      # one Medic for every four on foot
                elif want == "sniper" and money() >= 125 and g.has_built("factory", self.team):
                    g.train("sniper", [b], self.team)
                elif money() >= 50 and (want != "tank" or not g.has_built("factory", self.team) or money() >= 200):
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
                u.command(("amove", *self._standoff(u, threat.x, threat.y)))

    STANDOFF = {"sniper": 200.0, "medic": 120.0}

    def _standoff(self, u, tx, ty):
        """Where a unit should go for a target: Snipers stop 200 short so they fight at their range, and never
        walk into the line; Medics 120 short, behind it; everyone else goes to the target."""
        if u.kind not in self.STANDOFF:
            return tx, ty
        dx, dy = u.x - tx, u.y - ty
        d = math.hypot(dx, dy) or 1.0
        back = min(self.STANDOFF[u.kind], max(0.0, d - 60.0))
        return tx + dx / d * back, ty + dy / d * back

    def _grab_crates(self, hq, home):
        """A supply crate in sight and not too far from home is worth a trooper's walk."""
        g = self.game
        for c in g.crates:
            if math.hypot(c.x - hq.x, c.y - hq.y) > 1400 or not g.fog_for(self.team).is_visible(c.x, c.y):
                continue
            if any(u.order[0] == "move" and abs(u.order[1] - c.x) < 1 and abs(u.order[2] - c.y) < 1 for u in home):
                continue
            idle = [u for u in home if u.order[0] == "idle"]
            if idle:
                min(idle, key=lambda u: math.hypot(u.x - c.x, u.y - c.y)).command(("move", c.x, c.y))

    def _open_route(self, hq, home, workers):
        """When the way to the enemy is cut — the crossings are down — an attack must not bounce off the water:
        an Engineer goes to put back the bridge on the route, an escort holds the near bank, and the wave
        waits for the span. Rebuilding pays the bridge's price even with nothing else in the bank."""
        g = self.game
        if g.elapsed < self._next_route:
            return
        self._next_route = g.elapsed + 6.0
        target = g.primary_target(self.team, hq.x, hq.y)
        if target is None:
            self.route_open, self.route_bridge = True, None
            return
        self.route_open = g.nav.reaches(hq.x, hq.y, target.x, target.y)
        if self.route_open:
            self.route_bridge = None
            return
        down = [b for b in g.bridges if not b.intact]
        if not down:
            return
        b = min(down, key=lambda b: math.hypot(b.x - hq.x, b.y - hq.y) + math.hypot(target.x - b.x, target.y - b.y))
        self.route_bridge = b
        if not any(w.order[0] == "rebuild" for w in workers) and g.resources[self.team] >= BRIDGE_COST:
            free = [w for w in workers if w.order[0] in ("idle", "gather", "return")]
            if free:
                builder = min(free, key=lambda w: math.hypot(w.x - b.x, w.y - b.y))
                g.resources[self.team] -= BRIDGE_COST
                builder.command(("rebuild", b))
        # The escort holds the near bank: a little short of the ruins, on this side of the water.
        d = math.hypot(b.x - hq.x, b.y - hq.y) or 1.0
        px, py = b.x - (b.x - hq.x) / d * 150, b.y - (b.y - hq.y) / d * 150
        for u in [u for u in home if u.order[0] == "idle"][:6]:
            u.command(("amove", *self._standoff(u, px, py)))

    def _attack(self, hq, home):
        g = self.game
        overdue = g.elapsed > self.next_wave + 120 and len(home) >= 4
        if not self.route_open:
            self.next_wave = max(self.next_wave, g.elapsed + 10)       # the wave waits for the crossing
        if g.elapsed >= self.next_wave and (len(home) >= self.wave_size or overdue):
            target = g.primary_target(self.team, hq.x, hq.y)
            if target:
                for u in home:
                    u.command(("amove", *self._standoff(u, target.x, target.y)))
                self.attackers += home
                self.wave_size = min(40, self.wave_size + 2 + self.diff.index * 2)
                self.next_wave = g.elapsed + 50
                g.wave_launched(self.team, target)
        for u in self.attackers:
            if u.order[0] == "idle":
                t = g.primary_target(self.team, u.x, u.y)
                if t:
                    u.command(("amove", *self._standoff(u, t.x, t.y)))
        self._raid(hq, home)
        self._siege(home)
        self._towers(hq, home)
        self._answer_pings(home)

    def _answer_pings(self, home):
        """An ally's alert point: whatever is standing idle at home goes there (at least a pair, up to a wave),
        and stays out as attackers — so a human ally can call the computer's army onto a fight."""
        g = self.game
        calls = [p for p in g.pings if p[0] != self.team and g.allied(p[0], self.team)
                 and p[3] > self.answered_ping and g.elapsed - p[3] < 30.0]
        if not calls:
            return
        slot, x, y, t, _kind = calls[-1]
        self.answered_ping = t
        # Standing idle, or on a home errand (a watchtower, a defence): the call takes priority.
        idle = [u for u in home if u.order[0] in ("idle", "amove")]
        if len(idle) < 2:
            return
        party = idle[:max(4, self.wave_size)]
        for u in party:
            u.command(("amove", *self._standoff(u, x, y)))
        self.attackers += party

    def _raid(self, hq, home):
        """Between waves, two or three troops go for the enemy building nearest this base — usually an
        expansion or a forward depot — so the enemy has to watch its edges as well as its front."""
        g = self.game
        if g.elapsed < self.next_raid or len(home) < self.wave_size // 2 + 3 or self.diff.index == 0:
            return
        idle = [u for u in home if u.order[0] == "idle" and u.kind in ("marine", "sniper")]
        if len(idle) < 2:
            return
        targets = [b for b in g.buildings if not b.dead and g.enemies(b.team, self.team) and b.targetable_by(self.team)]
        if not targets:
            return
        t = min(targets, key=lambda b: math.hypot(b.x - hq.x, b.y - hq.y))
        party = idle[:3]
        for u in party:
            u.command(("amove", *self._standoff(u, t.x, t.y)))
        self.attackers += party
        self.next_raid = g.elapsed + 90

    def _towers(self, hq, home):
        """Between waves, a few idle troops go and sit on the nearest watchtower nobody on this side holds."""
        g = self.game
        if not g.towers or len(home) < 4 or g.elapsed < 120:
            return
        mine = g.players[self.team].team
        unheld = [t for t in g.towers if t.owner is None or g.players[t.owner].team != mine]
        if not unheld:
            return
        t = min(unheld, key=lambda t: math.hypot(t.x - hq.x, t.y - hq.y))
        idle = [u for u in home if u.order[0] == "idle" and u.kind != "worker"][:3]
        for u in idle:
            u.command(("amove", t.x + random.uniform(-40, 40), t.y + random.uniform(-40, 40)))

    def _siege(self, home):
        """Tanks dig in when an enemy building is within sieged range and pack up when nothing is."""
        g = self.game
        for u in home + self.attackers:
            if not u.can_siege or u.mode in (1, 3):
                continue
            near = g.find_target(u, SIEGE_RANGE - 20, min_range=SIEGE_MIN_RANGE)
            if not u.sieged and near is not None and near.is_building:
                u.set_siege(True)
            elif u.sieged and near is None:
                u.set_siege(False)
