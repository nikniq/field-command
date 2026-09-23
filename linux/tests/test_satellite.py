"""The satellite view through the real client: Tab fits the whole map on screen with markers, Tab (or a jump)
brings the camera back where it was."""
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


def test_tab_shows_the_whole_map_and_tab_brings_you_back(game):
    app, g = game
    from fieldcommand import defs
    frame(app, g, 0.2)
    before = (g.cam.x, g.cam.y, g.cam.zoom)
    g._key_down(pygame.event.Event(pygame.KEYDOWN, key=pygame.K_TAB, unicode="\t", mod=0))
    assert g.satellite
    v = g.cam.view_rect()
    assert v[0] <= 0 and v[2] >= defs.WORLD_W and v[1] <= 0 and v[3] >= defs.WORLD_H     # the whole map fits
    frame(app, g, 0.2)                                                                   # markers draw
    g.zoom(1.1)                                                                          # zooming out does nothing
    assert g.satellite
    g._key_down(pygame.event.Event(pygame.KEYDOWN, key=pygame.K_TAB, unicode="\t", mod=0))
    assert not g.satellite and (g.cam.x, g.cam.y, g.cam.zoom) == before
    g.toggle_satellite()
    g.zoom(0.9)                                                                          # zooming in comes back down
    assert not g.satellite and g.cam.zoom == before[2]
