"""Fonts, cached text rendering and small drawing helpers shared by the HUD and menu."""
from collections import OrderedDict

import pygame

from .defs import to255

# Candidates in preference order; SysFont takes the first that is installed. The list covers Linux
# (Noto/Cantarell/DejaVu), Windows (Segoe UI/Consolas) and macOS (Helvetica Neue/Menlo).
SANS = "notosans,cantarell,dejavusans,liberationsans,segoeui,helveticaneue,helvetica,arial"
MONO = "notosansmono,dejavusansmono,liberationmono,consolas,menlo,monospace"
_fonts = {}
_text = OrderedDict()


def font(size, bold=False, mono=False):
    key = (int(size), bold, mono)
    f = _fonts.get(key)
    if f is None:
        f = pygame.font.SysFont(MONO if mono else SANS, int(size), bold=bold)
        _fonts[key] = f
    return f


def text(s, size, color, bold=False, mono=False):
    """Rendered text surface (cached). `color` may be float RGBA or 0-255 RGB."""
    c = to255(color) if isinstance(color[0], float) else tuple(color[:3])
    key = (s, int(size), c, bold, mono)
    img = _text.get(key)
    if img is None:
        img = font(size, bold, mono).render(s, True, c)
        _text[key] = img
        if len(_text) > 1500:
            _text.popitem(last=False)
    else:
        _text.move_to_end(key)
    return img


def blit_text(screen, s, size, color, pos, align="left", valign="center", bold=False, mono=False, shadow=False):
    img = text(s, size, color, bold, mono)
    x, y = pos
    w, h = img.get_size()
    if align == "center":
        x -= w / 2
    elif align == "right":
        x -= w
    if valign == "center":
        y -= h / 2
    elif valign == "bottom":
        y -= h
    if shadow:
        screen.blit(text(s, size, (0, 0, 0), bold, mono), (x + 1, y + 1.5))
    screen.blit(img, (x, y))
    return pygame.Rect(int(x), int(y), w, h)


def wrap(s, size, width, bold=False):
    f = font(size, bold)
    out = []
    for para in s.split("\n"):
        line = ""
        for word in para.split(" "):
            trial = (line + " " + word).strip()
            if f.size(trial)[0] <= width or not line:
                line = trial
            else:
                out.append(line)
                line = word
        out.append(line)
    return out


def dashed_line(screen, color, a, b, phase, dash=7, gap=6, width=2):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    length = (dx * dx + dy * dy) ** 0.5
    if length < 1:
        return
    ux, uy = dx / length, dy / length
    period = dash + gap
    t = -(phase % period)
    while t < length:
        s0 = max(0.0, t)
        s1 = min(length, t + dash)
        if s1 > s0:
            pygame.draw.line(screen, color, (ax + ux * s0, ay + uy * s0), (ax + ux * s1, ay + uy * s1), width)
        t += period
