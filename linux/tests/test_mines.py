"""Land mines: laid by Engineers, hidden from the enemy, in nobody's way, and gone when they go off."""
import math

from conftest import hq_of, make_world, run
from fieldcommand import net
from fieldcommand.ai import AI
from fieldcommand.defs import BUILDINGS, BUILD_MENU, BUILDING_KINDS, MINE_DAMAGE, MINE_SPLASH, MINE_TRIGGER
from fieldcommand.entities import Unit


def spawn(w, kind, team, x, y):
    u = Unit(w, kind, team, x, y)
    w._add(u)
    u.command(("idle",))
    u.cooldown = 1e9
    return u


def lay(w, x, y, team=0):
    m = w.start_building("mine", x, y, team)
    m.built, m.progress, m.hp = True, 1.0, m.max_hp
    return m


def test_the_mine_is_in_the_catalogue_on_the_engineer_card():
    s = BUILDINGS["mine"]
    assert BUILD_MENU[-1] == "mine" and BUILDING_KINDS[-1] == "mine" and s.requires == "barracks" and s.cost == 40
    assert s.hotkey not in {BUILDINGS[k].hotkey for k in BUILD_MENU if k != "mine"}


def test_an_engineer_lays_a_mine_and_the_enemy_never_sees_it():
    w = make_world()
    for u in list(w.units):
        u.command(("idle",))
    hq = hq_of(w, 0)
    bk = w.start_building("barracks", hq.x + 300, hq.y, 0)
    bk.built, bk.progress = True, 1.0
    e = next(u for u in w.units if u.team == 0 and u.kind == "worker")
    w.resources[0] = 500
    w.apply(0, ["build", e.id, "mine", hq.x + 200, hq.y + 200, False])
    assert e.order[0] == "build" and e.order[1] == "mine" and w.resources[0] == 500 - BUILDINGS["mine"].cost
    run(w, 20, until=lambda: any(b.kind == "mine" and b.built for b in w.buildings))
    m = next(b for b in w.buildings if b.kind == "mine")
    assert m.built
    foe = spawn(w, "marine", 1, m.x + 150, m.y)
    w.update_visibility()
    assert w.sees(0, m) and not w.sees(1, m) and not m.targetable_by(1)
    assert not any(b[0] == m.id for b in net.snapshot_for(w, 1, [])["b"])       # not on the enemy's wire
    assert w.find_target(foe, 400) is not m and w.primary_target(1, foe.x, foe.y) is not m


def test_the_first_hostile_on_the_ground_sets_it_off():
    w = make_world()
    for u in list(w.units):
        u.command(("idle",))
    hq = hq_of(w, 0)
    m = lay(w, hq.x + 400, hq.y + 400)
    own = spawn(w, "marine", 0, m.x + 5, m.y)                                    # friends walk over it
    ship = spawn(w, "gunship", 1, m.x, m.y)                                       # aircraft fly over it
    run(w, 1)
    assert not m.dead
    foe = spawn(w, "marine", 1, m.x + MINE_TRIGGER + 100, m.y)
    far = spawn(w, "tank", 1, m.x + MINE_SPLASH + 200, m.y)
    hp0, own0, far0 = foe.hp, own.hp, far.hp
    foe.x = m.x + MINE_TRIGGER - 1
    run(w, 0.5)
    assert m.dead and not any(b is m for b in w.buildings)
    assert foe.hp < hp0 and foe.hp <= hp0 - MINE_DAMAGE * 0.5                    # the burst falls off with distance
    assert own.hp == own0 and far.hp == far0                                      # no friendly fire, no reach past the burst


def test_mines_are_in_nobodys_way_and_do_not_keep_a_side_alive():
    w = make_world()
    for u in list(w.units):
        u.command(("idle",))
    hq = hq_of(w, 0)
    m = lay(w, hq.x + 300, hq.y)
    w._rebuild_nav()
    u = spawn(w, "marine", 0, hq.x + 200, hq.y)
    u.command(("move", hq.x + 400, hq.y))
    run(w, 6)
    assert abs(u.x - (hq.x + 400)) < 20 and abs(u.y - hq.y) < 20                  # straight through
    for b in list(w.buildings):
        if b.team == 1:
            b.dead = True
    m2 = lay(w, hq.x - 300, hq.y, team=1)
    w._cleanup_dead()
    w._check_victory()
    assert not w.players[1].alive and w.game_over and w.winner_team == w.players[0].team


def test_the_computer_mines_the_gap_in_its_wall():
    w = make_world("twin_ridges", players=2)
    ai = AI(w, 1)
    w.players[1].is_ai, w.players[1].ai = True, ai
    ai.opening = "turtle"
    hq = hq_of(w, 1)
    bk = w.start_building("barracks", hq.x - 300, hq.y, 1)
    bk.built, bk.progress = True, 1.0
    w.resources[1] = 3000
    w.elapsed = 400
    bases = [b for b in w.buildings if b.team == 1]
    workers = [u for u in w.units if u.team == 1 and u.kind == "worker"]
    ai.hit_at = w.elapsed
    ai._fortify(hq, bases, workers)
    queued = [o for wk in workers for o in [wk.order] + wk.queued if o[0] == "build"]
    assert any(o[1] == "wall" for o in queued) and sum(1 for o in queued if o[1] == "mine") >= 1
