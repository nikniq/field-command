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
    defaults = {"speed_index": 1, "edge_scroll": True, "sound": True, "music": True, "objectives": True,
                "last_difficulty": 1, "fullscreen": False,
                "player_name": "", "last_address": "", "map_id": "twin_ridges", "opponents": 1,
                "teams": 0,   # 0 = free-for-all, otherwise the number of teams the players are dealt into
                "campaign_done": [],   # mission ids completed, in any order
                "bars_always": False,  # health bars on everything, not only the hurt and the selected
                "ui_scale": 0,  # 0 = automatic from the screen size, otherwise 1, 1.5 or 2
                "keys": {},     # action -> key name, where it differs from defs.DEFAULT_KEYS
                "tutorial_done": False,   # the first-run arrows have been walked through (or a game played out)
                "career": {}}             # "wins", "losses", and "wins_<difficulty>" / "losses_<difficulty>"

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

    def key(self, action):
        """The key name bound to an action (see defs.KEY_ACTIONS)."""
        from .defs import DEFAULT_KEYS
        return (self._data.get("keys") or {}).get(action, DEFAULT_KEYS[action])

    def bind(self, action, name):
        """Binds `action` to key `name`; a key already used by another action is taken from it."""
        from .defs import DEFAULT_KEYS
        keys = dict(self._data.get("keys") or {})
        for other in DEFAULT_KEYS:
            if other != action and self.key(other) == name:
                keys[other] = ""                      # unbound until the player picks a key for it
        keys[action] = name
        self.set("keys", keys)

    def reset_keys(self):
        self.set("keys", {})

    def record_result(self, won, difficulty):
        """One more game played out, single player: the career record grows by a win or a loss."""
        c = dict(self._data.get("career") or {})
        for k in (("wins" if won else "losses"), f"{'wins' if won else 'losses'}_{difficulty}"):
            c[k] = int(c.get(k, 0)) + 1
        self.set("career", c)

    def career_text(self):
        c = self._data.get("career") or {}
        w, l = int(c.get("wins", 0)), int(c.get("losses", 0))
        if w + l == 0:
            return "No games played out yet"
        return f"Career: {w} won · {l} lost · {100 * w // (w + l)}%"

    def cycle_speed(self):
        self.set("speed_index", (self.speed_index + 1) % len(SPEEDS))

    def cycle_map(self):
        from .mapgen import CATALOG
        ids = [m["id"] for m in CATALOG]
        i = ids.index(self.map_id) if self.map_id in ids else -1
        self.set("map_id", ids[(i + 1) % len(ids)])
        self.set("opponents", min(self.opponents, self.max_opponents))
        self._clamp_teams()

    @property
    def max_opponents(self):
        from .mapgen import BY_ID
        return BY_ID.get(self.map_id, {"players": 2})["players"] - 1

    def cycle_opponents(self):
        self.set("opponents", self.opponents % self.max_opponents + 1)
        self._clamp_teams()

    # Teams for a single-player game. Players are dealt round-robin into `teams` alliances — the same rule
    # as the multiplayer lobby's presets — so with three opponents, "2 teams" is you and Computer 2 against
    # Computers 1 and 3.

    @property
    def team_options(self):
        """0 (free-for-all) plus every team count that is not just free-for-all by another name."""
        players = 1 + min(self.opponents, self.max_opponents)
        return [0] + [c for c in (2, 3, 4) if c < players]

    @property
    def team_count(self):
        return self.teams if self.teams in self.team_options else 0

    def cycle_teams(self):
        opts = self.team_options
        i = opts.index(self.team_count)
        self.set("teams", opts[(i + 1) % len(opts)])

    def _clamp_teams(self):
        if self.teams not in self.team_options:
            self.set("teams", 0)

    # UI scale. The interface is drawn at a logical size and scaled up, so on a 4K or HiDPI screen the buttons
    # and icons stay the size they were designed at instead of shrinking to specks.

    UI_SCALES = (0, 1, 1.5, 2)

    @staticmethod
    def auto_ui_scale(w, h):
        """2x on 4K-class screens, 1.5x on 1440p-class, otherwise 1x — judged by the shorter side."""
        short = min(w, h)
        return 2 if short >= 1600 else (1.5 if short >= 1200 else 1)

    def ui_scale_for(self, w, h):
        return self.auto_ui_scale(w, h) if not self.ui_scale else self.ui_scale

    def cycle_ui_scale(self):
        opts = list(self.UI_SCALES)
        cur = self.ui_scale if self.ui_scale in opts else 0
        self.set("ui_scale", opts[(opts.index(cur) + 1) % len(opts)])

    @property
    def game_speed(self):
        return SPEEDS[self.speed_index % len(SPEEDS)][1]

    @property
    def speed_name(self):
        return SPEEDS[self.speed_index % len(SPEEDS)][0]


settings = _Settings()
