"""Unit voices: every kind speaks in its own voice, with several lines, on selection and on an order."""
import random

import numpy as np

from fieldcommand import audio
from fieldcommand.defs import UNIT_KINDS


def test_every_unit_kind_has_its_own_voice_with_several_lines():
    assert set(audio.VOICE_PITCH) == set(UNIT_KINDS) == set(audio.VOICE_TIMBRE)
    assert len(set(audio.VOICE_PITCH.values())) == len(audio.VOICE_PITCH)   # distinct pitches per kind
    assert len(set(audio.VOICE_TIMBRE.values())) == len(audio.VOICE_TIMBRE) # and distinct timbres
    assert len(audio.VOICE_LINES["select"]) == 3 and len(audio.VOICE_LINES["ack"]) == 2
    rng = np.random.default_rng(3)
    for kind in UNIT_KINDS:
        sels = [audio.voice(kind, i, False, rng) for i in range(3)]
        acks = [audio.voice(kind, i, True, rng) for i in range(2)]
        for sel in sels:
            assert 0.2 < len(sel) / audio.RATE < 0.4 and np.abs(sel).max() > 0.3
        for ack in acks:
            assert 0.15 < len(ack) / audio.RATE < 0.3 and np.abs(ack).max() > 0.3
        assert max(len(a) for a in acks) < min(len(s) for s in sels)   # the acknowledgement is the quicker call
        assert len({len(s) for s in sels}) == 3                        # three different lines


def test_two_kinds_do_not_sound_alike():
    rng = np.random.default_rng(3)
    a = audio.voice("tank", 0, False, rng)
    b = audio.voice("sniper", 0, False, rng)
    assert len(a) == len(b)
    assert np.corrcoef(a, b)[0, 1] < 0.5


def test_a_unit_never_repeats_the_line_it_just_said():
    rnd = random.Random(1)
    seen = [audio.pick_line("voice_", "marine", rnd) for _ in range(40)]
    assert all(x != y for x, y in zip(seen, seen[1:])) and set(seen) == {0, 1, 2}
    acks = [audio.pick_line("ack_", "marine", rnd) for _ in range(10)]
    assert all(x != y for x, y in zip(acks, acks[1:]))
