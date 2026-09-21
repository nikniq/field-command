"""The wire format: snapshots round-trip through encode/decode and carry what a client needs."""
from conftest import hq_of, make_world, run
from fieldcommand import net


def test_snapshot_survives_framing():
    w = make_world()
    run(w, 2)
    snap = net.snapshot_for(w, 0, w.events)
    frame = net.encode(snap)
    header = int.from_bytes(frame[:4], "big")
    back = net.decode_payload(header, frame[4:])
    assert back == snap


def test_snapshot_hides_what_fog_hides():
    w = make_world()
    w.update_visibility()
    snap = net.snapshot_for(w, 0, [])
    enemy_hq = hq_of(w, 1)
    assert all(b[0] != enemy_hq.id for b in snap["b"])
    assert all(u[1] == 0 for u in snap["u"])


def test_status_codes_are_dense_and_named():
    codes = sorted(net.STATUS.values())
    assert codes == list(range(len(codes)))
    assert {"rebuild", "repair"} <= set(net.STATUS)
