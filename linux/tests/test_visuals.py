"""Client-side visual feedback through the real client: the map bakes with its tint, a hit whitens a sprite
for a few frames, and someone on foot who dies leaves a body where they dropped."""
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


def test_the_ground_carries_the_map_tint_and_the_clouds_drift(game):
    app, g = game
    from fieldcommand import art
    assert g.ground.get_size() == (int(g.s.map["w"]), int(g.s.map["h"]))
    tint = art.map_tint(64, 48, 42)
    px = pygame.surfarray.array3d(tint)
    assert px[0, 0].sum() > px[63, 47].sum()          # the sun's corner is brighter than the far one
    assert (px.max(axis=(0, 1)) <= 255).all()
    clouds = art.cloud_layer()
    assert clouds.get_size() == (1024, 1024) and pygame.surfarray.array_alpha(clouds).max() > 0
    frame(app, g, 0.5)                                 # draws the cloud layer without error


def test_a_hit_flashes_and_the_fallen_stay_where_they_dropped(game):
    app, g = game
    w = g.s.world
    hq = next(b for b in w.buildings if b.team == 0 and b.kind == "hq")
    frame(app, g, 0.2)
    eng = next(u for u in w.units if u.team == 0 and u.kind == "worker")
    eng.take_damage(10, None)
    frame(app, g, 1 / 30)
    assert eng._flash > 0
    frame(app, g, 0.5)
    assert eng._flash == 0
    hq.take_damage(10, None)
    frame(app, g, 1 / 30)
    assert hq._flash > 0
    before = len([d for d in g.fx.decals if isinstance(d[0], tuple)])
    eng.take_damage(99999, None)
    frame(app, g, 0.2)
    fallen = [d for d in g.fx.decals if isinstance(d[0], tuple)]
    assert len(fallen) == before + 1 and fallen[-1][0] == ("fallen", "worker")
    frame(app, g, 0.1)                                 # and it draws
