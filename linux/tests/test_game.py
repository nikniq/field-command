"""Whole games: the AI plays itself on every map and something sensible comes of it."""
import collections

import pytest

from conftest import make_world, run
from fieldcommand import mapgen
from fieldcommand.ai import AI


def play(map_id, seconds):
    spec = mapgen.BY_ID[map_id]
    w = make_world(map_id, players=spec["players"], ai=True, difficulty=2)
    for p in w.players.values():
        p.ai = AI(w, p.slot)
    run(w, seconds, until=lambda: w.game_over)
    return w


def test_a_two_player_game_reaches_a_result():
    w = play("twin_ridges", 1200)
    assert w.game_over and w.winner_team in (1, 2)


def test_the_ai_uses_the_whole_catalogue():
    w = play("river_crossing", 600)
    built = collections.Counter(b.kind for b in w.buildings if not b.dead and b.built)
    trained = collections.Counter(u.kind for u in w.units if not u.dead)
    everything = {k for k in list(built) + list(trained)}
    for k in ("barracks", "factory", "turret", "radar"):
        assert k in everything, (k, built)
    assert "sniper" in everything or w.game_over, trained


@pytest.mark.parametrize("map_id", [m["id"] for m in mapgen.CATALOG])
def test_every_map_runs_without_error(map_id):
    play(map_id, 90)
