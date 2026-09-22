"""The interface scales to the screen: automatic choice, the logical surface, and mouse conversion."""
import os
import tempfile

import pytest

pygame = pytest.importorskip("pygame")
pytest.importorskip("cairo")
os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")

from fieldcommand.settings import _Settings  # noqa: E402


def test_automatic_scale_follows_the_shorter_side():
    auto = _Settings.auto_ui_scale
    assert auto(1400, 880) == 1 and auto(1920, 1080) == 1
    assert auto(2560, 1440) == 1.5 and auto(3440, 1440) == 1.5
    assert auto(3840, 2160) == 2 and auto(2880, 1800) == 2


def test_a_4k_window_gets_a_full_size_interface():
    os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp()
    os.environ["FC_AUTOSTART"] = "1"
    os.environ.pop("FC_UI_SCALE", None)
    from fieldcommand.main import App
    app = App()
    try:
        pygame.display.set_mode((3840, 2160), pygame.RESIZABLE)
        app._window_changed()
        assert app.ui_scale == 2
        assert app.screen.get_size() == (1920, 1080)          # scenes draw here
        assert app.window.get_size() == (3840, 2160)          # and this is what is shown
        g = app.scene
        g.update(1 / 30, None)
        g.draw(app.screen, None)
        app.present()
        # A 64-pixel button in the logical surface is 128 pixels on the screen.
        assert app.to_logical((3000, 2000)) == (1500, 1000)
        e = pygame.event.Event(pygame.MOUSEBUTTONDOWN, {"pos": (3000, 2000), "button": 1})
        assert app._scaled_event(e).pos == (1500, 1000)
        from fieldcommand import hud as hudmod
        ox, oy = g.hud.card_origin
        assert ox + 4 * (hudmod.BTN + hudmod.GAP) <= 1920 and oy + 2 * (hudmod.BTN + hudmod.GAP) <= 1080
    finally:
        pygame.display.set_mode((1400, 880), pygame.RESIZABLE)     # leave the display as other tests expect it
        app._window_changed()
