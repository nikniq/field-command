"""The real command card, drawn by the real HUD: every button that should show an icon does, through
selection changes, hover, presses, zoom and window resizes. Needs pygame with fonts and pycairo; skipped
where they are missing (the simulation tests need neither)."""
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

import numpy as np  # noqa: E402


@pytest.fixture(scope="module")
def game():
    os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp()
    os.environ["FC_AUTOSTART"] = "1"
    from fieldcommand.main import App
    app = App()
    g = app.scene
    w = g.s.world
    hq = next(b for b in w.buildings if b.team == 0 and b.kind == "hq")

    def make(kind, dx, dy):
        b = w.start_building(kind, hq.x + dx, hq.y + dy, 0)
        b.built, b.progress, b.hp = True, 1.0, b.max_hp
        return b
    built = {k: make(k, dx, dy) for k, dx, dy in (("barracks", 300, 0), ("factory", 300, 250), ("depot", -300, 0), ("turret", 0, 300))}
    w.bridges_changed()
    w.resources[0] = 9999
    from fieldcommand.entities import Unit
    tank = Unit(w, "tank", 0, hq.x + 150, hq.y - 150)
    w._add(tank)
    eng = next(u for u in w.units if u.team == 0 and u.kind == "worker")
    yield app, g, {"hq": hq, "eng": eng, "tank": tank, **built}
    pygame.quit()


def icon_ink(screen, r, btn):
    """How much the middle of a button differs from a bare button face: near 0 means no icon was drawn."""
    from fieldcommand import art
    face = art.button(btn, btn, "normal")
    cx, cy = r.centerx, r.centery - 5
    patch = pygame.surfarray.array3d(screen.subsurface((cx - 17, cy - 17, 34, 34))).astype(int)
    ref = pygame.surfarray.array3d(face.subsurface((btn // 2 - 17, btn // 2 - 5 - 17, 34, 34))).astype(int)
    return float(np.abs(patch - ref).mean())


def test_every_card_icon_is_drawn_through_the_whole_workout(game):
    from fieldcommand import hud as hudmod
    app, g, e = game
    BTN, GAP = hudmod.BTN, hudmod.GAP
    scenarios = [[e["hq"]], [e["eng"]], [e["barracks"]], [e["tank"]], [e["barracks"], e["factory"], e["depot"], e["turret"]], []]
    blank = []
    for size in ((1400, 880), (1024, 700), (1920, 1080)):
        app.screen = pygame.display.set_mode(size, pygame.RESIZABLE)
        g.resize(*size)
        for sel in scenarios:
            g.set_selection(sel)
            for k in range(30):
                ox, oy = g.hud.card_origin
                rects = [pygame.Rect(ox + (i % 4) * (BTN + GAP), oy + (i // 4) * (BTN + GAP), BTN, BTN) for i in range(8)]
                mouse = rects[0].center if 8 <= k < 14 and g.hud.current_buttons else None
                if k == 14 and g.hud.current_buttons:
                    g.hud.press_button(0)
                if k == 20 and sel == [e["eng"]] and len(g.hud.current_buttons) > 2:
                    g.hud.press_button(2)
                if k == 24:
                    g.zoom(0.8 if k % 2 else 1.25)
                g.update(1 / 30, mouse)
                g.draw(app.screen, mouse)
                for i, b in enumerate(g.hud.current_buttons[:8]):
                    if icon_ink(app.screen, rects[i], BTN) < 6:
                        blank.append((size, [x.name for x in sel], k, b.title))
            g.cancel_modes()
    assert blank == []


def test_card_titles_fit_their_buttons(game):
    from fieldcommand import hud as hudmod, ui
    app, g, e = game
    for sel in ([e["hq"]], [e["barracks"]], [e["depot"]], [e["turret"]], [e["eng"]], [e["tank"]]):
        g.set_selection(sel)
        g.hud.current_buttons = g.command_buttons()
        for b in g.hud.current_buttons:
            size = 10
            while size > 7 and ui.font(size, True).size(b.title)[0] > hudmod.BTN - 6:
                size -= 1
            assert ui.font(size, True).size(b.title)[0] <= hudmod.BTN - 6, (b.title, size)
