"""Unit voices: a radio call per kind on selection and on an order."""
import numpy as np

from fieldcommand import audio
from fieldcommand.defs import UNIT_KINDS


def test_every_unit_kind_has_a_select_call_and_an_acknowledgement():
    assert set(audio.VOICE_PITCH) == set(UNIT_KINDS)
    rng = np.random.default_rng(3)
    for kind, f0 in audio.VOICE_PITCH.items():
        sel, ack = audio.voice(f0, False, rng), audio.voice(f0, True, rng)
        assert 0.2 < len(sel) / audio.RATE < 0.4 and 0.15 < len(ack) / audio.RATE < 0.3
        assert len(ack) < len(sel)                                       # the acknowledgement is the quicker call
        assert np.abs(sel).max() > 0.3 and np.abs(ack).max() > 0.3
    assert len(set(audio.VOICE_PITCH.values())) == len(audio.VOICE_PITCH)   # distinct pitches per kind
