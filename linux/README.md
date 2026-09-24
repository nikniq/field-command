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
| Siege Tank | 150 | Factory | 230 range, splash damage; can dig in (see below) |
| Medic | 75 | Barracks | Unarmed; heals anyone on foot, 6 HP a second (see below) |

The **Sniper** outranges everything that can shoot back — Siege Tanks reach 230 and Gun Turrets 210 — so a
few of them behind your line pick apart tanks and turrets before those can answer. They reload slowly and
die quickly, so they lose to anything that closes the distance: screen them with Rangers.

The **Siege Tank** can dig in — select it and press **G** (or the *Siege* button). It takes 2.5 seconds to set
up, during which it neither moves nor fires; dug in, it reaches 340 with 50-damage shells and a wider splash,
sees as far as it shoots, and cannot move or hit anything closer than 90. Press **G** again to pack up (another
2.5 seconds), or simply give it a move order and it packs up on its own. Mobile, a Sniper outranges it; sieged,
it outranges the Sniper — so tanks want to be set up before the Snipers arrive, and something up close to
handle what slips inside the ring. Computer players dig in when an enemy building is in reach and pack up
when nothing is.

The **Medic** (75 crystal, 50 HP, no weapon) heals Engineers, Rangers, Snipers and other Medics at 6 hit
points a second, one patient at a time, within 60 units. Left to itself it looks for the wounded as far as it
can see and walks over; on an attack-move (**A** then click) it advances with the line and stops for anyone
hurt on the way, then carries on. Right-click a wounded friendly with a Medic selected to send it there. An
attack order becomes an attack-move — it goes along, it never shoots. Vehicles are not its business: Siege
Tanks are repaired by Engineers (see *Repair*). The computer fields one Medic for every four troops on foot.

The **Radar Station** (175 crystal, needs a Barracks) sees 900 units in every direction, roughly three times
a Command Center, and its dish sweeps while it works. It carries no weapons and 520 HP, so put it behind
your lines or next to a Turret. One near a contested expansion shows attacks forming long before they
arrive; the server enforces fog of war, so this vision is the only way to watch ground you do not hold.

## The computer opponent

It plays an opening. Before the first minute is out it has settled on a **rush** (Barracks at once, a
small early wave, fewer Engineers), an **economy** (more Engineers, an early expansion, a later and larger
first wave) or a **turtle** (turrets and a shield generator early, the largest and latest first wave). Easy
never rushes, Hard tries all three, and nobody rushes across a giant map; which one it picks comes from the
game's seed, so a replay sees the same opening. A single trooper goes scouting at about 45 seconds: to your
Command Center's ground, past the two fields nearest the way there, and home, so its tally of your army
has something to count. It expands on the clock, or earlier when the field by its Command Center is under
45% of what it started with or its Engineers outnumber what the field can feed, and every expansion it
takes gets a turret of its own and a standing garrison (two, three or four troops by difficulty) that
answers raids on that post instead of leaving with the next wave. The balance runner reports wins by
opening, so its openings are tuned on evidence. It fields **Gunships** once it has a Factory and a Radar
Station — more of them against massed tanks, and more Rangers and Snipers when it sees yours — and it
walls its approach with **Barricades**: a turtle from the third minute, anyone within a minute of a
building taking damage, six blocks in two lines either side of a gap so its own army still marches out.

It knows when a fight is lost: a wave that has lost more than 60% of itself with the enemy still on it
**pulls back** to the Command Center rather than dying piecemeal, and the next wave waits at least forty
seconds more to be worth sending. And it knows when you are spent: on Normal and Hard, within twenty seconds
of a threat to one of its bases being repelled, if its home army is at least half a wave, it
**counterattacks** at once — the one time it attacks off the clock — no more than once a minute.

When every crossing to you is down, it knows its route is cut: an Engineer goes to rebuild the bridge on
the way, an escort holds the near bank, and the attack wave waits for the span instead of bouncing off the
water.

The computer keeps a tally of every enemy unit its side can see and builds to answer it: massed Rangers
bring tanks, tanks bring Snipers, Snipers bring tanks and Rangers together. Its Snipers stop 200 short of
whatever the army is attacking so they fight at their range instead of walking into the line, and from the
fourth minute on Normal and Hard a couple of troops raid your outlying buildings between waves. Scouting it
matters more than it did: what it sees of you is what it builds against.

