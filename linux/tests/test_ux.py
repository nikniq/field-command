"""Quality-of-life through the real client: portrait clicks refine a mixed selection, control groups badge
their units, leaving to the menu autosaves, and health bars can be always on."""
import os
import tempfile

import pytest

pygame = pytest.importorskip("pygame")
pytest.importorskip("cairo")
os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
try:
    pygame.font.init()
    pygame.font.SysFont("arial", 12)
except Exception as e:      # noqa: BLE001
    pytest.skip(f"pygame has no usable fonts here: {e}", allow_module_level=True)


@pytest.fixture(scope="module")
def game():
    os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp()
    os.environ["XDG_DATA_HOME"] = tempfile.mkdtemp()
    os.environ["FC_AUTOSTART"] = "1"
    from fieldcommand.main import App
    app = App()
    return app, app.scene


def frame(app, g, seconds=0.1):
    for _ in range(int(seconds / (1 / 30))):
        g.update(1 / 30, None)
    g.draw(app.screen, None)


def test_a_portrait_click_keeps_one_kind_and_shift_drops_it(game):
    app, g = game
    from fieldcommand.entities import Unit
    w = g.s.world
    hq = next(b for b in w.buildings if b.team == 0 and b.kind == "hq")
    tanks = [Unit(w, "tank", 0, hq.x + 200 + i * 40, hq.y + 200) for i in range(2)]
    marines = [Unit(w, "marine", 0, hq.x + 200 + i * 30, hq.y + 260) for i in range(3)]
    for u in tanks + marines:
        w._add(u)
    frame(app, g, 0.2)
    g.set_selection(tanks + marines)
    frame(app, g, 0.1)
    rect, e = next((r, e) for r, e in g.hud.icon_rects if e.kind == "tank")
    g.hud.handle_click(rect.center, right=False)
    assert sorted(u.id for u in g.selection) == sorted(u.id for u in tanks)
    g.set_selection(tanks + marines)
    frame(app, g, 0.1)
    rect, e = next((r, e) for r, e in g.hud.icon_rects if e.kind == "tank")
    pygame.key.set_mods(pygame.KMOD_SHIFT)
    try:
        g.hud.handle_click(rect.center, right=False)
    finally:
        pygame.key.set_mods(0)
    assert sorted(u.id for u in g.selection) == sorted(u.id for u in marines)


def test_control_groups_badge_their_units_and_bars_can_be_always_on(game):
    app, g = game
    from fieldcommand.settings import settings
    w = g.s.world
    marines = [u for u in w.units if u.team == 0 and u.kind == "marine"]
    g.set_selection(marines)
    g._key_down(pygame.event.Event(pygame.KEYDOWN, key=pygame.K_2, unicode="2", mod=pygame.KMOD_CTRL))
    assert all(g.group_of.get(u.id) == 2 for u in marines)
    settings.set("bars_always", True)
    frame(app, g, 0.1)                          # bars on every friendly, badges on the group — all draw
    settings.set("bars_always", False)


def test_leaving_to_the_menu_autosaves(game):
    app, g = game
    from fieldcommand import save
    before = {s[0] for s in save.list_saves()}
    g.to_menu()
    assert "autosave" in {s[0] for s in save.list_saves()} and "autosave" not in before or "autosave" in before
    assert type(app.scene).__name__ == "MenuScene"
