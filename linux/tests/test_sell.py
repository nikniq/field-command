"""Cancelling a building under construction and selling a finished one."""
from conftest import hq_of, idle_everyone, make_world, run
from fieldcommand.defs import BUILDINGS, GAS_BUILD, SELL_FRACTION, UNITS, UPGRADES, upgrade_cost
from fieldcommand.entities import Unit


def setup():
    w = make_world()
    hq = hq_of(w, 0)
    idle_everyone(w, 0)
    w.resources[0] = 5000
    w.gas[0] = 100
    return w, hq


def test_cancelling_a_site_returns_what_has_not_been_built_yet():
    w, hq = setup()
    for kind, dy in (("barracks", -250), ("factory", 250)):                    # Artillery needs a Factory
        b = w.start_building(kind, hq.x + 400, hq.y + dy, 0)
        b.built, b.progress, b.hp = True, 1.0, b.max_hp
    e = next(u for u in w.units if u.team == 0 and u.kind == "worker")
    w.update_visibility()
    spot = next((hq.x + dx, hq.y + dy) for dx in range(-300, 301, 50) for dy in range(-300, 301, 50)
                if w.can_place("artillery", hq.x + dx, hq.y + dy) and w.fog_for(0).is_explored(hq.x + dx, hq.y + dy))
    w.apply(0, ["build", e.id, "artillery", spot[0], spot[1], False])
    run(w, 40, until=lambda: any(b.kind == "artillery" for b in w.buildings))
    site = next(b for b in w.buildings if b.kind == "artillery")
    run(w, BUILDINGS["artillery"].build_time * 0.4)
    assert 0.3 < site.progress < 0.5 and not site.built
    c0, g0 = w.resources[0], w.gas[0]
    w.apply(0, ["cancelbuild", site.id])
    assert site.dead and site not in w.buildings and site.id not in w.by_id
    assert abs(w.resources[0] - c0 - BUILDINGS["artillery"].cost * (1 - site.progress)) <= 1
    assert abs(w.gas[0] - g0 - GAS_BUILD["artillery"] * (1 - site.progress)) <= 1
    assert any(ev[0] == "msg" and "cancelled" in ev[2] for ev in w.events)
    run(w, 1)
    assert e.order[0] != "build"                                                # the Engineer is free again


def test_selling_a_finished_building_pays_half_and_refunds_its_work():
    w, hq = setup()
    bk = w.start_building("barracks", hq.x + 400, hq.y, 0)
    bk.built, bk.progress, bk.hp = True, 1.0, bk.max_hp
    w.train("marine", [bk], 0)
    w.apply(0, ["upgrade", [bk.id], "hp"])
    c0, g0 = w.resources[0], w.gas[0]
    assert not w.cancel_building(bk)                                           # finished: cancel is not the tool
    w.apply(0, ["sell", bk.id])
    back = int(BUILDINGS["barracks"].cost * SELL_FRACTION) + UNITS["marine"].cost + upgrade_cost("hp", "barracks")
    assert w.resources[0] == c0 + back and w.gas[0] == g0
    assert bk.dead
    run(w, 0.1)
    assert bk not in w.buildings and any(ev[0] == "rubble" for ev in w.events) or bk not in w.buildings


def test_selling_is_yours_alone_and_a_site_cannot_be_sold():
    w, hq = setup()
    enemy = hq_of(w, 1)
    w.apply(0, ["sell", enemy.id])
    assert not enemy.dead
    site = w.start_building("depot", hq.x + 300, hq.y, 0)
    assert not w.sell_building(site) and not site.dead
    w.apply(1, ["cancelbuild", site.id])
    assert not site.dead


def test_selling_the_last_command_center_is_the_end():
    w, hq = setup()
    for b in list(w.buildings):
        if b.team == 0 and b is not hq:
            b.dead = True
    w._cleanup_dead()
    w.apply(0, ["sell", hq.id])
    run(w, 0.2)
    assert not w.players[0].alive and w.game_over
