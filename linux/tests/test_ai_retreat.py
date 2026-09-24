"""The computer pulls a beaten wave back and counterattacks the moment a threat to its base is repelled."""
from conftest import hq_of, make_world, run
from fieldcommand.ai import AI
from fieldcommand.entities import Unit


def ai_world():
    w = make_world("twin_ridges", players=2)
    ai = AI(w, 1)
    p = w.players[1]
    p.is_ai, p.ai = True, ai
    return w, ai, hq_of(w, 1)


def spawn(w, kind, team, x, y):
    u = Unit(w, kind, team, x, y)
    w._add(u)
    u.command(("idle",))
    return u


def test_a_wave_that_has_lost_most_of_itself_pulls_back():
    w, ai, hq = ai_world()
    wave = [spawn(w, "marine", 1, hq.x - 900 + i * 20, hq.y) for i in range(6)]
    ai.attackers, ai.launched = list(wave), 6
    for u in wave[:4]:
        u.dead = True
    w._cleanup_dead()
    ai.attackers = [u for u in ai.attackers if not u.dead]
    ai._retreat(hq)
    assert ai.retreats == 0 and ai.attackers                             # nobody near: it presses on
    spawn(w, "tank", 0, hq.x - 900 - 200, hq.y)
    before = ai.next_wave
    ai._retreat(hq)
    assert ai.retreats == 1 and not ai.attackers and ai.launched == 0
    assert all(u.order[0] == "move" and abs(u.order[1] - hq.x) < 1 for u in wave[4:])
    assert ai.next_wave >= before and ai.next_wave >= w.elapsed + 40


def test_a_wave_still_mostly_alive_keeps_going():
    w, ai, hq = ai_world()
    wave = [spawn(w, "marine", 1, hq.x - 900 + i * 20, hq.y) for i in range(6)]
    ai.attackers, ai.launched = list(wave), 6
    for u in wave[:3]:
        u.dead = True
    w._cleanup_dead()
    ai.attackers = [u for u in ai.attackers if not u.dead]
    spawn(w, "tank", 0, hq.x - 1100, hq.y)
    ai._retreat(hq)
    assert ai.retreats == 0 and len(ai.attackers) == 3                   # half is not "most"


def test_a_repelled_threat_is_answered_with_a_counterattack():
    w, ai, hq = ai_world()
    home = [spawn(w, "marine", 1, hq.x - 150 + i * 20, hq.y + 100) for i in range(8)]
    bases = [b for b in w.buildings if b.team == 1]
    raider = spawn(w, "marine", 0, hq.x - 500, hq.y)
    ai._defend(bases, home)
    assert ai.threat_seen_at == w.elapsed and not ai.counter_pending
    raider.dead = True
    w._cleanup_dead()
    ai.wave_size, ai.next_wave = 12, 1e9                                 # no scheduled wave is anywhere near
    ai._defend(bases, home)
    assert ai.counter_pending
    ai._attack(hq, home)
    assert ai.counters == 1 and len(ai.attackers) == 8 and all(u.order[0] == "amove" for u in home)
    assert not ai.counter_pending and ai.last_counter == w.elapsed
    # Not again for a minute, and not when the army is too thin.
    ai.attackers = []
    ai._defend(bases, home)
    spawn(w, "marine", 0, hq.x - 500, hq.y)
    ai._defend(bases, home)
    for u in list(w.units):
        if u.team == 0:
            u.dead = True
    w._cleanup_dead()
    ai._defend(bases, home)
    assert not ai.counter_pending


def test_easy_never_counterattacks():
    w = make_world("twin_ridges", players=2, difficulty=0)
    ai = AI(w, 1)
    hq = hq_of(w, 1)
    home = [spawn(w, "marine", 1, hq.x - 150 + i * 20, hq.y + 100) for i in range(5)]
    bases = [b for b in w.buildings if b.team == 1]
    raider = spawn(w, "marine", 0, hq.x - 500, hq.y)
    ai._defend(bases, home)
    raider.dead = True
    w._cleanup_dead()
    ai._defend(bases, home)
    assert not ai.counter_pending
