"""Balance against a human: the computer's production is capped by difficulty and spare crystal only
becomes extra production after the opening."""
from conftest import hq_of, make_world
from fieldcommand.ai import AI
from fieldcommand.defs import DIFFICULTIES, PRODUCTION_CAP, PRODUCTION_FLOAT_AT


def ai_world(difficulty):
    w = make_world("twin_ridges", players=2, difficulty=difficulty)
    ai = AI(w, 1)
    w.players[1].is_ai, w.players[1].ai = True, ai
    hq = hq_of(w, 1)
    return w, ai, hq


def stand(w, kind, x, y):
    b = w.start_building(kind, x, y, 1)
    b.built, b.progress, b.hp = True, 1.0, b.max_hp
    return b


def wanted(ai, hq, w, t):
    """What _construct orders built right now: the kind the chosen Engineer was told to build, or None."""
    w.elapsed = t
    bases = [b for b in w.buildings if b.team == 1]
    workers = [u for u in w.units if u.team == 1 and u.kind == "worker"]
    for u in workers:
        u.command(("idle",))
    ai._construct(hq, bases, workers)
    for u in workers:
        if u.order[0] == "build":
            k = u.order[1]
            u.command(("idle",))
            return k
    return None


def test_the_caps_rise_with_difficulty():
    assert PRODUCTION_CAP == [(2, 1), (4, 2), (6, 3)] and len(PRODUCTION_CAP) == len(DIFFICULTIES)
    assert PRODUCTION_FLOAT_AT == 300


def test_spare_crystal_does_not_become_barracks_in_the_opening():
    w, ai, hq = ai_world(2)
    w.resources[1] = 5000
    # Everything the plan asks for by the fourth minute already stands, so only the spare-crystal rule is left.
    stand(w, "barracks", hq.x - 300, hq.y)
    stand(w, "barracks", hq.x - 300, hq.y + 150)
    stand(w, "turret", hq.x - 250, hq.y + 300)
    stand(w, "factory", hq.x - 300, hq.y - 250)
    stand(w, "refinery", hq.x + 200, hq.y + 250)
    stand(w, "radar", hq.x + 250, hq.y - 100)
    for i in range(4):
        stand(w, "depot", hq.x + 150 + i * 90, hq.y - 250)
    for i in range(2):
        stand(w, "hq", hq.x + 600 + i * 300, hq.y + 500)                 # no expansion wanted either
        stand(w, "turret", hq.x + 600 + i * 300, hq.y + 650)             # and each one already guarded
    k = wanted(ai, hq, w, 200)                                           # Hard, three minutes in, rich
    assert k not in ("barracks", "factory"), k                           # not before the opening is over
    k = wanted(ai, hq, w, 320)
    assert k in ("barracks", "factory"), k                               # after it the bank gets spent


def test_normal_stops_at_its_cap_and_hard_goes_on():
    for diff, expect_more in ((1, False), (2, True)):
        w, ai, hq = ai_world(diff)
        w.resources[1] = 5000
        w.gas[1] = 500
        for i in range(4):
            stand(w, "barracks", hq.x - 350, hq.y - 300 + i * 150)
        for i in range(2):
            stand(w, "factory", hq.x - 150, hq.y - 300 + i * 200)
        for kind, (dx, dy) in (("radar", (150, 250)), ("shield", (300, -200)), ("refinery", (300, 100)), ("refinery", (400, 200)),
                               ("artillery", (-450, 300)), ("artillery", (-450, -300))):
            stand(w, kind, hq.x + dx, hq.y + dy)
        for i in range(4):
            stand(w, "turret", hq.x - 250 + i * 70, hq.y + 350)
        for i in range(6):
            stand(w, "depot", hq.x + 100 + i * 90, hq.y - 350)
        for i in range(2):
            stand(w, "hq", hq.x + 600 + i * 300, hq.y + 500)             # no expansion wanted
            stand(w, "turret", hq.x + 600 + i * 300, hq.y + 650)         # and each one already guarded
        kinds = {wanted(ai, hq, w, t) for t in (400, 600, 900)}
        more = bool(kinds & {"barracks", "factory"})
        assert more == expect_more, (diff, kinds)
