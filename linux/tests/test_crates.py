"""Supply crates: they drop on open ground, the first unit to reach one collects its gift, they expire, travel
on the wire only while seen, and survive a save."""
from conftest import hq_of, idle_everyone, make_world, run
from fieldcommand import net, save
from fieldcommand.defs import CRATE_FIRST, CRATE_LIFE, CRATE_SQUAD
from fieldcommand.entities import Unit


def field():
    w = make_world()
    idle_everyone(w, 0)
    idle_everyone(w, 1)
    return w


def test_the_first_crate_drops_on_open_ground_away_from_bases():
    w = field()
    run(w, CRATE_FIRST + 1)
    assert len(w.crates) == 1
    c = w.crates[0]
    assert not w.nav.is_blocked(int(c.x // 40), int(c.y // 40))
    assert all(((b.x - c.x) ** 2 + (b.y - c.y) ** 2) ** 0.5 >= 600 for b in w.buildings)
    assert c.id in w.by_id


def test_the_first_unit_to_reach_a_crate_collects_it():
    w = field()
    cash = w.drop_crate("crystal")
    bank = w.resources[0]
    runner = Unit(w, "marine", 0, cash.x + 60, cash.y)
    w._add(runner)
    runner.command(("move", cash.x, cash.y))
    assert run(w, 6, until=lambda: cash.dead)
    assert w.resources[0] == bank + cash.amount and cash not in w.crates
    squad = w.drop_crate("squad")
    before = sum(1 for u in w.units if u.team == 0 and u.kind == "marine")
    eng = Unit(w, "worker", 0, squad.x + 60, squad.y)
    w._add(eng)
    eng.command(("move", squad.x, squad.y))
    heard = []
    for _ in range(6 * 30):
        w.step(1 / 30)
        heard += [e for e in w.events if e[0] == "crate"]
        w.events.clear()
        if squad.dead:
            break
    assert squad.dead
    assert sum(1 for u in w.units if u.team == 0 and u.kind == "marine") == before + CRATE_SQUAD
    ev = heard[0]
    assert ev[1] == 0 and ev[4] == "squad"
    assert net.event_visible(w, 0, ev)          # the taker's side always hears of it
    tank = w.drop_crate("tank")
    t = Unit(w, "marine", 1, tank.x + 60, tank.y)
    w._add(t)
    t.command(("move", tank.x, tank.y))
    assert run(w, 6, until=lambda: tank.dead)
    assert any(u.team == 1 and u.kind == "tank" for u in w.units)


def test_crates_expire_travel_only_when_seen_and_survive_a_save():
    w = field()
    old = w.drop_crate("tank")
    run(w, CRATE_LIFE + 2)
    assert old.dead and old not in w.crates
    c = w.drop_crate("crystal")
    snap = net.snapshot_for(w, 0, [])
    seen = w.fog_for(0).is_visible(c.x, c.y)
    assert (c.id in [row[0] for row in snap["cr"]]) == seen
    w2 = save.world_from_dict(save.world_to_dict(w, "crates"))
    assert any(k.id == c.id and k.kind == "crystal" and k.amount == c.amount for k in w2.crates)
    assert w2.next_crate == w.next_crate


def test_the_computer_walks_a_trooper_to_a_crate_it_can_see():
    w = make_world(ai=True)
    run(w, 2)
    hq = hq_of(w, 1)
    c = w.drop_crate("crystal")
    c.x, c.y = hq.x - 300, hq.y            # in sight of the base
    w.update_visibility()
    r = Unit(w, "marine", 1, hq.x - 100, hq.y)
    w._add(r)
    r.command(("idle",))
    assert run(w, 20, until=lambda: c.dead)
