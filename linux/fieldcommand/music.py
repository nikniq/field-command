"""Procedural ambient music, layered by threat (no audio files). Three eight-second loops are synthesised
once from the same recipe in both editions: a `pad` (a slow minor drone, always on), a `pulse` (a filtered
bass line at 100 beats a minute that comes up as the enemy comes into view), and `drums` (a kick and hats
that come up when your forces are fighting). The client keeps a `Threat` meter from what it sees and hears
— an attack alert, gunfire, enemies on screen — which rises in a second and falls over six, and the mixer
sets each layer's gain from it. Audio.swift's `Music` is the same."""
import numpy as np

RATE = 22050
LOOP_SECONDS = 8.0
BPM = 100.0
LAYERS = ["pad", "pulse", "drums"]
MASTER = 0.32            # the whole mix, under the effects
RISE = 1.0               # seconds for the meter to climb to a higher target
FALL = 6.0               # and to settle to a lower one
ALERT_HOLD = 12.0        # an attack alert counts for this long
SHOT_HOLD = 4.0          # gunfire heard, this long
THREAT_ALERT, THREAT_SHOTS, THREAT_SEEN = 1.0, 0.7, 0.4
SHOTS = ("rifle", "cannon", "turret", "snipe", "explosion")


def _smooth(e0, e1, x):
    t = min(1.0, max(0.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def layer_gains(threat):
    """Per-layer gain for a threat level in 0..1: the pad is always there, the pulse comes up through the
    middle of the range, the drums over the top of it."""
    return {"pad": 1.0, "pulse": _smooth(0.2, 0.6, threat), "drums": _smooth(0.55, 1.0, threat)}


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


def synthesise():
    """The three loops as float32 arrays in [-1, 1], each LOOP_SECONDS long and seamless."""
    n = int(RATE * LOOP_SECONDS)
    beat = 60.0 / BPM
    rng = np.random.default_rng(11)
    t = np.arange(n) / RATE
    # Pad: A minor, two octaves apart, each voice slightly detuned so it slowly beats; a breath every loop.
    pad = np.zeros(n)
    for f, g in ((110.0, 0.5), (110.6, 0.5), (164.8, 0.35), (220.0, 0.25), (261.6, 0.2), (329.6, 0.15)):
        pad += _tone(f, n) * g
    pad *= 0.55 + 0.45 * np.sin(2 * np.pi * t / LOOP_SECONDS - np.pi / 2) * 0.5 + 0.25
    pad = _lowpass(pad, 0.12)
    # Pulse: a bass note every beat over A - C - E - D, softened, with a little grit.
    pulse = np.zeros(n)
    notes = [55.0, 65.4, 82.4, 73.4]
    step = int(RATE * beat)
    for i in range(int(LOOP_SECONDS / beat)):
        f = notes[(i // 2) % len(notes)]
        seg = min(step, n - i * step)
        env = _env(seg, 0.01, 0.22)
        pulse[i * step:i * step + seg] += (_tone(f, seg) + 0.4 * np.sign(_tone(f * 2, seg))) * env * (1.0 if i % 2 == 0 else 0.7)
    pulse = _lowpass(pulse, 0.2)
    # Drums: a kick on the beat (a sine sweeping down), hats off the beat (short bright noise), a snare on 2 and 4.
    drums = np.zeros(n)
    for i in range(int(LOOP_SECONDS / beat)):
        s = i * step
        kn = min(int(RATE * 0.25), n - s)
        sweep = 120.0 * np.exp(-np.arange(kn) / RATE * 18) + 40.0
        drums[s:s + kn] += np.sin(2 * np.pi * np.cumsum(sweep) / RATE) * _env(kn, 0.002, 0.09) * 1.2
        hs = s + step // 2
        hn = min(int(RATE * 0.06), n - hs)
        if hn > 0:
            drums[hs:hs + hn] += rng.uniform(-1, 1, hn) * _env(hn, 0.001, 0.02) * 0.35
        if i % 2 == 1:
            sn = min(int(RATE * 0.16), n - s)
            drums[s:s + sn] += _lowpass(rng.uniform(-1, 1, sn), 0.5) * _env(sn, 0.002, 0.05) * 0.6
    out = {}
    for name, x, vol in (("pad", pad, 0.22), ("pulse", pulse, 0.5), ("drums", drums, 0.7)):
        x = x * vol
        x[-int(RATE * 0.02):] *= np.linspace(1, 0, int(RATE * 0.02))       # a short fade so the loop seam is clean
        x[:int(RATE * 0.02)] *= np.linspace(0, 1, int(RATE * 0.02))
        out[name] = np.clip(x, -1, 1).astype(np.float32)
    return out
