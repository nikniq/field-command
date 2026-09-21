"""An attacker beyond your sight shows itself when it hits you, then fades back into the fog."""
from conftest import hq_of, make_world, run
from fieldcommand.defs import REVEAL_TIME, UNITS
from fieldcommand.entities import Unit


def test_a_hidden_sniper_is_revealed_by_its_own_shot_and_fades_again():
    w = make_world()
    hq = hq_of(w, 0)
    victim = w.start_building("depot", hq.x + 400, hq.y, 0)      # sees 200; cannot walk towards its attacker
    victim.built, victim.progress, victim.hp = True, 1.0, 10 ** 6
    sn = Unit(w, "sniper", 1, victim.x + victim.half + UNITS["sniper"].range - 10, victim.y)
    w._add(sn)
    w.update_visibility()
    assert not w.sees(0, sn), "the sniper starts hidden"
    w.apply(1, ["attack", [sn.id], victim.id, False])
    assert run(w, 5, until=lambda: w.sees(0, sn)), "its first shot reveals it"
    sn.command(("idle",))
    run(w, REVEAL_TIME + 0.5)
    w.update_visibility()
    assert not w.sees(0, sn), "and it fades back into the fog once it stops"


def test_allies_do_not_reveal_each_other():
    w = make_world("four_corners", players=4, teams=2)
    hq = hq_of(w, 0)
    ally = Unit(w, "marine", 2, hq.x + 100, hq.y)
    w._add(ally)
    hq.take_damage(1, ally)            # a stray allied hit
    assert ally.id not in w.reveals[w.players[0].team]
