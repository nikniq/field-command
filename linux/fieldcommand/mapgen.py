"""Map catalogue and generation. A map is plain JSON-serialisable data so the server can send it to any client.

    {"id", "name", "players", "w", "h", "starts": [[x, y, mineral_angle]], "expansions": [[x, y, count, amount]],
     "crystals": [[x, y, amount, variant]], "clearings": [[x, y, r]], "roads": [[[x, y], ...]],
     "walls": [[x0, y0, x1, y1, "water" | "cliff"]], "bridges": [[x0, y0, x1, y1]],
     "trees": [[x, y, radius, variant, angle_deg, scale]]}

Walls are impassable terrain; bridges are walkable decoration drawn over water.
The Mac edition's ServerWorld.swift carries an identical catalogue (same ids, layouts and player counts).
"""
import math
import random

from .defs import DEFAULT_WORLD, GOLD_AMOUNT

CATALOG = [
    {"id": "twin_ridges", "name": "Twin Ridges", "players": 2, "desc": "Open ground with bases in opposite corners."},
    {"id": "river_crossing", "name": "River Crossing", "players": 2, "desc": "A river splits the map; fight over three bridges."},
    {"id": "highland_pass", "name": "Highland Pass", "players": 2, "desc": "Cliff ridges funnel armies through narrow passes."},
    {"id": "four_corners", "name": "Four Corners", "players": 4, "desc": "A base in every corner and a rich centre."},
    {"id": "crossroads", "name": "Crossroads", "players": 4, "desc": "Bases on each edge; lakes guard the corners."},
    {"id": "grand_arena", "name": "Grand Arena", "players": 12, "desc": "Mega map: twelve bases ringing an open plain."},
    {"id": "riverlands", "name": "Riverlands", "players": 12, "desc": "Mega map: four rivers and a walled heartland."},
    {"id": "continental_divide", "name": "Continental Divide", "players": 12,
     "desc": "Giant map: a cliff spine splits north from south; five passes."},
    {"id": "archipelago", "name": "Archipelago", "players": 12,
     "desc": "Giant map: a bridged island in an inland sea, lakes along the rim."},
    {"id": "six_rivers", "name": "Six Rivers", "players": 12,
     "desc": "Giant map: six rivers run from the middle to the edges; two bases a wedge."},
    {"id": "crater_fields", "name": "Crater Fields", "players": 12,
     "desc": "Giant map: every base sits inside a broken crater on an open plain."},
    {"id": "long_march", "name": "The Long March", "players": 12,
     "desc": "Giant map: two rows of six bases face each other across a wide river."},
]
BY_ID = {m["id"]: m for m in CATALOG}

# Each map's world size. The mega maps are half again as wide and tall to hold twelve bases; the giant maps
# are half again as wide and tall as those (9000 x 6300, five times the standard area).
MEGA_WORLD = (6000.0, 4200.0)
GIANT_WORLD = (9000.0, 6300.0)
GIANT_IDS = ("continental_divide", "archipelago", "six_rivers", "crater_fields", "long_march")
SIZES = {m["id"]: (GIANT_WORLD if m["id"] in GIANT_IDS else MEGA_WORLD if m["players"] > 4 else DEFAULT_WORLD)
         for m in CATALOG}
_W, _H = DEFAULT_WORLD  # size of the map currently being generated (see _begin)


def _begin(map_id):
    """Switches the generator helpers to this map's world size."""
    global _W, _H
    _W, _H = SIZES.get(map_id, DEFAULT_WORLD)


def _rot(p):
    """180° rotation about the map centre (keeps layouts fair)."""
    return (_W - p[0], _H - p[1])


def _rot_rect(r):
    return (_W - r[2], _H - r[3], _W - r[0], _H - r[1])


def _river(xc, width, gaps, seed, amp=60.0, seg=140.0):
    """A meandering north-south river built from short offset segments, leaving bridge gaps."""
    rnd = random.Random(seed)
    phase = rnd.uniform(0, math.tau)
    rects, y = [], 0.0
    while y < _H:
        y1 = min(_H, y + seg)
        for g0, g1 in gaps:  # clip against bridge gaps
            if y < g1 and y1 > g0:
                y1 = g0 if y < g0 else y1
                if y >= g0:
                    y = g1
                    y1 = min(_H, y + seg)
        if y1 > y:
            x = xc + math.sin((y + y1) / 2 / 420 + phase) * amp
            rects.append((x - width / 2, y, x + width / 2, y1, "water"))
        y = y1
    return rects


