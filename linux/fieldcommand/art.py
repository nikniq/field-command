"""Procedurally drawn textures (Cairo), converted to pygame surfaces and cached.

Drawing callbacks work in a centred, y-up coordinate system with a key light from the top-left,
mirroring the macOS edition. Base textures are rendered at 2x so they stay crisp when zoomed in.
"""
import math
import random
from collections import OrderedDict

import cairo
import numpy as np
import pygame

from .defs import (AMBER, BAD, BLACK, BUTTON_EDGE, CRYSTAL, GOOD, TEAM_COLOR, TEAM_DARK, TEAM_LIGHT, WHITE, alpha, mix, rgb,
                   BUILDINGS, to255a)

SCALE = 2  # texture pixels per world unit

CONCRETE = rgb(0.47, 0.48, 0.46)
STEEL = rgb(0.36, 0.38, 0.41)
GUNMETAL = rgb(0.22, 0.23, 0.25)

UNIT_SIZE = {"worker": (34, 34), "marine": (38, 36), "tank": (54, 42), "sniper": (44, 36), "medic": (38, 36),
             "gunship": (56, 56)}
TURRET_SIZE = (68, 30)
CHIMNEYS = [(0.58, 0.55), (0.28, 0.62)]

_cache = {}


# ---------------------------------------------------------------- core

