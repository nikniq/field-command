"""Game constants, unit/building stats, colours and geometry helpers.

World coordinates are y-up with the origin at the bottom-left of the map, matching the macOS edition.
"""
import math
from dataclasses import dataclass

# Size of the map in play. Maps carry their own size (mega maps are larger), so read these through the module
# (`defs.WORLD_W`) rather than importing the names, and call set_world_size() when a map is loaded.
WORLD_W, WORLD_H = 4000.0, 2800.0
DEFAULT_WORLD = (4000.0, 2800.0)
PLAYER, ENEMY = 0, 1


def set_world_size(w, h):
    global WORLD_W, WORLD_H
    WORLD_W, WORLD_H = float(w), float(h)


def opponent(team):
    return 1 - team


# ---------------------------------------------------------------- colours (float RGBA, 0..1)

def rgb(r, g, b, a=1.0):
    return (r, g, b, a)


def mix(c1, c2, t):
    return tuple(c1[i] * (1 - t) + c2[i] * t for i in range(4))


def alpha(c, a):
    return (c[0], c[1], c[2], a)


def to255(c):
    return tuple(int(max(0.0, min(1.0, v)) * 255) for v in c[:3])


def to255a(c):
    return tuple(int(max(0.0, min(1.0, v)) * 255) for v in c[:4])


WHITE = rgb(1, 1, 1)
BLACK = rgb(0, 0, 0)

CRYSTAL = rgb(0.40, 0.92, 1.0)
TEXT = rgb(0.90, 0.93, 0.95)
DIM = rgb(0.55, 0.62, 0.68)
AMBER = rgb(1.0, 0.76, 0.30)
GOOD = rgb(0.45, 0.95, 0.50)
BAD = rgb(1.0, 0.40, 0.35)
BUTTON_EDGE = rgb(0.35, 0.55, 0.75)

# Player colours by slot. Up to 12 play at once on the mega maps.
MAX_PLAYERS = 12
_TEAM_RGB = [
    (0.28, 0.62, 1.00, "Blue"), (0.95, 0.32, 0.26, "Red"), (0.30, 0.82, 0.38, "Green"), (0.72, 0.46, 1.00, "Violet"),
    (1.00, 0.76, 0.25, "Gold"), (0.20, 0.85, 0.82, "Teal"), (1.00, 0.52, 0.80, "Rose"), (0.98, 0.56, 0.18, "Orange"),
    (0.60, 0.93, 0.25, "Lime"), (0.45, 0.50, 0.95, "Indigo"), (0.85, 0.83, 0.78, "Bone"), (0.66, 0.44, 0.24, "Umber"),
]
TEAM_COLOR = {i: rgb(r, g, b) for i, (r, g, b, _n) in enumerate(_TEAM_RGB)}
TEAM_LIGHT = {i: mix(TEAM_COLOR[i], WHITE, 0.45) for i in range(MAX_PLAYERS)}
TEAM_DARK = {i: mix(TEAM_COLOR[i], BLACK, 0.68) for i in range(MAX_PLAYERS)}
COLOR_NAMES = {i: n for i, (_r, _g, _b, n) in enumerate(_TEAM_RGB)}
# Order matters: the network protocol sends a kind as its index here, so new kinds are appended
# at the end and the macOS edition's NetProtocol lists must match exactly.
UNIT_KINDS = ["worker", "marine", "tank", "sniper", "medic", "gunship"]
BUILDING_KINDS = ["hq", "depot", "barracks", "factory", "turret", "radar", "artillery", "shield", "wall"]


# ---------------------------------------------------------------- stats

@dataclass(frozen=True)
class UnitStats:
    name: str
    glyph: str
    cost: int
    supply: int
    hp: float
    speed: float
    range: float
    damage: float
    cooldown: float
    radius: float
    build_time: float
    sight: float
    splash: float
    hotkey: str
    desc: str
    requires: str = None      # building kind that must be finished before this unit can be trained
    flies: bool = False       # an aircraft: moves in a straight line over terrain, walls and units
    hits_air: bool = True     # can this unit's weapon reach an aircraft?


