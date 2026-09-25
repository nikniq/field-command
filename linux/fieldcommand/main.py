"""Entry point and application shell (window, main loop, scene switching, headless test mode).

Developer environment variables (all optional):
    FC_AUTOSTART=0|1|2    skip the menu and start at that difficulty
    FC_AUTOPLAY=1         an AI also plays the player's side
    FC_HEADLESS=1         run without a window as fast as possible (implies dummy video/audio drivers)
    FC_SNAPSHOT_DIR=dir   save periodic screenshots and a stats log (headless or windowed)
    FC_MENUSHOT=path      render the title screen to a PNG and exit
    FC_MAP=id             map for FC_AUTOSTART games (see mapgen.CATALOG); FC_OPPONENTS=1..11 computer opponents
    FC_TEAMS=n            deal the players into n teams (default: free-for-all)
    FC_UI_SCALE=x         force the interface scale (1, 1.5 or 2) instead of choosing it from the screen size

Command line:
    field-command --server [--port 47777] [--name NAME]   run a dedicated multiplayer server
"""
import os
import sys
import time
import traceback


def _stats(scene):
    g = scene.s.world

    def side(t):
        us = [u for u in g.units if u.team == t]
        kinds = {}
        for b in g.buildings:
            if b.team == t:
                kinds[b.stats.short] = kinds.get(b.stats.short, 0) + 1
        return (f"res={int(g.resources[t])} workers={sum(u.kind == 'worker' for u in us)} "
                f"rangers={sum(u.kind == 'marine' for u in us)} snipers={sum(u.kind == 'sniper' for u in us)} "
                f"tanks={sum(u.kind == 'tank' for u in us)} "
                f"supply={g.supply_used(t)}/{g.supply_cap(t)} mined={g.crystals_mined[t]} lost={g.units_lost[t]} "
                f"[{','.join(f'{k}={v}' for k, v in sorted(kinds.items()))}]")
    return f"t={int(g.elapsed)}\n" + "\n".join(f"  {p.name}: {side(s)}" for s, p in g.players.items())