def _to_surface(surf):
    """Cairo ARGB32 (premultiplied BGRA) -> pygame RGBA surface with straight alpha."""
    w, h = surf.get_width(), surf.get_height()
    stride = surf.get_stride()
    buf = np.frombuffer(surf.get_data(), dtype=np.uint8).reshape(h, stride // 4, 4)[:, :w, :].astype(np.float32)
    a = buf[..., 3:4]
    with np.errstate(divide="ignore", invalid="ignore"):
        rgb_ = np.where(a > 0, buf[..., :3] * 255.0 / a, 0)
    out = np.empty((h, w, 4), dtype=np.uint8)
    out[..., 0] = np.clip(rgb_[..., 2], 0, 255)
    out[..., 1] = np.clip(rgb_[..., 1], 0, 255)
    out[..., 2] = np.clip(rgb_[..., 0], 0, 255)
    out[..., 3] = buf[..., 3]
    s = pygame.image.frombuffer(out.tobytes(), (w, h), "RGBA")
    return s.convert_alpha() if pygame.display.get_init() and pygame.display.get_surface() else s.copy()


def render(size, draw, scale=SCALE):
    w, h = max(1, int(math.ceil(size[0] * scale))), max(1, int(math.ceil(size[1] * scale)))
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    ctx = cairo.Context(surf)
    ctx.translate(w / 2, h / 2)
    ctx.scale(scale, -scale)
    ctx.set_line_join(cairo.LINE_JOIN_ROUND)
    ctx.set_line_cap(cairo.LINE_CAP_ROUND)
    draw(ctx)
    surf.flush()
    return surf


def texture(key, size, draw, scale=SCALE):
    t = _cache.get(key)
    if t is None:
        t = _to_surface(render(size, draw, scale))
        _cache[key] = t
    return t


# ---------------------------------------------------------------- path & paint helpers

def rr(x, y, w, h, r):
    r = max(0.0, min(r, w / 2 - 0.01, h / 2 - 0.01))

    def f(ctx):
        if r <= 0:
            ctx.rectangle(x, y, w, h)
            return
        ctx.new_sub_path()
        ctx.arc(x + w - r, y + r, r, -math.pi / 2, 0)
        ctx.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
        ctx.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
        ctx.arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
        ctx.close_path()
    return f


def ellipse(x, y, w, h):
    def f(ctx):
        ctx.save()
        ctx.translate(x + w / 2, y + h / 2)
        ctx.scale(w / 2, h / 2)
        ctx.new_sub_path()
        ctx.arc(0, 0, 1, 0, 2 * math.pi)
        ctx.restore()
    return f


def circle(cx, cy, r):
    return ellipse(cx - r, cy - r, 2 * r, 2 * r)


def poly(pts):
    def f(ctx):
        ctx.move_to(*pts[0])
        for p in pts[1:]:
            ctx.line_to(*p)
        ctx.close_path()
    return f


def _src(ctx, c):
    ctx.set_source_rgba(*c)


def fill(ctx, path, c):
    ctx.new_path()
    path(ctx)
    _src(ctx, c)
    ctx.fill()


def stroke(ctx, path, c, w):
    ctx.new_path()
    path(ctx)
    _src(ctx, c)
    ctx.set_line_width(w)
    ctx.stroke()


def lines(ctx, segs, c, w):
    ctx.new_path()
    for (a, b) in segs:
        ctx.move_to(*a)
        ctx.line_to(*b)
    _src(ctx, c)
    ctx.set_line_width(w)
    ctx.stroke()


def _stops(g, colors):
    n = len(colors)
    for i, c in enumerate(colors):
        g.add_color_stop_rgba(i / (n - 1) if n > 1 else 0, *c)
    g.set_extend(cairo.EXTEND_PAD)


def linear(ctx, path, colors, a, b):
    g = cairo.LinearGradient(a[0], a[1], b[0], b[1])
    _stops(g, colors)
    ctx.new_path()
    path(ctx)
    ctx.set_source(g)
    ctx.fill()


def radial(ctx, path, colors, c, r):
    g = cairo.RadialGradient(c[0], c[1], 0, c[0], c[1], r)
    _stops(g, colors)
    ctx.set_source(g)
    if path is None:
        ctx.paint()
    else:
        ctx.new_path()
        path(ctx)
        ctx.fill()


def _extents(ctx, path):
    ctx.new_path()
    path(ctx)
    return ctx.path_extents()


def lit(ctx, path, base, strength=1.0):
    x1, y1, x2, y2 = _extents(ctx, path)
    linear(ctx, path, [mix(base, WHITE, 0.34 * strength), base, mix(base, BLACK, 0.42 * strength)], (x1, y2), (x2, y1))


def rim(ctx, path, a=0.35):
    x1, y1, x2, y2 = _extents(ctx, path)
    ctx.save()
    ctx.new_path()
    path(ctx)
    ctx.clip()
    g = cairo.LinearGradient(x1, y2, (x1 + x2) / 2, (y1 + y2) / 2)
    _stops(g, [alpha(WHITE, a), alpha(WHITE, 0)])
    ctx.new_path()
    path(ctx)
    ctx.set_source(g)
    ctx.set_line_width(2)
    ctx.stroke()
    ctx.restore()


def metal(team):
    return mix(STEEL, TEAM_COLOR[team], 0.38)


def _octagon(r):
    return poly([(math.cos(i * math.pi / 4 + math.pi / 8) * r, math.sin(i * math.pi / 4 + math.pi / 8) * r) for i in range(8)])


# ---------------------------------------------------------------- generic soft shapes

def glow():
    return texture("glow", (64, 64), lambda c: radial(c, None, [WHITE, alpha(WHITE, 0.45), alpha(WHITE, 0)], (0, 0), 32), 1)


def shadow():
    return texture("shadow", (64, 64), lambda c: radial(c, None, [rgb(0, 0, 0, 0.55), rgb(0, 0, 0, 0.35), rgb(0, 0, 0, 0)], (0, 0), 32), 1)


def blob():
    def d(c):
        rnd = random.Random(7)
        for _ in range(9):
            p = (rnd.uniform(-10, 10), rnd.uniform(-10, 10))
            radial(c, None, [alpha(WHITE, 0.35), alpha(WHITE, 0)], p, rnd.uniform(14, 22))
    return texture("blob", (64, 64), d, 1)


def ring():
    def d(c):
        stroke(c, circle(0, 0, 28), alpha(WHITE, 0.25), 6)
        stroke(c, circle(0, 0, 28), WHITE, 2.2)
    return texture("ring", (64, 64), d)


def square_ring():
    def d(c):
        p = rr(-29, -29, 58, 58, 7)
        stroke(c, p, alpha(WHITE, 0.25), 5)
        stroke(c, p, WHITE, 1.6)
    return texture("square_ring", (64, 64), d)


# ---------------------------------------------------------------- units

def unit(kind, team):
    def d(c):
        {"worker": _worker, "marine": _marine, "tank": _tank_hull, "sniper": _sniper, "medic": _medic,
         "gunship": _gunship}[kind](c, team)
    return texture(("unit", kind, team), UNIT_SIZE[kind], d)


def _worker(c, team):
    col = TEAM_COLOR[team]
    pack = rr(-12, -6, 8, 12, 2)
    lit(c, pack, rgb(0.40, 0.40, 0.38))
    stroke(c, pack, rgb(0, 0, 0, 0.5), 0.8)
    lit(c, rr(2, -7.5, 10, 4, 1.5), STEEL)
    fill(c, poly([(11.5, -8), (17, -5.5), (11.5, -3)]), AMBER)
    body = ellipse(-7.5, -9.5, 15, 19)
    lit(c, body, col)
    rim(c, body)
    stroke(c, body, mix(col, BLACK, 0.5), 1)
    helm = circle(0.5, 0, 5.2)
    lit(c, helm, AMBER)
    stroke(c, helm, mix(AMBER, BLACK, 0.5), 0.9)
    fill(c, ellipse(-2.5, 0.8, 3.5, 2.2), alpha(WHITE, 0.6))


def _marine(c, team):
    col = TEAM_COLOR[team]
    fill(c, rr(-1, -6.2, 19, 3, 1), GUNMETAL)
    fill(c, rr(16.5, -6.6, 3, 3.8, 0.8), rgb(0.12, 0.12, 0.13))
    fill(c, rr(4, -7.5, 5, 2, 0.5), rgb(0.35, 0.3, 0.22))
    body = ellipse(-7, -10.5, 14, 21)
    lit(c, body, col)
    rim(c, body)
    stroke(c, body, mix(col, BLACK, 0.55), 1)
    for y in (7.8, -7.8):
        pad = circle(-0.5, y, 3.4)
        lit(c, pad, mix(col, BLACK, 0.3))
        stroke(c, pad, mix(col, BLACK, 0.6), 0.7)
    lit(c, ellipse(3, -7, 6, 4.5), mix(col, BLACK, 0.15))
    helm = circle(0, 0, 5.4)
    lit(c, helm, mix(col, BLACK, 0.35))
    stroke(c, helm, rgb(0, 0, 0, 0.6), 0.8)
    fill(c, rr(2.2, -2.8, 3, 5.6, 1.2), rgb(0.45, 0.95, 1.0))
    fill(c, ellipse(-3, 0.8, 3.2, 2), alpha(WHITE, 0.45))


def _medic(c, team):
    """A Ranger's build without the rifle: a white aid pack with a red cross on the back, a bag in hand."""
    col = TEAM_COLOR[team]
    pack = rr(-13, -6.5, 9, 13, 2.5)
    lit(c, pack, rgb(0.93, 0.93, 0.9))
    stroke(c, pack, rgb(0, 0, 0, 0.45), 0.8)
    fill(c, rr(-10, -1.2, 3.4, 2.4, 0.4), rgb(0.85, 0.15, 0.15))     # the cross
    fill(c, rr(-9.5, -3.2, 2.4, 6.4, 0.4), rgb(0.85, 0.15, 0.15))
    bag = rr(3, 3.5, 8, 5.5, 1.2)
    lit(c, bag, rgb(0.9, 0.9, 0.88))
    stroke(c, bag, rgb(0, 0, 0, 0.45), 0.7)
    fill(c, rr(6.2, 5.2, 1.6, 2.2, 0.3), rgb(0.85, 0.15, 0.15))
    body = ellipse(-7, -10.5, 14, 21)
    lit(c, body, col)
    rim(c, body)
    stroke(c, body, mix(col, BLACK, 0.55), 1)
    for y in (7.8, -7.8):
        pad = circle(-0.5, y, 3.4)
        lit(c, pad, mix(col, BLACK, 0.3))
        stroke(c, pad, mix(col, BLACK, 0.6), 0.7)
    lit(c, ellipse(3, -7, 6, 4.5), mix(col, BLACK, 0.15))
    helm = circle(0, 0, 5.4)
    lit(c, helm, rgb(0.93, 0.93, 0.9))
    stroke(c, helm, rgb(0, 0, 0, 0.6), 0.8)
    fill(c, rr(-1.1, -3.2, 2.2, 6.4, 0.3), rgb(0.85, 0.15, 0.15))      # cross on the helmet
    fill(c, rr(-3.2, -1.1, 6.4, 2.2, 0.3), rgb(0.85, 0.15, 0.15))
    fill(c, ellipse(-3, 0.8, 3.2, 2), alpha(WHITE, 0.35))


def _gunship(c, team):
    """A Gunship seen from above: a slim fuselage with stub wings, a tail boom and a spinning rotor disc."""
    col = TEAM_COLOR[team]
    wing = rr(-6, -17, 10, 34, 2)
    lit(c, wing, mix(col, BLACK, 0.35))
    stroke(c, wing, rgb(0, 0, 0, 0.5), 0.8)
    for y in (-15.5, 15.5):
        fill(c, rr(-3, y - 1.2, 8, 2.4, 0.8), STEEL)          # the gun pods
    boom = rr(-24, -2.2, 16, 4.4, 1.5)
    lit(c, boom, mix(col, BLACK, 0.25))
    stroke(c, boom, rgb(0, 0, 0, 0.5), 0.7)
    fill(c, rr(-26, -6, 3, 12, 1), rgb(0.30, 0.31, 0.33))     # tail rotor
    body = ellipse(-12, -7, 30, 14)
    lit(c, body, col)
    rim(c, body)
    stroke(c, body, mix(col, BLACK, 0.55), 1)
    canopy = ellipse(6, -4.5, 11, 9)
    lit(c, canopy, rgb(0.25, 0.45, 0.6))
    fill(c, ellipse(8, -3.5, 5, 3), alpha(WHITE, 0.4))
    fill(c, rr(15, -1.3, 8, 2.6, 0.9), STEEL)                # the chain gun under the nose
    fill(c, circle(-2, 0, 26), rgb(0.85, 0.85, 0.85, 0.16))  # the rotor disc, a blur
    lines(c, [((-2, -26), (-2, 26)), ((-28, 0), (24, 0))], rgb(0.2, 0.2, 0.2, 0.35), 1.4)
    fill(c, circle(-2, 0, 2.6), rgb(0.2, 0.2, 0.22))


def _sniper(c, team):
    """Lankier than a Ranger, with a long barrel, a bipod and a cold scope glint."""
    col = TEAM_COLOR[team]
    barrel = rr(-1, -5.6, 25, 2.6, 0.8)
    lit(c, barrel, GUNMETAL)
    stroke(c, barrel, rgb(0, 0, 0, 0.5), 0.6)
    fill(c, rr(22, -6.2, 3.4, 3.8, 0.8), rgb(0.1, 0.1, 0.11))     # muzzle brake
    lines(c, [((16, -4.3), (13, -1.2)), ((16, -4.3), (19, -1.2))], rgb(0.14, 0.14, 0.15), 1.2)   # bipod
    scope = rr(5, -8.4, 8, 2.6, 1)
    lit(c, scope, rgb(0.2, 0.21, 0.23))
    fill(c, circle(12.4, -7.1, 1.5), rgb(0.55, 0.95, 1.0))
    body = ellipse(-7, -9.5, 14, 19)
    lit(c, body, mix(col, BLACK, 0.12))
    rim(c, body)
    stroke(c, body, mix(col, BLACK, 0.6), 1)
    cloak = poly([(-7, -9), (-12.5, -4), (-13.5, 4), (-7, 9)])     # ghillie drape
    fill(c, cloak, alpha(mix(col, BLACK, 0.45), 0.85))
    stroke(c, cloak, rgb(0, 0, 0, 0.45), 0.7)
    helm = circle(0.4, 0, 5.0)
    lit(c, helm, mix(col, BLACK, 0.45))
    stroke(c, helm, rgb(0, 0, 0, 0.6), 0.8)
    fill(c, rr(2.0, -2.4, 2.8, 4.8, 1.1), rgb(0.78, 0.95, 1.0))
    fill(c, ellipse(-3, 0.8, 3.0, 1.9), alpha(WHITE, 0.4))


def _tank_hull(c, team):
    for y in (-14, 14):
        tr = rr(-24, y - 5.5, 48, 11, 4)
        lit(c, tr, rgb(0.2, 0.2, 0.21))
        segs = [((x, y - 4.8), (x, y + 4.8)) for x in [-21 + i * 3.5 for i in range(13)]]
        lines(c, segs, alpha(WHITE, 0.13), 1)
        stroke(c, tr, rgb(0, 0, 0, 0.6), 1)
    hull = rr(-20, -11, 40, 22, 4)
    lit(c, hull, metal(team))
    rim(c, hull, 0.45)
    stroke(c, hull, rgb(0, 0, 0, 0.6), 1.1)
    fill(c, poly([(13, -10), (20, -7), (20, 7), (13, 10)]), alpha(WHITE, 0.12))
    lines(c, [((-18, gy), (-12, gy)) for gy in [-6 + i * 2.4 for i in range(6)]], rgb(0, 0, 0, 0.45), 1)
    fill(c, rr(-9, -11, 3.5, 22, 0), alpha(TEAM_COLOR[team], 0.8))


def tank_outriggers(team):
    """Four stabiliser legs that fold out under a sieged tank. Drawn under the hull, rotated with it."""
    def d(c):
        for sx in (-1, 1):
            for sy in (-1, 1):
                leg = poly([(sx * 14, sy * 8), (sx * 30, sy * 24), (sx * 34, sy * 20), (sx * 18, sy * 5)])
                lit(c, leg, rgb(0.3, 0.31, 0.33))
                stroke(c, leg, rgb(0, 0, 0, 0.6), 1)
                foot = circle(sx * 31, sy * 22, 4.5)
                lit(c, foot, mix(TEAM_COLOR[team], BLACK, 0.4))
                stroke(c, foot, rgb(0, 0, 0, 0.6), 0.9)
    return texture(("outriggers", team), (76, 56), d)


def crate():
    """A supply drop: an olive crate with strapping, a white chevron and a beacon light on the lid."""
    def d(c):
        box_ = rr(-16, -13, 32, 26, 3)
        lit(c, box_, rgb(0.42, 0.44, 0.28))
        stroke(c, box_, rgb(0, 0, 0, 0.6), 1.2)
        for x in (-8, 8):
            fill(c, rr(x - 2, -13, 4, 26, 0.5), rgb(0.22, 0.2, 0.14))        # strapping
        fill(c, poly([(-5, 4), (0, -3), (5, 4), (3, 4), (0, 0), (-3, 4)]), rgb(0.92, 0.92, 0.88))
        fill(c, circle(11, -9, 2.4), rgb(1.0, 0.45, 0.2))
        fill(c, circle(10.3, -9.6, 0.9), alpha(WHITE, 0.8))
    return texture("crate", (44, 38), d)


def watchtower(team):
    """A stone tower on a square footing, flying the holder's banner — grey and bare when nobody holds it."""
    col = TEAM_COLOR[team] if team is not None else rgb(0.45, 0.47, 0.5)

    def d(c):
        base = rr(-30, -30, 60, 60, 6)
        lit(c, base, CONCRETE, 0.75)
        stroke(c, base, rgb(0, 0, 0, 0.5), 1.2)
        for sx, sy in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
            fill(c, circle(sx * 24, sy * 24, 2.2), rgb(0.2, 0.2, 0.22))
        # The tower itself, drawn as a stack of shrinking rings so it reads as tall from above.
        for i, r in enumerate((22, 18, 14)):
            ring_ = circle(3 - i, -3 + i, r)
            lit(c, ring_, mix(rgb(0.55, 0.53, 0.5), BLACK, 0.12 * i))
            stroke(c, ring_, rgb(0, 0, 0, 0.55), 1)
        top = circle(1, -1, 10)
        lit(c, top, rgb(0.62, 0.6, 0.57))
        stroke(c, top, rgb(0, 0, 0, 0.6), 1)
        for i in range(8):
            a = i * math.pi / 4
            fill(c, rr(1 + math.cos(a) * 11 - 1.6, -1 + math.sin(a) * 11 - 1.6, 3.2, 3.2, 0.6), rgb(0.35, 0.34, 0.33))
        # Banner: a pole with a pennant in the holder's colour.
        lines(c, [((1, -1), (1, 24))], rgb(0.15, 0.15, 0.16), 2)
        fill(c, poly([(1, 24), (17, 19), (1, 13)]), col)
        stroke(c, poly([(1, 24), (17, 19), (1, 13)]), rgb(0, 0, 0, 0.5), 0.8)
        if team is not None:
            fill(c, circle(1, -1, 3.5), TEAM_LIGHT[team])
    return texture(("watchtower", team), (84, 84), d)


def group_badge(n):
    """A small dark plate with the control group's number, drawn beside a unit that is in one."""
    def d(c):
        plate = rr(-7, -7, 14, 14, 3)
        fill(c, plate, rgb(0.05, 0.06, 0.08, 0.85))
        stroke(c, plate, alpha(WHITE, 0.55), 1)
        # A seven-segment style digit keeps the badge font-free and crisp at any zoom
        segs = {0: "abcdef", 1: "bc", 2: "abged", 3: "abgcd", 4: "fgbc", 5: "afgcd", 6: "afgedc", 7: "abc", 8: "abcdefg", 9: "abfgcd"}
        pts = {"a": ((-3, -4.5), (3, -4.5)), "b": ((3, -4.5), (3, 0)), "c": ((3, 0), (3, 4.5)), "d": ((-3, 4.5), (3, 4.5)),
               "e": ((-3, 0), (-3, 4.5)), "f": ((-3, -4.5), (-3, 0)), "g": ((-3, 0), (3, 0))}
        lines(c, [pts[k] for k in segs.get(n % 10, "")], rgb(1, 0.85, 0.4), 1.6)
    return texture(("gbadge", n), (16, 16), d)


def chevrons(rank, team):
    """Rank marks drawn above a veteran: one, two or three small chevrons in the owner's light colour."""
    col = TEAM_LIGHT[team]

    def d(c):
        for i in range(rank):
            y = -6 + i * 5
            p = poly([(-6, y - 2.5), (0, y + 2.5), (6, y - 2.5), (6, y - 5), (0, y), (-6, y - 5)])
            fill(c, p, col)
            stroke(c, p, rgb(0, 0, 0, 0.7), 0.7)
    return texture(("chevrons", rank, team), (16, 20), d)


def icon_plate(w, h):
    """The dark rounded plate drawn behind command-card icons."""
    key = ("icon_plate", w, h)
    t = _cache.get(key)
    if t is None:
        t = pygame.Surface((w, h), pygame.SRCALPHA)
        pygame.draw.rect(t, (6, 9, 12, 150), (0, 0, w, h), border_radius=7)
        pygame.draw.rect(t, (255, 255, 255, 22), (0, 0, w, h), 1, border_radius=7)
        _cache[key] = t
    return t


def icon_upgrade(kind):
    """Command-card icons for building upgrades: a plate, a shield, gears, a crate and a twin barrel."""
    def d(c):
        if kind == "hp":
            plate = rr(-13, -13, 26, 26, 4)
            lit(c, plate, rgb(0.5, 0.55, 0.6))
            stroke(c, plate, rgb(0, 0, 0, 0.6), 1.2)
            for x, y in ((-8, -8), (8, -8), (-8, 8), (8, 8)):
                fill(c, circle(x, y, 2), rgb(0.2, 0.2, 0.22))
            fill(c, rr(-4, -12, 8, 24, 1), alpha(GOOD, 0.8))
            fill(c, rr(-12, -4, 24, 8, 1), alpha(GOOD, 0.8))
        elif kind == "armor":
            sh = poly([(0, 16), (13, 9), (13, -4), (0, -15), (-13, -4), (-13, 9)])
            lit(c, sh, rgb(0.35, 0.5, 0.75))
            stroke(c, sh, rgb(0, 0, 0, 0.6), 1.2)
            lines(c, [((0, 12), (0, -10))], alpha(WHITE, 0.5), 2)
        elif kind == "prod":
            for cx, cy, r in ((-6, 3, 9), (8, -5, 6)):
                for i in range(8):
                    a = i * math.pi / 4
                    fill(c, rr(cx + math.cos(a) * r - 2, cy + math.sin(a) * r - 2, 4, 4, 1), rgb(0.6, 0.62, 0.65))
                g = circle(cx, cy, r - 1)
                lit(c, g, rgb(0.55, 0.58, 0.62))
                stroke(c, g, rgb(0, 0, 0, 0.6), 1)
                fill(c, circle(cx, cy, r * 0.35), rgb(0.2, 0.2, 0.22))
        elif kind == "supply":
            box = rr(-13, -10, 26, 20, 2)
            lit(c, box, rgb(0.6, 0.45, 0.25))
            stroke(c, box, rgb(0, 0, 0, 0.6), 1.2)
            lines(c, [((-13, 0), (13, 0)), ((0, -10), (0, 10))], rgb(0.25, 0.17, 0.09, 0.8), 1.5)
            fill(c, rr(-5, -16, 10, 6, 1), AMBER)
        elif kind == "defense":
            # A gun over the Command Center's octagon
            oct_ = _octagon(15)
            lit(c, oct_, rgb(0.42, 0.46, 0.55))
            stroke(c, oct_, rgb(0, 0, 0, 0.6), 1.2)
            linear(c, rr(0, -2.2, 18, 4.4, 1.2), [rgb(0.7, 0.72, 0.74), rgb(0.3, 0.31, 0.33)], (0, 2), (0, -2))
            fill(c, rr(15, -2.8, 4, 5.6, 1), rgb(0.12, 0.12, 0.13))
            base = circle(-3, 0, 6.5)
            lit(c, base, rgb(0.5, 0.55, 0.62))
            stroke(c, base, rgb(0, 0, 0, 0.6), 1)
            fill(c, circle(-3, 0, 2), rgb(1, 0.35, 0.3))
        elif kind == "entrench":
            # Sandbags, three courses, a rifle resting over the top
            for row, y in enumerate((8, 1, -6)):
                for i in range(-2 + row % 2, 3):
                    bag = rr(i * 9 - 4 + (4.5 if row % 2 else 0) - 4.5, y - 3.5, 8, 7, 3)
                    lit(c, bag, rgb(0.62, 0.55, 0.38))
                    stroke(c, bag, rgb(0, 0, 0, 0.5), 0.8)
            lines(c, [((-14, -10), (12, -14))], rgb(0.2, 0.2, 0.22), 2.2)
            fill(c, circle(-13, -10, 2), rgb(0.35, 0.36, 0.38))
        elif kind == "stabilise":
            # A tank hull driving right, speed lines behind it, a shell leaving the barrel
            for y in (-9, -3, 3):
                lines(c, [((-19, y), (-9 - abs(y) * 0.4, y))], rgb(0.8, 0.82, 0.85, 0.7), 1.5)
            hull = rr(-8, -6, 20, 12, 3)
            lit(c, hull, rgb(0.55, 0.6, 0.66))
            stroke(c, hull, rgb(0, 0, 0, 0.6), 1)
            fill(c, rr(0, -2, 17, 4, 1), rgb(0.35, 0.36, 0.38))
            fill(c, circle(0, 0, 4.5), rgb(0.4, 0.44, 0.5))
            fill(c, circle(19, 0, 2.2), AMBER)
        else:   # guns
            for y in (-5, 5):
                linear(c, rr(-4, y - 2.2, 22, 4.4, 1.2), [rgb(0.7, 0.72, 0.74), rgb(0.3, 0.31, 0.33)], (0, y + 2), (0, y - 2))
                fill(c, rr(17, y - 2.8, 4, 5.6, 1), rgb(0.12, 0.12, 0.13))
            base = rr(-14, -10, 16, 20, 5)
            lit(c, base, rgb(0.5, 0.55, 0.62))
            stroke(c, base, rgb(0, 0, 0, 0.6), 1)
            fill(c, circle(-6, 0, 2.2), rgb(1, 0.35, 0.3))
    return texture(("icon_upgrade", kind), (40, 40), d)


def icon_siege(on):
    """Command-card icon: a tank silhouette over splayed legs (dig in) or over wheels (pack up)."""
    def d(c):
        if on:
            for sx in (-1, 1):
                lines(c, [((sx * 6, 0), (sx * 15, -11))], rgb(0.75, 0.78, 0.8), 3)
                fill(c, circle(sx * 15, -11, 2.6), AMBER)
        else:
            for sx in (-1, 1):
                fill(c, circle(sx * 9, -9, 4), rgb(0.2, 0.2, 0.21))
        hull = rr(-11, -6, 22, 12, 3)
        lit(c, hull, rgb(0.55, 0.6, 0.66))
        stroke(c, hull, rgb(0, 0, 0, 0.6), 1)
        fill(c, rr(-3, -2, 18, 4, 1), rgb(0.35, 0.36, 0.38))
        fill(c, circle(-2, 0, 4.5), rgb(0.4, 0.44, 0.5))
        if on:
            stroke(c, circle(0, 0, 17), alpha(AMBER, 0.8), 1.5)
    return texture(("icon_siege", on), (40, 40), d)


def icon_ability(aid):
    """Command-card icon for a unit ability: a grenade, a target reticle or a smoke plume."""
    def d(c):
        if aid == "grenade":
            body = circle(0, 2, 10)
            lit(c, body, rgb(0.3, 0.42, 0.3))
            stroke(c, body, rgb(0, 0, 0, 0.6), 1)
            lines(c, [((-7, 2), (7, 2)), ((0, -5), (0, 9)), ((-5, -3), (5, 7)), ((5, -3), (-5, 7))], rgb(0, 0, 0, 0.35), 1)
            fill(c, rr(-3, -13, 6, 5, 1), rgb(0.5, 0.52, 0.55))
            lines(c, [((3, -12), (9, -16))], AMBER, 2)
        elif aid == "mark":
            stroke(c, circle(0, 0, 13), AMBER, 2)
            stroke(c, circle(0, 0, 5), AMBER, 1.5)
            lines(c, [((-17, 0), (-8, 0)), ((8, 0), (17, 0)), ((0, -17), (0, -8)), ((0, 8), (0, 17))], AMBER, 2)
            fill(c, circle(0, 0, 2), BAD)
        else:
            for (x, y, r, k) in ((0, 8, 8, 0.55), (-6, 0, 7, 0.62), (6, -1, 7.5, 0.66), (0, -8, 8, 0.72), (-3, -14, 5, 0.78)):
                fill(c, circle(x, y, r), rgb(k, k, k + 0.02))
            fill(c, rr(-4, 10, 8, 6, 1), rgb(0.35, 0.36, 0.38))
    return texture(("icon_ability", aid), (40, 40), d)


def tank_turret(team):
    def d(c):
        linear(c, rr(4, -2.7, 25, 5.4, 1.5), [rgb(0.62, 0.64, 0.66), rgb(0.3, 0.31, 0.33)], (0, 3), (0, -3))
        lit(c, rr(27, -4, 6, 8, 1.5), GUNMETAL)
        dome = rr(-12, -9.5, 21, 19, 7)
        lit(c, dome, mix(TEAM_COLOR[team], STEEL, 0.25))
        rim(c, dome, 0.5)
        stroke(c, dome, rgb(0, 0, 0, 0.6), 1)
        hatch = circle(-3.5, 2.5, 3.6)
        lit(c, hatch, mix(TEAM_COLOR[team], BLACK, 0.45))
        stroke(c, hatch, rgb(0, 0, 0, 0.5), 0.7)
    return texture(("turret", team), TURRET_SIZE, d)


# ---------------------------------------------------------------- buildings

def building_canvas(kind):
    h = BUILDINGS[kind].half
    return (h * 2 + 28, h * 2 + 28)


def building(kind, team):
    h = BUILDINGS[kind].half

    def d(c):
        if kind != "turret":
            _foundation(c, h)
        _extrude(c, kind, h, team)
        {"hq": _hq, "depot": _depot, "barracks": _barracks, "factory": _factory, "turret": _turret_base,
         "radar": _radar, "artillery": _artillery_base, "shield": _shield_gen, "wall": _wall}[kind](c, h, team)
        if kind != "wall":
            _roof_kit(c, kind, h, team)
    return texture(("bld", kind, team), building_canvas(kind), d)


def _silhouette(kind, h):
    """The outline of a building's body, used for its walls, shadow and roof trim."""
    if kind == "hq":
        return _octagon(h * 0.98)
    if kind == "turret":
        return circle(0, 0, h * 0.8)
    if kind == "radar":
        return _octagon(h * 0.92)
    if kind == "shield":
        return _octagon(h * 0.9)
    if kind == "wall":
        return rr(-h * 0.92, -h * 0.72, h * 1.84, h * 1.44, 3)
    if kind == "artillery":
        return rr(-h * 0.88, -h * 0.88, h * 1.76, h * 1.76, 6)
    if kind == "depot":
        return rr(-h * 0.86, -h * 0.87, h * 1.72, h * 1.74, 4)
    if kind == "barracks":
        return rr(-h * 0.9, -h * 0.62, h * 1.8, h * 1.52, 4)
    return rr(-h * 0.92, -h * 0.66, h * 1.84, h * 1.5, 4)


def _extrude(c, kind, h, team):
    """Fakes height: a ground shadow plus stacked wall slices offset towards the bottom right."""
    body = _silhouette(kind, h)
    c.save()
    c.translate(7, -9)
    fill(c, body, rgb(0, 0, 0, 0.34))
    c.restore()
    depth = 7 if kind in ("hq", "factory", "barracks") else 5
    for i in range(depth, 0, -1):
        c.save()
        c.translate(i * 0.55, -i * 0.7)
        fill(c, body, mix(metal(team), BLACK, 0.55 + 0.04 * i))
        c.restore()


def _roof_kit(c, kind, h, team):
    """Shared roof clutter: vents, hatches, rivets, weather streaks and a team flash."""
    rnd = random.Random(hash(kind) % 997)
    body = _silhouette(kind, h)
    stroke(c, body, rgb(0, 0, 0, 0.5), 1.2)

    def vent(x, y, w, hh):
        v = rr(x - w / 2, y - hh / 2, w, hh, 2)
        lit(c, v, rgb(0.34, 0.35, 0.37))
        stroke(c, v, rgb(0, 0, 0, 0.55), 1)
        slats = []
        yy = y - hh / 2 + 2.5
        while yy < y + hh / 2 - 1:
            slats.append(((x - w / 2 + 2, yy), (x + w / 2 - 2, yy)))
            yy += 2.6
        lines(c, slats, rgb(0, 0, 0, 0.45), 1)

    if kind == "hq":
        for sx, sy in ((-0.62, -0.58), (0.62, -0.58)):
            vent(sx * h, sy * h, h * 0.3, h * 0.2)
        _mast(c, -h * 0.66, h * 0.6, h * 0.34, team)
    elif kind == "barracks":
        vent(-h * 0.62, -h * 0.34, h * 0.34, h * 0.22)
        vent(h * 0.62, -h * 0.34, h * 0.34, h * 0.22)
        _mast(c, h * 0.7, h * 0.5, h * 0.3, team)
        # Landing stripes by the doors
        for sx in (-0.5, 0.5):
            lines(c, [((sx * h - 9, h * 0.34), (sx * h + 9, h * 0.34))], alpha(AMBER, 0.7), 1.5)
    elif kind == "factory":
        vent(-h * 0.6, h * 0.1, h * 0.36, h * 0.26)
        hatch = rr(h * 0.2, -h * 0.2, h * 0.38, h * 0.38, 3)
        lit(c, hatch, rgb(0.3, 0.31, 0.33))
        stroke(c, hatch, rgb(0, 0, 0, 0.5), 1)
        fill(c, circle(h * 0.39, -h * 0.01, h * 0.07), rgb(0.5, 0.5, 0.52))
    elif kind == "depot":
        for sy in (-0.62, 0.0, 0.62):
            fill(c, rr(-h * 0.2, sy * h - 2, h * 0.4, 4, 2), rgb(0.1, 0.1, 0.11))
        _mast(c, -h * 0.72, -h * 0.72, h * 0.22, team)

    # Rivets around the roof edge and a few weather streaks.
    n = 18 if kind != "turret" else 12
    for i in range(n):
        a = i / n * 2 * math.pi
        k = 0.8 if kind == "hq" else 0.74
        fill(c, circle(math.cos(a) * h * k, math.sin(a) * h * k, 1.1), alpha(WHITE, 0.25))
    c.save()
    c.new_path()
    body(c)
    c.clip()
    for _ in range(7):
        x = rnd.uniform(-h * 0.8, h * 0.8)
        y0 = rnd.uniform(-h * 0.2, h * 0.7)
        lines(c, [((x, y0), (x + rnd.uniform(-2, 2), y0 - rnd.uniform(h * 0.3, h * 0.8)))], rgb(0, 0, 0, 0.12), rnd.uniform(1.5, 4))
    c.restore()


def _mast(c, x, y, length, team):
    """A small antenna with a team-coloured beacon."""
    lines(c, [((x, y), (x + length * 0.5, y + length * 0.72))], rgb(0.1, 0.1, 0.11), 2)
    fill(c, circle(x, y, 2.6), rgb(0.26, 0.27, 0.29))
    tip = (x + length * 0.5, y + length * 0.72)
    fill(c, circle(*tip, 2.6), TEAM_LIGHT[team])
    fill(c, circle(*tip, 1.2), alpha(WHITE, 0.9))


def _foundation(c, h):
    pad = rr(-h - 5, -h - 5, 2 * h + 10, 2 * h + 10, 9)
    lit(c, pad, CONCRETE, 0.7)
    stroke(c, pad, rgb(0, 0, 0, 0.45), 1.2)
    for sx, sy in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
        cx, cy = sx * (h + 1), sy * (h + 1)
        fill(c, poly([(cx, cy), (cx - sx * 9, cy), (cx, cy - sy * 9)]), alpha(AMBER, 0.8))


def _hq(c, h, team):
    outer = _octagon(h * 0.98)
    lit(c, outer, metal(team))
    rim(c, outer, 0.4)
    stroke(c, outer, TEAM_COLOR[team], 2)
    seams = []
    for i in range(8):
        a = i * math.pi / 4
        seams.append(((math.cos(a) * h * 0.66, math.sin(a) * h * 0.66), (math.cos(a) * h * 0.9, math.sin(a) * h * 0.9)))
    lines(c, seams, rgb(0, 0, 0, 0.3), 1.2)
    inner = _octagon(h * 0.66)
    lit(c, inner, mix(metal(team), WHITE, 0.12))
    stroke(c, inner, rgb(0, 0, 0, 0.45), 1.2)
    for i in range(4):
        a = i * math.pi / 2 + math.pi / 4
        pad = circle(math.cos(a) * h * 0.72, math.sin(a) * h * 0.72, h * 0.15)
        fill(c, pad, rgb(0.16, 0.17, 0.18))
        stroke(c, pad, AMBER, 1.5)
    dome = circle(0, 0, h * 0.38)
    radial(c, dome, [TEAM_LIGHT[team], TEAM_COLOR[team], mix(TEAM_COLOR[team], BLACK, 0.45)], (-h * 0.12, h * 0.12), h * 0.5)
    stroke(c, dome, alpha(WHITE, 0.55), 1.5)
    fill(c, ellipse(-h * 0.22, h * 0.08, h * 0.2, h * 0.12), alpha(WHITE, 0.45))
    for i in range(16):
        a = i * math.pi / 8
        fill(c, circle(math.cos(a) * h * 0.83, math.sin(a) * h * 0.83, 1.6), alpha(WHITE, 0.9) if i % 2 == 0 else TEAM_LIGHT[team])


def dish():
    def d(c):
        fill(c, rr(0, -1.5, 14, 3, 1), rgb(0.8, 0.82, 0.85))
        e = ellipse(12, -9, 8, 18)
        lit(c, e, rgb(0.85, 0.87, 0.9))
        stroke(c, e, rgb(0, 0, 0, 0.4), 0.8)
    return texture("dish", (44, 24), d)


def _depot(c, h, team):
    for i in range(3):
        y = -h * 0.62 + i * h * 0.62
        x0, y0, w, hh = -h * 0.86, y - h * 0.25, h * 1.72, h * 0.5
        box = rr(x0, y0, w, hh, 3)
        lit(c, box, mix(TEAM_COLOR[team], STEEL, 0.35) if i == 1 else metal(team))
        ribs = []
        x = x0 + 7
        while x < x0 + w - 5:
            ribs.append(((x, y0 + 2), (x, y0 + hh - 2)))
            x += 5
        lines(c, ribs, rgb(0, 0, 0, 0.2), 1)
        fill(c, rr(x0, y0, 5, hh, 2), rgb(0, 0, 0, 0.3))
        fill(c, rr(x0 + w - 5, y0, 5, hh, 2), rgb(0, 0, 0, 0.3))
        rim(c, box)
        stroke(c, box, rgb(0, 0, 0, 0.5), 1)


def _barracks(c, h, team):
    m = metal(team)
    top = (-h * 0.9, h * 0.12, h * 1.8, h * 0.78)
    bottom = (-h * 0.9, -h * 0.62, h * 1.8, h * 0.74)
    linear(c, rr(*top, 4), [mix(m, WHITE, 0.28), mix(m, WHITE, 0.08)], (0, top[1] + top[3]), (0, top[1]))
    linear(c, rr(*bottom, 4), [mix(m, BLACK, 0.15), mix(m, BLACK, 0.4)], (0, bottom[1] + bottom[3]), (0, bottom[1]))
    seams = []
    x = -h * 0.9 + 12
    while x < h * 0.9:
        seams.append(((x, -h * 0.6), (x, top[1] + top[3] - 2)))
        x += 12
    lines(c, seams, rgb(0, 0, 0, 0.14), 1)
    lines(c, [((-h * 0.9, h * 0.12), (h * 0.9, h * 0.12))], alpha(WHITE, 0.4), 2)
    stroke(c, rr(-h * 0.9, -h * 0.62, h * 1.8, h * 1.52, 4), rgb(0, 0, 0, 0.55), 1.2)
    for sx in (-0.5, 0.5):
        fill(c, rr(sx * h - 6, h * 0.42, 12, 10, 2), rgb(0.15, 0.16, 0.17))
        lines(c, [((sx * h - 4, h * 0.47), (sx * h + 4, h * 0.47))], alpha(WHITE, 0.2), 1)
    fill(c, rr(-h * 0.24, -h * 0.66, h * 0.48, h * 0.2, 2), rgb(0.1, 0.1, 0.11))
    fill(c, rr(-h * 0.2, -h * 0.5, h * 0.4, 2.5, 1), TEAM_LIGHT[team])
    rnd = random.Random(3)
    for side in (-1, 1):
        sx = side * h * 0.34
        while abs(sx) < h * 0.88:
            lit(c, ellipse(sx - 5, -h * 0.86 + rnd.uniform(-1, 1), 10, 6), rgb(0.62, 0.55, 0.4))
            sx += side * 9


def _factory(c, h, team):
    m = metal(team)
    hx, hy, hw, hh = -h * 0.92, -h * 0.66, h * 1.84, h * 1.5
    band = hw / 4
    for i in range(4):
        x0 = hx + i * band
        linear(c, rr(x0, hy, band, hh, 0), [mix(m, WHITE, 0.3), mix(m, BLACK, 0.35)], (x0, 0), (x0 + band, 0))
        gx = x0 + band - band * 0.22
        linear(c, rr(gx, hy + 4, band * 0.18, hh - 8, 1), [rgb(0.45, 0.75, 0.85), rgb(0.12, 0.22, 0.3)], (0, hy + hh), (0, hy))
    stroke(c, rr(hx, hy, hw, hh, 4), rgb(0, 0, 0, 0.55), 1.3)
    fill(c, rr(hx, hy + hh - 5, hw, 5, 1), TEAM_COLOR[team])
    for ox, oy in CHIMNEYS:
        r = h * (0.14 if ox > 0.5 else 0.11)
        st = circle(ox * h, oy * h, r)
        lit(c, st, rgb(0.45, 0.43, 0.4))
        stroke(c, st, rgb(0, 0, 0, 0.5), 1)
        fill(c, circle(ox * h, oy * h, r * 0.6), rgb(0.05, 0.05, 0.05))
    dx, dy, dw, dh = -h * 0.38, -h * 0.8, h * 0.76, h * 0.2
    fill(c, rr(dx, dy, dw, dh, 2), rgb(0.12, 0.12, 0.13))
    c.save()
    c.new_path()
    c.rectangle(dx, dy + dh - 5, dw, 5)
    c.clip()
    fill(c, rr(dx, dy + dh - 5, dw, 5, 0), AMBER)
    segs = []
    x = dx
    while x < dx + dw:
        segs.append(((x, dy + dh - 6), (x + 6, dy + dh + 1)))
        x += 7
    lines(c, segs, BLACK, 2.5)
    c.restore()


def _turret_base(c, h, team):
    base = circle(0, 0, h + 2)
    lit(c, base, CONCRETE, 0.8)
    stroke(c, base, rgb(0, 0, 0, 0.5), 1.2)
    for i in range(10):
        a = i * math.pi / 5
        fill(c, circle(math.cos(a) * h * 0.86, math.sin(a) * h * 0.86, 1.8), rgb(0.2, 0.2, 0.2))
    ringp = circle(0, 0, h * 0.66)
    lit(c, ringp, mix(TEAM_COLOR[team], BLACK, 0.35))
    stroke(c, ringp, TEAM_COLOR[team], 1.5)


def _radar(c, h, team):
    """Ringed concrete pad with a lit mounting collar; the dish itself is a separate sprite."""
    pad = _octagon(h * 0.92)
    lit(c, pad, CONCRETE, 0.8)
    stroke(c, pad, rgb(0, 0, 0, 0.5), 1.2)
    for i in range(3):
        r = h * (0.72 - i * 0.16)
        stroke(c, circle(0, 0, r), alpha(TEAM_COLOR[team], 0.35 - i * 0.07), 1.1)
    for i in range(8):
        a = i * math.pi / 4
        fill(c, circle(math.cos(a) * h * 0.8, math.sin(a) * h * 0.8, 1.7), rgb(0.2, 0.2, 0.2))
    collar = circle(0, 0, h * 0.2)
    lit(c, collar, mix(TEAM_COLOR[team], STEEL, 0.35))
    stroke(c, collar, TEAM_COLOR[team], 1.3)
    # Console box at the edge, so the pad does not read as a turret.
    box = rr(-h * 0.78, -h * 0.18, h * 0.3, h * 0.36, 2)
    lit(c, box, rgb(0.3, 0.31, 0.33))
    stroke(c, box, rgb(0, 0, 0, 0.55), 0.9)
    fill(c, circle(-h * 0.63, 0, 1.6), rgb(0.45, 0.95, 0.5))


def _artillery_base(c, h, team):
    """A square gun pit: concrete floor, a sandbag parapet and a lit pivot ring for the carriage."""
    col = TEAM_COLOR[team]
    pit = rr(-h * 0.88, -h * 0.88, h * 1.76, h * 1.76, 6)
    lit(c, pit, CONCRETE, 0.8)
    stroke(c, pit, rgb(0, 0, 0, 0.5), 1.2)
    rnd = random.Random(77)
    for i in range(20):        # sandbags along the parapet
        t = i / 20
        side = int(t * 4)
        u = (t * 4 - side) * 2 - 1
        x, y = ((u * h * 0.8, -h * 0.8), (h * 0.8, u * h * 0.8), (-u * h * 0.8, h * 0.8), (-h * 0.8, -u * h * 0.8))[side]
        bag = ellipse(x - 5.5, y - 3.5, 11, 7)
        lit(c, bag, rgb(0.55 + rnd.uniform(-0.04, 0.04), 0.48, 0.32))
        stroke(c, bag, rgb(0, 0, 0, 0.45), 0.7)
    ringp = circle(0, 0, h * 0.5)
    lit(c, ringp, mix(col, BLACK, 0.35))
    stroke(c, ringp, col, 1.5)
    for i in range(8):
        a = i * math.pi / 4
        fill(c, circle(math.cos(a) * h * 0.42, math.sin(a) * h * 0.42, 1.6), rgb(0.2, 0.2, 0.2))


def artillery_gun(team):
    """The carriage and long barrel that swing on the pit's pivot."""
    def d(c):
        barrel = rr(2, -3.2, 46, 6.4, 1.6)
        linear(c, barrel, [rgb(0.7, 0.72, 0.74), rgb(0.28, 0.29, 0.31)], (0, 3), (0, -3))
        stroke(c, barrel, rgb(0, 0, 0, 0.55), 0.8)
        fill(c, rr(44, -4.4, 7, 8.8, 1.4), GUNMETAL)           # muzzle brake
        for x in (14, 22):
            fill(c, rr(x, -4, 2.5, 8, 0.6), rgb(0.2, 0.2, 0.22))   # recuperator bands
        cradle = rr(-16, -12, 30, 24, 6)
        lit(c, cradle, mix(TEAM_COLOR[team], STEEL, 0.25))
        rim(c, cradle, 0.5)
        stroke(c, cradle, rgb(0, 0, 0, 0.6), 1)
        fill(c, rr(-13, -9, 8, 18, 2), rgb(0.22, 0.23, 0.25))   # breech block
        fill(c, circle(-3, 0, 2.4), rgb(1, 0.35, 0.3))
    return texture(("agun", team), (104, 40), d)


def _shield_gen(c, h, team):
    """An octagonal pad with three pylons around a glowing emitter core."""
    col = TEAM_COLOR[team]
    pad = _octagon(h * 0.9)
    lit(c, pad, CONCRETE, 0.8)
    stroke(c, pad, rgb(0, 0, 0, 0.5), 1.2)
    for i in range(3):
        a = i * 2 * math.pi / 3 - math.pi / 2
        x, y = math.cos(a) * h * 0.58, math.sin(a) * h * 0.58
        pylon = rr(x - 5, y - 5, 10, 10, 2)
        lit(c, pylon, rgb(0.32, 0.33, 0.36))
        stroke(c, pylon, rgb(0, 0, 0, 0.55), 0.9)
        fill(c, circle(x, y, 2.2), rgb(0.45, 0.85, 1.0))
        lines(c, [((x, y), (x * 0.25, y * 0.25))], alpha(rgb(0.45, 0.85, 1.0), 0.5), 1.2)
    core = circle(0, 0, h * 0.26)
    lit(c, core, mix(col, STEEL, 0.4))
    stroke(c, core, col, 1.4)
    fill(c, circle(0, 0, h * 0.13), rgb(0.55, 0.9, 1.0))
    fill(c, circle(-h * 0.04, -h * 0.05, h * 0.05), alpha(WHITE, 0.8))


def _wall(c, h, team):
    """A Barricade: a squat block of poured concrete with a lighter cap, seams, and a team stripe."""
    col = TEAM_COLOR[team]
    body = _silhouette("wall", h)
    lit(c, body, CONCRETE, 0.85)
    cap = rr(-h * 0.84, h * 0.18, h * 1.68, h * 0.44, 2)
    lit(c, cap, mix(CONCRETE, WHITE, 0.18))
    stroke(c, cap, rgb(0, 0, 0, 0.45), 0.9)
    seams = [((-h * 0.3, -h * 0.66), (-h * 0.3, h * 0.1)), ((h * 0.3, -h * 0.66), (h * 0.3, h * 0.1)),
             ((-h * 0.85, -h * 0.28), (h * 0.85, -h * 0.28))]
    lines(c, seams, rgb(0, 0, 0, 0.35), 1.0)
    stripe = rr(-h * 0.8, -h * 0.6, h * 1.6, h * 0.14, 1)
    fill(c, stripe, alpha(col, 0.85))
    stroke(c, body, rgb(0, 0, 0, 0.5), 1.2)


def shield_dome(team):
    """The translucent field drawn over a working generator; the game pulses its alpha."""
    def d(c):
        dome = ellipse(-40, -40, 80, 80)
        fill(c, dome, alpha(rgb(0.45, 0.85, 1.0), 0.16))
        stroke(c, dome, alpha(rgb(0.6, 0.92, 1.0), 0.7), 1.4)
        stroke(c, ellipse(-30, -30, 60, 60), alpha(rgb(0.6, 0.92, 1.0), 0.25), 1)
        fill(c, ellipse(-22, -30, 24, 12), alpha(WHITE, 0.18))
    return texture(("dome", team), (88, 88), d)


def radar_dish(team):
    """The sweeping dish: a lattice parabola on a short mast, drawn on top of the station."""
    def d(c):
        arm = rr(-3, -2.6, 14, 5.2, 1.6)
        lit(c, arm, STEEL)
        stroke(c, arm, rgb(0, 0, 0, 0.5), 0.8)
        back = ellipse(9, -19, 9, 38)
        fill(c, back, alpha(mix(TEAM_COLOR[team], BLACK, 0.25), 0.7))
        face = ellipse(13, -20, 13, 40)
        lit(c, face, rgb(0.88, 0.90, 0.92))
        stroke(c, face, rgb(0, 0, 0, 0.45), 1.1)
        lines(c, [((14, -15 + i * 6), (25, -15 + i * 6)) for i in range(6)], rgb(0, 0, 0, 0.16), 1)
        lines(c, [((19, -19), (19, 19))], rgb(0, 0, 0, 0.16), 1)
        fill(c, rr(24, -2, 9, 4, 1.2), GUNMETAL)            # feed horn on its boom
        fill(c, circle(33, 0, 2.6), TEAM_LIGHT[team])
        fill(c, circle(0, 0, 4.0), rgb(0.26, 0.27, 0.29))
    return texture(("rdish", team), (84, 50), d)


def turret_gun(team):
    def d(c):
        for y in (-4.5, 4.5):
            linear(c, rr(4, y - 2.2, 30, 4.4, 1.2), [rgb(0.7, 0.72, 0.74), rgb(0.3, 0.31, 0.33)], (0, y + 2), (0, y - 2))
            fill(c, rr(31, y - 2.8, 4, 5.6, 1), GUNMETAL)
        body = rr(-13, -11, 25, 22, 7)
        lit(c, body, mix(TEAM_COLOR[team], STEEL, 0.25))
        rim(c, body, 0.5)
        stroke(c, body, rgb(0, 0, 0, 0.6), 1)
        fill(c, circle(5, 0, 2.2), rgb(1, 0.35, 0.3))
    return texture(("tgun", team), (76, 36), d)


def scaffold(half):
    def d(c):
        c.save()
        c.new_path()
        rr(-half, -half, half * 2, half * 2, 6)(c)
        c.clip()
        segs = []
        k = -2 * half
        while k < 2 * half:
            segs.append(((-half, -half + k), (half, half + k)))
            k += 18
        lines(c, segs, alpha(AMBER, 0.55), 2)
        c.restore()
        c.set_dash([8, 5])
        stroke(c, rr(-half, -half, half * 2, half * 2, 6), AMBER, 2.5)
        c.set_dash([])
    return texture(("scaffold", int(half)), (half * 2 + 10, half * 2 + 10), d)


# ---------------------------------------------------------------- crystals & nature

# Gold (variant 3): the same shards in warm metal with a bright edge, so a deposit reads at a glance.
GOLD_FACES = ([rgb(1.0, 0.96, 0.7), rgb(0.95, 0.78, 0.25)], [rgb(0.85, 0.62, 0.15), rgb(0.45, 0.3, 0.05)])
CRYSTAL_FACES = ([rgb(0.75, 1, 1), rgb(0.3, 0.85, 1)], [rgb(0.25, 0.7, 0.95), rgb(0.08, 0.35, 0.6)])


def crystal(variant):
    def d(c):
        left, right = GOLD_FACES if variant == 3 else CRYSTAL_FACES
        rnd = random.Random(100 + variant)
        shards = [(rnd.uniform(-13, 13), rnd.uniform(-18, -6), rnd.uniform(7, 12), rnd.uniform(16, 34), rnd.uniform(-5, 5))
                  for _ in range(5)]
        for (x, y, w, h, tilt) in sorted(shards, key=lambda s: -s[1]):
            bl, bm, br = (x - w / 2, y), (x, y - w * 0.3), (x + w / 2, y)
            tl, tr, tip = (x - w / 2 + tilt, y + h * 0.78), (x + w / 2 + tilt, y + h * 0.78), (x + tilt, y + h)
            linear(c, poly([bl, bm, tip, tl]), left, tip, bm)
            linear(c, poly([bm, br, tr, tip]), right, tip, bm)
            stroke(c, poly([bl, bm, br, tr, tip, tl]), alpha(WHITE, 0.6), 0.8)
            lines(c, [(bm, tip)], alpha(WHITE, 0.5), 0.8)
            lines(c, [((bl[0] + 1.5, bl[1] + 2), (tl[0] + 1.5, tl[1] - 2))], alpha(WHITE, 0.7), 1)
    return texture(("crystal", variant % 4), (54, 60), d)


def tree(variant):
    def d(c):
        rnd = random.Random(200 + variant)
        base = [rgb(0.14, 0.30, 0.13), rgb(0.18, 0.33, 0.12), rgb(0.12, 0.26, 0.16)][variant % 3]
        blobs = [((0, 0), 20)]
        for _ in range(6):
            a = rnd.uniform(0, 2 * math.pi)
            dd = rnd.uniform(9, 17)
            blobs.append(((math.cos(a) * dd, math.sin(a) * dd), rnd.uniform(11, 17)))
        for (p, r) in blobs:
            fill(c, circle(p[0], p[1], r + 1.5), mix(base, BLACK, 0.55))
        for (p, r) in sorted(blobs, key=lambda b: b[0][1] - b[0][0]):
            radial(c, circle(p[0], p[1], r), [mix(base, WHITE, 0.28), base, mix(base, BLACK, 0.35)],
                   (p[0] - r * 0.35, p[1] + r * 0.35), r * 1.3)
        for _ in range(14):
            fill(c, circle(rnd.uniform(-22, 16), rnd.uniform(-14, 22), rnd.uniform(1.5, 3.5)), alpha(mix(base, WHITE, 0.35), 0.5))
    return texture(("tree", variant % 3), (84, 84), d)


def rock(variant):
    def d(c):
        rnd = random.Random(300 + variant)
        pts = []
        for i in range(7):
            a = i / 7 * 2 * math.pi
            r = rnd.uniform(11, 16)
            pts.append((math.cos(a) * r * 1.2, math.sin(a) * r * 0.9))
        p = poly(pts)
        lit(c, p, rgb(0.5, 0.5, 0.47))
        lines(c, [(pts[1], (-2, 1)), ((-2, 1), pts[4])], rgb(0, 0, 0, 0.25), 1)
        stroke(c, p, rgb(0, 0, 0, 0.45), 1)
    return texture(("rock", variant % 4), (44, 36), d)


def tuft():
    def d(c):
        rnd = random.Random(9)
        segs = []
        for _ in range(7):
            x = rnd.uniform(-4, 4)
            segs.append(((x, -5), (x + rnd.uniform(-4, 4), rnd.uniform(1, 7))))
        lines(c, segs, rgb(0.42, 0.55, 0.26), 1.1)
    return texture("tuft", (16, 16), d)


def scorch():
    def d(c):
        rnd = random.Random(11)
        radial(c, None, [rgb(0.02, 0.02, 0.02, 0.6), rgb(0.05, 0.05, 0.05, 0.3), rgb(0, 0, 0, 0)], (0, 0), 30)
        for _ in range(10):
            a = rnd.uniform(0, 2 * math.pi)
            dd = rnd.uniform(10, 24)
            radial(c, None, [rgb(0.05, 0.05, 0.05, 0.35), rgb(0, 0, 0, 0)], (math.cos(a) * dd, math.sin(a) * dd), rnd.uniform(4, 9))
    return texture("scorch", (64, 64), d, 1)


def rubble():
    def d(c):
        rnd = random.Random(13)
        radial(c, None, [rgb(0.03, 0.03, 0.03, 0.65), rgb(0.03, 0.03, 0.03, 0.4), rgb(0, 0, 0, 0)], (0, 0), 46)
        for _ in range(26):
            cx, cy, s = rnd.uniform(-34, 34), rnd.uniform(-34, 34), rnd.uniform(3, 8)
            lit(c, poly([(cx - s, cy), (cx, cy + s * 0.8), (cx + s, cy - s * 0.2), (cx + s * 0.2, cy - s)]), rgb(0.38, 0.37, 0.35))
    return texture("rubble", (96, 96), d)


# ---------------------------------------------------------------- terrain

def _value_noise(n, base_period, octaves, seed):
    rng = np.random.default_rng(seed)
    lattice = rng.random((256, 256), dtype=np.float32)
    u = (np.arange(n, dtype=np.float32) / n)
    total = np.zeros((n, n), dtype=np.float32)
    amp, norm, period = 0.5, 0.0, base_period
    for _ in range(octaves):
        x = u * period
        x0 = np.floor(x).astype(np.int32)
        f = x - x0
        f = f * f * (3 - 2 * f)
        xa, xb = x0 % period, (x0 + 1) % period
        # rows = y, cols = x
        a = lattice[np.ix_(xa, xa)]
        b = lattice[np.ix_(xa, xb)]
        cc = lattice[np.ix_(xb, xa)]
        dd = lattice[np.ix_(xb, xb)]
        fx = f[np.newaxis, :]
        fy = f[:, np.newaxis]
        top = a + (b - a) * fx
        bottom = cc + (dd - cc) * fx
        total += (top + (bottom - top) * fy) * amp
        norm += amp
        amp *= 0.5
        period *= 2
    return total / norm


def map_tint(w, h, seed):
    """A small RGB image that multiplies the whole ground: a sun from the upper left (bright there, a cooler
    shade toward the lower right) and low-frequency biome tints — dry straw, dark forest floor, pale scrub —
    so a map is not one uniform green. Scaled up to the world at bake time."""
    n = 256
    a = _value_noise(n, 2, 3, 40 + seed)
    b = _value_noise(n, 3, 2, 80 + seed)
    ys, xs = np.mgrid[0:n, 0:n].astype(np.float32) / (n - 1)
    sun = 1.10 - 0.16 * (xs + ys) / 2                      # upper-left to lower-right
    dry = np.clip((a - 0.58) / 0.16, 0, 1)                 # straw-coloured patches
    dark = np.clip((0.42 - a) / 0.14, 0, 1)                # forest-floor shade
    scrub = np.clip((b - 0.62) / 0.14, 0, 1) * (1 - dry)   # pale, greyish scrub
    r = 1 + 0.14 * dry - 0.16 * dark + 0.04 * scrub
    g = 1 + 0.06 * dry - 0.10 * dark + 0.00 * scrub
    bl = 1 - 0.14 * dry - 0.06 * dark + 0.06 * scrub
    img = np.stack([r * sun, g * sun, bl * (sun * 0.96 + 0.04)], axis=-1)
    img = (np.clip(img, 0, 1.0) * 255).astype(np.uint8)    # multiply never brightens past the base colour
    surf = pygame.surfarray.make_surface(np.transpose(img, (1, 0, 2)))
    return pygame.transform.smoothscale(surf, (w, h))


def cloud_layer():
    """A seamless 1024-unit tile of soft cloud shadow (alpha only) that drifts over the map."""
    t = _cache.get("clouds")
    if t is not None:
        return t
    n = 1024
    a = _value_noise(n, 2, 3, 9)
    alpha = np.clip((a - 0.52) / 0.30, 0, 1) * 0.26
    img = np.zeros((n, n, 4), np.uint8)
    img[..., 3] = (alpha * 255).astype(np.uint8)
    surf = pygame.image.frombuffer(np.transpose(img, (1, 0, 2)).tobytes(), (n, n), "RGBA")
    surf = surf.convert_alpha() if pygame.display.get_surface() else surf
    _cache["clouds"] = surf
    return surf


def ground_tile():
    """Seamless 1024x1024 grass/dirt tile (1 pixel per world unit)."""
    t = _cache.get("ground")
    if t is not None:
        return t
    n = 1024
    a = _value_noise(n, 4, 5, 1)
    b = _value_noise(n, 3, 4, 2)
    grain = np.random.default_rng(5).random((n, n), dtype=np.float32)
    r = 0.13 + 0.11 * a
    g = 0.21 + 0.14 * a
    bl = 0.11 + 0.06 * a
    dirt = np.clip((b - 0.56) / 0.14, 0, 1) * 0.85
    r += (0.34 + 0.06 * a - r) * dirt
    g += (0.28 + 0.05 * a - g) * dirt
    bl += (0.19 + 0.03 * a - bl) * dirt
    k = 0.9 + 0.2 * grain
    img = np.stack([r * k, g * k, bl * k], axis=-1)
    img = (np.clip(img, 0, 1) * 255).astype(np.uint8)
    surf = pygame.surfarray.make_surface(np.transpose(img, (1, 0, 2)))
    # Grass strokes with wrap-around so the tile stays seamless.
    rnd = random.Random(21)
    light, dark = (102, 133, 64), (13, 26, 10)
    blades = pygame.Surface((n, n), pygame.SRCALPHA)
    for _ in range(2600):
        x, y = rnd.uniform(0, n), rnd.uniform(0, n)
        dx, dy = rnd.uniform(-3, 3), -rnd.uniform(3, 7)
        col = (*(light if rnd.random() < 0.5 else dark), 90)
        for ox in (-n, 0, n):
            for oy in (-n, 0, n):
                px, py = x + ox, y + oy
                if -8 < px < n + 8 and -8 < py < n + 8:
                    pygame.draw.line(blades, col, (px, py), (px + dx, py + dy))
    # Ground clutter, also wrapped: pebbles with a lit edge, tufts of darker grass, and a few wildflowers.
    def wrapped(x, y, r, draw):
        for ox in (-n, 0, n):
            for oy in (-n, 0, n):
                px, py = x + ox, y + oy
                if -r - 2 < px < n + r + 2 and -r - 2 < py < n + r + 2:
                    draw(px, py)
    for _ in range(150):
        x, y = rnd.uniform(0, n), rnd.uniform(0, n)
        w, h = rnd.uniform(3, 7), rnd.uniform(2, 4)
        shade = rnd.uniform(0.78, 1.0)
        base = (int(96 * shade), int(90 * shade), int(82 * shade))
        wrapped(x, y, 8, lambda px, py: (pygame.draw.ellipse(blades, (*base, 210), (px - w / 2, py - h / 2 + 1, w, h)),
                                         pygame.draw.ellipse(blades, (150, 145, 135, 130), (px - w / 2, py - h / 2, w, h - 1))))
    for _ in range(320):
        x, y = rnd.uniform(0, n), rnd.uniform(0, n)
        segs = [(rnd.uniform(-3, 3), -rnd.uniform(4, 8)) for _ in range(3)]
        wrapped(x, y, 10, lambda px, py: [pygame.draw.line(blades, (20, 40, 16, 120), (px + i * 1.5 - 1.5, py), (px + i * 1.5 - 1.5 + dx, py + dy))
                                          for i, (dx, dy) in enumerate(segs)])
    for _ in range(200):
        x, y = rnd.uniform(0, n), rnd.uniform(0, n)
        col = rnd.choice(((232, 210, 90), (222, 120, 140), (238, 238, 240), (150, 120, 220)))
        wrapped(x, y, 3, lambda px, py: pygame.draw.circle(blades, (*col, 200), (px, py), rnd.choice((1, 1, 2))))
    surf.blit(blades, (0, 0))
    t = surf.convert() if pygame.display.get_surface() else surf
    _cache["ground"] = t
    return t


def tread():
    """A short pair of tank tracks pressed into the ground: two dark dashed bands, fading at the ends."""
    def d(c):
        for sy in (-7, 7):
            for i in range(-3, 4):
                a = 0.4 * (1 - abs(i) / 4.0)
                fill(c, rr(i * 4 - 1.5, sy - 2.5, 3, 5, 0.8), rgb(0.06, 0.05, 0.04, a))
    return texture("tread", (32, 24), d, 1)


# ---------------------------------------------------------------- interface

def panel(w, h, radius=10, accent=BUTTON_EDGE, scale=1):
    w, h = int(w), int(h)

    def d(c):
        x0, y0, ww, hh = -w / 2 + 1, -h / 2 + 1, w - 2, h - 2
        p = rr(x0, y0, ww, hh, radius)
        linear(c, p, [rgb(0.11, 0.14, 0.17, 0.97), rgb(0.05, 0.065, 0.08, 0.97)], (0, y0 + hh), (0, y0))
        stroke(c, p, alpha(accent, 0.45), 1.2)
        lines(c, [((x0 + radius, y0 + hh - 1.5), (x0 + ww - radius, y0 + hh - 1.5))], alpha(WHITE, 0.10), 1)
    return texture(("panel", w, h, radius, accent), (w, h), d, scale)


def button(w, h, state, accent=BUTTON_EDGE):
    """state: normal | hover | disabled | active"""
    w, h = int(w), int(h)

    def d(c):
        x0, y0, ww, hh = -w / 2 + 1.5, -h / 2 + 1.5, w - 3, h - 3
        p = rr(x0, y0, ww, hh, 8)
        if state == "normal":
            top, bottom, edge = rgb(0.17, 0.22, 0.27), rgb(0.09, 0.12, 0.15), alpha(accent, 0.8)
        elif state == "hover":
            top, bottom, edge = rgb(0.24, 0.32, 0.40), rgb(0.12, 0.17, 0.22), AMBER
        elif state == "disabled":
            top, bottom, edge = rgb(0.11, 0.12, 0.13), rgb(0.07, 0.08, 0.09), alpha(WHITE, 0.15)
        else:
            top, bottom, edge = alpha(accent, 0.55), alpha(accent, 0.25), accent
        linear(c, p, [top, bottom], (0, y0 + hh), (0, y0))
        lines(c, [((x0 + 7, y0 + hh - 1.5), (x0 + ww - 7, y0 + hh - 1.5))], alpha(WHITE, 0.14), 1)
        stroke(c, p, edge, 2 if state == "hover" else 1.3)
    return texture(("button", w, h, state, accent), (w, h), d, 1)


def icon_attack():
    def d(c):
        t = [((0, 7), (0, 17)), ((0, -7), (0, -17)), ((7, 0), (17, 0)), ((-7, 0), (-17, 0))]
        stroke(c, circle(0, 0, 11), rgb(0, 0, 0, 0.6), 5)
        lines(c, t, rgb(0, 0, 0, 0.6), 5)
        stroke(c, circle(0, 0, 11), BAD, 2.5)
        lines(c, t, BAD, 2.5)
        fill(c, circle(0, 0, 2.5), BAD)
    return texture("icon_attack", (40, 40), d)


def icon_stop():
    def d(c):
        o = _octagon(15)
        lit(c, o, rgb(0.75, 0.2, 0.18))
        stroke(c, o, WHITE, 2)
        fill(c, rr(-7, -2.5, 14, 5, 1), WHITE)
    return texture("icon_stop", (40, 40), d)


def crystal_icon():
    def d(c):
        p = poly([(0, 9), (6, 1), (0, -9), (-6, 1)])
        linear(c, p, [rgb(0.8, 1, 1), rgb(0.2, 0.7, 1)], (-5, 8), (5, -8))
        lines(c, [((0, 9), (0, -9))], alpha(WHITE, 0.6), 0.8)
        stroke(c, p, alpha(WHITE, 0.8), 1)
    return texture("crystal_icon", (20, 20), d)


def alloy_icon():
    """An ingot: a steel-blue bar with a lit top face."""
    def d(c):
        p = poly([(-8, -4), (8, -4), (6, 4), (-6, 4)])
        lit(c, p, rgb(0.55, 0.62, 0.72))
        fill(c, poly([(-6, 4), (6, 4), (5, 8), (-5, 8)]), rgb(0.78, 0.84, 0.92))
        stroke(c, p, rgb(0, 0, 0, 0.5), 1)
        lines(c, [((-4, 0), (4, 0))], alpha(WHITE, 0.35), 1)
    return texture("alloy_icon", (20, 20), d)


def supply_icon():
    def d(c):
        p = rr(-7, -7, 14, 11, 2)
        lit(c, p, rgb(0.85, 0.75, 0.45))
        fill(c, poly([(-8, 4), (0, 9), (8, 4)]), rgb(0.95, 0.85, 0.55))
        stroke(c, p, rgb(0, 0, 0, 0.5), 1)
    return texture("supply_icon", (20, 20), d)


def vignette(w, h):
    key = ("vignette", int(w), int(h))
    t = _cache.get(key)
    if t is None:
        base = texture("vignette_base", (256, 256),
                       lambda c: radial(c, None, [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.5)], (0, 0), 182), 1)
        t = pygame.transform.smoothscale(base, (int(w), int(h)))
        _cache[key] = t
    return t