UNITS = {
    "worker": UnitStats("Engineer", "EN", 50, 1, 45, 95, 6, 4, 1.2, 9, 10, 220, 0, "W",
                        "Mines crystal and constructs buildings."),
    "marine": UnitStats("Ranger", "RG", 50, 1, 60, 88, 150, 7, 0.75, 10, 12, 260, 0, "R",
                        "Versatile rifle infantry."),
    "tank": UnitStats("Siege Tank", "TK", 150, 3, 220, 62, 230, 32, 2.2, 17, 22, 280, 45, "T",
                      "Long-range armor. Shells deal splash damage. Cannot fire at aircraft.", hits_air=False),
    "sniper": UnitStats("Sniper", "SN", 125, 2, 55, 74, 330, 55, 3.2, 10, 24, 360, 0, "N",
                        "Outranges tanks and turrets, one heavy shot at a time. Helpless up close.",
                        requires="factory"),
    "medic": UnitStats("Medic", "MD", 75, 1, 50, 90, 0, 0, 0.0, 10, 14, 240, 0, "M",
                       "Heals wounded infantry nearby. Unarmed: keep it behind the line."),
    "gunship": UnitStats("Gunship", "GS", 200, 3, 260, 150, 130, 22, 0.7, 14, 30, 300, 0, "Q",
                         "Flies straight over cliffs, water and walls; a fast chain gun. Tanks and artillery cannot touch it.",
                         requires="radar", flies=True),
}
# Buildings that can shoot aircraft; the rest (artillery) fire at the ground only.
AIR_GUNS = ("turret", "hq")

# Healing: a Medic restores HEAL_RATE hit points a second to one wounded ally on foot (Engineers, Rangers,
# Snipers, other Medics) within HEAL_RANGE, and looks for the wounded as far as it can see. Vehicles are
# mended by Engineers instead, at the repair price.
HEAL_RATE = 6.0
HEAL_RANGE = 60.0


@dataclass(frozen=True)
class BuildingStats:
    name: str
    short: str
    glyph: str
    cost: int
    hp: float
    half: float
    build_time: float
    supply: int
    produces: tuple
    requires: str
    range: float
    damage: float
    cooldown: float
    sight: float
    hotkey: str
    desc: str


BUILDINGS = {
    "hq": BuildingStats("Command Center", "HQ", "HQ", 400, 1500, 80, 60, 10, ("worker",), None, 0, 0, 0, 340, "C",
                        "Trains Engineers. Crystal drop-off. +10 supply."),
    "depot": BuildingStats("Supply Depot", "Depot", "SD", 100, 400, 42, 20, 8, (), None, 0, 0, 0, 200, "E",
                           "Provides +8 supply."),
    "barracks": BuildingStats("Barracks", "Barracks", "BK", 150, 900, 64, 35, 0, ("marine", "sniper", "medic"), "hq", 0, 0, 0, 240, "B",
                              "Trains Rangers and Medics, and Snipers once a Factory is up."),
    "factory": BuildingStats("Factory", "Factory", "FC", 200, 1100, 70, 45, 0, ("tank", "gunship"), "barracks", 0, 0, 0, 240, "F",
                             "Builds Siege Tanks."),
    "turret": BuildingStats("Gun Turret", "Turret", "GT", 100, 380, 30, 22, 0, (), "barracks", 210, 11, 0.7, 270, "T",
                            "Static defense. Fires on nearby enemies."),
    "radar": BuildingStats("Radar Station", "Radar", "RD", 175, 520, 34, 30, 0, (), "barracks", 0, 0, 0, 900, "D",
                           "Sweeps a wide circle of the map. Unarmed."),
    "artillery": BuildingStats("Artillery", "Artillery", "AT", 250, 600, 40, 40, 0, (), "factory", 480, 45, 4.0, 300, "L",
                               "Lobs shells 480 out, further than it sees: spotters find its targets. Blind inside 150."),
    "shield": BuildingStats("Shield Generator", "Shield", "SG", 225, 500, 36, 35, 0, (), "barracks", 0, 0, 0, 240, "K",
                            "Shields every building of yours within 320: 300 points soaked before the walls, recharging."),
    "wall": BuildingStats("Barricade", "Wall", "BR", 30, 700, 22, 8, 0, (), None, 0, 0, 0, 120, "V",
                          "A block of wall: cheap, tough and in the way. Nothing walks through until it is shot down. Shift places a run."),
}
BUILD_MENU = ["hq", "depot", "barracks", "factory", "turret", "radar", "artillery", "shield", "wall"]

