# Field Command — macOS edition

A real-time strategy game in Swift and SpriteKit: mine crystal with Engineers, build a base, train Rangers,
Snipers and Siege Tanks, and destroy every enemy building. All artwork is drawn procedurally with Core Graphics
and every sound effect is synthesised at launch (`Audio.swift`, the same thirteen recipes as the Linux edition —
rifle, cannon, sniper crack, siege lock-down, explosions, chimes and alerts), so there are no asset files. The
Linux port lives in `../linux/`.

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
| Continental Divide | 12 | **Giant map**: a cliff spine splits north from south, five passes through it |
| Archipelago | 12 | **Giant map**: a rich island in an inland sea, four bridges, lakes along the rim |
| Six Rivers | 12 | **Giant map**: six rivers run from a central lake to the edges, two bridges each |
| Crater Fields | 12 | **Giant map**: every base inside a broken ring of cliffs; a walled crater in the middle |
| The Long March | 12 | **Giant map**: two rows of six bases across a wide river with six bridges |

The two mega maps play up to **twelve** players on a world half again as wide and tall (6000 x 4200 instead of
4000 x 2800); the five giant maps are half again as wide and tall as those (9000 x 6300). Maps carry their own
size, so the fog, navigation and terrain grids are built to fit the map in play. The giant maps' layouts are
baked into `GiantMaps.swift` from the Linux generator (`mapgen.bake_swift()`), and the parity tests check the
file is current.

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
Station** (175 crystal, needs a Barracks; 900 sight, unarmed) and the **Medic**. See `../linux/README.md` for
the numbers.

Both editions speak protocol 20, so a 1.38.0 Mac and a 1.38.0 Linux client play together; neither accepts an
older client, which would mis-read the newer units, orders and the state of the bridges.

## The computer opponent

Plays an opening (a rush, an economy or a turtle, from the seed by difficulty and map size), sends a scout to
your door, expands when its home field runs low or its Engineers crowd it, and keeps a turret and a garrison
at every expansion, fields Gunships against massed tanks and walls its approach with Barricades. Watches
what it can see of your army and builds to counter it, keeps its Snipers at range, and raids between waves
on Normal and Hard. Pulls a beaten wave back and counterattacks a repelled threat (`FC_COUNTERTEST`). Same
reasoning as the Linux edition (`FC_AITEST`).

## The Armory

**Y** opens the store: eighteen pieces of kit, three per unit type, bought once with crystal and worn by every
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

Select Engineers and right-click a damaged friendly building — or Siege Tank — to repair it: 30 seconds for a
full bar with one Engineer (more stack), at 35% of the building's or tank's price for a full bar, charged as it
heals. The rules and numbers match the Linux edition exactly — `FC_REPAIRTEST` and `FC_MEDICTEST` check them.

## Artillery and shield generators

**L** builds an Artillery emplacement (250, needs a Factory): 480 reach beyond its 300 sight, so a spotter
finds its targets; slow, high-arcing 45-damage shells with splash every 4 seconds, blind inside 150. **K**
builds a Shield Generator (225, needs a Barracks): every building of yours within 320 carries 300 shield
points that soak damage first and recharge. Same numbers as the Linux edition (`FC_ARTYTEST`).

## The campaign

**C** on the title screen opens five missions played in order — First Light, Hold the Line (survive eight
minutes), The Gold Run (hold the gold for three), Crossfire (2v2) and The Long March — each unlocking the
next as it is won; progress is kept in `UserDefaults`. Each is briefed before it is deployed (a map of the
mission, the objective, the timeline; Enter deploys) and runs a script on its clock: word from Command,
reinforcements from your map edge, enemy columns from theirs, a raid on your ally. Same missions, scripts
and rules as the Linux edition (`FC_CAMPAIGNTEST`). Every side starts with 5000 crystal.

## Unit abilities

Q on the card: a Ranger's Grenade (40 in a 60 burst, reach 200, 20 s), a Sniper's Mark Target (+50% damage
taken for 8 s, reach 360, 25 s) and a Siege Tank's Smoke (ranged hits within 120 halved for 8 s, 30 s). The
computer uses them too. Same numbers as the Linux edition (`FC_ABILITYTEST`).

## The start: crystal, an established base, reinforcements

