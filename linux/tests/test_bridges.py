"""Bridges: shelling one down, what that blocks, and rebuilding it."""
import math

from conftest import DT, hq_of, make_world, run
from fieldcommand import net
from fieldcommand.defs import BRIDGE_COST, BRIDGE_HP, rect_distance
from fieldcommand.entities import Unit


def cell(world, b):
    return int(b.x // 40), int(b.y // 40)


def test_river_crossing_has_three_bridges_that_start_walkable():
    w = make_world("river_crossing")
    assert len(w.bridges) == 3
    w._rebuild_nav()
    for b in w.bridges:
        assert b.intact and not w.nav.is_blocked(*cell(w, b))


def test_a_tank_shells_a_bridge_down_and_the_span_blocks():
    w = make_world("river_crossing")
    br = w.bridges[0]
    tank = Unit(w, "tank", 0, br.x - 200, br.y)
    w._add(tank)
    w.apply(0, ["attack", [tank.id], br.id, False])
    assert tank.order[0] == "attack" and tank.order[1] is br
    assert run(w, 150, until=lambda: not br.intact)
    w._rebuild_nav()
    assert w.nav.is_blocked(*cell(w, br))
    assert br.targetable_by(0) is False        # ruins are rebuilt, not shot at again


def test_an_engineer_rebuilds_for_crystal_and_the_span_opens():
    w = make_world("river_crossing")
    br = w.bridges[0]
    br.take_damage(BRIDGE_HP, None)
    eng = Unit(w, "worker", 0, br.x - 120, br.y)
    w._add(eng)
    w.resources[0] = 500
    w.apply(0, ["rebuild", eng.id, br.id, False])
    assert eng.order[0] == "rebuild"
    assert w.resources[0] == 500 - BRIDGE_COST
    assert run(w, 120, until=lambda: br.intact)
    assert br.hp == BRIDGE_HP
    w._rebuild_nav()
    assert not w.nav.is_blocked(*cell(w, br))


def test_cancelling_a_rebuild_refunds():
    w = make_world("river_crossing")
    br = w.bridges[1]
    br.take_damage(BRIDGE_HP, None)
    eng = Unit(w, "worker", 0, br.x - 120, br.y)
    w._add(eng)
    w.resources[0] = 500
    w.apply(0, ["rebuild", eng.id, br.id, False])
    assert w.resources[0] == 500 - BRIDGE_COST
    eng.command(("idle",))
    assert w.resources[0] == 500


def test_a_unit_on_a_collapsing_deck_is_pushed_clear():
    w = make_world("river_crossing")
    br = w.bridges[0]
    u = Unit(w, "marine", 0, br.x, br.y)
    w._add(u)
    w._rebuild_nav()
    br.take_damage(BRIDGE_HP, None)
    run(w, 3)
    x0, y0, x1, y1 = br.rect
    assert not u.dead
    assert not (x0 <= u.x <= x1 and y0 <= u.y <= y1)


def test_breaking_every_crossing_cuts_the_map_in_two():
    y = min(b.y for b in make_world("river_crossing").bridges)
    target = (3600, y)

    def crossing(bridges_up):
        w = make_world("river_crossing")
        if not bridges_up:
            for b in w.bridges:
                b.take_damage(BRIDGE_HP, None)
        w._rebuild_nav()
        scout = Unit(w, "marine", 0, 400, y)
        w._add(scout)
        scout.command(("move", *target))
        arrived = lambda: math.hypot(scout.x - target[0], scout.y - target[1]) < 80
        return run(w, 240 if bridges_up else 120, until=arrived), scout.x

    assert crossing(True)[0]
    made_it, x = crossing(False)
    assert not made_it and x < 2000, x


def test_bridge_state_travels_in_snapshots():
    w = make_world("river_crossing")
    w.bridges[1].take_damage(BRIDGE_HP, None)
    snap = net.snapshot_for(w, 0, w.events)
    assert [b[1] for b in snap["br"]] == [1, 0, 1]
    assert any(e[0] == "bridge" and e[2] == 0 for e in snap["e"])


def test_the_computer_rebuilds_the_crossing_its_attack_needs():
    """With every span down the enemy is unreachable; the computer sends an Engineer to the crossing on its
    route, holds the wave until it stands, and then the route is open again."""
    w = make_world("river_crossing", ai=True, difficulty=1)
    run(w, 5)
    for b in w.bridges:
        b.take_damage(BRIDGE_HP, None)
    w.resources[1] = 400
    ai = w.players[1].ai
    ai._next_route = 0.0
    run(w, 7)
    assert not ai.route_open and ai.route_bridge is not None
    assert any(u.order[0] == "rebuild" for u in w.units if u.team == 1 and u.kind == "worker")
    assert run(w, 240, until=lambda: any(b.intact for b in w.bridges))
    ai._next_route = 0.0
    run(w, 7)
    assert ai.route_open