def _ridge(x0, x1, yc, thick, seed, chunk=170.0):
    """A cliff ridge from x0 to x1 made of chunks of varying thickness."""
    rnd = random.Random(seed)
    rects, x = [], x0
    while x < x1 - 1:
        nx = min(x1, x + chunk * rnd.uniform(0.7, 1.2))
        t = thick * rnd.uniform(0.75, 1.3)
        c = yc + rnd.uniform(-18, 18)
        rects.append((x, c - t / 2, nx, c + t / 2, "cliff"))
        x = nx
    return rects


def _lake(cx, cy, w, h, seed):
    """An irregular lake: a main basin plus overlapping bays."""
    rnd = random.Random(seed)
    rects = [(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, "water")]
    for _ in range(4):
        bw, bh = w * rnd.uniform(0.35, 0.6), h * rnd.uniform(0.35, 0.6)
        side = rnd.randrange(4)
        ox = rnd.uniform(-w / 2 + bw / 2, w / 2 - bw / 2)
        oy = rnd.uniform(-h / 2 + bh / 2, h / 2 - bh / 2)
        push = rnd.uniform(0.12, 0.22)
        if side == 0:
            oy = -h / 2 - bh * push
        elif side == 1:
            oy = h / 2 + bh * push
        elif side == 2:
            ox = -w / 2 - bw * push
        else:
            ox = w / 2 + bw * push
        rects.append((cx + ox - bw / 2, cy + oy - bh / 2, cx + ox + bw / 2, cy + oy + bh / 2, "water"))
    return rects


def _rot_wall(r):
    x0, y0, x1, y1 = _rot_rect(r[:4])
    return (x0, y0, x1, y1, r[4])


def _mirror_x(r):
    return (_W - r[2], r[1], _W - r[0], r[3], r[4])


def _mirror_y(r):
    return (r[0], _H - r[3], r[2], _H - r[1], r[4])


def _stream(p0, p1, width, gaps, seed, amp=70.0, seg=150.0):
    """A meandering watercourse from p0 to p1. `gaps` are (start, end) fractions of the length left dry for
    bridges. Returns (wall rects, bridge rects)."""
    rnd = random.Random(seed)
    phase = rnd.uniform(0, math.tau)
    length = math.hypot(p1[0] - p0[0], p1[1] - p0[1])
    ux, uy = (p1[0] - p0[0]) / length, (p1[1] - p0[1]) / length
    nx, ny = -uy, ux
    half = width / 2
    rects, bridges = [], []
    steps = max(1, int(round(length / seg)))
    for i in range(steps):
        t0, t1 = i / steps, (i + 1) / steps
        if any(t1 > g0 and t0 < g1 for g0, g1 in gaps):
            continue
        out = []
        for t in (t0, t1):
            d = t * length
            off = math.sin(d / 430 + phase) * amp
            out.append((p0[0] + ux * d + nx * off, p0[1] + uy * d + ny * off))
        (ax, ay), (bx, by) = out
        x0, x1 = sorted((ax, bx))
        y0, y1 = sorted((ay, by))
        rects.append((x0 - half, y0 - half, x1 + half, y1 + half, "water"))
    for g0, g1 in gaps:
        mid = [(p0[0] + ux * t * length + nx * math.sin(t * length / 430 + phase) * amp,
                p0[1] + uy * t * length + ny * math.sin(t * length / 430 + phase) * amp) for t in (g0, g1)]
        cx, cy = (mid[0][0] + mid[1][0]) / 2, (mid[0][1] + mid[1][1]) / 2
        span = (g1 - g0) * length / 2 + 30
        deck = 110.0  # half the walkway's width across the stream
        bridges.append((cx - abs(ux) * span - abs(nx) * deck, cy - abs(uy) * span - abs(ny) * deck,
                        cx + abs(ux) * span + abs(nx) * deck, cy + abs(uy) * span + abs(ny) * deck))
    return rects, bridges


def _arc_ridge(cx, cy, radius, a0, a1, thick, seed, chunk=70.0):
    """Cliff blocks along an arc. They overlap so the rendered ridge reads as one curved wall."""
    rnd = random.Random(seed)
    rects = []
    n = max(1, int((a1 - a0) * radius / chunk))
    for i in range(n + 1):
        a = a0 + i / n * (a1 - a0)
        r = radius + rnd.uniform(-18, 18)
        t = thick * rnd.uniform(0.9, 1.15)
        x, y = cx + math.cos(a) * r, cy + math.sin(a) * r
        rects.append((x - t / 2, y - t / 2, x + t / 2, y + t / 2, "cliff"))
    return rects


def _dist_to_roads(roads, x, y):
    best = 1e9
    for road in roads:
        for (ax, ay), (bx, by) in zip(road, road[1:]):
            abx, aby = bx - ax, by - ay
            t = max(0.0, min(1.0, ((x - ax) * abx + (y - ay) * aby) / max(1e-3, abx * abx + aby * aby)))
            best = min(best, math.hypot(x - (ax + abx * t), y - (ay + aby * t)))
    return best


