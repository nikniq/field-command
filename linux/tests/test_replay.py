"""Determinism and replays: the same seed and commands give the same game; a recorded game replays exactly;
the batch runner reports."""
import json
import os

from conftest import hq_of, make_world
from fieldcommand import mapgen, replay
from fieldcommand.defs import DIFFICULTIES
from fieldcommand.world import PlayerInfo, World

DT = 1 / 30


def signature(w):
    return ([(u.id, u.kind, u.team, round(u.x, 3), round(u.y, 3), round(u.hp, 3), u.order[0]) for u in w.units if not u.dead],
            [(b.id, b.kind, round(b.hp, 3), b.built, len(b.queue)) for b in w.buildings if not b.dead],
            {s: round(v, 3) for s, v in w.resources.items()}, w.tick, w.next_crate, len(w.crates))


def fresh(seed):
    ps = [PlayerInfo(i, f"P{i}", i + 1, is_ai=i > 0) for i in range(2)]
    return World(mapgen.generate("twin_ridges"), ps, DIFFICULTIES[1], seed=seed)


def scripted(w):
    """A few human commands at fixed ticks, through apply so they are recorded."""
    hq = hq_of(w, 0)
    eng = [u for u in w.units if u.team == 0 and u.kind == "worker"]
    for t in range(1, 30 * 90 + 1):
        if t == 10:
            w.apply(0, ["train", [hq.id], "worker"])
        if t == 40:
            w.apply(0, ["build", eng[0].id, "barracks", hq.x + 300, hq.y, False])
        if t == 900:
            w.apply(0, ["move", [u.id for u in eng[1:3]], hq.x + 500, hq.y + 200, False, False])
        w.step(DT)
        w.events.clear()


def test_the_same_seed_and_commands_give_the_same_game():
    a, b = fresh(7), fresh(7)
    scripted(a)
    scripted(b)
    assert signature(a) == signature(b)
    c = fresh(8)
    scripted(c)
    assert signature(c) != signature(a)


def test_a_recorded_game_replays_exactly(tmp_path, monkeypatch):
    monkeypatch.setattr(replay, "replays_dir", lambda: str(tmp_path))
    a = fresh(11)
    scripted(a)
    path = replay.write_replay(a, "last", viewer=0)
    assert os.path.exists(path) and os.path.getsize(path) < 20000
    rec = replay.read_replay("last")
    assert rec.seed == 11 and rec.map == "twin_ridges" and len(rec.commands) == 3     # people only; the computer re-decides
    ps = [PlayerInfo(p["slot"], p["name"], p["team"], is_ai=p["ai"]) for p in rec.players]
    b = World(mapgen.generate(rec.map), ps, DIFFICULTIES[rec.difficulty], seed=rec.seed)
    while b.tick < a.tick:
        while rec.next < len(rec.commands) and rec.commands[rec.next][0] <= b.tick:
            _t, slot, cmd = rec.commands[rec.next]
            b._apply(slot, cmd)
            rec.next += 1
        b.step(DT)
        b.events.clear()
    assert signature(b) == signature(a)
    assert replay.list_replays()[0][0] == "last"


def test_a_replay_session_watches_and_ignores_input(tmp_path, monkeypatch):
    monkeypatch.setattr(replay, "replays_dir", lambda: str(tmp_path))
    from fieldcommand.session import LocalSession
    a = fresh(3)
    scripted(a)
    replay.write_replay(a, "last", viewer=0)
    s = LocalSession.replay("last")
    assert s.spectating and s.world.seed == 3
    hq = hq_of(s.world, 0)
    s.send(["train", [hq.id], "worker"])          # ignored: a replay is watched, not played
    assert not s.world.record
    for _ in range(40):
        s.update(1 / 30)
    assert s.world.tick >= 30 and s.replay.next >= 1


def test_the_batch_runner_reports(tmp_path):
    from fieldcommand import batch
    out = tmp_path / "runs.csv"
    rows = batch.play("twin_ridges", 5, 1, limit=60)
    assert len(rows) == 2 and all("trained_marine" in r for r in rows)
    text = batch.summarise(rows)
    assert "twin_ridges: 1 games" in text and "wins by start slot" in text
    assert batch.main(["--games", "1", "--maps", "twin_ridges", "--limit", "30", "--out", str(out)]) == 0
    assert out.exists()
