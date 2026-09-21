"""Procedurally synthesised sound effects (no audio files needed)."""
import numpy as np
import pygame

from .settings import settings

RATE = 22050
_sounds = {}
_enabled = False
_last_played = {}


def _env(n, attack=0.005, decay=None):
    t = np.arange(n) / RATE
    a = np.minimum(1.0, t / max(attack, 1e-4))
    d = np.exp(-t / decay) if decay else np.ones(n)
    return a * d


def _noise(n, rng):
    return rng.uniform(-1, 1, n)


def _tone(freq, n, kind="sine"):
    t = np.arange(n) / RATE
    if kind == "square":
        return np.sign(np.sin(2 * np.pi * freq * t))
    return np.sin(2 * np.pi * freq * t)


def _lowpass(x, k):
    out = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += k * (v - acc)
        out[i] = acc
    return out


def _make(samples, volume):
    samples = np.clip(samples * volume, -1, 1)
    pcm = (samples * 32767).astype(np.int16)
    channels = pygame.mixer.get_init()[2]
    if channels == 2:
        pcm = np.column_stack([pcm, pcm])
    return pygame.sndarray.make_sound(np.ascontiguousarray(pcm))


def init():
    global _enabled
    try:
        pygame.mixer.pre_init(RATE, -16, 2, 512)
        pygame.mixer.init()
        pygame.mixer.set_num_channels(24)
    except (pygame.error, NotImplementedError, ImportError, AttributeError):
        _enabled = False  # no audio device or mixer support: play silently
        return
    rng = np.random.default_rng(3)
    n = lambda s: int(RATE * s)
    _sounds["rifle"] = _make(_noise(n(0.08), rng) * _env(n(0.08), decay=0.018), 0.18)
    _sounds["cannon"] = _make(_lowpass(_noise(n(0.5), rng), 0.08) * _env(n(0.5), decay=0.12) * 2.5, 0.5)
    _sounds["explosion"] = _make(_lowpass(_noise(n(0.9), rng), 0.05) * _env(n(0.9), decay=0.25) * 3, 0.6)
    _sounds["turret"] = _make(_noise(n(0.1), rng) * _env(n(0.1), decay=0.025), 0.2)
    chime = np.concatenate([_tone(880, n(0.12)) * _env(n(0.12), decay=0.08), _tone(1320, n(0.25)) * _env(n(0.25), decay=0.12)])
    _sounds["complete"] = _make(chime, 0.25)
    alert = np.concatenate([_tone(440, n(0.15), "square") * 0.5, np.zeros(n(0.05)), _tone(330, n(0.25), "square") * 0.5])
    _sounds["alert"] = _make(alert * _env(len(alert), decay=0.4), 0.18)
    wave = np.concatenate([_tone(220, n(0.3), "square"), _tone(196, n(0.45), "square")]) * 0.4
    _sounds["wave"] = _make(wave * _env(len(wave), decay=0.6), 0.2)
    # A sniper's report: a hard crack with a short tail, pitched above the rifle.
    crack = _lowpass(_noise(n(0.35), rng), 0.55) * _env(n(0.35), attack=0.001, decay=0.05)
    tail = _lowpass(_noise(n(0.35), rng), 0.06) * _env(n(0.35), attack=0.02, decay=0.16) * 0.5
    _sounds["snipe"] = _make(crack * 1.6 + tail, 0.42)
    _sounds["pop"] = _make(_tone(660, n(0.08)) * _env(n(0.08), decay=0.03), 0.25)
    _sounds["click"] = _make(_tone(1200, n(0.03)) * _env(n(0.03), decay=0.01), 0.15)
    win = np.concatenate([_tone(f, n(0.18)) * _env(n(0.18), decay=0.2) for f in (523, 659, 784, 1046)])
    _sounds["victory"] = _make(win, 0.3)
    lose = np.concatenate([_tone(f, n(0.3), "square") * 0.4 * _env(n(0.3), decay=0.3) for f in (392, 330, 262)])
    _sounds["defeat"] = _make(lose, 0.25)
    _enabled = True


def play(name, min_gap=0.0):
    """Plays a named effect; `min_gap` throttles rapid repeats (e.g. gunfire)."""
    if not _enabled or not settings.sound:
        return
    s = _sounds.get(name)
    if s is None:
        return
    now = pygame.time.get_ticks() / 1000
    if min_gap and now - _last_played.get(name, -1) < min_gap:
        return
    _last_played[name] = now
    s.play()