def _rect_dist(r, x, y):
    dx = max(r[0] - x, 0.0, x - r[2])
    dy = max(r[1] - y, 0.0, y - r[3])
    return math.hypot(dx, dy)


def _finish(map_id, starts, expansions, roads, seed, walls=(), bridges=()):
    """Adds mineral lines, clearings and forests around the given layout."""
    w, h = _W, _H
    crystals, clearings = [], []
    variant = 0
    for (x, y, base) in starts:
        clearings.append([x, y, 470])
        for i in range(8):
            a = base + i / 7 * (math.pi / 2)
            d = 255 if i % 2 == 0 else 285
            crystals.append([round(x + math.cos(a) * d, 1), round(y + math.sin(a) * d, 1), 1500, variant % 3])
            variant += 1
    for (x, y, n, amount) in expansions:
        clearings.append([x, y, 300])
        for i in range(n):
            a = i / n * 2 * math.pi + 0.3
            # A gold deposit is an expansion worth GOLD_AMOUNT a node; its nodes are drawn gold (variant 3).
            crystals.append([round(x + math.cos(a) * 70, 1), round(y + math.sin(a) * 70, 1), amount,
                             3 if amount >= GOLD_AMOUNT else variant % 3])
            variant += 1

    rnd = random.Random(seed)
    trees = []
    blockers = [tuple(wl[:4]) for wl in walls] + [tuple(b) for b in bridges]

    def allowed(x, y):
        if x < 20 or y < 20 or x > w - 20 or y > h - 20:
            return False
        if any(math.hypot(x - cx, y - cy) < r + 40 for cx, cy, r in clearings):
            return False
        if _dist_to_roads(roads, x, y) < 150:
            return False
        if any(_rect_dist(r, x, y) < 60 for r in blockers):
            return False
        return not any(math.hypot(x - t[0], y - t[1]) < 46 for t in trees)

    sites = []
    for _ in range(34):
        cx, cy = rnd.uniform(150, w - 150), rnd.uniform(150, h - 150)
        for _ in range(rnd.randint(5, 12)):
            a = rnd.uniform(0, 2 * math.pi)
            d = rnd.uniform(0, 120)
            sites.append((cx + math.cos(a) * d, cy + math.sin(a) * d))
    e = 30.0
    while e < max(w, h):
        sites += [(e, rnd.uniform(25, 110)), (e, h - rnd.uniform(25, 110)),
                  (rnd.uniform(25, 110), e), (w - rnd.uniform(25, 110), e)]
        e += rnd.uniform(45, 75)
    for x, y in sites:
        if allowed(x, y):
            trees.append([round(x, 1), round(y, 1), 20.0, rnd.randint(0, 2), round(rnd.uniform(0, 360), 1),
                          round(rnd.uniform(0.8, 1.15), 3)])
    meta = BY_ID[map_id]
    return {"id": map_id, "name": meta["name"], "players": meta["players"], "w": w, "h": h, "seed": seed,
            "starts": [[x, y, round(b, 5)] for x, y, b in starts],
            "expansions": [list(e) for e in expansions], "crystals": crystals, "clearings": clearings,
            "roads": [[list(p) for p in r] for r in roads], "trees": trees,
            "walls": [[*[round(v, 1) for v in wl[:4]], wl[4]] for wl in walls],
            "bridges": [[round(v, 1) for v in b] for b in bridges]}


def twin_ridges():
    _begin("twin_ridges")
    ps, es = (560.0, 560.0), (_W - 560.0, _H - 560.0)
    starts = [(ps[0], ps[1], math.pi), (es[0], es[1], 0.0)]
    expansions = [(2000, 480, 6, 1000), (2000, 2320, 6, 1000), (520, 2280, 6, 1000), (3480, 520, 6, 1000), (2000, 1400, 4, GOLD_AMOUNT)]
    roads = [
        [ps, (1150, 820), (1600, 1250), (2000, 1400), (2400, 1550), (2850, 1980), es],
        [(1600, 1250), (1850, 800), (2000, 600)],
        [(2400, 1550), (2150, 2000), (2000, 2200)],
        [ps, (700, 1400), (560, 2150)],
        [es, (3300, 1400), (3440, 650)],
    ]
    return _finish("twin_ridges", starts, expansions, roads, 42)


