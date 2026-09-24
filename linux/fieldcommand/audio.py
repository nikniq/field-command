"""Procedurally synthesised sound effects (no audio files needed), and the music mixer (see music.py)."""
import numpy as np
import random
import pygame

from . import music
from .settings import settings

RATE = 22050
_sounds = {}
_enabled = False
_last_played = {}
_music = {}              # layer name -> (Sound, Channel) once the loops are playing
_music_level = -1.0
MUSIC_CHANNELS = 5       # the first channels are kept for the loops; effects use the rest
# Unit voices: a radio acknowledgement per kind — two tones when selected, a quick one on an order. The base
# pitch tells the kinds apart; the same numbers live in Audio.swift.
VOICE_PITCH = {"worker": 520.0, "marine": 440.0, "tank": 200.0, "sniper": 660.0, "medic": 590.0, "gunship": 360.0}
# Each kind speaks in its own voice: the base pitch above, a timbre, and a handful of lines picked at random
# so the same unit does not say the same thing twice running. Audio.swift has the same tables.
VOICE_TIMBRE = {"worker": "clean", "marine": "buzz", "tank": "growl", "sniper": "thin", "medic": "soft", "gunship": "rotor"}
VOICE_LINES = {"select": [[(1.0, 0.09), (1.25, 0.12)], [(1.0, 0.07), (0.9, 0.06), (1.35, 0.12)], [(1.2, 0.08), (1.0, 0.14)]],
               "ack": [[(1.5, 0.07), (1.1, 0.09)], [(1.25, 0.06), (1.25, 0.06)]]}
_last_line = {}


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
        pygame.mixer.set_reserved(MUSIC_CHANNELS)
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
    # A siege tank locking down: hydraulics, then a clank.
    hiss = _lowpass(_noise(n(0.5), rng), 0.25) * _env(n(0.5), attack=0.05, decay=0.2) * 0.8
    clank = _tone(180, n(0.18), "square") * _env(n(0.18), attack=0.002, decay=0.05)
    _sounds["siege"] = _make(np.concatenate([hiss, clank]), 0.3)
    _sounds["pop"] = _make(_tone(660, n(0.08)) * _env(n(0.08), decay=0.03), 0.25)
    _sounds["click"] = _make(_tone(1200, n(0.03)) * _env(n(0.03), decay=0.01), 0.15)
    win = np.concatenate([_tone(f, n(0.18)) * _env(n(0.18), decay=0.2) for f in (523, 659, 784, 1046)])
    _sounds["victory"] = _make(win, 0.3)
    lose = np.concatenate([_tone(f, n(0.3), "square") * 0.4 * _env(n(0.3), decay=0.3) for f in (392, 330, 262)])
    _sounds["defeat"] = _make(lose, 0.25)
    for kind in VOICE_PITCH:
        for i in range(len(VOICE_LINES["select"])):
            _sounds[f"voice_{kind}_{i}"] = _make(voice(kind, i, False, rng), 0.3)
        for i in range(len(VOICE_LINES["ack"])):
            _sounds[f"ack_{kind}_{i}"] = _make(voice(kind, i, True, rng), 0.3)
    _enabled = True


def pick_line(prefix, kind, rnd=random):
    """Which of the kind's lines to say next: never the one it said last."""
    n = len(VOICE_LINES["ack" if prefix == "ack_" else "select"])
    last = _last_line.get(prefix + kind)
    choices = [i for i in range(n) if i != last] or [0]
    i = rnd.choice(choices)
    _last_line[prefix + kind] = i
    return i


def play_voice(prefix, kind):
    """A unit's radio call: `voice_` on selection, `ack_` on an order; a different line each time."""
    if not _enabled or not settings.sound:
        return
    now = pygame.time.get_ticks() / 1000
    if now - _last_played.get(prefix + kind, -1) < 0.3:
        return
    _last_played[prefix + kind] = now
    play(f"{prefix}{kind}_{pick_line(prefix, kind)}")


# Timbre: (buzz, speaker lowpass, vibrato Hz, vibrato depth, sub-octave, rotor chop Hz)
_TIMBRES = {"clean": (0.15, 0.5, 40.0, 0.02, 0.0, 0.0), "buzz": (0.35, 0.35, 40.0, 0.02, 0.0, 0.0),
            "growl": (0.45, 0.18, 6.0, 0.03, 0.5, 0.0), "thin": (0.1, 0.7, 60.0, 0.015, 0.0, 0.0),
            "soft": (0.0, 0.25, 5.0, 0.025, 0.0, 0.0), "rotor": (0.3, 0.35, 40.0, 0.02, 0.0, 24.0)}


def voice(kind, line, ack, rng):
    """A radio call in the kind's voice: a squelch click, then the line's notes with vibrato through a
    band-limited 'speaker' — the Siege Tank growls an octave down, the Gunship's is chopped by its rotor."""
    n = lambda s: int(RATE * s)
    f0 = VOICE_PITCH[kind]
    buzz, lp, vib_hz, vib_depth, sub, chop = _TIMBRES[VOICE_TIMBRE[kind]]
    parts = [_noise(n(0.03), rng) * _env(n(0.03), attack=0.001, decay=0.008) * 0.6]
    for ratio, secs in VOICE_LINES["ack" if ack else "select"][line]:
        f = f0 * ratio
        m = n(secs)
        t = np.arange(m) / RATE
        vib = f * (1 + vib_depth * np.sin(2 * np.pi * vib_hz * t))
        tone = np.sin(2 * np.pi * np.cumsum(vib) / RATE)
        tone += buzz * np.sign(tone) * (1 - t / secs)                # a buzz that fades out of the note
        if sub:
            tone += sub * np.sin(2 * np.pi * np.cumsum(vib / 2) / RATE)
        if chop:
            tone *= 0.6 + 0.4 * np.sin(2 * np.pi * chop * t)
        parts.append(_lowpass(tone, lp) * _env(m, attack=0.006, decay=secs * 0.6))
        parts.append(np.zeros(n(0.02)))
    parts.append(_noise(n(0.02), rng) * _env(n(0.02), attack=0.001, decay=0.006) * 0.4)
    out = np.concatenate(parts)
    return out / max(1e-6, np.abs(out).max())                          # every voice as loud as the next


def music_update(threat):
    """Keeps the three loops playing and sets their gains from the threat level (0..1). Off with the music
    setting: the loops pause and pick up where they were when it comes back."""
    global _music_level
    if not _enabled:
        return
    if not settings.music or not settings.sound:
        if _music and _music_level >= 0:
            for _s, ch in _music.values():
                ch.pause()
            _music_level = -1.0
        return
    if not _music:
        for i, (name, samples) in enumerate(music.synthesise().items()):
            s = _make(samples, 1.0)
            ch = pygame.mixer.Channel(i)
            ch.play(s, loops=-1)
            ch.set_volume(0.0)
            _music[name] = (s, ch)
    elif _music_level < 0:
        for _s, ch in _music.values():
            ch.unpause()
    gains = music.layer_gains(threat)
    for name, (_s, ch) in _music.items():
        ch.set_volume(gains[name] * music.MASTER)
    _music_level = threat


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
