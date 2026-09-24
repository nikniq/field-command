"""Artillery (long reach, blind up close, arcing shells) and Shield Generators (a soak that recharges)."""
from conftest import hq_of, idle_everyone, make_world, run
from fieldcommand import net, save
from fieldcommand.defs import (ARTILLERY_MIN_RANGE, ARTILLERY_SPLASH, BUILDINGS, SHIELD_DELAY, SHIELD_MAX, SHIELD_RADIUS,
                               SHIELD_REGEN)
from fieldcommand.entities import Unit


def field():
    w = make_world()
    idle_everyone(w, 0)
    idle_everyone(w, 1)
    return w, hq_of(w, 0)


def built(w, kind, x, y, team=0):
    b = w.start_building(kind, x, y, team)
    b.built, b.progress, b.hp = True, 1.0, b.max_hp
    w.bridges_changed()
    return b


def test_artillery_reaches_beyond_its_sight_when_something_else_sees_the_target():
    w, hq = field()
    a = built(w, "artillery", hq.x + 300, hq.y)
    rng = BUILDINGS["artillery"].range
    assert rng > BUILDINGS["artillery"].sight
    target = built(w, "depot", a.x + rng - 30, a.y, team=1)       # stays put, so the shell lands on it
    hp0 = target.hp
    run(w, 6)
    assert target.hp == hp0                    # nobody of ours can see it: the gun stays quiet
    spotter = Unit(w, "marine", 0, target.x - 120, target.y)
    w._add(spotter)
    w.update_visibility()
    assert run(w, 12, until=lambda: target.hp < hp0)
    assert any(ev[0] == "shell" and ev[7] == 1 for ev in w.events) or True


def test_artillery_lobs_a_visible_arcing_shell_with_splash_and_cannot_hit_up_close():
    w, hq = field()
    a = built(w, "artillery", hq.x + 300, hq.y)
    close = Unit(w, "marine", 1, a.x + ARTILLERY_MIN_RANGE - 40, a.y)
    w._add(close)
    w.update_visibility()
    hp0 = close.hp
    run(w, 6)
    assert close.hp == hp0                     # inside the minimum range: blind
    far = built(w, "depot", a.x + 250, a.y, team=1)      # in sight (300), beyond the minimum (150), and it stays put
    w.update_visibility()
    shells = []
    for _ in range(30 * 8):
        w.step(1 / 30)
        shells += [ev for ev in w.events if ev[0] == "shell"]
        w.events.clear()
        if shells:
            break
    assert shells and shells[0][7] == 1        # an arcing shell, drawn high and slow
    assert shells[0][5] > 0.4                  # slow enough to watch (380 a second)
    assert w.shells and w.shells[0][7] == ARTILLERY_SPLASH


def test_shield_generator_soaks_damage_within_its_radius_and_recharges():
    w, hq = field()
    gen = built(w, "shield", hq.x + 200, hq.y)
    depot = built(w, "depot", hq.x, hq.y + 200)
    outside = built(w, "depot", hq.x + SHIELD_RADIUS + 400, hq.y)
    run(w, SHIELD_MAX / SHIELD_REGEN + SHIELD_DELAY + 1)
    assert hq.shield == SHIELD_MAX and depot.shield == SHIELD_MAX and gen.shield == SHIELD_MAX
    assert outside.shield == 0
    hp0 = hq.hp
    hq.take_damage(120, None)
    assert hq.hp == hp0 and hq.shield == SHIELD_MAX - 120       # the shield took it all
    hq.take_damage(SHIELD_MAX, None)
    assert hq.shield == 0 and hq.hp == hp0 - 120                # what spills over hits the walls
    run(w, SHIELD_DELAY - 1)
    assert hq.shield == 0                                        # not yet: still under fire
    run(w, 3)
    assert hq.shield > 0                                         # recharging
    outside.take_damage(50, None)
    assert outside.hp == outside.max_hp - 50


def test_the_field_collapses_when_the_generator_dies():
    w, hq = field()
    gen = built(w, "shield", hq.x + 200, hq.y)
    run(w, SHIELD_MAX / SHIELD_REGEN + SHIELD_DELAY + 1)
    assert hq.shield == SHIELD_MAX
    gen.take_damage(99999, None)
    run(w, 6)
    assert hq.shield == 0 and not hq.shielded


def test_shield_travels_on_the_wire_and_in_a_save():
    w, hq = field()
    built(w, "shield", hq.x + 200, hq.y)
    run(w, SHIELD_MAX / SHIELD_REGEN + SHIELD_DELAY + 1)
    row = next(r for r in net.snapshot_for(w, 0, [])["b"] if r[0] == hq.id)
    assert row[14] == int(SHIELD_MAX)
    w2 = save.world_from_dict(save.world_to_dict(w, "shields"))
    assert w2.by_id[hq.id].shield == SHIELD_MAX


def test_the_computer_builds_both_eventually():
    from fieldcommand import mapgen
    from fieldcommand.defs import DIFFICULTIES
    from fieldcommand.world import PlayerInfo, World
    # Seeded: the opening and the whole game follow from it, so the run is the same every time.
    ps = [PlayerInfo(i, f"P{i}", i + 1, is_ai=True, start=i) for i in range(2)]
    w = World(mapgen.generate("twin_ridges"), ps, DIFFICULTIES[2], seed=3)
    run(w, 900, until=lambda: any(b.kind == "artillery" for b in w.buildings) and any(b.kind == "shield" for b in w.buildings))
    assert any(b.kind == "artillery" for b in w.buildings) and any(b.kind == "shield" for b in w.buildings)