def river_crossing():
    """A north-south river with three bridges; bases on the west and east edges."""
    _begin("river_crossing")
    lb, rb = (620.0, 1400.0), _rot((620.0, 1400.0))
    starts = [(lb[0], lb[1], 0.75 * math.pi), (rb[0], rb[1], 1.75 * math.pi)]
    gaps = [(560.0, 760.0), (1300.0, 1500.0), (2040.0, 2240.0)]
    walls = _river(2000.0, 230.0, gaps, 5)
    bridges = []
    for g0, g1 in gaps:
        xs = [w_[0] for w_ in walls if abs(w_[1] - g1) < 1 or abs(w_[3] - g0) < 1]
        xe = [w_[2] for w_ in walls if abs(w_[1] - g1) < 1 or abs(w_[3] - g0) < 1]
        bridges.append((min(xs) - 24, g0, max(xe) + 24, g1))
    expansions = [(560, 380, 6, 1000), (560, 2420, 6, 1000), (3440, 380, 6, 1000), (3440, 2420, 6, 1000),
                  (1450, 1400, 4, GOLD_AMOUNT), (2550, 1400, 4, GOLD_AMOUNT)]
    roads = [[lb, (1150, 1400), (2000, 1400), (2850, 1400), rb],
             [lb, (1100, 800), (2000, 660), (2900, 520), (3440, 520)],
             [rb, (2900, 2000), (2000, 2140), (1100, 2280), (560, 2280)],
             [lb, (560, 520)], [rb, (3440, 2280)]]
    return _finish("river_crossing", starts, expansions, roads, 11, walls, bridges)


def highland_pass():
    """Two cliff ridges cross the map; each has two passes."""
    _begin("highland_pass")
    ps, es = (560.0, 560.0), _rot((560.0, 560.0))
    starts = [(ps[0], ps[1], math.pi), (es[0], es[1], 0.0)]
    ridge_a = _ridge(0.0, 640.0, 1060.0, 120.0, 3) + _ridge(900.0, 2200.0, 1060.0, 120.0, 4) + _ridge(2480.0, _W, 1060.0, 120.0, 5)
    walls = ridge_a + [_rot_wall(r) for r in ridge_a]
    expansions = [(420, 1400, 6, 1000), (3580, 1400, 6, 1000), (2000, 1400, 4, GOLD_AMOUNT), (2000, 480, 6, 1000), (2000, 2320, 6, 1000)]
    roads = [[ps, (770, 820), (770, 1300), (1660, 1500), (1660, 1950), (2600, 2200), es],
             [ps, (1500, 700), (2340, 860), (2340, 1300), (3230, 1500), (3230, 1980), es],
             [(770, 1300), (420, 1400)], [(3230, 1500), (3580, 1400)], [(1660, 1500), (2000, 1400), (2340, 1300)]]
    return _finish("highland_pass", starts, expansions, roads, 23, walls)


def four_corners():
    _begin("four_corners")
    bl, br = (560.0, 560.0), (_W - 560.0, 560.0)
    tl, tr = (560.0, _H - 560.0), (_W - 560.0, _H - 560.0)
    starts = [(bl[0], bl[1], math.pi), (tr[0], tr[1], 0.0), (br[0], br[1], 1.5 * math.pi), (tl[0], tl[1], 0.5 * math.pi)]
    c = (_W / 2, _H / 2)
    expansions = [(2000, 430, 6, 1000), (2000, 2370, 6, 1000), (430, 1400, 6, 1000), (3570, 1400, 6, 1000), (c[0], c[1], 4, GOLD_AMOUNT)]
    roads = [
        [bl, (1300, 950), c], [br, (2700, 950), c], [tl, (1300, 1850), c], [tr, (2700, 1850), c],
        [bl, (1300, 520), (2000, 560), (2700, 520), br],
        [tl, (1300, 2280), (2000, 2240), (2700, 2280), tr],
        [bl, (560, 1400), tl], [br, (3440, 1400), tr],
    ]
    return _finish("four_corners", starts, expansions, roads, 7)


def crossroads():
    """Bases in the middle of each edge; lakes fill the quadrants between them."""
    _begin("crossroads")
    left, right = (520.0, 1400.0), (_W - 520.0, 1400.0)
    bottom, top = (2000.0, 520.0), (2000.0, _H - 520.0)
    # Opposite bases first so 2-player games start across the map.
    starts = [(left[0], left[1], 0.75 * math.pi), (right[0], right[1], 1.75 * math.pi),
              (bottom[0], bottom[1], 1.25 * math.pi), (top[0], top[1], 0.25 * math.pi)]
    lake = _lake(1120.0, 860.0, 560.0, 340.0, 9)
    walls = lake + [_mirror_x(r) for r in lake] + [_mirror_y(r) for r in lake] + [_rot_wall(r) for r in lake]
    c = (_W / 2, _H / 2)
    expansions = [(380, 380, 6, 1000), (3620, 380, 6, 1000), (380, 2420, 6, 1000), (3620, 2420, 6, 1000), (c[0], c[1], 4, GOLD_AMOUNT)]
    roads = [[left, c, right], [bottom, c, top],
             [left, (560, 700), (380, 380)], [bottom, (1400, 420), (380, 380)],
             [right, (3440, 2100), (3620, 2420)], [top, (2600, 2380), (3620, 2420)],
             [left, (560, 2100), (380, 2420)], [top, (1400, 2380), (380, 2420)],
             [right, (3440, 700), (3620, 380)], [bottom, (2600, 420), (3620, 380)]]
    return _finish("crossroads", starts, expansions, roads, 31, walls)


