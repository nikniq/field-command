"""Tech: researched once, and the whole side's army changes — Rangers and Snipers dig in, tanks fire on the move."""
import math

from conftest import hq_of, idle_everyone, make_world, run
from fieldcommand import net
from fieldcommand.ai import AI
from fieldcommand.defs import ENTRENCH_FACTOR, ENTRENCH_KINDS, ENTRENCH_TIME, TECH, UPGRADES, UPGRADE_KINDS, upgrade_applies
from fieldcommand.entities import Unit


def setup(kind):
    w = make_world()
    hq = hq_of(w, 0)
    idle_everyone(w, 0)
    for u in list(w.units):
        u.command(("idle",))
        u.cooldown = 1e9
    w.resources[0] = 5000
    b = w.start_building(kind, hq.x + 400, hq.y, 0)
    b.built, b.progress, b.hp = True, 1.0, b.max_hp
    return w, hq, b


def spawn(w, kind, team, x, y, armed=False):
    u = Unit(w, kind, team, x, y)
    w._add(u)
    u.command(("idle",))
    if not armed:
        u.cooldown = 1e9
    return u


def research(w, b, kind):
    w.apply(0, ["upgrade", [b.id], kind])
    assert b.upgrading == kind
    assert run(w, UPGRADES[kind].time + 1, until=lambda: kind in b.upgrades)


def test_the_two_techs_are_in_the_catalogue_at_their_buildings():
    assert TECH == ("entrench", "stabilise") and UPGRADE_KINDS[-2:] == list(TECH)
    assert upgrade_applies("entrench", "barracks") and not upgrade_applies("entrench", "factory")
    assert upgrade_applies("stabilise", "factory") and not upgrade_applies("stabilise", "barracks")
    assert UPGRADES["entrench"].flat and UPGRADES["stabilise"].flat


def test_entrenched_infantry_that_holds_still_takes_less():
    w, hq, bk = setup("barracks")
    r = spawn(w, "marine", 0, hq.x + 200, hq.y + 300)
    foe = spawn(w, "marine", 1, r.x + 100, r.y)
    run(w, ENTRENCH_TIME + 1)
    assert not r.dug_in                                               # no tech yet
    hp = r.hp
    r.take_damage(10, foe)
    assert math.isclose(hp - r.hp, 10)
    research(w, bk, "entrench")
    assert w.has_tech("entrench", 0) and r.still_for >= ENTRENCH_TIME and r.dug_in
    hp = r.hp
    r.take_damage(10, foe)
    assert math.isclose(hp - r.hp, 10 * ENTRENCH_FACTOR)
    assert r.status_text().endswith("dug in")
    r.command(("move", r.x + 200, r.y))
    run(w, 1)
    assert r.still_for < ENTRENCH_TIME and not r.dug_in
    hp = r.hp
    r.take_damage(10, foe)
    assert math.isclose(hp - r.hp, 10)                                # on the move: no protection


def test_tanks_and_engineers_do_not_dig_in():
    w, hq, bk = setup("barracks")
    research(w, bk, "entrench")
    t = spawn(w, "tank", 0, hq.x + 200, hq.y + 300)
    e = spawn(w, "worker", 0, hq.x + 260, hq.y + 300)
    run(w, ENTRENCH_TIME + 1)
    assert not t.dug_in and not e.dug_in and set(ENTRENCH_KINDS) == {"marine", "sniper"}


def test_tech_is_bought_once_for_the_whole_side():
    w, hq, bk = setup("barracks")
    bk2 = w.start_building("barracks", hq.x + 400, hq.y + 250, 0)
    bk2.built, bk2.progress, bk2.hp = True, 1.0, bk2.max_hp
    assert bk2.can_upgrade("entrench")
    research(w, bk, "entrench")
    assert not bk2.can_upgrade("entrench")
    before = w.resources[0]
    w.apply(0, ["upgrade", [bk2.id], "entrench"])
    assert bk2.upgrading is None and w.resources[0] == before
    # The bit travels in the building's upgrade mask.
    snap = net.snapshot_for(w, 0, [])
    row = next(b for b in snap["b"] if b[0] == bk.id)
    assert row[12] & (1 << UPGRADE_KINDS.index("entrench"))          # the installed-upgrades mask


def test_stabilised_tanks_fire_on_the_move():
    w, hq, fc = setup("factory")
    t = spawn(w, "tank", 0, hq.x + 200, hq.y + 400, armed=True)
    target = spawn(w, "marine", 1, hq.x + 500, hq.y + 520)             # beside the road the tank will drive
    hp = target.hp
    t.command(("move", hq.x + 800, hq.y + 400))
    run(w, 4)
    assert target.hp == hp                                            # no tech: a moving tank holds its fire
    t.command(("move", hq.x + 200, hq.y + 400))
    run(w, 10, until=lambda: t.order[0] == "idle")
    research(w, fc, "stabilise")
    t.command(("move", hq.x + 800, hq.y + 400))
    run(w, 4, until=lambda: target.hp < hp)
    assert target.hp < hp and t.order[0] == "move"                     # it fired and kept driving


def test_the_computer_researches_both():
    w, hq, bk = setup("barracks")
    fc = w.start_building("factory", hq.x + 400, hq.y + 250, 0)
    fc.built, fc.progress, fc.hp = True, 1.0, fc.max_hp
    ai = AI(w, 0)
    bases = [b for b in w.buildings if b.team == 0]
    for b in bases:
        b.upgrades.add("prod")
    w.resources[0] = 5000
    ai._upgrade(hq, bases)
    assert bk.upgrading == "entrench"
    bk.upgrades.add("entrench")
    bk.upgrading = None
    ai._upgrade(hq, bases)
    assert fc.upgrading == "stabilise"