# Bridges. They come with the map rather than being built from scratch, so their numbers live here
# rather than in BUILDINGS: nobody owns one, anybody can shell it down, any Engineer can rebuild it.
BRIDGE_HP = 900.0
BRIDGE_COST = 75
BRIDGE_REBUILD_TIME = 25.0

# Siege mode. A Siege Tank can dig in: it stops moving and takes SIEGE_TRANSITION seconds to switch either way,
# and while sieged it fires further and harder but cannot hit anything closer than SIEGE_MIN_RANGE. Mobile,
# a Sniper (330) outranges it; sieged, it outranges the Sniper — but has to be set up first.
SIEGE_RANGE = 340.0
SIEGE_MIN_RANGE = 90.0
SIEGE_DAMAGE = 50.0
SIEGE_SPLASH = 65.0
SIEGE_COOLDOWN = 3.2
SIEGE_TRANSITION = 2.5
SIEGE_SIGHT = 360.0          # dug in, a tank sees as far as it shoots
MODE_MOBILE, MODE_SIEGING, MODE_SIEGED, MODE_UNSIEGING = 0, 1, 2, 3

# Building upgrades. Bought on one building at a time, researched by that building over `time` seconds,
# and permanent for it. `cost` is a fraction of the building's own price unless `flat` is set.
@dataclass(frozen=True)
class Upgrade:
    name: str
    short: str
    desc: str
    cost: float             # fraction of the building's price, or crystal when flat
    flat: bool
    time: float
    hotkey: str
    applies_to: tuple       # building kinds, or () for every building
    button: str = ""        # the label on the 64-pixel command-card button; `name` is for tooltips and messages