def grand_arena():
    """Twelve bases ringing an open plain: the classic mega free-for-all."""
    _begin("grand_arena")
    cx, cy = _W / 2, _H / 2
    rx, ry = _W * 0.385, _H * 0.375
    starts, expansions, roads, ring = [], [], [], []
    for i in range(12):
        a = math.radians(15 + i * 30)
        x, y = cx + math.cos(a) * rx, cy + math.sin(a) * ry
        starts.append((round(x, 1), round(y, 1), a - math.pi / 4))
        ring.append((x, y))
        # A close expansion just outside each base, and a shared one on the way to the middle.
        ex, ey = cx + math.cos(a) * rx * 1.18, cy + math.sin(a) * ry * 1.2
        expansions.append((round(min(_W - 200, max(200, ex)), 1), round(min(_H - 200, max(200, ey)), 1), 6, 1000))
        if i % 2 == 0:
            expansions.append((round(cx + math.cos(a + 0.26) * rx * 0.52, 1), round(cy + math.sin(a + 0.26) * ry * 0.52, 1), 5, 1400))
    expansions.append((cx, cy, 8, GOLD_AMOUNT))
    roads.append([*ring, ring[0]])  # ring road joining every base
    for i in range(0, 12, 2):
        roads.append([ring[i], (cx + (ring[i][0] - cx) * 0.4, cy + (ring[i][1] - cy) * 0.4), (cx, cy)])
    # A few ponds between the ring and the middle so the plain is not featureless.
    walls = []
    for i in range(4):
        a = math.radians(45 + i * 90)
        walls += _lake(cx + math.cos(a) * rx * 0.45, cy + math.sin(a) * ry * 0.45, 520, 340, 40 + i)
    return _finish("grand_arena", starts, expansions, roads, 61, walls)


def riverlands():
    """Four rivers split the map into quarters around a cliff-walled heartland."""
    _begin("riverlands")
    cx, cy = _W / 2, _H / 2
    walls, bridges = [], []
    edges = [(_W, cy), (cx, _H), (0.0, cy), (cx, 0.0)]  # each river runs from one map edge toward the middle
    for i, edge in enumerate(edges):
        a = math.radians(i * 90)
        inner = (cx + math.cos(a) * 1320, cy + math.sin(a) * 1320)
        r, b = _stream(edge, inner, 220, [(0.30, 0.40), (0.66, 0.76)], 70 + i)
        walls += r
        bridges += b
    for i in range(4):  # ring wall around the rich middle, with a gap on each diagonal
        a0 = math.radians(i * 90 + 15)
        walls += _arc_ridge(cx, cy, 1010, a0, a0 + math.radians(60), 165, 80 + i)
    starts, expansions, roads = [], [], []
    for q in range(4):
        for k, off in enumerate((22, 45, 68)):
            a = math.radians(q * 90 + off)
            x = cx + math.cos(a) * _W * 0.40
            y = cy + math.sin(a) * _H * 0.40
            starts.append((round(x, 1), round(y, 1), a - math.pi / 4))
            expansions.append((round(cx + math.cos(a) * _W * 0.27, 1), round(cy + math.sin(a) * _H * 0.27, 1), 5, 1200))
            roads.append([(x, y), (cx + math.cos(a) * 1500, cy + math.sin(a) * 1050), (cx + math.cos(a) * 760, cy + math.sin(a) * 760)])
        a = math.radians(q * 90 + 45)
        expansions.append((round(cx + math.cos(a) * 700, 1), round(cy + math.sin(a) * 700, 1), 6, 1600))
    expansions.append((cx, cy, 8, GOLD_AMOUNT))
    ring = [(cx + math.cos(math.radians(k * 30)) * _W * 0.40, cy + math.sin(math.radians(k * 30)) * _H * 0.40) for k in range(12)]
    roads.append([*ring, ring[0]])
    return _finish("riverlands", starts, expansions, roads, 73, walls, bridges)


# ---------------------------------------------------------------- giant maps (9000 x 6300, twelve players)

