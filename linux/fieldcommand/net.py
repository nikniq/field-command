"""Multiplayer networking: wire protocol, authoritative server, client connection and LAN discovery.

Wire format (TCP): each message is a 4-byte big-endian header followed by a payload. The low 31 bits of
the header are the payload length; the top bit marks a raw-DEFLATE compressed payload. Payloads are
UTF-8 JSON objects with a "t" (type) field.

Client -> server: hello{name, version, client} · slot{slot, kind?, team?} · ready{ready} · difficulty{index}
                  preset{mode} · map{id} · start · cmd{c} · chat{text} · leave
Server -> client: welcome{slot, host, server} · lobby{slots, difficulty, host_slot, map, map_name, map_players} · start{slot, map, players,
                  difficulty, crystals} · snap{...} · end{winner_team, stats} · chat{slot, name, text} · error{text}

LAN discovery: servers broadcast a small JSON datagram on UDP port DISCOVERY_PORT once a second.
"""
import asyncio
import json
import math
import queue
import socket
import struct
import threading
import time
import zlib

from . import mapgen
from .defs import HISTORY_STEP, BUILDING_KINDS, CRATE_KINDS, DIFFICULTIES, KIT_IDS, MAX_PLAYERS, UNIT_KINDS, UPGRADE_KINDS
from .entities import Building, Crystal, Unit
from .world import PlayerInfo, World

PROTOCOL_VERSION = 16
GAME_PORT = 47777
DISCOVERY_PORT = 47778
TICK_RATE = 30
SNAPSHOT_EVERY = 3  # ticks -> 10 snapshots per second
COMPRESS_OVER = 512
_FLAG = 0x80000000

UNIT_INDEX = {k: i for i, k in enumerate(UNIT_KINDS)}
CRATE_INDEX = {k: i for i, k in enumerate(CRATE_KINDS)}
UPGRADE_INDEX = {k: i for i, k in enumerate(UPGRADE_KINDS)}
BUILDING_INDEX = {k: i for i, k in enumerate(BUILDING_KINDS)}
STATUS = {"idle": 0, "move": 1, "amove": 2, "attack": 3, "gather": 4, "return": 5, "build": 6,
          "rebuild": 7, "repair": 8, "heal": 9}


# ---------------------------------------------------------------- framing

def encode(msg):
    data = json.dumps(msg, separators=(",", ":")).encode()
    if len(data) > COMPRESS_OVER:
        c = zlib.compressobj(6, zlib.DEFLATED, -15)
        z = c.compress(data) + c.flush()
        return struct.pack(">I", len(z) | _FLAG) + z
    return struct.pack(">I", len(data)) + data


def decode_payload(header, payload):
    if header & _FLAG:
        payload = zlib.decompress(payload, -15)
    return json.loads(payload.decode())


def _r(v, nd=1):
    return round(v, nd)


# ---------------------------------------------------------------- snapshots & event filtering

POSITIONAL = {"tracer", "muzzle", "sparks", "smoke", "explode", "flash", "shell", "wreck", "rubble", "shake", "sound"}
PRIVATE = {"msg", "alert", "income", "built", "wave", "trained", "upgraded", "rank", "kit"}
PUBLIC = {"elim", "gameover", "chat", "bridge", "tower"}


def event_visible(world, slot, ev):
    """Whether player `slot` should receive event `ev` (fog of war applies to effects too)."""
    kind = ev[0]
    if kind in PRIVATE:
        return ev[1] == slot
    if kind in PUBLIC:
        return True
    if kind == "ping":
        return world.allied(ev[1], slot)      # an alert point is for the whole alliance
    if kind == "crate":
        return world.allied(ev[1], slot) or world.fog_for(slot).is_visible(ev[2], ev[3])
    fog = world.fog_for(slot)
    if kind in ("recoil", "pulse"):
        e = world.by_id.get(ev[1])
        return e is not None and world.sees(slot, e)
    if kind == "bdead":
        return ev[1] == slot or world.allied(ev[1], slot) or fog.is_visible(ev[3], ev[4])
    if kind == "sound":
        return fog.is_visible(ev[2], ev[3])
    if kind in ("tracer", "shell"):
        return fog.is_visible(ev[1], ev[2]) or fog.is_visible(ev[3], ev[4])
    if kind in POSITIONAL:
        return fog.is_visible(ev[1], ev[2])
    return False


def _pack_event(ev):
    return [_r(v) if isinstance(v, float) else v for v in ev]