class App:
    def __init__(self):
        env = os.environ
        self.headless = env.get("FC_HEADLESS") == "1"
        if self.headless:
            env.setdefault("SDL_VIDEODRIVER", "dummy")
            env.setdefault("SDL_AUDIODRIVER", "dummy")
        env.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
        # The desktop names a window by its class; without this it is "main.py" in the shell's dialogs.
        env.setdefault("SDL_VIDEO_X11_WMCLASS", "Field Command")
        env.setdefault("SDL_VIDEO_WAYLAND_WMCLASS", "Field Command")
        import pygame
        self.pg = pygame
        from . import audio
        from .settings import settings
        self.settings = settings
        pygame.init()
        if not self.headless:
            audio.init()
        pygame.display.set_caption("Field Command")
        self.windowed_size = (1400, 880)
        # `window` is the real display surface; `screen` is what scenes draw on. They are the same object at
        # UI scale 1, and a smaller logical surface that is scaled up to the window otherwise, so on a 4K or
        # HiDPI screen the interface keeps the size it was designed at.
        self.ui_scale = 1
        if settings.fullscreen and not self.headless:
            self.window = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
        else:
            self.window = pygame.display.set_mode(self.windowed_size, pygame.RESIZABLE)
        self.screen = self.window
        self._apply_ui_scale(env.get("FC_UI_SCALE"))
        try:
            from . import art
            pygame.display.set_icon(art.app_icon(64))
        except Exception:
            pass
        self.autoplay = env.get("FC_AUTOPLAY") == "1"
        self.server = None
        self.snapshot_dir = env.get("FC_SNAPSHOT_DIR")
        self._next_snapshot = 5.0
        self.running = True
        self.clock = pygame.time.Clock()
        from .defs import DIFFICULTIES
        auto = env.get("FC_AUTOSTART")
        if auto is not None or self.headless:
            from .game import GameScene
            from .session import LocalSession
            self.scene = GameScene(self, LocalSession(DIFFICULTIES[int(auto or 1) % 3], autoplay=self.autoplay,
                                                      map_id=env.get("FC_MAP") or self.settings.map_id,
                                                      opponents=int(env.get("FC_OPPONENTS") or self.settings.opponents),
                                                      teams=int(env.get("FC_TEAMS") or 0)))
        else:
            from .menu import MenuScene
            self.scene = MenuScene(self)

    def set_scene(self, scene):
        self.scene = scene

    # ------------------------------------------------------------ loading

    def loading(self, text):
        """Called between the heavy steps of setting a game up: shows what is happening, keeps the window
        answering the desktop (a slow machine otherwise gets a 'not responding' dialog), and notes the time
        each step took for startup.txt beside the saves."""
        now = time.time()
        if not hasattr(self, "_loading"):
            self._loading = []
        self._loading.append([text, now])
        if self.headless:
            return
        pg = self.pg
        for e in pg.event.get():
            if e.type == pg.QUIT:
                self.running = False
        try:
            from . import ui
            from .defs import AMBER, DIM, TEXT
            self.screen.fill((14, 16, 18))
            w, h = self.screen.get_size()
            ui.blit_text(self.screen, "FIELD COMMAND", 30, AMBER, (w / 2, h / 2 - 40), align="center", bold=True)
            ui.blit_text(self.screen, text + "…", 16, TEXT, (w / 2, h / 2 + 4), align="center")
            done = [f"{t}  {self._loading[i + 1][1] - at:.1f}s" for i, (t, at) in enumerate(self._loading[:-1])][-4:]
            for j, line in enumerate(done):
                ui.blit_text(self.screen, line, 11, DIM, (w / 2, h / 2 + 40 + j * 15), align="center")
            self.present()
        except Exception:  # noqa: BLE001 — a loading frame is never worth a crash
            pass

    def loading_done(self):
        """Closes the loading record and writes it where a bug report can find it."""
        steps = getattr(self, "_loading", None)
        if not steps:
            return
        steps.append(["ready", time.time()])
        try:
            from .save import saves_dir
            from . import __version__
            path = os.path.join(os.path.dirname(saves_dir()), "startup.txt")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(f"Field Command {__version__} · Python {sys.version.split()[0]} · pygame {self.pg.version.ver} on {sys.platform}\n")
                fh.write(f"window {self.window.get_size()} logical {self.screen.get_size()} ui_scale {self.ui_scale}\n")
                for (t, at), (_n, nxt) in zip(steps, steps[1:]):
                    fh.write(f"{nxt - at:7.2f}s  {t}\n")
                fh.write(f"{steps[-1][1] - steps[0][1]:7.2f}s  total\n")
        except Exception:  # noqa: BLE001
            pass
        self._loading = []

    # ------------------------------------------------------------ window, scale and screenshots

    def _apply_ui_scale(self, forced=None):
        """Picks the UI scale for the current window and (re)creates the logical surface to match."""
        w, h = self.window.get_size()
        scale = float(forced) if forced else self.settings.ui_scale_for(w, h)
        self.ui_scale = scale
        if scale == 1:
            self.screen = self.window
        else:
            self.screen = self.pg.Surface((max(320, int(w / scale)), max(200, int(h / scale)))).convert()

    def _window_changed(self):
        self.window = self.pg.display.get_surface()
        self._apply_ui_scale()
        self.scene.resize(*self.screen.get_size())

    def set_ui_scale(self, value):
        self.settings.set("ui_scale", value)
        self._window_changed()

    def to_logical(self, pos):
        s = self.ui_scale
        return pos if s == 1 else (pos[0] / s, pos[1] / s)

    def _scaled_event(self, e):
        if self.ui_scale == 1 or not hasattr(e, "pos"):
            return e
        d = dict(e.dict)
        d["pos"] = self.to_logical(e.pos)
        if "rel" in d:
            d["rel"] = (e.rel[0] / self.ui_scale, e.rel[1] / self.ui_scale)
        return self.pg.event.Event(e.type, d)

    def present(self):
        """Puts the logical surface on the window, scaled, and flips."""
        if self.screen is not self.window:
            if float(self.ui_scale).is_integer():
                self.pg.transform.scale(self.screen, self.window.get_size(), self.window)
            else:
                self.pg.transform.smoothscale(self.screen, self.window.get_size(), self.window)
        self.pg.display.flip()

    def screenshot(self):
        """F12: saves the window as it is shown, plus a note on the environment, and says where."""
        import datetime
        import platform
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        folder = next((d for d in (os.path.join(os.path.expanduser("~"), "Pictures"), os.path.expanduser("~"), os.getcwd())
                       if os.path.isdir(d)), os.getcwd())
        path = os.path.join(folder, f"field-command-{stamp}.png")
        try:
            self.pg.image.save(self.window, path)
        except Exception as e:  # noqa: BLE001 — pygame builds without image saving fall back to the logical surface
            path = os.path.join(folder, f"field-command-{stamp}.bmp")
            self.pg.image.save(self.window, path)
        from . import __version__
        info = self.pg.display.Info()
        with open(path.rsplit(".", 1)[0] + ".txt", "w") as f:
            f.write(f"Field Command {__version__}\npygame {self.pg.version.ver} SDL {'.'.join(map(str, self.pg.get_sdl_version()))}\n"
                    f"python {platform.python_version()} on {platform.platform()}\n"
                    f"window {self.window.get_size()} logical {self.screen.get_size()} ui_scale {self.ui_scale} "
                    f"(setting {self.settings.ui_scale}) depth {info.bitsize} fullscreen {self.settings.fullscreen}\n"
                    f"driver {self.pg.display.get_driver()}\n"
                    f"command-card icon repairs this game: {getattr(getattr(self.scene, 'hud', None), 'icon_repairs', 0)}\n")
        hud = getattr(self.scene, "hud", None)
        if hud is not None:
            hud.flash(f"Screenshot saved to {path}", (0.9, 0.93, 0.95, 1))
        print(f"screenshot: {path}", flush=True)
        return path

    def quit(self):
        self.running = False
        if self.server is not None:
            self.server.stop()

    def toggle_fullscreen(self):
        pg = self.pg
        full = not self.settings.fullscreen
        self.settings.set("fullscreen", full)
        if full:
            self.windowed_size = self.window.get_size()
            pg.display.set_mode((0, 0), pg.FULLSCREEN)
        else:
            pg.display.set_mode(self.windowed_size, pg.RESIZABLE)
        self._window_changed()

    def game_ended(self, game, won):
        if self.snapshot_dir:
            self._log(game, f"GAME OVER player {'WON' if won else 'LOST'}")

    # ------------------------------------------------------------ debug output

    def _log(self, game, extra=""):
        line = _stats(game) + (f"  {extra}" if extra else "")
        print(line, flush=True)
        os.makedirs(self.snapshot_dir, exist_ok=True)
        with open(os.path.join(self.snapshot_dir, "log.txt"), "a") as f:
            f.write(line + "\n")

    def _snapshot(self, name):
        os.makedirs(self.snapshot_dir, exist_ok=True)
        self.pg.image.save(self.window, os.path.join(self.snapshot_dir, f"{name}.png"))

    def _maybe_snapshot(self, force=False):
        g = self.scene
        if not self.snapshot_dir or not hasattr(g, "s") or not hasattr(g.s, "world"):
            return
        if force or g.elapsed >= self._next_snapshot:
            self._next_snapshot += 60
            self._log(g)
            self._snapshot("end" if force else f"t{int(g.elapsed):04d}")

    # ------------------------------------------------------------ loops

    def run(self):
        if self.headless:
            return self._run_headless()
        try:
            self._run_windowed()
        except Exception:  # noqa: BLE001 — anything: the traceback is written where it can be found, and shown
            self._crashed(traceback.format_exc())
            raise

    def _crashed(self, text):
        """An unhandled error would otherwise close the window with the traceback lost in a terminal nobody
        is watching: it goes to crash.txt beside the saves, and the window says so for a few seconds."""
        from .save import saves_dir
        path = os.path.join(os.path.dirname(saves_dir()), "crash.txt")
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                from . import __version__
                fh.write(f"Field Command {__version__} on {sys.platform}\n\n{text}")
        except OSError:
            path = "(could not write crash.txt)"
        print(text, file=sys.stderr)
        print(f"crash log: {path}", file=sys.stderr, flush=True)
        try:
            pg = self.pg
            from . import ui
            from .defs import BAD, DIM, TEXT
            end = time.time() + 8
            while time.time() < end:
                for e in pg.event.get():
                    if e.type in (pg.QUIT, pg.KEYDOWN, pg.MOUSEBUTTONDOWN):
                        end = 0
                self.screen.fill((14, 16, 18))
                w, h = self.screen.get_size()
                ui.blit_text(self.screen, "The game hit an error and has to stop.", 22, BAD, (w / 2, h / 2 - 40), align="center", bold=True)
                ui.blit_text(self.screen, f"Details were saved to {path}", 14, TEXT, (w / 2, h / 2), align="center")
                ui.blit_text(self.screen, "Please attach that file to a bug report. Any key closes this.", 12, DIM, (w / 2, h / 2 + 28), align="center")
                self.present()
                self.clock.tick(30)
        except Exception:  # noqa: BLE001 — the display may be what broke
            pass

    def _run_windowed(self):
        pg = self.pg
        while self.running:
            dt = min(self.clock.tick(60) / 1000.0, 1 / 15)
            for e in pg.event.get():
                if e.type == pg.QUIT:
                    self.running = False
                elif e.type in (pg.VIDEORESIZE, getattr(pg, "WINDOWSIZECHANGED", -1)):
                    if not self.settings.fullscreen:
                        self._window_changed()
                elif e.type == pg.KEYDOWN and (e.key == pg.K_F11 or (e.key == pg.K_RETURN and e.mod & pg.KMOD_ALT)):
                    self.toggle_fullscreen()
                elif e.type == pg.KEYDOWN and e.key == pg.K_F12:
                    self.screenshot()
                elif e.type == pg.KEYDOWN and e.key == pg.K_q and e.mod & pg.KMOD_CTRL:
                    self.quit()
                else:
                    self.scene.handle_event(self._scaled_event(e))
            mouse = self.to_logical(pg.mouse.get_pos()) if pg.mouse.get_focused() else None
            self.scene.update(dt, mouse)
            self.scene.draw(self.screen, mouse)
            self.present()
            self._maybe_snapshot()
        self.quit()
        pg.quit()

    def _run_headless(self, max_time=2400):
        g = self.scene
        dt = 1 / 30
        start = time.time()
        frames = 0
        while not g.s.game_over and g.elapsed < max_time:
            self.pg.event.pump()
            g.update(dt, None)
            frames += 1
            if self.snapshot_dir and g.elapsed >= self._next_snapshot:
                g.draw(self.screen, None)
                self._maybe_snapshot()
        if self.snapshot_dir:
            g.draw(self.screen, None)
            self._maybe_snapshot(force=True)
        print(f"headless: {frames} steps, {g.elapsed:.0f}s simulated in {time.time() - start:.1f}s", flush=True)
        self.pg.quit()


def menu_shot(path):
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
    os.environ.pop("FC_AUTOSTART", None)
    app = App()
    for _ in range(40):
        app.scene.update(0.05, None)
    app.scene.draw(app.screen, None)
    app.pg.image.save(app.screen, path)


def run_server(argv):
    """Dedicated server: `field-command --server [--port N] [--name NAME]` (no display or pygame needed)."""
    from .net import GAME_PORT, Server

    def opt(flag, default):
        return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else default
    port = int(opt("--port", GAME_PORT))
    name = opt("--name", "Field Command server")
    print(f"Starting dedicated server '{name}' on TCP {port} (LAN discovery on UDP 47778). Ctrl+C to stop.")
    Server(name=name, port=port).serve_forever()
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if "--version" in argv:
        from . import __version__
        print(f"Field Command {__version__}")
        return 0
    if "--make-icons" in argv:
        from .icons import write_icons
        write_icons(argv[argv.index("--make-icons") + 1])
        return 0
    if "--server" in argv:
        return run_server(argv)
    if os.environ.get("FC_MENUSHOT"):
        menu_shot(os.environ["FC_MENUSHOT"])
        return 0
    App().run()
    return 0