def continental_divide():
    """A cliff spine runs the width of the map with five passes; six bases north of it, six south."""
    _begin("continental_divide")
    cx, cy = _W / 2, _H / 2
    xs = [_W * f for f in (0.10, 0.26, 0.42, 0.58, 0.74, 0.90)]
    north = [(round(x, 1), 760.0) for x in xs]
    south = [(round(x, 1), _H - 760.0) for x in xs]
    # Opposite corners first so a two-player game starts far apart.
    order = [(north[0], 1.75 * math.pi), (south[5], 0.75 * math.pi), (north[5], 1.25 * math.pi), (south[0], 0.25 * math.pi),
             (north[2], 1.5 * math.pi), (south[3], 0.5 * math.pi), (north[3], 1.5 * math.pi), (south[2], 0.5 * math.pi),
             (north[1], 1.5 * math.pi), (south[4], 0.5 * math.pi), (north[4], 1.5 * math.pi), (south[1], 0.5 * math.pi)]
    starts = [(p[0], p[1], a) for p, a in order]
    passes = [_W * f for f in (0.18, 0.34, 0.50, 0.66, 0.82)]
    walls = []
    x = 0.0
    for i, px in enumerate(passes):
        walls += _ridge(x, px - 190, cy, 170.0, 90 + i)
        x = px + 190
    walls += _ridge(x, _W, cy, 170.0, 96)
    expansions = []
    for (x, y) in north:
        expansions.append((x, y + 900, 6, 1000))
    for (x, y) in south:
        expansions.append((x, y - 900, 6, 1000))
    for i, px in enumerate(passes):
        rich = GOLD_AMOUNT if i == 2 else 1400       # the middle pass is worth fighting for
        expansions.append((px, cy - 620, 5, rich))
        expansions.append((px, cy + 620, 5, rich))
    roads = [[*north], [*south]]
    for px in passes:
        roads.append([(px, 760.0), (px, cy), (px, _H - 760.0)])
    return _finish("continental_divide", starts, expansions, roads, 101, walls)


def archipelago():
    """Twelve bases ring an inland sea; a rich island in the middle is reached by four bridges, and lakes lie
    between neighbouring bases along the rim."""
    _begin("archipelago")
    cx, cy = _W / 2, _H / 2
    rx, ry = _W * 0.40, _H * 0.39
    starts, expansions, roads, ring = [], [], [], []
    for i in range(12):
        a = math.radians(15 + i * 30)
        x, y = cx + math.cos(a) * rx, cy + math.sin(a) * ry
        starts.append((round(x, 1), round(y, 1), a - math.pi / 4))
        ring.append((x, y))
        expansions.append((round(cx + math.cos(a) * rx * 0.86, 1), round(cy + math.sin(a) * ry * 0.86, 1), 5, 1200))
    walls, bridges = [], []
    corners = [(cx + 1700, cy - 1250), (cx + 1700, cy + 1250), (cx - 1700, cy + 1250), (cx - 1700, cy - 1250)]
    for i in range(4):      # the sea: a square moat with one bridged strait per side
        r, b = _stream(corners[i], corners[(i + 1) % 4], 300, [(0.42, 0.58)], 110 + i, amp=90.0)
        walls += r
        bridges += b
    for i in range(6):      # lakes between every other pair of neighbours on the rim
        a = math.radians(30 + i * 60)
        walls += _lake(cx + math.cos(a) * rx * 1.06, cy + math.sin(a) * ry * 1.06, 400, 280, 120 + i)
    expansions.append((cx, cy, 8, GOLD_AMOUNT))
    for i in range(4):
        a = math.radians(45 + i * 90)
        expansions.append((round(cx + math.cos(a) * 820, 1), round(cy + math.sin(a) * 820, 1), 5, 1400))
    roads.append([*ring, ring[0]])
    for i in range(4):      # a road through each strait to the island
        a = math.radians(i * 90)
        far = (cx + math.cos(a) * rx * 0.9, cy + math.sin(a) * ry * 0.9)
        roads.append([far, (cx + math.cos(a) * 1700, cy + math.sin(a) * 1250), (cx, cy)])
    return _finish("archipelago", starts, expansions, roads, 131, walls, bridges)


