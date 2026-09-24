"""High ground: plateaus are walkable and buildable, and whatever stands on one sees and shoots further."""
from conftest import hq_of, make_world
from fieldcommand import mapgen
from fieldcommand.defs import BUILDINGS, HIGH_RANGE, HIGH_SIGHT, UNITS
from fieldcommand.entities import Unit


def test_three_maps_have_plateaus_inside_the_world_and_clear_of_walls():
    from fieldcommand.defs import rects_intersect
    with_ridges = []
    for m in mapgen.CATALOG:
        spec = mapgen.generate(m["id"])
        for x0, y0, x1, y1 in spec.get("ridges", []):
            assert 0 <= x0 < x1 <= spec["w"] and 0 <= y0 < y1 <= spec["h"], m["id"]
            assert not any(rects_intersect((x0, y0, x1, y1), tuple(w[:4])) for w in spec["walls"]), m["id"]
            with_ridges.append(m["id"])
    assert set(with_ridges) == {"twin_ridges", "highland_pass", "four_corners"}


def test_standing_on_a_plateau_sees_and_shoots_further():
    w = make_world("twin_ridges")
    x0, y0, x1, y1 = w.ridges[0]
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    up = Unit(w, "marine", 0, cx, cy)
    down = Unit(w, "marine", 0, x0 - 200, cy)
    assert w.on_high(cx, cy) and not w.on_high(x0 - 200, cy)
    assert up.attack_range == down.attack_range + HIGH_RANGE == UNITS["marine"].range + HIGH_RANGE
    assert up.sight == down.sight * HIGH_SIGHT


def test_a_turret_on_the_high_ground_reaches_further():
    w = make_world("twin_ridges")
    x0, y0, x1, y1 = w.ridges[0]
    t = w.start_building("turret", (x0 + x1) / 2, (y0 + y1) / 2, 0)
    t.built = True
    assert t.turret_range == BUILDINGS["turret"].range + HIGH_RANGE


def test_plateaus_are_walkable_buildable_and_reveal_more():
    w = make_world("twin_ridges")
    x0, y0, x1, y1 = w.ridges[0]
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hq = hq_of(w, 0)
    assert w.nav.reaches(hq.x, hq.y, cx, cy)
    assert w.can_place("depot", cx, cy)
    for u in list(w.units):
        u.dead = True
    w._cleanup_dead()
    r = Unit(w, "marine", 0, cx, cy)
    w._add(r)
    w.update_visibility()
    far = UNITS["marine"].sight * 1.2                          # beyond a plain Ranger's sight, within a high one's
    assert w.fog[w.players[0].team].is_visible(cx + far, cy)
    r.x = x0 - 200
    w.update_visibility()
    assert not w.fog[w.players[0].team].is_visible(x0 - 200 + far, cy)