## The Armory

Press **Y** (or the *Armory* button in the top bar) to open the store. Kit is bought once with crystal and worn
by every unit of that type for the rest of the match — including the ones already in the field, which get the
extra health on the spot. Fifteen pieces, three per unit type:

| Unit | Kit | Cost | Effect |
| --- | --- | --- | --- |
| Engineer | Hard hat | 100 | +50% hit points |
| | Power tools | 150 | repairs and rebuilds 30% faster |
| | Cargo rig | 150 | 12 crystal per trip instead of 8 |
| Ranger | Flak jacket | 200 | +25% hit points |
| | Hollow points | 250 | +20% damage |
| | Sprint boots | 150 | +15% speed |
| Sniper | Long scope | 300 | +30 range (360 — further than a dug-in tank) |
| | Ghillie suit | 200 | +25% hit points |
| | Match ammo | 250 | reloads 20% faster |
| Siege Tank | Reactive armour | 300 | +25% hit points |
| | Extended barrel | 300 | +20 range, mobile and dug in |
| | Autoloader | 350 | reloads 20% faster |
| Medic | Trauma kit | 200 | heals 50% faster |
| | Ceramic plates | 150 | +30% hit points |
| | Field litter | 150 | +15% speed |

Kit stacks with veterancy and with building upgrades, so the mix you buy shapes your army: Long scope lets
Snipers out-reach sieged tanks again, Extended barrel gives tanks it back, and a Cargo rig is the cheapest
income boost in the game. Computer players shop too once they are sitting on crystal.

## Attackers reveal themselves

Anything that hits you shows itself to your side for 2.5 seconds, even from beyond your sight. A Sniper or a
dug-in Siege Tank shelling you from the dark appears on the map and the minimap for as long as it keeps
firing, so it can be seen and answered; stop firing and it fades back into the fog.

## Veterancy

Every unit counts its kills. At **2, 5 and 10** it earns a rank, and each rank adds **10%** to its base damage
and hit points — the extra health is granted on promotion, so a veteran walks out of the fight stronger, not
merely with a taller empty bar. Chevrons above the unit show its rank, and the selection panel says
"Rank 2 (5 kills)". Buildings count too: a Sniper that finishes off a Turret gets the credit. Pulling a
wounded rank-3 tank back to be repaired is now worth more than a fresh one.

## Watchtowers

Every map has three neutral **watchtowers** — one at the centre, one on each flank, nudged onto dry ground
by the same rule in both editions, applied to the map the server generated, so every client in a game sees
them in the same place. Park troops inside
a tower's ring (140) for **8 seconds** with nothing hostile in it and it is yours: a pennant in your colour
goes up, and you see **700** around it until someone takes it back the same way. A contested ring never
flips, and the capture clock winds back when the ring empties. Towers are marked on the minimap, and
computer players send a few idle troops to sit on the nearest one they do not hold.

## Artillery

The **Artillery** emplacement (250 crystal, needs a Factory, hotkey **L**) is a fixed gun with 480 reach —
further than a dug-in Siege Tank's 340 or a Sniper's 360 — but only 300 sight, so it can only hit what
something of yours can see: push a Ranger, a Radar Station or a watchtower forward and the guns behind you do
the rest. It lobs a 45-damage shell with a 55 splash every 4 seconds; the shell climbs in a high, slow arc
(380 a second) that you can follow across the screen and lands with a blast. It cannot hit anything inside
150, so it needs a turret or troops to guard it up close. The placement ghost shows both circles. Computer
players build one from about eight minutes in and a second late in a long game.

## Shield generators

The **Shield Generator** (225 crystal, needs a Barracks, hotkey **K**) projects a field over every building
of yours within 320 — including itself. Each carries up to 300 shield points, shown as a blue bar above the
health bar, that soak damage before the walls take any; four seconds after the last hit they recharge at 15
a second. Overlapping generators do not stack. If the generator falls, the field collapses over the next
few seconds. Armour plating applies before the shield, so an armoured, shielded Command Center is a very hard
nut. Computer players build one from about six minutes in.

## The Gunship

