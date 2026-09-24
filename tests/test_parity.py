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
                               TOWER_RADIUS, TOWER_SIGHT, VET_BONUS, VET_THRESHOLDS, REVEAL_RADIUS, REVEAL_TIME,
                               CARRY_CAP, KITS)
from fieldcommand import net  # noqa: E402
from fieldcommand.session import lineup_text  # noqa: E402

SWIFT = os.path.join(ROOT, "macos", "Sources", "FieldCommand")


def swift(name):
    # UTF-8 explicitly: the sources carry em dashes and symbols, and Windows would read them as cp1252.
    with open(os.path.join(SWIFT, name), encoding="utf-8") as f:
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
        assert p.flies == (sw[p.name].get("flies", "false") == "true"), f"unit {k}.flies"
        assert p.hits_air == (sw[p.name].get("hitsAir", "true") == "true"), f"unit {k}.hits_air"


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
    from fieldcommand.defs import HIGH_RANGE, HIGH_SIGHT
    assert const("highSight") == HIGH_SIGHT
    assert const("highRange") == HIGH_RANGE
    from fieldcommand.defs import HISTORY_STEP, UNDO_PROGRESS, UNDO_WINDOW
    assert const("historyStep") == HISTORY_STEP
    assert const("undoWindow") == UNDO_WINDOW
    assert const("undoProgress") == UNDO_PROGRESS


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
        m = re.search(r'case \.%s: return UpgradeStats\((.*?)appliesTo: \[(.*?)\], button: ("[^"]*")\)' % k, src, re.S)
        assert m, f"upgrade {k} missing from Defs.swift"
        f = dict(re.findall(r'(\w+): ("[^"]*"|[\d.]+|true|false)', m.group(1)))
        f["button"] = m.group(3)
        assert f["name"].strip('"') == p.name and f["short"].strip('"') == p.short and f["desc"].strip('"') == p.desc
        assert float(f["cost"]) == p.cost and (f["flat"] == "true") == p.flat, k
        assert float(f["time"]) == p.time and f["hotkey"].strip('"') == p.hotkey, k
        assert f["button"].strip('"') == p.button, k
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


def test_armory_catalogue_agrees():
    src = swift("Defs.swift")
    rows = re.findall(r'Kit\(id: "(\w+)", unit: \.(\w+), name: "([^"]+)", cost: (\d+), desc: "([^"]+)", effect: \[(.*?)\]\)', src)
    assert [r[0] for r in rows] == [k.id for k in KITS], "kit wire order"
    for (kid, unit, name, cost, desc, effect), k in zip(rows, KITS):
        assert (unit, name, int(cost), desc) == (k.unit, k.name, k.cost, k.desc), kid
        eff = tuple((key, float(v)) for key, v in re.findall(r'\("(\w+)", ([\d.]+)\)', effect))
        assert eff == tuple((key, float(v)) for key, v in k.effect), kid
    assert int(re.search(r"let carryCap = (\d+)", src).group(1)) == CARRY_CAP


def test_map_catalogue_agrees():
    """Same ids, names, player counts, blurbs and world sizes; and the giant maps' baked layouts are what
    mapgen.py generates today."""
    from fieldcommand import mapgen
    src = swift("ServerWorld.swift")
    rows = re.findall(r'Info\(id: "(\w+)", name: "([^"]+)", players: (\d+), desc: "([^"]+)"\)', src)
    assert [(r[0], r[1], int(r[2]), r[3]) for r in rows] == [(m["id"], m["name"], m["players"], m["desc"]) for m in mapgen.CATALOG]
    giant = re.search(r"giantWorld = CGSize\(width: (\d+), height: (\d+)\)", src)
    mega = re.search(r"megaWorld = CGSize\(width: (\d+), height: (\d+)\)", src)
    assert (float(giant.group(1)), float(giant.group(2))) == mapgen.GIANT_WORLD
    assert (float(mega.group(1)), float(mega.group(2))) == mapgen.MEGA_WORLD
    ids = set(re.search(r"giantIds: Set<String> = \[(.*?)\]", src).group(1).replace('"', "").replace(" ", "").split(","))
    assert ids == set(mapgen.GIANT_IDS)

    baked = swift("GiantMaps.swift")
    for mid in mapgen.GIANT_IDS:
        m = mapgen.generate(mid)
        cam = "".join(p.title() for p in mid.split("_"))
        cam = cam[0].lower() + cam[1:]
        for part, fn in [("Starts", mapgen.bake_starts), ("Expansions", mapgen.bake_expansions), ("Roads", mapgen.bake_roads),
                         ("Walls", mapgen.bake_walls), ("Bridges", mapgen.bake_bridges)]:
            got = re.search(rf'let {cam}{part} = "(.*?)"\n', baked).group(1)
            assert got == fn(m), f"{mid} {part}: re-bake with mapgen.bake_swift()"