def app_icon_surface(px):
    """Cairo surface for the application icon (used for window icon and packaging)."""
    def d(c):
        s = 64
        rect = rr(-s * 0.41, -s * 0.41, s * 0.82, s * 0.82, s * 0.19)
        c.save()
        c.new_path()
        rect(c)
        c.clip()
        linear(c, rect, [rgb(0.20, 0.29, 0.17), rgb(0.07, 0.11, 0.07)], (-s / 2, s / 2), (s / 2, -s / 2))
        g = -s * 0.41
        segs = []
        while g < s * 0.41:
            segs += [((g, -s / 2), (g, s / 2)), ((-s / 2, g), (s / 2, g))]
            g += s / 8
        lines(c, segs, alpha(WHITE, 0.07), 0.3)
        for (cx, cy, team) in ((-0.2, -0.2, 0), (0.2, 0.2, 1)):
            b = rr(cx * s - s * 0.13, cy * s - s * 0.13, s * 0.26, s * 0.26, s * 0.03)
            fill(c, b, TEAM_DARK[team])
            stroke(c, b, TEAM_COLOR[team], s * 0.02)
            fill(c, circle(cx * s, cy * s, s * 0.045), TEAM_COLOR[team])
        p = poly([(0, s * 0.17), (s * 0.08, s * 0.02), (0, -s * 0.13), (-s * 0.08, s * 0.02)])
        radial(c, None, [alpha(CRYSTAL, 0.6), alpha(CRYSTAL, 0)], (0, 0), s * 0.2)
        fill(c, p, CRYSTAL)
        stroke(c, p, rgb(0.9, 1, 1), s * 0.012)
        c.restore()
    return render((64, 64), d, px / 64)


