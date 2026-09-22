# Field Command — macOS edition

A real-time strategy game in Swift and SpriteKit: mine crystal with Engineers, build a base, train Rangers,
Snipers and Siege Tanks, and destroy every enemy building. All artwork is drawn procedurally with Core Graphics and
all sound effects are synthesised, so there are no asset files. The Linux port lives in `../linux/`.

## Build and run

```sh
swift build -c release && .build/release/FieldCommand   # run from the terminal
./build_app.sh                                          # build "build/Field Command.app"
open "build/Field Command.app"
```

`build_app.sh` writes the bundle, its `Info.plist` (including the local-network usage description needed for
LAN games), the icon and an ad-hoc signature. Requires Xcode command line tools; macOS 13 or newer.

## Maps

Pick a map and the number of computer opponents (up to eleven on a mega map) on the title screen, or let the
host choose one in the multiplayer lobby (*Map: Auto* picks one that fits the player count). **Teams** deals a
single-player game into alliances with computer allies, round-robin like the lobby's presets, and the line
under the map shows who is with whom — see `../linux/README.md`.

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
4000 x 2800). Maps carry their own size, so the fog, navigation and terrain grids are built to fit the map in play.

Water and cliffs block movement, building and line of fire; bridges are walkable until someone breaks them. Troops path around terrain
and buildings with A* on a 40-unit navigation grid (`Nav.swift`), so they no longer snag on the corner of a
base. The map catalogue and the pathfinding match the Linux edition exactly.

## How a game runs

Every game — single player included — is simulated by the authoritative server in `ServerWorld.swift` and
`GameServer.swift`. A skirmish starts a private server on a loopback port that is not announced on the LAN,
and the game window is its only client, so single player and multiplayer always behave identically. Pausing
is allowed only on such a private server. `Terrain.swift` draws water and cliffs from the map data the server
sends, so Mac and Linux clients see the same map whoever hosts it.

## Multiplayer (up to 12 players, Linux and Mac)

Choose **Multiplayer** (or press **M**) on the title screen: *Host Game* announces the game on the LAN and
shows the address others can type; joining works from the discovered list or by address. Either edition can
host and both can join the other. The lobby holds twelve slots (two columns) with free-for-all and 2/3/4-team
presets.

```sh
.build/release/FieldCommand --server --port 47777 --name "My server"   # dedicated server, no window
```

The server enforces fog of war, so a modified client cannot reveal the map. TCP 47777 carries the game and
UDP 47778 carries LAN discovery; forward the TCP port for internet play.

## Units and buildings

The catalogue matches the Linux edition exactly — including the **Sniper** (125 crystal at the Barracks once a
Factory stands; 330 range, which outranges Siege Tanks and Gun Turrets, but only 55 HP) and the **Radar
Station** (175 crystal, needs a Barracks; 900 sight, unarmed). See `../linux/README.md` for the numbers.

Both editions speak protocol 8, so a 1.8.0 Mac and a 1.8.0 Linux client play together; neither accepts an
older client, which would mis-read the newer units, orders and the state of the bridges.

## The Armory

**Y** opens the store: twelve pieces of kit, three per unit type, bought once with crystal and worn by every
unit of that type all match. The catalogue and effects match the Linux edition (`FC_STORETEST`).

## Attackers reveal themselves

Anything that hits you shows itself to your side for 2.5 seconds, even from beyond your sight, and fades
back into the fog when it stops firing.

## Veterancy and watchtowers

Units earn a rank at 2, 5 and 10 kills, each worth +10% damage and health, shown as chevrons. Three neutral
watchtowers per map are taken by holding their ring for 8 seconds and grant 700 sight to the holder. Rules
and placement match the Linux edition (`FC_TOWERTEST`).

## Building upgrades

A finished building's command card offers its upgrades — Reinforce (V, double hit points), Armour plating (X,
30% less damage), and on U: Assembly line for producers, Expanded storage for depots, Twin cannon for
turrets. One at a time per building, permanent, cancellable from the selection panel. The catalogue matches
the Linux edition exactly (`FC_UPGRADETEST`).

## Siege mode

Select Siege Tanks and press **G** to dig in: 2.5 seconds to set up, then 340 reach and 50-damage shells but no
movement and a blind spot inside 90. **G** again, or any move order, packs them up. Numbers match the Linux
edition (`FC_SIEGETEST` checks them).

## Repair

Select Engineers and right-click a damaged friendly building to repair it: 30 seconds for a full bar with one
Engineer (more stack), at 35% of the building's price for a full bar, charged as it heals. The rules and
numbers match the Linux edition exactly — `FC_REPAIRTEST` checks them.

## Bridges

Bridges have 900 hit points and belong to nobody: press **A** and click one to demolish it (a plain
right-click still walks across), or right-click the ruins with an Engineer selected to rebuild it for 75
crystal. A fallen span blocks movement and fire like the water it crossed. The rules and numbers match the
Linux edition — see `../linux/README.md`.

## Controls

Same as the Linux edition (see `../linux/README.md`), with **⌃⌘F** for full screen and **⌘Q** to quit.
Preferences (game speed, edge scrolling, sound, objectives, map, opponents) are stored in `UserDefaults`.

## Screenshots

**F12** in a game saves the view to `~/Pictures/field-command-<time>.png` with a `.txt` note of the version and
display scale — attach both to a bug report.

## Developer options

```sh
FC_WORLDTEST=1 .build/release/FieldCommand                    # AI-only game on every map, headless
FC_SKIRMISHTEST=riverlands FC_OPPONENTS=11 .build/release/FieldCommand  # headless skirmish incl. pausing
FC_HOSTTEST=1 .build/release/FieldCommand                     # host a lobby and play it headless
FC_NETTEST=host:port .build/release/FieldCommand              # join a server as a scripted bot
FC_SNAPSHOT_DIR=/tmp/fc …                                     # write screenshots and a stats log
FC_MENUSHOT=/tmp/menu.png .build/release/FieldCommand         # render the title screen and exit
FC_BRIDGETEST=river_crossing .build/release/FieldCommand      # shell a bridge down and rebuild it, headless
FC_REPAIRTEST=1 .build/release/FieldCommand                   # repair time, cost and limits, headless
FC_TEAMSTEST=1 .build/release/FieldCommand                    # single-player teams: the deal and a 2v2
FC_SIEGETEST=1 .build/release/FieldCommand                    # siege mode: transition, reach, blind spot
FC_UPGRADETEST=1 .build/release/FieldCommand                  # building upgrades: each effect and the rules
FC_TOWERTEST=1 .build/release/FieldCommand                    # veterancy ranks and watchtower capture
FC_STORETEST=1 .build/release/FieldCommand                    # the Armory: every kit effect and the rules
FC_CARDSHOT=/tmp/fc .build/release/FieldCommand               # screenshots of the command card for each selection
```