UPGRADES = {
    "hp": Upgrade("Reinforce", "Reinforced", "Doubles the building's hit points.", 0.6, False, 30, "V", (),
                  button="Reinforce"),
    "armor": Upgrade("Armour plating", "Armoured", "The building takes 30% less damage.", 0.6, False, 30, "X", (),
                     button="Armour"),
    "prod": Upgrade("Assembly line", "Assembly line", "Trains units twice as fast.", 0.8, False, 40, "U",
                    ("hq", "barracks", "factory"), button="Assembly"),
    "supply": Upgrade("Expanded storage", "Expanded", "+8 supply from this depot.", 75, True, 20, "U", ("depot",),
                      button="Storage"),
    "guns": Upgrade("Twin cannon", "Twin cannon", "Damage 11 to 20 and range 210 to 260.", 0.9, False, 35, "U",
                    ("turret",), button="Twin gun"),
    "defense": Upgrade("Point defence", "Point defence", "The Command Center mounts a gun: damage 14 at range 240.", 0.5,
                       False, 35, "J", ("hq",), button="Defence"),
    # Tech: researched once at one building, and the whole side's army changes.
    "entrench": Upgrade("Entrenchment", "Entrenched", "Rangers and Snipers that hold still for 3s take 30% less damage.", 150,
                        True, 40, "E", ("barracks",), button="Entrench"),
    "stabilise": Upgrade("Stabilisers", "Stabilised", "Siege Tanks fire on the move.", 200, True, 50, "B", ("factory",),
                         button="Stabilise"),
}
# Order matters: an installed set travels as a bitmask over this list, an upgrade in progress as its index.
UPGRADE_KINDS = ["hp", "armor", "prod", "supply", "guns", "defense", "entrench", "stabilise"]
# Tech is side-wide: once any building of a side has it, every unit it names benefits and nobody buys it again.
TECH = ("entrench", "stabilise")
ENTRENCH_TIME = 3.0          # seconds still before a Ranger or Sniper counts as dug in
ENTRENCH_FACTOR = 0.7        # damage taken while dug in
ENTRENCH_KINDS = ("marine", "sniper")
# The campaign: hand-authored missions played in order against the computer. `win` is "destroy" (the usual
# rule), "survive" (be standing when `seconds` run out) or "hold" (keep the point at `hold` = (x, y, radius)
# yours, with no enemy unit inside the ring, for `seconds` in a row). Same list in the macOS edition.
@dataclass(frozen=True)
class Mission:
    id: str
    title: str
    map: str
    opponents: int
    difficulty: int         # index into DIFFICULTIES
    teams: int
    win: str
    seconds: float
    hold: tuple             # (x, y, radius) or ()
    brief: str
    # The script: events fired on the mission clock, in order. ("text", at, text) is a line from Command;
    # ("spawn", at, owner, unit, count, from, target, text) puts `count` units of `unit` for slot `owner` on
    # the map edge nearest slot `from`'s start, walking (allies) or attack-moving (enemies) to slot `target`'s
    # Command Center — or, with target -1, to the hold ring or the middle of the map.
    events: tuple = ()
    # Missions that unlock this one: any one of them done will do. Empty means open from the start.
    requires: tuple = ()
    # A named unit (kind, name) that stands with you from the first second and must survive: lose it, lose
    # the mission. Empty for none.
    vip: tuple = ()


# How many veterans carry over from a won mission into the next, and the kinds that can.
VETERAN_CARRY = 8
VETERAN_KINDS = ("marine", "sniper", "tank", "medic", "gunship")

CAMPAIGN = [
    Mission("first_light", "First Light", "twin_ridges", 1, 0, 0, "destroy", 0, (),
            "Mine, build, and take the enemy base. The computer goes easy on you — this once.",
            (("text", 15, "Command: mine crystal with your Engineers, then put up a Barracks (B) and a Supply Depot."),
             ("spawn", 150, 0, "marine", 3, 0, 0, "Reinforcements: three Rangers have reached the field from your side."),
             ("text", 300, "Command: the enemy Command Center is in the far corner. Attack-move (A) your army onto it."))),
    Mission("hold_the_line", "Hold the Line", "river_crossing", 1, 2, 0, "survive", 480, (),
            "Eight minutes. The enemy comes over the bridges in force; be standing when the clock runs out. Cut a bridge if you must.",
            (("text", 10, "Command: dig in. Turrets by the bridges, Engineers repairing behind them."),
             ("spawn", 90, 0, "tank", 2, 0, 0, "Reinforcements: two Siege Tanks from the rear."),
             ("spawn", 150, 1, "marine", 6, 1, 0, "A column of enemy Rangers is coming over the bridges."),
             ("spawn", 300, 1, "tank", 4, 1, 0, "Enemy Siege Tanks are on the road."),
             ("spawn", 420, 1, "marine", 8, 1, 0, "The last push: hold one more minute.")),
            requires=("first_light",)),
    Mission("gold_run", "The Gold Run", "highland_pass", 1, 1, 0, "hold", 180, (2000, 1400, 260),
            "Hold the gold deposit in the middle pass for three minutes without an enemy inside the ring.",
            (("text", 10, "Command: the gold is in the middle pass. Take it, and keep the enemy out of the ring."),
             ("spawn", 240, 1, "marine", 5, 1, -1, "An enemy squad has been sent for the gold."),
             ("spawn", 360, 0, "marine", 4, 0, 0, "Reinforcements: a squad of Rangers has arrived.")),
            requires=("first_light",), vip=("sniper", "Sergeant Kade")),
    Mission("crossfire", "Crossfire", "four_corners", 3, 1, 2, "destroy", 0, (),
            "You and a computer ally against two. Use attack points (Z) to bring your ally onto the fight.",
            (("text", 10, "Command: your ally holds the far corner. Attack points (Z) call them onto a fight."),
             ("spawn", 200, 1, "marine", 6, 1, 2, "Your ally is under attack — get your army over there."),
             ("spawn", 420, 3, "tank", 3, 3, 0, "Enemy tanks on the road to your base.")),
            requires=("hold_the_line", "gold_run")),
    Mission("long_march", "The Long March", "long_march", 11, 2, 2, "destroy", 0, (),
            "Twelve commanders in two lines across a wide river. Hold the middle bridges, take the gold, and roll them up.",
            (("text", 10, "Command: five commanders stand with you. Hold the middle bridges and take the gold."),
             ("spawn", 300, 0, "tank", 4, 0, 0, "Reinforcements: four Siege Tanks from the rear."),
             ("spawn", 600, 1, "marine", 8, 1, 0, "An enemy column is marching on your base."),
             ("spawn", 900, 0, "marine", 6, 0, 0, "Reinforcements: six Rangers from the rear.")),
            requires=("crossfire",), vip=("tank", "Colonel Rook")),
]
MISSION_BY_ID = {m.id: m for m in CAMPAIGN}

