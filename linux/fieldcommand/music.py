"""Procedural ambient music, layered by threat (no audio files). Five loops of 19.2 seconds — four bars over
A minor, F, C, G at 100 beats a minute — are synthesised once from the same recipe in both editions: a
`pad` (sustained chords, always on), a `melody` (a plucked arpeggio with an echo, the calm layer, which
yields as the threat climbs), a `pulse` (a bass line on the roots that comes up as the enemy comes into
view), `drums` (a kick, hats and a snare that come up when your forces are fighting, with a fill at the
turn) and `brass` (a sawtooth swell only at the very top). The client keeps a `Threat` meter from what it sees and hears
— an attack alert, gunfire, enemies on screen — which rises in a second and falls over six, and the mixer
sets each layer's gain from it. Audio.swift's `Music` is the same."""
import numpy as np

RATE = 22050
BPM = 100.0
BEATS = 32                       # four chords of eight beats: A minor, F, C, G
LOOP_SECONDS = BEATS * 60.0 / BPM    # 19.2 s
LAYERS = ["pad", "melody", "pulse", "drums", "brass"]
MASTER = 0.32            # the whole mix, under the effects
RISE = 1.0               # seconds for the meter to climb to a higher target
FALL = 6.0               # and to settle to a lower one
ALERT_HOLD = 12.0        # an attack alert counts for this long
SHOT_HOLD = 4.0          # gunfire heard, this long
THREAT_ALERT, THREAT_SHOTS, THREAT_SEEN = 1.0, 0.7, 0.4
SHOTS = ("rifle", "cannon", "turret", "snipe", "explosion")
# The progression, as (root, third, fifth) in Hz, low: Am, F, C, G.
CHORDS = [(110.0, 130.81, 164.81), (87.31, 110.0, 130.81), (130.81, 164.81, 196.0), (98.0, 123.47, 146.83)]


