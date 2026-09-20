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
UNIT_KINDS = ["worker", "marine", "tank"]
BUILDING_KINDS = ["hq", "depot", "barracks", "factory", "turret"]


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


UNITS = {
    "worker": UnitStats("Engineer", "EN", 50, 1, 45, 95, 6, 4, 1.2, 9, 10, 220, 0, "W",
                        "Mines crystal and constructs buildings."),
    "marine": UnitStats("Ranger", "RG", 50, 1, 60, 88, 150, 7, 0.75, 10, 12, 260, 0, "R",
                        "Versatile rifle infantry."),
    "tank": UnitStats("Siege Tank", "TK", 150, 3, 220, 62, 230, 32, 2.2, 17, 22, 280, 45, "T",
                      "Long-range armor. Shells deal splash damage."),
}


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
    "barracks": BuildingStats("Barracks", "Barracks", "BK", 150, 900, 64, 35, 0, ("marine",), "hq", 0, 0, 0, 240, "B",
                              "Trains Rangers."),
    "factory": BuildingStats("Factory", "Factory", "FC", 200, 1100, 70, 45, 0, ("tank",), "barracks", 0, 0, 0, 240, "F",
                             "Builds Siege Tanks."),
    "turret": BuildingStats("Gun Turret", "Turret", "GT", 100, 380, 30, 22, 0, (), "barracks", 210, 11, 0.7, 270, "T",
                            "Static defense. Fires on nearby enemies."),
}
BUILD_MENU = ["hq", "depot", "barracks", "factory", "turret"]


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


def angle_lerp(a, b, t):
    d = (b - a + math.pi) % (2 * math.pi) - math.pi
    return a + d * min(1.0, t)


def fmt_time(t):
    s = int(t)
    return f"{s // 60:02d}:{s % 60:02d}"