# Every side starts with this much crystal in the bank, unless the game was set up with another amount.
START_CRYSTAL = 5000
START_CRYSTAL_OPTIONS = [2000, 5000, 10000, 20000]
# How a side starts: a Command Center and five Engineers, or an established base with these already standing
# — (kind, distance from the Command Center, angle off the direction to the middle of the map).
START_BASES = [("fresh", "Fresh start", "A Command Center and five Engineers"),
               ("established", "Established base", "Depots, a Barracks, a Factory and a turret already standing")]
ESTABLISHED = [("depot", 230.0, 1.2), ("depot", 230.0, -1.2), ("barracks", 270.0, 0.55), ("factory", 300.0, -0.55),
               ("turret", 340.0, 0.0)]
# Unit abilities, one per kind, on Q: (id, name, reach, cooldown seconds, needs) where needs is "point",
# "target" or "self". A Ranger's grenade bursts where it lands; a Sniper marks a target so everything hits it
# harder for a while; a Siege Tank pops smoke that halves ranged damage to anything inside.
ABILITIES = {"marine": ("grenade", "Grenade", 200.0, 20.0, "point"),
             "sniper": ("mark", "Mark Target", 360.0, 25.0, "target"),
             "tank": ("smoke", "Smoke", 0.0, 30.0, "self")}
GRENADE_DAMAGE = 40.0
GRENADE_SPLASH = 60.0
MARK_DURATION = 8.0
MARK_BONUS = 0.5            # +50% damage taken while marked
SMOKE_RADIUS = 120.0
SMOKE_DURATION = 8.0
SMOKE_FACTOR = 0.5          # ranged damage taken inside smoke
SMOKE_RANGED = 60.0         # a hit from further than this is ranged

# Alloy: the second resource. Gold deposits yield alloy instead of crystal (a trip's cargo either way), every
# side starts with ALLOY_START, and heavy armour, aircraft, the big guns and tech cost alloy on top of crystal.
ALLOY_START = 100
ALLOY_COST = {"tank": 30, "gunship": 40}                        # units
ALLOY_BUILD = {"artillery": 50}                                 # buildings
ALLOY_UPGRADE = {"guns": 20, "entrench": 40, "stabilise": 60}   # upgrades and tech
ALLOY = (0.72, 0.78, 0.86, 1.0)                                 # the colour alloy is written in

