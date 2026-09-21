# Field Command — Linux edition

A real-time strategy game: mine crystal with Engineers, build a base, train Rangers and Siege Tanks,
and destroy every enemy building. This is the Linux port of the macOS (SpriteKit) edition in
`../macos/`, rewritten in Python with pygame. All artwork is drawn procedurally with Cairo and all
sound effects are synthesised, so there are no asset files.

The Windows edition runs this same package; `../windows/` holds only its entry point and PyInstaller
build, so a change here lands on both platforms.

## Play from the source tree (Fedora)

```sh
sudo dnf install python3-pygame python3-cairo python3-numpy
./field-command
```

Requires Python 3.9+ and pygame 2.1+ (Fedora 38 and later ship suitable versions).

## Install system-wide

```sh
sudo make install            # installs to /usr/local
sudo make uninstall
```

This installs the `field-command` command, a desktop entry (it appears in the GNOME/KDE app grid),
AppStream metadata and icons.

## Build an RPM

```sh
sudo dnf install rpm-build make python3-devel desktop-file-utils libappstream-glib
make rpm
sudo dnf install rpmbuild/RPMS/noarch/field-command-1.0.0-1.*.noarch.rpm
```

## Units and buildings

| | Cost | Trained at | Notes |
| --- | --- | --- | --- |
| Engineer | 50 | Command Center | Mines crystal and builds |
| Ranger | 50 | Barracks | Rifle infantry, 150 range |
| Sniper | 125 | Barracks (needs a Factory) | 330 range, 55 damage a shot, one shot every 3.2s; 55 HP |
| Siege Tank | 150 | Factory | 230 range, splash damage |

The **Sniper** outranges everything that can shoot back — Siege Tanks reach 230 and Gun Turrets 210 — so a
few of them behind your line pick apart tanks and turrets before those can answer. They reload slowly and
die quickly, so they lose to anything that closes the distance: screen them with Rangers.

The **Radar Station** (175 crystal, needs a Barracks) sees 900 units in every direction, roughly three times
a Command Center, and its dish sweeps while it works. It carries no weapons and 520 HP, so put it behind
your lines or next to a Turret. One near a contested expansion shows attacks forming long before they
arrive; the server enforces fog of war, so this vision is the only way to watch ground you do not hold.

## Repair

Select Engineers and right-click a damaged building of yours or an ally's to repair it. One Engineer restores
a full health bar in 30 seconds, and more Engineers work proportionally faster. A full bar costs 35% of the
building's price, charged as the health goes back on, so patching a half-wrecked Command Center costs 70
crystal. If the crystal runs out, repair stops rather than going into debt. When the job is done each
Engineer goes back to what it was doing. Buildings still under construction finish on their own and cannot
be repaired.

Computer players send an Engineer to their worst-damaged building once it drops below 70%, one at a time,
when they have crystal to spare.

## Bridges

Bridges are structures, not scenery. Each one has 900 hit points and belongs to nobody, so either side can
break a crossing or put it back.

| | |
| --- | --- |
| Demolish | Select troops, press **A**, click the bridge (the deliberate gesture — a plain right-click walks across it) |
| Rebuild | Select an Engineer, right-click the ruins — 75 crystal, 25 seconds |
| Hover | Shows condition and what you can do with it |
| Minimap | Amber while it stands, red outline once it is down |

A fallen bridge blocks its span exactly like the water it crossed: nothing walks over it and nothing shoots
through it, so on *River Crossing* breaking all three crossings cuts the map in two. Siege Tank shells and
Snipers work on bridges as well as buildings; Engineers cannot shoot one down. Troops standing on a deck when
it collapses are pushed clear onto the nearest bank.

Computer players rebuild a crossing near their base when they have crystal to spare, so cutting a bridge buys
time rather than winning outright.

## Maps

Seven maps ship with the game; pick one on the title screen (**Map:**) along with the number of computer
opponents (up to eleven on a mega map), or let the lobby host choose one for a multiplayer game.

**Teams** on the title screen turns a single-player game into a team game with computer allies. Players are
dealt round-robin into that many alliances — the same rule as the multiplayer lobby's presets — and the line
under the map says exactly who is with whom before you start: with three opponents, *Teams: 2* is you and
Computer 2 against Computers 1 and 3. Allies share their vision, never fire on each other, and win together;
the game is over when one alliance is left. Only team counts that differ from free-for-all are offered, so
with a single opponent the setting stays on *Free-for-all*.

