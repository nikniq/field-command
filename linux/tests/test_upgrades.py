"""Building upgrades: each effect, the research time and price, and the rules around buying them."""
from conftest import hq_of, idle_everyone, make_world, run
from fieldcommand import net
from fieldcommand.defs import (ARMOR_FACTOR, BUILDINGS, DEPOT_UPGRADED_SUPPLY, TURRET_UPGRADED_DAMAGE,
                               TURRET_UPGRADED_RANGE, UPGRADES, UPGRADE_KINDS, upgrade_cost)
from fieldcommand.entities import Unit


def setup(kind="hq"):
    w = make_world()
    hq = hq_of(w, 0)
    idle_everyone(w, 0)
    w.resources[0] = 5000
    if kind == "hq":
        return w, hq
    b = w.start_building(kind, hq.x + 400, hq.y, 0)
    b.built, b.progress, b.hp = True, 1.0, b.max_hp
    return w, b


def buy(w, b, kind):
    w.apply(0, ["upgrade", [b.id], kind])
    assert b.upgrading == kind, (kind, b.upgrading)
    assert run(w, UPGRADES[kind].time + 1, until=lambda: kind in b.upgrades)


def test_reinforce_doubles_hit_points_and_keeps_the_building_sound():
    w, hq = setup()
    hq.hp = 1000
    buy(w, hq, "hp")
    assert hq.max_hp == 3000 and hq.hp == 2500


def test_armour_plating_takes_30_percent_less():
    w, hq = setup()
    buy(w, hq, "armor")
    hq.take_damage(100, None)
    assert hq.hp == hq.max_hp - 100 * ARMOR_FACTOR


def test_assembly_line_trains_twice_as_fast():
    def train_time(upgraded):
        w, hq = setup()
        if upgraded:
            buy(w, hq, "prod")
        w.train("worker", [hq], 0)
        t0 = w.elapsed
        n0 = sum(1 for u in w.units if u.team == 0)
        run(w, 30, until=lambda: sum(1 for u in w.units if u.team == 0) > n0)
        return w.elapsed - t0
    assert abs(train_time(True) * 2 - train_time(False)) < 0.2


def test_expanded_storage_doubles_a_depot():
    w, depot = setup("depot")
    before = w.supply_cap(0)
    buy(w, depot, "supply")
    assert w.supply_cap(0) == before + DEPOT_UPGRADED_SUPPLY
    assert depot.supply == BUILDINGS["depot"].supply * 2


def test_twin_cannon_hits_harder_and_further():
    w, turret = setup("turret")
    buy(w, turret, "guns")
    assert turret.turret_damage == TURRET_UPGRADED_DAMAGE and turret.turret_range == TURRET_UPGRADED_RANGE
    victim = Unit(w, "marine", 1, turret.x + 240, turret.y)     # outside the stock 210, inside 260
    w._add(victim)
    w.update_visibility()
    assert run(w, 10, until=lambda: victim.dead)


def test_price_and_time_are_as_advertised():
    w, hq = setup()
    bank = w.resources[0]
    t0 = w.elapsed
    buy(w, hq, "hp")
    assert bank - w.resources[0] == upgrade_cost("hp", "hq") == round(BUILDINGS["hq"].cost * 0.6)
    assert abs((w.elapsed - t0) - UPGRADES["hp"].time) < 0.2


def test_one_at_a_time_never_twice_and_only_where_it_applies():
    w, hq = setup()
    w.apply(0, ["upgrade", [hq.id], "hp"])
    w.apply(0, ["upgrade", [hq.id], "armor"])
    assert hq.upgrading == "hp"                       # busy
    run(w, UPGRADES["hp"].time + 1)
    bank = w.resources[0]
    w.apply(0, ["upgrade", [hq.id], "hp"])
    assert hq.upgrading is None and w.resources[0] == bank    # already installed: nothing charged
    w.apply(0, ["upgrade", [hq.id], "guns"])
    assert hq.upgrading is None                        # turrets only
    w.apply(0, ["upgrade", [hq.id], "supply"])
    assert hq.upgrading is None                        # depots only


def test_cancelling_refunds():
    w, hq = setup()
    bank = w.resources[0]
    w.apply(0, ["upgrade", [hq.id], "armor"])
    run(w, 5)
    w.apply(0, ["cancelup", hq.id])
    assert hq.upgrading is None and w.resources[0] == bank


def test_not_enough_crystal():
    w, hq = setup()
    w.resources[0] = 10
    w.apply(0, ["upgrade", [hq.id], "hp"])
    assert hq.upgrading is None and w.resources[0] == 10


def test_upgrades_travel_in_snapshots():
    w, hq = setup()
    buy(w, hq, "armor")
    w.apply(0, ["upgrade", [hq.id], "hp"])
    snap = net.snapshot_for(w, 0, [])
    row = next(r for r in snap["b"] if r[0] == hq.id)
    assert row[12] == 1 << UPGRADE_KINDS.index("armor")
    assert row[13][0] == UPGRADE_KINDS.index("hp")