def test_high_ground_agrees():
    """The hand-written maps' plateaus are the ones mapgen.py places."""
    from fieldcommand import mapgen
    src = swift("ServerWorld.swift")
    sw = {}
    for name, body in re.findall(r"static let (\w+)Ridges: \[\(Double, Double, Double, Double\)\] = \[(.*?)\]\n", src):
        sw[name] = [tuple(float(v) for v in r.split(",")) for r in re.findall(r"\(([\d., ]+)\)", body)]
    for m in mapgen.CATALOG:
        ridges = [tuple(float(v) for v in r) for r in mapgen.generate(m["id"]).get("ridges", [])]
        cam = "".join(p.title() for p in m["id"].split("_"))
        cam = cam[0].lower() + cam[1:]
        assert sw.get(cam, []) == ridges, m["id"]


def test_music_agrees():
    """The music's loop, tempo, layers and threat numbers match in both editions."""
    from fieldcommand import audio, music
    src = swift("Audio.swift")
    def const(name):
        return float(re.search(r"static let %s(?:: \w+)? = ([\d.]+)" % name, src).group(1))
    assert const("bpm") == music.BPM and const("master") == music.MASTER
    assert int(re.search(r"static let beats = (\d+)", src).group(1)) == music.BEATS
    chords = re.findall(r"\(([\d.]+), ([\d.]+), ([\d.]+)\)", re.search(r"static let chords: .*?= \[(.*?)\]", src).group(1))
    assert [tuple(float(v) for v in c) for c in chords] == [tuple(c) for c in music.CHORDS]
    pitches = dict(re.findall(r'"(\w+)": (\d+)', re.search(r"static let voicePitch: \[String: Double\] = \[(.*?)\]", src).group(1)))
    assert {k: float(v) for k, v in pitches.items()} == audio.VOICE_PITCH
    assert re.findall(r'"(\w+)"', re.search(r"static let layers = \[(.*?)\]", src).group(1)) == music.LAYERS
    rise, fall = re.search(r"static let rise = ([\d.]+), fall = ([\d.]+)", src).groups()
    assert (float(rise), float(fall)) == (music.RISE, music.FALL)
    ah, sh = re.search(r"static let alertHold = ([\d.]+), shotHold = ([\d.]+)", src).groups()
    assert (float(ah), float(sh)) == (music.ALERT_HOLD, music.SHOT_HOLD)
    ta, ts, tn = re.search(r"static let threatAlert = ([\d.]+), threatShots = ([\d.]+), threatSeen = ([\d.]+)", src).groups()
    assert (float(ta), float(ts), float(tn)) == (music.THREAT_ALERT, music.THREAT_SHOTS, music.THREAT_SEEN)
    shots = set(re.findall(r'"(\w+)"', re.search(r"static let shots: Set<String> = \[(.*?)\]", src).group(1)))
    assert shots == set(music.SHOTS)


def test_key_actions_agree():
    """The rebindable actions, their labels and default keys match in both editions."""
    from fieldcommand.defs import KEY_ACTIONS
    src = swift("Defs.swift")
    block = re.search(r"let keyActions: \[\(action: String, label: String, key: String\)\] = \[(.*?)\n\]", src, re.S).group(1)
    rows = re.findall(r'\("(\w+)", "([^"]+)", "(\w+)"\)', block)
    assert [tuple(r) for r in rows] == [tuple(a) for a in KEY_ACTIONS]


