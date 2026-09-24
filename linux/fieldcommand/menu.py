"""Title screen: an animated skirmish in the background, difficulty cards and quick settings."""
import math
import random

import pygame

from . import __version__, art, audio, mapgen, ui
from .defs import AMBER, BUTTON_EDGE, DIFFICULTIES, DIM, ENEMY, GOOD, PLAYER, TEXT, to255
from .effects import Effects
from .game import Camera, GameScene
from .session import LocalSession, lineup_text
from .settings import settings


class MenuScene:
    def __init__(self, app):
        self.app = app
        self.fx = Effects()
        self.t = 0.0
        self._boom = 0.0
        self.cards = []
        self.toggles = []
        self.campaign_open = False
        self.campaign_rows = []      # (rect, Mission) for the missions that can be started
        self.briefing = None         # the mission whose briefing is up, before it is deployed
        self.deploy_rect = None
        self._thumbs = {}            # map id -> briefing map surface
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
        if self.briefing is not None:
            if e.type == pygame.MOUSEBUTTONDOWN and e.button == 1:
                if self.deploy_rect and self.deploy_rect.collidepoint(e.pos):
                    self.deploy(self.briefing)
            elif e.type == pygame.KEYDOWN and e.key in (pygame.K_RETURN, pygame.K_KP_ENTER):
                self.deploy(self.briefing)
            elif e.type == pygame.KEYDOWN and e.key in (pygame.K_ESCAPE, pygame.K_c):
                self.briefing, self.campaign_open = None, True
            return
        if self.campaign_open:
            if e.type == pygame.MOUSEBUTTONDOWN and e.button == 1:
                for r, m in self.campaign_rows:
                    if r.collidepoint(e.pos):
                        self.start_mission(m)
                        return
            elif e.type == pygame.KEYDOWN and e.key in (pygame.K_c, pygame.K_ESCAPE):
                self.campaign_open = False
            return
        if e.type == pygame.MOUSEBUTTONDOWN and e.button == 1:
            cp = getattr(self, "toggles_campaign", None)
            if cp and cp[0].collidepoint(e.pos):
                cp[1]()
                return
            for r, d in self.cards:
                if r.collidepoint(e.pos):
                    self.start(d)
                    return
            mp = getattr(self, "toggles_mp", None)
            if mp and mp[0].collidepoint(e.pos):
                mp[1]()
                return
            ld = getattr(self, "toggles_load", None)
            if ld and ld[0].collidepoint(e.pos):
                ld[1]()
                return
            rp = getattr(self, "toggles_replay", None)
            if rp and rp[0].collidepoint(e.pos):
                rp[1]()
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
            elif e.key == pygame.K_c:
                self.toggle_campaign()
            elif e.key == pygame.K_l:
                self.load_latest()
            elif e.key == pygame.K_r:
                self.watch_replay()
            elif e.key == pygame.K_ESCAPE:
                self.app.quit()

    def start(self, d):
        settings.set("last_difficulty", d.index)
        audio.play("click")
        session = LocalSession(d, autoplay=self.app.autoplay, map_id=settings.map_id,
                               opponents=min(settings.opponents, settings.max_opponents), teams=settings.team_count)
        self.app.set_scene(GameScene(self.app, session))

    def toggle_campaign(self):
        audio.play("click")
        self.campaign_open = not self.campaign_open

    def start_mission(self, m):
        """A mission is briefed before it is deployed: the map, the objective and what the clock will bring."""
        audio.play("click")
        self.briefing, self.campaign_open = m, False

    def deploy(self, m):
        from .defs import DIFFICULTIES
        audio.play("click")
        session = LocalSession(DIFFICULTIES[m.difficulty], autoplay=self.app.autoplay, map_id=m.map,
                               opponents=m.opponents, teams=m.teams, mission=m.id)
        self.app.set_scene(GameScene(self.app, session))

    @staticmethod
    def objective_text(m):
        clock = f"{int(m.seconds) // 60}:{int(m.seconds) % 60:02d}"
        return {"destroy": "Destroy every enemy building", "survive": f"Be standing after {clock}",
                "hold": f"Hold the ring for {clock} with no enemy inside"}[m.win]

    @staticmethod
    def timeline(m):
        """The script as the briefing shows it: (m:ss, line) per event, columns named by whose they are."""
        rows = []
        for e in m.events:
            at = f"{int(e[1]) // 60}:{int(e[1]) % 60:02d}"
            if e[0] == "text":
                rows.append((at, "Word from Command"))
            else:
                rows.append((at, ("Reinforcements arrive" if e[2] == 0 else "Enemy column on the move")))
        return rows

    def map_thumb(self, m, tw):
        """The mission's map, small: water and cliffs, crystal and gold, every side's start, the hold ring."""
        from .defs import CRYSTAL, TEAM_COLOR
        spec = mapgen.resolve(m.map, 1 + m.opponents)
        key = (m.id, tw)
        if key in self._thumbs:
            return self._thumbs[key]
        mw, mh = spec["w"], spec["h"]
        s = tw / mw
        th = max(1, int(mh * s))
        surf = pygame.Surface((tw, th))
        surf.fill((48, 70, 40))
        for x0, y0, x1, y1, kind in spec.get("walls", []):
            col = (38, 66, 104) if kind == "water" else (74, 62, 50)
            pygame.draw.rect(surf, col, (int(x0 * s), int(y0 * s), max(1, int((x1 - x0) * s)), max(1, int((y1 - y0) * s))))
        for x0, y0, x1, y1 in spec.get("bridges", []):
            pygame.draw.rect(surf, to255(AMBER), (int(x0 * s), int(y0 * s), max(2, int((x1 - x0) * s)), max(2, int((y1 - y0) * s))))
        for c in spec["crystals"]:
            gold = len(c) > 3 and c[3] == 3
            r = 3 if gold else 1
            pygame.draw.rect(surf, to255(AMBER if gold else CRYSTAL), (int(c[0] * s) - r, int(c[1] * s) - r, 2 * r + 1, 2 * r + 1))
        for i, st in enumerate(spec["starts"][:1 + m.opponents]):
            p = (int(st[0] * s), int(st[1] * s))
            pygame.draw.rect(surf, to255(TEAM_COLOR[i]), (p[0] - 4, p[1] - 4, 9, 9))
            pygame.draw.rect(surf, (255, 255, 255), (p[0] - 5, p[1] - 5, 11, 11), 1)
        if m.hold:
            pygame.draw.circle(surf, to255(AMBER), (int(m.hold[0] * s), int(m.hold[1] * s)), max(4, int(m.hold[2] * s)), 1)
        self._thumbs[key] = surf
        return surf

    def _draw_briefing(self, screen, mouse):
        from .defs import CAMPAIGN, DIFFICULTIES
        m = self.briefing
        w, h = self.w, self.h
        dim = pygame.Surface((w, h), pygame.SRCALPHA)
        dim.fill((0, 0, 0, 170))
        screen.blit(dim, (0, 0))
        box_w, box_h = min(w - 40, 780), min(h - 20, 540)
        bx, by = (w - box_w) // 2, max(10, (h - box_h) // 2)
        screen.blit(art.panel(box_w, box_h, 16, AMBER), (bx, by))
        n = [x.id for x in CAMPAIGN].index(m.id) + 1
        ui.blit_text(screen, m.title.upper(), 34, AMBER, (w / 2, by + 42), align="center", bold=True)
        meta = mapgen.BY_ID.get(m.map, {"name": m.map})["name"]
        ui.blit_text(screen, f"Mission {n} of {len(CAMPAIGN)} · {meta} · {m.opponents} opponent{'s' if m.opponents != 1 else ''} · {DIFFICULTIES[m.difficulty].name}",
                     13, DIM, (w / 2, by + 74), align="center", bold=True)
        tw = min(300, box_w // 2 - 40)
        thumb = self.map_thumb(m, tw)
        tx, ty = bx + 24, by + 100
        pygame.draw.rect(screen, (20, 24, 26), (tx - 3, ty - 3, thumb.get_width() + 6, thumb.get_height() + 6))
        screen.blit(thumb, (tx, ty))
        ui.blit_text(screen, "You are the white-edged square; the ring is the hold.", 10, DIM, (tx, ty + thumb.get_height() + 14))
        rx = tx + tw + 28
        rw = bx + box_w - 24 - rx
        y = ty
        for line in ui.wrap(m.brief, 13, rw)[:4]:
            ui.blit_text(screen, line, 13, TEXT, (rx, y))
            y += 18
        y += 10
        ui.blit_text(screen, "OBJECTIVE", 12, AMBER, (rx, y), bold=True)
        ui.blit_text(screen, self.objective_text(m), 13, TEXT, (rx, y + 18))
        y += 46
        ui.blit_text(screen, "TIMELINE", 12, AMBER, (rx, y), bold=True)
        y += 18
        for at, line in self.timeline(m)[:6]:
            ui.blit_text(screen, at, 12, DIM, (rx, y), mono=True)
            ui.blit_text(screen, line, 12, TEXT, (rx + 44, y))
            y += 16
        r = pygame.Rect(w // 2 - 110, by + box_h - 74, 220, 44)
        hover = mouse is not None and r.collidepoint(mouse)
        screen.blit(art.button(r.w, r.h, "hover" if hover else "normal", GOOD), r.topleft)
        ui.blit_text(screen, "DEPLOY  (Enter)", 16, TEXT, r.center, align="center", bold=True)
        self.deploy_rect = r
        ui.blit_text(screen, "Esc back to the mission list", 11, DIM, (w / 2, by + box_h - 18), align="center")

    def _draw_campaign(self, screen, mouse):
        """The mission list: each unlocks the next; done ones are ticked."""
        from .defs import CAMPAIGN, DIFFICULTIES
        w, h = self.w, self.h
        done = list(settings.campaign_done)
        dim = pygame.Surface((w, h), pygame.SRCALPHA)
        dim.fill((0, 0, 0, 150))
        screen.blit(dim, (0, 0))
        box_w, row_h = min(w - 40, 640), 78
        box_h = 120 + row_h * len(CAMPAIGN) + 60
        bx, by = (w - box_w) // 2, max(10, (h - box_h) // 2)
        screen.blit(art.panel(box_w, box_h, 16, GOOD), (bx, by))
        ui.blit_text(screen, "CAMPAIGN", 36, GOOD, (w / 2, by + 44), align="center", bold=True)
        ui.blit_text(screen, "Five missions, played in order. Each unlocks the next.", 13, TEXT, (w / 2, by + 78), align="center", bold=True)
        self.campaign_rows = []
        y = by + 118
        for i, m in enumerate(CAMPAIGN):
            unlocked = i == 0 or CAMPAIGN[i - 1].id in done
            finished = m.id in done
            r = pygame.Rect(bx + 20, int(y), box_w - 40, row_h - 8)
            hover = mouse is not None and r.collidepoint(mouse) and unlocked
            state = "disabled" if not unlocked else ("hover" if hover else ("active" if finished else "normal"))
            screen.blit(art.button(r.w, r.h, state, GOOD if finished else AMBER), r.topleft)
            head = f"{i + 1}. {m.title}" + ("  ✓" if finished else ("" if unlocked else "  — locked"))
            ui.blit_text(screen, head, 16, TEXT if unlocked else DIM, (r.x + 16, r.y + 20), bold=True)
            meta = mapgen.BY_ID.get(m.map, {"name": m.map})["name"]
            ui.blit_text(screen, f"{meta} · {m.opponents} opponent{'s' if m.opponents != 1 else ''} · {DIFFICULTIES[m.difficulty].name}",
                         11, DIM, (r.right - 16, r.y + 20), align="right")
            for j, line in enumerate(ui.wrap(m.brief, 12, r.w - 32)[:2]):
                ui.blit_text(screen, line, 12, TEXT if unlocked else DIM, (r.x + 16, r.y + 42 + j * 15))
            if unlocked:
                self.campaign_rows.append((r, m))
            y += row_h
        ui.blit_text(screen, "Click a mission to deploy · C or Esc closes", 12, DIM, (w / 2, by + box_h - 28), align="center")

    def _latest_save(self):
        from .save import list_saves
        saves = list_saves()
        return saves[0] if saves else None

    def load_latest(self):
        latest = self._latest_save()
        if not latest:
            return
        from .session import LocalSession
        try:
            session = LocalSession.load(latest[0], autoplay=self.app.autoplay)
        except (OSError, ValueError, KeyError):
            return
        audio.play("click")
        self.app.set_scene(GameScene(self.app, session))

    def watch_replay(self):
        from .replay import list_replays
        if not list_replays():
            return
        from .session import LocalSession
        try:
            session = LocalSession.replay(list_replays()[0][0])
        except (OSError, ValueError, KeyError):
            return
        audio.play("click")
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

        # Campaign, Multiplayer and Load Game in a row under the difficulty cards.
        from .defs import CAMPAIGN
        kr = pygame.Rect(int(w / 2 - 380), int(cy + ch / 2 + 22), 230, 44)
        hover = mouse is not None and kr.collidepoint(mouse)
        screen.blit(art.button(kr.w, kr.h, "hover" if hover else "active", GOOD), kr.topleft)
        ui.blit_text(screen, "CAMPAIGN  (C)", 16, TEXT, kr.center, align="center", bold=True)
        ui.blit_text(screen, f"{len(settings.campaign_done)} of {len(CAMPAIGN)} missions done", 11, DIM,
                     (kr.centerx, kr.bottom + 12), align="center")
        self.toggles_campaign = (kr, self.toggle_campaign)
        mr = pygame.Rect(int(w / 2 - 140), int(cy + ch / 2 + 22), 260, 44)
        hover = mouse is not None and mr.collidepoint(mouse)
        screen.blit(art.button(mr.w, mr.h, "hover" if hover else "active", AMBER), mr.topleft)
        ui.blit_text(screen, "MULTIPLAYER  (M)", 16, TEXT, mr.center, align="center", bold=True)
        self.toggles_mp = (mr, self.multiplayer)
        latest = self._latest_save()
        lr = pygame.Rect(int(w / 2 + 130), int(cy + ch / 2 + 22), 250, 44)
        hover = mouse is not None and lr.collidepoint(mouse)
        screen.blit(art.button(lr.w, lr.h, "hover" if hover and latest else ("normal" if latest else "disabled")), lr.topleft)
        ui.blit_text(screen, "LOAD GAME  (L)", 14, TEXT if latest else DIM, lr.center, align="center", bold=True)
        if latest:
            name, label, _at, elapsed = latest
            ui.blit_text(screen, f"{label or name} · {int(elapsed) // 60:02d}:{int(elapsed) % 60:02d} in",
                         11, DIM, (lr.centerx, lr.bottom + 12), align="center")
        self.toggles_load = (lr, self.load_latest) if latest else None
        from .replay import list_replays
        reps = list_replays()
        rr_ = pygame.Rect(int(w / 2 + 130), int(cy + ch / 2 + 22 + 60), 250, 34)
        hover = mouse is not None and rr_.collidepoint(mouse)
        screen.blit(art.button(rr_.w, rr_.h, "hover" if hover and reps else ("normal" if reps else "disabled")), rr_.topleft)
        ui.blit_text(screen, "WATCH LAST GAME  (R)", 13, TEXT if reps else DIM, rr_.center, align="center", bold=True)
        self.toggles_replay = (rr_, self.watch_replay) if reps else None
        rows = [
            (f"Speed: {settings.speed_name}", settings.cycle_speed),
            (f"Edge scroll: {'On' if settings.edge_scroll else 'Off'}", lambda: settings.toggle("edge_scroll")),
            (f"Sound: {'On' if settings.sound else 'Off'}", lambda: settings.toggle("sound")),
            (f"Objectives: {'On' if settings.objectives else 'Off'}", lambda: settings.toggle("objectives")),
            (f"Fullscreen: {'On' if settings.fullscreen else 'Off'}", self.app.toggle_fullscreen),
            (f"UI scale: {'Auto' if not settings.ui_scale else f'{settings.ui_scale:g}x'}"
             + (f" ({self.app.ui_scale:g}x)" if not settings.ui_scale else ""),
             lambda: (settings.cycle_ui_scale(), self.app._window_changed())),
        ]
        tw, th, tg = 138, 34, 10
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
        tc = settings.team_count
        picks = [(360, f"Map: {meta['name']}  ({meta['players']}p)", settings.cycle_map),
                 (170, f"Opponents: {n}", settings.cycle_opponents),
                 (170, "Teams: Free-for-all" if tc < 2 else f"Teams: {tc}", settings.cycle_teams)]
        pt = sum(p[0] for p in picks) + tg * (len(picks) - 1)
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
        # Who is with whom — the round-robin deal is otherwise invisible until the game starts.
        ui.blit_text(screen, lineup_text(n, tc), 13, AMBER if tc >= 2 else DIM, (w / 2, py + th + 34),
                     align="center", bold=tc >= 2)
        ty += th + 38
        lines = ["Mine crystal with Engineers, expand, and train an army of Rangers and Siege Tanks.",
                 "Destroy every enemy building to win. Objectives on screen will guide your first minutes."]
        for i, l in enumerate(lines):
            ui.blit_text(screen, l, 14, TEXT, (w / 2, ty + 80 + i * 24), align="center")
        ui.blit_text(screen, "1 / 2 / 3 or Enter to deploy  ·  C campaign  ·  M multiplayer  ·  F11 full screen  ·  Esc quit", 12, DIM, (w / 2, h - 26), align="center")
        if self.campaign_open:
            self._draw_campaign(screen, mouse)
        if self.briefing is not None:
            self._draw_briefing(screen, mouse)
        ui.blit_text(screen, f"v{__version__}", 12, DIM, (w - 18, h - 26), align="right")
