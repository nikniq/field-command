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


# ---------------------------------------------------------------- the strategist (1.20)

def test_openings_follow_difficulty_seed_and_map_size():
    import random
    from fieldcommand.ai import OPENING_ORDER, choose_opening
    easy = {choose_opening(random.Random(s), 0, False) for s in range(40)}
    hard = {choose_opening(random.Random(s), 2, False) for s in range(40)}
    giant = {choose_opening(random.Random(s), 2, True) for s in range(40)}
    assert "rush" not in easy and "rush" in hard and len(hard) == 3   # Easy never rushes; Hard tries everything
    assert "rush" not in giant                                        # and nobody rushes across a giant map
    assert all(o in OPENING_ORDER for o in easy | hard | giant)
    from conftest import DIFFICULTIES, PlayerInfo, World, mapgen
    def seeded(seed):
        ps = [PlayerInfo(i, f"P{i}", i + 1, is_ai=True, start=i) for i in range(2)]
        return World(mapgen.generate("twin_ridges"), ps, DIFFICULTIES[2], seed=seed)
    picks = [seeded(s).players[1].ai.opening for s in range(12)]
    assert picks == [seeded(s).players[1].ai.opening for s in range(12)]   # from the seed: a replay picks the same one
    assert len(set(picks)) > 1                                        # and different seeds pick differently


def test_the_opening_bends_the_build_plan_and_the_first_wave():
    w, ai, hq = ai_world()
    def by(t, kind):
        return max(n for k, n in ai._plan(t) if k == kind)
    ai.opening = "rush"
    assert by(25.0, "barracks") == 1                                  # a rush has its Barracks up at once
    ai.opening = "economy"
    assert by(25.0, "barracks") == 0
    ai.opening = "turtle"
    assert by(80.0, "turret") == 1                                    # a turtle digs in early
    rush, turtle = AI(w, 1, opening="rush"), AI(w, 1, opening="turtle")
    assert rush.next_wave < turtle.next_wave and rush.wave_size < turtle.wave_size


def test_a_scout_walks_to_the_enemy_door_and_comes_home():
    w, ai, hq = ai_world()
    home = [Unit(w, "marine", 1, hq.x + 100 + i * 20, hq.y) for i in range(3)]
    for u in home:
        w._add(u)
    w.elapsed = ai.next_scout
    ai._scout(hq, home)
    ex, ey = w.map["starts"][0][:2]
    assert ai.scout in home and ai.scout.order[0] == "move"
    assert abs(ai.scout.order[1] - ex) < 1 and abs(ai.scout.order[2] - ey) < 1
    assert ai.scout_route[-1] == (hq.x, hq.y)                         # the route ends back home
    ai.scout.command(("idle",))
    ai.scout_route = []
    ai._scout(hq, home)
    assert ai.scout is None and ai.next_scout > w.elapsed             # home again; the next one waits


def test_the_expansion_comes_early_when_the_home_field_runs_low():
    w, ai, hq = ai_world()
    workers = [u for u in w.units if u.team == 1 and u.kind == "worker"]
    assert not ai._should_expand(50.0, [hq], workers)
    for c in w.crystals:
        if abs(c.x - hq.x) < 700 and abs(c.y - hq.y) < 700:
            c.amount = int(c.amount * 0.3)
    assert ai._should_expand(50.0, [hq], workers)                     # under 45% of what it started with
    w, ai, hq = ai_world()
    ai._should_expand(50.0, [hq], [])
    crowd = [Unit(w, "worker", 1, hq.x, hq.y) for _ in range(40)]
    assert ai._should_expand(50.0, [hq], crowd)                       # or with more Engineers than the field can feed


def test_an_expansion_gets_a_turret_and_a_garrison():
    w, ai, hq = ai_world()
    ai.opening = "turtle"                                             # whose timed expansion is not due yet
    e = w.start_building("hq", hq.x - 900, hq.y, 1)                   # toward the middle, inside the map
    e.built = True
    bases = [b for b in w.buildings if b.team == 1]
    assert ai._unguarded_expansion(hq, bases) is e
    w.resources[1] = 2000
    w.elapsed = 200 * w.difficulty.pace
    workers = [u for u in w.units if u.team == 1 and u.kind == "worker"]
    ai._construct(hq, bases, workers)
    builds = [u.order for u in workers if u.order[0] == "build" and u.order[1] == "turret"]
    assert builds and abs(builds[0][2] - e.x) < 500 and abs(builds[0][3] - e.y) < 500
    home = [Unit(w, "marine", 1, hq.x + 100 + i * 20, hq.y) for i in range(8)]
    for u in home:
        w._add(u)
    ai._garrison(hq, bases, home)
    assert len(ai.guards) == 3                                        # GARRISON on Normal
    assert all(u.order[0] == "amove" and abs(u.order[1] - e.x) < 200 for u in ai.guards)
    ai.update(2.0)
    assert not any(u in ai.attackers for u in ai.guards)              # guards are not the home army
