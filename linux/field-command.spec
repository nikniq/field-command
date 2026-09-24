Name:           field-command
Version:        1.26.0
Release:        1%{?dist}
Summary:        Real-time strategy game: mine crystal, build an army, destroy the enemy base

License:        MIT
URL:            https://example.invalid/field-command
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  make
BuildRequires:  python3-devel
BuildRequires:  desktop-file-utils
BuildRequires:  libappstream-glib

Requires:       python3
Requires:       python3-pygame >= 2.1
Requires:       python3-cairo
Requires:       python3-numpy
Requires:       hicolor-icon-theme

%description
Field Command is a classic real-time strategy game. Engineers mine crystal and
construct a base, Barracks and Factories train Rangers and Siege Tanks, and a
computer opponent expands, defends and sends escalating attack waves. Features
fog of war, three difficulty levels, an objectives guide, control groups,
shift-queued orders and procedurally generated artwork and sound.

%prep
%autosetup -n %{name}-%{version}

%build
# Pure Python; nothing to compile.

%install
%make_install PREFIX=%{_prefix}
%py_byte_compile %{python3} %{buildroot}%{_datadir}/%{name}/fieldcommand

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/%{name}.desktop
appstream-util validate-relax --nonet %{buildroot}%{_metainfodir}/%{name}.metainfo.xml

