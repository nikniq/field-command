"""Fog-of-war visibility grid (numpy only, so the server can use it without pygame)."""
import math

import numpy as np

from . import defs


class FogGrid:
    cell = 20

    def __init__(self):
        self.cols = int(math.ceil(defs.WORLD_W / self.cell))
        self.rows = int(math.ceil(defs.WORLD_H / self.cell))
        shape = (self.rows, self.cols)
        self.visible = np.zeros(shape, dtype=bool)
        self.explored = np.zeros(shape, dtype=bool)
        self.reveal_all = False
        self.version = 0
        self._disks = {}

    def _disk(self, n):
        d = self._disks.get(n)
        if d is None:
            y, x = np.mgrid[-n:n + 1, -n:n + 1]
            d = (x * x + y * y) <= (n + 0.3) ** 2
            self._disks[n] = d
        return d

    def recompute(self, viewers):
        self.visible[:] = False
        c = self.cell
        for (x, y, r) in viewers:
            cx, cy, n = int(x // c), int(y // c), int(r // c)
            mask = self._disk(n)
            x0, x1, y0, y1 = cx - n, cx + n + 1, cy - n, cy + n + 1
            mx0, my0 = max(0, -x0), max(0, -y0)
            mx1 = mask.shape[1] - max(0, x1 - self.cols)
            my1 = mask.shape[0] - max(0, y1 - self.rows)
            if mx0 >= mx1 or my0 >= my1:
                continue
            self.visible[max(0, y0):min(self.rows, y1), max(0, x0):min(self.cols, x1)] |= mask[my0:my1, mx0:mx1]
        self.explored |= self.visible
        self.version += 1

    def _idx(self, x, y):
        cx, cy = int(x // self.cell), int(y // self.cell)
        if 0 <= cx < self.cols and 0 <= cy < self.rows:
            return cy, cx
        return None

    def is_visible(self, x, y):
        if self.reveal_all:
            return True
        i = self._idx(x, y)
        return bool(self.visible[i]) if i else False

    def is_explored(self, x, y):
        if self.reveal_all:
            return True
        i = self._idx(x, y)
        return bool(self.explored[i]) if i else False

    def any_visible(self, r):
        if self.reveal_all:
            return True
        c = self.cell
        x0, x1 = max(0, int(r[0] // c)), min(self.cols - 1, int(r[2] // c))
        y0, y1 = max(0, int(r[1] // c)), min(self.rows - 1, int(r[3] // c))
        if x0 > x1 or y0 > y1:
            return False
        return bool(self.visible[y0:y1 + 1, x0:x1 + 1].any())