def app_icon(px=64):
    return _to_surface(app_icon_surface(px))


# ---------------------------------------------------------------- cursors

def cursors():
    if "cursors" in _cache:
        return _cache["cursors"]
    out = {}

    def attack(c):
        t = [((0, 5), (0, 13)), ((0, -5), (0, -13)), ((5, 0), (13, 0)), ((-5, 0), (-13, 0))]
        stroke(c, circle(0, 0, 9), BLACK, 4.5)
        lines(c, t, BLACK, 4.5)
        stroke(c, circle(0, 0, 9), BAD, 2)
        lines(c, t, BAD, 2)
        fill(c, circle(0, 0, 1.8), BAD)

    def gather(c):
        p = poly([(0, 11), (7, 1), (0, -11), (-7, 1)])
        stroke(c, p, BLACK, 4)
        linear(c, p, [rgb(0.8, 1, 1), rgb(0.2, 0.7, 1)], (-6, 10), (6, -10))
        stroke(c, p, WHITE, 1.3)

    for name, fn in (("attack", attack), ("gather", gather)):
        surf = _to_surface(render((32, 32), fn, 1))
        try:
            out[name] = pygame.cursors.Cursor((16, 16), surf)
        except (pygame.error, TypeError):
            pass
    _cache["cursors"] = out
    return out


