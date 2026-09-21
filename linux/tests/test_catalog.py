"""The unit and building catalogue, and the things the network protocol relies on."""
from fieldcommand.defs import BUILDINGS, BUILDING_KINDS, BUILD_MENU, UNITS, UNIT_KINDS


def test_kind_lists_match_the_catalogue_in_order():
    # The protocol sends a kind as its index into these lists.
    assert list(UNITS) == UNIT_KINDS
    assert list(BUILDINGS) == BUILDING_KINDS


def test_every_build_menu_entry_exists():
    assert all(k in BUILDINGS for k in BUILD_MENU)


def test_every_produced_unit_exists():
    for b in BUILDINGS.values():
        assert all(k in UNITS for k in b.produces)


def test_requirements_are_real_buildings():
    for s in list(UNITS.values()) + list(BUILDINGS.values()):
        assert s.requires is None or s.requires in BUILDINGS


def test_sniper_outranges_what_shoots_back():
    assert UNITS["sniper"].range > UNITS["tank"].range
    assert UNITS["sniper"].range > BUILDINGS["turret"].range


def test_hotkeys_do_not_collide_within_a_menu():
    build = [BUILDINGS[k].hotkey for k in BUILD_MENU]
    assert len(build) == len(set(build)), build
    for b in BUILDINGS.values():
        trained = [UNITS[k].hotkey for k in b.produces]
        assert len(trained) == len(set(trained)), (b.name, trained)
