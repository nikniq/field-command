"""Title screen: an animated skirmish in the background, difficulty cards and quick settings."""
import math
import random

import pygame

from . import art, audio, mapgen, ui
from .defs import AMBER, BUTTON_EDGE, DIFFICULTIES, DIM, ENEMY, PLAYER, TEXT, to255
from .effects import Effects
from .game import Camera, GameScene
from .session import LocalSession
from .settings import settings


class MenuScene:
    def __init__(self, app):
        self.app = app
        self.fx = Effects()
        self.t = 0.0
        self._boom = 0.0
        self.cards = []
        self.toggles = []
        w, h = app.screen.get_size()
        self.resize(w, h)

    def resize(self, w, h):
        self.w, self.h = w, h
        self.cam = Camera(w, h)
        self.cam.x = self.cam.y = 0.0
        rnd = random.Random(77)
        self.props = []  # (texture, x, y, angle_deg, scale)
        for team, sx, sy in ((PLAYER, -1, -1), (ENEMY, 1, 1)):
            bx, by = sx * (w / 2 - 140), sy * (h / 2 - 120)
            for kind, ox, oy in (("hq", 0, 0), ("barracks", -sx * 190, 0), ("turret", -sx * 120, -sy * 150), ("depot", 0, -sy * 160)):
                self.props.append((art.building(kind, team), bx + ox, by + oy, 0, 1))
                if kind == "turret":
                    self.props.append((art.turret_gun(team), bx + ox, by + oy, math.degrees(math.pi + 0.6 if sx > 0 else 0.6), 1))
        for i in range(8):
            a = i * 0.7
            self.props.append((art.crystal(i % 3), -w / 2 + 560 + math.cos(a) * 70, -h / 2 + 150 + math.sin(a) * 55, 0, 1))
        for _ in range(24):
            if rnd.random() < 0.5:
                p = (rnd.uniform(-w / 2, w / 2), (1 if rnd.random() < 0.5 else -1) * (h / 2 - 10))
            else:
                p = ((1 if rnd.random() < 0.5 else -1) * (w / 2 - 10), rnd.uniform(-h / 2, h / 2))
            self.props.append((art.tree(rnd.randint(0, 2)), p[0], p[1], rnd.uniform(0, 360), 1))
        self.squads = []
        for i in range(10):
            team = PLAYER if i % 2 == 0 else ENEMY
            kind = "tank" if i % 3 == 0 else "marine"
            d = 1 if team == PLAYER else -1
            self.squads.append((team, kind, d, rnd.uniform(-h / 3, h / 3), rnd.uniform(16, 28), rnd.uniform(0, 10)))
        self.ground = pygame.Surface((w, h)).convert()
        tile = art.ground_tile()
        for x in range(0, w, 1024):
            for y in range(0, h, 1024):
                self.ground.blit(tile, (x, y))
        shade = pygame.Surface((w, h), pygame.SRCALPHA)
        shade.fill((0, 0, 0, 0))
        self.shade = shade

    def handle_event(self, e):
        if e.type == pygame.MOUSEBUTTONDOWN and e.button == 1:
            for r, d in self.cards:
                if r.collidepoint(e.pos):
                    self.start(d)
                    return
            mp = getattr(self, "toggles_mp", None)
            if mp and mp[0].collidepoint(e.pos):
                mp[1]()
                return
            for r, action in self.toggles:
                if r.collidepoint(e.pos):
                    audio.play("click")
                    action()
                    return
        elif e.type == pygame.KEYDOWN:
            if e.key in (pygame.K_1, pygame.K_KP1):
                self.start(DIFFICULTIES[0])
            elif e.key in (pygame.K_2, pygame.K_KP2):
                self.start(DIFFICULTIES[1])
            elif e.key in (pygame.K_3, pygame.K_KP3):
                self.start(DIFFICULTIES[2])
            elif e.key in (pygame.K_RETURN, pygame.K_KP_ENTER):
                self.start(DIFFICULTIES[settings.last_difficulty % 3])
            elif e.key == pygame.K_m:
                self.multiplayer()
            elif e.key == pygame.K_ESCAPE:
                self.app.quit()

    def start(self, d):
        settings.set("last_difficulty", d.index)
        audio.play("click")
        session = LocalSession(d, autoplay=self.app.autoplay, map_id=settings.map_id,
                               opponents=min(settings.opponents, settings.max_opponents))
        self.app.set_scene(GameScene(self.app, session))

    def multiplayer(self):
        from .lobby import MultiplayerScene
        audio.play("click")
        self.app.set_scene(MultiplayerScene(self.app))

    def update(self, dt, mouse):
        self.t += dt
        self._boom -= dt
        if self._boom <= 0:
            self._boom = random.uniform(0.6, 1.8)
            x, y = random.uniform(-self.w / 2, self.w / 2), random.uniform(-self.h / 2, self.h / 2)
            s = random.uniform(14, 30)
            self.fx.fire_burst(x, y, s)
            self.fx.smoke_burst(x, y, s)
        self.fx.update(dt)

    def draw(self, screen, mouse):
        w, h = self.w, self.h
        drift = (math.sin(self.t / 20 * math.pi) * 30, math.sin(self.t / 20 * math.pi) * 15)
        screen.blit(self.ground, (drift[0] - 40, drift[1] - 40))
        screen.blit(self.ground, (drift[0] - 40 + w, drift[1] - 40))
        screen.blit(self.ground, (drift[0] - 40, drift[1] - 40 + h))
        cam = self.cam
        for tex, x, y, ang, s in self.props:
            img = art.sprites.get(("menuprop", id(tex)), tex, ang, s / art.SCALE)
            sx, sy = cam.to_screen(x, y)
            screen.blit(img, (sx - img.get_width() / 2, sy - img.get_height() / 2))
        for team, kind, d, y0, dur, delay in self.squads:
            t = self.t - delay
            if t < 0:
                continue
            k = (t % dur) / dur
            travel = w + 120
            x = -d * (w / 2 + 60) + d * travel * k
            y = y0 + d * travel * 0.25 * k
            ang = 14.3 if d > 0 else 194.3
            sx, sy = cam.to_screen(x, y)
            img = art.sprites.get(("unit", kind, team), art.unit(kind, team), ang, 1 / art.SCALE)
            screen.blit(img, (sx - img.get_width() / 2, sy - img.get_height() / 2))
            if kind == "tank":
                tur = art.sprites.get(("turret", team), art.tank_turret(team), ang, 1 / art.SCALE)
                screen.blit(tur, (sx - tur.get_width() / 2, sy - tur.get_height() / 2))
        self.fx.draw(screen, cam, ui.text)
        dim = pygame.Surface((w, h), pygame.SRCALPHA)
        dim.fill((0, 0, 0, 128))
        screen.blit(dim, (0, 0))
        screen.blit(art.vignette(w * 1.15, h * 1.15), (-w * 0.075, -h * 0.075))
        self._draw_content(screen, mouse)

    def _draw_content(self, screen, mouse):
        w, h = self.w, self.h
        title_y = h * 0.23
        glow = art.tinted_glow((900, 260), to255(BUTTON_EDGE), 3)
        screen.blit(glow, (w / 2 - 450, title_y - 130), special_flags=pygame.BLEND_ADD)
        size = int(min(92, w / 9))
        ui.blit_text(screen, "FIELD COMMAND", size, (0, 0, 0), (w / 2 + 3, title_y + 4), align="center", bold=True)
        ui.blit_text(screen, "FIELD COMMAND", size, TEXT, (w / 2, title_y), align="center", bold=True)
        ui.blit_text(screen, "A  REAL-TIME  STRATEGY  OPERATION", 15, AMBER, (w / 2, title_y + 58), align="center", bold=True)

        cw, ch, gap = 230, 150, 24
        total = 3 * cw + 2 * gap
        cy = h * 0.48
        ui.blit_text(screen, "SELECT DIFFICULTY", 13, DIM, (w / 2, cy - ch / 2 - 26), align="center", bold=True)
        icons = ["worker", "marine", "tank"]
        self.cards = []
        for i, d in enumerate(DIFFICULTIES):
            r = pygame.Rect(int(w / 2 - total / 2 + i * (cw + gap)), int(cy - ch / 2), cw, ch)
            hover = mouse is not None and r.collidepoint(mouse)
            rr = r.inflate(6, 6) if hover else r
            screen.blit(art.button(rr.w, rr.h, "hover" if hover else "normal"), rr.topleft)
            tex = art.unit(icons[i], ENEMY if i == 2 else PLAYER)
            img = art.sprites.get(("card", i), tex, 90, 58 / max(tex.get_size()))
            screen.blit(img, (r.centerx - img.get_width() / 2, r.centery - 30 - img.get_height() / 2))
            ui.blit_text(screen, d.name.upper(), 24, TEXT, (r.centerx, r.centery + 18), align="center", bold=True)
            ui.blit_text(screen, d.blurb, 12, DIM, (r.centerx, r.centery + 44), align="center")
            ui.blit_text(screen, str(i + 1), 12, AMBER, (r.x + 16, r.y + 16), align="center", bold=True)
            if i == settings.last_difficulty:
                ui.blit_text(screen, "LAST PLAYED", 9, AMBER, (r.right - 12, r.y + 16), align="right", bold=True)
            self.cards.append((r, d))

        mr = pygame.Rect(int(w / 2 - 160), int(cy + ch / 2 + 22), 320, 44)
        hover = mouse is not None and mr.collidepoint(mouse)
        screen.blit(art.button(mr.w, mr.h, "hover" if hover else "active", AMBER), mr.topleft)
        ui.blit_text(screen, "MULTIPLAYER  (M)", 16, TEXT, mr.center, align="center", bold=True)
        self.toggles_mp = (mr, self.multiplayer)
        rows = [
            (f"Speed: {settings.speed_name}", settings.cycle_speed),
            (f"Edge scroll: {'On' if settings.edge_scroll else 'Off'}", lambda: settings.toggle("edge_scroll")),
            (f"Sound: {'On' if settings.sound else 'Off'}", lambda: settings.toggle("sound")),
            (f"Objectives: {'On' if settings.objectives else 'Off'}", lambda: settings.toggle("objectives")),
            (f"Fullscreen: {'On' if settings.fullscreen else 'Off'}", self.app.toggle_fullscreen),
        ]
        tw, th, tg = 150, 34, 12
        tt = len(rows) * tw + (len(rows) - 1) * tg
        ty = cy + ch / 2 + 86
        self.toggles = []
        for i, (label, action) in enumerate(rows):
            r = pygame.Rect(int(w / 2 - tt / 2 + i * (tw + tg)), int(ty), tw, th)
            hover = mouse is not None and r.collidepoint(mouse)
            screen.blit(art.button(tw, th, "hover" if hover else "normal"), r.topleft)
            ui.blit_text(screen, label, 13, TEXT, r.center, align="center", bold=True)
            self.toggles.append((r, action))
        # Map and opponent pickers
        meta = mapgen.BY_ID.get(settings.map_id, mapgen.CATALOG[0])
        n = min(settings.opponents, settings.max_opponents)
        picks = [(360, f"Map: {meta['name']}  ({meta['players']}p)", settings.cycle_map),
                 (170, f"Opponents: {n}", settings.cycle_opponents)]
        pt = sum(p[0] for p in picks) + tg
        x = w / 2 - pt / 2
        py = ty + th + 12
        for pw, label, action in picks:
            r = pygame.Rect(int(x), int(py), pw, th)
            hover = mouse is not None and r.collidepoint(mouse)
            screen.blit(art.button(pw, th, "hover" if hover else "active", AMBER), r.topleft)
            ui.blit_text(screen, label, 13, TEXT, r.center, align="center", bold=True)
            self.toggles.append((r, action))
            x += pw + tg
        ui.blit_text(screen, meta.get("desc", ""), 12, DIM, (w / 2, py + th + 14), align="center")
        ty += th + 38
        lines = ["Mine crystal with Engineers, expand, and train an army of Rangers and Siege Tanks.",
                 "Destroy every enemy building to win. Objectives on screen will guide your first minutes."]
        for i, l in enumerate(lines):
            ui.blit_text(screen, l, 14, TEXT, (w / 2, ty + 80 + i * 24), align="center")
        ui.blit_text(screen, "1 / 2 / 3 or Enter to deploy  ·  M multiplayer  ·  F11 full screen  ·  Esc quit", 12, DIM, (w / 2, h - 26), align="center")
