"""Watchtowers: placement, capture, contest, vision and the wire."""
import math

from conftest import hq_of, make_world, run
from fieldcommand import mapgen, net
from fieldcommand.defs import TOWER_CAPTURE_TIME, TOWER_RADIUS, TOWER_SIGHT, rect_distance
from fieldcommand.entities import Unit
import pytest


@pytest.mark.parametrize("map_id", [m["id"] for m in mapgen.CATALOG])
def test_every_map_gets_three_towers_on_open_ground(map_id):
    w = make_world(map_id, players=mapgen.BY_ID[map_id]["players"])
    assert len(w.towers) == 3, map_id
    for t in w.towers:
        assert not any(rect_distance(wl, t.x, t.y) < 20 for wl in w.map_walls), (map_id, t.x, t.y)
        assert all(math.hypot(o.x - t.x, o.y - t.y) > 300 for o in w.towers if o is not t)


def test_troops_alone_in_the_ring_take_it_in_eight_seconds():
    w = make_world()
    t = w.towers[0]
    u = Unit(w, "marine", 0, t.x + 60, t.y)
    w._add(u)
    assert t.owner is None
    run(w, TOWER_CAPTURE_TIME - 0.5)
    assert t.owner is None and t.capturing == 0 and t.progress > 0.8
    run(w, 1.0)
    assert t.owner == 0 and t.progress == 0


def test_a_contested_ring_does_not_flip_and_the_clock_winds_back():
    w = make_world()
    t = w.towers[0]
    a = Unit(w, "marine", 0, t.x + 60, t.y)
    b = Unit(w, "marine", 1, t.x - 60, t.y)
    for u in (a, b):
        w._add(u)
        u.order = ("idle",)
        u.hp = 10 ** 6            # nobody dies; this is about the ring, not the fight
    run(w, 6)
    assert t.owner is None and t.progress == 0


def test_the_owner_sees_around_it_and_can_lose_it():
    w = make_world()
    t = w.towers[0]
    u = Unit(w, "marine", 0, t.x + 60, t.y)
    w._add(u)
    run(w, TOWER_CAPTURE_TIME + 0.5)
    assert t.owner == 0
    w.update_visibility()
    far = (t.x + TOWER_SIGHT - 40, t.y)
    assert w.fog_for(0).is_visible(*far) and not w.fog_for(1).is_visible(*far)
    u.dead = True
    w._cleanup_dead()
    e = Unit(w, "marine", 1, t.x - 60, t.y)
    w._add(e)
    run(w, TOWER_CAPTURE_TIME + 0.5)
    assert t.owner == 1
    w.update_visibility()
    assert w.fog_for(1).is_visible(*far)


def test_towers_travel_in_snapshots():
    w = make_world()
    snap = net.snapshot_for(w, 0, [])
    assert len(snap["tw"]) == 3 and snap["tw"][0][3] == -1
