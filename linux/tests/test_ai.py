"""The computer opponent watches what it faces and answers it."""
from conftest import hq_of, make_world, run
from fieldcommand.ai import AI
from fieldcommand.entities import Unit


def ai_world():
    w = make_world("twin_ridges", players=2)
    ai = AI(w, 1)
    p = w.players[1]
    p.is_ai, p.ai = True, ai
    return w, ai, hq_of(w, 1)


def test_the_ai_notices_enemy_units_it_can_see_and_forgets_them():
    w, ai, hq = ai_world()
    for i in range(5):
        w._add(Unit(w, "tank", 0, hq.x + 250 + i * 30, hq.y))       # in the AI's sight, not in its face
    w.update_visibility()
    ai._observe()
    assert ai.seen["tank"] >= 4
    for _ in range(40):
        ai._observe()                                                  # they wander off; the tally decays
    for u in list(w.units):
        if u.team == 0:
            u.dead = True
    w._cleanup_dead()
    w.update_visibility()
    for _ in range(40):                                                # 0.85^40 of ~27: gone
        ai._observe()
    assert ai.seen["tank"] < 0.5


def test_massed_tanks_are_answered_with_snipers_and_massed_rangers_with_tanks():
    w, ai, hq = ai_world()
    ai.seen = {"marine": 0.0, "sniper": 0.0, "tank": 12.0}
    assert ai._wanted([]) == "sniper"
    ai.seen = {"marine": 12.0, "sniper": 0.0, "tank": 0.0}
    assert ai._wanted([]) == "tank"
    ai.seen = {"marine": 0.0, "sniper": 0.0, "tank": 0.0}
    assert ai._wanted([]) == "marine"                                  # the base mix opens with Rangers


def test_snipers_stop_short_of_the_target():
    w, ai, hq = ai_world()
    sn = Unit(w, "sniper", 1, hq.x, hq.y)
    r = Unit(w, "marine", 1, hq.x, hq.y)
    tx, ty = hq.x - 1000, hq.y
    sx, sy = ai._standoff(sn, tx, ty)
    assert abs((sx - tx)) == 200 and sy == ty                          # 200 short, on the line
    assert ai._standoff(r, tx, ty) == (tx, ty)                          # Rangers go all the way


def test_raids_go_out_between_waves_on_normal_and_up():
    w, ai, hq = ai_world()
    w.elapsed = 300
    ai.next_raid = 0
    ai.wave_size = 8
    home = [Unit(w, "marine", 1, hq.x + 100 + i * 20, hq.y) for i in range(8)]
    for u in home:
        w._add(u)
    enemy_depot = w.start_building("depot", hq_of(w, 0).x + 600, hq_of(w, 0).y, 0)
    enemy_depot.built = True
    w.update_visibility()
    enemy_depot.revealed_mask = 0xFF                                    # the AI has scouted it
    ai._raid(hq, home)
    raiders = [u for u in home if u.order[0] == "amove"]
    assert 2 <= len(raiders) <= 3 and len(ai.attackers) == len(raiders)
    assert ai.next_raid == 390


def test_a_game_between_two_reacting_ais_still_finishes():
    w = make_world("twin_ridges", players=2, ai=True)
    for p in w.players.values():
        p.ai = AI(w, p.slot)
    assert run(w, 1500, until=lambda: w.game_over)
