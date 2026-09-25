"""Barricades: a cheap wall block that stops movement until it is shot down."""
import math

from conftest import DT, hq_of, make_world, run
from fieldcommand.ai import AI
from fieldcommand.defs import BUILDINGS, BUILDING_KINDS, BUILD_MENU
from fieldcommand.entities import Unit


def wall_line(w, x, y0, y1, team):
    """A run of Barricades along x from y0 to y1, already built."""
    s = BUILDINGS["wall"]
    out = []
    y = y0
    while y <= y1:
        b = w.start_building("wall", x, y, team)
        b.built, b.progress = True, 1.0
        out.append(b)
        y += s.half * 2
    w._rebuild_nav()
    return out


def test_the_barricade_is_in_the_catalogue_cheap_and_late_on_the_wire():
    s = BUILDINGS["wall"]
    assert s.cost <= 40 and s.hp >= 500 and s.half <= 24 and s.requires is None and s.range == 0
    assert BUILDING_KINDS[-2:] == ["wall", "mine"] and BUILD_MENU[-2:] == ["wall", "mine"]   # the mine came after


def test_a_run_of_barricades_blocks_the_way_until_it_is_shot_down():
    w = make_world("twin_ridges")
    for u in list(w.units):
        u.command(("idle",))
    hq = hq_of(w, 0)
    x = hq.x + 500
    from fieldcommand.defs import WORLD_H
    walls = wall_line(w, x, 0, WORLD_H, 0)                          # edge to edge: no way round
    assert len(walls) >= 60
    assert not w.nav.reaches(hq.x, hq.y, x + 200, hq.y)
    for b in walls:
        b.take_damage(99999, None)
    w._cleanup_dead()
    w._rebuild_nav()
    assert w.nav.reaches(hq.x, hq.y, x + 200, hq.y)


def test_an_attacker_walks_up_to_the_wall_and_shoots_it():
    w = make_world("twin_ridges")
    for u in list(w.units):
        u.command(("idle",))
    hq = hq_of(w, 0)
    x = hq.x + 500
    walls = wall_line(w, x, hq.y - 400, hq.y + 400, 0)
    hp0 = sum(b.hp for b in walls)
    t = Unit(w, "tank", 1, x + 300, hq.y)
    w._add(t)
    t.command(("amove", hq.x, hq.y))
    run(w, 25)
    assert sum(b.hp for b in walls if not b.dead) < hp0 - 100      # it is shooting the wall in its way
    assert t.x > x                                                   # and has not walked through it


def test_the_computer_still_attacks_a_walled_base():
    w = make_world("twin_ridges", players=2, ai=True)
    ai = w.players[1].ai
    hq0 = hq_of(w, 0)
    from fieldcommand.defs import WORLD_H
    wall_line(w, hq0.x + 500, 0, WORLD_H, 0)                        # edge to edge: the base is walled off
    assert not w.nav.reaches(hq_of(w, 1).x, hq_of(w, 1).y, hq0.x, hq0.y)
    ai._next_route = 0
    ai._open_route(hq_of(w, 1), [], [u for u in w.units if u.team == 1 and u.kind == "worker"])
    assert ai.route_open and ai.route_bridge is None                 # nothing to rebuild: the wave goes anyway
