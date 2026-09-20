"""Multiplayer screens: host/join/LAN browser, and the pre-game lobby."""
import getpass
import math

import pygame

from . import art, audio, mapgen, ui
from .defs import AMBER, BAD, COLOR_NAMES, DIFFICULTIES, DIM, GOOD, MAX_PLAYERS, TEAM_COLOR, TEXT, to255
from .net import GAME_PORT, PROTOCOL_VERSION, Connection, LanBrowser, Server, local_ip
from .settings import settings


def _default_name():
    try:
        return (settings.player_name or getpass.getuser() or "Commander")[:20]
    except Exception:  # noqa: BLE001
        return "Commander"


class _Field:
    def __init__(self, text, placeholder, limit=40):
        self.text, self.placeholder, self.limit = text, placeholder, limit
        self.rect = pygame.Rect(0, 0, 0, 0)

    def draw(self, screen, focused, label):
        r = self.rect
        screen.blit(art.button(r.w, r.h, "hover" if focused else "normal"), r.topleft)
        ui.blit_text(screen, label, 11, DIM, (r.x, r.y - 12), bold=True)
        caret = "|" if focused and (pygame.time.get_ticks() // 500) % 2 == 0 else ""
        shown = self.text or ("" if focused else self.placeholder)
        ui.blit_text(screen, shown + caret, 15, TEXT if self.text else DIM, (r.x + 12, r.centery))


class MultiplayerScene:
    def __init__(self, app, message=None):
        self.app = app
        self.name = _Field(_default_name(), "Your name", 20)
        self.addr = _Field(settings.last_address or "", "IP address, e.g. 192.168.1.20", 60)
        self.focus = None
        self.status = message or ""
        self.status_color = BAD if message else DIM
        self.browser = LanBrowser()
        self.buttons = []
        self.games = []
        self.resize(*app.screen.get_size())

    def resize(self, w, h):
        self.w, self.h = w, h

    def _close(self):
        self.browser.close()

    def _connect(self, host, port, hosting=False):
        name = self.name.text.strip() or "Commander"
        settings.set("player_name", name)
        try:
            conn = Connection(host, port)
        except OSError as e:
            self.status, self.status_color = f"Could not connect to {host}:{port} — {e}", BAD
            return
        conn.send({"t": "hello", "name": name, "version": PROTOCOL_VERSION, "client": "linux"})
        self._close()
        self.app.set_scene(LobbyScene(self.app, conn, hosting=hosting))

    def host(self):
        try:
            if self.app.server is None:
                self.app.server = Server(name=f"{self.name.text.strip() or 'Commander'}'s game", port=GAME_PORT,
                                         log=lambda *_: None).start()
        except OSError as e:
            self.status, self.status_color = f"Could not start a server on port {GAME_PORT}: {e}", BAD
            return
        self._connect("127.0.0.1", GAME_PORT, hosting=True)

    def join(self, text=None):
        text = (text or self.addr.text).strip()
        if not text:
            self.status, self.status_color = "Enter the host's IP address, or pick a game from the list", BAD
            return
        host, _, port = text.partition(":")
        settings.set("last_address", text)
        self._connect(host, int(port) if port.isdigit() else GAME_PORT)

    def back(self):
        from .menu import MenuScene
        self._close()
        self.app.set_scene(MenuScene(self.app))

    def handle_event(self, e):
        if e.type == pygame.MOUSEBUTTONDOWN and e.button == 1:
            self.focus = None
            for f in (self.name, self.addr):
                if f.rect.collidepoint(e.pos):
                    self.focus = f
            for r, action in self.buttons:
                if r.collidepoint(e.pos):
                    audio.play("click")
                    action()
                    return
        elif e.type == pygame.TEXTINPUT and self.focus:
            self.focus.text = (self.focus.text + e.text)[:self.focus.limit]
        elif e.type == pygame.KEYDOWN:
            if e.key == pygame.K_ESCAPE:
                self.back()
            elif e.key == pygame.K_BACKSPACE and self.focus:
                self.focus.text = self.focus.text[:-1]
            elif e.key in (pygame.K_RETURN, pygame.K_KP_ENTER):
                if self.focus is self.addr:
                    self.join()
                else:
                    self.focus = self.addr
            elif e.key == pygame.K_TAB:
                self.focus = self.addr if self.focus is self.name else self.name

    def update(self, dt, mouse):
        self.games = self.browser.list()

    def _button(self, screen, mouse, rect, label, action, accent=False):
        hover = mouse is not None and rect.collidepoint(mouse)
        state = "hover" if hover else ("active" if accent else "normal")
        screen.blit(art.button(rect.w, rect.h, state, AMBER if accent else (0.35, 0.55, 0.75, 1)), rect.topleft)
        ui.blit_text(screen, label, 15, TEXT, rect.center, align="center", bold=True)
        self.buttons.append((rect, action))

    def draw(self, screen, mouse):
        w, h = self.w, self.h
        _backdrop(screen, w, h)
        self.buttons = []
        ui.blit_text(screen, "MULTIPLAYER", 44, TEXT, (w / 2, 80), align="center", bold=True)
        ui.blit_text(screen, "Up to 4 players · free-for-all or teams · Linux and Mac clients can play together",
                     14, DIM, (w / 2, 122), align="center")
        col_w = 460
        x = w / 2 - col_w - 20
        y = 190
        screen.blit(art.panel(col_w, 380, 12), (x, y - 20))
        self.name.rect = pygame.Rect(x + 24, y + 30, col_w - 48, 40)
        self.name.draw(screen, self.focus is self.name, "YOUR NAME")
        ui.blit_text(screen, "HOST A GAME", 13, AMBER, (x + 24, y + 104), bold=True)
        ui.blit_text(screen, f"Others on your network can join at {local_ip()}:{GAME_PORT}", 12, DIM, (x + 24, y + 126))
        self._button(screen, mouse, pygame.Rect(x + 24, y + 144, col_w - 48, 44), "Host Game", self.host, accent=True)
        self.addr.rect = pygame.Rect(x + 24, y + 238, col_w - 48, 40)
        self.addr.draw(screen, self.focus is self.addr, "JOIN BY ADDRESS")
        self._button(screen, mouse, pygame.Rect(x + 24, y + 290, col_w - 48, 44), "Join", self.join)

        x2 = w / 2 + 20
        screen.blit(art.panel(col_w, 380, 12), (x2, y - 20))
        ui.blit_text(screen, "GAMES ON YOUR NETWORK", 13, AMBER, (x2 + 24, y + 8), bold=True)
        if not self.browser.running:
            ui.blit_text(screen, "LAN discovery unavailable (port in use?)", 13, BAD, (x2 + 24, y + 44))
        elif not self.games:
            dots = "." * (1 + (pygame.time.get_ticks() // 400) % 3)
            ui.blit_text(screen, "Searching" + dots, 14, DIM, (x2 + 24, y + 44))
            ui.blit_text(screen, "Games hosted on this network appear here automatically.", 12, DIM, (x2 + 24, y + 70))
        for i, g in enumerate(self.games[:6]):
            r = pygame.Rect(x2 + 24, y + 30 + i * 52, col_w - 48, 44)
            joinable = g.get("state") == "lobby" and g.get("open", 0) > 0
            label = f"{g['name']}"
            sub = f"{g['ip']}:{g['port']} · {g.get('players', 0)} player(s) · " + (
                "open" if joinable else ("in progress" if g.get("state") != "lobby" else "full"))
            hover = mouse is not None and r.collidepoint(mouse)
            screen.blit(art.button(r.w, r.h, "hover" if hover and joinable else ("normal" if joinable else "disabled")), r.topleft)
            ui.blit_text(screen, label, 14, TEXT if joinable else DIM, (r.x + 14, r.y + 14), bold=True)
            ui.blit_text(screen, sub, 11, DIM, (r.x + 14, r.y + 32))
            if joinable:
                self.buttons.append((r, lambda g=g: self.join(f"{g['ip']}:{g['port']}")))
        self._button(screen, mouse, pygame.Rect(w / 2 - 100, y + 400, 200, 42), "Back", self.back)
        if self.status:
            ui.blit_text(screen, self.status, 14, self.status_color, (w / 2, y + 470), align="center", bold=True)
        ui.blit_text(screen, "Fedora: open the ports with  sudo firewall-cmd --add-port=47777/tcp --add-port=47778/udp",
                     12, DIM, (w / 2, h - 26), align="center")


class LobbyScene:
    def __init__(self, app, conn, hosting=False, slot=None, initial=None):
        self.app = app
        self.conn = conn
        self.hosting = hosting
        self.slot = slot
        self.is_host = hosting
        self.state = None
        self.error = ""
        self.chat_log = []
        self.chat_text = None
        self.buttons = []
        self.ready = False
        if initial:
            self._on_lobby(initial)
        self.resize(*app.screen.get_size())

    def resize(self, w, h):
        self.w, self.h = w, h

    def _on_lobby(self, m):
        self.state = m
        hs = m.get("host_slot")
        self.is_host = self.slot is not None and hs == self.slot
        if self.slot is not None:
            me = m["slots"][self.slot]
            self.ready = me.get("ready", False)

    def leave(self):
        from .menu import MenuScene
        self.conn.close()
        if self.app.server is not None and self.hosting:
            self.app.server.stop()
            self.app.server = None
        self.app.set_scene(MultiplayerScene(self.app))

    def update(self, dt, mouse):
        for m in self.conn.messages():
            t = m.get("t")
            if t == "welcome":
                self.slot = m["slot"]
                self.is_host = m.get("host", False)
            elif t == "lobby":
                self._on_lobby(m)
            elif t == "chat":
                self.chat_log.append((m.get("slot", -1), m.get("name", "?"), m.get("text", "")))
                self.chat_log = self.chat_log[-6:]
                audio.play("pop")
            elif t == "error":
                self.error = m.get("text", "Error")
            elif t == "start":
                from .game import GameScene
                from .session import NetSession
                audio.play("click")
                self.app.set_scene(GameScene(self.app, NetSession(self.conn, m)))
                return
            elif t == "disconnected":
                if self.app.server is not None and self.hosting:
                    self.app.server.stop()
                    self.app.server = None
                self.app.set_scene(MultiplayerScene(self.app, message=f"Disconnected: {m.get('text', '')}"))
                return

    # -- actions

    def _send(self, msg):
        self.conn.send(msg)

    def cycle_kind(self, i):
        order = ["open", "ai", "closed"]
        cur = self.state["slots"][i]["kind"]
        self._send({"t": "slot", "slot": i, "kind": order[(order.index(cur) + 1) % 3] if cur in order else "open"})

    def cycle_team(self, i):
        self._send({"t": "slot", "slot": i, "team": self.state["slots"][i]["team"] % MAX_PLAYERS + 1})

    @staticmethod
    def _map_label(st):
        name = st.get("map_name") or "Auto (by player count)"
        return name if st.get("map", "auto") == "auto" else f"{name}  ({st.get('map_players', '?')} players)"

    def cycle_map(self):
        ids = ["auto"] + [m["id"] for m in mapgen.CATALOG]
        cur = (self.state or {}).get("map", "auto")
        self._send({"t": "map", "id": ids[(ids.index(cur) + 1) % len(ids) if cur in ids else 0]})

    def toggle_ready(self):
        self._send({"t": "ready", "ready": not self.ready})

    def start(self):
        self.error = ""
        self._send({"t": "start"})

    def handle_event(self, e):
        if self.chat_text is not None:
            if e.type == pygame.TEXTINPUT:
                self.chat_text = (self.chat_text + e.text)[:120]
            elif e.type == pygame.KEYDOWN:
                if e.key in (pygame.K_RETURN, pygame.K_KP_ENTER):
                    if self.chat_text.strip():
                        self._send({"t": "chat", "text": self.chat_text.strip()})
                    self.chat_text = None
                elif e.key == pygame.K_ESCAPE:
                    self.chat_text = None
                elif e.key == pygame.K_BACKSPACE:
                    self.chat_text = self.chat_text[:-1]
            return
        if e.type == pygame.MOUSEBUTTONDOWN and e.button == 1:
            for r, action in self.buttons:
                if r.collidepoint(e.pos):
                    audio.play("click")
                    action()
                    return
        elif e.type == pygame.KEYDOWN:
            if e.key == pygame.K_ESCAPE:
                self.leave()
            elif e.key in (pygame.K_RETURN, pygame.K_KP_ENTER):
                self.chat_text = ""

    def _button(self, screen, mouse, rect, label, action, enabled=True, accent=False, size=14):
        hover = enabled and mouse is not None and rect.collidepoint(mouse)
        state = "disabled" if not enabled else ("hover" if hover else ("active" if accent else "normal"))
        screen.blit(art.button(rect.w, rect.h, state, AMBER if accent else (0.35, 0.55, 0.75, 1)), rect.topleft)
        ui.blit_text(screen, label, size, TEXT if enabled else DIM, rect.center, align="center", bold=True)
        if enabled:
            self.buttons.append((rect, action))

    def draw(self, screen, mouse):
        w, h = self.w, self.h
        _backdrop(screen, w, h)
        self.buttons = []
        if self.state is None:
            ui.blit_text(screen, "Connecting…", 24, TEXT, (w / 2, h / 2), align="center", bold=True)
            if self.error:
                ui.blit_text(screen, self.error, 15, BAD, (w / 2, h / 2 + 40), align="center", bold=True)
            self._button(screen, mouse, pygame.Rect(w / 2 - 90, h / 2 + 80, 180, 40), "Back", self.leave)
            return
        st = self.state
        ui.blit_text(screen, "LOBBY", 44, TEXT, (w / 2, 70), align="center", bold=True)
        sub = st.get("name", "")
        if self.hosting:
            sub += f"   ·   others join at {local_ip()}:{GAME_PORT}"
        ui.blit_text(screen, sub, 14, DIM, (w / 2, 110), align="center")

        cols = 2 if len(st["slots"]) > 6 else 1
        rows = -(-len(st["slots"]) // cols)
        pw = min(1120 if cols == 2 else 820, w - 40)
        cw = pw / cols
        rh = 44 if cols == 2 else 64
        px, py = (w - pw) / 2, 150
        screen.blit(art.panel(pw, rows * rh + 40, 12), (px, py))
        for c in range(cols):
            hx = px + c * cw
            ui.blit_text(screen, "PLAYER", 11, DIM, (hx + 54, py + 20), bold=True)
            ui.blit_text(screen, "TEAM", 11, DIM, (hx + cw - 210, py + 20), bold=True)
            ui.blit_text(screen, "STATUS", 11, DIM, (hx + cw - 100, py + 20), bold=True)
        for i, s in enumerate(st["slots"]):
            col, row = (i // rows, i % rows) if cols == 2 else (0, i)
            hx = px + col * cw
            y = py + 40 + row * rh
            pygame.draw.circle(screen, to255(TEAM_COLOR[i]), (int(hx + 30), int(y + rh / 2)), 10)
            kind = s["kind"]
            if kind == "human":
                label = s["name"] + ("  (you)" if i == self.slot else "") + ("  · host" if i == st.get("host_slot") else "")
            else:
                label = {"ai": f"{s['name'] or 'Computer'} ({DIFFICULTIES[st['difficulty']].name})", "open": "Open", "closed": "Closed"}[kind]
            ui.blit_text(screen, label, 14, TEXT if kind in ("human", "ai") else DIM, (hx + 50, y + rh / 2 - 7), bold=kind == "human")
            ui.blit_text(screen, COLOR_NAMES[i], 10, DIM, (hx + 50, y + rh / 2 + 9))
            bh = rh - 12
            if self.is_host and kind != "human":
                self._button(screen, mouse, pygame.Rect(hx + cw - 320, y + 6, 100, bh),
                             {"ai": "Computer", "open": "Open", "closed": "Closed"}[kind], lambda i=i: self.cycle_kind(i), size=12)
            if kind in ("human", "ai"):
                can = self.is_host or i == self.slot
                self._button(screen, mouse, pygame.Rect(hx + cw - 210, y + 6, 92, bh), f"Team {s['team']}",
                             lambda i=i: self.cycle_team(i), enabled=can, size=12)
                if kind == "human":
                    host = i == st.get("host_slot")
                    status, col_ = ("Host", AMBER) if host else (("Ready", GOOD) if s["ready"] else ("Not ready", DIM))
                else:
                    status, col_ = "Ready", GOOD
                ui.blit_text(screen, status, 12, col_, (hx + cw - 100, y + rh / 2), bold=True)

        by = py + rows * rh + 60
        if self.is_host:
            self._button(screen, mouse, pygame.Rect(px, by, 180, 40), f"AI: {DIFFICULTIES[st['difficulty']].name}",
                         lambda: self._send({"t": "difficulty", "index": (st["difficulty"] + 1) % 3}))
            self._button(screen, mouse, pygame.Rect(px + 196, by, 140, 40), "Free-for-all",
                         lambda: self._send({"t": "preset", "mode": "ffa"}))
            for k, n in enumerate((2, 3, 4)):
                self._button(screen, mouse, pygame.Rect(px + 352 + k * 92, by, 84, 40), f"{n} teams",
                             lambda n=n: self._send({"t": "preset", "mode": "teams", "count": n}))
            self._button(screen, mouse, pygame.Rect(px + pw - 200, by, 200, 40), "Start Game", self.start, accent=True)
            self._button(screen, mouse, pygame.Rect(px, by + 54, 492, 40), "Map: " + self._map_label(st), self.cycle_map)
        else:
            self._button(screen, mouse, pygame.Rect(px + pw - 200, by, 200, 40), "Not Ready" if self.ready else "Ready",
                         self.toggle_ready, accent=not self.ready)
            ui.blit_text(screen, "Waiting for the host to start the game", 14, DIM, (px, by + 20))
            ui.blit_text(screen, "Map: " + self._map_label(st), 15, TEXT, (px, by + 66), bold=True)
        self._button(screen, mouse, pygame.Rect(px + pw - 200, by + 54, 200, 40), "Leave", self.leave)
        if self.error:
            ui.blit_text(screen, self.error, 15, BAD, (w / 2, by + 118), align="center", bold=True)

        cy = by + 140
        ui.blit_text(screen, "CHAT  (Enter to type)", 11, DIM, (px, cy), bold=True)
        for j, (slot, name, text) in enumerate(self.chat_log):
            ui.blit_text(screen, f"{name}: {text}", 13, TEAM_COLOR.get(slot, TEXT), (px, cy + 20 + j * 18))
        if self.chat_text is not None:
            caret = "|" if (pygame.time.get_ticks() // 500) % 2 == 0 else " "
            ui.blit_text(screen, "Say: " + self.chat_text + caret, 14, TEXT, (px, cy + 20 + len(self.chat_log) * 18 + 6))


_bg_cache = {}


def _backdrop(screen, w, h):
    key = (w, h)
    bg = _bg_cache.get(key)
    if bg is None:
        bg = pygame.Surface((w, h)).convert()
        tile = art.ground_tile()
        for x in range(0, w, 1024):
            for y in range(0, h, 1024):
                bg.blit(tile, (x, y))
        dim = pygame.Surface((w, h), pygame.SRCALPHA)
        dim.fill((0, 0, 0, 170))
        bg.blit(dim, (0, 0))
        bg.blit(art.vignette(w * 1.15, h * 1.15), (-w * 0.075, -h * 0.075))
        _bg_cache.clear()
        _bg_cache[key] = bg
    screen.blit(bg, (0, 0))