def order_points(u):
    """[(status_code, x, y), ...] for a unit's current + queued orders (for drawing order lines)."""
    pts = []
    for o in [u.order] + u.queued:
        k = o[0]
        if k in ("move", "amove"):
            pts.append((STATUS[k], o[1], o[2]))
        elif k in ("attack", "gather", "heal"):
            t = o[1]
            if not t.dead:
                pts.append((STATUS[k], t.x, t.y))
        elif k == "build":
            pts.append((STATUS[k], o[2], o[3]))
        elif k == "rebuild":
            pts.append((STATUS["build"], o[1].x, o[1].y))
        elif k == "repair":
            if not o[1].dead:
                pts.append((STATUS["build"], o[1].x, o[1].y))
    return pts


def snapshot_for(world, slot, events):
    units, orders, buildings = [], {}, []
    for u in world.units:
        if u.dead or not world.sees(slot, u):
            continue
        units.append([u.id, u.team, UNIT_INDEX[u.kind], _r(u.x), _r(u.y), int(math.degrees(u.angle)) % 360,
                      int(math.degrees(u.gun_angle)) % 360, int(math.ceil(u.hp)), u.carrying, u.mode, u.rank])
        if u.team == slot:
            pts = []
            for code, x, y in order_points(u):
                pts += [code, _r(x), _r(y)]
            orders[str(u.id)] = [STATUS[u.order[0]], len(u.queued), pts]
    for b in world.buildings:
        if b.dead or not world.sees(slot, b):
            continue
        own = b.team == slot
        buildings.append([b.id, b.team, BUILDING_INDEX[b.kind], _r(b.x), _r(b.y), int(math.ceil(b.hp)), int(b.built),
                          int(b.progress * 100), int(b.queue_progress * 100) if own else 0,
                          int(math.degrees(b.gun_angle)) % 360,
                          [UNIT_INDEX[k] for k in b.queue] if own else [],
                          [_r(b.rally[0]), _r(b.rally[1])] if (own and b.rally) else 0,
                          sum(1 << UPGRADE_INDEX[k] for k in b.upgrades),
                          [UPGRADE_INDEX[b.upgrading], int(b.upgrade_progress * 100)] if (own and b.upgrading) else 0,
                          int(b.shield)])
    return {"t": "snap", "time": _r(world.elapsed, 2), "res": int(world.resources[slot]),
            "sup": [world.supply_used(slot), world.supply_cap(slot)],
            "u": units, "o": orders, "b": buildings,
            "br": [[b.id, int(b.intact), int(math.ceil(b.hp)), int(b.progress * 100)] for b in world.bridges],
            "kit": sum(1 << i for i, k in enumerate(KIT_IDS) if k in world.kits.get(slot, ())),
            "ms": int(world.mission_progress()) if world.mission else 0,
            "hold": {str(t): round(v, 1) for t, v in world.hold.items()} if world.mode == "koth" else {},
            "rf": round(world.reinforce_left(slot), 1),
            "cr": [[c.id, _r(c.x), _r(c.y), CRATE_INDEX[c.kind], c.amount] for c in world.crates
                   if world.fog_for(slot).is_visible(c.x, c.y)],
            "tw": [[t.id, _r(t.x), _r(t.y), -1 if t.owner is None else t.owner,
                    -1 if t.capturing is None else t.capturing, int(t.progress * 100)] for t in world.towers],
            "c": [[c.id, c.amount] for c in world.crystals],
            "p": {str(s): int(p.alive) for s, p in world.players.items()},
            "e": [_pack_event(ev) for ev in events if event_visible(world, slot, ev)]}


def stats_of(world):
    return {str(s): {"name": p.name, "team": p.team, "trained": world.units_trained[s], "lost": world.units_lost[s],
                     "mined": world.crystals_mined[s], "alive": p.alive} for s, p in world.players.items()}


# ---------------------------------------------------------------- server

class _Slot:
    def __init__(self, index):
        self.index = index
        self.kind = "open"  # open | human | ai | closed
        self.name = ""
        self.team = index + 1
        self.ready = False
        self.client = None

    def to_json(self):
        return {"slot": self.index, "kind": self.kind, "name": self.name, "team": self.team, "ready": self.ready}


class _Client:
    _next = 1

    def __init__(self, reader, writer):
        self.id = _Client._next
        _Client._next += 1
        self.reader, self.writer = reader, writer
        self.slot = None
        self.name = "Player"
        self.client = "?"

    def send(self, msg):
        try:
            self.writer.write(encode(msg))
        except (ConnectionError, RuntimeError):
            pass


