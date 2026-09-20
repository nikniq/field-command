"""Player preferences, stored where the platform keeps them:

    Windows          %APPDATA%\\FieldCommand\\settings.json
    everywhere else  $XDG_CONFIG_HOME/fieldcommand/settings.json (or ~/.config/...)
"""
import json
import os
import sys

SPEEDS = [("Slow", 0.75), ("Normal", 1.0), ("Fast", 1.35), ("Faster", 1.7)]


def _path():
    if sys.platform == "win32":
        base = os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Roaming")
        return os.path.join(base, "FieldCommand", "settings.json")
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "fieldcommand", "settings.json")


class _Settings:
    defaults = {"speed_index": 1, "edge_scroll": True, "sound": True, "objectives": True,
                "last_difficulty": 1, "fullscreen": False,
                "player_name": "", "last_address": "", "map_id": "twin_ridges", "opponents": 1}

    def __init__(self):
        self._data = dict(self.defaults)
        try:
            with open(_path()) as f:
                self._data.update(json.load(f))
        except (OSError, ValueError):
            pass

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        return self._data.get(name, self.defaults.get(name))

    def set(self, name, value):
        self._data[name] = value
        try:
            os.makedirs(os.path.dirname(_path()), exist_ok=True)
            with open(_path(), "w") as f:
                json.dump(self._data, f, indent=2)
        except OSError:
            pass

    def toggle(self, name):
        self.set(name, not self._data.get(name))

    def cycle_speed(self):
        self.set("speed_index", (self.speed_index + 1) % len(SPEEDS))

    def cycle_map(self):
        from .mapgen import CATALOG
        ids = [m["id"] for m in CATALOG]
        i = ids.index(self.map_id) if self.map_id in ids else -1
        self.set("map_id", ids[(i + 1) % len(ids)])
        self.set("opponents", min(self.opponents, self.max_opponents))

    @property
    def max_opponents(self):
        from .mapgen import BY_ID
        return BY_ID.get(self.map_id, {"players": 2})["players"] - 1

    def cycle_opponents(self):
        self.set("opponents", self.opponents % self.max_opponents + 1)

    @property
    def game_speed(self):
        return SPEEDS[self.speed_index % len(SPEEDS)][1]

    @property
    def speed_name(self):
        return SPEEDS[self.speed_index % len(SPEEDS)][0]


settings = _Settings()
