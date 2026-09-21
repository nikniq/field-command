"""Engineers repairing buildings: speed, cost, stacking and refusals."""
from conftest import hq_of, idle_everyone, make_world, run
from fieldcommand import net
from fieldcommand.defs import BUILDINGS, REPAIR_COST_RATIO, REPAIR_TIME
from fieldcommand.entities import Unit


def damaged_hq(bank=1000.0):
    w = make_world()
    hq = hq_of(w, 0)
    hq.hp = hq.max_hp * 0.5
    idle_everyone(w, 0)
    w.resources[0] = bank
    return w, hq


def engineer(w, hq, dy=0):
    e = Unit(w, "worker", 0, hq.x + 140, hq.y + dy)
    w._add(e)
    return e


def test_one_engineer_repairs_half_a_command_center_at_the_advertised_price():
    w, hq = damaged_hq()
    e = engineer(w, hq)
    w.apply(0, ["repair", [e.id], hq.id, False])
    assert e.order[0] == "repair"
    assert run(w, 40, until=lambda: hq.hp >= hq.max_hp)
    spent = 1000 - w.resources[0]
    assert abs(spent - 0.5 * BUILDINGS["hq"].cost * REPAIR_COST_RATIO) < 0.5
    assert e.order[0] != "repair"          # back to what it was doing


def test_three_engineers_stack():
    w, hq = damaged_hq()
    crew = [engineer(w, hq, dy) for dy in (-40, 0, 40)]
    w.apply(0, ["repair", [c.id for c in crew], hq.id, False])
    t0 = w.elapsed
    assert run(w, 40, until=lambda: hq.hp >= hq.max_hp)
    assert w.elapsed - t0 < REPAIR_TIME * 0.5 * 0.8


def test_repair_stops_without_crystal_rather_than_going_into_debt():
    w, hq = damaged_hq(bank=3.0)
    e = engineer(w, hq)
    w.apply(0, ["repair", [e.id], hq.id, False])
    told = []
    for _ in range(20 * 30):
        w.step(1 / 30)
        told += [ev[2] for ev in w.events if ev[0] == "msg" and ev[1] == 0]
        w.events.clear()
        if e.order[0] != "repair":
            break
    assert w.resources[0] >= 0 and hq.hp < hq.max_hp
    assert any("Not enough crystal" in m for m in told)


def test_enemy_buildings_and_construction_sites_are_refused():
    w = make_world()
    hq = hq_of(w, 0)
    enemy = hq_of(w, 1)
    enemy.hp = 500
    e = engineer(w, hq)
    w.apply(0, ["repair", [e.id], enemy.id, False])
    assert e.order[0] != "repair"
    site = w.start_building("depot", hq.x + 400, hq.y, 0)
    w.apply(0, ["repair", [e.id], site.id, False])
    assert e.order[0] != "repair"


def test_the_order_has_a_status_code_and_a_status_line():
    w, hq = damaged_hq()
    e = engineer(w, hq)
    w.apply(0, ["repair", [e.id], hq.id, False])
    snap = net.snapshot_for(w, 0, [])
    assert snap["o"][str(e.id)][0] == net.STATUS["repair"]
    assert e.status_text() == "Repairing Command Center"
