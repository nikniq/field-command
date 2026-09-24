"""Organic terrain rendering: water and cliffs are drawn from a blurred, noise-warped mask of the map's wall
rectangles, so overlapping pieces merge into natural lakes, rivers and ridges. Collision still uses the rects;
the drawn shape always covers them and extends a little beyond.
"""
import math

import numpy as np
import pygame

from .art import _value_noise
from . import defs

RES = 2  # world units per pixel of the working buffers (mega maps use a coarser buffer, see _res)


def _res():
    """Keep the working buffers about 2000 x 1400 whatever the map size, so big maps cost no more memory."""
    return max(RES, int(math.ceil(defs.WORLD_W / 2000)))


def _mask(rects, W, H, res):
    m = np.zeros((H, W), np.float32)
    for x0, y0, x1, y1 in rects:
        # rect in world coords (y up) -> buffer rows (y down)
        c0, c1 = int(max(0, x0 // res)), int(min(W, -(-x1 // res)))
        r0, r1 = int(max(0, (defs.WORLD_H - y1) // res)), int(min(H, -(-(defs.WORLD_H - y0) // res)))
        m[r0:r1, c0:c1] = 1.0
    return m


def _blur(a, r, passes=3):
    """Separable box blur, repeated to approximate a gaussian."""
    for _ in range(passes):
        for axis in (0, 1):
            p = np.pad(a, [(r + 1, r) if ax == axis else (0, 0) for ax in range(2)], mode="edge")
            c = np.cumsum(p, axis=axis, dtype=np.float32)
            if axis == 0:
                a = (c[2 * r + 1:] - c[:-2 * r - 1]) / (2 * r + 1)
            else:
                a = (c[:, 2 * r + 1:] - c[:, :-2 * r - 1]) / (2 * r + 1)
    return a


def _noise(W, H, period, octaves, seed):
    """Smooth value noise in [-1, 1]; `period` is the feature size in buffer pixels."""
    n = max(W, H)
    base = _value_noise(n, max(2, min(int(n / period), 256 >> (octaves - 1))), octaves, seed)
    return base[:H, :W] * 2 - 1


def _smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def _lerp(a, b, t):
    return a + (np.asarray(b, np.float32) - a) * t[..., None]


def render(map_spec):
    """Returns a world-sized RGBA surface of all water, cliffs and high ground (or None when the map has none)."""
    walls = map_spec.get("walls", [])
    ridges = map_spec.get("ridges", [])
    if not walls and not ridges:
        return None
    res = _res()
    W, H = int(defs.WORLD_W) // res, int(defs.WORLD_H) // res
    seed = int(map_spec.get("seed", 1))
    rgb = np.zeros((H, W, 3), np.float32)
    alpha = np.zeros((H, W), np.float32)
    warp = _noise(W, H, 150 / res, 3, seed + 11)  # low-frequency wobble of the outlines
    fine = _noise(W, H, 40 / res, 2, seed + 12)

    water = [w[:4] for w in walls if w[4] == "water"] + [tuple(b) for b in map_spec.get("bridges", [])]
    if any(w[4] == "water" for w in walls):
        b = _blur(_mask(water, W, H, res), max(6, int(32 / res)))
        f = b + warp * 0.24 * _smooth(0.0, 0.2, b)  # wobble only near the water
        shore = _smooth(0.10, 0.17, f)
        wet = _smooth(0.28, 0.33, f)
        depth = _smooth(0.35, 0.95, f + fine * 0.04)
        sand = np.array([118, 104, 70], np.float32) + fine[..., None] * 14
        col = _lerp(sand, (70, 58, 36), _smooth(0.18, 0.28, f))  # damp mud next to the water
        shallow = np.array([46, 112, 128], np.float32)
        deep = np.array([16, 50, 76], np.float32)
        wc = _lerp(np.broadcast_to(shallow, col.shape).copy(), deep, depth)
        ripple = np.sin(np.arange(H)[:, None] * 0.5 + np.arange(W)[None, :] * 0.04 + fine * 2.5) * 0.5 + 0.5
        patchy = _smooth(0.0, 0.6, _noise(W, H, 30, 2, seed + 13))
        wc += (ripple ** 14 * patchy)[..., None] * 30 * (0.4 + depth[..., None])
        foam = np.exp(-((f - 0.315) / 0.018) ** 2)
        wc += foam[..., None] * 60
        col = col * (1 - wet[..., None]) + wc * wet[..., None]
        rgb = rgb * (1 - shore[..., None]) + col * shore[..., None]
        alpha = np.maximum(alpha, shore * 0.97)

    cliffs = [w[:4] for w in walls if w[4] == "cliff"]
    if cliffs:
        b = _blur(_mask(cliffs, W, H, res), max(5, int(20 / res)))
        f = b + warp * 0.22 * _smooth(0.0, 0.2, b)
        body = _smooth(0.24, 0.30, f)
        # height field -> lighting (light from the top-left of the screen); fine noise makes it craggy
        hgt = _smooth(0.22, 0.75, f) * 40 + (fine * 9 + np.abs(warp) * 8) * _smooth(0.2, 0.5, f)
        gy, gx = np.gradient(hgt)
        light = np.clip(0.62 + gx * 0.20 + gy * 0.26, 0.15, 1.25)
        top = _smooth(0.55, 0.75, f)
        rock = _lerp(np.broadcast_to(np.array([92, 86, 76], np.float32), f.shape + (3,)).copy(), (128, 122, 108), top)
        rock += fine[..., None] * 26
        rock = rock * light[..., None]
        # cast shadow down-right
        sh = np.roll(np.roll(body, 7, axis=0), 5, axis=1) * (1 - body)
        rgb = rgb * (1 - sh[..., None] * 0.4)
        alpha = np.maximum(alpha, sh * 0.4)
        rgb = rgb * (1 - body[..., None]) + rock * body[..., None]
        alpha = np.maximum(alpha, body)

    if ridges:
        # High ground: a raised plateau of drier grass with a lit rim toward the light and a soft cast shadow
        # down-right, so it reads as a step up rather than a patch of colour.
        b = _blur(_mask([tuple(r[:4]) for r in ridges], W, H, res), max(4, int(14 / res)))
        f = b + warp * 0.12 * _smooth(0.0, 0.3, b)
        body = _smooth(0.36, 0.44, f)
        hgt = _smooth(0.32, 0.62, f) * 18 + fine * 3 * _smooth(0.3, 0.6, f)
        gy, gx = np.gradient(hgt)
        light = np.clip(0.80 + gx * 0.30 + gy * 0.36, 0.45, 1.35)
        grass = np.broadcast_to(np.array([112, 126, 66], np.float32), f.shape + (3,)).copy() + fine[..., None] * 12
        grass = grass * light[..., None]
        sh = np.roll(np.roll(body, 4, axis=0), 3, axis=1) * (1 - body)
        rgb = rgb * (1 - sh[..., None] * 0.35)
        alpha = np.maximum(alpha, sh * 0.35)
        rgb = rgb * (1 - body[..., None]) + grass * body[..., None]
        alpha = np.maximum(alpha, body)

    # rgb currently holds colour already weighted by coverage for cliffs' shadow; un-premultiply
    out = np.zeros((H, W, 4), np.uint8)
    a = np.clip(alpha, 1e-4, 1)
    out[..., :3] = np.clip(rgb / a[..., None], 0, 255).astype(np.uint8)
    out[..., 3] = (np.clip(alpha, 0, 1) * 255).astype(np.uint8)
    surf = pygame.image.frombuffer(out.tobytes(), (W, H), "RGBA")
    return pygame.transform.smoothscale(surf, (int(defs.WORLD_W), int(defs.WORLD_H)))
