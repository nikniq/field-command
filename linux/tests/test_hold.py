"""Hold position and the tactical pause."""
import math

from conftest import hq_of, make_world, run
from fieldcommand import net
from fieldcommand.defs import KEY_ACTIONS, UNITS
from fieldcommand.entities import Unit


def spawn(w, kind, team, x, y):
    u = Unit(w, kind, team, x, y)
    w._add(u)
    u.command(("idle",))
    return u


def test_a_holding_unit_fires_at_what_comes_in_reach_and_never_chases():
    w = make_world()
    for u in list(w.units):
        u.command(("idle",))
        u.cooldown = 1e9
    hq = hq_of(w, 0)
    r = spawn(w, "marine", 0, hq.x + 500, hq.y)
    w.apply(0, ["hold", [r.id]])
    assert r.order == ("hold",) and r.status_text().startswith("Holding")
    far = spawn(w, "marine", 1, r.x + UNITS["marine"].range + 120, r.y)        # in sight, out of reach
    far.cooldown = 1e9
    far.command(("hold",))                                                      # and not walking in either
    x0 = r.x
    run(w, 4)
    assert abs(r.x - x0) < 1 and r.order == ("hold",) and far.hp == far.max_hp  # it stands; an idle unit would have gone
    far.x = r.x + UNITS["marine"].range - 10                                   # now in reach
    run(w, 3)
    assert far.hp < far.max_hp and abs(r.x - x0) < 1 and r.order == ("hold",)
    assert net.STATUS["hold"] == 10 and net.snapshot_for(w, 0, [])["o"][str(r.id)][0] == 10


def test_engineers_do_not_hold_and_a_move_order_ends_it():
    w = make_world()
    hq = hq_of(w, 0)
    e = next(u for u in w.units if u.team == 0 and u.kind == "worker")
    e.command(("idle",))
    w.apply(0, ["hold", [e.id]])
    assert e.order[0] != "hold"
    r = spawn(w, "marine", 0, hq.x + 300, hq.y)
    w.apply(0, ["hold", [r.id]])
    w.apply(0, ["move", [r.id], hq.x + 400, hq.y, False, False])
    assert r.order[0] == "move"


def test_hold_survives_a_save():
    from fieldcommand.save import world_to_dict, world_from_dict
    w = make_world()
    hq = hq_of(w, 0)
    r = spawn(w, "marine", 0, hq.x + 300, hq.y)
    w.apply(0, ["hold", [r.id]])
    w2 = world_from_dict(world_to_dict(w))
    assert w2.by_id[r.id].order == ("hold",)


def test_the_tactical_pause_is_a_bound_key():
    assert ("tactical", "Tactical pause (give orders while stopped)", "f1") in KEY_ACTIONS
