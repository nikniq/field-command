"""Alloy: the second resource, mined from gold, spent on heavy armour, aircraft, the big guns and tech."""
import math

from conftest import hq_of, idle_everyone, make_world, run
from fieldcommand import net
from fieldcommand.ai import AI
from fieldcommand.defs import ALLOY_BUILD, ALLOY_COST, ALLOY_START, ALLOY_UPGRADE, BUILDINGS, UNITS, upgrade_cost
from fieldcommand.entities import Unit


def setup():
    w = make_world()
    hq = hq_of(w, 0)
    idle_everyone(w, 0)
    w.resources[0] = 5000
    return w, hq


def factory(w, hq):
    b = w.start_building("factory", hq.x + 400, hq.y, 0)
    b.built, b.progress, b.hp = True, 1.0, b.max_hp
    bk = w.start_building("barracks", hq.x + 400, hq.y + 250, 0)
    bk.built, bk.progress, bk.hp = True, 1.0, bk.max_hp
    return b


def test_every_side_starts_with_some_alloy_and_the_prices_are_set():
    w, hq = setup()
    assert w.alloy == {0: ALLOY_START, 1: ALLOY_START} and ALLOY_START == 100
    assert set(ALLOY_COST) == {"tank", "gunship"} and set(ALLOY_BUILD) == {"artillery"}
    assert set(ALLOY_UPGRADE) == {"guns", "entrench", "stabilise"}


def test_gold_yields_alloy_and_crystal_yields_crystal():
    w, hq = setup()
    gold = next(c for c in w.crystals if c.gold)
    plain = next(c for c in w.crystals if not c.gold)
    e = Unit(w, "worker", 0, gold.x + 30, gold.y)
    w._add(e)
    e.carrying = e.carry_cap
    e.home_crystal = gold
    e.command(("return",))
    e.x, e.y = hq.x + hq.half + 4, hq.y
    a0, c0 = w.alloy[0], w.resources[0]
    run(w, 1)
    assert w.alloy[0] == a0 + e.carry_cap and w.resources[0] == c0
    e.carrying = e.carry_cap
    e.home_crystal = plain
    e.command(("return",))
    e.x, e.y = hq.x + hq.half + 4, hq.y
    run(w, 1)
    assert w.alloy[0] == a0 + e.carry_cap and w.resources[0] == c0 + e.carry_cap


def test_tanks_cost_alloy_and_the_bank_says_no_when_it_is_empty():
    w, hq = setup()
    fc = factory(w, hq)
    w.alloy[0] = ALLOY_COST["tank"] - 1
    assert not w.train("tank", [fc], 0) and not fc.queue
    assert any(ev[0] == "msg" and "alloy" in ev[2] for ev in w.events)
    w.alloy[0] = ALLOY_COST["tank"]
    assert w.train("tank", [fc], 0) and fc.queue == ["tank"] and w.alloy[0] == 0
    w.cancel_queue(fc, 0)
    assert w.alloy[0] == ALLOY_COST["tank"]                                # cancelled: the alloy comes back
    assert w.train("marine", [fc if False else [b for b in w.buildings if b.kind == "barracks"][0]], 0)


def test_artillery_and_tech_take_alloy_too_and_hand_it_back_when_undone():
    w, hq = setup()
    fc = factory(w, hq)
    e = [u for u in w.units if u.team == 0 and u.kind == "worker"][0]
    w.update_visibility()
    spot = next((hq.x + dx, hq.y + dy) for dx in range(-300, 301, 50) for dy in range(-300, 301, 50)
                if w.can_place("artillery", hq.x + dx, hq.y + dy) and w.fog_for(0).is_explored(hq.x + dx, hq.y + dy))
    w.alloy[0] = 10
    w.apply(0, ["build", e.id, "artillery", spot[0], spot[1], False])
    assert e.order[0] != "build"
    w.alloy[0] = ALLOY_BUILD["artillery"] + 5
    w.apply(0, ["build", e.id, "artillery", spot[0], spot[1], False])
    assert e.order[0] == "build" and w.alloy[0] == 5
    e.command(("idle",))                                                  # the order dropped: refunded
    assert w.alloy[0] == ALLOY_BUILD["artillery"] + 5
    w.alloy[0] = ALLOY_UPGRADE["stabilise"]
    w.apply(0, ["upgrade", [fc.id], "stabilise"])
    assert fc.upgrading == "stabilise" and w.alloy[0] == 0
    fc.cancel_upgrade()
    assert w.alloy[0] == ALLOY_UPGRADE["stabilise"]


def test_alloy_travels_on_the_wire_and_in_saves():
    from fieldcommand.save import world_to_dict, world_from_dict
    w, hq = setup()
    w.alloy[0] = 77
    assert net.snapshot_for(w, 0, [])["al"] == 77
    w2 = world_from_dict(world_to_dict(w))
    assert w2.alloy[0] == 77 and w2.alloy[1] == ALLOY_START


def test_the_computer_puts_two_engineers_on_the_gold_once_it_has_a_factory():
    w = make_world()
    hq = hq_of(w, 1)
    ai = AI(w, 1)
    w.players[1].is_ai, w.players[1].ai = True, ai
    for _ in range(4):
        w._add(Unit(w, "worker", 1, hq.x - 100, hq.y + 80))
    fc = w.start_building("factory", hq.x - 400, hq.y, 1)
    fc.built, fc.progress, fc.hp = True, 1.0, fc.max_hp
    ai.think = 0
    ai.update(0.1)
    assert len(ai.gold_miners) == 2 and all(m.order[0] == "gather" and m.order[1].gold for m in ai.gold_miners)
