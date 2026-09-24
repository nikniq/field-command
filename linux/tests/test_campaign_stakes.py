"""Campaign stakes: veterans carry over, missions open in branches, and a named unit that must survive."""
from conftest import hq_of, run
from fieldcommand import mapgen, net
from fieldcommand.defs import CAMPAIGN, DIFFICULTIES, MISSION_BY_ID, UNITS, VETERAN_CARRY, VETERAN_KINDS, VET_THRESHOLDS
from fieldcommand.replay import Replay, replay_to_dict
from fieldcommand.world import PlayerInfo, World


def mission_world(mid, veterans=()):
    m = MISSION_BY_ID[mid]
    spec = mapgen.resolve(m.map, 1 + m.opponents)
    ps = [PlayerInfo(i, f"P{i}", (i % m.teams + 1) if m.teams >= 2 else i + 1, is_ai=i > 0) for i in range(1 + m.opponents)]
    return World(spec, ps, DIFFICULTIES[m.difficulty], mission=mid, veterans=veterans), m


def test_missions_open_in_branches_not_a_line():
    by = MISSION_BY_ID
    assert by["first_light"].requires == ()
    assert by["hold_the_line"].requires == ("first_light",) and by["gold_run"].requires == ("first_light",)
    assert set(by["crossfire"].requires) == {"hold_the_line", "gold_run"}
    assert by["long_march"].requires == ("crossfire",)
    for m in CAMPAIGN:
        assert all(r in by for r in m.requires)
        assert not m.vip or (m.vip[0] in UNITS and m.vip[1])
    assert by["gold_run"].vip == ("sniper", "Sergeant Kade") and by["long_march"].vip == ("tank", "Colonel Rook")


def test_veterans_stand_by_the_command_center_with_their_rank():
    w, m = mission_world("first_light", veterans=[("marine", VET_THRESHOLDS[1]), ("tank", VET_THRESHOLDS[0]), ("worker", 99)])
    hq = hq_of(w, 0)
    vets = [u for u in w.units if u.team == 0 and u.rank > 0]
    assert sorted(u.kind for u in vets) == ["marine", "tank"]                # an Engineer is no veteran
    r = next(u for u in vets if u.kind == "marine")
    assert r.rank == 2 and r.kills == VET_THRESHOLDS[1] and r.max_hp > UNITS["marine"].hp and r.hp == r.max_hp
    assert all(((u.x - hq.x) ** 2 + (u.y - hq.y) ** 2) ** 0.5 < 200 for u in vets)
    assert len(w.veterans) == 2 + 1 and VETERAN_CARRY == 8 and set(VETERAN_KINDS) == {"marine", "sniper", "tank", "medic", "gunship"}


def test_the_named_unit_stands_with_you_and_its_death_loses_the_mission():
    w, m = mission_world("gold_run")
    for u in list(w.units):
        u.command(("idle",))
    v = w.vip
    assert v is not None and v.kind == "sniper" and v.team == 0 and v.name == "Sergeant Kade (Sniper)"
    assert net.start_message(w, 0)["vip"] == v.id if hasattr(net, "start_message") else True
    run(w, 1)
    assert not w.game_over
    v.hp = 0
    v.dead = True
    run(w, 0.5)
    assert w.game_over and w.winner_team != w.players[0].team
    assert w.vip.dead


def test_missions_without_a_named_unit_and_a_replay_carry_the_veterans():
    w, m = mission_world("first_light", veterans=[("sniper", VET_THRESHOLDS[0])])
    assert w.vip is None
    rec = Replay(replay_to_dict(w))
    assert rec.veterans == [("sniper", VET_THRESHOLDS[0])]
