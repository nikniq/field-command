"""Entry point and application shell (window, main loop, scene switching, headless test mode).

Developer environment variables (all optional):
    FC_AUTOSTART=0|1|2    skip the menu and start at that difficulty
    FC_AUTOPLAY=1         an AI also plays the player's side
    FC_HEADLESS=1         run without a window as fast as possible (implies dummy video/audio drivers)
    FC_SNAPSHOT_DIR=dir   save periodic screenshots and a stats log (headless or windowed)
    FC_MENUSHOT=path      render the title screen to a PNG and exit
    FC_MAP=id             map for FC_AUTOSTART games (see mapgen.CATALOG); FC_OPPONENTS=1..3 computer opponents

Command line:
    field-command --server [--port 47777] [--name NAME]   run a dedicated multiplayer server
"""
import os
import sys
import time


def _stats(scene):
    g = scene.s.world

    def side(t):
        us = [u for u in g.units if u.team == t]
        kinds = {}
        for b in g.buildings:
            if b.team == t:
                kinds[b.stats.short] = kinds.get(b.stats.short, 0) + 1
        return (f"res={int(g.resources[t])} workers={sum(u.kind == 'worker' for u in us)} "
                f"rangers={sum(u.kind == 'marine' for u in us)} tanks={sum(u.kind == 'tank' for u in us)} "
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
        flags = pygame.RESIZABLE
        if settings.fullscreen and not self.headless:
            self.screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
        else:
            self.screen = pygame.display.set_mode(self.windowed_size, flags)
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
                                                      opponents=int(env.get("FC_OPPONENTS") or self.settings.opponents)))
        else:
            from .menu import MenuScene
            self.scene = MenuScene(self)

    def set_scene(self, scene):
        self.scene = scene

    def quit(self):
        self.running = False
        if self.server is not None:
            self.server.stop()

    def toggle_fullscreen(self):
        pg = self.pg
        full = not self.settings.fullscreen
        self.settings.set("fullscreen", full)
        if full:
            self.windowed_size = self.screen.get_size()
            self.screen = pg.display.set_mode((0, 0), pg.FULLSCREEN)
        else:
            self.screen = pg.display.set_mode(self.windowed_size, pg.RESIZABLE)
        self.scene.resize(*self.screen.get_size())

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
        self.pg.image.save(self.screen, os.path.join(self.snapshot_dir, f"{name}.png"))

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
        pg = self.pg
        while self.running:
            dt = min(self.clock.tick(60) / 1000.0, 1 / 15)
            for e in pg.event.get():
                if e.type == pg.QUIT:
                    self.running = False
                elif e.type in (pg.VIDEORESIZE, getattr(pg, "WINDOWSIZECHANGED", -1)):
                    if not self.settings.fullscreen:
                        self.screen = pg.display.get_surface()
                        self.scene.resize(*self.screen.get_size())
                elif e.type == pg.KEYDOWN and (e.key == pg.K_F11 or (e.key == pg.K_RETURN and e.mod & pg.KMOD_ALT)):
                    self.toggle_fullscreen()
                elif e.type == pg.KEYDOWN and e.key == pg.K_q and e.mod & pg.KMOD_CTRL:
                    self.quit()
                else:
                    self.scene.handle_event(e)
            mouse = pg.mouse.get_pos() if pg.mouse.get_focused() else None
            self.scene.update(dt, mouse)
            self.scene.draw(self.screen, mouse)
            pg.display.flip()
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