Every side starts with 5000 crystal; Crystal and Base on the title screen set the bank (2000 to 20000) and
whether a base already stands (two depots, a Barracks, a Factory and a turret). From the Command Center's
card, call in four Rangers (G, 300) or two Siege Tanks (K, 600), which walk in from your edge of the map,
one call a minute. Same numbers as the Linux edition (`FC_STARTTEST`).

## Game modes

Mode on the title screen: Annihilation, King of the Hill (hold the gold ring three minutes; the ring is
drawn in the holder's colour, the computer contests it) or Sudden Death (lose your last Command Center and
you are out). Same rules and numbers as the Linux edition (`FC_MODETEST`).

## Replays and the career record

Every single-player game is recorded to `~/Library/Application Support/FieldCommand/replays/`, filed by
date and map (the newest forty kept). **Replays (R)** on the title screen lists them with map, date, length
and result; click one to watch it. Your career record (wins, losses, win rate) sits under the button and on
the end screen. Same files and rules as the Linux edition (`FC_REPLAYTEST`).

## The Gunship

An aircraft from the Factory (needs a Radar Station, Q) that flies straight over cliffs, water, walls and
units with a chain gun; tanks and artillery cannot fire at it, Rangers, Snipers, turrets and the Command
Center's gun can. Same numbers and rules as the Linux edition (`FC_AIRTEST`).

## Barricades

A 30-crystal block of wall (V on the Engineer card, Shift for a run) that blocks movement until it is shot
down; attackers stop and fire at it, and the computer still attacks a walled base. Same rules and numbers
as the Linux edition (`FC_WALLTEST`).

## Polish

The end screen's army-size timeline, Backspace to undo the last placement, a unit counter by type right of the
clock, rebindable keys (Keys… in the game menu) and first-run arrows — as the Linux edition has them
(`FC_POLISHTEST`).

## Music

Five synthesised loops over four chords — a pad, a plucked melody, a bass pulse, drums and a brass swell —
mixed by a threat meter fed by what the client sees and hears: the melody at the base, the pulse as the
enemy comes into view, drums while your forces fight, brass at the top. Units answer with a radio call when
selected and a quick acknowledgement on an order, each kind in its own voice with several lines. *Music:
On/Off* beside *Sound*. Same recipe and numbers as the Linux edition (`FC_AUDIOTEST`).

## Alloy

The second resource: gold yields alloy, every side starts with 100, and tanks (30), Gunships (40), Artillery
(50), the Twin cannon (20) and the two techs (40, 60) cost it on top of crystal. Refunded when undone, an
ingot counter beside the crystal one, the computer mines it once it has a Factory. Same numbers as the Linux
edition (`FC_ALLOYTEST`).

## Tech

Entrenchment at the Barracks (150, 40 s: Rangers and Snipers that hold still for 3 s take 30% less
damage, "dug in" on the card) and Stabilisers at the Factory (200, 50 s: Siege Tanks fire on the move);
each is researched once for the whole side. Same numbers as the Linux edition (`FC_TECHTEST`).

## The derelict Siege Tank

A wreck near the middle of every map: an Engineer alone beside it for 12 s salvages it into a working Siege
Tank of that side; troops cannot, an enemy inside the ring stalls it, and the computer sends an Engineer with
an escort. Same placement and numbers as the Linux edition (`FC_DERELICTTEST`).

## Cover

Anyone on foot among trees (within 24 of a trunk) takes half damage from ranged fire (a hit from further
than 60); tanks and aircraft get nothing, and it does not stack with smoke. The unit card says "in cover"
and a green badge sits by the health bar. Same numbers as the Linux edition (`FC_COVERTEST`).

## High ground

Plateaus on Twin Ridges, Highland Pass and Four Corners, drawn raised: walkable, buildable, and anything on
one sees 30% further and shoots 40 further, turrets included. Same rectangles and numbers as the Linux
edition (`FC_HIGHTEST`).

## Satellite view, point defence and supply crates

**Tab** shows the whole map with markers for every troop and building (Tab, Space or a minimap click brings
you back). **J** on a Command Center buys point defence: a roof gun with 240 reach. Supply crates drop on the
field every 75 seconds; the first unit to reach one banks crystal or gains a squad or a tank. The computer
reopens a cut route by rebuilding the bridge on its way (`FC_AITEST`). Same rules as the Linux edition
(`FC_UPGRADETEST`, `FC_CRATETEST`).