def _smooth(e0, e1, x):
    t = min(1.0, max(0.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def layer_gains(threat):
    """Per-layer gain for a threat level in 0..1: the pad is always there, the melody yields as the threat
    climbs, the pulse comes up through the middle of the range, the drums over the top of it, and a brass
    swell only at the very top."""
    return {"pad": 1.0, "melody": 1.0 - _smooth(0.35, 0.75, threat), "pulse": _smooth(0.2, 0.6, threat),
            "drums": _smooth(0.55, 1.0, threat), "brass": _smooth(0.8, 1.0, threat)}


class Threat:
    """What the player is facing, as a number: 1 when under attack, 0.7 while shots are heard, 0.4 with an
    enemy in sight, else 0 — smoothed so the music breathes rather than flickers."""

    def __init__(self):
        self.level = 0.0
        self.last_alert = -1e9
        self.last_shot = -1e9
        self.enemies_seen = 0

    def note(self, kind, now):
        if kind == "alert":
            self.last_alert = now
        elif kind in SHOTS:
            self.last_shot = now

    def target(self, now):
        if now - self.last_alert < ALERT_HOLD:
            return THREAT_ALERT
        if now - self.last_shot < SHOT_HOLD:
            return THREAT_SHOTS
        return THREAT_SEEN if self.enemies_seen > 0 else 0.0

    def update(self, dt, now):
        t = self.target(now)
        k = min(1.0, dt / (RISE if t > self.level else FALL))
        self.level += (t - self.level) * k
        return self.level


# ---------------------------------------------------------------- synthesis

def _tone(freq, n, phase=0.0):
    return np.sin(2 * np.pi * freq * np.arange(n) / RATE + phase)


def _env(n, attack, decay):
    t = np.arange(n) / RATE
    return np.minimum(1.0, t / max(attack, 1e-4)) * np.exp(-t / decay)


def _lowpass(x, k):
    out = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += k * (v - acc)
        out[i] = acc
    return out


def _pluck(freq, n):
    """A plucked note: a sine with a touch of its octave, a quick attack and a decaying tail."""
    t = np.arange(n) / RATE
    env = np.minimum(1.0, t / 0.008) * np.exp(-t / 0.28)
    return (np.sin(2 * np.pi * freq * t) + 0.3 * np.sin(2 * np.pi * freq * 2 * t)) * env


def _echo(x, delay, gain):
    d = int(RATE * delay)
    out = x.copy()
    out[d:] += x[:-d] * gain
    return out


def synthesise():
    """The five loops as float32 arrays in [-1, 1], each LOOP_SECONDS long and seamless: a chord progression
    over four bars — A minor, F, C, G — at 100 beats a minute."""
    n = int(RATE * LOOP_SECONDS)
    beat = 60.0 / BPM
    step = int(RATE * beat)
    bar = step * 8
    rng = np.random.default_rng(11)
    t = np.arange(n) / RATE
    # Pad: every chord sustained over its bar, voices detuned so they slowly beat, crossfading at the bar line.
    pad = np.zeros(n)
    for ci, (r, third, fifth) in enumerate(CHORDS):
        seg = np.zeros(n)
        for f, g in ((r, 0.5), (r * 1.004, 0.45), (third, 0.3), (fifth, 0.3), (r * 2, 0.2)):
            seg += _tone(f, n) * g
        fade = np.clip((t - ci * beat * 8) / 1.5, 0, 1) * np.clip(((ci + 1) * beat * 8 + 0.4 - t) / 1.5, 0, 1)
        if ci == 0:                                   # the first chord also carries the loop's seam
            fade = np.maximum(fade, np.clip((LOOP_SECONDS - t) / 0.01, 0, 1) * 0)
        pad += seg * fade
    pad *= 0.8 + 0.2 * np.sin(2 * np.pi * t / 6.0)
    pad = _lowpass(pad, 0.12)
    # Melody: a plucked arpeggio over each chord's tones, eighth notes, with a soft echo — the calm layer.
    melody = np.zeros(n)
    pattern = [0, 2, 1, 2, 3, 2, 1, 2, 0, 1, 2, 3, 2, 1, 2, 1]        # indices into (root, third, fifth, octave)
    for ci, (r, third, fifth) in enumerate(CHORDS):
        tones = (r * 2, third * 2, fifth * 2, r * 4)
        for k in range(16):
            f = tones[pattern[k]]
            start_ = ci * bar + k * step // 2
            m = min(int(RATE * 0.5), n - start_)
            if m > 0:
                melody[start_:start_ + m] += _pluck(f, m) * (0.9 if k % 4 == 0 else 0.6)
    melody = _echo(melody, beat * 0.75, 0.35)
    # Pulse: a bass note every beat on the chord's root, softened, with a little grit.
    pulse = np.zeros(n)
    for ci, (r, _third, _fifth) in enumerate(CHORDS):
        for k in range(8):
            f = r / 2
            start_ = ci * bar + k * step
            seg = min(step, n - start_)
            env = _env(seg, 0.01, 0.22)
            pulse[start_:start_ + seg] += (_tone(f, seg) + 0.4 * np.sign(_tone(f * 2, seg))) * env * (1.0 if k % 2 == 0 else 0.7)
    pulse = _lowpass(pulse, 0.2)
    # Drums: a kick on the beat, hats off the beat, a snare on two and four, and a fill on the last bar's end.
    drums = np.zeros(n)
    for k in range(BEATS):
        s_ = k * step
        kn = min(int(RATE * 0.25), n - s_)
        sweep = 120.0 * np.exp(-np.arange(kn) / RATE * 18) + 40.0
        drums[s_:s_ + kn] += np.sin(2 * np.pi * np.cumsum(sweep) / RATE) * _env(kn, 0.002, 0.09) * 1.2
        hs = s_ + step // 2
        hn = min(int(RATE * 0.06), n - hs)
        if hn > 0:
            drums[hs:hs + hn] += rng.uniform(-1, 1, hn) * _env(hn, 0.001, 0.02) * 0.35
        if k % 2 == 1:
            sn = min(int(RATE * 0.16), n - s_)
            drums[s_:s_ + sn] += _lowpass(rng.uniform(-1, 1, sn), 0.5) * _env(sn, 0.002, 0.05) * 0.6
        if k >= BEATS - 2:                                             # the fill: four quick snares
            for q in range(4):
                qs = s_ + q * step // 4
                qn = min(int(RATE * 0.1), n - qs)
                if qn > 0:
                    drums[qs:qs + qn] += _lowpass(rng.uniform(-1, 1, qn), 0.5) * _env(qn, 0.002, 0.04) * 0.45
    # Brass: a sawtooth swell on the chord every four beats, only at the very top of the threat.
    brass = np.zeros(n)
    for ci, (r, third, fifth) in enumerate(CHORDS):
        for k in (0, 4):
            start_ = ci * bar + k * step
            seg = min(step * 3, n - start_)
            tt = np.arange(seg) / RATE
            env = np.minimum(1.0, tt / 0.35) * np.exp(-np.maximum(0, tt - 1.2) / 0.5)
            for f, g in ((r, 0.5), (third, 0.35), (fifth, 0.35)):
                saw = 2 * ((f * tt) % 1.0) - 1
                brass[start_:start_ + seg] += saw * env * g
    brass = _lowpass(brass, 0.08)
    out = {}
    for name, x, vol in (("pad", pad, 0.22), ("melody", melody, 0.34), ("pulse", pulse, 0.5), ("drums", drums, 0.7),
                         ("brass", brass, 0.55)):
        x = x * vol
        fade_n = int(RATE * 0.02)
        x[-fade_n:] *= np.linspace(1, 0, fade_n)       # a short fade so the loop seam is clean
        x[:fade_n] *= np.linspace(0, 1, fade_n)
        out[name] = np.clip(x, -1, 1).astype(np.float32)
    return out