# The derelict: a wrecked Siege Tank left near the middle of every map. An Engineer alone beside it (within
# DERELICT_RADIUS, with nothing hostile inside that ring) for DERELICT_TIME seconds salvages it: it becomes a
# working Siege Tank of that side. A reason to leave the base in the first minute.
DERELICT_RADIUS = 90.0
DERELICT_TIME = 12.0

# Cover: anyone on foot standing among trees (within COVER_REACH of a trunk's edge) takes COVER_FACTOR of
# ranged damage (a hit from further than SMOKE_RANGED). Tanks and aircraft get nothing from a forest.
COVER_REACH = 24.0
COVER_FACTOR = 0.5
COVER_KINDS = ("worker", "marine", "sniper", "medic")

# Off-map reinforcements, called in from the Command Center for crystal: unit kind -> (how many, the price).
# They walk in from the map edge nearest your start; one call per REINFORCE_COOLDOWN seconds.
REINFORCEMENTS = {"marine": (4, 300), "tank": (2, 600)}
REINFORCE_ORDER = ["marine", "tank"]
REINFORCE_COOLDOWN = 60.0

# Skirmish game modes: (id, name, rule). Annihilation is the usual rule; King of the Hill goes to the first
# side to hold the gold ring, uncontested, for KOTH_HOLD seconds; Sudden Death knocks a side out with its
# last Command Center. Campaign missions carry their own rules and ignore the mode.
MODES = [("annihilation", "Annihilation", "Destroy every enemy building"),
         ("koth", "King of the Hill", "First to hold the gold ring for 3:00 wins"),
         ("sudden", "Sudden Death", "Lose your last Command Center and you are out")]
MODE_BY_ID = {m[0]: m for m in MODES}
KOTH_HOLD = 180.0
KOTH_RADIUS = 260.0

# The post-game timeline: every side's army size is sampled this often (seconds) for the graph on the
# end screen. UNDO_WINDOW is how long after placing a building it can be taken back for a full refund.
HISTORY_STEP = 15.0
UNDO_WINDOW = 20.0
UNDO_PROGRESS = 0.5      # a site further along than this stays

# Rebindable keys: (action, label, default key name — pygame's names; the Mac edition maps its own codes).
KEY_ACTIONS = [
    ("satellite", "Satellite view", "tab"), ("jump", "Jump to the last alert", "space"),
    ("army", "Select the army", "f2"), ("idle", "Select an idle Engineer", "i"),
    ("ping", "Attack point (Shift: alert)", "z"), ("objectives", "Objectives panel", "o"),
    ("armory", "The Armory", "y"), ("undo", "Undo the last placement", "backspace"),
    ("pause", "Game menu", "p"), ("help", "Help", "h"),
]
DEFAULT_KEYS = {a: k for a, _l, k in KEY_ACTIONS}

# High ground: a map's ridges ([x0, y0, x1, y1] plateaus) are walkable and buildable, and anything standing
# on one sees HIGH_SIGHT times as far and shoots HIGH_RANGE further.
HIGH_SIGHT = 1.3
HIGH_RANGE = 40.0

# Supply crates: one drops somewhere open every CRATE_INTERVAL seconds (at most CRATE_MAX on the field, each
# gone after CRATE_LIFE), and the first unit to reach one collects its gift for its side: crystal, a squad
# of Rangers, or a Siege Tank. CRATE_KINDS is the wire order.
CRATE_INTERVAL = 75.0
CRATE_FIRST = 60.0
CRATE_MAX = 4
CRATE_LIFE = 180.0
CRATE_RADIUS = 22.0
CRATE_KINDS = ["crystal", "squad", "tank"]
CRATE_SQUAD = 3          # Rangers in a squad crate
CRATE_CRYSTAL = (150, 200, 250, 300, 400)

