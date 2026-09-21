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
                               BUILDING_KINDS, REPAIR_COST_RATIO, REPAIR_TIME, UNITS, UNIT_KINDS)
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
