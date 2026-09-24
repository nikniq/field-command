"""The derelict Siege Tank: one near the middle of every map, salvaged by an Engineer alone beside it."""
import math

import pytest

from conftest import hq_of, make_world, run
from fieldcommand import mapgen, net
from fieldcommand.ai import AI
from fieldcommand.defs import DERELICT_RADIUS, DERELICT_TIME, rect_distance
from fieldcommand.entities import Unit


def spawn(w, kind, team, x, y):
    u = Unit(w, kind, team, x, y)
    w._add(u)
    u.command(("idle",))
    u.cooldown = 1e9
    return u


@pytest.mark.parametrize("map_id", [m["id"] for m in mapgen.CATALOG])
def test_every_map_has_one_derelict_on_open_ground_near_the_middle(map_id):
    w = make_world(map_id, players=mapgen.BY_ID[map_id]["players"])
    assert len(w.derelicts) == 1, map_id
    d = w.derelicts[0]
    assert not any(rect_distance(wl, d.x, d.y) < 20 for wl in w.map_walls), (map_id, d.x, d.y)
    assert all(math.hypot(t.x - d.x, t.y - d.y) >= 300 for t in w.towers)
    rx, ry = w.ring
    assert math.hypot(d.x - rx, d.y - ry) < 700
    assert w.by_id[d.id] is d


def test_an_engineer_alone_beside_it_salvages_a_siege_tank():
    w = make_world()
    for u in list(w.units):
        u.command(("idle",))
    d = w.derelicts[0]
    e = spawn(w, "worker", 0, d.x + 40, d.y)
    tanks = lambda: [u for u in w.units if u.kind == "tank" and u.team == 0 and not u.dead]
    run(w, DERELICT_TIME - 0.5)
    assert w.derelicts == [d] and d.capturing == 0 and d.progress > 0.8 and not tanks()
    run(w, 1.0)
    assert not w.derelicts and d.salvaged and d.id not in w.by_id
    assert len(tanks()) == 1 and math.hypot(tanks()[0].x - d.x, tanks()[0].y - d.y) < 30


def test_troops_alone_do_not_salvage_and_an_enemy_inside_stalls_it():
    w = make_world()
    for u in list(w.units):
        u.command(("idle",))
    d = w.derelicts[0]
    spawn(w, "marine", 0, d.x + 40, d.y)
    run(w, DERELICT_TIME + 1)
    assert w.derelicts == [d] and d.progress == 0                       # a Ranger cannot do the work
    e = spawn(w, "worker", 0, d.x - 40, d.y)
    run(w, DERELICT_TIME / 2)
    assert 0.3 < d.progress < 0.7 and d.capturing == 0
    foe = spawn(w, "marine", 1, d.x, d.y + 50)
    run(w, 2)
    assert d.progress < 0.5 - 0.1                                        # contested: the clock winds back
    foe.dead = True
    w._cleanup_dead()
    run(w, DERELICT_TIME)
    assert not w.derelicts


def test_the_derelict_travels_on_the_wire_and_in_saves():
    from fieldcommand.save import world_to_dict, world_from_dict
    w = make_world()
    for u in list(w.units):
        u.command(("idle",))
    d = w.derelicts[0]
    spawn(w, "worker", 1, d.x + 30, d.y)
    run(w, 3)
    snap = net.snapshot_for(w, 0, [])
    assert len(snap["dr"]) == 1 and snap["dr"][0][0] == d.id and snap["dr"][0][4] == 1 and snap["dr"][0][5] > 0
    w2 = world_from_dict(world_to_dict(w))
    assert len(w2.derelicts) == 1 and w2.derelicts[0].id == d.id and w2.derelicts[0].capturing == 1 and w2.derelicts[0].progress > 0
    run(w, DERELICT_TIME)
    assert not w.derelicts
    w3 = world_from_dict(world_to_dict(w))
    assert not w3.derelicts and net.snapshot_for(w, 0, [])["dr"] == []


def test_the_computer_sends_an_engineer_for_it():
    w = make_world("twin_ridges", players=2)
    ai = AI(w, 1)
    w.players[1].is_ai, w.players[1].ai = True, ai
    w.elapsed = 25.0
    hq = hq_of(w, 1)
    home = [u for u in w.units if u.team == 1 and u.kind != "worker"]
    workers = [u for u in w.units if u.team == 1 and u.kind == "worker"]
    ai._salvage(hq, workers, home)
    d = w.derelicts[0]
    assert ai.salvager in workers and ai.salvager.order[0] == "move" and abs(ai.salvager.order[1] - (d.x + 30)) < 1
    w.derelicts.clear()
    ai._salvage(hq, workers, home)
    assert ai.salvager is None