# The Command Center's point-defence gun (the "defense" upgrade): a turret's reach, a little less bite.
HQ_GUN_RANGE = 240.0
HQ_GUN_DAMAGE = 14.0
HQ_GUN_COOLDOWN = 0.6
ARMOR_FACTOR = 0.7
TURRET_UPGRADED_DAMAGE = 20.0
TURRET_UPGRADED_RANGE = 260.0
DEPOT_UPGRADED_SUPPLY = 8


def upgrade_cost(kind, building_kind):
    u = UPGRADES[kind]
    return int(u.cost) if u.flat else int(round(BUILDINGS[building_kind].cost * u.cost))


def upgrade_applies(kind, building_kind):
    a = UPGRADES[kind].applies_to
    return not a or building_kind in a


# The Armory. Kit is bought once per match with crystal and worn by every unit of that type, present and
# future. Effects: hp/damage/speed/cooldown are fractions of the unit's base value (cooldown is a reduction),
# range is added in world units, work speeds up an Engineer's repairing and rebuilding, carry adds crystal
# to each mining trip. The order of KITS is the wire order: what a player owns travels as a bitmask.
@dataclass(frozen=True)
class Kit:
    id: str
    unit: str
    name: str
    cost: int
    desc: str
    effect: tuple      # ((key, value), ...)

    def bonus(self, key):
        return dict(self.effect).get(key, 0.0)


KITS = [
    Kit("hardhat", "worker", "Hard hat", 100, "+50% hit points. Engineers survive a stray shell.", (("hp", 0.5),)),
    Kit("powertools", "worker", "Power tools", 150, "Repairs and rebuilds 30% faster.", (("work", 0.3),)),
    Kit("cargorig", "worker", "Cargo rig", 150, "Carries 12 crystal per trip instead of 8.", (("carry", 4),)),
    Kit("flak", "marine", "Flak jacket", 200, "+25% hit points for every Ranger.", (("hp", 0.25),)),
    Kit("hollowpoint", "marine", "Hollow points", 250, "+20% Ranger damage.", (("damage", 0.2),)),
    Kit("boots", "marine", "Sprint boots", 150, "Rangers move 15% faster.", (("speed", 0.15),)),
    Kit("scope", "sniper", "Long scope", 300, "+30 range: 360, further than a dug-in tank.", (("range", 30),)),
    Kit("ghillie", "sniper", "Ghillie suit", 200, "+25% hit points for every Sniper.", (("hp", 0.25),)),
    Kit("matchammo", "sniper", "Match ammo", 250, "Snipers reload 20% faster.", (("cooldown", 0.2),)),
    Kit("reactive", "tank", "Reactive armour", 300, "+25% hit points for every Siege Tank.", (("hp", 0.25),)),
    Kit("barrel", "tank", "Extended barrel", 300, "+20 range, mobile and dug in.", (("range", 20),)),
    Kit("autoloader", "tank", "Autoloader", 350, "Tanks reload 20% faster.", (("cooldown", 0.2),)),
    Kit("trauma", "medic", "Trauma kit", 200, "Medics heal 50% faster.", (("heal", 0.5),)),
    Kit("plates", "medic", "Ceramic plates", 150, "+30% hit points for every Medic.", (("hp", 0.3),)),
    Kit("litter", "medic", "Field litter", 150, "Medics move 15% faster.", (("speed", 0.15),)),
    Kit("bellyplate", "gunship", "Belly armour", 300, "+25% hit points for every Gunship.", (("hp", 0.25),)),
    Kit("piercing", "gunship", "Piercing rounds", 300, "+20% Gunship damage.", (("damage", 0.2),)),
    Kit("rotortune", "gunship", "Rotor tune", 250, "Gunships fly 15% faster.", (("speed", 0.15),)),
]
KIT_BY_ID = {k.id: k for k in KITS}
KIT_IDS = [k.id for k in KITS]
CARRY_CAP = 8            # crystal an Engineer carries per trip without a Cargo rig

