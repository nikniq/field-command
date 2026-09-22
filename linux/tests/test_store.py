"""The Armory: kit bought once, worn by every unit of that type, with every effect checked in play."""
from conftest import DT, hq_of, idle_everyone, make_world, run
from fieldcommand import net
from fieldcommand.defs import CARRY_CAP, KITS, KIT_BY_ID, KIT_IDS, SIEGE_RANGE, UNITS
from fieldcommand.entities import Unit


def setup(bank=5000.0):
    w = make_world()
    idle_everyone(w, 0)
    w.resources[0] = bank
    return w, hq_of(w, 0)


def test_catalogue_is_sane():
    assert len(KITS) == 12 and len(set(KIT_IDS)) == 12
    assert all(k.unit in UNITS and k.cost > 0 for k in KITS)
    assert {k.unit for k in KITS} == set(UNITS)


def test_hit_point_kit_is_worn_by_present_and_future_units():
    w, hq = setup()
    veteran = Unit(w, "marine", 0, hq.x + 100, hq.y)
    w._add(veteran)
    veteran.hp = 30
    assert w.buy_kit(0, "flak")
    base = UNITS["marine"].hp
    assert veteran.max_hp == base * 1.25 and veteran.hp == 30 + base * 0.25
    recruit = Unit(w, "marine", 0, hq.x + 140, hq.y)
    assert recruit.max_hp == base * 1.25 and recruit.hp == recruit.max_hp


def test_damage_speed_range_and_reload_kit():
    w, hq = setup()
    for kid in ("hollowpoint", "boots", "scope", "autoloader", "barrel"):
        assert w.buy_kit(0, kid)
    r = Unit(w, "marine", 0, hq.x + 100, hq.y)
    sn = Unit(w, "sniper", 0, hq.x + 100, hq.y + 50)
    t = Unit(w, "tank", 0, hq.x + 100, hq.y + 100)
    assert r.vet_mult == 1.2 and r.speed == UNITS["marine"].speed * 1.15
    assert sn.attack_range == UNITS["sniper"].range + 30
    assert t.attack_range == UNITS["tank"].range + 20
    t.mode = 2
    assert t.attack_range == SIEGE_RANGE + 20
    enemy = Unit(w, "worker", 1, t.x + 150, t.y)
    w._add(t); w._add(enemy)
    t.mode = 0
    t._fire(enemy)
    assert abs(t.cooldown - UNITS["tank"].cooldown * 0.8) < 1e-9      # 20% shorter reload


def test_cargo_rig_and_power_tools():
    w, hq = setup()
    eng = Unit(w, "worker", 0, hq.x + 100, hq.y)
    w._add(eng)
    assert eng.carry_cap == CARRY_CAP and eng.work_mult == 1.0
    w.buy_kit(0, "cargorig")
    w.buy_kit(0, "powertools")
    assert eng.carry_cap == CARRY_CAP + 4 and abs(eng.work_mult - 1.3) < 1e-9


def test_price_once_and_only_with_crystal():
    w, hq = setup(bank=250.0)
    assert not w.buy_kit(0, "scope")            # 300: cannot afford
    assert w.buy_kit(0, "flak") and w.resources[0] == 50
    assert not w.buy_kit(0, "flak")             # never twice
    assert not w.buy_kit(0, "nope")


def test_kit_travels_in_snapshots_as_a_mask():
    w, hq = setup()
    w.buy_kit(0, "flak")
    w.buy_kit(0, "scope")
    snap = net.snapshot_for(w, 0, [])
    assert snap["kit"] == (1 << KIT_IDS.index("flak")) | (1 << KIT_IDS.index("scope"))
    assert net.snapshot_for(w, 1, [])["kit"] == 0
