"""Navigation grid and A* pathfinding (pure Python, no pygame).

The map is divided into 40-unit cells. A cell is blocked if its centre lies inside a wall, building, tree or
crystal, padded by CLEARANCE so unit bodies keep off the edges. Units walk straight at their goal when the line
is clear, and otherwise follow a smoothed A* path. The grid is rebuilt when buildings appear or disappear.
"""
import heapq
import math

from . import defs

CELL = 40.0
CLEARANCE = 14.0
_SQRT2 = math.sqrt(2)
_NEIGHBOURS = [(1, 0, 1.0), (-1, 0, 1.0), (0, 1, 1.0), (0, -1, 1.0),
               (1, 1, _SQRT2), (1, -1, _SQRT2), (-1, 1, _SQRT2), (-1, -1, _SQRT2)]


class NavGrid:
    def __init__(self):
        self.cols = int(math.ceil(defs.WORLD_W / CELL))
        self.rows = int(math.ceil(defs.WORLD_H / CELL))
        self.blocked = bytearray(self.cols * self.rows)
        self.version = 0

    # ------------------------------------------------------------ building the grid

    def rebuild(self, rects, circles):
        """rects: [(x0, y0, x1, y1)], circles: [(x, y, r)] of impassable space."""
        b = bytearray(self.cols * self.rows)
        cols, rows = self.cols, self.rows
        pad = CLEARANCE
        for (x0, y0, x1, y1) in rects:
            cx0 = max(0, int((x0 - pad) // CELL))
            cx1 = min(cols - 1, int((x1 + pad) // CELL))
            cy0 = max(0, int((y0 - pad) // CELL))
            cy1 = min(rows - 1, int((y1 + pad) // CELL))
            for cy in range(cy0, cy1 + 1):
                py = (cy + 0.5) * CELL
                if py < y0 - pad or py > y1 + pad:
                    continue
                row = cy * cols
                for cx in range(cx0, cx1 + 1):
                    px = (cx + 0.5) * CELL
                    if x0 - pad <= px <= x1 + pad:
                        b[row + cx] = 1
        for (x, y, r) in circles:
            rr = r + pad
            cx0, cx1 = max(0, int((x - rr) // CELL)), min(cols - 1, int((x + rr) // CELL))
            cy0, cy1 = max(0, int((y - rr) // CELL)), min(rows - 1, int((y + rr) // CELL))
            r2 = rr * rr
            for cy in range(cy0, cy1 + 1):
                dy = (cy + 0.5) * CELL - y
                for cx in range(cx0, cx1 + 1):
                    dx = (cx + 0.5) * CELL - x
                    if dx * dx + dy * dy <= r2:
                        b[cy * cols + cx] = 1
        self.blocked = b
        self.version += 1

    # ------------------------------------------------------------ queries

    def cell(self, x, y):
        return (min(self.cols - 1, max(0, int(x // CELL))), min(self.rows - 1, max(0, int(y // CELL))))

    def center(self, cx, cy):
        return ((cx + 0.5) * CELL, (cy + 0.5) * CELL)

    def is_blocked(self, cx, cy):
        return self.blocked[cy * self.cols + cx] == 1

    def line_clear(self, x0, y0, x1, y1, ignore_end=0.0):
        """True if the straight line crosses no blocked cell. The first cell and the final `ignore_end` units
        (e.g. the target building's own footprint) are not checked."""
        d = math.hypot(x1 - x0, y1 - y0)
        length = d - ignore_end
        if length <= 0:
            return True
        step = CELL * 0.4
        n = int(length / step)
        if n <= 0:
            return True
        ux, uy = (x1 - x0) / d, (y1 - y0) / d
        start = self.cell(x0, y0)
        cols, blocked = self.cols, self.blocked
        for i in range(1, n + 1):
            t = i * step
            cx, cy = int((x0 + ux * t) // CELL), int((y0 + uy * t) // CELL)
            if (cx, cy) == start:
                continue
            if cx < 0 or cy < 0 or cx >= cols or cy >= self.rows or blocked[cy * cols + cx]:
                return False
        return True

    def nearest_free(self, cx, cy, max_r=8):
        if not self.is_blocked(cx, cy):
            return cx, cy
        best, best_d = None, 1e9
        for r in range(1, max_r + 1):
            for dy in range(-r, r + 1):
                for dx in range(-r, r + 1):
                    if max(abs(dx), abs(dy)) != r:
                        continue
                    x, y = cx + dx, cy + dy
                    if 0 <= x < self.cols and 0 <= y < self.rows and not self.blocked[y * self.cols + x]:
                        d = dx * dx + dy * dy
                        if d < best_d:
                            best, best_d = (x, y), d
            if best:
                return best
        return cx, cy

    # ------------------------------------------------------------ A*

    def find_path(self, x0, y0, x1, y1, max_nodes=9000):
        """Waypoints from (x0, y0) toward (x1, y1), ending at the goal itself. If the goal is unreachable the
        path leads to the reachable cell closest to it. Returns [] when the line is already clear."""
        cols, rows, blocked = self.cols, self.rows, self.blocked
        sx, sy = self.nearest_free(*self.cell(x0, y0))
        gx, gy = self.nearest_free(*self.cell(x1, y1))
        start, goal = sy * cols + sx, gy * cols + gx
        if start == goal:
            return [(x1, y1)]

        def h(i):
            dx, dy = abs(i % cols - gx), abs(i // cols - gy)
            return (dx + dy) + (_SQRT2 - 2) * min(dx, dy)

        g = {start: 0.0}
        came = {}
        open_ = [(h(start), start)]
        closed = set()
        best, best_h = start, h(start)
        expanded = 0
        while open_:
            _, cur = heapq.heappop(open_)
            if cur in closed:
                continue
            if cur == goal:
                best = goal
                break
            closed.add(cur)
            expanded += 1
            if expanded > max_nodes:
                break
            hc = h(cur)
            if hc < best_h:
                best, best_h = cur, hc
            cx, cy = cur % cols, cur // cols
            gc = g[cur]
            for dx, dy, cost in _NEIGHBOURS:
                nx, ny = cx + dx, cy + dy
                if nx < 0 or ny < 0 or nx >= cols or ny >= rows:
                    continue
                ni = ny * cols + nx
                if blocked[ni] or ni in closed:
                    continue
                if dx and dy and (blocked[cy * cols + nx] or blocked[ny * cols + cx]):
                    continue  # no corner cutting
                ng = gc + cost
                if ng < g.get(ni, 1e18):
                    g[ni] = ng
                    came[ni] = cur
                    heapq.heappush(open_, (ng + h(ni), ni))
        # Reconstruct
        cells = [best]
        while cells[-1] in came:
            cells.append(came[cells[-1]])
        cells.reverse()
        pts = [self.center(i % cols, i // cols) for i in cells[1:]]
        if best == goal:
            pts.append((x1, y1))
        return self._smooth((x0, y0), pts)

    def _smooth(self, origin, pts):
        """String-pulling: skip waypoints that can be seen directly from the previous kept point."""
        if len(pts) <= 1:
            return pts
        out = []
        anchor = origin
        i = 0
        while i < len(pts):
            j = len(pts) - 1
            while j > i and not self.line_clear(anchor[0], anchor[1], pts[j][0], pts[j][1]):
                j -= 1
            out.append(pts[j])
            anchor = pts[j]
            i = j + 1
        return out