# ---------------------------------------------------------------- transformed-sprite cache

class SpriteCache:
    """LRU cache of rotated/zoomed/tinted/faded variants of base textures."""

    def __init__(self, limit=6000):
        self.limit = limit
        self.items = OrderedDict()

    def get(self, key, base, angle_deg, scale, tint=None, fade=255, squash=1.0):
        a = int(round(angle_deg / 5.0)) % 72
        s = round(scale * 40) / 40
        k = (key, a, s, tint, fade, round(squash, 3))
        surf = self.items.get(k)
        if surf is not None:
            self.items.move_to_end(k)
            return surf
        if tint is not None:
            # tint = (r, g, b, amount): blend colour channels toward (r, g, b) by amount/255
            base = base.copy()
            arr = pygame.surfarray.pixels3d(base)
            amt = tint[3] / 255
            arr[:] = (arr * (1 - amt) + np.array(tint[:3], dtype=np.float32) * amt).astype(np.uint8)
            del arr
        if a == 0 and abs(s - 1) < 1e-6:
            surf = base
        elif a == 0:
            w, h = base.get_size()
            surf = pygame.transform.smoothscale(base, (max(1, int(w * s)), max(1, int(h * s))))
        else:
            surf = pygame.transform.rotozoom(base, a * 5.0, s)
        if abs(squash - 1) > 1e-3:
            # Ground-flat images (clouds, decals) foreshorten with the tilt
            surf = pygame.transform.smoothscale(surf, (surf.get_width(), max(1, int(surf.get_height() * squash))))
        if fade < 255:
            surf = surf.copy()
            surf.set_alpha(fade)
        if surf is not base and surf.get_bounding_rect().width == 0 and base.get_bounding_rect().width > 0:
            # The transform came back empty for a base that is not (seen once on the command card): scale the
            # plain way and rotate, and never keep an empty variant.
            w, h = base.get_size()
            surf = pygame.transform.scale(base, (max(1, int(w * s)), max(1, int(h * s))))
            if a != 0:
                surf = pygame.transform.rotate(surf, a * 5.0)
            if fade < 255:
                surf.set_alpha(fade)
            return surf
        self.items[k] = surf
        if len(self.items) > self.limit:
            self.items.popitem(last=False)
        return surf