class Server:
    """Authoritative game server. Run `start()` for a background thread (in-game hosting) or
    `serve_forever()` for a dedicated process."""

    def __init__(self, name="Field Command", port=GAME_PORT, announce=True, log=print, sim_speed=1):
        self.name = name
        self.sim_speed = sim_speed  # simulation steps per tick (>1 only for automated tests)
        self.port = port
        self.announce = announce
        self.log = log
        self.slots = [_Slot(i) for i in range(MAX_PLAYERS)]
        self.slots[1].kind = "ai"
        self.slots[1].name = "Computer 2"
        self.difficulty = 1
        self.map_id = "auto"
        self.clients = []
        self.host = None
        self.state = "lobby"
        self.world = None
        self.pending = []
        self.loop = None
        self.thread = None
        self.ready_event = threading.Event()
        self.error = None
        self._stop = None

    # -- lifecycle

    def start(self):
        self.thread = threading.Thread(target=self._thread_main, name="fc-server", daemon=True)
        self.thread.start()
        self.ready_event.wait(5)
        if self.error:
            raise OSError(self.error)
        return self

    def _thread_main(self):
        try:
            asyncio.run(self._main())
        except Exception as e:  # noqa: BLE001 - surface bind errors to the caller
            self.error = str(e)
            self.ready_event.set()

    def serve_forever(self):
        try:
            asyncio.run(self._main())
        except KeyboardInterrupt:
            pass

    def stop(self):
        if self.loop and self._stop:
            self.loop.call_soon_threadsafe(self._stop.set)

    async def _main(self):
        self.loop = asyncio.get_running_loop()
        self._stop = asyncio.Event()
        server = await asyncio.start_server(self._on_client, host="0.0.0.0", port=self.port)
        self.log(f"Field Command server '{self.name}' listening on port {self.port}")
        self.ready_event.set()
        tasks = [asyncio.create_task(self._tick_loop())]
        if self.announce:
            tasks.append(asyncio.create_task(self._announce_loop()))
        async with server:
            await self._stop.wait()
        for t in tasks:
            t.cancel()
        for c in list(self.clients):
            c.writer.close()

    # -- connections

    async def _on_client(self, reader, writer):
        c = _Client(reader, writer)
        self.clients.append(c)
        try:
            while True:
                header = struct.unpack(">I", await reader.readexactly(4))[0]
                n = header & ~_FLAG
                if n > 4_000_000:
                    break
                msg = decode_payload(header, await reader.readexactly(n))
                self._on_message(c, msg)
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionError, ValueError, OSError):
            pass
        finally:
            self._disconnect(c)
            try:
                writer.close()
            except Exception:  # noqa: BLE001
                pass

    def _disconnect(self, c):
        if c in self.clients:
            self.clients.remove(c)
        if c.slot is not None:
            s = self.slots[c.slot]
            if self.state == "lobby":
                s.kind, s.name, s.client, s.ready = "open", "", None, False
            else:
                s.client = None
                if self.world and c.slot in self.world.players:
                    self.world.players[c.slot].connected = False
                    self.world.emit("chat", -1, f"{s.name} left the game")
        if c is self.host:
            self.host = next((x for x in self.clients if x.slot is not None), None)
        if not any(x.slot is not None for x in self.clients) and self.state != "lobby":
            self.log("All players left; returning to lobby")
            self._reset_lobby()
        self._broadcast_lobby()

    def _reset_lobby(self):
        self.state = "lobby"
        self.world = None
        for s in self.slots:
            if s.kind == "human" and s.client is None:
                s.kind, s.name = "open", ""
            s.ready = False

    def _send_all(self, msg):
        for c in self.clients:
            c.send(msg)

    def _broadcast_lobby(self):
        self._send_all({"t": "lobby", "slots": [s.to_json() for s in self.slots], "difficulty": self.difficulty,
                        "host_slot": self.host.slot if self.host else None, "state": self.state, "name": self.name,
                        "map": self.map_id, "map_name": self._map_meta()["name"], "map_players": self._map_meta()["players"]})

    def _map_meta(self):
        return mapgen.BY_ID.get(self.map_id, {"name": "Auto (by player count)", "players": MAX_PLAYERS})

    def _on_message(self, c, m):
        t = m.get("t")
        if t == "hello":
            if m.get("version") != PROTOCOL_VERSION:
                c.send({"t": "error", "text": f"Version mismatch (server {PROTOCOL_VERSION}, client {m.get('version')})"})
                return
            if self.state != "lobby":
                c.send({"t": "error", "text": "A game is already in progress"})
                return
            free = next((s for s in self.slots if s.kind == "open"), None)
            if free is None:
                free = next((s for s in self.slots if s.kind == "ai"), None)
            if free is None:
                c.send({"t": "error", "text": "The game is full"})
                return
            c.name = str(m.get("name") or "Player")[:20]
            c.client = str(m.get("client", "?"))
            free.kind, free.name, free.client, free.ready = "human", c.name, c, False
            c.slot = free.index
            if self.host is None:
                self.host = c
            c.send({"t": "welcome", "slot": c.slot, "host": c is self.host, "server": self.name})
            self.log(f"{c.name} ({c.client}) joined slot {c.slot + 1}")
            self._broadcast_lobby()
        elif c.slot is None:
            return
        elif t == "cmd" and self.state == "game":
            self.pending.append((c.slot, m.get("c")))
        elif t == "chat":
            text = str(m.get("text", ""))[:200]
            if self.world:
                self.world.emit("chat", c.slot, text)
            else:
                self._send_all({"t": "chat", "slot": c.slot, "name": c.name, "text": text})
        elif self.state != "lobby":
            return
        elif t == "ready":
            self.slots[c.slot].ready = bool(m.get("ready"))
            self._broadcast_lobby()
        elif t == "slot":
            i = m.get("slot")
            if not isinstance(i, int) or not 0 <= i < MAX_PLAYERS:
                return
            s = self.slots[i]
            is_host = c is self.host
            if "team" in m and (is_host or i == c.slot) and isinstance(m["team"], int) and 1 <= m["team"] <= MAX_PLAYERS:
                s.team = m["team"]
            if "kind" in m and is_host and s.kind != "human" and m["kind"] in ("open", "ai", "closed"):
                s.kind = m["kind"]
                s.name = f"Computer {s.index + 1}" if s.kind == "ai" else ""
            self._broadcast_lobby()
        elif t == "difficulty" and c is self.host:
            self.difficulty = int(m.get("index", 1)) % len(DIFFICULTIES)
            self._broadcast_lobby()
        elif t == "map" and c is self.host:
            mid = m.get("id")
            if mid == "auto" or mid in mapgen.BY_ID:
                self.map_id = mid
                self._broadcast_lobby()
        elif t == "preset" and c is self.host:
            # "ffa" gives everyone their own team; otherwise the slots are dealt round-robin into `count` teams.
            count = MAX_PLAYERS if m.get("mode") == "ffa" else max(2, min(MAX_PLAYERS, int(m.get("count", 2))))
            for s in self.slots:
                s.team = s.index % count + 1
            self._broadcast_lobby()
        elif t == "start" and c is self.host:
            ok, why = self.can_start()
            if not ok:
                c.send({"t": "error", "text": why})
            else:
                self._start_game()

    def can_start(self):
        active = [s for s in self.slots if s.kind in ("human", "ai")]
        if len(active) < 2:
            return False, "Need at least two players"
        if len({s.team for s in active}) < 2:
            return False, "Everyone is on the same team"
        if any(s.kind == "human" and not s.ready and s.client is not self.host for s in active):
            return False, "Waiting for players to ready up"
        if len(active) > self._map_meta()["players"]:
            return False, f"{self._map_meta()['name']} is for {self._map_meta()['players']} players"
        return True, ""

    def _start_game(self):
        active = [s for s in self.slots if s.kind in ("human", "ai")]
        spec = mapgen.resolve(self.map_id, len(active))
        players = [PlayerInfo(s.index, s.name or f"Computer {s.index + 1}", s.team, s.kind == "ai", start=i)
                   for i, s in enumerate(active)]
        self.world = World(spec, players, DIFFICULTIES[self.difficulty])
        self.pending = []
        self.state = "game"
        self._tick = 0
        info = [{"slot": p.slot, "name": p.name, "team": p.team, "ai": p.is_ai} for p in players]
        crystals = [[c.id, c.x, c.y, c.amount, c.variant] for c in self.world.crystals]
        for c in self.clients:
            if c.slot is not None:
                c.send({"t": "start", "slot": c.slot, "map": spec, "players": info, "difficulty": self.difficulty,
                        "crystals": crystals, "mode": w.mode, "start_crystal": w.start_crystal, "start_base": w.start_base})
        self.log(f"Game started: {len(active)} players on {spec['name']}")

    async def _tick_loop(self):
        dt = 1.0 / TICK_RATE
        nxt = time.perf_counter()
        while True:
            nxt += dt
            if self.state == "game" and self.world:
                self._game_tick(dt)
            delay = nxt - time.perf_counter()
            if delay < -0.5:
                nxt = time.perf_counter()
            await asyncio.sleep(max(0.0, delay))

    def _game_tick(self, dt):
        w = self.world
        for slot, cmd in self.pending:
            if isinstance(cmd, list):
                w.apply(slot, cmd)
        self.pending = []
        for _ in range(self.sim_speed):
            w.step(dt)
            if w.game_over:
                break
        self._tick += 1
        if self._tick % SNAPSHOT_EVERY == 0 or w.game_over:
            events = w.events
            w.events = []
            for c in self.clients:
                if c.slot is not None and c.slot in w.players:
                    c.send(snapshot_for(w, c.slot, events))
        if w.game_over:
            self._send_all({"t": "end", "winner_team": w.winner_team, "stats": stats_of(w),
                            "history": {str(s): h for s, h in w.history.items()}, "history_step": HISTORY_STEP})
            self.log(f"Game over; winning team {w.winner_team}")
            self.state = "over"
            self._reset_lobby()
            self._broadcast_lobby()

    async def _announce_loop(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.setblocking(False)
        try:
            while True:
                players = sum(1 for s in self.slots if s.kind == "human")
                open_ = sum(1 for s in self.slots if s.kind == "open")
                msg = json.dumps({"fc": PROTOCOL_VERSION, "name": self.name, "port": self.port, "players": players,
                                  "open": open_, "state": self.state}).encode()
                for addr in ("255.255.255.255", "127.0.0.1"):
                    try:
                        sock.sendto(msg, (addr, DISCOVERY_PORT))
                    except OSError:
                        pass
                await asyncio.sleep(1.0)
        finally:
            sock.close()


# ---------------------------------------------------------------- client side

class Connection:
    """Blocking TCP client with a background reader thread. Poll `messages()` from the game loop."""

    def __init__(self, host, port=GAME_PORT, timeout=5.0):
        self.addr = (host, port)
        self.sock = socket.create_connection(self.addr, timeout=timeout)
        self.sock.settimeout(None)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.inbox = queue.Queue()
        self.lock = threading.Lock()
        self.alive = True
        self.error = None
        threading.Thread(target=self._reader, name="fc-conn", daemon=True).start()

    def _recv_exact(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("Connection closed")
            buf += chunk
        return bytes(buf)

    def _reader(self):
        try:
            while True:
                header = struct.unpack(">I", self._recv_exact(4))[0]
                self.inbox.put(decode_payload(header, self._recv_exact(header & ~_FLAG)))
        except (OSError, ConnectionError, ValueError) as e:
            self.error = str(e)
        finally:
            self.alive = False
            self.inbox.put({"t": "disconnected", "text": self.error or "Disconnected"})

    def send(self, msg):
        if not self.alive:
            return
        try:
            with self.lock:
                self.sock.sendall(encode(msg))
        except OSError as e:
            self.error = str(e)
            self.alive = False

    def messages(self):
        out = []
        while True:
            try:
                out.append(self.inbox.get_nowait())
            except queue.Empty:
                return out

    def close(self):
        self.alive = False
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


class LanBrowser:
    """Listens for server announcements on the local network."""

    def __init__(self):
        self.games = {}
        self.running = True
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if hasattr(socket, "SO_REUSEPORT"):
            try:
                self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            except OSError:
                pass
        try:
            self.sock.bind(("", DISCOVERY_PORT))
            self.sock.settimeout(0.5)
            threading.Thread(target=self._listen, name="fc-lan", daemon=True).start()
        except OSError:
            self.running = False

    def _listen(self):
        while self.running:
            try:
                data, (ip, _port) = self.sock.recvfrom(2048)
                info = json.loads(data.decode())
                if info.get("fc") == PROTOCOL_VERSION:
                    key = (ip, int(info.get("port", GAME_PORT)))
                    info["ip"], info["seen"] = ip, time.time()
                    # Prefer a real LAN address over loopback for the same server.
                    if ip == "127.0.0.1" and any(k[1] == key[1] and k[0] != ip for k in self.games):
                        continue
                    self.games[key] = info
            except socket.timeout:
                pass
            except (OSError, ValueError):
                pass

    def list(self):
        now = time.time()
        fresh = [g for g in self.games.values() if now - g["seen"] < 3.5]
        return sorted(fresh, key=lambda g: (g["ip"] == "127.0.0.1", g["name"]))

    def close(self):
        self.running = False
        try:
            self.sock.close()
        except OSError:
            pass


def local_ip():
    """Best guess at this machine's LAN address (for telling other players where to connect)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()
