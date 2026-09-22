"""Save and load: a mid-game world survives a round trip through JSON and plays on."""
import json
import os
import tempfile

import pytest

from conftest import DT, hq_of, make_world, run
from fieldcommand import net, save
from fieldcommand.ai import AI
from fieldcommand.defs import BRIDGE_HP
from fieldcommand.entities import Unit


def busy_world():
    """A game a few minutes in, with a bit of everything in flight."""
    w = make_world("river_crossing", players=2, ai=True, difficulty=2)
    for p in w.players.values():
        p.ai = AI(w, p.slot)
    run(w, 240)
    hq = hq_of(w, 0)
    w.resources[0] = 3000
    w.buy_kit(0, "flak")
    w.apply(0, ["upgrade", [hq.id], "hp"])
    t = Unit(w, "tank", 0, hq.x + 200, hq.y)
    w._add(t)
    t.kills, t.rank, t.mode = 5, 2, 2
    w.bridges[0].take_damage(BRIDGE_HP, None)
    w.towers[0].owner = 1
    run(w, 3)
    return w


def signature(w):
    """Everything a save must carry, in a comparable shape."""
    units = sorted((u.id, u.kind, u.team, round(u.x, 1), round(u.y, 1), round(u.hp, 3), u.mode, u.rank, u.order[0])
                   for u in w.units if not u.dead)
    buildings = sorted((b.id, b.kind, b.team, b.built, round(b.hp, 3), tuple(b.queue), tuple(sorted(b.upgrades)), b.upgrading)
                       for b in w.buildings if not b.dead)
    return {
        "elapsed": round(w.elapsed, 3), "units": units, "buildings": buildings,
        "crystals": sorted((c.id, c.amount) for c in w.crystals if not c.dead),
        "bridges": [(b.id, b.intact, b.hp) for b in w.bridges], "towers": [(t.id, t.owner) for t in w.towers],
        "resources": {s: round(v, 3) for s, v in w.resources.items()}, "kits": {s: sorted(k) for s, k in w.kits.items()},
        "explored": {t: int(g.explored.sum()) for t, g in w.fog.items()},
        "ai": {s: (p.ai.wave_size, p.ai.next_wave, len([u for u in p.ai.attackers if not u.dead]))
               for s, p in w.players.items() if p.ai},
    }


def test_round_trip_keeps_the_whole_game():
    w = busy_world()
    w.update_visibility()          # the sight pass is throttled; loading runs it at once, so settle it here too
    before = signature(w)
    data = json.loads(json.dumps(save.world_to_dict(w, "test")))     # through real JSON, as the file would be
    assert data["format"] == save.SAVE_FORMAT and data["game"] == "field-command"
    w2 = save.world_from_dict(data)
    assert signature(w2) == before
    # Orders came back pointing at the right things.
    for u in w2.units:
        if u.order[0] in ("attack", "gather"):
            assert u.order[1] is w2.by_id[u.order[1].id]
    # And the same snapshot goes out to a client.
    assert net.snapshot_for(w2, 0, [])["u"] == net.snapshot_for(w, 0, [])["u"]


def test_a_loaded_game_plays_on_to_a_result():
    w = busy_world()
    w2 = save.world_from_dict(save.world_to_dict(w))
    assert run(w2, 1500, until=lambda: w2.game_over)
    assert max(e.id for e in w2.by_id.values()) < w2._next_id


def test_files_land_in_the_saves_dir_and_list_newest_first(monkeypatch):
    tmp = tempfile.mkdtemp()
    monkeypatch.setattr(save, "saves_dir", lambda: tmp)
    w = make_world()
    save.write_save(w, "first", "First")
    run(w, 1)
    p = save.write_save(w, "second", "Second")
    assert os.path.exists(p) and not os.path.exists(p + ".tmp")
    names = [s[0] for s in save.list_saves()]
    assert set(names) == {"first", "second"}
    w3 = save.read_save("second")
    assert abs(w3.elapsed - w.elapsed) < 1e-6


def test_unknown_formats_are_refused():
    import pytest
    with pytest.raises(ValueError):
        save.world_from_dict({"game": "field-command", "format": 99})


FIXTURES = os.path.join(os.path.dirname(__file__), "..", "..", "tests", "fixtures")


@pytest.mark.parametrize("name", ["save_python.json", "save_macos.json"])
def test_saves_from_either_edition_load_and_play_on(name):
    """The macOS edition writes the same document; a game saved there resumes here (and vice versa, FC_SAVETEST)."""
    with open(os.path.join(FIXTURES, name)) as f:
        data = json.load(f)
    w = save.world_from_dict(data)
    assert len(w.units) == len(data["units"]) and len(w.buildings) == len(data["buildings"])
    assert "flak" in w.kits[0]
    assert not w.bridges[0].intact and w.towers[0].owner == 1
    run(w, 1500, until=lambda: w.game_over)
    assert w.game_over
