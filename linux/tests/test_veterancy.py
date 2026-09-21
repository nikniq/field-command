"""Veterancy: kills earn ranks, ranks add damage and health, and rank travels on the wire."""
from conftest import hq_of, make_world, run
from fieldcommand import net
from fieldcommand.defs import UNITS, VET_BONUS, VET_THRESHOLDS
from fieldcommand.entities import Unit


def test_kills_earn_ranks_at_the_thresholds():
    w = make_world()
    hq = hq_of(w, 0)
    r = Unit(w, "marine", 0, hq.x + 100, hq.y)
    w._add(r)
    for n in range(1, VET_THRESHOLDS[-1] + 1):
        r.credit_kill()
        assert r.rank == sum(1 for t in VET_THRESHOLDS if n >= t), n
    assert r.rank == 3 and r.vet_mult == 1 + 3 * VET_BONUS


def test_promotion_raises_max_health_and_grants_the_difference():
    w = make_world()
    hq = hq_of(w, 0)
    r = Unit(w, "marine", 0, hq.x + 100, hq.y)
    w._add(r)
    r.hp = 30
    for _ in range(VET_THRESHOLDS[0]):
        r.credit_kill()
    base = UNITS["marine"].hp
    assert r.max_hp == base * (1 + VET_BONUS) and r.hp == 30 + base * VET_BONUS


def test_a_kill_in_combat_is_credited_to_the_shooter():
    w = make_world()
    hq = hq_of(w, 0)
    sn = Unit(w, "sniper", 0, hq.x + 100, hq.y)
    w._add(sn)
    w.update_visibility()
    victims = [Unit(w, "worker", 1, sn.x + 200 + i * 20, sn.y) for i in range(2)]
    for v in victims:
        w._add(v)
        v.order = ("idle",)
    w.update_visibility()
    for v in victims:
        w.apply(0, ["attack", [sn.id], v.id, False])
        assert run(w, 20, until=lambda: v.dead)
    assert sn.kills == 2 and sn.rank == 1


def test_veterans_hit_harder():
    w = make_world()
    hq = hq_of(w, 0)
    r = Unit(w, "marine", 0, hq.x + 100, hq.y)
    w._add(r)
    r.kills, r.rank = 10, 3
    target = hq_of(w, 1)
    r.x, r.y = target.x - 150, target.y
    w.update_visibility()
    w.apply(0, ["attack", [r.id], target.id, False])
    hp0 = target.hp
    run(w, 0.6)                       # one shot
    assert abs((hp0 - target.hp) - UNITS["marine"].damage * 1.3) < 1e-6


def test_rank_travels_in_snapshots():
    w = make_world()
    hq = hq_of(w, 0)
    r = Unit(w, "marine", 0, hq.x + 100, hq.y)
    w._add(r)
    r.kills, r.rank = 5, 2
    w.update_visibility()
    row = next(x for x in net.snapshot_for(w, 0, [])["u"] if x[0] == r.id)
    assert row[10] == 2
