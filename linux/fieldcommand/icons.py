"""Writes the application icon as PNGs for packaging (only needs pycairo)."""
import os


def write_icons(out_dir):
    from .art import app_icon_surface
    for px in (16, 32, 48, 64, 128, 256, 512):
        d = os.path.join(out_dir, f"{px}x{px}", "apps")
        os.makedirs(d, exist_ok=True)
        app_icon_surface(px).write_to_png(os.path.join(d, "field-command.png"))