def test_gold_deposits_agree():
    from fieldcommand import mapgen
    from fieldcommand.defs import GOLD_AMOUNT
    src = swift("Defs.swift")
    assert int(re.search(r"let goldAmount = (\d+)", src).group(1)) == GOLD_AMOUNT
    # Every map has at least one gold deposit, and the baked/hand-written Swift maps carry the same number.
    sw = swift("ServerWorld.swift") + swift("GiantMaps.swift")
    for m in mapgen.CATALOG:
        spec = mapgen.generate(m["id"])
        gold = [c for c in spec["crystals"] if c[3] == 3]
        assert gold and all(c[2] == GOLD_AMOUNT for c in gold), m["id"]
    assert sw.count("goldAmount)") + sw.count("goldAmount]") >= 7        # the seven hand-written maps' sites


def test_artillery_and_shield_constants_agree():
    from fieldcommand import defs
    src = swift("Defs.swift")
    for name, value in [("artilleryMinRange", defs.ARTILLERY_MIN_RANGE), ("artillerySplash", defs.ARTILLERY_SPLASH),
                        ("artilleryShellSpeed", defs.ARTILLERY_SHELL_SPEED), ("tankShellSpeed", defs.TANK_SHELL_SPEED),
                        ("shieldRadius", defs.SHIELD_RADIUS), ("shieldMax", defs.SHIELD_MAX),
                        ("shieldRegen", defs.SHIELD_REGEN), ("shieldDelay", defs.SHIELD_DELAY)]:
        assert float(re.search(rf"let {name}: Double = ([\d.]+)", src).group(1)) == value, name


def test_hq_gun_and_crate_constants_agree():
    from fieldcommand import defs
    src = swift("Defs.swift")
    for name, value in [("hqGunRange", defs.HQ_GUN_RANGE), ("hqGunDamage", defs.HQ_GUN_DAMAGE), ("hqGunCooldown", defs.HQ_GUN_COOLDOWN),
                        ("crateInterval", defs.CRATE_INTERVAL), ("crateFirst", defs.CRATE_FIRST), ("crateLife", defs.CRATE_LIFE),
                        ("crateRadius", defs.CRATE_RADIUS)]:
        assert float(re.search(rf"let {name}: Double = ([\d.]+)", src).group(1)) == value, name
    assert int(re.search(r"let crateMax = (\d+)", src).group(1)) == defs.CRATE_MAX
    assert int(re.search(r"let crateSquad = (\d+)", src).group(1)) == defs.CRATE_SQUAD
    kinds = re.search(r"let crateKinds = \[(.*?)\]", src).group(1).replace('"', "").replace(" ", "").split(",")
    assert kinds == defs.CRATE_KINDS
    amounts = [int(v) for v in re.search(r"let crateCrystal = \[(.*?)\]", src).group(1).split(",")]
    assert tuple(amounts) == defs.CRATE_CRYSTAL


def test_campaign_agrees():
    from fieldcommand.defs import CAMPAIGN
    src = swift("Defs.swift")
    rows = re.findall(r'Mission\(id: "(\w+)", title: "([^"]+)", map: "(\w+)", opponents: (\d+), difficulty: (\d+), teams: (\d+), '
                      r'win: "(\w+)", seconds: (\d+), hold: (nil|\([\d., ]+\)),\s*brief: "([^"]+)",\s*events: \[(.*?)\]\)', src, re.S)
    assert len(rows) == len(CAMPAIGN)
    for r, m in zip(rows, CAMPAIGN):
        assert (r[0], r[1], r[2], int(r[3]), int(r[4]), int(r[5]), r[6], float(r[7]), r[9]) == \
            (m.id, m.title, m.map, m.opponents, m.difficulty, m.teams, m.win, float(m.seconds), m.brief), m.id
        hold = () if r[8] == "nil" else tuple(float(v) for v in r[8].strip("()").split(","))
        assert hold == tuple(float(v) for v in m.hold), m.id
        evs = re.findall(r'MissionEvent\(kind: "(\w+)", at: (\d+)(?:, owner: (\d+), unit: "(\w+)", count: (\d+), from: (\d+), target: (-?\d+))?, '
                         r'text: "([^"]+)"\)', r[10])
        assert len(evs) == len(m.events), m.id
        for e, me in zip(evs, m.events):
            if e[0] == "text":
                assert (e[0], float(e[1]), e[7]) == (me[0], float(me[1]), me[2]), (m.id, me)
            else:
                assert (e[0], float(e[1]), int(e[2]), e[3], int(e[4]), int(e[5]), int(e[6]), e[7]) == \
                    (me[0], float(me[1]), me[2], me[3], me[4], me[5], me[6], me[7]), (m.id, me)