%files
%doc README.md
%{_bindir}/%{name}
%{_datadir}/%{name}/
%{_datadir}/applications/%{name}.desktop
%{_metainfodir}/%{name}.metainfo.xml
%{_datadir}/icons/hicolor/*/apps/%{name}.png

%changelog
* Thu Sep 24 2026 Field Command Developers <noreply@example.invalid> - 1.26.0-1
- The Gunship: an aircraft from the Factory (needs a Radar Station, Q) that flies straight over cliffs,
  water, walls and other units with a fast chain gun; Siege Tanks and Artillery cannot fire at it,
  Rangers, Snipers, turrets and the Command Center's gun can
- Undo the last placement moves from U to Backspace, so U is free for the Assembly line and the other
  building upgrades again
- Mac: the HUD no longer recreates its labels and icons several times a second while nothing changes
  (the selection panel, objectives and tutorial arrows now rebuild only on change); SpriteKit drops
  glyphs and pictures under that churn, which is the likely cause of icons and menu text dropping out.
  Both editions gain an icon soak test (FC_ICONSOAK, test_ux.py) that plays minutes of a real game
  through the client and checks every card icon renders

* Thu Sep 24 2026 Field Command Developers <noreply@example.invalid> - 1.25.0-1
- Barricades: a 30-crystal block of wall (V on the Engineer card, Shift places a run) that nothing walks
  through until it is shot down; attackers stop and shoot it, and the computer still comes for a walled base

* Thu Sep 24 2026 Field Command Developers <noreply@example.invalid> - 1.24.0-1
- Polish: an army-size timeline on the end screen; U undoes the last placement for a full refund within 20
  seconds; a unit counter by type on the top bar; rebindable keys (Keys… in the game menu); first-run
  arrows that point at what each opening objective needs

* Thu Sep 24 2026 Field Command Developers <noreply@example.invalid> - 1.23.0-1
- Procedural music: three synthesised loops (a pad, a pulse, drums) mixed by a threat meter fed by what you
  see and hear — calm at the base, the pulse as the enemy comes into view, drums when your forces fight;
  a Music setting beside Sound

* Thu Sep 24 2026 Field Command Developers <noreply@example.invalid> - 1.22.0-1
- High ground: Twin Ridges, Highland Pass and Four Corners have raised plateaus; anything standing on one
  sees 30% further and shoots 40 further, turrets included

* Thu Sep 24 2026 Field Command Developers <noreply@example.invalid> - 1.21.0-1
- Campaign scripting: every mission runs a script on its clock — word from Command, reinforcements walking
  in from your map edge, enemy columns from theirs, a raid on your ally — and is briefed before it is
  deployed, with a map of the mission, the objective and the timeline

* Thu Sep 24 2026 Field Command Developers <noreply@example.invalid> - 1.20.0-1
- The computer is a strategist: it opens with a rush, an economy or a turtle (by difficulty, seed and map
  size), sends a scout to your door, expands when its home field runs low or its Engineers crowd it, and
  keeps a turret and a garrison at every expansion; the batch runner reports wins by opening

* Thu Sep 24 2026 Field Command Developers <noreply@example.invalid> - 1.19.0-1
- Replays: every single-player game is recorded on its way out and can be watched again from the title
  screen (R); the simulation is now deterministic and fixed-step, so a replay is the seed plus your commands
- Balance batch runner: python -m fieldcommand.batch (or ./cx.sh batch) plays computer games headless and
  reports win rates by start slot, game length and the unit mix

* Thu Sep 24 2026 Field Command Developers <noreply@example.invalid> - 1.18.1-1
- The command card checks every icon it draws and redraws any that comes back blank; the F12 screenshot
  note counts such repairs so a report can say whether it happened

* Thu Sep 24 2026 Field Command Developers <noreply@example.invalid> - 1.18.0-1
- 2.5D: the camera looks down at an angle — the ground is foreshortened, buildings stand up on real walls,
  and what is nearer draws over what is behind it

* Wed Sep 23 2026 Field Command Developers <noreply@example.invalid> - 1.17.0-1
- Click a portrait to keep only that kind of a mixed selection (Shift+click drops it, Ctrl+click picks one)
- Control-group numbers ride on the units; leaving to the menu autosaves; health bars can be always on

* Wed Sep 23 2026 Field Command Developers <noreply@example.invalid> - 1.16.0-1
- The campaign: five missions in order — First Light, Hold the Line, The Gold Run, Crossfire, The Long
  March — with survive and hold-the-point objectives, unlocking as they are won
- Every side starts with 2000 crystal

* Wed Sep 23 2026 Field Command Developers <noreply@example.invalid> - 1.15.0-1
- The computer reopens a cut route: with the crossings down it rebuilds the bridge on its way, escorted,
  and holds its wave until the span stands
- Satellite view (Tab): the whole map on screen with markers for every troop and building
- Point defence (J): the Command Center mounts its own gun
- Supply crates drop on the field: the first unit to reach one banks crystal or gains a squad or a tank
- Protocol 11 (older clients are refused)

* Wed Sep 23 2026 Field Command Developers <noreply@example.invalid> - 1.14.0-1
- Visuals: one sun for the whole map with biome tints, drifting cloud shadows, wheel ruts along roads,
  pebbles, darker forest floors, longer-lasting craters, hit flashes, and the fallen left where they dropped

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.13.0-1
- Artillery emplacement (L): 480 reach beyond its sight, slow high-arcing shells you can watch, blind up close
- Shield Generator (K): 300 recharging shield points on every building within 320
- The command card grows to ten buttons; protocol 10 (older clients are refused)

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.12.0-1
- Five giant maps (9000 x 6300, twelve players): Continental Divide, Archipelago, Six Rivers, Crater Fields,
  The Long March — the same layouts in the macOS edition
- Attack points (Z or Alt+click) and help points (Shift+Z): beacons for the whole alliance; computer
  allies send troops to them
- Gold deposits: every map has a contested field worth a hundred normal mineral nodes

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.11.0-1
- Medics: an unarmed Barracks unit (M, 75 crystal) that heals anyone on foot and follows the line
- Engineers repair Siege Tanks, at the repair rate and 35% of the tank's price
- Three Medic kits in the Armory; protocol 9 (older clients are refused)

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.10.0-1
- Save and load single-player games: F5/F9, the pause menu, Load Game on the title screen, autosave every 5 min
- Saves are one JSON document shared with the macOS edition, so a game saved on one loads on the other

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.9.1-1
- The macOS edition now synthesises the same thirteen sound effects as this one

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.9.0-1
- The computer opponent watches your army and builds to counter it, keeps its Snipers at range, and raids

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.8.1-1
- UI scale: the interface is drawn at 2x on 4K and 1.5x on 1440p screens (or as set on the title screen)
- F12 saves a screenshot and an environment note to ~/Pictures

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.8.0-1
- The Armory (Y): buy kit for your troops with crystal, worn by every unit of that type all match
- Network protocol 8

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.7.1-1
- Command-card titles no longer overflow their buttons; upgrades get short button labels

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.7.0-1
- Veterancy: units earn ranks at 2, 5 and 10 kills, each adding 10% damage and health
- Watchtowers: three neutral control points per map; hold one for 8 seconds to see 700 around it
- Attackers reveal themselves for 2.5 seconds when they hit you, even from beyond your sight
- Network protocol 7

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.6.1-1
- The command card no longer goes blank for a mixed selection of buildings
- Command-card icons sit on a dark plate for contrast; large buildings no longer pop at the screen edge

* Mon Sep 21 2026 Field Command Developers <noreply@example.invalid> - 1.6.0-1
- Building upgrades: Reinforce, Armour plating, Assembly line, Expanded storage, Twin cannon
- Network protocol 6

* Mon Sep 21 2026 Field Command Developers <noreply@example.invalid> - 1.5.0-1
- Siege Tanks can dig in: longer reach and heavier shells, immobile, with a blind spot
- Network protocol 5

* Mon Sep 21 2026 Field Command Developers <noreply@example.invalid> - 1.4.0-1
- Single-player games can be played in teams with computer allies
- "Play again" keeps the chosen map, opponents and teams

* Mon Sep 21 2026 Field Command Developers <noreply@example.invalid> - 1.3.0-1
- Engineers repair damaged buildings, paying for the health as it goes back on
- Locked build icons stay visible in greyscale instead of fading into the button
- Fix a crash selecting an Engineer that is rebuilding a bridge
- Cache bridge artwork, which was being re-rendered every frame
- Network protocol 4

* Mon Sep 21 2026 Field Command Developers <noreply@example.invalid> - 1.2.0-1
- Bridges can be destroyed and rebuilt by Engineers; a fallen span blocks the crossing
- Network protocol 3: bridge condition now travels with each snapshot

* Mon Sep 21 2026 Field Command Developers <noreply@example.invalid> - 1.1.0-1
- Add the Sniper (Barracks, needs a Factory) and the Radar Station
- Network protocol 2: 1.0.0 clients cannot join a 1.1.0 game

* Sat Sep 19 2026 Field Command Developers <noreply@example.invalid> - 1.0.0-1
- Initial Linux release
