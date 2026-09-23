"""Campaign missions: timed survival, holding the gold, the catalogue, and how they travel."""
from conftest import hq_of, idle_everyone, make_world, run
from fieldcommand import mapgen, net, save
from fieldcommand.defs import CAMPAIGN, DIFFICULTIES, MISSION_BY_ID
from fieldcommand.entities import Unit
from fieldcommand.world import PlayerInfo, World


def mission_world(mid):
    m = MISSION_BY_ID[mid]
    spec = mapgen.resolve(m.map, 1 + m.opponents)
    ps = [PlayerInfo(i, f"P{i}", (i % m.teams + 1) if m.teams >= 2 else i + 1, is_ai=i > 0) for i in range(1 + m.opponents)]
    w = World(spec, ps, DIFFICULTIES[m.difficulty], mission=mid)
    return w, m


def test_the_catalogue_is_playable():
    ids = [m.id for m in CAMPAIGN]
    assert len(ids) == len(set(ids)) == 5
    for m in CAMPAIGN:
        assert m.map in mapgen.BY_ID and mapgen.BY_ID[m.map]["players"] >= 1 + m.opponents
        assert m.win in ("destroy", "survive", "hold")
        assert (m.win == "hold") == bool(m.hold)
        assert 0 <= m.difficulty < len(DIFFICULTIES)


def test_survive_is_won_when_the_clock_runs_out_and_you_still_stand():
    w, m = mission_world("hold_the_line")
    idle_everyone(w, 0)
    idle_everyone(w, 1)
    w.players[1].ai = None
    w.elapsed = m.seconds - 2
    assert run(w, 4, until=lambda: w.game_over)
    assert w.winner_team == w.players[0].team
    assert w.mission_progress() >= m.seconds


def test_hold_counts_only_while_the_ring_is_yours_and_clear():
    w, m = mission_world("gold_run")
    idle_everyone(w, 0)
    idle_everyone(w, 1)
    w.players[1].ai = None
    hx, hy, hr = m.hold
    assert any(c.gold and abs(c.x - hx) < hr and abs(c.y - hy) < hr for c in w.crystals)     # the gold is in the ring
    r = Unit(w, "marine", 0, hx, hy)
    w._add(r)
    r.command(("idle",))
    run(w, 3)
    assert 2.5 < w.mission_timer < 3.5
    foe = Unit(w, "marine", 1, hx + 40, hy)
    w._add(foe)
    foe.command(("idle",))
    r.hp = 9999
    run(w, 0.5)
    assert w.mission_timer == 0                    # an enemy in the ring resets the count
    foe.take_damage(99999, None)
    w.mission_timer = m.seconds - 1
    assert run(w, 3, until=lambda: w.game_over)
    assert w.winner_team == w.players[0].team


def test_progress_travels_in_snapshots_and_saves():
    w, m = mission_world("hold_the_line")
    w.elapsed = 100
    assert net.snapshot_for(w, 0, [])["ms"] == 100
    w2 = save.world_from_dict(save.world_to_dict(w, "mission"))
    assert w2.mission is not None and w2.mission.id == "hold_the_line"
    plain = make_world()
    assert net.snapshot_for(plain, 0, [])["ms"] == 0 and plain.mission is None