def test_starting_crystal_agrees():
    from fieldcommand.defs import START_CRYSTAL
    assert int(re.search(r"let startCrystal = (\d+)", swift("Defs.swift")).group(1)) == START_CRYSTAL


def test_healing_constants_agree():
    from fieldcommand.defs import HEAL_RANGE, HEAL_RATE
    src = swift("Defs.swift")
    assert float(re.search(r"let healRate: Double = ([\d.]+)", src).group(1)) == HEAL_RATE
    assert float(re.search(r"let healRange: Double = ([\d.]+)", src).group(1)) == HEAL_RANGE


def test_save_format_agrees():
    from fieldcommand.save import SAVE_FORMAT
    assert int(re.search(r"static let format = (\d+)", swift("SaveGame.swift")).group(1)) == SAVE_FORMAT


def test_app_versions_agree():
    swift_v = re.search(r'let appVersion = "([^"]+)"', swift("Defs.swift")).group(1)
    with open(os.path.join(ROOT, "linux", "fieldcommand", "__init__.py"), encoding="utf-8") as f:
        py_v = re.search(r'__version__ = "([^"]+)"', f.read()).group(1)
    with open(os.path.join(ROOT, "linux", "Makefile"), encoding="utf-8") as f:
        mk_v = re.search(r"VERSION\s*:=\s*(\S+)", f.read()).group(1)
    with open(os.path.join(ROOT, "linux", "field-command.spec"), encoding="utf-8") as f:
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


def test_openings_agree():
    """The computer's openings, their odds and the strategist's numbers match in both editions."""
    from fieldcommand.ai import EXPAND_AT, GARRISON, GIANT_W, OPENING_ORDER, OPENING_WEIGHTS, OPENINGS, SCOUT_AT, SCOUT_EVERY
    src = swift("ServerWorld.swift")
    block = re.search(r"let openings: \[String: \[String: Double\]\] = \[(.*?)\n\]", src, re.S).group(1)
    for name, factors in OPENINGS.items():
        row = re.search(r'"%s": \[(.*?)\]' % name, block).group(1)
        got = {k: float(v) for k, v in re.findall(r'"(\w+)": (-?[\d.]+)', row)}
        assert got == {k: float(v) for k, v in factors.items()}, name
    order = re.findall(r'"(\w+)"', re.search(r"let openingOrder = \[(.*?)\]", src).group(1))
    assert order == OPENING_ORDER
    weights = re.search(r"let openingWeights: \[\[Double\]\] = \[(.*?)\]\n", src).group(1)
    assert [[int(x) for x in re.findall(r"\d+", row)] for row in re.findall(r"\[([\d, ]+)\]", weights)] == OPENING_WEIGHTS
    assert [int(x) for x in re.findall(r"\d+", re.search(r"let garrison = \[(.*?)\]", src).group(1))] == GARRISON
    assert float(re.search(r"let giantW: Double = ([\d.]+)", src).group(1)) == GIANT_W
    assert float(re.search(r"let scoutAt: Double = ([\d.]+)", src).group(1)) == SCOUT_AT
    assert float(re.search(r"let scoutEvery: Double = ([\d.]+)", src).group(1)) == SCOUT_EVERY
    assert float(re.search(r"let expandAt: Double = ([\d.]+)", src).group(1)) == EXPAND_AT
    from fieldcommand.ai import FORTIFY_AT, FORTIFY_BLOCKS, FORTIFY_DIST, FORTIFY_OFFSETS
    assert float(re.search(r"let fortifyAt: Double = ([\d.]+)", src).group(1)) == FORTIFY_AT
    assert float(re.search(r"let fortifyDist: Double = ([\d.]+)", src).group(1)) == FORTIFY_DIST
    assert int(re.search(r"let fortifyBlocks = (\d+)", src).group(1)) == FORTIFY_BLOCKS
    offs = [float(v) for v in re.findall(r"-?\d+", re.search(r"let fortifyOffsets: \[Double\] = \[(.*?)\]", src).group(1))]
    assert offs == [float(v) for v in FORTIFY_OFFSETS]
