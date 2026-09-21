"""Single-player teams: the deal, alliances in play, and the settings around them."""
from conftest import hq_of, make_world, run
from fieldcommand.ai import AI
from fieldcommand.defs import DIFFICULTIES
from fieldcommand.session import LocalSession, lineup_text, team_of
from fieldcommand.settings import settings


def test_players_are_dealt_round_robin_like_the_lobby():
    assert [team_of(i, 2) for i in range(4)] == [1, 2, 1, 2]
    assert [team_of(i, 3) for i in range(6)] == [1, 2, 3, 1, 2, 3]
    assert [team_of(i, 0) for i in range(4)] == [1, 2, 3, 4]      # free-for-all


def test_allies_share_vision():
    s = LocalSession(DIFFICULTIES[1], map_id="four_corners", opponents=3, teams=2)
    w = s.world
    assert w.allied(0, 2) and not w.allied(0, 1)
    ally_hq = hq_of(w, 2)
    w.update_visibility()
    assert s.fog.is_visible(ally_hq.x, ally_hq.y)


def test_a_2v2_plays_to_a_finish_with_no_friendly_fire():
    w = make_world("four_corners", players=4, ai=True, teams=2)
    for p in w.players.values():
        p.ai = AI(w, p.slot)
    hits = []
    cls = type(w.units[0])
    original = cls.take_damage

    def watched(self, amount, attacker):
        if attacker is not None and getattr(attacker, "team", None) is not None \
                and self.team != attacker.team and w.allied(self.team, attacker.team):
            hits.append((self, attacker))
        return original(self, amount, attacker)

    cls.take_damage = watched
    try:
        assert run(w, 1500, until=lambda: w.game_over)
    finally:
        cls.take_damage = original
    assert hits == []
    survivors = {p.slot for p in w.players.values() if p.alive}
    assert {team_of(s, 2) for s in survivors} == {w.winner_team}


def test_lineup_text_names_small_games_and_counts_big_ones():
    assert lineup_text(1, 0) == "Free-for-all: everyone for themselves"
    assert lineup_text(3, 2) == "You + Computer 2  vs  Computer 1 + Computer 3"
    assert lineup_text(11, 4) == "You + 2 allies  vs  3 teams of 3"
    assert all(len(lineup_text(o, t)) <= 80 for o in range(1, 12) for t in (0, 2, 3, 4))


def test_settings_offer_only_meaningful_team_counts_and_clamp():
    settings.set("map_id", "four_corners")
    settings.set("opponents", 1)
    assert settings.team_options == [0]
    settings.set("opponents", 3)
    assert settings.team_options == [0, 2, 3]
    settings.cycle_teams()
    settings.cycle_teams()
    assert settings.team_count == 3
    settings.cycle_opponents()            # 3 -> 1 on a 4-player map
    assert settings.team_count == 0


def test_play_again_remembers_the_setup():
    s = LocalSession(DIFFICULTIES[1], map_id="crossroads", opponents=3, teams=2)
    assert s.skirmish == ("crossroads", 3, 2)
