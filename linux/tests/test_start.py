"""The start of a game: crystal in the bank, an established base, and off-map reinforcements for crystal."""
import json
import math

from conftest import DT, hq_of, make_world, run
from fieldcommand import mapgen, net, replay, save
from fieldcommand.defs import (DIFFICULTIES, ESTABLISHED, REINFORCEMENTS, REINFORCE_COOLDOWN, START_BASES, START_CRYSTAL,
                               START_CRYSTAL_OPTIONS, UNITS, WORLD_H, WORLD_W)
from fieldcommand.world import PlayerInfo, World


def world(**kw):
    spec = mapgen.resolve("twin_ridges", 2)
    ps = [PlayerInfo(i, f"P{i}", i + 1, is_ai=False, start=i) for i in range(2)]
    w = World(spec, ps, DIFFICULTIES[1], seed=6, **kw)
    for u in list(w.units):
        u.command(("idle",))
    return w


def test_starting_crystal_defaults_to_five_thousand_and_can_be_set():
    assert START_CRYSTAL == 5000 and START_CRYSTAL in START_CRYSTAL_OPTIONS
    assert make_world().resources[0] == 5000
    w = world(start_crystal=20000)
    assert w.resources == {0: 20000.0, 1: 20000.0} and w.start_crystal == 20000


def test_an_established_base_stands_from_the_first_second():
    assert [b[0] for b in START_BASES] == ["fresh", "established"]
    fresh = world()
    assert [b.kind for b in fresh.buildings if b.team == 0] == ["hq"]
    w = world(start_base="established")
    for slot in (0, 1):
        kinds = sorted(b.kind for b in w.buildings if b.team == slot and b.built)
        assert kinds.count("depot") == 2 and "barracks" in kinds and "factory" in kinds and "turret" in kinds
        hq = hq_of(w, slot)
        for b in w.buildings:
            if b.team == slot and b.kind != "hq":
                assert 150 < math.hypot(b.x - hq.x, b.y - hq.y) < 420
    assert len(ESTABLISHED) == 5
    assert w.supply_cap(0) > fresh.supply_cap(0)                       # the depots count from the start


def test_reinforcements_walk_in_from_your_edge_for_crystal_with_a_cooldown():
    w = world()
    hq = hq_of(w, 0)
    before = len(w.units)
    assert w.reinforce_left(0) == 0
    w.apply(0, ["reinforce", "marine"])
    count, cost = REINFORCEMENTS["marine"]
    new = [u for u in w.units if u.team == 0 and u.kind == "marine"]
    assert len(new) == count and len(w.units) == before + count and w.resources[0] == START_CRYSTAL - cost
    ex, ey = w.edge_point(0)
    assert min(ex, ey, WORLD_W - ex, WORLD_H - ey) == 80
    assert all(math.hypot(u.x - ex, u.y - ey) < 120 for u in new)
    assert all(u.order[0] == "move" and 150 < math.hypot(u.order[1] - hq.x, u.order[2] - hq.y) < 300 for u in new)
    assert any(e[0] == "msg" and "Reinforcements" in e[2] for e in w.events)
    assert abs(w.reinforce_left(0) - REINFORCE_COOLDOWN) < 1e-6
    w.apply(0, ["reinforce", "tank"])                                    # too soon: nothing happens
    assert not any(u.kind == "tank" for u in w.units if u.team == 0) and w.resources[0] == START_CRYSTAL - cost
    w.elapsed += REINFORCE_COOLDOWN
    w.apply(0, ["reinforce", "tank"])
    assert sum(1 for u in w.units if u.team == 0 and u.kind == "tank") == REINFORCEMENTS["tank"][0]
    w.resources[1] = 10
    w.apply(1, ["reinforce", "marine"])
    assert not any(u.kind == "marine" for u in w.units if u.team == 1)   # no crystal, no column
    assert net.snapshot_for(w, 0, [])["rf"] > 0 and net.snapshot_for(w, 1, [])["rf"] == 0


def test_the_setup_travels_in_saves_and_replays():
    w = world(start_crystal=10000, start_base="established")
    w.apply(0, ["reinforce", "marine"])
    w2 = save.world_from_dict(json.loads(json.dumps(save.world_to_dict(w, "t"))))
    assert w2.start_crystal == 10000 and w2.start_base == "established" and w2.reinforce_left(0) > 0
    rec = replay.Replay(json.loads(json.dumps(replay.replay_to_dict(w, 0))))
    assert rec.start_crystal == 10000 and rec.start_base == "established"
