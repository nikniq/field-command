"""Campaign missions: timed survival, holding the gold, the catalogue, and how they travel."""
from conftest import DT, hq_of, idle_everyone, make_world, run
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


# ---------------------------------------------------------------- the script (1.21)

def test_every_script_is_well_formed():
    from fieldcommand.defs import UNIT_KINDS
    for m in CAMPAIGN:
        assert m.events, m.id
        ats = [e[1] for e in m.events]
        assert ats == sorted(ats) and ats[0] > 0
        for e in m.events:
            assert e[0] in ("text", "spawn") and e[-1]
            if e[0] == "spawn":
                _, _, owner, unit, count, src, target = e[:7]
                assert 0 <= owner <= m.opponents and 0 <= src <= m.opponents and -1 <= target <= m.opponents
                assert unit in UNIT_KINDS and count > 0


def quiet(mid):
    w, m = mission_world(mid)
    for s in w.players:
        idle_everyone(w, s)
        w.players[s].ai = None
    return w, m


def fire_next(w, m):
    """Runs the clock up to the next scripted event and steps it through; returns the event and the new units."""
    ev = m.events[w.mission_fired]
    w.elapsed = ev[1] - DT / 2
    before = set(id(u) for u in w.units)
    w.events.clear()
    w.step(DT)
    return ev, [u for u in w.units if id(u) not in before]


def test_command_speaks_and_reinforcements_walk_in_from_your_edge():
    import math
    from fieldcommand.defs import WORLD_H, WORLD_W
    w, m = quiet("first_light")
    ev, new = fire_next(w, m)
    assert ev[0] == "text" and not new and ("msg", 0, ev[2], "good") in w.events
    ev, new = fire_next(w, m)
    assert ev[0] == "spawn" and ev[2] == 0
    assert len(new) == ev[4] and all(u.kind == ev[3] and u.team == 0 for u in new)
    ex, ey = w.edge_point(0)
    assert min(ex, ey, WORLD_W - ex, WORLD_H - ey) == 80                        # on the map edge
    assert all(math.hypot(u.x - ex, u.y - ey) < 120 for u in new)
    hq = hq_of(w, 0)
    for u in new:                                                                # allies walk home, stopping short
        assert u.order[0] == "move" and 150 < math.hypot(u.order[1] - hq.x, u.order[2] - hq.y) < 300
    assert ("msg", 0, ev[7], "good") in w.events and w.mission_fired == 2


def test_enemy_columns_attack_move_on_their_target():
    w, m = quiet("hold_the_line")
    while m.events[w.mission_fired][2] != 1:
        fire_next(w, m)
    ev, new = fire_next(w, m)
    hq = hq_of(w, 0)
    assert len(new) == ev[4] and all(u.team == 1 and u.order == ("amove", hq.x, hq.y) for u in new)
    assert ("msg", 0, ev[7], "bad") in w.events
    w, m = quiet("gold_run")
    while m.events[w.mission_fired][0] != "spawn":
        fire_next(w, m)
    ev, new = fire_next(w, m)
    assert ev[6] == -1 and all(u.order == ("amove", *m.hold[:2]) for u in new)   # -1: the hold ring
    w, m = quiet("crossfire")
    while m.events[w.mission_fired][0] != "spawn":
        fire_next(w, m)
    ev, new = fire_next(w, m)
    ally = hq_of(w, 2)
    assert ev[6] == 2 and all(u.team == 1 and u.order == ("amove", ally.x, ally.y) for u in new)


def test_the_script_position_travels_in_saves():
    w, m = quiet("first_light")
    fire_next(w, m)
    fire_next(w, m)
    w2 = save.world_from_dict(save.world_to_dict(w, "mission"))
    assert w2.mission_fired == 2
    w2.elapsed = 1000
    w2.step(DT)
    assert w2.mission_fired == len(m.events)                                     # and it carries on from there
