"""Screen-space interface: top bar, minimap, selection info, command card, messages, objectives and overlays.

Uses pygame's native screen coordinates (origin top-left, y down).
"""
import math

import pygame

from . import art, audio, defs, ui
from .defs import (AMBER, BAD, BUILDINGS, COLOR_NAMES, CRYSTAL, DIM, GOOD, KITS, TEAM_COLOR, TEAM_LIGHT, TEXT,
                   UNITS, UNIT_KINDS, UPGRADES, UPGRADE_KINDS, fmt_time, to255)
from .settings import settings

PANEL_H = 192
TOP_H = 42
BTN = 64
GAP = 7
MM_W = 236


class HUD:
    def __init__(self, game):
        self.game = game
        self.messages = []  # [text, color, age]
        self.objective_done = {}
        self.current_buttons = []
        self.button_rects = []
        self.queue_rects = []
        self.upgrade_rect = None
        self.icon_rects = []
        self.top_buttons = []
        self.overlay = None  # callable that returns (title, color, subtitle, lines, rows)
        self.store_open = False
        self.store_buttons = []      # (rect, kit id or None for Close), rebuilt each frame the store is drawn
        self.overlay_buttons = []
        self._hover_text = None
        self._pings = []
        self._press = {}
        self.icon_repairs = 0        # blank command-card icons caught and redrawn (see _draw_card)
        self._mm_fog = None
        self._fog_timer = 0.0
        self._fog_dirty = True
        self.chat_text = None
        self.layout(game.cam.w, game.cam.h)

    @property
    def overlay_visible(self):
        return self.overlay is not None or self.store_open

    # ------------------------------------------------------------ layout

    def layout(self, w, h):
        self.w, self.h = w, h
        self.mm_scale = MM_W / defs.WORLD_W
        mm_h = int(defs.WORLD_H * self.mm_scale)
        self.mm_rect = pygame.Rect(16, h - PANEL_H + (PANEL_H - mm_h) // 2, MM_W, mm_h)
        card_w, card_h = 5 * BTN + 4 * GAP, 2 * BTN + GAP
        self.card_origin = (w - 22 - card_w, h - PANEL_H + (PANEL_H - card_h) // 2)
        self.card_frame = pygame.Rect(self.card_origin[0] - 10, self.card_origin[1] - 10, card_w + 20, card_h + 20)
        self.mm_frame = self.mm_rect.inflate(16, 16)
        ix = self.mm_frame.right + 14
        self.info_frame = pygame.Rect(ix, self.mm_frame.top, self.card_frame.left - 14 - ix, self.mm_frame.height)
        self.info_rect = self.info_frame.inflate(-32, -28)
        terrain = pygame.transform.smoothscale(self.game.ground, self.mm_rect.size)
        for (x, y, *_r) in self.game.obstacles:
            pygame.draw.circle(terrain, (18, 38, 18), self._mm_local(x, y), 2)
        self.mm_terrain = terrain
        self._fog_dirty = True

    def _mm_local(self, x, y):
        return (int(x * self.mm_scale), int(self.mm_rect.height - y * self.mm_scale))

    def _mm_point(self, x, y):
        lx, ly = self._mm_local(x, y)
        return (self.mm_rect.x + lx, self.mm_rect.y + ly)

    def over_hud(self, p):
        return p[1] > self.h - PANEL_H or p[1] < TOP_H

    # ------------------------------------------------------------ events from game

    def selection_changed(self):
        pass  # the HUD is rebuilt every frame

    def fog_changed(self):
        self._fog_dirty = True

    def flash(self, text, color):
        for m in self.messages:
            if m[0] == text:
                m[2] = 0.0
                return
        self.messages.insert(0, [text, color, 0.0])
        del self.messages[4:]

    def ping(self, x, y, color=None, life=2.4):
        self._pings.append([x, y, 0.0, color or BAD, life])

    def set_hover(self, text, color, pos):
        self._hover_text = (text, color, pos) if text and not self.overlay_visible else None

    # ------------------------------------------------------------ update

    def update(self, dt, mouse):
        for m in self.messages:
            m[2] += dt
        self.messages = [m for m in self.messages if m[2] < 4.6]
        for p in self._pings:
            p[2] += dt
        self._pings = [p for p in self._pings if p[2] < p[4]]
        for k in list(self._press):
            self._press[k] -= dt
            if self._press[k] <= 0:
                del self._press[k]
        self._fog_timer -= dt
        if self._fog_dirty and self._fog_timer <= 0:
            self._fog_timer = 0.15
            self._fog_dirty = False
            f = self.game.fog_view
            size = (int(f.cols * f.cell * self.mm_scale), int(f.rows * f.cell * self.mm_scale))
            self._mm_fog = pygame.transform.smoothscale(f.surface, size)
        self.current_buttons = self.game.command_buttons()
        self._update_objectives()

    # ------------------------------------------------------------ clicks

    def handle_click(self, pos, right, queue=False):
        if self.store_open:
            for r, kit_id in self.store_buttons:
                if r.collidepoint(pos):
                    if kit_id is None:
                        self.close_store()
                    elif not right:
                        self.game.buy_kit(kit_id)
                        audio.play("click")
                    return True
            return True
        if self.overlay_visible:
            if not right:
                for r, action in self.overlay_buttons:
                    if r.collidepoint(pos):
                        audio.play("click")
                        action()
                        break
            return True
        g = self.game
        if self.mm_rect.collidepoint(pos):
            wx, wy = self._mm_to_world(pos)
            if right:
                g.smart_command(wx, wy, queue)
            elif g.ping_pending or pygame.key.get_mods() & pygame.KMOD_ALT:
                g.place_ping(wx, wy)
            else:
                g.center_camera(wx, wy)
                g.minimap_dragging = True
            return True
        if not self.over_hud(pos):
            return False
        if right:
            return True
        for r, action in self.top_buttons:
            if r.collidepoint(pos):
                audio.play("click")
                action()
                return True
        for i, r in enumerate(self.button_rects):
            if r.collidepoint(pos):
                self.press_button(i)
                return True
        if len(g.selection) == 1 and g.selection[0].is_building:
            for r, idx in self.queue_rects:
                if r.collidepoint(pos):
                    g.cancel_queue(g.selection[0], idx)
                    return True
            if self.upgrade_rect and self.upgrade_rect[0].collidepoint(pos):
                g.cancel_upgrade(self.upgrade_rect[1])
                return True
        for r, e in self.icon_rects:
            if r.collidepoint(pos):
                # A portrait in a mixed selection: click keeps only that kind, Shift+click drops that kind,
                # Ctrl+click picks out just the one.
                mods = pygame.key.get_mods()
                same = [x for x in g.selection if x.is_building == e.is_building and x.kind == e.kind]
                if mods & pygame.KMOD_CTRL:
                    g.set_selection([e])
                elif mods & pygame.KMOD_SHIFT:
                    g.set_selection([x for x in g.selection if x not in same] or [e])
                else:
                    g.set_selection(same)
                audio.play("click")
                return True
        return True

    def press_button(self, i):
        if i >= len(self.current_buttons):
            return
        b = self.current_buttons[i]
        self._press[i] = 0.12
        if b.enabled:
            audio.play("click")
            b.action()
        else:
            self.flash("Requirements not met", BAD)

    def _mm_to_world(self, pos):
        x = (min(max(pos[0], self.mm_rect.left), self.mm_rect.right) - self.mm_rect.x) / self.mm_scale
        y = (self.mm_rect.bottom - min(max(pos[1], self.mm_rect.top), self.mm_rect.bottom)) / self.mm_scale
        return x, y

    def minimap_drag(self, pos):
        self.game.center_camera(*self._mm_to_world(pos))

    # ------------------------------------------------------------ objectives

    OBJECTIVES = [
        ("Train an Engineer — select the Command Center, press W", lambda s: s.trained_kinds.get("worker", 0) >= 1),
        ("Build a Supply Depot — select an Engineer, press E", lambda s: s.has_built("depot")),
        ("Build a Barracks (B)", lambda s: s.has_built("barracks")),
        ("Train 5 Rangers at the Barracks (R)", lambda s: s.trained_kinds.get("marine", 0) >= 5),
        ("Build a Factory (F)", lambda s: s.has_built("factory")),
        ("Train a Siege Tank (T)", lambda s: s.trained_kinds.get("tank", 0) >= 1),
        ("Train a Sniper at the Barracks (N)", lambda s: s.trained_kinds.get("sniper", 0) >= 1),
        ("Build a Radar Station (D) to watch the map", lambda s: s.has_built("radar")),
        ("Destroy every enemy building", lambda g: False),
    ]

    def _update_objectives(self):
        g = self.game
        if not g.s.can_pause:
            return
        for i, (text, done) in enumerate(self.OBJECTIVES):
            if i not in self.objective_done and done(g.s):
                self.objective_done[i] = g.elapsed
                if settings.objectives:
                    self.flash("Objective complete: " + text.split(" —")[0], GOOD)
                    audio.play("pop")

    def mission_row(self):
        """The mission's own objective, with its clock where it has one."""
        m = getattr(self.game.s, "mission", None)
        if m is None:
            return None
        if m.win == "destroy":
            return f"{m.title}: destroy every enemy building"
        left = max(0, int(m.seconds - self.game.s.mission_progress()))
        verb = "survive" if m.win == "survive" else "hold the gold"
        return f"{m.title}: {verb} — {fmt_time(left)} to go"

    def _objective_rows(self):
        g = self.game
        rows = []
        mr = self.mission_row()
        if mr:
            rows.append((mr, False))
        for i, (text, _done) in enumerate(self.OBJECTIVES):
            t = self.objective_done.get(i)
            if t is not None and g.elapsed - t > 4:
                continue
            rows.append((text, t is not None))
            if len(rows) >= 3:
                break
        return rows

    # ------------------------------------------------------------ drawing

    def draw(self, screen, mouse):
        g = self.game
        w, h = self.w, self.h
        screen.blit(art.panel(w + 4, PANEL_H + 2, 0), (-2, h - PANEL_H))
        for r in (self.mm_frame, self.info_frame, self.card_frame):
            screen.blit(art.panel(r.w, r.h, 8), r.topleft)
        self._draw_minimap(screen)
        self._draw_info(screen)
        self._draw_card(screen, mouse)
        self._draw_top(screen, mouse)
        if not self.overlay_visible:
            if g.s.can_pause:
                if settings.objectives:
                    self._draw_objectives(screen)
            else:
                self._draw_scoreboard(screen)
        if self.chat_text is not None:
            self._draw_chat_input(screen)
        self._draw_messages(screen)
        if not self.overlay_visible:
            self._draw_tooltip(screen, mouse)
            if self._hover_text:
                text, color, pos = self._hover_text
                img = ui.text(text, 12, color, bold=True)
                bw = img.get_width() + 16
                x, y = pos[0] + 18, pos[1] + 14
                screen.blit(art.panel(bw, 22, 6), (x, y))
                screen.blit(img, (x + 8, y + 11 - img.get_height() / 2))
        if self.overlay_visible:
            if self.store_open:
                self._draw_store(screen, mouse)
            else:
                self._draw_overlay(screen, mouse)

    # top bar

    def _top_button(self, screen, mouse, x, width, label, icon, highlight, action):
        r = pygame.Rect(int(x), (TOP_H - 30) // 2, int(width), 30)
        hover = mouse is not None and r.collidepoint(mouse) and not self.overlay_visible
        state = "hover" if hover else ("active" if highlight else "normal")
        screen.blit(art.button(r.w, r.h, state, AMBER if highlight else (0.35, 0.55, 0.75, 1)), r.topleft)
        lx = r.x + 10
        if icon is not None:
            img = art.sprites.get(("topicon", id(icon)), icon, 90, 24 / max(icon.get_size()))
            screen.blit(img, (r.x + 17 - img.get_width() / 2, r.centery - img.get_height() / 2))
            lx = r.x + 32
        ui.blit_text(screen, label, 13, AMBER if highlight else TEXT, (lx, r.centery), bold=True)
        self.top_buttons.append((r, action))
        return r.right + 8

    def _draw_top(self, screen, mouse):
        g = self.game
        w = self.w
        screen.blit(art.panel(w + 4, TOP_H + 2, 0), (-2, -2))
        self.top_buttons = []
        cy = TOP_H // 2
        ci = art.sprites.get("cicon18", art.crystal_icon(), 0, 18 / 40)
        screen.blit(ci, (24 - ci.get_width() / 2, cy - ci.get_height() / 2))
        ui.blit_text(screen, str(int(g.s.resources)), 17, CRYSTAL, (38, cy), bold=True, mono=True)
        si = art.sprites.get("sicon18", art.supply_icon(), 0, 18 / 40)
        screen.blit(si, (128 - si.get_width() / 2, cy - si.get_height() / 2))
        used, cap = g.s.supply_used, g.s.supply_cap
        ui.blit_text(screen, f"{used}/{cap}", 17, BAD if used >= cap else TEXT, (142, cy), bold=True, mono=True)
        idle = len(g.idle_workers())
        army = len(g.army())
        me = g.s.slot
        x = self._top_button(screen, mouse, 220, 96, f"{idle} idle", art.unit("worker", me), idle > 0, g.select_idle_worker)
        x = self._top_button(screen, mouse, x, 104, f"Army {army}", art.unit("marine", me), False, g.select_army)
        x = self._top_button(screen, mouse, x, 90, "Attack (Z)", None, g.ping_pending, g.begin_ping)
        self._top_button(screen, mouse, x, 112, "Satellite (Tab)", None, g.satellite, g.toggle_satellite)
        speed = settings.speed_index != 1 and g.s.can_pause
        clock = fmt_time(g.elapsed) + (f"  ·  {settings.speed_name}" if speed else "") + ("" if g.s.can_pause else "  ·  ONLINE") \
            + ("  ·  REPLAY" if getattr(g.s, "spectating", False) else "")
        ui.blit_text(screen, clock, 16, TEXT, (w / 2, cy), align="center", bold=True, mono=True)
        self._top_button(screen, mouse, w - 14 - 72, 72, "Menu", None, False, g.toggle_pause)
        self._top_button(screen, mouse, w - 14 - 72 - 8 - 64, 64, "Help", None, False, g.toggle_help)
        self._top_button(screen, mouse, w - 14 - 72 - 8 - 64 - 8 - 92, 92, "Armory (Y)", None,
                         len(g.s.kits) < len(KITS) and g.s.resources >= 100, g.toggle_store)

    # minimap

    def _draw_minimap(self, screen):
        g = self.game
        r = self.mm_rect
        screen.blit(self.mm_terrain, r.topleft)
        if self._mm_fog:
            screen.blit(self._mm_fog, (r.x, r.bottom - self._mm_fog.get_height()), area=None)
        screen.set_clip(r)
        s = g.s
        for c in s.crystals:
            if s.fog.is_explored(c.x, c.y):
                p = self._mm_point(c.x, c.y)
                if c.gold:
                    pygame.draw.rect(screen, to255(AMBER), (p[0] - 2, p[1] - 2, 5, 5))
                else:
                    pygame.draw.rect(screen, to255(CRYSTAL), (p[0] - 1, p[1] - 1, 3, 3))
        for t in getattr(s, "towers", ()):
            p = self._mm_point(t.x, t.y)
            col = to255(TEAM_LIGHT[t.owner]) if t.owner is not None else (190, 190, 190)
            pygame.draw.circle(screen, col, p, 4, 0 if t.owner is not None else 1)
        for br in getattr(s, "bridges", ()):
            x0, y0 = self._mm_point(br.rect[0], br.rect[3])
            x1, y1 = self._mm_point(br.rect[2], br.rect[1])
            rect = (x0, y0, max(2, x1 - x0), max(2, y1 - y0))
            pygame.draw.rect(screen, to255(AMBER if br.intact else BAD), rect, 0 if br.intact else 1)
        for b in s.buildings:
            if s.shown(b):
                p = self._mm_point(b.x, b.y)
                sz = max(6, int(b.half * 2 * self.mm_scale))
                pygame.draw.rect(screen, to255(TEAM_COLOR[b.team]), (p[0] - sz // 2, p[1] - sz // 2, sz, sz))
        for u in s.units:
            if s.shown(u):
                p = self._mm_point(u.x, u.y)
                sz = 4 if u.kind == "tank" else 3
                pygame.draw.rect(screen, to255(TEAM_LIGHT[u.team]), (p[0] - 1, p[1] - 1, sz, sz))
        for x, y, age, color, _life in self._pings:
            k = (age % 0.6) / 0.6
            p = self._mm_point(x, y)
            c = tuple(int(ch * (1 - k)) for ch in to255(color))
            pygame.draw.circle(screen, c, p, int(3 + 14 * k), 2)
        v = g.cam.view_rect()
        a = self._mm_point(max(0, v[0]), min(defs.WORLD_H, v[3]))
        b = self._mm_point(min(defs.WORLD_W, v[2]), max(0, v[1]))
        pygame.draw.rect(screen, (255, 255, 255), (a[0], a[1], b[0] - a[0], b[1] - a[1]), 1)
        screen.set_clip(None)

    # selection info

    def _portrait(self, screen, tex, team, size, fit, center, rotate=True):
        bg = art.button(size, size, "active", TEAM_COLOR[team])
        screen.blit(bg, (center[0] - size / 2, center[1] - size / 2))
        k = fit / max(tex.get_size())
        img = art.sprites.get(("portrait", id(tex), fit), tex, 90 if rotate else 0, k)
        screen.blit(img, (center[0] - img.get_width() / 2, center[1] - img.get_height() / 2))

    @staticmethod
    def _bar(screen, x, y, w, frac, color, h=6):
        pygame.draw.rect(screen, (0, 0, 0), (x, y - h / 2, w, h))
        pygame.draw.rect(screen, to255(color), (x, y - h / 2, w * max(0.0, min(1.0, frac)), h))

    @staticmethod
    def _hp_color(f):
        return GOOD if f > 0.6 else AMBER if f > 0.3 else BAD

    def _draw_info(self, screen):
        g = self.game
        self.queue_rects = []
        self.icon_rects = []
        sel = g.selection
        x0, top = self.info_rect.x, self.info_rect.y
        if not sel:
            ui.blit_text(screen, "NO SELECTION", 13, AMBER, (x0, top + 8), bold=True)
            tips = ["Drag to select units · right-click to move, attack or mine",
                    "Shift+right-click queues orders · A attack-move · S stop",
                    "I idle engineer · ` or F2 select army · Space jump to alert",
                    "Wheel to zoom · middle-drag to pan · H opens the field manual"]
            for i, t in enumerate(tips):
                ui.blit_text(screen, t, 13, DIM, (x0, top + 38 + i * 22))
            return
        if len(sel) == 1:
            self._draw_single(screen, sel[0], x0, top)
        else:
            self._draw_multi(screen, sel, x0, top)

    def _tex_for(self, e):
        return art.building(e.kind, e.team) if e.is_building else art.unit(e.kind, e.team)

    def _draw_single(self, screen, e, x0, top):
        ps = 92
        self._portrait(screen, self._tex_for(e), e.team, ps, 80 if e.is_building else 64, (x0 + ps / 2, top + ps / 2),
                       rotate=not e.is_building)
        tx = x0 + ps + 16
        ui.blit_text(screen, e.name.upper(), 18, TEXT, (tx, top + 10), bold=True)
        mine, ally = e.team == self.game.s.slot, self.game.friendly(e)
        owner = "Your forces" if mine else f"{'Allied' if ally else 'Hostile'} · {self.game.s.player_name(e.team)}"
        ui.blit_text(screen, owner, 12, TEAM_COLOR[e.team], (tx, top + 32), bold=True)
        frac = e.hp / e.max_hp
        self._bar(screen, tx, top + 50, 180, frac, self._hp_color(frac), 8)
        ui.blit_text(screen, f"{math.ceil(e.hp)} / {int(e.max_hp)}", 11, TEXT, (tx + 188, top + 50), mono=True)
        if not e.is_building:
            s = e.stats
            stats = f"DMG {int(s.damage)}{'+splash' if s.splash else ''}   RANGE {int(s.range)}   SPEED {int(s.speed)}"
            ui.blit_text(screen, stats, 11, DIM, (tx, top + 72), mono=True)
            status = e.status_text() if mine else ("Allied unit" if ally else "Hostile unit")
            if e.carrying and mine:
                status += f" · carrying {e.carrying}"
            if e.queued and mine:
                status += f" · +{len(e.queued)} queued"
            ui.blit_text(screen, status, 14, TEXT, (x0, top + ps + 20), bold=True)
            return
        if not e.built:
            ui.blit_text(screen, f"Under construction  {int(e.progress * 100)}%", 13, AMBER, (tx, top + 74), bold=True)
            self._bar(screen, x0, top + ps + 18, min(260, self.info_rect.right - x0), e.progress, AMBER, 8)
            return
        if not mine:
            ui.blit_text(screen, e.stats.desc, 13, DIM, (x0, top + ps + 20))
            return
        if e.queue:
            ui.blit_text(screen, f"Training {UNITS[e.queue[0]].name}  {int(e.queue_progress * 100)}%", 12, TEXT, (tx, top + 74), bold=True)
            slot = 44
            for i in range(5):
                r = pygame.Rect(x0 + i * (slot + 6), top + ps + 8, slot, slot)
                if i < len(e.queue):
                    self._portrait(screen, art.unit(e.queue[i], e.team), e.team, slot, 34, r.center)
                    pygame.draw.line(screen, (200, 200, 200), (r.right - 9, r.top + 4), (r.right - 4, r.top + 9), 2)
                    pygame.draw.line(screen, (200, 200, 200), (r.right - 4, r.top + 4), (r.right - 9, r.top + 9), 2)
                    self.queue_rects.append((r, i))
                else:
                    screen.blit(art.button(slot, slot, "disabled"), r.topleft)
            self._bar(screen, x0, top + ps + 8 + slot + 6, slot, e.queue_progress, CRYSTAL, 4)
        else:
            line = e.stats.desc + ("  Right-click the map to set a rally point." if e.stats.produces else "")
            for i, l in enumerate(ui.wrap(line, 13, max(200, self.info_rect.right - tx))):
                ui.blit_text(screen, l, 13, DIM, (tx, top + 74 + i * 18))
        # Upgrades: what is installed, and what is being researched (click the bar to cancel).
        y = top + ps + 8 + (50 if e.queue else 0)
        if e.upgrades:
            names = " · ".join(UPGRADES[k].short for k in UPGRADE_KINDS if k in e.upgrades)
            ui.blit_text(screen, names, 12, GOOD, (x0, y + 40 if not e.queue else y + 4), bold=True)
        if e.upgrading:
            yy = y + 58 if not e.queue else y + 20
            ui.blit_text(screen, f"Researching {UPGRADES[e.upgrading].name}  {int(e.upgrade_progress * 100)}%",
                         12, AMBER, (x0, yy), bold=True)
            w = min(260, self.info_rect.right - x0)
            self._bar(screen, x0, yy + 14, w, e.upgrade_progress, AMBER, 5)
            self.upgrade_rect = (pygame.Rect(x0, yy - 8, w, 28), e)

    def _draw_multi(self, screen, sel, x0, top):
        counts = {}
        for e in sel:
            counts[e.name] = counts.get(e.name, 0) + 1
        ui.blit_text(screen, f"{len(sel)} SELECTED", 13, AMBER, (x0, top + 8), bold=True)
        ui.blit_text(screen, "  ·  ".join(f"{n} {k}" for k, n in sorted(counts.items())), 13, TEXT, (x0 + 110, top + 8))
        s, gp = 40, 5
        cols = max(1, (self.info_rect.w + gp) // (s + gp))
        for i, e in enumerate(sel[:cols * 3]):
            c, r = i % cols, i // cols
            rect = pygame.Rect(x0 + c * (s + gp), top + 26 + r * (s + gp + 3), s, s)
            self._portrait(screen, self._tex_for(e), e.team, s, 36 if e.is_building else 30, rect.center, rotate=not e.is_building)
            f = e.hp / e.max_hp
            self._bar(screen, rect.x + 3, rect.bottom - 5, s - 6, f, self._hp_color(f), 3)
            self.icon_rects.append((rect, e))

    # command card

    def _icon_source(self, b):
        """The base texture a command button's icon is cut from."""
        g = self.game
        kind = b.icon[0]
        if kind == "attack":
            return art.icon_attack()
        if kind == "stop":
            return art.icon_stop()
        if kind == "siege":
            return art.icon_siege(b.icon[1])
        if kind == "upgrade":
            return art.icon_upgrade(b.icon[1])
        if kind == "unit":
            return art.unit(b.icon[1], g.s.slot)
        return art.building(b.icon[1], g.s.slot)

    def _draw_card(self, screen, mouse):
        g = self.game
        self.button_rects = []
        ox, oy = self.card_origin
        for i in range(10):
            col, row = i % 5, i // 5
            r = pygame.Rect(ox + col * (BTN + GAP), oy + row * (BTN + GAP), BTN, BTN)
            if i >= len(self.current_buttons):
                img = art.button(BTN, BTN, "disabled").copy()
                img.set_alpha(128)
                screen.blit(img, r.topleft)
                continue
            self.button_rects.append(r)
            b = self.current_buttons[i]
            hover = mouse is not None and r.collidepoint(mouse) and not self.overlay_visible
            state = "disabled" if not b.enabled else ("hover" if hover else "normal")
            pressed = i in self._press
            if pressed:
                r = r.inflate(-6, -6)
            screen.blit(art.button(r.w, r.h, state), r.topleft)
            tex = self._icon_source(b)
            kind = b.icon[0]
            fit = 30 if kind in ("attack", "stop") else 34 if kind in ("siege", "upgrade") else \
                (40 if kind == "unit" and b.icon[1] == "tank" else 30) if kind == "unit" else 38
            rot = 90 if kind == "unit" else 0
            if not b.enabled:
                # Locked, not missing: keep the art legible in greyscale so the button still says what it
                # builds. (At the old 35% opacity it vanished into the dark disabled button.)
                tex = art.greyscale(tex)
            img = art.sprites.get(("icon", b.icon, fit, b.enabled), tex, rot, fit / max(tex.get_size()),
                                  fade=255 if b.enabled else 160)
            if img.get_bounding_rect().width == 0:
                # A blank icon: whatever produced it (a stale cached surface after a display change, a failed
                # conversion), throw the cached art away and draw it fresh — and remember it for the F12 note.
                art.forget_icon(b.icon, tex)
                tex = art.greyscale(self._icon_source(b)) if not b.enabled else self._icon_source(b)
                img = art.sprites.get(("icon", b.icon, fit, b.enabled), tex, rot, fit / max(tex.get_size()),
                                      fade=255 if b.enabled else 160)
                self.icon_repairs += 1
            # A dark plate behind the picture, so the art reads against the button face in every state.
            pw, ph = max(img.get_width(), img.get_height()) + 10, max(img.get_width(), img.get_height()) + 10
            plate = art.icon_plate(pw, ph)
            screen.blit(plate, (r.centerx - pw / 2, r.centery - 5 - ph / 2))
            screen.blit(img, (r.centerx - img.get_width() / 2, r.centery - 5 - img.get_height() / 2))
            pygame.draw.rect(screen, (0, 0, 0), (r.x + 3, r.y + 3, 16, 16))
            ui.blit_text(screen, b.hotkey, 11, AMBER, (r.x + 11, r.y + 11), align="center", bold=True)
            # The title shrinks until it fits the button, so a long name never runs into its neighbour.
            size = 10
            while size > 7 and ui.font(size, True).size(b.title)[0] > BTN - 6:
                size -= 1
            ui.blit_text(screen, b.title, size, TEXT if b.enabled else DIM, (r.centerx, r.bottom - 10), align="center", bold=True)
            if b.cost is not None:
                ok = g.s.resources >= b.cost
                ui.blit_text(screen, str(b.cost), 10, CRYSTAL if ok else BAD, (r.right - 5, r.y + 11), align="right", mono=True)

    def _draw_tooltip(self, screen, mouse):
        if mouse is None:
            return
        for i, r in enumerate(self.button_rects):
            if r.collidepoint(mouse) and i < len(self.current_buttons):
                b = self.current_buttons[i]
                body = ui.wrap(b.tip, 12, 270)
                title = f"{b.title}   [{b.hotkey}]"
                tw = ui.font(14, True).size(title)[0]
                w = max(tw + 70, max(ui.font(12).size(l)[0] for l in body)) + 24
                h = 24 + 18 + len(body) * 17 + 6
                x = min(self.card_origin[0], self.w - w - 12)
                y = self.h - PANEL_H - 10 - h
                screen.blit(art.panel(w, h, 8, AMBER), (x, y))
                ui.blit_text(screen, title, 14, TEXT, (x + 12, y + 18), bold=True)
                if b.cost is not None:
                    r = ui.blit_text(screen, str(b.cost), 13, CRYSTAL, (x + w - 12, y + 18), align="right", mono=True)
                    ci = art.sprites.get("cicon14", art.crystal_icon(), 0, 14 / 40)
                    screen.blit(ci, (r.x - 4 - ci.get_width(), y + 18 - ci.get_height() / 2))
                for j, l in enumerate(body):
                    ui.blit_text(screen, l, 12, DIM, (x + 12, y + 42 + j * 17))
                return

    # messages & objectives

    def _draw_messages(self, screen):
        for i, (text, color, age) in enumerate(self.messages):
            a = 1.0 if age < 4 else max(0.0, 1 - (age - 4) / 0.6)
            if a <= 0:
                continue
            img = ui.text(text, 16, color, bold=True)
            sh = ui.text(text, 16, (0, 0, 0), bold=True)
            x = self.w / 2 - img.get_width() / 2
            y = TOP_H + 22 + i * 24
            if a < 1:
                img = img.copy()
                sh = sh.copy()
                img.set_alpha(int(255 * a))
                sh.set_alpha(int(255 * a))
            screen.blit(sh, (x + 1, y + 1.5))
            screen.blit(img, (x, y))

    def _draw_objectives(self, screen):
        rows = self._objective_rows()
        if not rows:
            return
        w, rh = 360, 22
        h = 30 + len(rows) * rh
        x, y = 14, TOP_H + 12
        screen.blit(art.panel(w, h, 8, AMBER), (x, y))
        ui.blit_text(screen, "OBJECTIVES", 11, AMBER, (x + 12, y + 14), bold=True)
        ui.blit_text(screen, "O to hide", 10, DIM, (x + w - 12, y + 14), align="right")
        for i, (text, done) in enumerate(rows):
            yy = y + 34 + i * rh
            if done:
                pygame.draw.lines(screen, to255(GOOD), False, [(x + 13, yy), (x + 17, yy + 4), (x + 24, yy - 5)], 2)
            else:
                pygame.draw.circle(screen, to255(DIM), (x + 18, yy), 5, 1)
            ui.blit_text(screen, text, 12, GOOD if done else TEXT, (x + 30, yy))

    def _draw_scoreboard(self, screen):
        g = self.game
        players = sorted(g.s.players.values(), key=lambda p: (p.team, p.slot))
        w, rh = 250, 22
        h = 30 + len(players) * rh
        x, y = 14, TOP_H + 12
        screen.blit(art.panel(w, h, 8), (x, y))
        ui.blit_text(screen, "PLAYERS", 11, AMBER, (x + 12, y + 14), bold=True)
        ui.blit_text(screen, "Enter to chat", 10, DIM, (x + w - 12, y + 14), align="right")
        for i, p in enumerate(players):
            yy = y + 34 + i * rh
            pygame.draw.circle(screen, to255(TEAM_COLOR[p.slot]), (x + 18, yy), 5)
            label = p.name + (" (you)" if p.slot == g.s.slot else "") + (" · AI" if p.is_ai else "")
            col = TEXT if p.alive else DIM
            ui.blit_text(screen, label, 12, col, (x + 30, yy), bold=p.slot == g.s.slot)
            ui.blit_text(screen, f"Team {p.team}" if p.alive else "Out", 11, DIM if p.alive else BAD, (x + w - 12, yy), align="right")

    def _draw_chat_input(self, screen):
        w = min(520, self.w - 40)
        x, y = (self.w - w) // 2, self.h - PANEL_H - 50
        screen.blit(art.panel(w, 32, 8, AMBER), (x, y))
        caret = "|" if (pygame.time.get_ticks() // 500) % 2 == 0 else " "
        ui.blit_text(screen, "Say: " + self.chat_text + caret, 14, TEXT, (x + 12, y + 16))

    def handle_text_event(self, e):
        """Consumes keyboard input while the chat line is open. Returns True if handled."""
        if self.chat_text is None:
            return False
        if e.type == pygame.TEXTINPUT:
            self.chat_text = (self.chat_text + e.text)[:120]
            return True
        if e.type == pygame.KEYDOWN:
            if e.key in (pygame.K_RETURN, pygame.K_KP_ENTER):
                text = self.chat_text.strip()
                self.chat_text = None
                if text and hasattr(self.game.s, "chat"):
                    self.game.s.chat(text)
            elif e.key == pygame.K_ESCAPE:
                self.chat_text = None
            elif e.key == pygame.K_BACKSPACE:
                self.chat_text = self.chat_text[:-1]
            return True
        return e.type == pygame.KEYUP

    # overlays

    def clear_overlay(self):
        self.overlay = None
        self.store_open = False

    # the Armory

    def open_store(self):
        self.store_open = True
        audio.play("click")

    def close_store(self):
        self.store_open = False

    def _draw_store(self, screen, mouse):
        g = self.game
        owned = g.s.kits
        dim = pygame.Surface((self.w, self.h), pygame.SRCALPHA)
        dim.fill((0, 0, 0, 150))
        screen.blit(dim, (0, 0))
        kinds = UNIT_KINDS
        row_h, card_w, card_h, gap = 106, 196, 88, 10
        box_w = min(self.w - 40, 150 + 3 * (card_w + gap) + 40)
        box_h = 132 + len(kinds) * row_h + 70
        bx, by = (self.w - box_w) // 2, max(10, (self.h - box_h) // 2)
        glow = art.tinted_glow((int(box_w * 1.3), int(box_h * 1.5)), to255(AMBER), 1)
        screen.blit(glow, (self.w / 2 - box_w * 0.65, by + box_h / 2 - box_h * 0.75), special_flags=pygame.BLEND_ADD)
        screen.blit(art.panel(box_w, box_h, 16, AMBER), (bx, by))
        ui.blit_text(screen, "ARMORY", 42, AMBER, (self.w / 2, by + 48), align="center", bold=True)
        ui.blit_text(screen, "Kit is bought once and worn by every unit of that type for the rest of the match.",
                     14, TEXT, (self.w / 2, by + 86), align="center", bold=True)
        ci = art.sprites.get("cicon14", art.crystal_icon(), 0, 14 / 40)
        bal = ui.blit_text(screen, str(int(g.s.resources)), 16, CRYSTAL, (bx + box_w - 24, by + 48), align="right", bold=True, mono=True)
        screen.blit(ci, (bal.x - 6 - ci.get_width(), by + 48 - ci.get_height() / 2))
        self.store_buttons = []
        y = by + 118
        for kind in kinds:
            tex = art.unit(kind, g.s.slot)
            self._portrait(screen, tex, g.s.slot, 56, 40, (bx + 48, y + row_h / 2 - 6))
            ui.blit_text(screen, UNITS[kind].name, 13, TEXT, (bx + 48, y + row_h - 14), align="center", bold=True)
            x = bx + 110
            for kit in [k for k in KITS if k.unit == kind]:
                r = pygame.Rect(int(x), int(y + 4), card_w, card_h)
                have = kit.id in owned
                afford = g.s.resources >= kit.cost
                hover = mouse is not None and r.collidepoint(mouse)
                state = "active" if have else ("hover" if hover and afford else ("normal" if afford else "disabled"))
                screen.blit(art.button(card_w, card_h, state, GOOD if have else AMBER), r.topleft)
                ui.blit_text(screen, kit.name, 14, TEXT, (r.x + 12, r.y + 18), bold=True)
                if have:
                    ui.blit_text(screen, "ISSUED", 11, GOOD, (r.right - 12, r.y + 18), align="right", bold=True)
                else:
                    cr = ui.blit_text(screen, str(kit.cost), 13, CRYSTAL if afford else BAD, (r.right - 12, r.y + 18),
                                      align="right", mono=True)
                    screen.blit(ci, (cr.x - 4 - ci.get_width(), r.y + 18 - ci.get_height() / 2))
                for i, line in enumerate(ui.wrap(kit.desc, 11, card_w - 24)[:3]):
                    ui.blit_text(screen, line, 11, DIM if not have else TEXT, (r.x + 12, r.y + 40 + i * 15))
                if not have:
                    self.store_buttons.append((r, kit.id))
                x += card_w + gap
            y += row_h
        cr = pygame.Rect(int(self.w / 2 - 110), int(by + box_h - 58), 220, 42)
        hover = mouse is not None and cr.collidepoint(mouse)
        screen.blit(art.button(cr.w, cr.h, "hover" if hover else "normal"), cr.topleft)
        ui.blit_text(screen, "Close  (Y)", 15, TEXT, cr.center, align="center", bold=True)
        self.store_buttons.append((cr, None))
        self.overlay_buttons = []

    def _settings_rows(self):
        def refresh(fn):
            return lambda: fn()
        return [
            [(f"Speed: {settings.speed_name}", settings.cycle_speed),
             (f"Edge scroll: {'On' if settings.edge_scroll else 'Off'}", lambda: settings.toggle("edge_scroll"))],
            [(f"Sound: {'On' if settings.sound else 'Off'}", lambda: settings.toggle("sound")),
             (f"Music: {'On' if settings.music else 'Off'}", lambda: settings.toggle("music"))],
            [(f"Objectives: {'On' if settings.objectives else 'Off'}", lambda: settings.toggle("objectives"))],
            [(f"Fullscreen: {'On' if settings.fullscreen else 'Off'}", self.game.app.toggle_fullscreen),
             (f"Health bars: {'Always' if settings.bars_always else 'When hurt'}", lambda: settings.toggle("bars_always"))],
        ]

    def show_pause(self):
        g = self.game
        if g.s.can_pause:
            self.overlay = lambda: ("PAUSED", TEXT, "Settings are saved automatically.  F5 quick-saves, F9 loads it.", [],
                                    self._settings_rows()
                                    + [[("Save Game", lambda: (g.save_game("save", "Saved game"), g.toggle_pause())),
                                        ("Load Game", lambda: g.load_game("save"))]]
                                    + [[("Resume", g.toggle_pause), ("Main Menu", g.to_menu)]])
        else:
            rows = self._settings_rows()
            rows[0] = [rows[0][1]]  # game speed is controlled by the server
            self.overlay = lambda: ("GAME MENU", TEXT, "The game keeps running while this menu is open.", [],
                                    rows + [[("Resume", g.toggle_pause), ("Leave Game", g.to_menu)]])

    def show_help(self):
        g = self.game
        lines = [
            "Left-click / drag — select · Shift adds · Double-click selects all of a type",
            "Right-click — move · attack · mine crystal · set rally point (buildings)",
            "Shift + right-click — queue orders    A then click — attack-move    S — stop",
            "Engineer: C Command Center · E Supply Depot · B Barracks · F Factory · T Turret",
            "Command Center: W Engineer · Barracks: R Ranger · Factory: T Siege Tank",
            "Ctrl+1–9 — assign group · 1–9 — recall (double-tap to jump there)",
            "I — next idle engineer · ` or F2 — select army · Space — jump to alert",
            "Z or Alt+click — attack point, Shift+Z — help point: your whole side sees it, computer allies send troops",
            "Tab — satellite view: the whole map on screen; Tab, Space or a minimap click brings you back",
            "Click a portrait — keep only that kind · Shift+click — drop that kind · Ctrl+click — just the one",
            "Arrows / screen edge / middle-drag — pan · Wheel or +/− — zoom",
            "Y — the Armory: buy kit for your troops · G — siege / unsiege tanks",
            "F5 — quick save · F9 — quick load · the game also autosaves every five minutes",
            "P or Esc — menu & settings · O — objectives · F11 — fullscreen"
            + ("" if g.s.can_pause else " · Enter — chat"),
        ]
        subtitle = "Destroy every enemy building to win." if g.s.can_pause else \
            "Destroy every building of every enemy team. The game keeps running while this is open."
        self.overlay = lambda: ("FIELD MANUAL", AMBER, subtitle, lines, [[("Close", g.toggle_help)]])

    def _stats_lines(self):
        g = self.game
        stats = g.s.stats()
        lines = [f"Mission time  {fmt_time(g.elapsed)}   ·   {g.s.map.get('name', '')}   ·   Difficulty  {g.difficulty.name}"]
        for slot, st in sorted(stats.items(), key=lambda kv: (kv[1]["team"], kv[0])):
            you = " (you)" if slot == g.s.slot else ""
            lines.append(f"{st['name']}{you}  ·  Team {st['team']}  ·  trained {st['trained']}  ·  lost {st['lost']}"
                         f"  ·  mined {st['mined']}")
        return lines

    def show_end(self, won):
        g = self.game
        lines = self._stats_lines()
        mission = getattr(g.s, "mission", None)
        if g.s.can_pause:
            lines.append("Enter — play again · Esc — main menu")
            rows = [[("Play Again", g.restart), ("Main Menu", g.to_menu)]]
            if mission and won:
                from .defs import CAMPAIGN
                i = [m.id for m in CAMPAIGN].index(mission.id)
                if i + 1 < len(CAMPAIGN):
                    rows = [[("Next Mission", g.next_mission), ("Play Again", g.restart), ("Main Menu", g.to_menu)]]
        else:
            lines.append("Enter — back to lobby · Esc — main menu")
            rows = [[("Back to Lobby", g.back_to_lobby), ("Main Menu", g.to_menu)]]
        if mission:
            self.overlay = lambda: ("MISSION COMPLETE" if won else "MISSION FAILED", GOOD if won else BAD,
                                    f"{mission.title} — " + ("well fought." if won else "the field is lost."), lines, rows)
        else:
            self.overlay = lambda: ("VICTORY" if won else "DEFEAT", GOOD if won else BAD,
                                    ("Your team is victorious." if not g.s.can_pause else "The enemy base has fallen.") if won
                                    else "Your forces have been defeated.", lines, rows)

    def show_eliminated(self):
        g = self.game
        self.overlay = lambda: ("ELIMINATED", BAD, "All your buildings were destroyed. The match continues.",
                                ["You can keep watching with your team's vision, or leave the game."],
                                [[("Keep Watching", self.clear_overlay), ("Leave Game", g.to_menu)]])

    def show_disconnected(self, reason):
        g = self.game
        self.overlay = lambda: ("DISCONNECTED", BAD, "The connection to the server was lost.", [str(reason)[:80]],
                                [[("Main Menu", g.to_menu)]])

    def _draw_overlay(self, screen, mouse):
        title, color, subtitle, lines, rows = self.overlay()
        dim = pygame.Surface((self.w, self.h), pygame.SRCALPHA)
        dim.fill((0, 0, 0, 150))
        screen.blit(dim, (0, 0))
        line_h, bh, row_gap, bw, bgap = 24, 42, 12, 220, 16
        box_w = min(self.w - 40, 760)
        box_h = 104 + len(lines) * line_h + (30 if subtitle else 0) + len(rows) * (bh + row_gap) + 16
        bx, by = (self.w - box_w) // 2, (self.h - box_h) // 2
        glow = art.tinted_glow((int(box_w * 1.3), int(box_h * 1.6)), to255(color), 1)
        screen.blit(glow, (self.w / 2 - box_w * 0.65, self.h / 2 - box_h * 0.8), special_flags=pygame.BLEND_ADD)
        screen.blit(art.panel(box_w, box_h, 16, color), (bx, by))
        y = by + 52
        ui.blit_text(screen, title, 42, color, (self.w / 2, y), align="center", bold=True)
        y += 40
        if subtitle:
            ui.blit_text(screen, subtitle, 16, TEXT, (self.w / 2, y), align="center", bold=True)
            y += 32
        for l in lines:
            ui.blit_text(screen, l, 14, DIM, (self.w / 2, y), align="center")
            y += line_h
        y += 8
        self.overlay_buttons = []
        for row in rows:
            total = len(row) * bw + (len(row) - 1) * bgap
            x = (self.w - total) // 2
            for label, action in row:
                r = pygame.Rect(x, y, bw, bh)
                hover = mouse is not None and r.collidepoint(mouse)
                screen.blit(art.button(bw, bh, "hover" if hover else "normal"), r.topleft)
                ui.blit_text(screen, label, 15, TEXT, r.center, align="center", bold=True)
                self.overlay_buttons.append((r, action))
                x += bw + bgap
            y += bh + row_gap
