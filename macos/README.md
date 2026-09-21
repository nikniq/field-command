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
host choose one in the multiplayer lobby (*Map: Auto* picks one that fits the player count).

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

Water and cliffs block movement, building and line of fire; bridges are walkable. Troops path around terrain
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

Both editions speak protocol 2, so a 1.1.0 Mac and a 1.1.0 Linux client play together; neither will accept a
1.0.0 client, which predates these two.

## Controls

Same as the Linux edition (see `../linux/README.md`), with **⌃⌘F** for full screen and **⌘Q** to quit.
Preferences (game speed, edge scrolling, sound, objectives, map, opponents) are stored in `UserDefaults`.

## Developer options

```sh
FC_WORLDTEST=1 .build/release/FieldCommand                    # AI-only game on every map, headless
FC_SKIRMISHTEST=riverlands FC_OPPONENTS=11 .build/release/FieldCommand  # headless skirmish incl. pausing
FC_HOSTTEST=1 .build/release/FieldCommand                     # host a lobby and play it headless
FC_NETTEST=host:port .build/release/FieldCommand              # join a server as a scripted bot
FC_SNAPSHOT_DIR=/tmp/fc …                                     # write screenshots and a stats log
FC_MENUSHOT=/tmp/menu.png .build/release/FieldCommand         # render the title screen and exit
```
