"""Sniper and Radar Station mechanics against the simulation."""
from conftest import hq_of, make_world, run
from fieldcommand.defs import BUILDINGS, UNITS
from fieldcommand.entities import Unit


def messages(world, slot):
    out = [e[2] for e in world.events if e[0] == "msg" and e[1] == slot]
    world.events.clear()
    return out


def test_sniper_needs_a_factory():
    w = make_world()
    hq = hq_of(w, 0)
    w.resources[0] = 5000
    bk = w.start_building("barracks", hq.x + 300, hq.y, 0)
    bk.built, bk.progress = True, 1.0
    w.events.clear()
    assert w.train("sniper", [bk], 0) is False
    assert "Requires Factory" in messages(w, 0)
    fc = w.start_building("factory", hq.x + 500, hq.y, 0)
    fc.built, fc.progress = True, 1.0
    assert w.train("sniper", [bk], 0) is True
    assert bk.queue == ["sniper"]


def test_sniper_kills_a_ranger_outside_ranger_range():
    w = make_world()
    hq = hq_of(w, 0)
    sn = Unit(w, "sniper", 0, hq.x + 100, hq.y + 100)
    w._add(sn)
    victim = Unit(w, "marine", 1, sn.x + 250, sn.y)   # inside 330, outside the Ranger's 150
    w._add(victim)
    sn.command(("attack", victim))
    assert run(w, 20, until=lambda: victim.dead)


def test_radar_reveals_ground_the_base_cannot_see():
    w = make_world()
    hq = hq_of(w, 0)
    far = (hq.x + 1500, hq.y)
    w.update_visibility()
    fog = w.fog_for(0)
    assert not fog.is_visible(*far)
    rd = w.start_building("radar", far[0] - 600, far[1], 0)     # 900 sight covers `far`
    rd.built, rd.progress = True, 1.0
    w.update_visibility()
    assert fog.is_visible(*far)
    assert BUILDINGS["radar"].sight == 900


def test_radar_dish_turns():
    w = make_world()
    hq = hq_of(w, 0)
    rd = w.start_building("radar", hq.x + 400, hq.y, 0)
    rd.built, rd.progress = True, 1.0
    a0 = rd.gun_angle
    run(w, 1)
    assert abs(rd.gun_angle - a0) > 0.1
