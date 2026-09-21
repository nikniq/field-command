"""Siege mode: the transition, the longer reach, the blind spot, auto-unsiege on a move, and the wire."""
from conftest import DT, hq_of, make_world, run
from fieldcommand import net
from fieldcommand.defs import (MODE_MOBILE, MODE_SIEGED, MODE_SIEGING, MODE_UNSIEGING, SIEGE_MIN_RANGE,
                               SIEGE_RANGE, SIEGE_TRANSITION, UNITS)
from fieldcommand.entities import Unit


def tank(w, x, y, team=0):
    t = Unit(w, "tank", team, x, y)
    w._add(t)
    w.update_visibility()     # placed after the first fog pass: let it see, as the next tick would
    return t


def test_only_tanks_can_siege():
    w = make_world()
    hq = hq_of(w, 0)
    r = Unit(w, "marine", 0, hq.x + 100, hq.y)
    w._add(r)
    w.apply(0, ["siege", [r.id], True])
    assert r.mode == MODE_MOBILE


def test_digging_in_takes_the_advertised_time_and_stops_everything_meanwhile():
    w = make_world()
    hq = hq_of(w, 0)
    t = tank(w, hq.x + 200, hq.y)
    w.apply(0, ["siege", [t.id], True])
    assert t.mode == MODE_SIEGING and t.status_text() == "Digging in"
    enemy = Unit(w, "marine", 1, t.x + 150, t.y)    # in reach, but nothing fires while switching
    w._add(enemy)
    hp0 = enemy.hp
    run(w, SIEGE_TRANSITION - 0.2)
    assert t.mode == MODE_SIEGING and enemy.hp == hp0
    run(w, 0.4)
    assert t.mode == MODE_SIEGED and t.attack_range == SIEGE_RANGE and t.status_text().startswith("Sieged")


def test_a_sieged_tank_outranges_a_sniper_and_a_mobile_one_does_not():
    assert UNITS["tank"].range < UNITS["sniper"].range < SIEGE_RANGE


def test_a_sieged_tank_hits_at_long_range_and_holds_position():
    w = make_world()
    hq = hq_of(w, 0)
    t = tank(w, hq.x + 200, hq.y)
    t.mode = MODE_SIEGED
    victim = Unit(w, "marine", 1, t.x + 300, t.y)   # beyond the mobile 230, inside the sieged 340
    w._add(victim)
    victim.order = ("idle",)
    x0 = t.x
    w.apply(0, ["attack", [t.id], victim.id, False])
    assert run(w, 15, until=lambda: victim.dead)
    assert t.x == x0 and t.sieged


def test_the_blind_spot_is_real():
    w = make_world()
    hq = hq_of(w, 0)
    t = tank(w, hq.x + 200, hq.y)
    t.mode = MODE_SIEGED
    close = Unit(w, "worker", 1, t.x + 40, t.y)     # inside the 90 minimum
    w._add(close)
    close.order = ("idle",)
    w.apply(0, ["attack", [t.id], close.id, False])
    run(w, 8)
    assert not close.dead and t.x == hq.x + 200
    assert not t.in_range(close) and SIEGE_MIN_RANGE > 0


def test_a_move_order_packs_the_tank_up_first():
    w = make_world()
    hq = hq_of(w, 0)
    t = tank(w, hq.x + 200, hq.y)
    t.mode = MODE_SIEGED
    w.apply(0, ["move", [t.id], hq.x + 700, hq.y, False, False])
    run(w, DT)
    assert t.mode == MODE_UNSIEGING and t.status_text() == "Packing up"
    run(w, SIEGE_TRANSITION + 0.2)
    assert t.mode == MODE_MOBILE
    x1 = t.x
    run(w, 2)
    assert t.x > x1 + 30       # and then it goes


def test_sieged_shells_hit_harder():
    def damage_from(sieged):
        w = make_world()
        hq = hq_of(w, 0)
        t = tank(w, hq.x + 200, hq.y)
        t.mode = MODE_SIEGED if sieged else MODE_MOBILE
        target = hq_of(w, 1)
        target.x, target.y = t.x + 200, t.y     # parked in range for both modes, outside the blind spot
        target.rect = (target.x - target.half, target.y - target.half, target.x + target.half, target.y + target.half)
        w.apply(0, ["attack", [t.id], target.id, False])
        hp0 = target.hp
        run(w, 6)
        return hp0 - target.hp
    assert damage_from(True) > damage_from(False) > 0


def test_mode_travels_in_snapshots():
    w = make_world()
    hq = hq_of(w, 0)
    t = tank(w, hq.x + 200, hq.y)
    t.mode = MODE_SIEGED
    snap = net.snapshot_for(w, 0, [])
    row = next(r for r in snap["u"] if r[0] == t.id)
    assert row[9] == MODE_SIEGED
