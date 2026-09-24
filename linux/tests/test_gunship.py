"""The Gunship: an aircraft that flies straight over terrain and walls, and that tanks cannot touch."""
import math

from conftest import DT, hq_of, make_world, run
from fieldcommand.defs import AIR_GUNS, BUILDINGS, UNITS, UNIT_KINDS, WORLD_H
from fieldcommand.entities import Unit


def wall_line(w, x, y0, y1, team):
    y = y0
    while y <= y1:
        b = w.start_building("wall", x, y, team)
        b.built, b.progress = True, 1.0
        y += BUILDINGS["wall"].half * 2
    w._rebuild_nav()


def test_the_gunship_is_in_the_catalogue_and_trained_at_the_factory():
    s = UNITS["gunship"]
    assert s.flies and s.hits_air and s.requires == "radar" and s.speed > UNITS["marine"].speed
    assert "gunship" in BUILDINGS["factory"].produces and UNIT_KINDS[-1] == "gunship"
    assert not UNITS["tank"].hits_air and UNITS["marine"].hits_air and UNITS["sniper"].hits_air
    assert set(AIR_GUNS) == {"turret", "hq"}


def test_it_flies_straight_over_a_wall_that_stops_a_tank():
    w = make_world("twin_ridges")
    for u in list(w.units):
        u.command(("idle",))
    hq = hq_of(w, 0)
    x = hq.x + 500
    wall_line(w, x, 0, WORLD_H, 1)                                   # an enemy wall, edge to edge
    ship = Unit(w, "gunship", 0, hq.x, hq.y + 300)
    tank = Unit(w, "tank", 0, hq.x, hq.y - 300)
    w._add(ship)
    w._add(tank)
    ship.command(("move", x + 400, hq.y + 300))
    tank.command(("move", x + 400, hq.y - 300))
    run(w, 12)
    assert ship.x > x + 300 and ship.path is None                    # over the wall, no path needed
    assert tank.x < x                                                # the tank is still on this side


def test_tanks_cannot_shoot_it_but_rangers_and_turrets_can():
    w = make_world("twin_ridges")
    for u in list(w.units):
        u.command(("idle",))
    hq = hq_of(w, 0)
    ship = Unit(w, "gunship", 1, hq.x + 400, hq.y + 500)
    w._add(ship)
    ship.command(("idle",))
    tank = Unit(w, "tank", 0, hq.x + 400, hq.y + 380)
    w._add(tank)
    tank.command(("idle",))
    w.update_visibility()
    assert w.find_target(tank, 400) is None                          # in range, but a tank cannot lift its gun
    ranger = Unit(w, "marine", 0, hq.x + 400, hq.y + 400)
    w._add(ranger)
    ranger.command(("idle",))
    assert w.find_target(ranger, 400) is ship
    t = w.start_building("turret", hq.x + 400, hq.y + 300, 0)
    t.built = True
    assert t.hits_air and w.find_target(t, 400) is ship
    a = w.start_building("artillery", hq.x + 600, hq.y + 300, 0)
    a.built = True
    assert not a.hits_air and w.find_target(a, 600) is None


def test_it_passes_over_ground_units_without_pushing_them():
    w = make_world("twin_ridges")
    for u in list(w.units):
        u.command(("idle",))
    hq = hq_of(w, 0)
    crowd = [Unit(w, "marine", 0, hq.x + 300 + i * 22, hq.y + 400) for i in range(6)]
    for u in crowd:
        w._add(u)
        u.command(("idle",))
    before = [(u.x, u.y) for u in crowd]
    ship = Unit(w, "gunship", 0, hq.x + 100, hq.y + 400)
    w._add(ship)
    ship.command(("move", hq.x + 700, hq.y + 400))
    run(w, 6)
    assert ship.x > hq.x + 600
    assert all(math.hypot(u.x - bx, u.y - by) < 1 for u, (bx, by) in zip(crowd, before))