# Attacker reveal. Anything that hits you shows itself to your alliance for REVEAL_TIME seconds, even from
# beyond your sight — so a Sniper or a dug-in tank shelling you from the dark can be seen and answered.
REVEAL_TIME = 2.5
REVEAL_RADIUS = 60.0

# Veterancy. A unit earns a rank at each kill count in VET_THRESHOLDS; every rank adds VET_BONUS of its base
# damage and hit points (the extra health is granted on promotion, so a veteran comes out of the fight
# stronger, not merely with a taller empty bar).
VET_THRESHOLDS = (2, 5, 10)
VET_BONUS = 0.10

# Watchtowers. Neutral control points at the centre and the two flanks of every map, nudged onto dry ground.
# Stand troops within TOWER_RADIUS for TOWER_CAPTURE_TIME seconds with nothing hostile inside it to take one;
# the owner sees TOWER_SIGHT around it. Anyone can take it back the same way.
TOWER_RADIUS = 140.0
TOWER_CAPTURE_TIME = 8.0
TOWER_SIGHT = 700.0
TOWER_HALF = 26.0

# Repair: one Engineer restores a building's full health in REPAIR_TIME seconds (more Engineers stack), and a
# full bar costs REPAIR_COST_RATIO of the building's price, charged as the health goes back on.
# Engineers also repair Siege Tanks, at the same rate and the same share of the tank's price.
# Artillery: a fixed gun that reaches beyond its own sight, so it needs something else to see the target. Its
# shells fly slowly in a high arc (visible all the way), land with splash, and it cannot hit anything close.
ARTILLERY_MIN_RANGE = 150.0
ARTILLERY_SPLASH = 55.0
ARTILLERY_SHELL_SPEED = 380.0    # world units a second; tank shells fly at 650
TANK_SHELL_SPEED = 650.0

# Shield generators: every friendly building within SHIELD_RADIUS carries up to SHIELD_MAX shield points that
# soak damage before the walls; after SHIELD_DELAY seconds without a hit they recharge at SHIELD_REGEN a second.
SHIELD_RADIUS = 320.0
SHIELD_MAX = 300.0
SHIELD_REGEN = 15.0
SHIELD_DELAY = 4.0

# Gold: a deposit worth a hundred normal mineral nodes. Drawn gold (crystal variant 3), mined like any other,
# but it does not run out — a spot worth holding for the whole match.
GOLD_AMOUNT = 150000

REPAIR_TIME = 30.0
REPAIR_COST_RATIO = 0.35


@dataclass(frozen=True)
class Difficulty:
    index: int
    name: str
    blurb: str
    income: float
    first_attack: float
    initial_wave: int
    pace: float
    worker_target: int


DIFFICULTIES = [
    Difficulty(0, "Easy", "Relaxed foe, late attacks", 0.7, 480, 5, 1.35, 12),
    Difficulty(1, "Normal", "A balanced commander", 1.0, 330, 8, 1.0, 16),
    Difficulty(2, "Hard", "Aggressive, rich economy", 1.35, 230, 10, 0.75, 20),
]


# ---------------------------------------------------------------- geometry

def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def dist(ax, ay, bx, by):
    return math.hypot(bx - ax, by - ay)


def square_rect(x, y, h):
    return (x - h, y - h, x + h, y + h)


def rect_distance(r, px, py):
    dx = max(r[0] - px, 0.0, px - r[2])
    dy = max(r[1] - py, 0.0, py - r[3])
    return math.hypot(dx, dy)


def rects_intersect(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def inset(r, d):
    return (r[0] + d, r[1] + d, r[2] - d, r[3] - d)


def angle_diff(a, b):
    """The signed shortest turn from a to b."""
    return (b - a + math.pi) % (2 * math.pi) - math.pi


def angle_lerp(a, b, t):
    return a + angle_diff(a, b) * min(1.0, t)


def fmt_time(t):
    s = int(t)
    return f"{s // 60:02d}:{s % 60:02d}"
