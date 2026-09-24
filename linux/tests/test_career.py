"""The career record: wins and losses, overall and by difficulty."""
from fieldcommand.settings import settings


def test_the_career_counts_wins_and_losses_by_difficulty():
    settings.set("career", {})
    assert settings.career_text() == "No games played out yet"
    settings.record_result(True, 1)
    settings.record_result(True, 2)
    settings.record_result(False, 1)
    c = settings.career
    assert (c["wins"], c["losses"], c["wins_1"], c["wins_2"], c["losses_1"]) == (2, 1, 1, 1, 1)
    assert settings.career_text() == "Career: 2 won · 1 lost · 66%"
    settings.set("career", {})