def six_rivers():
    """Six rivers run from a central lake to the map edges, each crossed by two bridges; two bases in every
    wedge between them."""
    _begin("six_rivers")
    cx, cy = _W / 2, _H / 2
    walls, bridges = [], []
    walls += _lake(cx, cy, 700, 520, 140)
    for i in range(6):
        a = math.radians(i * 60)
        far = (cx + math.cos(a) * _W * 0.62, cy + math.sin(a) * _H * 0.62)
        near = (cx + math.cos(a) * 520, cy + math.sin(a) * 520)
        r, b = _stream(near, far, 220, [(0.28, 0.36), (0.62, 0.70)], 150 + i, amp=60.0)
        walls += r
        bridges += b
    starts, expansions, roads = [], [], []
    ring = []
    for i in range(6):
        for off in (18, 42):
            a = math.radians(i * 60 + off)
            x, y = cx + math.cos(a) * _W * 0.40, cy + math.sin(a) * _H * 0.40
            starts.append((round(x, 1), round(y, 1), a - math.pi / 4))
            ring.append((x, y))
            expansions.append((round(cx + math.cos(a) * _W * 0.24, 1), round(cy + math.sin(a) * _H * 0.24, 1), 5, 1200))
            roads.append([(x, y), (cx + math.cos(a) * 1400, cy + math.sin(a) * 1000)])
        a = math.radians(i * 60 + 30)
        rich = GOLD_AMOUNT if i in (1, 4) else 1600       # north and south of the lake: two gold fields
        expansions.append((round(cx + math.cos(a) * 1200, 1), round(cy + math.sin(a) * 1200, 1), 6, rich))
        roads.append([(cx + math.cos(a) * _W * 0.40, cy + math.sin(a) * _H * 0.40), (cx + math.cos(a) * 1200, cy + math.sin(a) * 1200)])
    roads.append([*ring, ring[0]])
    return _finish("six_rivers", starts, expansions, roads, 149, walls, bridges)


def crater_fields():
    """Every base sits inside a broken ring of cliffs with two openings; a walled rich crater in the middle."""
    _begin("crater_fields")
    cx, cy = _W / 2, _H / 2
    rx, ry = _W * 0.40, _H * 0.38
    starts, expansions, roads, ring, walls = [], [], [], [], []
    for i in range(12):
        a = math.radians(15 + i * 30)
        x, y = cx + math.cos(a) * rx, cy + math.sin(a) * ry
        starts.append((round(x, 1), round(y, 1), a - math.pi / 4))
        ring.append((x, y))
        # Two arcs of cliff around the base, leaving an opening toward the middle and one along the rim.
        inward = a + math.pi
        walls += _arc_ridge(x, y, 640, inward + math.radians(35), inward + math.radians(145), 150, 160 + i)
        walls += _arc_ridge(x, y, 640, inward + math.radians(215), inward + math.radians(325), 150, 172 + i)
        expansions.append((round(cx + math.cos(a) * rx * 0.60, 1), round(cy + math.sin(a) * ry * 0.60, 1), 5, 1200))
    for i in range(4):      # the central crater, open on the diagonals
        a0 = math.radians(i * 90 + 20)
        walls += _arc_ridge(cx, cy, 900, a0, a0 + math.radians(50), 160, 184 + i)
    expansions.append((cx, cy, 8, GOLD_AMOUNT))
    for i in range(4):
        a = math.radians(45 + i * 90)
        expansions.append((round(cx + math.cos(a) * 1500, 1), round(cy + math.sin(a) * 1500, 1), 6, 1400))
    roads.append([*ring, ring[0]])
    for i in range(12):
        a = math.radians(15 + i * 30)
        roads.append([ring[i], (cx + math.cos(a) * rx * 0.60, cy + math.sin(a) * ry * 0.60), (cx, cy)])
    return _finish("crater_fields", starts, expansions, roads, 191, walls)


def long_march():
    """Two rows of six bases face each other across a wide river with six bridges; lakes between the bases."""
    _begin("long_march")
    cx, cy = _W / 2, _H / 2
    xs = [900.0 + i * 1440.0 for i in range(6)]
    north = [(x, 820.0) for x in xs]
    south = [(x, _H - 820.0) for x in xs]
    order = [(north[0], 1.75 * math.pi), (south[5], 0.75 * math.pi), (north[5], 1.25 * math.pi), (south[0], 0.25 * math.pi),
             (north[2], 1.5 * math.pi), (south[3], 0.5 * math.pi), (north[3], 1.5 * math.pi), (south[2], 0.5 * math.pi),
             (north[1], 1.5 * math.pi), (south[4], 0.5 * math.pi), (north[4], 1.5 * math.pi), (south[1], 0.5 * math.pi)]
    starts = [(p[0], p[1], a) for p, a in order]
    gaps = [((x - 130) / _W, (x + 130) / _W) for x in xs]   # a bridge in front of every base
    walls, bridges = _stream((0.0, cy), (_W, cy), 280, gaps, 201, amp=80.0)
    for i in range(5):      # lakes between neighbouring bases, both rows
        mx = (xs[i] + xs[i + 1]) / 2
        walls += _lake(mx, 820.0 + 520, 400, 300, 210 + i)
        walls += _lake(mx, _H - 820.0 - 520, 400, 300, 216 + i)
    expansions = []
    for (x, y) in north:
        expansions.append((x, y + 980, 6, 1000))
    for (x, y) in south:
        expansions.append((x, y - 980, 6, 1000))
    for i in range(5):
        mx = (xs[i] + xs[i + 1]) / 2
        rich = GOLD_AMOUNT if i == 2 else 1400       # the two fields either side of the middle bridges
        expansions.append((mx, cy - 560, 5, rich))
        expansions.append((mx, cy + 560, 5, rich))
    roads = [[*north], [*south]]
    for x in xs:
        roads.append([(x, 820.0), (x, cy), (x, _H - 820.0)])
    return _finish("long_march", starts, expansions, roads, 223, walls, bridges)


