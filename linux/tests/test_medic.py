"""Medics heal infantry; Engineers repair Siege Tanks."""
from conftest import hq_of, idle_everyone, make_world, run
from fieldcommand import net, save
from fieldcommand.defs import HEAL_RANGE, HEAL_RATE, REPAIR_COST_RATIO, REPAIR_TIME, UNITS
from fieldcommand.entities import Unit


def field(bank=1000.0):
    w = make_world()
    idle_everyone(w, 0)
    w.resources[0] = bank
    return w, hq_of(w, 0)


def unit(w, kind, team, x, y):
    u = Unit(w, kind, team, x, y)
    w._add(u)
    return u


def test_a_medic_treats_a_wounded_ranger_at_the_advertised_rate():
    w, hq = field()
    m = unit(w, "medic", 0, hq.x + 200, hq.y)
    r = unit(w, "marine", 0, hq.x + 200 + HEAL_RANGE - 5, hq.y)
    r.hp = r.max_hp - 30
    w.apply(0, ["repair", [m.id], r.id, False])
    assert m.order == ("heal", r) and m.status_text() == "Treating Ranger"
    t0 = w.elapsed
    assert run(w, 20, until=lambda: r.hp >= r.max_hp)
    took = w.elapsed - t0
    assert abs(took - 30 / HEAL_RATE) < 1.0
    assert m.order[0] == "idle"


def test_an_idle_medic_finds_the_wounded_by_itself_and_walks_over():
    w, hq = field()
    m = unit(w, "medic", 0, hq.x + 200, hq.y)
    far = unit(w, "sniper", 0, hq.x + 200, hq.y + 180)
    far.hp = 10
    assert run(w, 20, until=lambda: far.hp >= far.max_hp)
    assert m.distance_to(far) - far.radius - m.radius <= HEAL_RANGE + 10


def test_medics_never_shoot_and_tanks_are_not_their_business():
    w, hq = field()
    m = unit(w, "medic", 0, hq.x + 200, hq.y)
    enemy = unit(w, "marine", 1, hq.x + 260, hq.y)
    w.apply(0, ["attack", [m.id], enemy.id, False])
    assert m.order[0] == "amove"            # unarmed: it goes along, it does not engage
    run(w, 3)
    assert enemy.hp == enemy.max_hp and m.kills == 0
    t = unit(w, "tank", 0, hq.x + 200, hq.y + 40)
    t.hp = 100
    w.apply(0, ["repair", [m.id], t.id, False])
    assert m.order[0] != "heal"
    assert UNITS["medic"].damage == 0 and UNITS["medic"].range == 0


def test_a_medic_on_attack_move_stops_for_the_wounded_then_carries_on():
    w, hq = field()
    m = unit(w, "medic", 0, hq.x + 200, hq.y)
    r = unit(w, "marine", 0, hq.x + 300, hq.y + 30)
    r.hp = r.max_hp - 12
    w.apply(0, ["move", [m.id], hq.x + 600, hq.y, False, True])
    assert run(w, 10, until=lambda: m.order[0] == "heal")
    assert run(w, 20, until=lambda: r.hp >= r.max_hp)
    assert m.order[0] == "amove"           # resumes the advance


def test_trauma_kit_speeds_healing():
    w, hq = field()
    w.buy_kit(0, "trauma")
    m = unit(w, "medic", 0, hq.x + 200, hq.y)
    r = unit(w, "marine", 0, hq.x + 230, hq.y)
    r.hp = r.max_hp - 30
    w.apply(0, ["repair", [m.id], r.id, False])
    t0 = w.elapsed
    assert run(w, 20, until=lambda: r.hp >= r.max_hp)
    assert abs((w.elapsed - t0) - 30 / (HEAL_RATE * 1.5)) < 1.0


def test_an_engineer_repairs_a_tank_at_the_repair_price():
    w, hq = field()
    e = unit(w, "worker", 0, hq.x + 200, hq.y)
    t = unit(w, "tank", 0, hq.x + 260, hq.y)
    t.hp = t.max_hp * 0.5
    w.apply(0, ["repair", [e.id], t.id, False])
    assert e.order == ("repair", t) and e.status_text() == "Repairing Siege Tank"
    t0 = w.elapsed
    assert run(w, 40, until=lambda: t.hp >= t.max_hp)
    assert abs((w.elapsed - t0) - REPAIR_TIME * 0.5) < 2.0
    assert abs((1000 - w.resources[0]) - 0.5 * UNITS["tank"].cost * REPAIR_COST_RATIO) < 0.5
    assert e.order[0] != "repair"


def test_an_engineer_follows_a_moving_tank_and_refuses_enemy_and_infantry():
    w, hq = field()
    e = unit(w, "worker", 0, hq.x + 200, hq.y)
    t = unit(w, "tank", 0, hq.x + 240, hq.y)
    t.hp = 50
    w.apply(0, ["repair", [e.id], t.id, False])
    w.apply(0, ["move", [t.id], hq.x + 600, hq.y, False, False])
    run(w, 4)
    assert e.order[0] == "repair" and e.distance_to(t) < 120     # keeping up
    enemy = unit(w, "tank", 1, hq.x + 300, hq.y + 200)
    enemy.hp = 50
    w.apply(0, ["repair", [e.id], enemy.id, False])
    assert e.order[0] != "repair" or e.order[1] is t
    r = unit(w, "marine", 0, hq.x + 200, hq.y + 60)
    r.hp = 10
    w.apply(0, ["repair", [e.id], r.id, False])
    assert not (e.order[0] == "repair" and e.order[1] is r)


def test_orders_survive_the_wire_and_a_save():
    w, hq = field()
    m = unit(w, "medic", 0, hq.x + 200, hq.y)
    r = unit(w, "marine", 0, hq.x + 230, hq.y)
    r.hp = 20
    e = unit(w, "worker", 0, hq.x + 200, hq.y + 60)
    t = unit(w, "tank", 0, hq.x + 260, hq.y + 60)
    t.hp = 100
    w.apply(0, ["repair", [m.id, e.id], r.id, False])
    w.apply(0, ["repair", [e.id], t.id, False])
    snap = net.snapshot_for(w, 0, [])
    assert snap["o"][str(m.id)][0] == net.STATUS["heal"]
    assert snap["o"][str(e.id)][0] == net.STATUS["repair"]
    w2 = save.world_from_dict(save.world_to_dict(w, "medics"))
    m2, e2 = w2.by_id[m.id], w2.by_id[e.id]
    assert m2.order[0] == "heal" and m2.order[1].id == r.id
    assert e2.order[0] == "repair" and e2.order[1].id == t.id


def test_the_computer_fields_medics_with_its_infantry():
    w = make_world(ai=True, difficulty=2)
    run(w, 420, until=lambda: any(u.kind == "medic" and not u.dead for u in w.units))
    assert any(u.kind == "medic" for u in w.units)