| Map | Players | Terrain |
| --- | --- | --- |
| Twin Ridges | 2 | Open ground, bases in opposite corners |
| River Crossing | 2 | A river splits the map; three bridges to fight over |
| Highland Pass | 2 | Cliff ridges with narrow passes |
| Four Corners | 4 | A base in each corner, rich centre |
| Crossroads | 4 | Bases on each edge, lakes in the quadrants |
| Grand Arena | 12 | **Mega map**: twelve bases ringing an open plain |
| Riverlands | 12 | **Mega map**: four rivers and a cliff-walled heartland |

The two mega maps play up to **twelve** players on a world half again as wide and tall (6000 x 4200 instead of
4000 x 2800); every other map is the standard size. A twelve-way free-for-all against computer players is
demanding but runs fine on a normal desktop.

Water and cliffs block movement, building and line of fire; bridges are walkable until someone breaks them. Troops path around
terrain and buildings with A* on a 40-unit navigation grid (`nav.py`), walking straight when the way is
clear, re-planning when buildings appear or when they are pushed off course, so they no longer snag on
the corner of a base. The Mac edition has the same catalogue and the same pathfinding.

## Multiplayer (up to 12 players, Linux and Mac)

Choose **Multiplayer** (or press **M**) on the title screen.

- **Host:** press *Host Game*. Others on your network see the game listed automatically, or can join with
  your address (shown on screen, e.g. `192.168.1.20:47777`). In the lobby the host sets each open slot to
  Computer/Open/Closed, picks teams (or the *Free-for-all* / *2 teams* / *3 teams* / *4 teams* presets, which deal
  the slots round-robin), the map and the AI difficulty. Twelve slots are shown in two columns.
  *Map: Auto* picks a map that fits the number of players.
- **Join:** pick a game from *Games on your network*, or type the host's address.
- **Dedicated server** (no display needed, e.g. on a spare machine or VPS):
  `field-command --server [--port 47777] [--name "My server"]` — the first player to join becomes the host.
- Mac players use the macOS edition's *Multiplayer* screen. Either side can host: Linux players can join a game
  hosted on a Mac and vice versa (the Mac app has its own built-in server, and `FieldCommand --server` runs a
  dedicated one on macOS).
- In game, press **Enter** to chat. The game keeps running when you open the menu.

All players must run the same version: the protocol is at 4 (Field Command 1.3.0, which added repair; 3 made
bridges destructible; 2 added the Sniper and the Radar Station), and a server refuses older clients rather
than letting them mis-read the game.

The server is authoritative: clients send orders and receive state snapshots (about 10–15 KB/s per player), and
fog of war is enforced on the server, so a modified client can't reveal the map.

Open the ports if Fedora's firewall is active (TCP for the game, UDP for LAN discovery):

```sh
sudo firewall-cmd --add-port=47777/tcp --add-port=47778/udp               # until reboot
sudo firewall-cmd --permanent --add-port=47777/tcp --add-port=47778/udp   # permanently
```

Internet play works the same way if the host forwards TCP port 47777 on their router.

## Controls

| Action | Input |
| --- | --- |
| Select / box-select | Left-click / drag (Shift adds, double-click selects all of a type) |
| Move, attack, mine, set rally point | Right-click (Ctrl+left-click also works) |
| Queue orders | Shift + right-click |
| Attack-move / Stop | A then click / S |
| Engineer builds | C Command Center · E Supply Depot · B Barracks · F Factory · T Turret · D Radar Station |
| Repair | Engineer + right-click a damaged building |
| Bridges | A then click to demolish · Engineer + right-click to rebuild |
| Train | W Engineer (HQ) · R Ranger, N Sniper (Barracks) · T Siege Tank (Factory) |
| Control groups | Ctrl+1–9 assign, 1–9 recall (double-tap to jump) |
| Idle engineer / army | I · \` or F2 |
| Camera | Arrows, screen edges, middle-drag, minimap; wheel or +/− to zoom; Space jumps to alerts |
| Pause & settings / help | P or Esc / H or F1 (online: the game keeps running) |
| Chat (multiplayer) | Enter |
| Fullscreen | F11 or Alt+Enter |

Settings (game speed, edge scrolling, sound, objectives, fullscreen) are saved to
`~/.config/fieldcommand/settings.json`.

## Developer options

```sh
make test                                   # the test suite (pip install pytest numpy)
make smoke                                  # headless AI-vs-AI match, prints the result
FC_AUTOSTART=1 ./field-command              # skip the menu (0 easy, 1 normal, 2 hard)
FC_HEADLESS=1 FC_AUTOPLAY=1 FC_SNAPSHOT_DIR=/tmp/fc ./field-command   # screenshots + stats log
FC_MAP=riverlands FC_OPPONENTS=11 FC_AUTOSTART=1 ./field-command      # a specific map and opponent count
FC_MAP=four_corners FC_OPPONENTS=3 FC_TEAMS=2 FC_AUTOSTART=1 ./field-command   # a 2v2 with a computer ally
```