GENERATORS = {"twin_ridges": twin_ridges, "river_crossing": river_crossing, "highland_pass": highland_pass,
              "four_corners": four_corners, "crossroads": crossroads, "grand_arena": grand_arena,
              "riverlands": riverlands, "continental_divide": continental_divide, "archipelago": archipelago,
              "six_rivers": six_rivers, "crater_fields": crater_fields, "long_march": long_march}


def generate(map_id):
    return GENERATORS.get(map_id, twin_ridges)()


def bake_swift(path=None):
    """Writes macos/Sources/FieldCommand/GiantMaps.swift: the giant maps' layouts as compact strings the Mac
    edition parses at launch, so it carries exactly these maps. (Strings, not array literals: the Swift type
    checker takes minutes over a few hundred tuple literals.) tests/test_parity.py checks the file is current."""
    import os
    out = ["import Foundation", "",
           "/// The five giant maps (9000 x 6300, twelve players), baked from linux/fieldcommand/mapgen.py so both editions",
           "/// carry the same layouts: the starts, expansions, roads, walls and bridges are baked data; the mineral lines,",
           "/// clearings and forests are laid out by `finish` exactly as on Linux (trees use each edition's own RNG).",
           "/// Re-bake with:  cd linux && python -c \"from fieldcommand import mapgen; mapgen.bake_swift()\"",
           "extension SMapGen {"]
    for mid in GIANT_IDS:
        m = generate(mid)
        cam = "".join(p.title() for p in mid.split("_"))
        cam = cam[0].lower() + cam[1:]
        out += [f"    // {mid}: generated by linux/fieldcommand/mapgen.py",
                f"    static func {cam}() -> [String: Any] {{",
                "        setWorldSize(giantWorld.width, giantWorld.height)",
                f'        return finish("{mid}", starts({cam}Starts), expansions({cam}Expansions), roads({cam}Roads),',
                f"                      seed: {m['seed']}, walls: walls({cam}Walls), bridges: rects({cam}Bridges))",
                "    }",
                f'    static let {cam}Starts = "{bake_starts(m)}"',
                f'    static let {cam}Expansions = "{bake_expansions(m)}"',
                f'    static let {cam}Roads = "{bake_roads(m)}"',
                f'    static let {cam}Walls = "{bake_walls(m)}"',
                f'    static let {cam}Bridges = "{bake_bridges(m)}"', ""]
    out.append("}")
    path = path or os.path.join(os.path.dirname(__file__), "..", "..", "macos", "Sources", "FieldCommand", "GiantMaps.swift")
    with open(path, "w") as fh:
        fh.write("\n".join(out) + "\n")
    return path


def _num(v):
    r = round(v, 1)
    return str(int(r)) if r == int(r) else str(r)


# The baked forms: numbers separated by spaces, entries by ';', a road's points by ','. What the Mac parses.
def bake_starts(m):
    return ";".join(f"{_num(s[0])} {_num(s[1])} {s[2]}" for s in m["starts"])


def bake_expansions(m):
    return ";".join(f"{_num(e[0])} {_num(e[1])} {e[2]} {e[3]}" for e in m["expansions"])


def bake_roads(m):
    return ";".join(",".join(f"{_num(p[0])} {_num(p[1])}" for p in r) for r in m["roads"])


def bake_walls(m):
    return ";".join(f"{_num(w[0])} {_num(w[1])} {_num(w[2])} {_num(w[3])} {w[4]}" for w in m["walls"])


def bake_bridges(m):
    return ";".join(f"{_num(b[0])} {_num(b[1])} {_num(b[2])} {_num(b[3])}" for b in m["bridges"])


def for_players(n):
    if n <= 2:
        return twin_ridges()
    return four_corners() if n <= 4 else grand_arena()


def resolve(map_id, n_players):
    """Map for a lobby choice: 'auto' picks by player count; too-small maps fall back to one that fits."""
    if map_id in BY_ID and BY_ID[map_id]["players"] >= n_players:
        return generate(map_id)
    return for_players(n_players)
