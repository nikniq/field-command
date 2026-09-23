"""The battlefield scene (client side): camera, input, selection, rendering and effects.

The simulation lives in a World behind a session (local or networked); this scene only sends commands
and draws what the session exposes.
"""
import math
import random

import pygame

from . import art, audio, defs, terrain, ui
from .defs import KIT_BY_ID
from .defs import (AMBER, ARTILLERY_MIN_RANGE, BAD, BRIDGE_COST, BUILDINGS, BUILD_MENU, CRYSTAL, DIM, GOOD, SHIELD_MAX,
                   SHIELD_RADIUS, TEAM_COLOR,
                   TEAM_LIGHT, TEXT, TOWER_RADIUS, UNITS, UPGRADES, UPGRADE_KINDS, clamp, rects_intersect,
                   to255, upgrade_applies, upgrade_cost)
from .effects import Effects
from .fogview import FogView
from .net import STATUS
from .settings import settings

SPARK_COLORS = {"hit": (255, 204, 102), "crystal": (102, 235, 255), "amber": (255, 194, 77),
                "heal": (140, 255, 170)}
TRACER_COLORS = {0: (1, 0.88, 0.5, 1), 1: (1, 0.75, 0.4, 1), 2: (0.78, 0.95, 1.0, 1)}
SOUND_GAPS = {"rifle": 0.05, "cannon": 0.08, "turret": 0.06, "explosion": 0.08, "snipe": 0.05}
ORDER_COLORS = {STATUS["move"]: GOOD, STATUS["amove"]: BAD, STATUS["attack"]: BAD, STATUS["gather"]: CRYSTAL,
                STATUS["build"]: AMBER, STATUS["rebuild"]: AMBER}


class CommandButton:
    def __init__(self, icon, title, hotkey, cost, enabled, tip, action):
        self.icon, self.title, self.hotkey, self.cost = icon, title, hotkey, cost
        self.enabled, self.tip, self.action = enabled, tip, action


# The tilt: the camera looks down at an angle, so the world's north-south axis is foreshortened on screen by
# this factor. Everything positioned through the camera picks it up; buildings show their walls below.
TILT = 0.8


class Camera:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.x, self.y = defs.WORLD_W / 2, defs.WORLD_H / 2
        self.zoom = 1.0
        self.sx = self.sy = 0.0  # shake offset

    def to_screen(self, x, y):
        return ((x - self.x - self.sx) / self.zoom + self.w / 2, self.h / 2 - (y - self.y - self.sy) * TILT / self.zoom)

    def to_world(self, px, py):
        return (self.x + self.sx + (px - self.w / 2) * self.zoom, self.y + self.sy - (py - self.h / 2) * self.zoom / TILT)

    def view_rect(self):
        hw, hh = self.w * self.zoom / 2, self.h * self.zoom / TILT / 2
        cx, cy = self.x + self.sx, self.y + self.sy
        return (cx - hw, cy - hh, cx + hw, cy + hh)


def build_ground(map_spec):
    """Bakes terrain, clearings, roads, rocks and tree shadows into one world-sized surface."""
    defs.set_world_size(map_spec.get("w", defs.DEFAULT_WORLD[0]), map_spec.get("h", defs.DEFAULT_WORLD[1]))
    W, H = int(defs.WORLD_W), int(defs.WORLD_H)
    ground = pygame.Surface((W, H))
    if pygame.display.get_surface():
        ground = ground.convert()
    tile = art.ground_tile()
    for x in range(0, W, 1024):
        for y in range(0, H, 1024):
            ground.blit(tile, (x, y))
    rnd = random.Random(map_spec.get("seed", 42))
    # One sun for the whole map and low-frequency biome tints: baked in as a multiply pass.
    ground.blit(art.map_tint(W, H, map_spec.get("seed", 42)), (0, 0), special_flags=pygame.BLEND_MULT)
    dirt = (107, 87, 56)
    blob = art.blob()

    def stamp(x, y, size, a):
        s = pygame.transform.smoothscale(blob, (int(size), int(size * rnd.uniform(0.7, 1.0))))
        s = pygame.transform.rotate(s, rnd.uniform(0, 360))
        s.fill((*dirt, int(255 * a)), special_flags=pygame.BLEND_RGBA_MULT)
        ground.blit(s, (x - s.get_width() / 2, H - y - s.get_height() / 2))

    for cx, cy, r in map_spec["clearings"]:
        for _ in range(int(r / 22)):
            a = rnd.uniform(0, 2 * math.pi)
            d = rnd.uniform(0, r * 0.6)
            stamp(cx + math.cos(a) * d, cy + math.sin(a) * d, r * rnd.uniform(0.6, 1.0), 0.5)
    for road in map_spec["roads"]:
        for (ax, ay), (bx, by) in zip(road, road[1:]):
            n = max(1, int(math.hypot(bx - ax, by - ay) / 28))
            for k in range(n + 1):
                t = k / n
                stamp(ax + (bx - ax) * t + rnd.uniform(-8, 8), ay + (by - ay) * t + rnd.uniform(-8, 8), rnd.uniform(110, 150), 0.42)
    # Wheel ruts: two worn lines either side of each road's centre, wobbling like real tracks.
    for road in map_spec["roads"]:
        for (ax, ay), (bx, by) in zip(road, road[1:]):
            length = math.hypot(bx - ax, by - ay)
            if length < 30:
                continue
            ux, uy = (bx - ax) / length, (by - ay) / length
            nx, ny = -uy, ux
            x0, y0 = min(ax, bx) - 40, min(ay, by) - 40
            over = pygame.Surface((int(abs(bx - ax)) + 80, int(abs(by - ay)) + 80), pygame.SRCALPHA)
            for side in (-9, 9):
                pts = []
                d = 0.0
                while d <= length:
                    wob = math.sin(d / 37 + side) * 3
                    px, py = ax + ux * d + nx * (side + wob), ay + uy * d + ny * (side + wob)
                    pts.append((px - x0, (H - py) - (H - y0 - over.get_height())))
                    d += 24
                if len(pts) > 1:
                    pygame.draw.lines(over, (58, 44, 28, 70), False, pts, 3)
            ground.blit(over, (x0, H - y0 - over.get_height()))
    # Terrain features: water and cliffs are one organic layer. Bridges are drawn per frame instead
    # of being baked in here, because they can be destroyed and rebuilt.
    m = art.TERRAIN_MARGIN
    layer = terrain.render(map_spec)
    if layer is not None:
        ground.blit(layer, (0, 0))
    tuft = pygame.transform.smoothscale(art.tuft(), (16, 16))
    for _ in range(500):
        ground.blit(tuft, (rnd.uniform(0, W), rnd.uniform(0, H)))
    for i in range(70):
        img = pygame.transform.rotozoom(art.rock(i % 4), rnd.uniform(-30, 30), rnd.uniform(0.5, 1.1) / art.SCALE)
        ground.blit(img, (rnd.uniform(0, W) - img.get_width() / 2, rnd.uniform(0, H) - img.get_height() / 2))
    for i in range(int(W * H / 40000)):          # pebbles: the rocks again, tiny
        img = pygame.transform.rotozoom(art.rock(i % 4), rnd.uniform(0, 360), rnd.uniform(0.12, 0.26) / art.SCALE)
        ground.blit(img, (rnd.uniform(0, W) - img.get_width() / 2, rnd.uniform(0, H) - img.get_height() / 2))
    shadow = art.shadow()
    # Forest floor: the ground under a stand of trees is darker than open grass, then each tree's own shadow.
    floor = pygame.transform.smoothscale(shadow, (150, 130))
    floor.fill((0, 0, 0, 110), special_flags=pygame.BLEND_RGBA_MULT)
    for (x, y, _r, _v, _a, s) in map_spec["trees"]:
        ground.blit(floor, (x + 6 - floor.get_width() / 2, H - (y - 8) - floor.get_height() / 2))
    for (x, y, _r, _v, _a, s) in map_spec["trees"]:
        sh = pygame.transform.smoothscale(shadow, (int(90 * s), int(80 * s)))
        ground.blit(sh, (x + 10 - sh.get_width() / 2, H - (y - 12) - sh.get_height() / 2))
    return ground


