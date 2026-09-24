"""The balance runner: plays computer-only games headless and writes what happened, so balance is decided on
evidence.  python -m fieldcommand.batch --games 4 --maps twin_ridges,river_crossing --difficulty 1 --out runs.csv

Each row is one player in one game: map, seed, slot, team, difficulty, winner or not, game length, units
trained by kind, units lost, buildings built by kind, crystal mined, kit bought, upgrades bought. The
summary printed afterwards gives win rate by start slot per map, average length, and the unit mix.
"""
import argparse
import collections
import csv
import sys
import time

from . import mapgen
from .defs import BUILDING_KINDS, DIFFICULTIES, UNIT_KINDS
from .world import PlayerInfo, World

DT = 1.0 / 30


def play(map_id, seed, difficulty, limit=3000.0):
    spec = mapgen.BY_ID[map_id]
    players = [PlayerInfo(i, f"AI{i}", i + 1, is_ai=True, start=i) for i in range(spec["players"])]
    w = World(mapgen.generate(map_id), players, DIFFICULTIES[difficulty], seed=seed)
    built = collections.defaultdict(collections.Counter)
    upgrades = collections.Counter()
    t0 = time.time()
    while not w.game_over and w.elapsed < limit:
        w.step(DT)
        for ev in w.events:
            if ev[0] == "built":
                built[ev[1]][ev[2]] += 1
            elif ev[0] == "upgraded":
                upgrades[ev[1]] += 1
        w.events.clear()
    rows = []
    for s, p in w.players.items():
        row = {"map": map_id, "seed": seed, "slot": s, "team": p.team, "difficulty": DIFFICULTIES[difficulty].name,
               "won": int(w.game_over and w.winner_team == p.team), "over": int(w.game_over), "length": round(w.elapsed),
               "units_trained": w.units_trained[s], "units_lost": w.units_lost[s], "mined": w.crystals_mined[s],
               "kits": len(w.kits.get(s, ())), "upgrades": upgrades[s], "real_seconds": round(time.time() - t0, 1)}
        for k in UNIT_KINDS:
            row[f"trained_{k}"] = w.trained_kinds[s].get(k, 0)
        for k in BUILDING_KINDS:
            row[f"built_{k}"] = built[s][k]
        rows.append(row)
    return rows


def summarise(rows):
    by_map = collections.defaultdict(list)
    for r in rows:
        by_map[r["map"]].append(r)
    lines = []
    for m, rs in by_map.items():
        games = {r["seed"] for r in rs}
        slots = sorted({r["slot"] for r in rs})
        wins = {s: sum(r["won"] for r in rs if r["slot"] == s) for s in slots}
        unfinished = sum(1 for r in rs if r["slot"] == slots[0] and not r["over"])
        lengths = [r["length"] for r in rs if r["slot"] == slots[0]]
        lines.append(f"{m}: {len(games)} games, avg {sum(lengths) / len(lengths):.0f}s, {unfinished} unfinished")
        lines.append("  wins by start slot: " + ", ".join(f"{s}:{wins[s]}" for s in slots))
        mix = collections.Counter()
        for r in rs:
            for k in UNIT_KINDS:
                mix[k] += r[f"trained_{k}"]
        total = max(1, sum(mix.values()))
        lines.append("  unit mix: " + ", ".join(f"{k} {100 * mix[k] / total:.0f}%" for k in UNIT_KINDS))
        blt = collections.Counter()
        for r in rs:
            for k in BUILDING_KINDS:
                blt[k] += r[f"built_{k}"]
        lines.append("  buildings per game: " + ", ".join(f"{k} {blt[k] / len(games):.1f}" for k in BUILDING_KINDS))
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Play computer-only games headless and report what happened.")
    ap.add_argument("--games", type=int, default=3, help="games per map")
    ap.add_argument("--maps", default="twin_ridges,river_crossing,highland_pass,four_corners,crossroads")
    ap.add_argument("--difficulty", type=int, default=1)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--limit", type=float, default=3000.0, help="give up on a game after this many simulated seconds")
    ap.add_argument("--out", default="", help="CSV file for the per-player rows")
    a = ap.parse_args(argv)
    rows = []
    for m in a.maps.split(","):
        for i in range(a.games):
            rows += play(m.strip(), a.seed + i, a.difficulty, a.limit)
            r = rows[-1]
            print(f"{m}: seed {a.seed + i} {'over' if r['over'] else 'unfinished'} at {r['length']}s "
                  f"({r['real_seconds']}s real)", file=sys.stderr)
    if a.out:
        with open(a.out, "w", newline="") as f:
            wr = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            wr.writeheader()
            wr.writerows(rows)
    print(summarise(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