sprites = SpriteCache()


def forget_icon(icon, tex):
    """Drops every cached form of a command-card icon so the next draw renders it from scratch: the base
    texture, its greyscale copy, and the scaled/faded variants in the sprite cache."""
    for key in [k for k in _cache if isinstance(k, tuple) and k and k[0] in ("bld", "unit", "icon_upgrade", "icon_siege")
                and (len(k) < 2 or k[1] in icon)]:
        _cache.pop(key, None)
    for key in ("icon_attack", "icon_stop", ("grey", id(tex))):
        _cache.pop(key, None)
    # The sprite cache's keys are (key, angle, scale, tint, fade, squash) with key = ("icon", icon, fit, enabled, team):
    # every scaled or faded variant of this icon goes too, or a blank one would be served again next frame.
    for k in [k for k in sprites.items if isinstance(k, tuple) and k and isinstance(k[0], tuple) and len(k[0]) > 1
              and k[0][0] == "icon" and k[0][1] == icon]:
        sprites.items.pop(k, None)


def greyscale(tex):
    """A cached greyscale copy of a texture, alpha untouched — for things that are shown but unavailable."""
    key = ("grey", id(tex))
    g = _cache.get(key)
    if g is None or g[0] is not tex:
        out = tex.copy()
        rgb_ = pygame.surfarray.pixels3d(out)
        lum = (rgb_[..., 0] * 0.30 + rgb_[..., 1] * 0.59 + rgb_[..., 2] * 0.11).astype(np.uint8)
        rgb_[..., 0] = rgb_[..., 1] = rgb_[..., 2] = lum
        del rgb_
        g = (tex, out)            # keep the source alive so id(tex) cannot be reused by another texture
        _cache[key] = g
    return g[1]


