"""Shared fixtures. The tests drive the simulation (World) directly: pure Python + numpy, no pygame, no window.

Run from the linux/ directory:  python -m pytest tests
"""
import os
import sys
import tempfile

# Never touch the real settings file.
os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp()
os.environ["APPDATA"] = os.environ["XDG_CONFIG_HOME"]
os.environ.setdefault("XDG_DATA_HOME", tempfile.mkdtemp())     # saves and replays stay out of the real home too

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest  # noqa: E402

from fieldcommand import mapgen  # noqa: E402
from fieldcommand.defs import DIFFICULTIES  # noqa: E402
from fieldcommand.world import PlayerInfo, World  # noqa: E402

DT = 1 / 30


def make_world(map_id="twin_ridges", players=2, ai=False, teams=0, difficulty=1, seed=None):
    """A world with `players` slots; nobody is AI-controlled unless asked, so the test holds the orders."""
    spec = mapgen.resolve(map_id, players)
    team = (lambda i: i % teams + 1) if teams >= 2 else (lambda i: i + 1)
    ps = [PlayerInfo(i, f"P{i}", team(i), is_ai=ai, start=i) for i in range(players)]
    return World(spec, ps, DIFFICULTIES[difficulty], seed=seed)


def run(world, seconds, until=None):
    """Steps the world for up to `seconds`, stopping early when `until()` is true."""
    for _ in range(int(seconds / DT)):
        world.step(DT)
        world.events.clear()
        if until is not None and until():
            return True
    return until() if until is not None else True


def idle_everyone(world, slot):
    """Stops the starting Engineers mining, so a player's bank only moves for what the test does."""
    for u in world.units:
        if u.team == slot:
            u.command(("idle",))


def hq_of(world, slot):
    return next(b for b in world.buildings if b.team == slot and b.kind == "hq")


@pytest.fixture
def world():
    return make_world()