class GameScene:
    def __init__(self, app, session):
        from .hud import HUD
        self.app = app
        self.s = session
        self.difficulty = session.difficulty
        w, h = app.screen.get_size()
        self.cam = Camera(w, h)
        self.fx = Effects()
        self.fog_view = FogView(session.fog)
        self.obstacles = session.obstacles
        self.clearings = session.map["clearings"]
        self.roads = session.map["roads"]
        self.ground = build_ground(session.map)
        self.clouds = art.cloud_layer()
        self._known_units = {}      # id -> (kind, team, x, y, angle): to mark where the fallen dropped
        self.selection = []
        self.paused = False
        self.placing = None
        self.attack_pending = False
        self.drag_start = self.drag_now = None
        self.pan_drag = None
        self.minimap_dragging = False
        self.keys_down = set()
        self.control_groups = {}
        self.group_of = {}           # unit id -> control group number, for the badge on the unit
        self._last_group_tap = (None, 0)
        self._last_click = (0, 0, 0)
        self._last_alert = -100.0
        self._last_alert_pos = None
        # Alert points: Z (or Alt+click) marks "attack here", Shift+Z "help here", for the whole alliance;
        # beacons are [x, y, slot, age, kind].
        self.ping_pending = False
        self.ping_kind = 0
        self.beacons = []
        # Satellite view: the whole map on screen at once (Tab), with markers so troops still read.
        self.satellite = False
        self._satellite_saved = None
        self._idle_cycle = 0
        self._last_builder = None
        self.hovered = None
        self._cursor = None
        self._dash = 0.0
        self.shells = []
        self._emit_acc = {}
        self._ground_view = None
        self._ground_key = None
        self._end_shown = False
        self._elim_shown = False
        self.hud = HUD(self)
        self.hud.fog_changed()
        my_hq = next((b for b in session.buildings if b.team == session.slot and b.kind == "hq"), None)
        start = (my_hq.x, my_hq.y) if my_hq else tuple(session.map["starts"][0][:2])
        # Look from the base toward the map centre.
        self.center_camera(start[0] + (defs.WORLD_W / 2 - start[0]) * 0.08, start[1] + (defs.WORLD_H / 2 - start[1]) * 0.08)
        self.hud.flash("Mine crystal, build an army, and destroy every enemy building.", TEXT)
        self.hud.flash("Press H at any time for the field manual." if session.can_pause else
                       "Multiplayer: press Enter to chat, H for the field manual.", DIM)

    # ------------------------------------------------------------ convenience

    @property
    def elapsed(self):
        return self.s.elapsed

    @property
    def online(self):
        return not self.s.can_pause

    def mine(self, e):
        return e.team == self.s.slot

    def friendly(self, e):
        return self.s.friendly(e)

    def idle_workers(self):
        return self.s.idle_workers()

    def army(self):
        return self.s.army()

    # ------------------------------------------------------------ main loop

    def resize(self, w, h):
        self.cam.w, self.cam.h = w, h
        self._ground_key = None
        self.hud.layout(w, h)
        self.clamp_camera()

    def update(self, dt, mouse):
        self._update_camera(dt, mouse)
        self._update_hover(mouse)
        self._dash += dt * 22
        running = not (self.paused and self.s.can_pause)
        for ev in self.s.update(dt, paused=not running):
            self._on_event(ev)
        if running:
            self.fx.update(dt * (settings.game_speed if self.s.can_pause else 1.0))
            self._update_client_fx(dt)
            self._update_hits_and_losses(dt)
        self.hud.update(dt, mouse)
        for b in self.beacons:
            b[3] += dt
        self.beacons = [b for b in self.beacons if b[3] < 12.0]
        self._autosave()
        if self.fog_view.update(dt):
            self.hud.fog_changed()
        self.selection = [e for e in self.selection if not e.dead]
        if self.s.game_over and not self._end_shown:
            self._end_shown = True
            self.cancel_modes()
            self.s.fog.reveal_all = True
            my_team = self.s.my_team()
            won = self.s.winner_team == my_team
            audio.play("victory" if won else "defeat")
            mission = getattr(self.s, "mission", None)
            if won and mission and mission.id not in settings.campaign_done:
                settings.set("campaign_done", list(settings.campaign_done) + [mission.id])
            self.hud.show_end(won)
            self.app.game_ended(self, won)
        disc = getattr(self.s, "disconnected", None)
        if disc and not self.s.game_over and not self._end_shown:
            self._end_shown = True
            self.hud.show_disconnected(disc)

    def _update_client_fx(self, dt):
        """Presentation-only animation derived from entity state (smoke, fire, sparks, recoil)."""
        fx = self.fx
        v = self.cam.view_rect()
        for u in self.s.units:
            if u.recoil:
                u.recoil = max(0.0, u.recoil - dt * 6)
            if u.pulse:
                u.pulse = max(0.0, u.pulse - dt * 5)
        for b in self.s.buildings:
            b.dish_angle = getattr(b, "dish_angle", 0.0) + dt * 0.9
            if not (v[0] - 200 < b.x < v[2] + 200 and v[1] - 200 < b.y < v[3] + 200) or not self.s.shown(b):
                continue
            acc = self._emit_acc.setdefault(b.id, [0.0, 0.0, 0.0, 0.0])
            if not b.built:
                acc[0] += dt * 6
                while acc[0] >= 1:
                    acc[0] -= 1
                    fx.sparks(b.x + random.uniform(-0.8, 0.8) * b.half, b.y + random.uniform(-0.8, 0.8) * b.half, 3, 50,
                              SPARK_COLORS["amber"])
                continue
            if b.kind == "factory":
                acc[1] += dt * (5 if b.queue or b.queue_progress else 0.6)
                while acc[1] >= 1:
                    acc[1] -= 1
                    ox, oy = random.choice(art.CHIMNEYS)
                    fx.smoke_puff(b.x + ox * b.half, b.y + oy * b.half, False)
            frac = b.hp / b.max_hp
            if frac < 0.55:
                acc[2] += dt * 7
                while acc[2] >= 1:
                    acc[2] -= 1
                    fx.smoke_puff(b.x - b.half * 0.3, b.y + b.half * 0.2, True)
            if frac < 0.28:
                acc[3] += dt * 26
                while acc[3] >= 1:
                    acc[3] -= 1
                    fx.flame(b.x + b.half * 0.25, b.y - b.half * 0.1)
        for s in self.shells:
            s[5] += dt
            f = min(1.0, s[5] / s[4])
            dist = math.hypot(s[2] - s[0], s[3] - s[1])
            # Artillery shells climb high and slow so you can follow them across the screen
            arc = math.sin(f * math.pi) * (min(220, dist * 0.35) if s[8] else min(40, dist * 0.12))
            s[6] = s[0] + (s[2] - s[0]) * f
            s[7] = s[1] + (s[3] - s[1]) * f + arc
            fx.trail(s[6], s[7])
        self.shells = [s for s in self.shells if s[5] < s[4]]

    # ------------------------------------------------------------ events from the simulation

    def _on_event(self, ev):
        k = ev[0]
        fx = self.fx
        me = self.s.slot
        if k == "tracer":
            fx.tracer(ev[1], ev[2], ev[3], ev[4], TRACER_COLORS.get(ev[5], TRACER_COLORS[0]),
                      {0: 1.4, 1: 2, 2: 1.1}.get(ev[5], 1.4))
        elif k == "muzzle":
            fx.muzzle(ev[1], ev[2], ev[3], ev[4])
        elif k == "sparks":
            fx.sparks(ev[1], ev[2], ev[3], ev[4], SPARK_COLORS.get(ev[5], SPARK_COLORS["hit"]))
        elif k == "smoke":
            fx.smoke_burst(ev[1], ev[2], ev[3])
        elif k == "explode":
            fx.explosion(ev[1], ev[2], ev[3], scorch=bool(ev[4]), delay=ev[5] if len(ev) > 5 else 0)
            if ev[3] > 25 and self._on_screen(ev[1], ev[2]):
                self.shake(min(10, ev[3] * 0.18))
        elif k == "flash":
            key = ev[4]
            key = str(key)
            col = (TEAM_LIGHT.get(int(key[4:]), TEXT) if key.startswith("team")
                   else (0.45, 0.85, 1.0, 1) if key == "shield" else (1, 0.7, 0.3, 1))
            fx.flash(ev[1], ev[2], ev[3], col, 0.5)
        elif k in ("recoil", "pulse"):
            e = self.s.by_id(ev[1])
            if e is not None:
                setattr(e, k, 1.0)
        elif k == "shell":
            self.shells.append([ev[1], ev[2], ev[3], ev[4], ev[5], 0.0, ev[1], ev[2], ev[7] if len(ev) > 7 else 0])
        elif k == "wreck":
            fx.decal("wreck", ev[1], ev[2], 54, 30, angle=ev[3], team=ev[4])
        elif k == "rubble":
            fx.decal("rubble", ev[1], ev[2], ev[3], 60)
        elif k == "shake":
            if self._on_screen(ev[1], ev[2]):
                self.shake(ev[3])
        elif k == "sound":
            if self._on_screen(ev[2], ev[3], 150):
                audio.play(ev[1], SOUND_GAPS.get(ev[1], 0))
        elif k == "msg":
            self.hud.flash(ev[2], {"bad": BAD, "good": GOOD}.get(ev[3], TEXT))
        elif k == "alert":
            self._alert(ev[2], ev[3])
        elif k == "ping":
            self._ping(ev[1], ev[2], ev[3], ev[4] if len(ev) > 4 else 0)
        elif k == "crate":
            self._crate_taken(ev[1], ev[2], ev[3], ev[4], ev[5])
        elif k == "income":
            if self._on_screen(ev[2], ev[3]):
                fx.text(f"+{ev[4]}", ev[2], ev[3] + 14, CRYSTAL)
        elif k == "built":
            self.hud.flash(f"{BUILDINGS[ev[2]].name} complete", GOOD)
            audio.play("complete")
        elif k == "wave":
            self.hud.flash("Intel: an enemy attack wave is inbound!", AMBER)
            audio.play("wave")
        elif k == "bdead":
            name = BUILDINGS[ev[2]].name
            if ev[1] == me:
                self.hud.flash(f"{name} destroyed", BAD)
            elif self.s.allied(ev[1], me):
                self.hud.flash(f"Ally's {name} destroyed", AMBER)
            else:
                self.hud.flash(f"Enemy {name} destroyed", GOOD)
        elif k == "kit":
            self.hud.flash(f"{KIT_BY_ID[ev[2]].name} issued to every {UNITS[KIT_BY_ID[ev[2]].unit].name}", GOOD)
            audio.play("complete")
        elif k == "upgraded":
            self.hud.flash(f"{BUILDINGS[ev[2]].name}: {UPGRADES[ev[3]].name} installed", GOOD)
            audio.play("complete")
        elif k == "tower":
            slot = ev[1]
            if slot == me:
                self.hud.flash("Watchtower captured — you now see far around it", GOOD)
            elif self.s.allied(slot, me):
                self.hud.flash(f"{self.s.players[slot].name} captured a Watchtower", AMBER)
            else:
                self.hud.flash(f"{self.s.players[slot].name} took a Watchtower", BAD)
                self.hud.ping(ev[3], ev[4])
        elif k == "rank":
            if ev[1] == me:
                u = self.s.by_id(ev[2])
                self.hud.flash(f"{u.name if u else 'Unit'} promoted to rank {ev[3]}", GOOD)
        elif k == "bridge":
            down = not ev[2]
            self.hud.flash("Bridge destroyed" if down else "Bridge rebuilt", BAD if down else GOOD)
            if down:
                self.hud.ping(ev[3], ev[4])
        elif k == "elim":
            if ev[1] == me:
                self.hud.flash("You have been eliminated", BAD)
                if self.online and not self._elim_shown and not self.s.game_over:
                    self._elim_shown = True
                    self.hud.show_eliminated()
            elif len(self.s.players) > 2:
                self.hud.flash(f"{ev[2]} has been eliminated", AMBER)
        elif k == "chat":
            who = "Server" if ev[1] == -1 else self.s.player_name(ev[1])
            self.hud.flash(f"{who}: {ev[2]}", TEAM_LIGHT.get(ev[1], TEXT))
            audio.play("pop")

    def _ping(self, slot, x, y, kind=0):
        """An alert point placed by someone on our side (maybe us): a beacon on the map and the minimap, and
        Space jumps there. Kind 0 is "attack here", 1 is "help here"."""
        me = slot == self.s.slot
        p = self.s.players.get(slot) if hasattr(self.s.players, "get") else None
        who = "You" if me else getattr(p, "name", f"Player {slot + 1}")
        color = TEAM_LIGHT[slot]
        self.beacons = [b for b in self.beacons if b[2] != slot] + [[x, y, slot, 0.0, kind]]
        self.hud.ping(x, y, color, 4.0)
        for i in range(3):
            self.fx.ring(x, y, 30, 160, color, 0.9, delay=i * 0.3)
        self._last_alert = self.elapsed
        self._last_alert_pos = (x, y)
        if me:
            self.hud.flash("Attack point set: allies are called here" if kind == 0 else "Alert point set: allies are called to help", TEXT)
        else:
            self.hud.flash((f"{who}: attack here!" if kind == 0 else f"{who} calls for help here!") + "  (Space to view)", color)
            audio.play("alert")

    def _crate_taken(self, slot, x, y, kind, amount):
        """Someone opened a supply crate: a burst where it stood, and a line for whoever gained by it."""
        for i in range(2):
            self.fx.ring(x, y, 20, 90, AMBER, 0.6, delay=i * 0.2)
        self.fx.sparks(x, y, 10, 90, "amber")
        me = slot == self.s.slot
        p = self.s.players.get(slot) if hasattr(self.s.players, "get") else None
        who = "You" if me else getattr(p, "name", f"Player {slot + 1}")
        gift = f"{amount} crystal" if kind == "crystal" else ("a squad of Rangers" if kind == "squad" else "a Siege Tank")
        if me or self.s.allied(slot, me and slot or self.s.slot):
            self.hud.flash(f"Supply crate: {who} found {gift}", GOOD)
            if me:
                audio.play("complete")
        else:
            self.hud.flash(f"{who} took a supply crate", TEXT)

    def begin_ping(self, kind=0):
        self.cancel_modes()
        self.ping_pending = True
        self.ping_kind = kind
        self.hud.flash("Attack point: click the map or minimap to direct your allies there" if kind == 0
                       else "Help point: click the map or minimap to call your allies there", TEXT)

    def place_ping(self, x, y):
        self.ping_pending = False
        self.s.send(["ping", x, y, self.ping_kind])
        self.ping_kind = 0
        audio.play("click")

    def _update_hits_and_losses(self, dt):
        """Client-side combat feedback: a white flash on anything that just lost health, and the fallen left
        where they dropped (tanks leave wrecks by server event; everyone on foot leaves a body)."""
        s = self.s
        seen = {}
        for u in s.units:
            if u.dead:
                continue
            last = getattr(u, "_last_hp", None)
            if last is not None and u.hp < last - 0.5:
                u._flash = 0.14
            u._last_hp = u.hp
            u._flash = max(0.0, getattr(u, "_flash", 0.0) - dt)
            seen[u.id] = (u.kind, u.team, u.x, u.y, u.angle)
        for b in s.buildings:
            if b.dead:
                continue
            last = getattr(b, "_last_hp", None)
            if last is not None and b.hp < last - 0.5:
                b._flash = 0.12
            b._last_hp = b.hp
            b._flash = max(0.0, getattr(b, "_flash", 0.0) - dt)
        for uid, (kind, team, x, y, angle) in self._known_units.items():
            if uid not in seen and kind != "tank" and s.fog.is_visible(x, y):
                self.fx.decal(("fallen", kind), x, y, 30, 18, angle=math.degrees(angle), team=team)
                self.fx.smoke_puff(x, y, False)
        self._known_units = seen

    def _draw_satellite_markers(self, screen, units, buildings):
        """From orbit a Ranger is a pixel: draw every visible unit as a solid dot and every building as a
        square in its side's colour, big enough to read, on top of the sprites."""
        cam = self.cam
        for u in units:
            sx, sy = cam.to_screen(u.x, u.y)
            col = to255(TEAM_LIGHT[u.team])
            r = 5 if u.kind == "tank" else 4
            pygame.draw.circle(screen, (0, 0, 0), (int(sx), int(sy)), r + 1)
            pygame.draw.circle(screen, col, (int(sx), int(sy)), r)
        for b in buildings:
            sx, sy = cam.to_screen(b.x, b.y)
            h = max(4, int(b.half / cam.zoom))
            pygame.draw.rect(screen, (0, 0, 0), (int(sx) - h - 1, int(sy) - h - 1, 2 * h + 2, 2 * h + 2), 2)
            pygame.draw.rect(screen, to255(TEAM_LIGHT[b.team]), (int(sx) - h, int(sy) - h, 2 * h, 2 * h), 2)

    def _draw_clouds(self, screen):
        """Cloud shadows drifting over everything on the ground (the fog goes on above them)."""
        cam = self.cam
        z = cam.zoom
        tile = art.sprites.get("clouds", self.clouds, 0, 1 / z, squash=TILT)
        tw = max(1, tile.get_width())
        ox = (self.elapsed * 22) % 1024
        oy = (self.elapsed * 9) % 1024
        v = cam.view_rect()
        x = math.floor((v[0] - ox) / 1024) * 1024 + ox
        while x < v[2]:
            y = math.floor((v[1] - oy) / 1024) * 1024 + oy
            while y < v[3] + 1024:
                sx, sy = cam.to_screen(x, y + 1024)
                screen.blit(tile, (sx, sy))
                y += 1024
            x += 1024

    def _draw_beacons(self, screen):
        """A pulsing marker in the pinger's colour, on top of the fog so it can be seen anywhere."""
        cam = self.cam
        z = cam.zoom
        for x, y, slot, age, kind in self.beacons:
            if not self._on_screen(x, y, 60):
                continue
            sx, sy = cam.to_screen(x, y)
            col = to255(TEAM_LIGHT[slot])
            k = (age % 1.0)
            r = int((10 + 34 * k) / z)
            pygame.draw.circle(screen, col, (int(sx), int(sy)), max(2, r), 2)
            if kind == 0:
                # Attack here: a target reticle in the caller's colour with a red core
                rr_ = int(16 / z)
                pygame.draw.circle(screen, col, (int(sx), int(sy)), max(3, rr_), max(1, int(2 / z)))
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    pygame.draw.line(screen, col, (int(sx + dx * rr_ * 0.6), int(sy + dy * rr_ * 0.6)),
                                     (int(sx + dx * rr_ * 1.5), int(sy + dy * rr_ * 1.5)), max(1, int(2 / z)))
                pygame.draw.circle(screen, to255(BAD), (int(sx), int(sy)), max(2, int(5 / z)))
            else:
                # Help here: a pennant so it reads as a marker, not a hit
                pygame.draw.circle(screen, col, (int(sx), int(sy)), max(2, int(6 / z)))
                pole = int(36 / z)
                pygame.draw.line(screen, col, (int(sx), int(sy)), (int(sx), int(sy) - pole), max(1, int(2 / z)))
                flag = [(int(sx), int(sy) - pole), (int(sx) + int(18 / z), int(sy) - pole + int(7 / z)), (int(sx), int(sy) - pole + int(14 / z))]
                pygame.draw.polygon(screen, col, flag)

    def _alert(self, x, y):
        if self.elapsed - self._last_alert <= 12:
            return
        v = self.cam.view_rect()
        if v[0] + 100 < x < v[2] - 100 and v[1] + 100 < y < v[3] - 100:
            return
        self._last_alert = self.elapsed
        self._last_alert_pos = (x, y)
        self.hud.flash("Your forces are under attack!  (Space to view)", BAD)
        self.hud.ping(x, y)
        for i in range(3):
            self.fx.ring(x, y, 30, 120, BAD, 0.8, delay=i * 0.35)
        audio.play("alert")

    # ------------------------------------------------------------ scene transitions

    def leave(self):
        self.s.leave()

    def restart(self):
        from .session import LocalSession
        if self.online:
            self.back_to_lobby()
            return
        mission = getattr(self.s, "mission", None)
        if mission:
            self.start_mission(mission)
            return
        map_id, opponents, teams = getattr(self.s, "skirmish", (None, 1, 0))
        self.app.set_scene(GameScene(self.app, LocalSession(self.difficulty, autoplay=self.app.autoplay,
                                                            map_id=map_id, opponents=opponents, teams=teams)))

    def start_mission(self, m):
        from .defs import DIFFICULTIES
        from .session import LocalSession
        self.app.set_scene(GameScene(self.app, LocalSession(DIFFICULTIES[m.difficulty], autoplay=self.app.autoplay,
                                                            map_id=m.map, opponents=m.opponents, teams=m.teams,
                                                            mission=m.id)))

    def next_mission(self):
        from .defs import CAMPAIGN
        mission = getattr(self.s, "mission", None)
        if not mission:
            return
        ids = [m.id for m in CAMPAIGN]
        i = ids.index(mission.id)
        if i + 1 < len(CAMPAIGN):
            self.start_mission(CAMPAIGN[i + 1])

    def back_to_lobby(self):
        from .lobby import LobbyScene
        if getattr(self.s, "conn", None) and self.s.conn.alive:
            self.app.set_scene(LobbyScene(self.app, self.s.conn, hosting=self.app.server is not None,
                                          slot=self.s.slot, initial=self.s.lobby_msg))
        else:
            self.to_menu()

    def to_menu(self):
        from .menu import MenuScene
        if self.can_save() and not self.s.game_over:
            self.save_game("autosave", "Autosave")      # so Load Game continues where you left off
        self.leave()
        if getattr(self.app, "server", None) is not None:
            self.app.server.stop()
            self.app.server = None
        try:
            pygame.mouse.set_cursor(pygame.SYSTEM_CURSOR_ARROW)
        except pygame.error:
            pass
        self.app.set_scene(MenuScene(self.app))

    def toggle_pause(self):
        if self.s.game_over:
            return
        if self.hud.overlay_visible:
            self.hud.clear_overlay()
            self.paused = False
        else:
            self.paused = True
            self.hud.show_pause()

    # ------------------------------------------------------------ saving

    def can_save(self):
        return self.s.can_pause and not self.s.game_over and hasattr(self.s, "world")

    def save_game(self, name, label=""):
        try:
            path = self.s.save(name, label)
        except OSError as e:
            self.hud.flash(f"Could not save: {e}", BAD)
            return
        self.hud.flash(f"Game saved ({label or name})", GOOD)
        audio.play("complete")
        return path

    def load_game(self, name):
        from .session import LocalSession
        try:
            session = LocalSession.load(name, autoplay=self.app.autoplay)
        except (OSError, ValueError, KeyError) as e:
            self.hud.flash(f"Could not load: {e}", BAD)
            return
        self.app.set_scene(GameScene(self.app, session))

    def _autosave(self):
        if self.can_save() and self.s.elapsed >= self.s.autosave_at:
            self.s.autosave_at = self.s.elapsed + 300
            try:
                self.s.save("autosave", "Autosave")
            except OSError:
                pass

    def toggle_store(self):
        if self.hud.store_open:
            self.hud.close_store()
        elif not self.hud.overlay_visible:
            self.hud.open_store()

    def buy_kit(self, kit_id):
        self.s.send(["buy", kit_id])

    def toggle_help(self):
        if self.s.game_over:
            return
        if self.hud.overlay_visible:
            self.hud.clear_overlay()
            self.paused = False
        else:
            self.paused = True
            self.hud.show_help()

    # ------------------------------------------------------------ camera

    def _update_camera(self, dt, mouse):
        vx = vy = 0
        k = self.keys_down
        if pygame.K_LEFT in k:
            vx -= 1
        if pygame.K_RIGHT in k:
            vx += 1
        if pygame.K_DOWN in k:
            vy -= 1
        if pygame.K_UP in k:
            vy += 1
        if (settings.edge_scroll and mouse and pygame.mouse.get_focused() and not self.hud.overlay_visible
                and self.drag_start is None and self.pan_drag is None and self.hud.chat_text is None):
            e = 4
            if mouse[0] < e:
                vx -= 1
            elif mouse[0] > self.cam.w - 1 - e:
                vx += 1
            if mouse[1] < e:
                vy += 1
            elif mouse[1] > self.cam.h - 1 - e:
                vy -= 1
        if vx or vy:
            l = math.hypot(vx, vy)
            s = 1050 * self.cam.zoom * dt
            self.cam.x += vx / l * s
            self.cam.y += vy / l * s
            self.clamp_camera()
        if self.fx.shake > 0.3:
            self.cam.sx = random.uniform(-1, 1) * self.fx.shake
            self.cam.sy = random.uniform(-1, 1) * self.fx.shake
            self.fx.shake *= 0.004 ** dt
        else:
            self.fx.shake = 0.0
            self.cam.sx = self.cam.sy = 0.0

    def shake(self, amount):
        self.fx.shake = min(14.0, max(self.fx.shake, amount))

    def clamp_camera(self):
        from .hud import PANEL_H, TOP_H
        if self.satellite:
            return                       # parked over the whole map
        z = self.cam.zoom
        hw, hh = self.cam.w * z / 2, self.cam.h * z / 2
        min_x, max_x = hw - 80, defs.WORLD_W - hw + 80
        min_y, max_y = hh - PANEL_H * z - 40, defs.WORLD_H - hh + TOP_H * z + 40
        self.cam.x = defs.WORLD_W / 2 if min_x > max_x else clamp(self.cam.x, min_x, max_x)
        self.cam.y = defs.WORLD_H / 2 if min_y > max_y else clamp(self.cam.y, min_y, max_y)

    def center_camera(self, x, y):
        if self.satellite:
            self.satellite = False
            self._satellite_saved = None
            self.cam.zoom = 1.0
        from .hud import PANEL_H, TOP_H
        self.cam.x = x
        self.cam.y = y - (PANEL_H - TOP_H) / 2 * self.cam.zoom
        self.clamp_camera()

    def toggle_satellite(self):
        """The whole map on screen: the camera pulls back to fit it, and comes back to where it was."""
        from .hud import PANEL_H, TOP_H
        if self.satellite:
            self.satellite = False
            if self._satellite_saved:
                self.cam.x, self.cam.y, self.cam.zoom = self._satellite_saved
            self.clamp_camera()
            return
        self._satellite_saved = (self.cam.x, self.cam.y, self.cam.zoom)
        self.satellite = True
        self.cam.zoom = max(defs.WORLD_W / self.cam.w, defs.WORLD_H / max(1, self.cam.h - PANEL_H - TOP_H)) * 1.03
        self.cam.x = defs.WORLD_W / 2
        self.cam.y = defs.WORLD_H / 2 - (PANEL_H - TOP_H) * self.cam.zoom / 2
        self.hud.flash("Satellite view: Tab returns to the ground", TEXT)

    def zoom(self, f, anchor=None):
        if self.satellite:
            if f >= 1:
                return
            self.toggle_satellite()      # zooming in from orbit brings you back down where you were
            return
        old = self.cam.zoom
        z = clamp(old * f, 0.55, 1.9)
        if abs(z - old) < 1e-4:
            return
        if anchor:
            ax, ay = anchor
            self.cam.x = ax + (self.cam.x - ax) * (z / old)
            self.cam.y = ay + (self.cam.y - ay) * (z / old)
        self.cam.zoom = z
        self.clamp_camera()

    def _on_screen(self, x, y, margin=0):
        v = self.cam.view_rect()
        return v[0] - margin <= x <= v[2] + margin and v[1] - margin <= y <= v[3] + margin

    def jump_camera(self):
        if self._last_alert_pos and self.elapsed - self._last_alert < 12:
            self.center_camera(*self._last_alert_pos)
            self._last_alert_pos = None
        elif self.selection:
            n = len(self.selection)
            self.center_camera(sum(e.x for e in self.selection) / n, sum(e.y for e in self.selection) / n)
        else:
            hq = next((b for b in self.s.buildings if self.mine(b) and b.kind == "hq"), None)
            if hq:
                self.center_camera(hq.x, hq.y)

    # ------------------------------------------------------------ input

    def handle_event(self, e):
        if self.hud.handle_text_event(e):
            return
        shift = bool(pygame.key.get_mods() & pygame.KMOD_SHIFT)
        if e.type == pygame.MOUSEBUTTONDOWN:
            if e.button == 1:
                if pygame.key.get_mods() & pygame.KMOD_CTRL and not self.hud.over_hud(e.pos):
                    self._right_click(e.pos, shift)
                else:
                    self._left_down(e.pos, shift)
            elif e.button == 3:
                self._right_click(e.pos, shift)
            elif e.button == 2:
                self.pan_drag = (e.pos, self.cam.x, self.cam.y)
        elif e.type == pygame.MOUSEBUTTONUP:
            if e.button == 1:
                self._left_up(e.pos, shift)
            elif e.button == 2:
                self.pan_drag = None
        elif e.type == pygame.MOUSEMOTION:
            if self.minimap_dragging:
                self.hud.minimap_drag(e.pos)
            elif self.pan_drag:
                (px, py), cx, cy = self.pan_drag
                self.cam.x = cx - (e.pos[0] - px) * self.cam.zoom
                self.cam.y = cy + (e.pos[1] - py) * self.cam.zoom
                self.clamp_camera()
            elif self.drag_start:
                self.drag_now = e.pos
        elif e.type == pygame.MOUSEWHEEL:
            if not self.hud.overlay_visible:
                mx, my = pygame.mouse.get_pos()
                self.zoom(0.9 if e.y > 0 else 1.1, self.cam.to_world(mx, my))
        elif e.type == pygame.KEYDOWN:
            self._key_down(e)
        elif e.type == pygame.KEYUP:
            self.keys_down.discard(e.key)

    def _blocked(self):
        return (self.paused and self.s.can_pause) or self.s.game_over or self.hud.overlay_visible

    def _left_down(self, pos, shift):
        if self.hud.handle_click(pos, right=False):
            return
        if self._blocked():
            return
        w = self.cam.to_world(*pos)
        if self.placing:
            self._try_place(self.placing, *self.snapped(*w), keep=shift)
            return
        if self.attack_pending:
            self.attack_pending = False
            self.issue_attack_move(*w, queue=shift)
            return
        if self.ping_pending or pygame.key.get_mods() & pygame.KMOD_ALT:
            self.place_ping(*w)
            return
        self.drag_start = self.drag_now = pos

    def _left_up(self, pos, shift):
        if self.minimap_dragging:
            self.minimap_dragging = False
            return
        if not self.drag_start:
            return
        s = self.drag_start
        self.drag_start = self.drag_now = None
        if abs(pos[0] - s[0]) < 6 and abs(pos[1] - s[1]) < 6:
            now = pygame.time.get_ticks()
            lt, lx, ly = self._last_click
            double = now - lt < 350 and abs(lx - pos[0]) < 8 and abs(ly - pos[1]) < 8
            self._last_click = (now, pos[0], pos[1])
            self._click_select(*self.cam.to_world(*pos), shift, double)
        else:
            a, b = self.cam.to_world(*s), self.cam.to_world(*pos)
            self._box_select((min(a[0], b[0]), min(a[1], b[1]), max(a[0], b[0]), max(a[1], b[1])), shift)

    def _right_click(self, pos, shift):
        if self._blocked():
            if self.hud.overlay_visible:
                self.hud.handle_click(pos, right=True)
            return
        if self.placing or self.attack_pending:
            self.cancel_modes()
            return
        if self.hud.handle_click(pos, right=True, queue=shift):
            return
        self.smart_command(*self.cam.to_world(*pos), queue=shift)

    def _key_down(self, e):
        key = e.key
        mods = getattr(e, "mod", 0) | pygame.key.get_mods()
        name = pygame.key.name(key)
        if key in (pygame.K_LEFT, pygame.K_RIGHT, pygame.K_UP, pygame.K_DOWN):
            self.keys_down.add(key)
            return
        if self.s.game_over:
            if key in (pygame.K_RETURN, pygame.K_KP_ENTER):
                self.restart()
            elif key == pygame.K_ESCAPE:
                self.to_menu()
            return
        if key == pygame.K_ESCAPE:
            if self.placing or self.attack_pending or self.ping_pending:
                self.cancel_modes()
            elif self.hud.overlay_visible:
                self.hud.clear_overlay()
                self.paused = False
            elif self.selection:
                self.set_selection([])
            else:
                self.toggle_pause()
            return
        if key in (pygame.K_RETURN, pygame.K_KP_ENTER) and self.online and not self.hud.overlay_visible:
            self.hud.chat_text = ""
            return
        if name == "p" or key == pygame.K_PAUSE:
            self.toggle_pause()
            return
        if name in ("h", "/", "?") or key == pygame.K_F1:
            self.toggle_help()
            return
        if name == "y" and not self.s.game_over:
            self.toggle_store()
            return
        if key == pygame.K_F5 and self.can_save():
            self.save_game("quicksave", "Quick save")
            return
        if key == pygame.K_F9 and self.can_save():
            self.load_game("quicksave")
            return
        if self._blocked():
            return
        if key == pygame.K_TAB:
            self.toggle_satellite()
        elif key == pygame.K_SPACE:
            if self.satellite:
                self.toggle_satellite()
            self.jump_camera()
        elif name in ("=", "+", "[+]"):
            self.zoom(0.9)
        elif name in ("-", "[-]"):
            self.zoom(1.1)
        elif name == "o":
            settings.toggle("objectives")
        elif key == pygame.K_F2 or name == "`":
            self.select_army()
        elif name.isdigit() and len(name) == 1:
            d = int(name)
            if mods & pygame.KMOD_CTRL:
                own = [x for x in self.selection if self.mine(x)]
                self.control_groups[d] = own
                self.group_of = {x.id: gn for gn, xs in self.control_groups.items() for x in xs if not x.is_building}
                self.hud.flash(f"Group {d} assigned ({len(own)})", TEXT)
            elif self.control_groups.get(d):
                self.set_selection([x for x in self.control_groups[d] if not x.dead])
                now = pygame.time.get_ticks()
                g, t = self._last_group_tap
                if g == d and now - t < 400:
                    self.jump_camera()
                self._last_group_tap = (d, now)
        elif name in ("i", "."):
            self.select_idle_worker()
        elif name == "z":
            self.begin_ping(1 if mods & pygame.KMOD_SHIFT else 0)
        else:
            self.hud.current_buttons = self.command_buttons()  # selection may have changed this frame
            for i, b in enumerate(self.hud.current_buttons):
                if b.hotkey.lower() == name:
                    self.hud.press_button(i)
                    break

    # ------------------------------------------------------------ hover & cursor

    def _update_hover(self, mouse):
        target, crystal, bridge, crate = None, None, None, None
        active = mouse and not self.hud.overlay_visible and self.drag_start is None and self.placing is None
        if active and not self.hud.over_hud(mouse):
            wx, wy = self.cam.to_world(*mouse)
            target = self.entity_at(wx, wy)
            if target is None and self.s.fog.is_explored(wx, wy):
                crystal = self.s.crystal_at(wx, wy)
                crate = self.crate_at(wx, wy)
            if target is None and crystal is None:
                bridge = self.bridge_at(wx, wy)
            if target is None and crystal is None and bridge is None:
                bridge = self.tower_at(wx, wy)
        self._hover_crate = crate
        hover = target or bridge
        if hover is not self.hovered:
            if self.hovered:
                self.hovered.hovered = False
            if hover:
                hover.hovered = True
            self.hovered = hover
        if mouse and target:
            color = TEXT if self.mine(target) else (TEAM_LIGHT[target.team] if self.friendly(target) else BAD)
            label = f"{target.name}  {math.ceil(target.hp)}/{int(target.max_hp)}"
            menders = self._menders(self.selected_own_units(), target)
            if menders:
                label += "    right-click to repair" if menders[0].kind == "worker" else "    right-click to treat"
            self.hud.set_hover(label, color, mouse)
        elif mouse and crate:
            self.hud.set_hover("Supply crate — walk any unit onto it", AMBER, mouse)
        elif mouse and crystal:
            if crystal.gold:
                self.hud.set_hover(f"Gold deposit  {crystal.amount}  (a hundred fields' worth)", AMBER, mouse)
            else:
                self.hud.set_hover(f"Crystal  {crystal.amount}", CRYSTAL, mouse)
        elif mouse and bridge and getattr(bridge, "name", "") == "Watchtower":
            t = bridge
            if t.owner is None:
                who = "unclaimed"
            elif self.mine_slot(t.owner):
                who = "yours"
            else:
                who = f"held by {self.s.players[t.owner].name}"
            hint = f"    {self.s.players[t.capturing].name} taking it {int(t.progress * 100)}%" if t.capturing is not None else ""
            self.hud.set_hover(f"Watchtower — {who}: stand troops inside its ring for 8s to take it{hint}",
                               TEAM_LIGHT[t.owner] if t.owner is not None else DIM, mouse)
        elif mouse and bridge:
            if bridge.intact:
                self.hud.set_hover(f"Bridge  {math.ceil(bridge.hp)}/{int(bridge.max_hp)}    A then click to demolish",
                                   AMBER, mouse)
            else:
                self.hud.set_hover(f"Bridge down    Engineer + right-click to rebuild ({BRIDGE_COST})", DIM, mouse)
        else:
            self.hud.set_hover(None, TEXT, mouse)

        kind = None
        if mouse and not self.hud.over_hud(mouse) and not self.hud.overlay_visible:
            own = self.selected_own_units()
            if self.attack_pending or self.ping_pending:
                kind = "attack"
            elif own and self.placing is None:
                if target and not self.friendly(target):
                    kind = "attack"
                elif crystal and any(u.kind == "worker" for u in own):
                    kind = "gather"
                elif target and self._menders(own, target):
                    kind = "gather"      # the work cursor: this Engineer can mend it, or this Medic treat it
                elif bridge is not None and not bridge.intact and any(u.kind == "worker" for u in own):
                    kind = "gather"      # the build cursor: this Engineer can put the crossing back
        if kind != self._cursor:
            self._cursor = kind
            cur = art.cursors().get(kind) if kind else None
            try:
                pygame.mouse.set_cursor(cur if cur else pygame.SYSTEM_CURSOR_ARROW)
            except (pygame.error, TypeError):
                pass

    # ------------------------------------------------------------ selection

    def set_selection(self, es):
        for e in self.selection:
            e.selected = False
        self.selection = [e for e in es if not e.dead]
        for e in self.selection:
            e.selected = True
        self.hud.selection_changed()

    def _click_select(self, x, y, shift, double):
        e = self.entity_at(x, y)
        if e is None:
            if not shift:
                self.set_selection([])
            return
        if double and self.mine(e):
            v = self.cam.view_rect()
            pool = self.s.buildings if e.is_building else self.s.units
            self.set_selection([o for o in pool if self.mine(o) and o.kind == e.kind and v[0] <= o.x <= v[2] and v[1] <= o.y <= v[3]])
            return
        if shift and self.mine(e) and all(self.mine(s) for s in self.selection):
            if e in self.selection:
                self.set_selection([s for s in self.selection if s is not e])
            else:
                self.set_selection(self.selection + [e])
        else:
            self.set_selection([e])

    def _box_select(self, r, shift):
        us = [u for u in self.s.units if self.mine(u) and r[0] - u.radius <= u.x <= r[2] + u.radius
              and r[1] - u.radius <= u.y <= r[3] + u.radius]
        if us:
            if shift:
                self.set_selection([s for s in self.selection if self.mine(s)] + [u for u in us if u not in self.selection])
            else:
                self.set_selection(us)
            return
        bs = [b for b in self.s.buildings if self.mine(b) and rects_intersect(r, b.rect)]
        if bs:
            self.set_selection([b for b in bs if b.kind == bs[0].kind])
        elif not shift:
            self.set_selection([])

    def select_idle_worker(self):
        idle = self.idle_workers()
        if not idle:
            self.hud.flash("No idle engineers", DIM)
            return
        self._idle_cycle = (self._idle_cycle + 1) % len(idle)
        w = idle[self._idle_cycle]
        self.set_selection([w])
        self.center_camera(w.x, w.y)

    def select_army(self):
        a = self.army()
        if not a:
            self.hud.flash("You have no combat units yet", DIM)
            return
        self.set_selection(a)

    def selected_own_units(self):
        return [e for e in self.selection if not e.is_building and self.mine(e) and not e.dead]

    def selected_own_buildings(self):
        return [e for e in self.selection if e.is_building and self.mine(e) and not e.dead]

    def _repairable(self, e):
        """An Engineer can mend it: a finished friendly building, or a friendly Siege Tank, below full health."""
        if e.dead or e.hp >= e.max_hp or not self.friendly(e):
            return False
        return e.built if e.is_building else e.kind == "tank"

    def _treatable(self, e):
        """A Medic can treat it: a friendly unit on foot below full health."""
        return not e.is_building and not e.dead and e.kind != "tank" and e.hp < e.max_hp and self.friendly(e)

    def _menders(self, us, target):
        """The selected units that can mend `target` (Engineers) or treat it (Medics)."""
        out = []
        if self._repairable(target):
            out += [u for u in us if u.kind == "worker"]
        if self._treatable(target):
            out += [u for u in us if u.kind == "medic" and u is not target]
        return out

    def crate_at(self, x, y):
        for c in getattr(self.s, "crates", ()):
            if not c.dead and math.hypot(c.x - x, c.y - y) < c.radius + 8 and self.s.fog.is_visible(c.x, c.y):
                return c
        return None

    def tower_at(self, x, y):
        for t in getattr(self.s, "towers", ()):
            r = t.rect
            if r[0] - 6 <= x <= r[2] + 6 and r[1] - 6 <= y <= r[3] + 6:
                return t
        return None

    def mine_slot(self, slot):
        return slot == self.s.slot

    def bridge_at(self, x, y, slack=0.0):
        for b in getattr(self.s, "bridges", ()):
            r = b.rect
            if r[0] - slack <= x <= r[2] + slack and r[1] - slack <= y <= r[3] + slack:
                return b
        return None

    def entity_at(self, x, y):
        best, best_d = None, 1e9
        for u in self.s.units:
            if u.dead or not self.s.shown(u):
                continue
            d = math.hypot(u.x - x, u.y - y)
            if d < u.radius + 6 and d < best_d:
                best, best_d = u, d
        if best:
            return best
        for b in self.s.buildings:
            if not b.dead and self.s.shown(b):
                r = b.rect
                if r[0] - 2 <= x <= r[2] + 2 and r[1] - 2 <= y <= r[3] + 2:
                    return b
        return None

    # ------------------------------------------------------------ commands (sent to the session)

    @staticmethod
    def _ids(es):
        return [e.id for e in es]

    def smart_command(self, x, y, queue=False):
        us = self.selected_own_units()
        send = self.s.send
        if us:
            br = self.bridge_at(x, y)
            if br is not None and not br.intact:
                workers = [u for u in us if u.kind == "worker"]
                if workers:
                    send(["rebuild", workers[0].id, br.id, queue])
                    self.fx.ring(br.x, br.y, 34, 8, AMBER)
                    rest = [u for u in us if u.kind != "worker"]
                    if rest:
                        send(["move", self._ids(rest), x, y, queue, False])
                    return
            # A standing bridge is a road: right-click walks across it. Demolition is deliberate — A then click.
            t = self.entity_at(x, y)
            if t and not self.friendly(t):
                send(["attack", self._ids(us), t.id, queue])
                self.fx.ring(t.x, t.y, 26, 6, BAD)
                return
            c = self.s.crystal_at(x, y) if self.s.fog.is_explored(x, y) else None
            if c:
                send(["gather", self._ids(us), c.id, queue])
                self.fx.ring(c.x, c.y, 26, 6, CRYSTAL)
                return
            if t is not None:
                menders = self._menders(us, t)
                if menders:
                    send(["repair", self._ids(menders), t.id, queue])
                    self.fx.ring(t.x, t.y, (t.half if t.is_building else t.radius) + 10, 8, AMBER)
                    rest = [u for u in us if u not in menders]
                    if rest:
                        send(["move", self._ids(rest), x, y, queue, False])
                    return
            if t is not None and t.is_building and self.mine(t) and t.kind == "hq" and t.built:
                carriers = [u for u in us if u.kind == "worker" and u.carrying]
                rest = [u for u in us if u not in carriers]
                if carriers:
                    send(["return", self._ids(carriers), queue])
                if rest:
                    send(["move", self._ids(rest), x, y, queue, False])
                return
            send(["move", self._ids(us), x, y, queue, False])
            self.fx.ring(x, y, 18, 4, GOOD)
            return
        producers = [b for b in self.selected_own_buildings() if b.stats.produces]
        if producers:
            send(["rally", self._ids(producers), x, y])
            self.fx.ring(x, y, 18, 4, GOOD)

    def issue_attack_move(self, x, y, queue=False):
        us = self.selected_own_units()
        if not us:
            return
        br = self.bridge_at(x, y)
        if br is not None and br.intact:
            armed = [u for u in us if u.kind != "worker"]
            if armed:
                self.s.send(["attack", self._ids(armed), br.id, queue])
                self.fx.ring(br.x, br.y, 34, 8, BAD)
                self.hud.flash("Demolishing the bridge", BAD)
                return
        t = self.entity_at(x, y)
        if t and not self.friendly(t):
            self.s.send(["attack", self._ids(us), t.id, queue])
            self.fx.ring(t.x, t.y, 26, 6, BAD)
        else:
            self.s.send(["move", self._ids(us), x, y, queue, True])
            self.fx.ring(x, y, 18, 4, BAD)

    def stop_selected(self):
        self.s.send(["stop", self._ids(self.selected_own_units())])

    def cancel_modes(self):
        self.placing = None
        self.attack_pending = False
        self.ping_pending = False

    def begin_placement(self, kind):
        s = BUILDINGS[kind]
        if s.requires and not self.s.has_built(s.requires):
            self.hud.flash(f"Requires {BUILDINGS[s.requires].name}", BAD)
            return
        if self.s.resources < s.cost:
            self.hud.flash("Not enough crystal", BAD)
            return
        self.attack_pending = False
        self.placing = kind
        self.hud.flash(f"Place {s.name}: click to build · Shift to place several · right-click to cancel", TEXT)

    @staticmethod
    def snapped(x, y):
        return (round(x / 16) * 16, round(y / 16) * 16)

    def _try_place(self, kind, x, y, keep):
        if not self.s.fog.is_explored(x, y):
            self.hud.flash("Can't build in unexplored territory", BAD)
            return
        if not self.s.can_place(kind, x, y):
            self.hud.flash("Can't build there", BAD)
            return
        cost = BUILDINGS[kind].cost
        if self.s.resources < cost:
            self.hud.flash("Not enough crystal", BAD)
            self.cancel_modes()
            return
        workers = [u for u in self.selected_own_units() if u.kind == "worker"]
        if not workers:
            self.cancel_modes()
            return
        builder = min(workers, key=lambda w: math.hypot(w.x - x, w.y - y))
        lb = self._last_builder
        if keep and lb is not None and not lb.dead and lb in workers:
            builder = lb
        self.s.send(["build", builder.id, kind, x, y, keep])
        self._last_builder = builder
        self.fx.ring(x, y, BUILDINGS[kind].half, 10, AMBER)
        if not keep or self.s.resources - cost < cost:
            self.cancel_modes()

    def train(self, kind):
        self.s.send(["train", self._ids(self.selected_own_buildings()), kind])

    def upgrade(self, kind):
        bs = [b for b in self.selected_own_buildings() if b.can_upgrade(kind)]
        if bs:
            self.s.send(["upgrade", self._ids(bs), kind])
            audio.play("click")

    def cancel_upgrade(self, b):
        self.s.send(["cancelup", b.id])

    def siege(self, on):
        tanks = [u for u in self.selected_own_units() if u.can_siege]
        if tanks:
            self.s.send(["siege", self._ids(tanks), on])
            audio.play("click")

    def cancel_queue(self, b, index):
        self.s.send(["cancel", b.id, index])

    def command_buttons(self):
        us = self.selected_own_units()
        if us:
            def attack():
                self.cancel_modes()
                self.attack_pending = True
                self.hud.flash("Attack: click a location or target", TEXT)
            out = [CommandButton(("attack",), "Attack", "A", None, True,
                                 "Attack-move: units engage any enemy they meet on the way. Shift+click to queue.", attack),
                   CommandButton(("stop",), "Stop", "S", None, True, "Halt all current and queued orders.", self.stop_selected)]
            tanks = [u for u in us if u.can_siege]
            if tanks:
                # One button for the whole selection: it digs in unless every tank is already dug in.
                on = not all(u.sieged for u in tanks)
                tip = ("Dig in: cannot move, but fires further (340) and harder, with a blind spot inside 90.\n"
                       "Takes 2.5 seconds either way. A move order packs the tank up again." if on
                       else "Pack up and become mobile again. Takes 2.5 seconds.")
                out.append(CommandButton(("siege", on), "Siege" if on else "Unsiege", "G", None, True, tip,
                                         lambda on=on: self.siege(on)))
            if any(u.kind == "worker" for u in us):
                for k in BUILD_MENU:
                    s = BUILDINGS[k]
                    ok = s.requires is None or self.s.has_built(s.requires)
                    tip = s.desc + ("" if ok else f"\nRequires {BUILDINGS[s.requires].name}.")
                    out.append(CommandButton(("building", k), s.short, s.hotkey, s.cost, ok, tip,
                                             lambda k=k: self.begin_placement(k)))
            return out
        bs = [b for b in self.selected_own_buildings() if b.built]
        if bs:
            # A mixed selection (say a Barracks and a Factory) shows every button any of them offers: training
            # goes to the buildings that can do it, upgrades to the ones they apply to. The card is never blank.
            kinds = []
            for b in bs:
                if b.kind not in kinds:
                    kinds.append(b.kind)
            produces = [k for bk in kinds for k in BUILDINGS[bk].produces]
            produces = list(dict.fromkeys(produces))
            out = []
            for k in produces:
                s = UNITS[k]
                ok = s.requires is None or self.s.has_built(s.requires)
                tip = (f"{s.desc}\nSupply {s.supply} · {int(s.build_time)}s build time.\n"
                       "Right-click the map to set a rally point.")
                if not ok:
                    tip += f"\nRequires {BUILDINGS[s.requires].name}."
                out.append(CommandButton(("unit", k), s.name, s.hotkey, s.cost, ok, tip,
                                         lambda k=k: self.train(k)))
            for k in UPGRADE_KINDS:
                u = UPGRADES[k]
                targets = [b for b in bs if upgrade_applies(k, b.kind)]
                if not targets:
                    continue
                cost = upgrade_cost(k, targets[0].kind)
                installed = all(k in b.upgrades for b in targets)
                busy = any(b.upgrading is not None for b in targets) and not installed
                ok = not installed and any(b.can_upgrade(k) for b in targets)
                tip = f"{u.name}: {u.desc}\n{int(u.time)}s to research; this building only."
                if len(targets) > 1:
                    tip += f"\nApplies to {len(targets)} selected buildings, one price each."
                if installed:
                    tip += "\nAlready installed."
                elif busy:
                    tip += "\nAlready researching something."
                out.append(CommandButton(("upgrade", k), u.button, u.hotkey, None if installed else cost, ok, tip,
                                         lambda k=k: self.upgrade(k)))
            return out
        return []

    # ------------------------------------------------------------ rendering

    def draw(self, screen, mouse):
        cam = self.cam
        z = cam.zoom
        s = self.s
        screen.fill((8, 10, 13))
        self._draw_ground(screen)
        self.fx.draw_decals(screen, cam)
        v = cam.view_rect()
        m = 240      # a Command Center is 160 across plus its shadow; anything nearer the edge than this still shows

        def visible(x, y):
            return v[0] - m < x < v[2] + m and v[1] - m < y < v[3] + m

        ts = 1 / (art.SCALE * z)
        units = [u for u in s.units if visible(u.x, u.y) and s.shown(u)]
        buildings = [b for b in s.buildings if visible(b.x, b.y) and s.shown(b)]
        for e in units + buildings:
            if e.selected or e.hovered:
                if self.mine(e):
                    col = to255(GOOD) if e.selected else (255, 255, 255)
                elif self.friendly(e):
                    col = to255(TEAM_LIGHT[e.team])
                else:
                    col = to255(BAD)
                if e.is_building:
                    base, size = (art.ring() if e.kind in ("turret", "artillery") else art.square_ring()), e.half * 2 + 22
                else:
                    base, size = art.ring(), e.radius * 2 + 12
                img = art.sprites.get(("ring", col), base, 0, size / (64 * art.SCALE) / z, tint=(*col, 255),
                                      fade=255 if e.selected else 150)
                sx, sy = cam.to_screen(e.x, e.y)
                screen.blit(img, (sx - img.get_width() / 2, sy - img.get_height() / 2))
        for b in getattr(s, "bridges", ()):
            if visible(b.x, b.y):
                self._draw_bridge(screen, b, z)
        for t in getattr(s, "towers", ()):
            if visible(t.x, t.y):
                self._draw_tower(screen, t, z, ts)
        for c in getattr(s, "crates", ()):
            if visible(c.x, c.y) and s.fog.is_visible(c.x, c.y):
                self._draw_crate(screen, c, z, ts)
        glow_px = int(90 / z)
        for c in s.crystals:
            if not visible(c.x, c.y) or not s.fog.is_explored(c.x, c.y):
                continue
            sx, sy = cam.to_screen(c.x, c.y)
            level = int(3 + 2 * math.sin(self.elapsed * 1.6 + c.phase))
            g = self.fx._glow(glow_px, (102, 235, 255), max(1, level))
            screen.blit(g, (sx - g.get_width() / 2, sy - g.get_height() / 2), special_flags=pygame.BLEND_ADD)
            sh = art.sprites.get("shadow", art.shadow(), 0, 50 / 64 / z)
            screen.blit(sh, (sx + 5 / z - sh.get_width() / 2, sy + 10 / z - sh.get_height() / 2))
            base = art.crystal(c.variant)
            if c.flip:
                base = art._cache.setdefault(("crystal_flip", c.variant), pygame.transform.flip(base, True, False))
            img = art.sprites.get(("crystal", c.variant, c.flip), base, 0, ts * c.scale)
            screen.blit(img, (sx - img.get_width() / 2, sy - 6 * c.scale / z - img.get_height() / 2))
        # Far to near: what is lower on screen is nearer the camera and draws last, over what stands behind it.
        for e in sorted(buildings + units, key=lambda e: -e.y):
            if e.is_building:
                self._draw_building(screen, e, ts)
            else:
                self._draw_unit(screen, e, ts)
        for (x, y, r, var, ang, sc) in self.obstacles:
            if visible(x, y):
                img = art.sprites.get(("tree", var), art.tree(var), ang, ts * sc)
                sx, sy = cam.to_screen(x, y)
                screen.blit(img, (sx - img.get_width() / 2, sy - img.get_height() / 2))
        for sh in self.shells:
            big = sh[8]
            g = self.fx._glow(int((26 if big else 16) / z), (255, 216, 115), 8)
            sx, sy = cam.to_screen(sh[6], sh[7])
            screen.blit(g, (sx - g.get_width() / 2, sy - g.get_height() / 2), special_flags=pygame.BLEND_ADD)
            if big:
                pygame.draw.circle(screen, (60, 50, 40), (int(sx), int(sy)), max(2, int(4 / z)))     # the shell itself
        self.fx.draw(screen, cam, ui.text)
        for e in units + buildings:
            self._draw_bars(screen, e)
        self._draw_clouds(screen)
        if self.satellite:
            self._draw_satellite_markers(screen, units, buildings)
        self.fog_view.draw(screen, cam)
        self._draw_beacons(screen)
        self._draw_overlays(screen, mouse)
        screen.blit(art.vignette(cam.w * 1.1, cam.h * 1.1), (-cam.w * 0.05, -cam.h * 0.05))
        self.hud.draw(screen, mouse)

    def _draw_ground(self, screen):
        cam = self.cam
        v = cam.view_rect()
        x0, y0 = max(0, v[0]), max(0, v[1])
        x1, y1 = min(defs.WORLD_W, v[2]), min(defs.WORLD_H, v[3])
        if x1 <= x0 or y1 <= y0:
            return
        ix0, iy0 = int(x0), int(defs.WORLD_H - y1)
        iw = min(int(x1 - x0), int(defs.WORLD_W) - ix0)
        ih = min(int(y1 - y0), int(defs.WORLD_H) - iy0)
        if iw <= 0 or ih <= 0:
            return
        sx, sy = cam.to_screen(ix0, defs.WORLD_H - iy0)
        tw, th = int(round(iw / cam.zoom)), int(round(ih * TILT / cam.zoom))
        key = (ix0, iy0, iw, ih, tw, th)
        if key != self._ground_key:
            sub = self.ground.subsurface((ix0, iy0, iw, ih))
            self._ground_view = sub if (tw, th) == (iw, ih) else pygame.transform.smoothscale(sub, (max(1, tw), max(1, th)))
            self._ground_key = key
        screen.blit(self._ground_view, (int(round(sx)), int(round(sy))))

    def _draw_bridge(self, screen, b, z):
        """Deck when it stands, pilings and a progress bar when it does not."""
        cam = self.cam
        x0, y0, x1, y1 = b.rect
        w, h = int(x1 - x0), int(y1 - y0)
        # bridge_patch/bridge_ruins render 1:1 with world units (not at art.SCALE) and carry a margin
        # on every side, so the sprite scales by 1/zoom and is offset by that margin.
        m = art.TERRAIN_MARGIN / z
        sx, sy = cam.to_screen(x0, y1)              # top-left corner of the span on screen
        if b.intact:
            img = art.sprites.get(("bridge", b.id), art.bridge_patch(w, h, b.id + 7), 0, 1 / z)
        else:
            img = art.sprites.get(("bridgeruin", b.id), art.bridge_ruins(w, h, b.id + 7), 0, 1 / z)
        screen.blit(img, (sx - m, sy - m))
        cx, cy = cam.to_screen(b.x, b.y)
        if b.intact and b.hp < b.max_hp:
            self._draw_bar(screen, cx, cy - (y1 - y0) / 2 / z - 10, 70 / z, b.hp / b.max_hp, GOOD)
        elif not b.intact and b.progress > 0:
            self._draw_bar(screen, cx, cy, 70 / z, b.progress, AMBER)
        if b.hovered:
            col = to255(AMBER if b.intact else DIM)
            ring = art.sprites.get(("bridgering", b.id, col), art.square_ring(), 0,
                                   (max(w, h) + 18) / (64 * art.SCALE) / z, tint=(*col, 255), fade=170)
            screen.blit(ring, (cx - ring.get_width() / 2, cy - ring.get_height() / 2))

    def _draw_crate(self, screen, c, z, ts):
        """The crate bobs a little and its beacon glows so it catches the eye from across the field."""
        cam = self.cam
        sx, sy = cam.to_screen(c.x, c.y)
        sh = art.sprites.get("shadow", art.shadow(), 0, 46 / 64 / z)
        screen.blit(sh, (sx + 4 / z - sh.get_width() / 2, sy + 5 / z - sh.get_height() / 2))
        g = self.fx._glow(int(70 / z), (255, 170, 80), 3 + int(2 * math.sin(self.elapsed * 4 + c.id)))
        screen.blit(g, (sx - g.get_width() / 2, sy - g.get_height() / 2), special_flags=pygame.BLEND_ADD)
        bob = math.sin(self.elapsed * 2.5 + c.id) * 2 / z
        img = art.sprites.get("crate", art.crate(), (c.id * 37) % 360, ts)
        screen.blit(img, (sx - img.get_width() / 2, sy - bob - img.get_height() / 2))
        if c is getattr(self, "_hover_crate", None):
            ring = art.sprites.get(("ring", (255, 255, 255)), art.ring(), 0, (c.radius * 2 + 12) / (64 * art.SCALE) / z,
                                   tint=(255, 255, 255, 255), fade=170)
            screen.blit(ring, (sx - ring.get_width() / 2, sy - ring.get_height() / 2))

    def _draw_tower(self, screen, t, z, ts):
        """The tower, its holder's banner, and the capture ring while someone is taking it."""
        cam = self.cam
        sx, sy = cam.to_screen(t.x, t.y)
        sh = art.sprites.get("shadow", art.shadow(), 0, 70 / 64 / z)
        screen.blit(sh, (sx + 6 / z - sh.get_width() / 2, sy + 8 / z - sh.get_height() / 2))
        img = art.sprites.get(("watchtower", t.owner), art.watchtower(t.owner), 0, ts)
        screen.blit(img, (sx - img.get_width() / 2, sy - img.get_height() / 2))
        if t.capturing is not None and t.progress > 0:
            col = to255(TEAM_LIGHT[t.capturing])
            r = int(TOWER_RADIUS / z)
            pygame.draw.circle(screen, (*col[:3],), (int(sx), int(sy)), r, 1)
            end = -math.pi / 2 + 2 * math.pi * t.progress
            pygame.draw.arc(screen, col, (int(sx - r), int(sy - r), 2 * r, 2 * r), -end, math.pi / 2, 4)
            self._draw_bar(screen, sx, sy + 40 / z, 60 / z, t.progress, TEAM_LIGHT[t.capturing])
        if t.hovered:
            col = to255(TEAM_LIGHT[t.owner]) if t.owner is not None else (200, 200, 200)
            ring = art.sprites.get(("towerring", col), art.square_ring(), 0, (t.half * 2 + 22) / (64 * art.SCALE) / z,
                                   tint=(*col, 255), fade=170)
            screen.blit(ring, (sx - ring.get_width() / 2, sy - ring.get_height() / 2))

    def _draw_bar(self, screen, cx, cy, width, frac, color):
        w = max(12, int(width))
        x, y = int(cx - w / 2), int(cy)
        pygame.draw.rect(screen, (8, 10, 12), (x - 1, y - 1, w + 2, 6))
        pygame.draw.rect(screen, to255(color), (x, y, int(w * max(0.0, min(1.0, frac))), 4))

    def _draw_building(self, screen, b, ts):
        cam = self.cam
        z = cam.zoom
        sx, sy = cam.to_screen(b.x, b.y)
        sh = art.sprites.get("shadow", art.shadow(), 0, b.half * 2.6 / 64 / z)
        screen.blit(sh, (sx + 8 / z - sh.get_width() / 2, sy + 10 / z - sh.get_height() / 2))
        fade = 255 if b.built else int(90 + 140 * b.progress) // 16 * 16
        img = art.sprites.get(("bld", b.kind, b.team), art.building(b.kind, b.team), 0, ts, fade=fade)
        # The walls: the tilt shows a building's height as dark slices of its own outline stacked below the roof.
        if b.built:
            wall_h = b.half * (0.28 if b.kind in ("turret", "artillery", "shield") else 0.45) * TILT / z
            slices = max(2, int(wall_h / 3))
            wall = art.sprites.get(("bldwall", b.kind, b.team), art.building(b.kind, b.team), 0, ts, tint=(14, 16, 20, 200), fade=235)
            for i in range(slices, 0, -1):
                dy = wall_h * i / slices
                screen.blit(wall, (sx + dy * 0.18 - wall.get_width() / 2, sy + dy - wall.get_height() / 2))
        screen.blit(img, (sx - img.get_width() / 2, sy - img.get_height() / 2))
        if getattr(b, "_flash", 0.0) > 0:
            hit = art.sprites.get(("bld", b.kind, b.team), art.building(b.kind, b.team), 0, ts, fade=110)
            screen.blit(hit, (sx - hit.get_width() / 2, sy - hit.get_height() / 2), special_flags=pygame.BLEND_ADD)
        if b.kind == "hq" and b.built:
            d = art.sprites.get("dish", art.dish(), math.degrees(getattr(b, "dish_angle", 0.0)), ts)
            screen.blit(d, (sx - d.get_width() / 2, sy - d.get_height() / 2))
        if b.kind == "turret":
            g = art.sprites.get(("tgun", b.team), art.turret_gun(b.team), math.degrees(b.gun_angle), ts, fade=fade)
            screen.blit(g, (sx - g.get_width() / 2, sy - g.get_height() / 2))
        if b.kind == "artillery":
            g = art.sprites.get(("agun", b.team), art.artillery_gun(b.team), math.degrees(b.gun_angle), ts, fade=fade)
            screen.blit(g, (sx - g.get_width() / 2, sy - g.get_height() / 2))
        if b.kind == "hq" and "defense" in b.upgrades:
            g = art.sprites.get(("hqgun", b.team), art.turret_gun(b.team), math.degrees(b.gun_angle), ts * 0.85, fade=fade)
            screen.blit(g, (sx - g.get_width() / 2, sy - g.get_height() / 2))
        if b.kind == "shield" and b.built:
            pulse = 0.55 + 0.25 * math.sin(self.elapsed * 3 + b.id)
            d = art.sprites.get(("dome", b.team), art.shield_dome(b.team), 0, ts, fade=int(255 * pulse))
            screen.blit(d, (sx - d.get_width() / 2, sy - d.get_height() / 2))
        if b.kind == "radar" and b.built:
            d = art.sprites.get(("rdish", b.team), art.radar_dish(b.team), math.degrees(b.gun_angle), ts)
            screen.blit(d, (sx - d.get_width() / 2, sy - d.get_height() / 2))
        if not b.built:
            s = art.sprites.get(("scaffold", b.half), art.scaffold(b.half), 0, ts)
            screen.blit(s, (sx - s.get_width() / 2, sy - s.get_height() / 2))

    def _draw_unit(self, screen, u, ts):
        cam = self.cam
        z = cam.zoom
        sx, sy = cam.to_screen(u.x, u.y)
        sh = art.sprites.get("shadow", art.shadow(), 0, u.radius * 2.8 / 64 / z)
        screen.blit(sh, (sx + 3 / z - sh.get_width() / 2, sy + 4 / z - sh.get_height() / 2))
        ca, sa = math.cos(u.angle), math.sin(u.angle)
        bob = -1.5 * u.recoil if u.kind == "marine" else (1.5 * u.pulse if u.kind == "worker" else 0.0)
        bx, by = sx + ca * bob / z, sy - sa * bob / z
        mode = getattr(u, "mode", 0)
        if u.kind == "tank" and mode != 0:
            # Outriggers fold out over the transition and stay out while sieged.
            timer = getattr(u, "mode_timer", 0.0)
            k = 1.0 if mode == 2 else (1 - timer / 2.5 if mode == 1 else timer / 2.5)
            legs = art.sprites.get(("outriggers", u.team), art.tank_outriggers(u.team), math.degrees(u.angle),
                                   ts * max(0.35, k))
            screen.blit(legs, (sx - legs.get_width() / 2, sy - legs.get_height() / 2))
        img = art.sprites.get(("unit", u.kind, u.team), art.unit(u.kind, u.team), math.degrees(u.angle), ts)
        screen.blit(img, (bx - img.get_width() / 2, by - img.get_height() / 2))
        if getattr(u, "_flash", 0.0) > 0:
            # Just hit: the same sprite added on top whitens it for a few frames
            hit = art.sprites.get(("unit", u.kind, u.team), art.unit(u.kind, u.team), math.degrees(u.angle), ts, fade=150)
            screen.blit(hit, (bx - hit.get_width() / 2, by - hit.get_height() / 2), special_flags=pygame.BLEND_ADD)
        if u.kind == "tank":
            rc = -4 * u.recoil
            gx, gy = sx + math.cos(u.gun_angle) * rc / z, sy - math.sin(u.gun_angle) * rc / z
            t = art.sprites.get(("turret", u.team), art.tank_turret(u.team), math.degrees(u.gun_angle), ts)
            screen.blit(t, (gx - t.get_width() / 2, gy - t.get_height() / 2))
        elif u.kind == "worker" and u.carrying:
            c = art.sprites.get("cicon", art.crystal_icon(), 0, 10 / 20 / z)
            screen.blit(c, (bx - ca * 9 / z - c.get_width() / 2, by + sa * 9 / z - c.get_height() / 2))
        rank = getattr(u, "rank", 0)
        if rank:
            ch = art.sprites.get(("chevrons", rank, u.team), art.chevrons(rank, u.team), 0, 1 / z)
            screen.blit(ch, (sx - ch.get_width() / 2, sy - (u.radius + 16) / z - ch.get_height() / 2))
        gn = self.group_of.get(u.id)
        if gn is not None:
            # The control group's number rides on the unit's shoulder, in a small plate
            badge = art.sprites.get(("gbadge", gn), art.group_badge(gn), 0, 1 / z)
            screen.blit(badge, (sx + (u.radius + 4) / z - badge.get_width() / 2, sy + (u.radius + 4) / z - badge.get_height() / 2))

    def _draw_bars(self, screen, e):
        cam = self.cam
        z = cam.zoom
        frac = max(0.0, min(1.0, e.hp / e.max_hp))
        building = e.is_building
        width = (max(44, e.half * 1.6) if building else max(22, e.radius * 2.2)) / z
        if e.selected or e.hovered or frac < 0.999 or (settings.bars_always and self.friendly(e)):
            bx, by = cam.to_screen(e.x, e.y + ((e.half + 12) if building else (e.radius + 10)))
            pygame.draw.rect(screen, (0, 0, 0), (bx - width / 2 - 1, by - 2.5, width + 2, 5))
            col = to255(GOOD if frac > 0.6 else AMBER if frac > 0.3 else BAD)
            pygame.draw.rect(screen, col, (bx - width / 2, by - 1.5, width * frac, 3))
        if building and getattr(e, "shield", 0) > 0:
            # The shield sits above the health bar, in field blue
            sfrac = max(0.0, min(1.0, e.shield / SHIELD_MAX))
            bx, by = cam.to_screen(e.x, e.y + e.half + 19)
            pygame.draw.rect(screen, (0, 0, 0), (bx - width / 2 - 1, by - 2.5, width + 2, 5))
            pygame.draw.rect(screen, (110, 215, 255), (bx - width / 2, by - 1.5, width * sfrac, 3))
        if building and self.friendly(e):
            p = None
            if not e.built:
                p, col = e.progress, to255(AMBER)
            elif e.queue:
                p, col = e.queue_progress, to255(CRYSTAL)
            if p is not None:
                w = e.half * 1.6 / z
                bx, by = cam.to_screen(e.x, e.y - e.half - 10)
                pygame.draw.rect(screen, (0, 0, 0), (bx - w / 2 - 1, by - 2.5, w + 2, 5))
                pygame.draw.rect(screen, col, (bx - w / 2, by - 1.5, w * max(0.0, min(1.0, p)), 3))

    def _draw_overlays(self, screen, mouse):
        cam = self.cam
        z = cam.zoom
        for u in self.selected_own_units()[:80]:
            fx, fy = u.x, u.y
            for code, tx, ty in self.s.order_points(u):
                c = tuple(int(ch * 0.7) for ch in to255(ORDER_COLORS.get(code, GOOD)))
                ui.dashed_line(screen, c, cam.to_screen(fx, fy), cam.to_screen(tx, ty), self._dash, width=2)
                fx, fy = tx, ty
        green = to255(GOOD)
        for b in self.selected_own_buildings():
            if b.rally:
                a, r = cam.to_screen(b.x, b.y), cam.to_screen(*b.rally)
                ui.dashed_line(screen, tuple(int(ch * 0.7) for ch in green), a, r, self._dash, width=2)
                pygame.draw.line(screen, (255, 255, 255), r, (r[0], r[1] - 26 / z), 2)
                pygame.draw.polygon(screen, green, [(r[0] + 1, r[1] - 26 / z), (r[0] + 16 / z, r[1] - 20 / z), (r[0] + 1, r[1] - 14 / z)])
        if self.placing and mouse and not self.hud.over_hud(mouse):
            k = self.placing
            px, py = self.snapped(*cam.to_world(*mouse))
            ok = self.s.can_place(k, px, py) and self.s.fog.is_explored(px, py)
            col = to255(GOOD if ok else BAD)
            img = art.sprites.get(("ghost", k, ok, self.s.slot), art.building(k, self.s.slot), 0, 1 / (art.SCALE * z),
                                  tint=(*col, 115), fade=160)
            sx, sy = cam.to_screen(px, py)
            screen.blit(img, (sx - img.get_width() / 2, sy - img.get_height() / 2))
            h = BUILDINGS[k].half / z
            pygame.draw.rect(screen, col, (sx - h, sy - h, 2 * h, 2 * h), 2, border_radius=int(8 / z))
            if k in ("turret", "artillery"):
                pygame.draw.circle(screen, (200, 200, 200), (int(sx), int(sy)), int(BUILDINGS[k].range / z), 1)
            if k == "artillery":
                pygame.draw.circle(screen, (200, 120, 120), (int(sx), int(sy)), int(ARTILLERY_MIN_RANGE / z), 1)
            if k == "shield":
                pygame.draw.circle(screen, (120, 210, 255), (int(sx), int(sy)), int(SHIELD_RADIUS / z), 1)
        if self.drag_start and self.drag_now:
            (ax, ay), (bx, by) = self.drag_start, self.drag_now
            r = pygame.Rect(min(ax, bx), min(ay, by), abs(bx - ax), abs(by - ay))
            if r.w > 2 and r.h > 2:
                fill = pygame.Surface(r.size, pygame.SRCALPHA)
                fill.fill((*to255(GOOD), 22))
                screen.blit(fill, r.topleft)
                pygame.draw.rect(screen, to255(GOOD), r, 1)