def tinted_glow(size, color, level):
    """Glow sprite for additive blending: premultiplied onto black (additive blits ignore alpha),
    tinted to `color` (0-255 RGB) at brightness level 0..8."""
    size = size if isinstance(size, tuple) else (size, size)
    key = ("glowc", size, color, level)
    t = _cache.get(key)
    if t is None:
        g = pygame.transform.smoothscale(glow(), (max(1, size[0]), max(1, size[1])))
        t = pygame.Surface(g.get_size())
        t.fill((0, 0, 0))
        t.blit(g, (0, 0))
        f = level / 8
        t.fill((int(color[0] * f), int(color[1] * f), int(color[2] * f)), special_flags=pygame.BLEND_RGB_MULT)
        _cache[key] = t
    return t


def tinted_blob(size, color, level):
    """Smoke puff sprite with alpha level 0..8."""
    key = ("blobc", size, color, level)
    t = _cache.get(key)
    if t is None:
        g = pygame.transform.smoothscale(blob(), (max(1, size), max(1, size)))
        g.fill((*color, int(255 * level / 8)), special_flags=pygame.BLEND_RGBA_MULT)
        _cache[key] = t = g
    return t


def tint_color(c):
    return to255a(c)


# ---------------------------------------------------------------- terrain features (baked into the ground)

