"""Replays: a recorded game is its seed, its setup and every command it received, by tick. Fed back into a
fresh simulation that gives exactly the same game, which is what makes replays small — a few kilobytes for
an hour — and what makes them a bug report's best friend."""
import json
import os
import time

from .save import saves_dir

REPLAY_FORMAT = 1


class Replay:
    def __init__(self, data):
        self.data = data
        self.map = data["map"]
        self.players = data["players"]
        self.difficulty = int(data["difficulty"])
        self.seed = int(data["seed"])
        self.mission = data.get("mission")
        self.viewer = int(data.get("viewer", 0))
        self.commands = [(int(t), int(slot), cmd) for t, slot, cmd in data["commands"]]
        self.next = 0
        self.elapsed = float(data.get("elapsed", 0))
        self.label = data.get("label", "")


def replays_dir():
    return os.path.join(os.path.dirname(saves_dir()), "replays")


def path_for(name):
    return os.path.join(replays_dir(), f"{name}.json")


def replay_to_dict(world, viewer=0, label=""):
    from . import __version__
    return {"game": "field-command", "format": REPLAY_FORMAT, "version": __version__, "label": label,
            "saved_at": int(time.time()), "map": world.map["id"], "difficulty": world.difficulty.index,
            "seed": world.seed, "mission": world.mission.id if world.mission else None, "viewer": viewer,
            "players": [{"slot": p.slot, "name": p.name, "team": p.team, "ai": p.is_ai} for p in world.players.values()],
            "elapsed": world.elapsed, "ticks": world.tick,
            "winner_team": world.winner_team,
            "commands": [[t, s, c] for t, s, c in world.record]}


def write_replay(world, name="last", viewer=0, label=""):
    os.makedirs(replays_dir(), exist_ok=True)
    path = path_for(name)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(replay_to_dict(world, viewer, label), f, separators=(",", ":"))
    os.replace(tmp, path)
    return path


def read_replay(name="last"):
    with open(path_for(name)) as f:
        data = json.load(f)
    if data.get("game") != "field-command" or data.get("format") != REPLAY_FORMAT:
        raise ValueError("not a Field Command replay this version can read")
    return Replay(data)


def list_replays():
    """(name, label, saved_at, elapsed), newest first."""
    out = []
    try:
        names = os.listdir(replays_dir())
    except OSError:
        return out
    for fn in names:
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(replays_dir(), fn)) as f:
                d = json.load(f)
            out.append((fn[:-5], d.get("label", ""), int(d.get("saved_at", 0)), float(d.get("elapsed", 0))))
        except (OSError, ValueError):
            continue
    return sorted(out, key=lambda r: -r[2])
