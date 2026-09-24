"""Saving and loading a single-player game.

A save is one JSON document — the map, every entity with its orders, the fog each side has explored, what
has been bought and built, and the computer players' plans — written by `world_to_dict` and read back by
`world_from_dict`. The macOS edition writes and reads the same document (SaveGame.swift), so a game saved on
one platform loads on the other. The format is versioned by SAVE_FORMAT; older formats are refused, not
guessed at.

Files live in the platform's data directory (see `saves_dir`): `quicksave.json` from F5, `autosave.json`
every few minutes, and whatever the player names from the menu.
"""
import base64
import json
import os
import sys
import time

import numpy as np

from . import defs
from .ai import AI
from .defs import DIFFICULTIES
from .defs import MISSION_BY_ID
from .entities import Crate, IDLE, Bridge, Building, Crystal, Unit, Watchtower

SAVE_FORMAT = 1


def saves_dir():
    if sys.platform == "win32":
        base = os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Roaming")
        return os.path.join(base, "FieldCommand", "saves")
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "fieldcommand", "saves")


# ---------------------------------------------------------------- orders

def _order_out(o):
    k = o[0]
    if k in ("move", "amove"):
        return [k, o[1], o[2]]
    if k in ("attack", "gather", "rebuild", "repair", "heal"):
        return [k, o[1].id]
    if k == "build":
        return [k, o[1], o[2], o[3]]
    return [k]


def _order_in(d, by_id):
    k = d[0]
    if k in ("move", "amove"):
        return (k, float(d[1]), float(d[2]))
    if k in ("attack", "gather", "rebuild", "repair", "heal"):
        t = by_id.get(d[1])
        return (k, t) if t is not None else IDLE
    if k == "build":
        return (k, d[1], float(d[2]), float(d[3]))
    return IDLE if k not in ("idle", "return") else (k,)


# ---------------------------------------------------------------- fog

def _bits_out(grid):
    return base64.b64encode(np.packbits(grid.explored.ravel())).decode("ascii")


def _bits_in(grid, text):
    flat = np.unpackbits(np.frombuffer(base64.b64decode(text), dtype=np.uint8))[:grid.rows * grid.cols]
    grid.explored[:] = flat.reshape(grid.rows, grid.cols).astype(bool)
    grid.version += 1


# ---------------------------------------------------------------- out

