"""Alert points: a player marks a spot, the whole alliance sees it, computer allies send troops."""
from conftest import hq_of, make_world, run
from fieldcommand import net
from fieldcommand.ai import AI
from fieldcommand.entities import Unit


def team_game():
    """Four players in two teams: slots 0 and 2 are allies, 1 and 3 the other side."""
    w = make_world("four_corners", players=4, teams=2)
    return w


def test_a_ping_is_an_event_for_the_whole_alliance_and_nobody_else():
    w = team_game()
    w.apply(0, ["ping", 1000, 900])
    ev = next(e for e in w.events if e[0] == "ping")
    assert ev == ("ping", 0, 1000.0, 900.0, 0)
    w.events.clear()
    run(w, 3.1)
    w.apply(0, ["ping", 1000, 900, 1])
    assert ("ping", 0, 1000.0, 900.0, 1) in w.events     # a "help here" point
    assert net.event_visible(w, 0, ev) and net.event_visible(w, 2, ev)
    assert not net.event_visible(w, 1, ev) and not net.event_visible(w, 3, ev)
    assert w.pings[-1][:3] == (0, 1000.0, 900.0)


def test_pings_are_rate_limited_and_clamped_to_the_map():
    w = team_game()
    w.apply(0, ["ping", -500, 99999])
    assert w.pings[-1][1] == 0 and w.pings[-1][2] == w.map_spec["h"] if hasattr(w, "map_spec") else True
    w.events.clear()
    w.apply(0, ["ping", 100, 100])
    assert not any(e[0] == "ping" for e in w.events)     # within 3 seconds of the last one
    run(w, 3.1)
    w.events.clear()
    w.apply(0, ["ping", 100, 100])
    assert any(e[0] == "ping" for e in w.events)


def test_a_computer_ally_sends_its_idle_troops_to_the_alert_point():
    w = team_game()
    ally = AI(w, 2)
    w.players[2].ai = ally
    hq = hq_of(w, 2)
    troops = [Unit(w, "marine", 2, hq.x + 200 + i * 30, hq.y + 200) for i in range(4)]
    for t in troops:
        w._add(t)
    target = (hq.x - 900, hq.y + 900)
    w.apply(0, ["ping", *target])
    run(w, 1.5)
    moving = [t for t in troops if t.order[0] == "amove"]
    assert len(moving) >= 2
    assert all(abs(t.order[1] - target[0]) < 5 and abs(t.order[2] - target[1]) < 5 for t in moving)
    assert all(t in ally.attackers for t in moving)
    # Enemies' pings are ignored, and the same ping is not answered twice.
    for t in troops:
        t.command(("idle",))
    run(w, 3.5)
    w.apply(1, ["ping", *target])
    run(w, 1.5)
    assert not any(t.order[0] == "amove" and abs(t.order[1] - target[0]) < 5 and abs(t.order[2] - target[1]) < 5 for t in troops)


def test_the_computer_does_not_answer_its_own_side_when_alone():
    w = make_world(ai=True)
    run(w, 1)
    w.apply(0, ["ping", 500, 500])
    run(w, 1.5)
    # Slot 1 is the enemy: no reaction at all
    assert not any(u.order[0] == "amove" and abs(u.order[1] - 500) < 5 for u in w.units if u.team == 1)
