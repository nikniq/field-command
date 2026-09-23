"""Renders a FogGrid as a soft, eased overlay (pygame)."""
import numpy as np
import pygame

FOG_RGB = (5, 8, 13)


class FogView:
    def __init__(self, grid):
        self.grid = grid
        self.cols, self.rows, self.cell = grid.cols, grid.rows, grid.cell
        self.shade = np.full((self.rows, self.cols), 0.93, dtype=np.float32)
        self.surface = pygame.Surface((self.cols, self.rows), pygame.SRCALPHA)
        self.surface.fill((*FOG_RGB, 240))
        self._seen_version = -1

    def update(self, dt):
        """Eases shading toward the target and refreshes the overlay; returns True when it changed."""
        g = self.grid
        if g.reveal_all:
            target = np.zeros_like(self.shade)
        else:
            target = np.where(g.visible, 0.0, np.where(g.explored, 0.5, 0.93)).astype(np.float32)
        d = target - self.shade
        moving = np.abs(d) > 0.003
        if not moving.any() and self._seen_version == g.version:
            return False
        self._seen_version = g.version
        k = min(1.0, dt * 6)
        self.shade += np.where(np.abs(d) < 0.01, d, d * k)
        s = self.shade
        p = np.pad(s, 1, mode="edge")
        b = s * 0.4 + (p[1:-1, :-2] + p[1:-1, 2:] + p[:-2, 1:-1] + p[2:, 1:-1]) * 0.15
        a = pygame.surfarray.pixels_alpha(self.surface)
        a[:] = (np.clip(b, 0, 1) * 255).astype(np.uint8)[::-1, :].T
        del a
        return True

    def draw(self, screen, cam):
        vx0, vy0, vx1, vy1 = cam.view_rect()
        c = self.cell
        cx0 = max(0, int(vx0 // c) - 1)
        cx1 = min(self.cols, int(vx1 // c) + 2)
        cy0 = max(0, int(vy0 // c) - 1)
        cy1 = min(self.rows, int(vy1 // c) + 2)
        if cx0 >= cx1 or cy0 >= cy1:
            return
        sub = self.surface.subsurface((cx0, self.rows - cy1, cx1 - cx0, cy1 - cy0))
        from .game import TILT
        w = int(round((cx1 - cx0) * c / cam.zoom))
        h = int(round((cy1 - cy0) * c * TILT / cam.zoom))
        img = pygame.transform.smoothscale(sub, (max(1, w), max(1, h)))
        sx, sy = cam.to_screen(cx0 * c, cy1 * c)
        screen.blit(img, (int(sx), int(sy)))