The **Gunship** (200 crystal, 3 supply, hotkey **Q** at the Factory once you have a Radar Station) is an
aircraft: it flies in a straight line over cliffs, water, Barricades and other units, fast, with a chain
gun (22 damage at range 130, seven shots every five seconds). It is drawn up in the air with its shadow on
the ground. Siege Tanks and Artillery cannot fire at it; Rangers, Snipers, turrets, the Command Center's
point-defence gun and other Gunships can. Use it to reach a walled expansion, hunt Engineers on a far
field, or pick off tanks from where they cannot answer — and keep it away from turrets.

## Unit abilities

Three kinds carry an ability on **Q** of their card, each on its own clock:

| Unit | Ability | What it does | Reach | Recharge |
|---|---|---|---|---|
| Ranger | **Grenade** | click a spot: 40 damage to everything within 60 of where it lands | 200 | 20 s |
| Sniper | **Mark Target** | click an enemy: it takes 50% more damage from everyone for 8 s (an amber reticle shows it) | 360 | 25 s |
| Siege Tank | **Smoke** | pops smoke where it stands: ranged hits (from further than 60) on anything within 120 do half damage for 8 s | self | 30 s |

With a group selected, every unit of that kind whose ability is ready uses it at once; the button greys out
and counts down while none is ready. The computer throws grenades into knots of your troops, marks your
toughest unit in reach and smokes its hurt tanks.

## Barricades

The **Barricade** (30 crystal, hotkey **V** on the Engineer card, no requirements) is a block of wall: 700
hit points, 44 across, up in eight seconds, and nothing walks through it. Hold **Shift** to place a run of
them. Movement, pathfinding and the computer's route-finding treat them like cliffs, so a walled-off base
has to be shot open: attackers walk up to the nearest block and fire, and the computer, finding no bridge
to rebuild, sends its wave anyway. Cover a pass with a line of them and a turret behind, or wall your
expansion's field and make the enemy pay for the way in. Engineers repair them like any building.

## Point defence

