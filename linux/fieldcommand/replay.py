"""Replays: a recorded game is its seed, its setup and every command it received, by tick. Fed back into a
fresh simulation that gives exactly the same game, which is what makes replays small — a few kilobytes for
an hour — and what makes them a bug report's best friend."""
import json
import os
import time

from .save import saves_dir

REPLAY_FORMAT = 1
KEEP_REPLAYS = 40        # the newest this many are kept; older ones are pruned as new games are recorded


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
        self.mode = data.get("mode", "annihilation")
        self.start_crystal = int(data.get("start_crystal", 2000))
        self.start_base = data.get("start_base", "fresh")
        self.veterans = [(str(k), int(n)) for k, n in data.get("veterans", [])]


def replays_dir():
    return os.path.join(os.path.dirname(saves_dir()), "replays")


def path_for(name):
    return os.path.join(replays_dir(), f"{name}.json")


def replay_to_dict(world, viewer=0, label=""):
    from . import __version__
    return {"game": "field-command", "format": REPLAY_FORMAT, "version": __version__, "label": label,
            "saved_at": int(time.time()), "map": world.map["id"], "difficulty": world.difficulty.index,
            "seed": world.seed, "mission": world.mission.id if world.mission else None, "viewer": viewer, "mode": world.mode,
            "start_crystal": world.start_crystal, "start_base": world.start_base,
            "veterans": [[k, n] for k, n in world.veterans],
            "players": [{"slot": p.slot, "name": p.name, "team": p.team, "ai": p.is_ai} for p in world.players.values()],
            "elapsed": world.elapsed, "ticks": world.tick,
            "winner_team": world.winner_team,
            "commands": [[t, s, c] for t, s, c in world.record]}


def replay_name(world, when=None):
    """A file name for a game: the date and time it was recorded and the map, so the browser reads well."""
    return time.strftime("%Y%m%d-%H%M%S", time.localtime(when)) + "_" + world.map["id"]


def write_replay(world, name=None, viewer=0, label=""):
    os.makedirs(replays_dir(), exist_ok=True)
    path = path_for(name or replay_name(world))
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(replay_to_dict(world, viewer, label), f, separators=(",", ":"))
    os.replace(tmp, path)
    prune_replays()
    return path


def prune_replays(keep=KEEP_REPLAYS):
    """Drops the oldest recordings beyond `keep`."""
    for r in list_replays()[keep:]:
        try:
            os.remove(path_for(r[0]))
        except OSError:
            pass


def result_of(data):
    """"Won", "Lost" or "Unfinished" from the viewer's side of a recorded game."""
    winner = data.get("winner_team")
    if winner is None:
        return "Unfinished"
    viewer = int(data.get("viewer", 0))
    mine = next((p["team"] for p in data.get("players", []) if p["slot"] == viewer), None)
    return "Won" if mine == winner else "Lost"


def read_replay(name="last"):
    with open(path_for(name)) as f:
        data = json.load(f)
    if data.get("game") != "field-command" or data.get("format") != REPLAY_FORMAT:
        raise ValueError("not a Field Command replay this version can read")
    return Replay(data)


def list_replays():
    """(name, label, saved_at, elapsed, map id, result, difficulty), newest first."""
    out, when = [], {}
    try:
        names = os.listdir(replays_dir())
    except OSError:
        return out
    for fn in names:
        if not fn.endswith(".json"):
            continue
        try:
            path = os.path.join(replays_dir(), fn)
            with open(path) as f:
                d = json.load(f)
            out.append((fn[:-5], d.get("label", ""), int(d.get("saved_at", 0)), float(d.get("elapsed", 0)),
                        d.get("map", ""), result_of(d), int(d.get("difficulty", 1))))
            when[fn[:-5]] = os.path.getmtime(path)
        except (OSError, ValueError):
            continue
    # Newest first; two recordings in the same second are ordered by the file's own timestamp.
    return sorted(out, key=lambda r: (r[2], when.get(r[0], 0.0)), reverse=True)
