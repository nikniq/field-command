"""Visual effects: particles, flashes, tracers, rings, decals and floating text.

Everything advances in simulation time, so effects freeze while the game is paused.
"""
import math
import random
from collections import OrderedDict

import pygame

from . import art
from .defs import to255

FIRE_SEQ = [(255, 242, 178), (255, 140, 38), (115, 31, 13)]
FLAME_SEQ = [(255, 230, 128), (255, 115, 26), (128, 26, 13)]
MAX_PARTICLES = 2500


def _seq(seq, t):
    t = max(0.0, min(0.999, t))
    f = t * (len(seq) - 1)
    i = int(f)
    k = f - i
    a, b = seq[i], seq[i + 1]
    q = round(k * 4) / 4  # quantise to keep the sprite cache small
    return tuple(int(a[j] + (b[j] - a[j]) * q) for j in range(3))


class Particle:
    __slots__ = ("x", "y", "vx", "vy", "ax", "ay", "age", "life", "size", "grow", "kind", "color", "alpha", "fade", "rot")

    def __init__(self, x, y, vx, vy, life, size, grow, kind, color=None, alpha=1.0, fade=None, ax=0.0, ay=0.0):
        self.x, self.y, self.vx, self.vy = x, y, vx, vy
        self.ax, self.ay = ax, ay
        self.age, self.life = 0.0, life
        self.size, self.grow = size, grow
        self.kind, self.color = kind, color
        self.alpha = alpha
        self.fade = fade
        self.rot = 0


class _LRU(OrderedDict):
    def __init__(self, limit):
        super().__init__()
        self.limit = limit

    def fetch(self, key, make):
        v = self.get(key)
        if v is None:
            v = make()
            self[key] = v
            if len(self) > self.limit:
                self.popitem(last=False)
        else:
            self.move_to_end(key)
        return v


