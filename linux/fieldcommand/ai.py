"""Computer player: economy, timed build plan, expansion, defence and escalating attack waves — and, from
1.9, an opponent that watches what it is up against and answers it.

It keeps a decaying tally of every enemy unit its side can see (`seen`) and turns that into a composition
to build towards: tanks answer massed Rangers, Snipers answer tanks, tanks and Rangers together answer
Snipers. Snipers in a wave hang back behind the main body so they fight at their range, and between waves
a couple of troops raid the enemy's nearest outlying building.

From 1.20 it is a strategist as well: it picks an opening for the first minutes (a rush, an economy or a
turtle), sends a scout to the enemy's door, expands when the home field runs low or its Engineers crowd
it, and keeps a turret and a garrison at every expansion it takes.

Works for any slot; enemies are every player outside its alliance."""
import math

from . import defs
from .defs import (ABILITIES, ALLOY_BUILD, ALLOY_COST, ALLOY_UPGRADE, DERELICT_RADIUS, GRENADE_SPLASH, BRIDGE_COST, BUILDINGS, KITS, SIEGE_MIN_RANGE, SIEGE_RANGE, rect_distance, square_rect,
                   upgrade_cost)

# Openings: how the first minutes are played. Each factor bends the timed plan — `barracks` and `turret`
# multiply the plan times for those buildings (turret also covers the shield), `attack` multiplies the time
# of the first wave, `wave` adds to its size, `workers` to the Engineer target, and `expand` multiplies the
# time before the first expansion. The same table lives in ServerWorld.swift (SAI.openings).
OPENINGS = {
    "rush": {"barracks": 0.55, "turret": 1.4, "attack": 0.6, "wave": -2, "workers": -3, "expand": 1.4},
    "economy": {"barracks": 1.0, "turret": 1.0, "attack": 1.3, "wave": 2, "workers": 4, "expand": 0.6},
    "turtle": {"barracks": 1.0, "turret": 0.5, "attack": 1.5, "wave": 4, "workers": 0, "expand": 1.0},
}
OPENING_ORDER = ["rush", "economy", "turtle"]
# Odds of each opening by difficulty (easy, normal, hard); a giant map never rushes.
OPENING_WEIGHTS = [[0, 1, 2], [1, 2, 1], [2, 2, 1]]
GIANT_W = 6000.0             # a world at least this wide counts as giant
GARRISON = [2, 3, 4]         # troops kept at every expansion, by difficulty
SCOUT_AT = 45.0              # the first scout leaves at this time (times the difficulty's pace)
SCOUT_EVERY = 150.0          # and another goes out this long after one comes home
EXPAND_AT = 300.0            # the timed expansion (times the opening's factor and the pace)
FORTIFY_AT = 150.0           # a turtle walls its approach from here (times the pace); others once the base has been hit
FORTIFY_DIST = 380.0         # the wall line sits this far from the Command Center, toward the middle of the map
FORTIFY_OFFSETS = (-4, -3, -2, 2, 3, 4)   # blocks either side of a two-block gap, in wall widths
FORTIFY_BLOCKS = 6


def choose_opening(rng, difficulty, giant):
    """One draw from the seeded stream, weighted by difficulty; identical in both editions."""
    weights = list(OPENING_WEIGHTS[difficulty])
    if giant:
        weights[0] = 0
    r = rng.random() * sum(weights)
    for name, w in zip(OPENING_ORDER, weights):
        r -= w
        if r < 0:
            return name
    return OPENING_ORDER[-1]