## Medics

**M** at the Barracks trains a Medic (75 crystal): unarmed, it heals anyone on foot at 6 HP a second within
60 units, finds the wounded by itself, and on an attack-move stops for casualties and carries on. Right-click
a wounded friendly to send one. Same rules as the Linux edition (`FC_MEDICTEST`).

## Bridges

Bridges have 900 hit points and belong to nobody: press **A** and click one to demolish it (a plain
right-click still walks across), or right-click the ruins with an Engineer selected to rebuild it for 75
crystal. A fallen span blocks movement and fire like the water it crossed. The rules and numbers match the
Linux edition — see `../linux/README.md`.

## Controls

Same as the Linux edition (see `../linux/README.md`), with **⌃⌘F** for full screen and **⌘Q** to quit.
Preferences (game speed, edge scrolling, sound, objectives, map, opponents) are stored in `UserDefaults`.

## Gold deposits

Every map has a contested gold deposit: nodes worth 150,000 crystal each, drawn gold, mined at the normal
rate and never running out. Same sites as the Linux edition (the parity tests check them).

## Alert points

**Z** then click — or **Option+click** — on the map or the minimap drops an attack point (a reticle), and
**Shift+Z** a help point (a pennant): a beacon and a minimap ping for your whole side, a message, and Space to
jump there. Computer allies send their idle troops.
Same rules as the Linux edition (`FC_PINGTEST`).

## Replays

Every single-player game is recorded to `~/Library/Application Support/FieldCommand/replays/last.json` and
**Watch Last Game (R)** on the title screen plays it back exactly: the simulation is deterministic (one
seeded generator, fixed 1/30 s steps) and the replay is the seed plus your commands by tick. Same file
format as the Linux edition; `FC_REPLAYTEST` checks determinism and playback.

## Saving and loading

Leaving a game for the main menu autosaves first, so Load Game continues it. **F5** quick-saves a single-player game and **F9** loads it back; the pause menu has *Save Game* and *Load
Game*, the title screen's **Load Game (L)** resumes the newest save, and the game autosaves every five
minutes. Saves are the same JSON document the Linux edition writes, kept in `~/Library/Application
Support/FieldCommand/saves/`, so a game saved on either platform loads on the other (`FC_SAVETEST` loads a
Linux-written save and plays it on).

## The look

The camera is tilted (its y scale is the zoom over the tilt), buildings stand on walls of their own
outline, and entities are depth-sorted by their y each frame. Otherwise the same procedural scene as the
Linux edition: a sun from the upper left with biome tints (a multiply layer
over the ground), drifting cloud shadows, wheel ruts along roads, pebbles, darker forest floors, craters that
stay, wrecks and the fallen, and a white flash on anything hit; pebbles, tufts and wildflowers on the ground,
dust behind anything on the move and tracks behind tanks, and a soft glow in your colour under selected units.

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
FC_AITEST=1 .build/release/FieldCommand                       # the opponent: observation, counters, standoff
FC_AUDIOTEST=1 .build/release/FieldCommand                    # every synthesised effect, length and loudness
FC_MEDICTEST=1 .build/release/FieldCommand                    # Medics healing, Engineers repairing tanks
FC_PINGTEST=1 .build/release/FieldCommand                     # alert points: alliance-only, rate limit, AI allies answer
FC_ARTYTEST=1 .build/release/FieldCommand                     # artillery reach, arc and blind spot; shields soak and recharge
FC_CRATETEST=1 .build/release/FieldCommand                    # supply crates: drop, pickup, gifts, expiry, save
FC_CAMPAIGNTEST=1 .build/release/FieldCommand                 # mission rules: survive, hold, progress, save
FC_REPLAYTEST=1 .build/release/FieldCommand                   # determinism, and a recorded game replaying exactly
FC_SAVETEST=1 FC_SAVE_FIXTURE=../tests/fixtures/save_python.json .build/release/FieldCommand   # save round trip + a Linux save
FC_CARDSHOT=/tmp/fc .build/release/FieldCommand               # screenshots of the command card for each selection
```