TERRAIN_MARGIN = 22


def _outline(w, h, base, amp, rnd, step=9.0):
    """Closed outline around a centred w x h rectangle, offset outward by base..base+amp with a smooth,
    low-frequency wobble and rounded corners. Never cuts into the rectangle."""
    pts = []
    corners = [(w / 2, -h / 2, -math.pi / 2), (w / 2, h / 2, 0.0), (-w / 2, h / 2, math.pi / 2), (-w / 2, -h / 2, math.pi)]
    edges = [((-w / 2, -h / 2), (w / 2, -h / 2), (0, -1)), ((w / 2, -h / 2), (w / 2, h / 2), (1, 0)),
             ((w / 2, h / 2), (-w / 2, h / 2), (0, 1)), ((-w / 2, h / 2), (-w / 2, -h / 2), (-1, 0))]
    f1, f2 = 2 * math.pi / rnd.uniform(160, 260), 2 * math.pi / rnd.uniform(55, 90)
    p1, p2 = rnd.uniform(0, 6.28), rnd.uniform(0, 6.28)
    s_ = 0.0

    def off():
        return base + amp * (0.5 + 0.3 * math.sin(s_ * f1 + p1) + 0.2 * math.sin(s_ * f2 + p2))

    for i, ((ax, ay), (bx, by), (nx, ny)) in enumerate(edges):
        n = max(1, int(math.hypot(bx - ax, by - ay) / step))
        for k in range(n):
            t = k / n
            o = off()
            pts.append((ax + (bx - ax) * t + nx * o, ay + (by - ay) * t + ny * o))
            s_ += step
        cx, cy, a0 = corners[i]
        for k in range(1, 7):
            a = a0 + k / 7 * (math.pi / 2)
            o = off()
            pts.append((cx + math.cos(a) * o, cy + math.sin(a) * o))
            s_ += step
    return poly(pts)


def water_layers(w, h, seed=1):
    """(shore, water) surfaces for one water rectangle; bake all shores first, then all water, so pieces merge."""
    m = TERRAIN_MARGIN

    def shore(c):
        rnd = random.Random(seed * 7 + 1)
        o = _outline(w, h, 12, m - 12, rnd)
        fill(c, o, rgb(0.46, 0.41, 0.28, 0.92))
        stroke(c, o, rgb(0.30, 0.26, 0.16, 0.4), 2.5)

    def water(c):
        rnd = random.Random(seed)
        o = _outline(w, h, 2, 9, random.Random(seed * 7 + 1))
        linear(c, o, [rgb(0.12, 0.31, 0.42), rgb(0.08, 0.23, 0.33), rgb(0.07, 0.19, 0.28)], (-w, h), (w, -h))
        c.save()
        c.new_path()
        o(c)
        c.clip()
        for _ in range(int(w * h / 4500) + 4):
            x, y = rnd.uniform(-w / 2, w / 2), rnd.uniform(-h / 2, h / 2)
            L = rnd.uniform(10, 26)
            lines(c, [((x - L / 2, y), (x - L / 6, y + 2)), ((x - L / 6, y + 2), (x + L / 2, y))], alpha(WHITE, 0.10), 1.2)
        c.restore()
    size = (w + 2 * m, h + 2 * m)
    return _to_surface(render(size, shore, 1)), _to_surface(render(size, water, 1))


def cliff_layers(w, h, seed=1):
    """(shadow, rock) surfaces for one cliff rectangle."""
    m = TERRAIN_MARGIN

    def shadow(c):
        c.translate(8, -11)
        fill(c, _outline(w, h, 4, 12, random.Random(seed * 3 + 5)), rgb(0, 0, 0, 0.38))

    def rock(c):
        rnd = random.Random(seed)
        outline = _outline(w, h, 4, 12, random.Random(seed * 3 + 5))
        lit(c, outline, rgb(0.33, 0.31, 0.28), 1.1)
        c.save()
        c.new_path()
        outline(c)
        c.clip()
        linear(c, rr(-w / 2 - m, -h / 2 - m, w + 2 * m, h * 0.5 + m, 0),
               [rgb(0.10, 0.09, 0.08, 0.0), rgb(0.10, 0.09, 0.08, 0.72)], (0, 0), (0, -h / 2 - m))
        segs = []
        x = -w / 2 - m
        while x < w / 2 + m:
            segs.append(((x, -h / 2 - m), (x + rnd.uniform(-4, 4), -h * rnd.uniform(0.02, 0.22))))
            x += rnd.uniform(6, 14)
        lines(c, segs, rgb(0.05, 0.05, 0.04, 0.35), 1.2)
        for _ in range(int(w * h / 1000) + 6):
            x, y = rnd.uniform(-w / 2, w / 2), rnd.uniform(-h * 0.1, h / 2 + 6)
            s_ = rnd.uniform(6, 17)
            pts = [(x + math.cos(a) * s_ * rnd.uniform(0.6, 1.1), y + math.sin(a) * s_ * rnd.uniform(0.6, 1.1))
                   for a in [k * 2 * math.pi / 6 for k in range(6)]]
            lit(c, poly(pts), mix(rgb(0.50, 0.48, 0.43), BLACK, rnd.uniform(0, 0.3)))
            stroke(c, poly(pts), rgb(0, 0, 0, 0.3), 1)
        c.restore()
        rim(c, outline, 0.45)
    size = (w + 2 * m, h + 2 * m)
    return _to_surface(render(size, shadow, 1)), _to_surface(render(size, rock, 1))


def _water_body(c, w, h, rnd):
    o = _outline(w, h, 2, 9, rnd)
    linear(c, o, [rgb(0.12, 0.31, 0.42), rgb(0.08, 0.23, 0.33)], (-w, h), (w, -h))


def bridge_ruins(w, h, seed=1):
    key = ("bridgeruins", w, h, seed)
    t = _cache.get(key)
    if t is None:
        t = _cache[key] = _bridge_ruins(w, h, seed)
    return t


def _bridge_ruins(w, h, seed=1):
    """What is left after a bridge comes down: stumps of the piers, a few broken planks in the water,
    and the burnt ends of the deck still clinging to each bank."""
    m = TERRAIN_MARGIN

    def d(c):
        rnd = random.Random(seed + 500)
        # The approaches survive: a short stub of deck at each end, charred where it tore away.
        along_x = w >= h
        span = w if along_x else h
        stub = max(16.0, span * 0.22)          # the approach still standing at each bank
        for near in (True, False):
            if along_x:
                x = -w / 2 + 6 if near else w / 2 - 6 - stub
                piece = rr(x, -h / 2 + 6, stub, h - 12, 3)
            else:
                y = -h / 2 + 6 if near else h / 2 - 6 - stub
                piece = rr(-w / 2 + 6, y, w - 12, stub, 3)
            linear(c, piece, [rgb(0.42, 0.30, 0.18), rgb(0.28, 0.19, 0.11)], (0, h / 2), (0, -h / 2))
            stroke(c, piece, rgb(0.12, 0.08, 0.04, 0.9), 1.4)
        # Pier stumps standing in the stream.
        n = max(2, int(span / 70))
        for i in range(n):
            t = (i + 0.5) / n
            px = (-w / 2 + t * w) if along_x else rnd.uniform(-w / 4, w / 4)
            py = rnd.uniform(-h / 4, h / 4) if along_x else (-h / 2 + t * h)
            post = rr(px - 5, py - 5, 10, 10, 2)
            lit(c, post, rgb(0.33, 0.23, 0.13))
            stroke(c, post, rgb(0.12, 0.08, 0.04, 0.8), 1.2)
            fill(c, circle(px, py, 7), rgb(0.6, 0.7, 0.8, 0.18))       # water disturbed around it
        # Planks adrift.
        for _ in range(7):
            px, py = rnd.uniform(-w / 2, w / 2), rnd.uniform(-h / 2, h / 2)
            ln = rnd.uniform(10, 26)
            a = rnd.uniform(0, math.pi)
            dx, dy = math.cos(a) * ln / 2, math.sin(a) * ln / 2
            lines(c, [((px - dx, py - dy), (px + dx, py + dy))], rgb(0.30, 0.21, 0.12, 0.85), 3)
    return _to_surface(render((w + 2 * m, h + 2 * m), d, 1))


def bridge_patch(w, h, seed=1):
    """A wooden bridge over water, walked along the x axis. Cached: bridges are drawn every frame."""
    key = ("bridgepatch", w, h, seed)
    t = _cache.get(key)
    if t is None:
        t = _cache[key] = _bridge_patch(w, h, seed)
    return t


def _bridge_patch(w, h, seed=1):
    m = TERRAIN_MARGIN

    def d(c):
        rnd = random.Random(seed)
        deck = rr(-w / 2, -h / 2 + 6, w, h - 12, 4)
        fill(c, rr(-w / 2 + 6, -h / 2 - 2, w, h - 12, 4), rgb(0, 0, 0, 0.35))
        linear(c, deck, [rgb(0.58, 0.43, 0.26), rgb(0.44, 0.31, 0.18)], (0, h / 2), (0, -h / 2))
        segs = []
        x = -w / 2 + 12
        while x < w / 2:
            segs.append(((x, -h / 2 + 7), (x, h / 2 - 7)))
            x += 12 + rnd.uniform(-1, 1)
        lines(c, segs, rgb(0.25, 0.17, 0.09, 0.8), 1.4)
        for y in (-h / 2 + 8, h / 2 - 8):
            rail = rr(-w / 2, y - 4, w, 8, 3)
            lit(c, rail, rgb(0.40, 0.28, 0.15))
            for px in range(int(-w / 2) + 8, int(w / 2), 40):
                fill(c, circle(px, y, 3.2), rgb(0.22, 0.15, 0.08))
        stroke(c, deck, rgb(0.20, 0.13, 0.06, 0.9), 1.5)
    return _to_surface(render((w + 2 * m, h + 2 * m), d, 1))