def world_to_dict(world, label=""):
    from . import __version__
    w = world
    units = []
    for u in w.units:
        if u.dead:
            continue
        units.append({"id": u.id, "kind": u.kind, "team": u.team, "x": u.x, "y": u.y, "angle": u.angle,
                      "gun_angle": u.gun_angle, "hp": u.hp, "max_hp": u.max_hp, "carrying": u.carrying,
                      "mode": u.mode, "mode_timer": u.mode_timer, "kills": u.kills, "rank": u.rank,
                      "cooldown": u.cooldown, "order": _order_out(u.order), "queued": [_order_out(q) for q in u.queued],
                      "home_crystal": u.home_crystal.id if u.home_crystal else None,
                      "resume_gather": u.resume_gather.id if u.resume_gather else None,
                      "resume_point": list(u.resume_point) if u.resume_point else None})
    buildings = []
    for b in w.buildings:
        if b.dead:
            continue
        buildings.append({"id": b.id, "kind": b.kind, "team": b.team, "x": b.x, "y": b.y, "hp": b.hp, "max_hp": b.max_hp,
                          "built": b.built, "progress": b.progress, "queue": list(b.queue), "queue_progress": b.queue_progress,
                          "rally": list(b.rally) if b.rally else None, "gun_angle": b.gun_angle,
                          "upgrades": sorted(b.upgrades), "upgrading": b.upgrading, "upgrade_progress": b.upgrade_progress,
                          "shield": b.shield})
    ai = {}
    for s, p in w.players.items():
        if p.ai is not None:
            a = p.ai
            ai[str(s)] = {"wave_size": a.wave_size, "next_wave": a.next_wave, "attackers": [u.id for u in a.attackers if not u.dead],
                          "seen": dict(a.seen), "next_raid": a.next_raid}
    return {
        "format": SAVE_FORMAT, "game": "field-command", "version": __version__, "label": label,
        "saved_at": int(time.time()), "map": w.map, "difficulty": w.difficulty.index, "elapsed": w.elapsed,
        "next_id": w._next_id,
        "players": [{"slot": p.slot, "name": p.name, "team": p.team, "is_ai": p.is_ai, "start": p.start, "alive": p.alive}
                    for p in w.players.values()],
        "resources": {str(s): v for s, v in w.resources.items()},
        "kits": {str(s): sorted(k) for s, k in w.kits.items()},
        "units_trained": {str(s): v for s, v in w.units_trained.items()},
        "units_lost": {str(s): v for s, v in w.units_lost.items()},
        "crystals_mined": {str(s): v for s, v in w.crystals_mined.items()},
        "trained_kinds": {str(s): dict(v) for s, v in w.trained_kinds.items()},
        "crystals": [{"id": c.id, "x": c.x, "y": c.y, "amount": c.amount, "max_amount": c.max_amount, "variant": c.variant}
                     for c in w.crystals if not c.dead],
        "shells": [[s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9].id if s[9] is not None else None]
                   for s in w.shells],
        "units": units, "buildings": buildings,
        "bridges": [{"id": b.id, "intact": b.intact, "hp": b.hp, "progress": b.progress} for b in w.bridges],
        "towers": [{"id": t.id, "owner": t.owner, "capturing": t.capturing, "progress": t.progress} for t in w.towers],
        "crates": [{"id": c.id, "x": c.x, "y": c.y, "kind": c.kind, "amount": c.amount, "born": c.born} for c in w.crates],
        "next_crate": w.next_crate,
        "mission": w.mission.id if w.mission else None, "mission_timer": w.mission_timer,
        "seed": w.seed, "rng": [w.rng.getstate()[0], list(w.rng.getstate()[1]), w.rng.getstate()[2]], "tick": w.tick,
        "reveals": {str(t): {str(i): until for i, until in r.items()} for t, r in w.reveals.items()},
        "ai": ai,
        "fog": {str(t): _bits_out(g) for t, g in w.fog.items()},
    }


# ---------------------------------------------------------------- in

