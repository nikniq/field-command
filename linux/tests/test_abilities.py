"""Unit abilities: the Ranger's grenade, the Sniper's mark and the Siege Tank's smoke, each on a cooldown."""
import math

from conftest import DT, hq_of, make_world, run
from fieldcommand.defs import (ABILITIES, GRENADE_DAMAGE, GRENADE_SPLASH, MARK_BONUS, MARK_DURATION, SMOKE_DURATION,
                               SMOKE_FACTOR, SMOKE_RADIUS, UNITS)
from fieldcommand.entities import Unit


def quiet(w):
    """Nobody fires on their own: the tests deal the damage themselves."""
    for u in list(w.units):
        u.command(("idle",))
        u.cooldown = 1e9


def spawn(w, kind, team, x, y, armed=False):
    u = Unit(w, kind, team, x, y)
    w._add(u)
    u.command(("idle",))
    if not armed:
        u.cooldown = 1e9
    return u


def test_every_ability_is_on_a_kind_that_exists():
    for kind, (aid, name, reach, cd, needs) in ABILITIES.items():
        assert kind in UNITS and needs in ("point", "target", "self") and cd > 0 and name


def test_a_grenade_bursts_where_it_lands_and_then_recharges():
    w = make_world("twin_ridges")
    quiet(w)
    hq = hq_of(w, 0)
    r = spawn(w, "marine", 0, hq.x + 300, hq.y)
    foes = [spawn(w, "marine", 1, hq.x + 450 + i * 20, hq.y) for i in range(3)]
    before = [f.hp for f in foes]
    assert w.use_ability(0, [r], hq.x + 470, hq.y) == 1
    assert r.ability_cd == ABILITIES["marine"][3]
    run(w, 3)
    assert all(f.hp < b for f, b in zip(foes, before))                # all three were inside the burst
    assert w.use_ability(0, [r], hq.x + 470, hq.y) == 0               # recharging
    run(w, ABILITIES["marine"][3] + 1)
    assert r.ability_cd == 0
    assert w.use_ability(0, [r], hq.x + 470, hq.y) == 1


def test_a_grenade_cannot_be_thrown_beyond_its_reach():
    w = make_world("twin_ridges")
    quiet(w)
    hq = hq_of(w, 0)
    r = spawn(w, "marine", 0, hq.x + 300, hq.y)
    assert w.use_ability(0, [r], hq.x + 300 + ABILITIES["marine"][2] + 50, hq.y) == 0
    assert r.ability_cd == 0


def test_a_marked_target_takes_half_again_as_much_until_the_mark_fades():
    w = make_world("twin_ridges")
    quiet(w)
    hq = hq_of(w, 0)
    s = spawn(w, "sniper", 0, hq.x + 300, hq.y)
    t = spawn(w, "tank", 1, hq.x + 500, hq.y)
    plain = t.hp
    t.take_damage(10, s)
    assert math.isclose(plain - t.hp, 10)
    assert w.use_ability(0, [s], t.x, t.y, t.id) == 1
    assert t.marked_until > w.elapsed
    before = t.hp
    t.take_damage(10, s)
    assert math.isclose(before - t.hp, 10 * (1 + MARK_BONUS))
    run(w, MARK_DURATION + 0.5)
    assert t.marked_until <= w.elapsed
    before = t.hp
    t.take_damage(10, s)
    assert math.isclose(before - t.hp, 10)


def test_a_mark_needs_an_enemy_in_reach():
    w = make_world("twin_ridges")
    quiet(w)
    hq = hq_of(w, 0)
    s = spawn(w, "sniper", 0, hq.x + 300, hq.y)
    friend = spawn(w, "marine", 0, hq.x + 400, hq.y)
    far = spawn(w, "marine", 1, hq.x + 300 + ABILITIES["sniper"][2] + 100, hq.y)
    assert w.use_ability(0, [s], friend.x, friend.y, friend.id) == 0
    assert w.use_ability(0, [s], far.x, far.y, far.id) == 0
    assert s.ability_cd == 0


def test_smoke_halves_ranged_damage_inside_it_but_not_point_blank_hits():
    w = make_world("twin_ridges")
    quiet(w)
    hq = hq_of(w, 0)
    tank = spawn(w, "tank", 0, hq.x + 300, hq.y)
    ranger = spawn(w, "marine", 0, hq.x + 330, hq.y)
    far = spawn(w, "sniper", 1, hq.x + 700, hq.y)
    near = spawn(w, "marine", 1, hq.x + 360, hq.y)
    assert w.use_ability(0, [tank], 0, 0) == 1
    assert len(w.smokes) == 1 and w.smokes[0][:2] == (tank.x, tank.y)
    before = ranger.hp
    ranger.take_damage(10, far)
    assert math.isclose(before - ranger.hp, 10 * SMOKE_FACTOR)
    before = ranger.hp
    ranger.take_damage(10, near)
    assert math.isclose(before - ranger.hp, 10)
    outside = spawn(w, "marine", 0, hq.x + 300 + SMOKE_RADIUS + 40, hq.y)
    before = outside.hp
    outside.take_damage(10, far)
    assert math.isclose(before - outside.hp, 10)
    run(w, SMOKE_DURATION + 0.5)
    assert not w.smokes
    before = ranger.hp
    ranger.take_damage(10, far)
    assert math.isclose(before - ranger.hp, 10)


def test_the_ability_command_goes_through_the_wire_and_the_save():
    from fieldcommand.net import snapshot_for
    from fieldcommand.save import world_to_dict, world_from_dict
    w = make_world("twin_ridges")
    quiet(w)
    hq = hq_of(w, 0)
    s = spawn(w, "sniper", 0, hq.x + 300, hq.y)
    t = spawn(w, "tank", 1, hq.x + 500, hq.y)
    tank = spawn(w, "tank", 0, hq.x + 200, hq.y)
    w._apply(0, ["ability", [s.id], t.x, t.y, t.id])
    w._apply(0, ["ability", [tank.id], 0, 0, None])
    run(w, 0.5)
    assert t.marked_until > w.elapsed and s.ability_cd > 0 and len(w.smokes) == 1
    snap = snapshot_for(w, 0, [])
    row = next(r for r in snap["u"] if r[0] == t.id)
    assert row[12] == 1                                               # marked
    row = next(r for r in snap["u"] if r[0] == s.id)
    assert row[11] > 0                                                # recharging
    assert len(snap["sm"]) == 1
    d = world_to_dict(w)
    w2 = world_from_dict(d)
    assert len(w2.smokes) == 1
    s2 = w2.by_id[s.id]
    assert s2.ability_cd > 0 and w2.by_id[t.id].marked_until > w2.elapsed


def test_the_computer_uses_its_abilities():
    w = make_world("twin_ridges", ai=True)
    quiet(w)
    hq = hq_of(w, 1)
    r = spawn(w, "marine", 1, hq.x - 300, hq.y, armed=True)
    sn = spawn(w, "sniper", 1, hq.x - 320, hq.y + 40, armed=True)
    foes = [spawn(w, "marine", 0, hq.x - 450 - i * 15, hq.y, armed=True) for i in range(3)]
    run(w, 2)
    assert r.ability_cd > 0                                           # a grenade went into the knot
    assert sn.ability_cd > 0 and any(f.marked_until > 0 for f in foes)
