"""Skirmish modes: King of the Hill's ring and timers, Sudden Death's elimination, and how the mode travels."""
import json

from conftest import DT, hq_of, make_world, run
from fieldcommand import mapgen, replay, save
from fieldcommand.ai import AI
from fieldcommand.defs import DIFFICULTIES, KOTH_HOLD, KOTH_RADIUS, MODES, MODE_BY_ID
from fieldcommand.entities import Unit
from fieldcommand.world import PlayerInfo, World


def world(mode, ai=False, players=2):
    spec = mapgen.resolve("twin_ridges", players)
    ps = [PlayerInfo(i, f"P{i}", i + 1, is_ai=ai, start=i) for i in range(players)]
    w = World(spec, ps, DIFFICULTIES[1], mode=mode, seed=4)
    for u in list(w.units):
        u.command(("idle",))
    return w


def test_the_catalogue_and_the_ring():
    assert [m[0] for m in MODES] == ["annihilation", "koth", "sudden"] and set(MODE_BY_ID) == {m[0] for m in MODES}
    w = world("koth")
    hx, hy = w.ring
    assert any(c.gold and abs(c.x - hx) < KOTH_RADIUS and abs(c.y - hy) < KOTH_RADIUS for c in w.crystals)
    assert world("nonsense").mode == "annihilation"


def test_king_of_the_hill_counts_an_uncontested_hold_and_the_first_to_three_minutes_wins():
    w = world("koth")
    hx, hy = w.ring
    r = Unit(w, "marine", 0, hx, hy)
    w._add(r)
    r.command(("idle",))
    run(w, 3)
    assert 2.5 < w.hold[1] < 3.5 and w.hold.get(2, 0.0) == 0.0
    foe = Unit(w, "marine", 1, hx + 40, hy)
    w._add(foe)
    foe.command(("idle",))
    r.hp = foe.hp = 9999
    run(w, 0.5)
    assert w.hold[1] == 0.0 and w.hold[2] == 0.0                         # contested: nobody's clock runs
    foe.take_damage(99999, None)
    w.hold[1] = KOTH_HOLD - 1
    assert run(w, 3, until=lambda: w.game_over) and w.winner_team == 1


def test_sudden_death_knocks_out_a_side_with_its_last_command_center():
    w = world("sudden")
    hq0 = hq_of(w, 0)
    depot = w.start_building("depot", hq0.x + 300, hq0.y, 0)
    depot.built = True
    hq0.take_damage(99999, None)
    run(w, 1)
    assert not w.players[0].alive and w.game_over and w.winner_team == 2
    assert not any(b.team == 0 for b in w.buildings)                     # the depot went with it
    w2 = world("annihilation")
    hq_of(w2, 0).take_damage(99999, None)
    w2.start_building("depot", 900, 900, 0).built = True
    run(w2, 1)
    assert w2.players[0].alive                                           # the usual rule: a depot still stands


def test_the_computer_goes_for_the_ring_until_it_leads_there():
    w = world("koth")
    ai = AI(w, 1, opening="rush")
    w.players[1].is_ai, w.players[1].ai = True, ai
    hq = hq_of(w, 1)
    assert ai._objective(hq_of(w, 0)) == w.ring
    w.hold[2], w.hold[1] = 30.0, 5.0
    assert ai._objective(hq_of(w, 0)) == (hq_of(w, 0).x, hq_of(w, 0).y)  # leading: on to the enemy base
    w.hold[2], w.hold[1] = 5.0, 30.0
    assert ai._objective(hq_of(w, 0)) == w.ring


def test_the_mode_travels_in_saves_replays_and_snapshots():
    from fieldcommand import net
    w = world("koth")
    w.hold[1] = 12.5
    w2 = save.world_from_dict(json.loads(json.dumps(save.world_to_dict(w, "t"))))
    assert w2.mode == "koth" and w2.hold == {1: 12.5}
    rec = replay.Replay(json.loads(json.dumps(replay.replay_to_dict(w, 0))))
    assert rec.mode == "koth"
    snap = net.snapshot_for(w, 0, [])
    assert snap["hold"] == {"1": 12.5}
    assert net.snapshot_for(world("annihilation"), 0, [])["hold"] == {}