def world_from_dict(data):
    """Rebuilds a World from a save. Raises ValueError for a document this version cannot read."""
    from .world import PlayerInfo, World
    if data.get("game") != "field-command" or data.get("format") != SAVE_FORMAT:
        raise ValueError(f"not a Field Command save this version can read (format {data.get('format')})")
    players = [PlayerInfo(p["slot"], p["name"], p["team"], is_ai=p["is_ai"], start=p["start"]) for p in data["players"]]
    w = World(data["map"], players, DIFFICULTIES[data["difficulty"]], seed=data.get("seed"))
    if data.get("rng") is not None:
        w.rng.setstate(tuple(tuple(x) if isinstance(x, list) else x for x in data["rng"]))
    w.tick = int(data.get("tick", 0))
    for p in data["players"]:
        w.players[p["slot"]].alive = p["alive"]
    # Start from nothing but the map: the constructor's opening base is replaced by what was saved.
    w.units, w.buildings, w.crystals = [], [], []
    w.by_id = {}
    for c in data["crystals"]:
        cr = Crystal(c["x"], c["y"], c["max_amount"], c["variant"], c["id"])
        cr.amount = c["amount"]
        w.crystals.append(cr)
        w.by_id[cr.id] = cr
    for saved, live in zip(data["bridges"], w.bridges):
        live.id, live.intact, live.hp, live.progress = saved["id"], saved["intact"], saved["hp"], saved["progress"]
    for c in data.get("crates", []):
        cr = Crate(c["id"], c["x"], c["y"], c["kind"], c["amount"], c["born"])
        w.crates.append(cr)
        w.by_id[cr.id] = cr
    w.next_crate = float(data.get("next_crate", w.next_crate))
    w.mission = MISSION_BY_ID.get(data.get("mission")) if data.get("mission") else None
    w.mission_timer = float(data.get("mission_timer", 0.0))
    for saved, live in zip(data["towers"], w.towers):
        live.id, live.owner, live.capturing, live.progress = saved["id"], saved["owner"], saved["capturing"], saved["progress"]
    for e in w.bridges + w.towers:
        w.by_id[e.id] = e
    w.kits = {int(s): set(v) for s, v in data["kits"].items()}
    for b in data["buildings"]:
        bd = Building(w, b["kind"], b["team"], b["x"], b["y"], b["built"])
        bd.id = b["id"]
        bd.hp, bd.max_hp, bd.progress = b["hp"], b["max_hp"], b["progress"]
        bd.queue, bd.queue_progress = list(b["queue"]), b["queue_progress"]
        bd.rally = tuple(b["rally"]) if b["rally"] else None
        bd.gun_angle = b["gun_angle"]
        bd.upgrades, bd.upgrading, bd.upgrade_progress = set(b["upgrades"]), b["upgrading"], b["upgrade_progress"]
        bd.shield = float(b.get("shield", 0.0))
        w.buildings.append(bd)
        w.by_id[bd.id] = bd
    units = []
    for u in data["units"]:
        un = Unit(w, u["kind"], u["team"], u["x"], u["y"])
        un.id = u["id"]
        un.angle, un.gun_angle = u["angle"], u["gun_angle"]
        un.hp, un.max_hp, un.carrying = u["hp"], u["max_hp"], u["carrying"]
        un.mode, un.mode_timer, un.kills, un.rank, un.cooldown = u["mode"], u["mode_timer"], u["kills"], u["rank"], u["cooldown"]
        un.last_x, un.last_y = un.x, un.y
        w.units.append(un)
        w.by_id[un.id] = un
        units.append((un, u))
    for un, u in units:                      # orders after every entity exists, so references resolve
        un.order = _order_in(u["order"], w.by_id)
        un.queued = [_order_in(q, w.by_id) for q in u["queued"]]
        un.home_crystal = w.by_id.get(u["home_crystal"]) if u["home_crystal"] is not None else None
        un.resume_gather = w.by_id.get(u["resume_gather"]) if u["resume_gather"] is not None else None
        un.resume_point = tuple(u["resume_point"]) if u["resume_point"] else None
    w._next_id = max(data["next_id"], max((e.id for e in w.by_id.values()), default=0) + 1)
    w.elapsed = data["elapsed"]
    w.resources = {int(s): float(v) for s, v in data["resources"].items()}
    w.units_trained = {int(s): v for s, v in data["units_trained"].items()}
    w.units_lost = {int(s): v for s, v in data["units_lost"].items()}
    w.crystals_mined = {int(s): v for s, v in data["crystals_mined"].items()}
    w.shells = [[*s[:9], w.by_id.get(s[9]) if s[9] is not None else None] for s in data.get("shells", [])]
    w.trained_kinds = {int(s): dict(v) for s, v in data["trained_kinds"].items()}
    for s, a in data["ai"].items():
        p = w.players[int(s)]
        p.ai = AI(w, p.slot)
        p.ai.wave_size, p.ai.next_wave, p.ai.next_raid = a["wave_size"], a["next_wave"], a["next_raid"]
        p.ai.seen = {k: float(v) for k, v in a["seen"].items()}
        p.ai.attackers = [w.by_id[i] for i in a["attackers"] if i in w.by_id]
    for t, r in data["reveals"].items():
        w.reveals[int(t)] = {int(i): until for i, until in r.items()}
    for t, bits in data["fog"].items():
        if int(t) in w.fog:
            _bits_in(w.fog[int(t)], bits)
    w.bridges_changed()
    w.update_visibility()
    return w


# ---------------------------------------------------------------- files

def save_path(name):
    return os.path.join(saves_dir(), f"{name}.json")


def write_save(world, name, label=""):
    os.makedirs(saves_dir(), exist_ok=True)
    path = save_path(name)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(world_to_dict(world, label), f, separators=(",", ":"))
    os.replace(tmp, path)
    return path


def read_save(name):
    with open(save_path(name)) as f:
        return world_from_dict(json.load(f))


def list_saves():
    """[(name, label, saved_at, elapsed)] newest first, from whatever is on disk."""
    out = []
    if not os.path.isdir(saves_dir()):
        return out
    for fn in os.listdir(saves_dir()):
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(saves_dir(), fn)) as f:
                head = json.load(f)
            out.append((fn[:-5], head.get("label", ""), head.get("saved_at", 0), head.get("elapsed", 0)))
        except (OSError, ValueError):
            continue
    out.sort(key=lambda r: -r[2])
    return out