class AI:
    def __init__(self, game, team, opening=None):
        self.game = game
        self.team = team
        self.think = 1.0
        d = game.difficulty
        self.opening = opening or choose_opening(game.rng, d.index, defs.WORLD_W >= GIANT_W)
        o = OPENINGS[self.opening]
        self.wave_size = max(3, d.initial_wave + o["wave"])
        self.next_wave = d.first_attack * o["attack"]
        self.attackers = []
        self.scout = None                # the trooper out looking, and where it still has to go
        self.scout_route = []
        self.next_scout = SCOUT_AT * d.pace
        self.guards = []                 # troops posted at expansions; not part of the home army
        self.home_crystal_start = None   # crystal near the Command Center when the game began
        self.seen = {"marine": 0.0, "sniper": 0.0, "tank": 0.0, "gunship": 0.0}     # decaying count of enemy units seen
        self.hit_at = -1e9               # when a building of this side last took damage (the walls go up after)
        self.answered_ping = -1.0        # time of the last allied alert point this side sent troops to
        # The route to the enemy: checked every few seconds; when it is cut, the crossing that reopens it.
        self.route_open = True
        self._next_route = 0.0
        self.route_bridge = None
        self.next_raid = 240.0
        self.salvager = None             # the Engineer sent for the derelict Siege Tank
        self.gold_miners = []            # Engineers kept on the gold for alloy
        self.air_alarm = None            # (x, y, when): where a Gunship was last over one of this side's bases
        # A wave that is being beaten pulls back; a repelled attack on this base is answered at once.
        self.launched = 0                # how many went out with the current wave and raids
        self.threat_seen_at = -1e9       # when an enemy was last near a base of this side
        self.last_counter = -1e9
        self.counter_pending = False
        self.retreats = 0
        self.counters = 0
        self.retreats_row = 0            # retreats since the enemy last lost a building: after three, the waves commit
        self.enemy_buildings = None

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
        self.guards = [u for u in self.guards if not u.dead]
        away = set(id(u) for u in self.attackers + self.guards)
        if self.scout is not None:
            away.add(id(self.scout))
        home = [u for u in army if id(u) not in away]

        dropoffs = [b for b in bases if b.kind == "hq" and b.built]
        self.gold_miners = [w for w in self.gold_miners if not w.dead]
        gold = [c for c in g.crystals if not c.dead and c.gold]
        if gold and len(workers) >= 6 and g.has_built("factory", self.team) and len(self.gold_miners) < 2:
            # Alloy for the tanks: two Engineers on the nearest gold node from the moment there is a Factory.
            free = [w for w in workers if w not in self.gold_miners and w is not self.salvager and w.order[0] in ("idle", "gather")]
            node = min(gold, key=lambda c: math.hypot(c.x - hq.x, c.y - hq.y))
            for w in sorted(free, key=lambda w: math.hypot(w.x - node.x, w.y - node.y))[:2 - len(self.gold_miners)]:
                w.command(("gather", node))
                self.gold_miners.append(w)
        for w in workers:
            if w.order[0] != "idle" or w is self.salvager:
                continue
            if w in self.gold_miners and gold:
                w.command(("gather", min(gold, key=lambda c: math.hypot(c.x - w.x, c.y - w.y))))
                continue
            served = [c for c in g.crystals if not c.dead and any(math.hypot(d.x - c.x, d.y - c.y) < 700 for d in dropoffs)]
            c = min(served, key=lambda c: math.hypot(c.x - w.x, c.y - w.y)) if served else g.nearest_crystal(w.x, w.y, 6000)
            if c:
                w.command(("gather", c))

        self._observe()
        self._salvage(hq, workers, home)
        reserve = self._construct(hq, bases, workers)
        self._produce(hq, bases, workers, reserve)
        self._rebuild_bridges(hq, workers)
        self._repair(bases, workers)
        self._upgrade(hq, bases)
        self._shop(army)
        self._defend(bases, home)
        self._abilities(mine)
        self._fortify(hq, bases, workers)
        self._garrison(hq, bases, home)
        self._scout(hq, home)
        self._grab_crates(hq, home)
        self._open_route(hq, home, workers)
        self._attack(hq, home)

    # ------------------------------------------------------------ strategy

    def _plan(self, t):
        """The timed build plan, bent by the opening: (kind, how many by now)."""
        o = OPENINGS[self.opening]
        base = [("barracks", 35, 1), ("turret", 140, 1), ("factory", 170, 1), ("barracks", 230, 2),
                ("radar", 260, 1), ("turret", 300, 2), ("shield", 380, 1), ("factory", 420, 2),
                ("artillery", 480, 1), ("barracks", 520, 3), ("turret", 560, 4), ("artillery", 720, 2)]
        out = []
        for k, at, n in base:
            f = o["barracks"] if k == "barracks" else o["turret"] if k in ("turret", "shield") else 1.0
            out.append((k, n if t > at * f else 0))
        return out

    def _should_expand(self, t, bases, workers):
        """Take a new field on the clock, when the home field is running low, or when the Engineers crowd it."""
        left = self._home_crystal_left(bases)
        if self.home_crystal_start is None:
            self.home_crystal_start = max(1, left)
        hqs = [b for b in bases if b.kind == "hq"]
        live = sum(1 for c in self.game.crystals if not c.dead and any(math.hypot(h.x - c.x, h.y - c.y) < 700 for h in hqs))
        return (t > EXPAND_AT * OPENINGS[self.opening]["expand"] or left < 5000
                or left < 0.45 * self.home_crystal_start or len(workers) > 2.5 * live + 2)

    def _expansions(self, hq, bases):
        return [b for b in bases if b.kind == "hq" and b.built and not b.dead and b is not hq]

    def _unguarded_expansion(self, hq, bases):
        """The first expansion with no turret of its own."""
        for e in self._expansions(hq, bases):
            if not any(b.kind == "turret" and math.hypot(b.x - e.x, b.y - e.y) < 450 for b in bases):
                return e
        return None

    def _garrison(self, hq, bases, home):
        """Every expansion keeps a few troops of its own, so a raid on it meets more than Engineers."""
        exps = self._expansions(hq, bases)
        if not exps:
            self.guards = []
            return
        need = GARRISON[self.diff.index]
        for e in exps:
            posted = [u for u in self.guards if math.hypot(u.x - e.x, u.y - e.y) < 500 or u.order[0] == "amove"]
            missing = need - len(posted)
            if missing <= 0:
                continue
            idle = [u for u in home if u.order[0] == "idle"]
            if len(idle) < missing + 2:              # never strip the main base bare
                continue
            party = sorted(idle, key=lambda u: math.hypot(u.x - e.x, u.y - e.y))[:missing]
            for i, u in enumerate(party):
                a = len(posted) + i
                u.command(("amove", e.x + math.cos(a * 2.1) * 130, e.y + math.sin(a * 2.1) * 130))
                self.guards.append(u)
        # A guard whose post has fallen goes back to the home army.
        self.guards = [u for u in self.guards if any(math.hypot(u.x - e.x, u.y - e.y) < 900 for e in exps) or u.order[0] == "amove"]

    def _scout_route(self, hq):
        """The nearest enemy Command Center's ground, then the two fields nearest the way there."""
        g = self.game
        starts = [tuple(g.map["starts"][p.start][:2]) for p in g.players.values() if p.alive and g.enemies(p.slot, self.team)]
        if not starts:
            return []
        ex, ey = min(starts, key=lambda s: math.hypot(s[0] - hq.x, s[1] - hq.y))
        mx, my = (hq.x + ex) / 2, (hq.y + ey) / 2
        fields = sorted((tuple(e[:2]) for e in g.map.get("expansions", [])), key=lambda e: math.hypot(e[0] - mx, e[1] - my))[:2]
        return [(ex, ey)] + fields

    def _scout(self, hq, home):
        """A single trooper walks the enemy's door and the fields between, so `seen` has something to see."""
        g = self.game
        if self.scout is not None and self.scout.dead:
            self.scout = None
        if self.scout is not None:
            if self.scout.order[0] == "idle":
                if self.scout_route:
                    x, y = self.scout_route.pop(0)
                    self.scout.command(("move", x, y))
                else:
                    self.scout = None
                    self.next_scout = g.elapsed + SCOUT_EVERY
            return
        if g.elapsed < self.next_scout:
            return
        idle = [u for u in home if u.order[0] == "idle" and u.kind == "marine"]
        route = self._scout_route(hq)
        if not idle or not route:
            return
        self.scout = min(idle, key=lambda u: math.hypot(u.x - route[0][0], u.y - route[0][1]))
        self.scout_route = route[1:] + [(hq.x, hq.y)]
        self.scout.command(("move", *route[0]))

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
        elif count("hq") < (4 if defs.WORLD_W >= GIANT_W else 3) and self._should_expand(t, bases, workers):
            e = self._expansion_site(hq.x, hq.y)
            if e:
                want, site = "hq", e
        if want is None and self.air_alarm is not None and g.elapsed - self.air_alarm[2] < 90 \
                and self._pending("turret", workers) == 0 and g.has_built("barracks", self.team):
            # A Gunship over the base: a turret goes up where it was, if nothing there can shoot up already.
            ax, ay, _ = self.air_alarm
            if not any(b.kind == "turret" and math.hypot(b.x - ax, b.y - ay) < 450 for b in bases):
                spot = self._find_spot("turret", ax, ay)
                if spot:
                    want, site = "turret", spot
        if want is None and t > 120:
            # An expansion without a turret of its own gets one before the plan goes on.
            e = self._unguarded_expansion(hq, bases)
            if e is not None and self._pending("turret", workers) == 0:
                spot = self._find_spot("turret", e.x, e.y)
                if spot:
                    want, site = "turret", spot
        if want is None:
            for k, n in self._plan(t):
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
        if g.alloy[self.team] < ALLOY_BUILD.get(want, 0):
            return 0
        candidates = [w for w in workers if w.order[0] != "build" and w not in self.gold_miners and w is not self.salvager]
        if not candidates:
            return 0
        builder = min(candidates, key=lambda w: math.hypot(w.x - hq.x, w.y - hq.y))
        spot = site or self._find_spot(want, hq.x, hq.y)
        if spot is None:
            return 0
        g.resources[self.team] -= cost
        g.alloy[self.team] -= ALLOY_BUILD.get(want, 0)
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
        wants += [(b, "entrench") for b in bases if b.kind == "barracks"][:1]
        wants += [(b, "stabilise") for b in bases if b.kind == "factory"][:1]
        wants += [(hq, "armor"), (hq, "hp")]
        wants += [(b, "guns") for b in bases if b.kind == "turret"]
        wants += [(b, "defense") for b in bases if b.kind == "hq"]
        wants += [(b, "supply") for b in bases if b.kind == "depot"]
        for b, k in wants:
            if b.can_upgrade(k) and g.resources[self.team] >= upgrade_cost(k, b.kind) + 300 and g.alloy[self.team] >= ALLOY_UPGRADE.get(k, 0):
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
            a = to_center + g.rng.uniform(-spread, spread)
            d = g.rng.uniform(190, 260 + attempt * 8) + (90 if guns else 0)
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
        Rangers, Snipers answer tanks, tanks and Rangers together answer Snipers, Gunships answer massed
        tanks, and Rangers and Snipers answer Gunships (which tanks cannot touch)."""
        w = {"marine": 3.0, "sniper": 1.0, "tank": 2.0, "gunship": 0.6}
        total = sum(self.seen.values())
        if total >= 3:
            share = {k: self.seen.get(k, 0.0) / total for k in w}
            w["sniper"] += 3.0 * share["tank"] + 1.0 * share["gunship"]
            w["tank"] += 2.0 * share["marine"] + 1.0 * share["sniper"]
            w["marine"] += 1.5 * share["sniper"] + 2.0 * share["gunship"]
            w["gunship"] += 2.5 * share["tank"]
        s = sum(w.values())
        return {k: v / s for k, v in w.items()}

    def _wanted(self, army):
        """The unit kind furthest below its target share; None when the army already matches."""
        counts = {"marine": 0, "sniper": 0, "tank": 0, "gunship": 0}
        for u in army:
            if u.kind in counts:
                counts[u.kind] += 1
        n = max(1, sum(counts.values()))
        comp = self._composition()
        deficit = {k: comp[k] * (n + 1) - counts[k] for k in counts}
        return max(deficit, key=deficit.get)

    def _fortify(self, hq, bases, workers):
        """Barricades across the approach: a turtle walls up early, anyone once the base has been hit. Two
        lines of blocks either side of a gap, so its own army still marches out — through a funnel."""
        g = self.game
        t = g.elapsed / self.diff.pace
        if any(b.hp < b.max_hp and b.built for b in bases):
            self.hit_at = g.elapsed
        early = self.opening == "turtle" and t > FORTIFY_AT
        if not (early or g.elapsed - self.hit_at < 60):
            return
        walls = sum(1 for b in bases if b.kind == "wall") + self._pending("wall", workers)
        if walls >= FORTIFY_BLOCKS or g.resources[self.team] < BUILDINGS["wall"].cost * 2 + 150:
            return
        free = [w for w in workers if w.order[0] in ("idle", "gather", "return")]
        if not free:
            return
        dx, dy = defs.WORLD_W / 2 - hq.x, defs.WORLD_H / 2 - hq.y
        d = math.hypot(dx, dy) or 1.0
        ux, uy = dx / d, dy / d
        cx, cy = hq.x + ux * FORTIFY_DIST, hq.y + uy * FORTIFY_DIST
        span = BUILDINGS["wall"].half * 2
        builder = min(free, key=lambda w: math.hypot(w.x - cx, w.y - cy))
        placed = 0
        for k in FORTIFY_OFFSETS:
            p = g.snapped(cx - uy * k * span, cy + ux * k * span)
            if not g.can_place("wall", p[0], p[1], margin=4):
                continue
            if any(b.kind == "wall" and abs(b.x - p[0]) < span / 2 and abs(b.y - p[1]) < span / 2 for b in bases):
                continue
            if g.resources[self.team] < BUILDINGS["wall"].cost + 150:
                break
            g.resources[self.team] -= BUILDINGS["wall"].cost
            builder.order_build("wall", p[0], p[1], queue=placed > 0)
            placed += 1
        # Mines in the funnel: whatever comes through the gap pays for it.
        mines = sum(1 for b in bases if b.kind == "mine") + self._pending("mine", workers)
        if g.has_built("barracks", self.team):
            for k in (-0.5, 0.5, 0.0):
                if mines >= 3 or g.resources[self.team] < BUILDINGS["mine"].cost + 150:
                    break
                p = g.snapped(cx - uy * k * span + ux * 40, cy + ux * k * span + uy * 40)
                if not g.can_place("mine", p[0], p[1], margin=2):
                    continue
                if any(b.kind == "mine" and abs(b.x - p[0]) < 30 and abs(b.y - p[1]) < 30 for b in bases):
                    continue
                g.resources[self.team] -= BUILDINGS["mine"].cost
                builder.order_build("mine", p[0], p[1], queue=placed > 0)
                placed += 1
                mines += 1
        return placed

    def _produce(self, hq, bases, workers, reserve):
        g = self.game
        money = lambda: g.resources[self.team] - reserve
        queued_workers = sum(1 for k in hq.queue if k == "worker")
        target = self.diff.worker_target + OPENINGS[self.opening]["workers"]
        if hq.kind == "hq" and hq.built and len(workers) + queued_workers < target and len(hq.queue) < 2:
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
            elif b.kind == "factory":
                alloy = g.alloy[self.team]
                if want == "gunship" and money() >= 200 and alloy >= ALLOY_COST["gunship"] and g.has_built("radar", self.team):
                    g.train("gunship", [b], self.team)
                elif money() >= 150 and alloy >= ALLOY_COST["tank"] and (want != "gunship" or not g.has_built("radar", self.team) or money() >= 350):
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
            # The threat is gone: if it was here a moment ago and the home army is worth sending, go after
            # whatever it came from before it can regroup.
            if self.threat_seen_at > -1e8 and g.elapsed - self.threat_seen_at < 20 and len(home) >= max(3, self.wave_size // 2) \
                    and g.elapsed - self.last_counter > 60 and self.diff.index >= 1:
                self.counter_pending = True
                self.threat_seen_at = -1e9
            return
        self.threat_seen_at = g.elapsed
        flying = threat.stats.flies
        if flying:
            self.air_alarm = (threat.x, threat.y, g.elapsed)
        # Against an aircraft only what can shoot up goes: tanks chasing a Gunship is a wasted army.
        for u in home:
            if u.order[0] in ("idle", "move") and (not flying or u.stats.hits_air):
                u.command(("amove", *self._standoff(u, threat.x, threat.y)))
        # A garrison answers what comes at its own post.
        for u in self.guards:
            if u.order[0] == "idle" and math.hypot(u.x - threat.x, u.y - threat.y) < 700 and (not flying or u.stats.hits_air):
                u.command(("amove", *self._standoff(u, threat.x, threat.y)))

    def _salvage(self, hq, workers, home):
        """The derelict Siege Tank is a free tank for whoever gets an Engineer to it first: one goes early,
        with a pair of troops to keep the ring clear."""
        g = self.game
        if not g.derelicts:
            self.salvager = None
            return
        if g.elapsed < 20 or not workers:
            return
        d = g.derelicts[0]
        if self.salvager is not None and (self.salvager.dead or self.salvager not in workers):
            self.salvager = None
        if self.salvager is None:
            self.salvager = min(workers, key=lambda w: math.hypot(w.x - d.x, w.y - d.y))
            self.salvager.command(("move", d.x + 30, d.y))
            for u in [u for u in home if u.order[0] == "idle" and u.kind != "worker"][:2]:
                u.command(("amove", d.x - 40, d.y + 30))
        elif self.salvager.order[0] != "move" and math.hypot(self.salvager.x - d.x, self.salvager.y - d.y) > DERELICT_RADIUS - 20:
            self.salvager.command(("move", d.x + 30, d.y))

    def _abilities(self, mine):
        """Rangers lob grenades into a knot of enemies, Snipers mark the toughest thing in reach, and a hurt
        Siege Tank under fire pops smoke."""
        g = self.game
        for u in mine:
            spec = ABILITIES.get(u.kind)
            if spec is None or u.ability_cd > 0:
                continue
            aid, _name, reach, _cd, needs = spec
            foes = [e for e in g.units if g.enemies(e.team, u.team) and not e.dead
                    and math.hypot(e.x - u.x, e.y - u.y) <= max(reach, 300.0)]
            if not foes:
                continue
            if aid == "grenade":
                best, count = None, 1
                for f in foes:
                    if math.hypot(f.x - u.x, f.y - u.y) > reach:
                        continue
                    n = sum(1 for o in foes if math.hypot(o.x - f.x, o.y - f.y) <= GRENADE_SPLASH * 0.8)
                    if n > count:
                        best, count = f, n
                if best is not None:
                    g.use_ability(self.team, [u], best.x, best.y)
            elif aid == "mark":
                fresh = [f for f in foes if f.marked_until <= g.elapsed and math.hypot(f.x - u.x, f.y - u.y) <= reach]
                if fresh:
                    t = max(fresh, key=lambda f: f.hp)
                    g.use_ability(self.team, [u], t.x, t.y, t.id)
            elif u.hp < u.max_hp * 0.6:
                g.use_ability(self.team, [u], u.x, u.y)

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
            self.route_open = True        # nothing to rebuild: the way is walled off, and walls are shot down on arrival
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
        counter = self.counter_pending and len(home) >= 3
        if (g.elapsed >= self.next_wave and (len(home) >= self.wave_size or overdue)) or counter:
            target = g.primary_target(self.team, hq.x, hq.y)
            goal = self._objective(target)
            if goal:
                # A wave is the planned size and a half at most: a full bank makes a big army, not one
                # monstrous first wave, and what stays behind keeps the base.
                party = home[:max(3, int(self.wave_size * 1.5))]
                for u in party:
                    u.command(("amove", *self._standoff(u, *goal)))
                self.attackers += party
                self.launched = len(self.attackers)
                if counter:
                    self.last_counter = g.elapsed
                    self.counters += 1
                else:
                    self.wave_size = min(40, self.wave_size + 2 + self.diff.index * 2)
                self.next_wave = g.elapsed + 50
                g.wave_launched(self.team, target)
        self.counter_pending = False
        self._retreat(hq)
        for u in self.attackers:
            if u.order[0] == "idle":
                goal = self._objective(g.primary_target(self.team, u.x, u.y))
                if goal:
                    u.command(("amove", *self._standoff(u, *goal)))
        self._raid(hq, home)
        self._siege(home)
        self._towers(hq, home)
        self._answer_pings(home)

    def _retreat(self, hq):
        """A wave that has lost most of itself with the enemy still on it pulls back to the Command Center
        rather than dying piecemeal, and the next wave waits a little longer to be worth sending."""
        g = self.game
        standing = sum(1 for b in g.buildings if not b.dead and g.enemies(b.team, self.team))
        if self.enemy_buildings is not None and standing < self.enemy_buildings:
            self.retreats_row = 0                                   # progress: the enemy is losing ground
        self.enemy_buildings = standing
        if self.launched < 4 or not self.attackers or len(self.attackers) >= self.launched * 0.4:
            return
        if self.retreats_row >= 3:
            return                                                  # three pull-backs without a dent: this one fights it out
        near = any(g.enemies(e.team, self.team) and not e.dead
                   and any(math.hypot(e.x - u.x, e.y - u.y) < 400 for u in self.attackers) for e in g.units)
        if not near:
            return
        for u in self.attackers:
            u.command(("move", hq.x, hq.y))
        self.attackers = []
        self.launched = 0
        self.next_wave = max(self.next_wave, g.elapsed + 40)
        self.retreats += 1
        self.retreats_row += 1

    def _objective(self, target):
        """Where a wave goes: in King of the Hill the gold ring, unless this side already holds the lead there;
        otherwise the enemy's nearest building."""
        g = self.game
        if g.mode == "koth":
            mine, best = g.hold_standing(self.team)
            if mine <= best or mine <= 0.0:
                return g.ring
        return (target.x, target.y) if target is not None else None

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
        self.launched += len(party)
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
            u.command(("amove", t.x + g.rng.uniform(-40, 40), t.y + g.rng.uniform(-40, 40)))

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
