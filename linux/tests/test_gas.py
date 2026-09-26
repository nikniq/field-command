"""Gas: the second resource, drawn from Refineries built anywhere, spent on heavy armour, aircraft, the big guns and tech."""
import math

from conftest import hq_of, idle_everyone, make_world, run
from fieldcommand import net
from fieldcommand.ai import AI
from fieldcommand.defs import BUILDINGS, BUILD_MENU, GAS_BUILD, GAS_COST, GAS_RATE, GAS_START, GAS_UPGRADE, UNITS
from fieldcommand.entities import Unit


def setup():
    w = make_world()
    hq = hq_of(w, 0)
    idle_everyone(w, 0)
    w.resources[0] = 5000
    return w, hq


def stand(w, kind, x, y, team=0):
    b = w.start_building(kind, x, y, team)
    b.built, b.progress, b.hp = True, 1.0, b.max_hp
    return b


def factory(w, hq):
    b = stand(w, "factory", hq.x + 400, hq.y)
    stand(w, "barracks", hq.x + 400, hq.y + 250)
    return b


def test_every_side_starts_with_some_gas_and_the_prices_are_set():
    w, hq = setup()
    assert w.gas == {0: GAS_START, 1: GAS_START} and GAS_START == 100
    assert set(GAS_COST) == {"tank", "gunship"} and set(GAS_BUILD) == {"artillery"}
    assert set(GAS_UPGRADE) == {"guns", "entrench", "stabilise"}
    s = BUILDINGS["refinery"]
    assert "refinery" in BUILD_MENU and s.requires is None and s.cost == 150 and GAS_RATE == 0.5
    assert s.hotkey not in {BUILDINGS[k].hotkey for k in BUILD_MENU if k != "refinery"}


def test_a_refinery_draws_gas_anywhere_and_gold_yields_crystal():
    w, hq = setup()
    e = next(u for u in w.units if u.team == 0 and u.kind == "worker")
    w.apply(0, ["build", e.id, "refinery", hq.x + 250, hq.y + 150, False])
    assert e.order[0] == "build" and e.order[1] == "refinery"
    run(w, 60, until=lambda: any(b.kind == "refinery" and b.built for b in w.buildings))
    r = next(b for b in w.buildings if b.kind == "refinery")
    assert r.built
    g0 = w.gas[0]
    run(w, 10)
    assert math.isclose(w.gas[0] - g0, GAS_RATE * 10, rel_tol=0.05)
    r2 = stand(w, "refinery", hq.x - 300, hq.y - 200)                       # a second one anywhere doubles it
    g1 = w.gas[0]
    run(w, 10)
    assert math.isclose(w.gas[0] - g1, GAS_RATE * 20, rel_tol=0.05)
    # Gold is minerals again: a trip from a gold node pays crystal, and no gas.
    gold = next(c for c in w.crystals if c.gold)
    m = Unit(w, "worker", 0, gold.x + 30, gold.y)
    w._add(m)
    m.carrying = m.carry_cap
    m.home_crystal = gold
    m.command(("return",))
    m.x, m.y = hq.x + hq.half + 4, hq.y
    c0, g2 = w.resources[0], w.gas[0]
    run(w, 1)
    assert w.resources[0] == c0 + m.carry_cap and w.gas[0] - g2 < GAS_RATE * 2.5


def test_tanks_cost_gas_and_the_bank_says_no_when_it_is_empty():
    w, hq = setup()
    fc = factory(w, hq)
    w.gas[0] = GAS_COST["tank"] - 1
    assert not w.train("tank", [fc], 0) and not fc.queue
    assert any(ev[0] == "msg" and "Refinery" in ev[2] for ev in w.events)
    w.gas[0] = GAS_COST["tank"]
    assert w.train("tank", [fc], 0) and fc.queue == ["tank"] and w.gas[0] == 0
    w.cancel_queue(fc, 0)
    assert w.gas[0] == GAS_COST["tank"]                                       # cancelled: the gas comes back


def test_artillery_and_tech_take_gas_too_and_hand_it_back_when_undone():
    w, hq = setup()
    fc = factory(w, hq)
    e = next(u for u in w.units if u.team == 0 and u.kind == "worker")
    w.update_visibility()
    spot = next((hq.x + dx, hq.y + dy) for dx in range(-300, 301, 50) for dy in range(-300, 301, 50)
                if w.can_place("artillery", hq.x + dx, hq.y + dy) and w.fog_for(0).is_explored(hq.x + dx, hq.y + dy))
    w.gas[0] = 10
    w.apply(0, ["build", e.id, "artillery", spot[0], spot[1], False])
    assert e.order[0] != "build"
    w.gas[0] = GAS_BUILD["artillery"] + 5
    w.apply(0, ["build", e.id, "artillery", spot[0], spot[1], False])
    assert e.order[0] == "build" and w.gas[0] == 5
    e.command(("idle",))
    assert w.gas[0] == GAS_BUILD["artillery"] + 5
    w.gas[0] = GAS_UPGRADE["stabilise"]
    w.apply(0, ["upgrade", [fc.id], "stabilise"])
    assert fc.upgrading == "stabilise" and w.gas[0] == 0
    fc.cancel_upgrade()
    assert w.gas[0] == GAS_UPGRADE["stabilise"]


def test_gas_travels_on_the_wire_and_in_saves_old_saves_included():
    from fieldcommand.save import world_to_dict, world_from_dict
    w, hq = setup()
    w.gas[0] = 77
    assert net.snapshot_for(w, 0, [])["gs"] == 77
    d = world_to_dict(w)
    w2 = world_from_dict(d)
    assert w2.gas[0] == 77 and w2.gas[1] == GAS_START
    d["alloy"] = d.pop("gas")                                                 # a save from before the rename
    assert world_from_dict(d).gas[0] == 77


def test_the_computer_builds_a_refinery_after_its_factory():
    w = make_world()
    ai = AI(w, 1)
    def wanted(t, kind):
        return max([n for k, n in ai._plan(t) if k == kind] or [0])
    assert wanted(200, "refinery") == 1 and wanted(200, "factory") == 1
    assert wanted(100, "refinery") == 0 and wanted(500, "refinery") == 2
