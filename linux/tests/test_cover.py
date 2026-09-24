"""Cover: anyone on foot among trees takes half from ranged fire; tanks, aircraft and point-blank hits get nothing."""
import math

from conftest import hq_of, make_world
from fieldcommand.defs import COVER_FACTOR, COVER_KINDS, COVER_REACH, SMOKE_RANGED, UNITS
from fieldcommand.entities import Unit


def spawn(w, kind, team, x, y):
    u = Unit(w, kind, team, x, y)
    w._add(u)
    u.command(("idle",))
    u.cooldown = 1e9
    return u


def a_tree(w):
    return w.obstacles[0][:3]


def test_the_rule_covers_everyone_on_foot_and_nobody_else():
    assert set(COVER_KINDS) == {k for k in UNITS if not UNITS[k].flies and k != "tank"}


def test_infantry_among_trees_takes_half_from_a_distance():
    w = make_world("twin_ridges")
    for u in list(w.units):
        u.command(("idle",))
        u.cooldown = 1e9
    tx, ty, tr = a_tree(w)
    r = spawn(w, "marine", 0, tx + tr + COVER_REACH - 2, ty)
    assert w.in_cover(r.x, r.y)
    far = spawn(w, "sniper", 1, r.x + SMOKE_RANGED + 300, r.y)
    near = spawn(w, "marine", 1, r.x + 30, r.y)
    hp = r.hp
    r.take_damage(10, far)
    assert math.isclose(hp - r.hp, 10 * COVER_FACTOR)
    hp = r.hp
    r.take_damage(10, near)
    assert math.isclose(hp - r.hp, 10)                                    # point blank: no cover
    open_ = spawn(w, "marine", 0, tx + tr + COVER_REACH + 400, ty)
    assert not w.in_cover(open_.x, open_.y) or any(math.hypot(open_.x - o[0], open_.y - o[1]) <= o[2] + COVER_REACH
                                                      for o in w.obstacles if o is not w.obstacles[0])


def test_tanks_get_nothing_from_a_forest():
    w = make_world("twin_ridges")
    for u in list(w.units):
        u.command(("idle",))
        u.cooldown = 1e9
    tx, ty, tr = a_tree(w)
    t = spawn(w, "tank", 0, tx + tr + COVER_REACH - 2, ty)
    far = spawn(w, "sniper", 1, t.x + 400, t.y)
    hp = t.hp
    t.take_damage(10, far)
    assert math.isclose(hp - t.hp, 10)


def test_cover_and_smoke_do_not_stack():
    w = make_world("twin_ridges")
    for u in list(w.units):
        u.command(("idle",))
        u.cooldown = 1e9
    tx, ty, tr = a_tree(w)
    r = spawn(w, "marine", 0, tx + tr + COVER_REACH - 2, ty)
    tank = spawn(w, "tank", 0, r.x + 20, r.y)
    assert w.use_ability(0, [tank], 0, 0) == 1
    far = spawn(w, "sniper", 1, r.x + 400, r.y)
    hp = r.hp
    r.take_damage(10, far)
    assert math.isclose(hp - r.hp, 10 * COVER_FACTOR)


def test_the_unit_card_says_so():
    w = make_world("twin_ridges")
    tx, ty, tr = a_tree(w)
    r = spawn(w, "marine", 0, tx + tr + COVER_REACH - 2, ty)
    assert r.status_text().endswith("in cover")
    t = spawn(w, "tank", 0, tx + tr + COVER_REACH - 2, ty)
    assert "cover" not in t.status_text()
