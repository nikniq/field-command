"""Polish (1.24): the army timeline for the end screen, undoing a placement, the unit counter, rebindable
keys and the first-run arrows."""
from conftest import DT, hq_of, make_world, run
from fieldcommand import save
from fieldcommand.defs import BUILDINGS, DEFAULT_KEYS, HISTORY_STEP, KEY_ACTIONS, UNDO_PROGRESS
from fieldcommand.entities import Unit
from fieldcommand.hud import army_counts
from fieldcommand.settings import settings


def test_every_side_army_is_sampled_on_the_clock_and_saved():
    w = make_world()
    for u in list(w.units):
        u.command(("idle",))
    run(w, HISTORY_STEP * 4 + 1)
    assert all(len(h) == 5 for h in w.history.values())               # t = 0, 15, 30, 45, 60
    for i in range(3):
        w._add(Unit(w, "marine", 0, hq_of(w, 0).x + 200 + i * 30, hq_of(w, 0).y))
    run(w, HISTORY_STEP)
    assert w.history[0][-1] == 3 and w.history[1][-1] == 0
    w2 = save.world_from_dict(save.world_to_dict(w, "t"))
    assert w2.history == w.history
    run(w2, HISTORY_STEP)
    assert len(w2.history[0]) == len(w.history[0]) + 1                 # and sampling carries on


def test_a_placement_can_be_taken_back_for_a_full_refund_while_it_has_barely_started():
    w = make_world()
    hq = hq_of(w, 0)
    w.resources[0] = 1000
    b = w.start_building("depot", hq.x + 300, hq.y, 0)
    w.resources[0] -= BUILDINGS["depot"].cost
    b.progress = UNDO_PROGRESS - 0.1
    w.apply(0, ["unbuild", b.id])
    assert b not in w.buildings and b.id not in w.by_id and w.resources[0] == 1000
    assert any(e[0] == "msg" and "undone" in e[2] for e in w.events)
    b2 = w.start_building("depot", hq.x + 300, hq.y, 0)
    w.resources[0] -= BUILDINGS["depot"].cost
    b2.progress = UNDO_PROGRESS + 0.1
    w.apply(0, ["unbuild", b2.id])
    assert b2 in w.buildings                                            # too far along: it stays
    w.apply(1, ["unbuild", b2.id])                                      # and never someone else's
    assert b2 in w.buildings


def test_the_unit_counter_counts_combat_kinds_in_catalogue_order():
    w = make_world()
    hq = hq_of(w, 0)
    for k in ("tank", "marine", "marine", "medic", "worker"):
        w._add(Unit(w, k, 0, hq.x + 200, hq.y))
    assert army_counts([u for u in w.units if u.team == 0]) == [("marine", 2), ("tank", 1), ("medic", 1)]


def test_keys_have_defaults_and_can_be_rebound_one_key_per_action():
    settings.reset_keys()
    assert settings.key("ping") == DEFAULT_KEYS["ping"] == "z" and len(KEY_ACTIONS) == len(DEFAULT_KEYS)
    settings.bind("ping", "x")
    assert settings.key("ping") == "x"
    settings.bind("undo", "x")                                          # X moves to undo; ping is left unbound
    assert settings.key("undo") == "x" and settings.key("ping") == ""
    settings.reset_keys()
    assert settings.key("ping") == "z" and settings.key("undo") == "backspace"
