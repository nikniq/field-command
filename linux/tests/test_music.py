"""Procedural music: three seamless loops, a threat meter that rises fast and falls slow, and layer gains
that bring the pulse and the drums up with it."""
import numpy as np

from fieldcommand import music


def test_five_loops_of_four_bars_within_bounds():
    loops = music.synthesise()
    assert list(loops) == music.LAYERS and len(music.LAYERS) == 5
    assert music.LOOP_SECONDS == music.BEATS * 60 / music.BPM and len(music.CHORDS) == 4
    n = int(music.RATE * music.LOOP_SECONDS)
    for name, x in loops.items():
        assert x.dtype == np.float32 and len(x) == n, name
        peak = float(np.abs(x).max())
        assert 0.1 < peak <= 1.0, (name, peak)
        assert abs(float(x[0])) < 0.01 and abs(float(x[-1])) < 0.01          # faded at the seam
        assert float(np.abs(x).mean()) > 0.002, name


def test_layer_gains_follow_the_threat():
    calm, edge, war = music.layer_gains(0.0), music.layer_gains(0.5), music.layer_gains(1.0)
    assert calm == {"pad": 1.0, "melody": 1.0, "pulse": 0.0, "drums": 0.0, "brass": 0.0}
    assert edge["pad"] == 1.0 and 0.5 < edge["pulse"] <= 1.0 and edge["drums"] == 0.0 and 0.4 < edge["melody"] < 1.0
    assert war == {"pad": 1.0, "melody": 0.0, "pulse": 1.0, "drums": 1.0, "brass": 1.0}


def test_the_meter_rises_in_a_second_and_falls_over_six():
    t = music.Threat()
    assert t.target(10.0) == 0.0
    t.enemies_seen = 2
    assert t.target(10.0) == music.THREAT_SEEN
    t.note("rifle", 10.0)
    assert t.target(11.0) == music.THREAT_SHOTS and t.target(10.0 + music.SHOT_HOLD + 1) == music.THREAT_SEEN
    t.note("alert", 20.0)
    assert t.target(21.0) == music.THREAT_ALERT
    now = 20.0
    for _ in range(30):                       # one second of frames
        now += 1 / 30
        t.update(1 / 30, now)
    assert t.level > 0.5                      # most of the way up within a second
    for _ in range(9):                        # the rest of the alert: it tops out
        now += 1.0
        t.update(1.0, now)
    assert t.level > 0.95
    t.enemies_seen = 0
    now = 20.0 + music.ALERT_HOLD + 0.1       # the alert has just lapsed
    t.update(1.0, now)
    assert 0.6 < t.level < 1.0                # a second after the alert lapses it has only started down
    for _ in range(12):
        now += 1.0
        t.update(1.0, now)
    assert t.level < 0.15                     # and it is quiet again a dozen seconds later