class Effects:
    def __init__(self):
        self.particles = []
        self.flashes = []
        self.tracers = []
        self.rings = []
        self.decals = []
        self.texts = []
        self.delayed = []
        self.shake = 0.0
        self._sprites = _LRU(3000)
        self._font = None

    # ------------------------------------------------------------ emitters

    def _add(self, p):
        if len(self.particles) < MAX_PARTICLES:
            self.particles.append(p)

    def fire_burst(self, x, y, size):
        n = int(min(60, 10 + size * 0.8))
        for _ in range(n):
            a = random.uniform(0, 2 * math.pi)
            sp = size * 2.2 + random.uniform(-1, 1) * size * 0.9
            self._add(Particle(x, y, math.cos(a) * sp, math.sin(a) * sp, random.uniform(0.3, 0.6),
                               size * 0.9 * random.uniform(0.6, 1.4), -size * 0.6, "fire", fade=1.8))

    def smoke_burst(self, x, y, size):
        n = int(min(24, 5 + size * 0.3))
        for _ in range(n):
            a = random.uniform(0, 2 * math.pi)
            sp = size * 0.9 + random.uniform(-1, 1) * size * 0.3
            self._add(Particle(x, y, math.cos(a) * sp, math.sin(a) * sp, random.uniform(1.2, 2.0),
                               size * 0.9 * random.uniform(0.7, 1.3), size * 0.7, "smoke", (41, 38, 36), 0.75, 0.5, ay=12))

    def sparks(self, x, y, count, speed, color):
        c = to255(color) if isinstance(color[0], float) else color
        for _ in range(count):
            a = random.uniform(0, 2 * math.pi)
            sp = speed * random.uniform(0.7, 1.3)
            self._add(Particle(x, y, math.cos(a) * sp, math.sin(a) * sp, random.uniform(0.25, 0.45), 5, -8, "spark", c))

    def smoke_puff(self, x, y, dark):
        a = math.pi / 2 + 0.3 + random.uniform(-0.25, 0.25)
        sp = random.uniform(18, 34)
        self._add(Particle(x + random.uniform(-6, 6), y + random.uniform(-6, 6), math.cos(a) * sp, math.sin(a) * sp,
                           random.uniform(2.0, 3.2), random.uniform(13, 25), 22, "smoke",
                           (31, 28, 26) if dark else (178, 178, 184), 0.55 if dark else 0.35, 0.22 if dark else 0.14, ax=8))

    def flame(self, x, y):
        a = math.pi / 2 + random.uniform(-0.25, 0.25)
        sp = random.uniform(18, 42)
        self._add(Particle(x + random.uniform(-16, 16), y + random.uniform(-10, 10), math.cos(a) * sp, math.sin(a) * sp,
                           random.uniform(0.4, 0.8), random.uniform(12, 24), -22, "flame", fade=1.2))

    def trail(self, x, y):
        self._add(Particle(x, y, 0, 0, 0.25, 8, -20, "spark", (255, 190, 90), 0.7, 2.5))

    # ------------------------------------------------------------ one-shot effects

    def flash(self, x, y, size, color, life=0.25):
        self.flashes.append([x, y, size, to255(color), 0.0, life])

    def tracer(self, x0, y0, x1, y1, color, width):
        self.tracers.append([x0, y0, x1, y1, to255(color), width, 0.0, 0.1])

    def muzzle(self, x, y, angle, size):
        self.flash(x, y, size, (1, 0.85, 0.5), 0.08)

    def explosion(self, x, y, size, scorch=True, delay=0.0):
        if delay > 0:
            self.delayed.append([delay, x, y, size, scorch])
            return
        self.flash(x, y, size * 3, (1, 0.7, 0.3), 0.3)
        self.fire_burst(x, y, size)
        self.smoke_burst(x, y, size)
        self.sparks(x, y, int(6 + size / 3), size * 4, (255, 216, 128))
        if scorch:
            self.decal("scorch", x, y, size * 2.2, 90)      # craters stay for a good while

    def decal(self, kind, x, y, size, life, angle=None, team=0):
        self.decals.append([kind, x, y, size, random.uniform(0, 360) if angle is None else angle, 0.0, life, team])
        if len(self.decals) > 160:
            self.decals.pop(0)

    def ring(self, x, y, size_from, size_to, color, life=0.4, delay=0.0):
        self.rings.append([x, y, size_from, size_to, to255(color), -delay, life])

    def text(self, s, x, y, color):
        self.texts.append([s, x, y, to255(color), 0.0, 0.9])

    # ------------------------------------------------------------ update

    def update(self, dt):
        for d in self.delayed:
            d[0] -= dt
        ready = [d for d in self.delayed if d[0] <= 0]
        if ready:
            self.delayed = [d for d in self.delayed if d[0] > 0]
            for _, x, y, size, scorch in ready:
                self.explosion(x, y, size, scorch)
        alive = []
        for p in self.particles:
            p.age += dt
            if p.age >= p.life:
                continue
            p.vx += p.ax * dt
            p.vy += p.ay * dt
            p.x += p.vx * dt
            p.y += p.vy * dt
            p.size = max(1.0, p.size + p.grow * dt)
            if p.fade:
                p.alpha -= p.fade * dt
                if p.alpha <= 0:
                    continue
            alive.append(p)
        self.particles = alive
        for lst in (self.flashes, self.texts):
            for e in lst:
                e[4] += dt
        self.flashes = [f for f in self.flashes if f[4] < f[5]]
        self.texts = [t for t in self.texts if t[4] < t[5]]
        for t in self.tracers:
            t[6] += dt
        self.tracers = [t for t in self.tracers if t[6] < t[7]]
        for r in self.rings:
            r[5] += dt
        self.rings = [r for r in self.rings if r[5] < r[6]]
        for d in self.decals:
            d[5] += dt
        self.decals = [d for d in self.decals if d[5] < d[6] + 4]

    # ------------------------------------------------------------ drawing

    def _glow(self, px, color, level):
        px = max(2, int(px) // 2 * 2 if px < 40 else int(px) // 6 * 6)
        return self._sprites.fetch(("g", px, color, level), lambda: art.tinted_glow(px, color, level))

    def _blob(self, px, color, level):
        px = max(2, int(px) // 2 * 2 if px < 40 else int(px) // 6 * 6)
        return self._sprites.fetch(("b", px, color, level), lambda: art.tinted_blob(px, color, level))

    def draw_decals(self, screen, cam):
        z = cam.zoom
        v = cam.view_rect()
        for kind, x, y, size, angle, age, life, team in self.decals:
            if x + size < v[0] or x - size > v[2] or y + size < v[1] or y - size > v[3]:
                continue
            fade = 255 if age < life else int(255 * max(0.0, 1 - (age - life) / 4))
            fade = fade // 32 * 32 or 16
            if kind == "wreck":
                base = art.unit("tank", team)
                img = art.sprites.get(("wreck", team), base, angle, 1 / (art.SCALE * z), tint=(0, 0, 0, 180), fade=fade)
            elif isinstance(kind, tuple):
                # ("fallen", unit kind): the fallen, darkened where they dropped
                base = art.unit(kind[1], team)
                img = art.sprites.get(("fallen", kind[1], team), base, angle, 1 / (art.SCALE * z), tint=(25, 20, 18, 165),
                                      fade=min(fade, 190))
            else:
                base = art.scorch() if kind == "scorch" else art.rubble()
                s = size / (base.get_width() / (1 if kind == "scorch" else art.SCALE)) / (1 if kind == "scorch" else art.SCALE)
                img = art.sprites.get((kind,), base, angle, s / z, fade=fade)
            sx, sy = cam.to_screen(x, y)
            screen.blit(img, (sx - img.get_width() / 2, sy - img.get_height() / 2))

    def draw(self, screen, cam, font):
        z = cam.zoom
        v = cam.view_rect()
        m = 60
        for p in self.particles:
            if p.x < v[0] - m or p.x > v[2] + m or p.y < v[1] - m or p.y > v[3] + m:
                continue
            sx, sy = cam.to_screen(p.x, p.y)
            px = p.size / z
            t = p.age / p.life
            if p.kind == "smoke":
                level = max(0, min(8, int(p.alpha * 8 + 0.5)))
                if level == 0:
                    continue
                img = self._blob(px, p.color, level)
                screen.blit(img, (sx - img.get_width() / 2, sy - img.get_height() / 2))
            else:
                color = _seq(FIRE_SEQ, t) if p.kind == "fire" else _seq(FLAME_SEQ, t) if p.kind == "flame" else p.color
                level = max(0, min(8, int(p.alpha * 8 + 0.5)))
                if level == 0:
                    continue
                img = self._glow(px, color, level)
                screen.blit(img, (sx - img.get_width() / 2, sy - img.get_height() / 2), special_flags=pygame.BLEND_ADD)
        for x, y, size, color, age, life in self.flashes:
            k = age / life
            px = size * (1 + 0.4 * k) / z
            level = max(1, int((1 - k) * 8))
            img = self._glow(px, color, level)
            sx, sy = cam.to_screen(x, y)
            screen.blit(img, (sx - img.get_width() / 2, sy - img.get_height() / 2), special_flags=pygame.BLEND_ADD)
        for x0, y0, x1, y1, color, width, age, life in self.tracers:
            k = 1 - age / life
            c = tuple(int(ch * k) for ch in color)
            a, b = cam.to_screen(x0, y0), cam.to_screen(x1, y1)
            pygame.draw.line(screen, c, a, b, max(1, int(width / z + 0.5)))
        for x, y, s0, s1, color, age, life in self.rings:
            if age < 0:
                continue
            k = age / life
            r = (s0 + (s1 - s0) * k) / z
            if r < 1:
                continue
            c = tuple(int(ch * (1 - k)) for ch in color)
            sx, sy = cam.to_screen(x, y)
            pygame.draw.circle(screen, c, (int(sx), int(sy)), int(r), 2)
        for s, x, y, color, age, life in self.texts:
            k = age / life
            img = font(s, 12, color, bold=True)
            if k > 0.55:
                img = img.copy()
                img.set_alpha(int(255 * (1 - (k - 0.55) / 0.45)))
            sx, sy = cam.to_screen(x, y + 22 * k)
            screen.blit(img, (sx - img.get_width() / 2, sy - img.get_height() / 2))
