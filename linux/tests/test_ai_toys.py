"""The computer uses the newer kit: Gunships in its mix, Barricades across its approach."""
import math

from conftest import hq_of, make_world
from fieldcommand.ai import AI, FORTIFY_BLOCKS
from fieldcommand.defs import BUILDINGS
from fieldcommand.entities import Unit


def ai_world():
    w = make_world("twin_ridges", players=2)
    ai = AI(w, 1, opening="turtle")
    w.players[1].is_ai, w.players[1].ai = True, ai
    return w, ai, hq_of(w, 1)


def test_gunships_answer_massed_tanks_and_rangers_answer_gunships():
    w, ai, hq = ai_world()
    ai.seen = {"marine": 0.0, "sniper": 0.0, "tank": 12.0, "gunship": 0.0}
    comp = ai._composition()
    assert comp["gunship"] > 0.25 and comp["sniper"] > comp["tank"]
    ai.seen = {"marine": 0.0, "sniper": 0.0, "tank": 0.0, "gunship": 12.0}
    comp = ai._composition()
    assert comp["marine"] > 0.5 and comp["gunship"] < 0.1
    ai.seen = {"marine": 0.0, "sniper": 0.0, "tank": 0.0, "gunship": 0.0}
    assert ai._wanted([]) == "marine"                                   # the base mix still opens with Rangers


def test_the_factory_trains_a_gunship_when_one_is_wanted_and_a_radar_stands():
    w, ai, hq = ai_world()
    for u in list(w.units):
        u.command(("idle",))
    fac = w.start_building("factory", hq.x - 300, hq.y, 1)
    fac.built = True
    for i in range(3):                                                  # supply for the test army
        w.start_building("depot", hq.x - 500, hq.y - 200 + i * 100, 1).built = True
    ai.seen = {"marine": 0.0, "sniper": 0.0, "tank": 12.0, "gunship": 0.0}
    w.resources[1] = 5000
    army = [Unit(w, "marine", 1, hq.x, hq.y + 200) for _ in range(6)] + [Unit(w, "sniper", 1, hq.x, hq.y + 240) for _ in range(3)]
    for u in army:
        w._add(u)
    assert ai._wanted(army) == "gunship"                                # Snipers already answer the tanks; air is next
    ai._produce(hq, [b for b in w.buildings if b.team == 1], [], 0)
    assert fac.queue == ["tank"]                                        # no Radar yet: a tank
    fac.queue = []
    rad = w.start_building("radar", hq.x - 300, hq.y + 200, 1)
    rad.built = True
    ai._produce(hq, [b for b in w.buildings if b.team == 1], [], 0)
    assert fac.queue == ["gunship"]


def test_a_turtle_walls_its_approach_with_a_gap_and_anyone_does_once_hit():
    w, ai, hq = ai_world()
    workers = [u for u in w.units if u.team == 1 and u.kind == "worker"]
    for u in workers:
        u.command(("idle",))
    w.resources[1] = 2000
    bases = [b for b in w.buildings if b.team == 1]
    w.elapsed = 100 * w.difficulty.pace
    assert not ai._fortify(hq, bases, workers)                          # too early
    w.elapsed = 200 * w.difficulty.pace
    placed = ai._fortify(hq, bases, workers)
    assert placed >= 4
    orders = [o for u in workers for o in [u.order] + u.queued if o[0] == "build" and o[1] == "wall"]
    assert len(orders) == placed
    xs = sorted(math.hypot(o[2] - hq.x, o[3] - hq.y) for o in orders)
    assert all(300 < d < 600 for d in xs)                               # a line across the approach, not on the base
    assert w.resources[1] == 2000 - placed * BUILDINGS["wall"].cost
    # An economy player walls up only after a building has been hit.
    w2, ai2, hq2 = ai_world()
    ai2.opening = "economy"
    workers2 = [u for u in w2.units if u.team == 1 and u.kind == "worker"]
    for u in workers2:
        u.command(("idle",))
    w2.resources[1] = 2000
    w2.elapsed = 600
    bases2 = [b for b in w2.buildings if b.team == 1]
    assert not ai2._fortify(hq2, bases2, workers2)
    hq2.hp -= 50
    assert ai2._fortify(hq2, bases2, workers2) >= 4
    assert sum(1 for u in workers2 for o in [u.order] + u.queued if o[0] == "build") <= FORTIFY_BLOCKS
