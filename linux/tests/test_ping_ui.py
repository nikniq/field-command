"""The alert point through the real client: Z then a click places it, the beacon and the minimap ping draw,
Space jumps to it. Needs pygame with fonts and pycairo; skipped where they are missing."""
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
    os.environ["FC_AUTOSTART"] = "1"
    from fieldcommand.main import App
    app = App()
    return app, app.scene


def frame(app, g, seconds=0.1):
    for _ in range(int(seconds / (1 / 30))):
        g.update(1 / 30, None)
    g.draw(app.screen, None)


def test_z_then_click_places_an_alert_point_and_it_is_drawn(game):
    app, g = game
    frame(app, g, 0.5)
    g._key_down(pygame.event.Event(pygame.KEYDOWN, key=pygame.K_z, unicode="z", mod=0))
    assert g.ping_pending
    hw, hh = app.screen.get_size()
    target = g.cam.to_world(hw // 2 + 40, hh // 2 - 40)
    g._left_down((hw // 2 + 40, hh // 2 - 40), False)
    assert not g.ping_pending
    frame(app, g, 0.3)                       # the server answers with the ping event
    assert g.beacons and abs(g.beacons[-1][0] - target[0]) < 2 and abs(g.beacons[-1][1] - target[1]) < 2
    assert g.beacons[-1][4] == 0                      # Z: an attack point
    assert g._last_alert_pos is not None
    assert g.hud._pings and g.hud._pings[-1][4] == 4.0
    frame(app, g, 0.1)                       # draws the beacon without error
    # Space jumps the camera to it.
    g.center_camera(target[0] + 900, target[1] + 600)
    g._key_down(pygame.event.Event(pygame.KEYDOWN, key=pygame.K_SPACE, unicode=" ", mod=0))
    assert abs(g.cam.x - target[0]) < 120 and abs(g.cam.y - target[1]) < 120     # as near as the map edge allows
    # Shift+Z is a help point.
    g._key_down(pygame.event.Event(pygame.KEYDOWN, key=pygame.K_z, unicode="Z", mod=pygame.KMOD_SHIFT))
    assert g.ping_pending and g.ping_kind == 1
    frame(app, g, 3.1)
    g._left_down((hw // 2 - 40, hh // 2 + 40), False)
    frame(app, g, 0.3)
    assert g.beacons[-1][4] == 1
    # Escape cancels a pending alert point.
    g.begin_ping()
    g._key_down(pygame.event.Event(pygame.KEYDOWN, key=pygame.K_ESCAPE, unicode="", mod=0))
    assert not g.ping_pending
