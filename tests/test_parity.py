"""The macOS (Swift) and Linux/Windows (Python) editions must agree on every stat and on the wire order.

Runs from the repository root with only the standard library plus the Python edition:
    python -m pytest tests
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "linux"))

from fieldcommand.defs import (BRIDGE_COST, BRIDGE_HP, BRIDGE_REBUILD_TIME, BUILDINGS,   # noqa: E402
                               BUILDING_KINDS, REPAIR_COST_RATIO, REPAIR_TIME, SIEGE_COOLDOWN, SIEGE_DAMAGE,
                               SIEGE_MIN_RANGE, SIEGE_RANGE, SIEGE_SIGHT, SIEGE_SPLASH, SIEGE_TRANSITION,
                               UNITS, UNIT_KINDS, ARMOR_FACTOR, DEPOT_UPGRADED_SUPPLY, TURRET_UPGRADED_DAMAGE,
                               TURRET_UPGRADED_RANGE, UPGRADES, UPGRADE_KINDS, TOWER_CAPTURE_TIME, TOWER_HALF,
                               TOWER_RADIUS, TOWER_SIGHT, VET_BONUS, VET_THRESHOLDS, REVEAL_RADIUS, REVEAL_TIME)
from fieldcommand import net  # noqa: E402
from fieldcommand.session import lineup_text  # noqa: E402

SWIFT = os.path.join(ROOT, "macos", "Sources", "FieldCommand")


def swift(name):
    with open(os.path.join(SWIFT, name)) as f:
        return f.read()


def swift_stats(src, kind):
    out = {}
    for m in re.finditer(r"return %sStats\(.*?\)\n" % kind, src, re.S):
        body = m.group(0)
        fields = dict(re.findall(r'(\w+): ([-\w."]+)', body))
        out[re.search(r'name: "([^"]+)"', body).group(1)] = fields
    return out


UNIT_FIELDS = [("cost", "cost"), ("supply", "supply"), ("hp", "hp"), ("speed", "speed"), ("range", "range"),
               ("damage", "damage"), ("cooldown", "cooldown"), ("radius", "radius"), ("build_time", "buildTime"),
               ("sight", "sight"), ("splash", "splash")]
BUILDING_FIELDS = [("cost", "cost"), ("hp", "hp"), ("half", "half"), ("build_time", "buildTime"),
                   ("supply", "supply"), ("range", "range"), ("damage", "damage"), ("cooldown", "cooldown"),
                   ("sight", "sight")]


def test_unit_stats_agree():
    sw = swift_stats(swift("Defs.swift"), "Unit")
    for k in UNIT_KINDS:
        p = UNITS[k]
        assert p.name in sw, f"{k} missing from Defs.swift"
        for pf, sf in UNIT_FIELDS:
            assert float(getattr(p, pf)) == float(sw[p.name][sf]), f"unit {k}.{pf}"
        assert p.hotkey == sw[p.name]["hotkey"].strip('"')


def test_building_stats_agree():
    sw = swift_stats(swift("Defs.swift"), "Building")
    for k in BUILDING_KINDS:
        p = BUILDINGS[k]
        assert p.name in sw, f"{k} missing from Defs.swift"
        for pf, sf in BUILDING_FIELDS:
            assert float(getattr(p, pf)) == float(sw[p.name][sf]), f"building {k}.{pf}"
        assert p.hotkey == sw[p.name]["hotkey"].strip('"')


def test_wire_order_agrees():
    src = swift("Net.swift").replace("\n", " ")
    units = [x.strip().lstrip(".") for x in re.search(r"unitKinds: \[UnitKind\] = \[(.*?)\]", src).group(1).split(",")]
    buildings = [x.strip().lstrip(".") for x in re.search(r"buildingKinds: \[BuildingKind\] = \[(.*?)\]", src).group(1).split(",")]
    assert units == UNIT_KINDS
    assert buildings == BUILDING_KINDS


def test_protocol_version_agrees():
    v = int(re.search(r"static let version = (\d+)", swift("Net.swift")).group(1))
    assert v == net.PROTOCOL_VERSION


def test_shared_constants_agree():
    src = swift("Defs.swift")

    def const(name):
        return float(re.search(r"let %s(?:: \w+)? = ([\d.]+)" % name, src).group(1))

    assert const("bridgeHP") == BRIDGE_HP
    assert const("bridgeCost") == BRIDGE_COST
    assert const("bridgeRebuildTime") == BRIDGE_REBUILD_TIME
    assert const("repairTime") == REPAIR_TIME
    assert const("repairCostRatio") == REPAIR_COST_RATIO
    assert const("siegeRange") == SIEGE_RANGE
    assert const("siegeMinRange") == SIEGE_MIN_RANGE
    assert const("siegeDamage") == SIEGE_DAMAGE
    assert const("siegeSplash") == SIEGE_SPLASH
    assert const("siegeCooldown") == SIEGE_COOLDOWN
    assert const("siegeTransition") == SIEGE_TRANSITION
    assert const("siegeSight") == SIEGE_SIGHT


def test_upgrade_catalogue_agrees():
    src = swift("Defs.swift")
    # Wire order: the Swift enum's cases, in declaration order.
    cases = re.search(r"enum UpgradeKind: Int, CaseIterable \{\s*case ([^\n]+)", src).group(1)
    order = [c.strip().split(" ")[0] for c in cases.split(",")]
    assert order == UPGRADE_KINDS
    names = re.search(r'var wireName: String \{ \[([^\]]+)\]', src).group(1)
    assert [n.strip().strip('"') for n in names.split(",")] == UPGRADE_KINDS
    for k in UPGRADE_KINDS:
        p = UPGRADES[k]
        m = re.search(r'case \.%s: return UpgradeStats\((.*?)appliesTo: \[(.*?)\]\)' % k, src, re.S)
        assert m, f"upgrade {k} missing from Defs.swift"
        f = dict(re.findall(r'(\w+): ("[^"]*"|[\d.]+|true|false)', m.group(1)))
        assert f["name"].strip('"') == p.name and f["short"].strip('"') == p.short and f["desc"].strip('"') == p.desc
        assert float(f["cost"]) == p.cost and (f["flat"] == "true") == p.flat, k
        assert float(f["time"]) == p.time and f["hotkey"].strip('"') == p.hotkey, k
        applies = tuple(x.strip().lstrip(".") for x in m.group(2).split(",") if x.strip())
        assert applies == p.applies_to, k
    def const(name):
        return float(re.search(r"let %s(?:: \w+)? = ([\d.]+)" % name, src).group(1))
    assert const("armorFactor") == ARMOR_FACTOR
    assert const("turretUpgradedDamage") == TURRET_UPGRADED_DAMAGE
    assert const("turretUpgradedRange") == TURRET_UPGRADED_RANGE
    assert const("depotUpgradedSupply") == DEPOT_UPGRADED_SUPPLY
    assert const("vetBonus") == VET_BONUS
    assert const("towerRadius") == TOWER_RADIUS
    assert const("towerCaptureTime") == TOWER_CAPTURE_TIME
    assert const("towerSight") == TOWER_SIGHT
    assert const("towerHalf") == TOWER_HALF
    assert const("revealTime") == REVEAL_TIME
    assert const("revealRadius") == REVEAL_RADIUS
    thresholds = re.search(r"let vetThresholds = \[([\d, ]+)\]", src).group(1)
    assert tuple(int(x) for x in thresholds.split(",")) == VET_THRESHOLDS


def test_app_versions_agree():
    swift_v = re.search(r'let appVersion = "([^"]+)"', swift("Defs.swift")).group(1)
    with open(os.path.join(ROOT, "linux", "fieldcommand", "__init__.py")) as f:
        py_v = re.search(r'__version__ = "([^"]+)"', f.read()).group(1)
    with open(os.path.join(ROOT, "linux", "Makefile")) as f:
        mk_v = re.search(r"VERSION\s*:=\s*(\S+)", f.read()).group(1)
    with open(os.path.join(ROOT, "linux", "field-command.spec")) as f:
        spec_v = re.search(r"Version:\s*(\S+)", f.read()).group(1)
    assert swift_v == py_v == mk_v == spec_v


def test_status_codes_agree():
    """The Mac client names each status code it receives; every Python code must be one it knows."""
    src = swift("Entities.swift")
    block = src[src.index("switch netStatus"):src.index("default: return", src.index("switch netStatus"))]
    known = {int(c) for c in re.findall(r"case (\d+):", block)}
    for name, code in net.STATUS.items():
        if code != 0:
            assert code in known, f"status {name}={code} unknown to the Mac client"