The Command Center can be armed: the **Point defence** upgrade (**J**, half the Center's price, 35 seconds)
mounts a gun on its roof that fires on anything hostile within 240 for 14 damage every 0.6 seconds — a
turret's reach, a little less bite — so a raid on an unguarded base is no longer free. Computer players buy
it after armour.

## Building upgrades

Select a finished building and the command card offers its upgrades. Each is researched by that building
alone, one at a time, and is permanent for it; click the progress bar in the selection panel to cancel and
get the crystal back.

| Upgrade | Key | Buildings | Effect | Cost | Time |
| --- | --- | --- | --- | --- | --- |
| Reinforce | V | all | doubles hit points (the new structure is sound, so it heals by the amount added) | 60% of price | 30s |
| Armour plating | X | all | takes 30% less damage | 60% of price | 30s |
| Assembly line | U | Command Center, Barracks, Factory | trains units twice as fast | 80% of price | 40s |
| Expanded storage | U | Supply Depot | +8 supply, doubling the depot | 75 | 20s |
| Twin cannon | U | Gun Turret | damage 11 to 20, range 210 to 260 | 90 | 35s |

Upgrades apply to the building they were bought on, so a Barracks with an Assembly line is worth more than a
second Barracks, and a Twin-cannon Turret outranges a mobile Siege Tank (230) though not a Sniper (330).
Computer players buy upgrades once they are sitting on crystal: production first, then armour on their
Command Center, then guns.

## Repair

Select Engineers and right-click a damaged building of yours or an ally's — or a damaged **Siege Tank** — to
repair it. One Engineer restores a full health bar in 30 seconds, and more Engineers work proportionally
faster. A full bar costs 35% of the building's or tank's price, charged as the health goes back on, so
patching a half-wrecked Command Center costs 70 crystal and a half-dead tank 26. If the crystal runs out,
repair stops rather than going into debt. When the job is done each Engineer goes back to what it was doing.
An Engineer follows a tank that moves off mid-repair. Buildings still under construction finish on their own
and cannot be repaired; infantry is healed by Medics, not repaired.

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

## The start: crystal, an established base, reinforcements

Every side starts with **5000 crystal**; the **Crystal** button on the title screen sets it to 2000, 5000,
10000 or 20000 for a skirmish. The **Base** button starts every side **fresh** (a Command Center and five
Engineers) or **established**: two Supply Depots, a Barracks, a Factory and a turret already standing around
the Command Center, turned to face the middle of the map (a spot a cliff or the mineral line will not take
is left out). Both travel in saves and replays.

**Off-map reinforcements**: select the Command Center and call in **four Rangers (G, 300 crystal)** or
**two Siege Tanks (K, 600)**. They walk in from your edge of the map and report to the Command Center. One
call a minute; the button shows when the next is ready.

## Game modes

The **Mode** button on the title screen sets the skirmish rule. **Annihilation** is the usual one: destroy
every enemy building. **King of the Hill**: the first side to hold the gold ring (260 around the gold
deposit; every map has one) for three minutes, uncontested, wins — anything of yours inside counts, any
enemy unit inside stops every clock, and the ring is drawn on the ground in the holder's colour with the
standing in the objectives row; the computer sends its waves at the ring until it leads there. **Sudden
Death**: lose your last Command Center and you are out, with everything you own. Campaign missions carry
their own rules. The mode travels in saves and replays.

## The campaign

**C** on the title screen (or the *Campaign* button) opens five missions played in order, each unlocking the
next as it is won:

| # | Mission | Map | Objective |
| --- | --- | --- | --- |
| 1 | First Light | Twin Ridges, one easy opponent | Destroy the enemy base |
| 2 | Hold the Line | River Crossing, one hard opponent | Be standing after eight minutes |
| 3 | The Gold Run | Highland Pass, one opponent | Hold the gold deposit for three minutes without an enemy in the ring |
| 4 | Crossfire | Four Corners, you and an ally against two | Destroy both enemy bases |
| 5 | The Long March | The Long March, twelve commanders in two teams | Destroy the other team |

The mission's objective sits at the top of the objectives panel with its clock; a won mission shows *Mission
complete* with a *Next Mission* button. Progress is kept in the settings file. Every side starts with 5000
crystal in a mission.

Every mission is **briefed** before it is deployed: a map of the mission (water, cliffs, crystal and gold,
every side's start, the hold ring), the objective, and a timeline of what the clock will bring. **Enter**
deploys, **Esc** goes back to the list, and *Next Mission* after a win opens the next briefing.

Every mission runs a **script** on its clock: word from Command at the right moments, reinforcements that
walk in from the map edge nearest your start and stop short of your Command Center, enemy columns that
come in from theirs and attack-move on your base — or on the gold ring, or on your ally (in Crossfire the
call is *Your ally is under attack*), announced as they appear. The script's position travels in saves,
and a replay runs it the same way. The five scripts live in `defs.py` (`CAMPAIGN`).

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
| Continental Divide | 12 | **Giant map**: a cliff spine splits north from south, five passes through it |
| Archipelago | 12 | **Giant map**: a rich island in an inland sea, four bridges, lakes along the rim |
| Six Rivers | 12 | **Giant map**: six rivers run from a central lake to the edges, two bridges each |
| Crater Fields | 12 | **Giant map**: every base inside a broken ring of cliffs; a walled crater in the middle |
| The Long March | 12 | **Giant map**: two rows of six bases across a wide river with six bridges |

The two mega maps play up to **twelve** players on a world half again as wide and tall (6000 x 4200 instead of
4000 x 2800). The five **giant** maps are half again as wide and tall as those — 9000 x 6300, five times the
standard area — with twelve bases, so expansions matter, armies take a while to arrive, and a Radar Station
or a watchtower is worth more than another turret. Every other map is the standard size. A twelve-way
free-for-all against computer players is demanding but runs fine on a normal desktop; on a giant map give it
a minute or two longer to come to blows, and expect this edition to use about a gigabyte of memory for the
world-sized ground and terrain images.

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

All players must run the same version: the protocol is at 8 (Field Command 1.8.0, the Armory; 7 veterancy and watchtowers;
6 building upgrades; 5 siege mode; 4 repair; 3 destructible bridges; 2 the Sniper and the Radar Station),
and a server refuses older clients rather than letting them mis-read the game.

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
| Siege / unsiege | G with Siege Tanks selected (a move order also packs them up) |
| Building upgrades | V Reinforce · X Armour · U Assembly line / Expanded storage / Twin cannon |
| The Armory | Y — buy kit for your troops |
| Repair | Engineer + right-click a damaged building |
| Bridges | A then click to demolish · Engineer + right-click to rebuild |
| Train | W Engineer (HQ) · R Ranger, N Sniper (Barracks) · T Siege Tank (Factory) |
| Control groups | Ctrl+1–9 assign, 1–9 recall (double-tap to jump) |
| Idle engineer / army | I · \` or F2 |
| Camera | Arrows, screen edges, middle-drag, minimap; wheel or +/− to zoom; Space jumps to alerts |
| Pause & settings / help | P or Esc / H or F1 (online: the game keeps running) |
| Attack point / help point for allies | Z then click (or Alt+click) / Shift+Z then click, map or minimap |
| Refine a mixed selection | Click a portrait: keep only that kind · Shift+click: drop that kind · Ctrl+click: just the one |
| Quick save / quick load (single player) | F5 / F9 |
| Chat (multiplayer) | Enter |
| Fullscreen | F11 or Alt+Enter |

Settings (game speed, edge scrolling, sound, objectives, fullscreen, health bars always on) are saved to
`~/.config/fieldcommand/settings.json`.

## High ground

Some maps have raised plateaus — drier, lighter grass with a lit rim and a shadow down the far side — on
Twin Ridges (two flanking the gold), Highland Pass (one on the middle side of each outer pass) and Four
Corners (either side of the gold). They are walkable and buildable, and anything standing on one, turrets
included, sees 30% further and shoots 40 further. Hold the plateau and you hold the ground below it; the
briefing map shows them as the lighter patches.

## The campaign has stakes

Three things carry weight between missions. **Veterans**: when you win, up to eight of your surviving units
with a rank (Rangers, Snipers, tanks, Medics, Gunships) are kept, and deploy with you at the start of the
next mission at the rank they earned, standing behind the Command Center. Lose them and they are gone; win
without them and the roster is whatever survived. **Branches**: First Light opens both Hold the Line and
The Gold Run, either of those opens Crossfire, and Crossfire opens The Long March, so the middle of the
campaign is yours to order. **Named units**: The Gold Run puts **Sergeant Kade**, a Sniper, and The Long
March **Colonel Rook**, a Siege Tank, at your Command Center from the first second. The briefing says
*must survive*, the card carries the name, and the moment one falls the mission is lost.

## Alloy: the second resource

Crystal pays for everything, but the heavy end of the army also costs **alloy**, shown as an ingot beside the
crystal counter. Every side starts with **100**; the only source after that is a **gold deposit**, which
yields alloy instead of crystal (a trip's cargo either way, so two Engineers on the gold bring in about an
alloy a second). The prices, on top of crystal: Siege Tank **30**, Gunship **40**, Artillery **50**, Twin
cannon **20**, Entrenchment **40**, Stabilisers **60**. Off-map reinforcement tanks stay crystal-only. A
cancelled order or an undone placement hands the alloy back, and the card shows the alloy under the crystal
price, red when you are short. The decision it makes you take: hold the middle for a heavy army, or stay
light and fast and let the enemy walk out for it. The computer puts two Engineers on the nearest gold node
as soon as it has a Factory.

## Tech: Entrenchment and Stabilisers

Two upgrades are **tech**: researched once, at one building, and the whole side's army changes. Nobody can
buy either twice; the button shows it installed on every Barracks or Factory you own once one has it.

| Tech | Where | Cost | Time | Effect |
|---|---|---|---|---|
| **Entrenchment** (E) | Barracks | 150 | 40 s | Rangers and Snipers that hold still for 3 s are *dug in*: they take 30% less damage from everything until they move (it stacks with cover) |
| **Stabilisers** (B) | Factory | 200 | 50 s | Siege Tanks fire on the move: a tank under a move order shoots whatever comes within reach without stopping, so it can fight its way out |

The computer researches both once it is sitting on crystal, after its assembly lines.

## The derelict Siege Tank

Every map has a **derelict Siege Tank** near the middle — on the nearest open ground to the gold that the
centre watchtower did not take, an amber square on the minimap. An **Engineer** alone beside it (within 90,
with nothing hostile inside that ring) for **12 seconds** salvages it: it becomes a working Siege Tank of
that side, on the spot, no crystal asked. Troops cannot do the work, an enemy inside the ring stalls it, and
the clock winds back while nobody is at it. It is a free tank in the first minute for whoever walks out for
it, and the computer walks out for it with an escort of two from the twentieth second. Every mode has it.

## Cover

Forests are more than obstacles. Anyone **on foot** — Rangers, Snipers, Medics, Engineers — standing among
trees (within 24 of a trunk) takes **half damage from ranged fire**, meaning any hit from further than 60.
Tanks and Gunships get nothing from a forest, a point-blank burst is not ranged, and cover does not stack
with a tank's smoke: the better of the two applies. The unit card says *in cover* and a green badge sits by
the health bar of a selected or hovered unit that has it. Fight from the treeline; make the enemy cross the
open. Every map's forests are laid out by the generator, so the cover is where the trees are.

## Gold deposits

Every map has at least one **gold deposit** — nodes drawn in gold, each worth 150,000 crystal, a hundred times
a normal field. They are mined like any other node, at the same rate, and they do not run out: the side that
holds the deposit never wants for crystal. They sit where the fighting is — the centre of most maps, the
middle bridges of River Crossing and The Long March, the middle pass of Continental Divide, north and south of
the lake on Six Rivers — and show as larger gold dots on the minimap.

## Alert points

Press **Z** (or the *Attack (Z)* button in the top bar) and click the map or the minimap — or simply
**Alt+click** — to drop an **attack point**: a target reticle in your colour that everyone on your side sees,
with a ping on the minimap, a message, and **Space** to jump to it. **Shift+Z** drops a **help point** (a
pennant) instead — "come and defend here". Computer allies answer it: whatever they
have standing at home, at least a pair and up to a wave's worth, sets off for the point and fights on from
there. One alert point every three seconds; enemies never see them. Use it to direct the whole team onto a
push, a defence or a bridge.

## Replays

Every single-player game is recorded — its seed, its setup and every command you gave, by tick — and
written to `~/.local/share/fieldcommand/replays/` when it ends or when you leave for the menu, filed by
date and map (`20260924-153012_twin_ridges.json`); the newest forty are kept. **Replays (R)** on the title
screen opens the browser: every recording with its map, date, length and result (won, lost or unfinished),
newest first; click one to watch it. The same simulation runs again from the same seed with your commands
fed in at the same ticks, so it is the same game to the last shot, and a replay of an hour is a few
kilobytes. While watching, the clock says *REPLAY* and input is ignored. Attach the file to a bug report;
it reproduces the game exactly on the same edition.

Under the button sits your **career record** — games won and lost, and the win rate — kept in the settings
file, overall and by difficulty; the end screen shows it too. Replays and multiplayer games do not count.

This works because the simulation is deterministic: every random choice comes from one generator seeded
per game, and the world always steps by exactly 1/30 s (game speed changes how many steps run per second).

## Balance runs

`./cx.sh batch --games 5 --maps twin_ridges,river_crossing --difficulty 1 --out runs.csv` (or
`python -m fieldcommand.batch`) plays computer-only games headless and writes a row per player per game —
who won, how long it took, what was trained, built, lost and mined — then prints win rates by start slot,
average length and the unit mix, and from 1.20 the wins by opening (rush, economy, turtle) per map. Balance changes are judged on those numbers.

## Polish: the timeline, undo, the counter, keys, the first run

The end screen carries a **timeline**: every side's army size over the game, one line per side in its
colour, sampled every 15 seconds (it travels in saves and over the wire). **Backspace** takes back the last
placement within 20 seconds — the site if it has barely started, for a full refund, or the Engineer's
pending order — and a **unit counter** right of the clock shows how many of each combat kind you field.
**Keys…** in the game menu opens the bindings: click an action, press a key; one key per action, *Reset
to defaults* puts them back. On the first single-player game **arrows** point at what each opening
objective needs — the Command Center, an Engineer, the card button — until the opening is walked through.

## Saving and loading

Leaving a single-player game for the main menu writes an autosave first, so **Load Game (L)** on the title
screen picks up where you left off. Single-player games can be saved and resumed: **F5** quick-saves and **F9** loads it back, the pause menu
(**P**) has *Save Game* and *Load Game*, and the title screen's **Load Game (L)** button resumes the newest
save. The game also autosaves every five minutes. Multiplayer games cannot be saved (the server owns them).

A save is one JSON document holding the whole simulation — every unit and its orders, buildings and their
queues and upgrades, crystals, bridges, watchtowers, kit, the computer opponents' plans and each side's
explored ground. Files live in `~/.local/share/fieldcommand/saves/` (Windows: `%APPDATA%\FieldCommand\saves`).
The macOS edition writes and reads exactly the same document, so a game saved on one platform loads on the
other; `tests/fixtures/` holds a save from each edition and both suites load the other's.

## Satellite view

**Tab** (or the *Satellite (Tab)* button in the top bar) pulls the camera back until the whole map is on
screen, with every troop drawn as a solid dot and every building as a square in its side's colour so they
still read from orbit. Orders, selection and the minimap all work as usual from up there; **Tab** again,
**Space** or a minimap click brings you back to where you were.

## Supply crates

From the first minute a supply crate drops somewhere open every 75 seconds (at most four on the field; each
lasts three minutes). The first unit of any side to walk onto one collects its gift: 150–400 crystal, a
squad of three Rangers, or a Siege Tank, spawned on the spot. Crates show while they are in your sight,
with a beacon glow; computer players send a trooper for any they can see near home.

## Music

There is no music file: five loops of 19.2 seconds — four bars over A minor, F, C and G at 100 beats a
minute — are synthesised at start and mixed by a threat meter the client keeps from what it sees and hears:
a **pad** of sustained chords (always there), a plucked **melody** with an echo (the calm layer, which
yields as the threat climbs), a bass **pulse** on the roots (up as enemies come into view), **drums** with
a fill at the turn (up while your forces are fighting and when the base is under attack) and a **brass**
swell only at the very top.

Units have **voices**: a radio call when selected and a quick acknowledgement when given an order, each
kind in a voice of its own — the Engineer's clean chirp, the Ranger's buzz, the Siege Tank's growl an
octave down, the Sniper's thin whistle, the Medic's soft warble and the Gunship's rotor-chopped call — with
three lines on selection and two on an order, never the same one twice running, synthesised like
everything else. The meter climbs in about a
second and settles over six, so the music breathes rather than flickers. The title screen plays the pad
alone. *Music: On/Off* sits beside *Sound* on the title screen and in the pause settings; both editions use
the same recipe (`music.py`, `Audio.swift`).

## The look

The camera looks down at an angle, not straight down: the ground is foreshortened north to south, every
building stands on dark walls that show its height, and whatever is nearer the camera draws over what is
behind it. The simulation is untouched by this — it is the same flat world seen from a tilt — so nothing on
the wire or in a save changes. Everything is drawn procedurally at launch — there are no image files — and the scene is lit as one place:
a sun from the upper left brightens that corner of every map and cools the far one, low-frequency biome
tints break the grass into straw, forest floor and scrub, cloud shadows drift across the ground, roads carry
wheel ruts, and the ground under a stand of trees is darker than open grass. Combat leaves marks: craters
stay for a minute and a half, tanks leave wrecks, anyone on foot who falls stays where they dropped for a
while, and anything hit flashes white for a few frames. Buildings smoke below half health and burn below a
quarter. The ground is strewn with pebbles, tufts and wildflowers; anything on the move kicks up dust and
tanks press tracks into the ground behind them; a selected unit of yours glows softly in your colour. The
macOS edition draws the same scene from the same recipes.

## Screen size and UI scale

The interface is drawn at a fixed design size and scaled to the window: **2x** on 4K-class screens, **1.5x**
on 1440p-class, **1x** otherwise, judged by the shorter side. Without this, on a 4K monitor the command card
was a row of 64-pixel buttons in the corner and its icons were a few millimetres wide. Override the choice
with **UI scale** on the title screen (Auto / 1x / 1.5x / 2x) or `FC_UI_SCALE=2`.

**F12** saves a screenshot of the window to `~/Pictures/field-command-<time>.png` together with a `.txt` note
of the versions, window size, scale and display driver — attach both to a bug report.

## Developer options

```sh
make test                                   # the test suite (pip install pytest numpy)
make smoke                                  # headless AI-vs-AI match, prints the result
FC_AUTOSTART=1 ./field-command              # skip the menu (0 easy, 1 normal, 2 hard)
FC_HEADLESS=1 FC_AUTOPLAY=1 FC_SNAPSHOT_DIR=/tmp/fc ./field-command   # screenshots + stats log
FC_MAP=riverlands FC_OPPONENTS=11 FC_AUTOSTART=1 ./field-command      # a specific map and opponent count
FC_MAP=four_corners FC_OPPONENTS=3 FC_TEAMS=2 FC_AUTOSTART=1 ./field-command   # a 2v2 with a computer ally
```
