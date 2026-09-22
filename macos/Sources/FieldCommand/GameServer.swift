import Foundation
import Compression

/// Native multiplayer server, protocol-compatible with the Linux edition's `net.py` server, so Linux and Mac
/// clients can join a game hosted on a Mac (or a dedicated `FieldCommand --server` process).
///
/// Threads: one accept thread, one reader thread per client, and one game thread that owns all lobby and world
/// state. Readers only enqueue messages; the game thread processes them at the start of each 30 Hz tick.
final class GameServer {
    static var hosted: GameServer?  // the server started by this app's "Host Game", if any

    let name: String
    private(set) var port: UInt16
    var simSpeed = 1
    var timeScale = 1.0  // game-speed multiplier (single player only)
    /// Single-player mode: bound to the loopback interface only, not announced on the LAN, and pausable.
    private(set) var localOnly = false
    var log: (String) -> Void = { print("[server] \($0)") }

    private final class Slot {
        let index: Int
        var kind = "open"  // open | human | ai | closed
        var name = ""
        var team: Int
        var ready = false
        var client: Client?
        init(_ i: Int) { index = i; team = i + 1 }
        var json: [String: Any] { ["slot": index, "kind": kind, "name": name, "team": team, "ready": ready] }
    }

    private final class Client {
        let fd: Int32
        let id: Int
        var slot: Int?
        var name = "Player"
        var alive = true
        init(fd: Int32, id: Int) { self.fd = fd; self.id = id }
    }

    private var listenFD: Int32 = -1
    private var slots = (0..<maxPlayers).map { Slot($0) }
    private var clients: [Client] = []
    private var host: Client?
    private var state = "lobby"
    private var difficulty = 1
    private var mapId = "auto"
    private var paused = false
    private var world: SWorld?
    /// A loaded game to start from instead of a fresh one.
    private var restoredWorld: SWorld?
    /// The live simulation, for the automated tests in Debug.swift.
    var simulation: SWorld? { world }
    /// Each slot's alliance, for the automated tests in Debug.swift.
    var slotTeams: [Int] { slots.map { $0.team } }
    private var pending: [(Int, [Any])] = []
    private var tick = 0
    private var running = false
    private var nextClientId = 1
    private let inboxLock = NSLock()
    private var inbox: [(Client, [String: Any])] = []
    private var announceFD: Int32 = -1

    init(name: String, port: UInt16 = NetProtocol.gamePort) {
        self.name = name
        self.port = port
        slots[1].kind = "ai"
        slots[1].name = "Computer 2"
    }

    /// A private server for a single-player skirmish: slot 0 is the local player, followed by `opponents`
    /// computer players on their own teams. Listens on an ephemeral loopback port (see `port` after `start`).
    /// A private server that resumes a saved single-player game.
    static func singlePlayer(restoring w: SWorld) -> GameServer {
        let s = GameServer(name: "Skirmish", port: 0)
        s.localOnly = true
        s.difficulty = w.difficulty.rawValue
        s.mapId = jStr(w.map["id"])
        s.restoredWorld = w
        for slot in s.slots {
            if let p = w.players[slot.index] {
                slot.kind = slot.index == 0 ? "open" : "ai"
                slot.name = p.name
                slot.team = p.team
            } else {
                slot.kind = "closed"
            }
        }
        return s
    }

    static func singlePlayer(opponents: Int, difficulty: Int, mapId: String, teams: Int = 0) -> GameServer {
        let s = GameServer(name: "Skirmish", port: 0)
        s.localOnly = true
        s.difficulty = difficulty
        s.mapId = mapId
        for slot in s.slots {
            slot.team = teamOf(slot: slot.index, teams: teams)
            if slot.index == 0 { slot.kind = "open" } else if slot.index <= opponents {
                slot.kind = "ai"
                slot.name = opponents > 1 ? "Computer \(slot.index)" : "Computer"
            } else {
                slot.kind = "closed"
            }
        }
        return s
    }

    // MARK: Lifecycle

    /// Binds the port and starts the server threads. Throws if the port is unavailable.
    func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw serverError("socket() failed") }
        var one: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: localOnly ? inet_addr("127.0.0.1") : INADDR_ANY)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0, listen(listenFD, 16) == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(listenFD)
            throw serverError("Could not listen on port \(port): \(msg)")
        }
        if port == 0 {
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listenFD, $0, &len) }
            }
            port = UInt16(bigEndian: bound.sin_port)
        }
        if !localOnly {
            announceFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            setsockopt(announceFD, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        running = true
        Thread { [weak self] in self?.acceptLoop() }.start()
        let game = Thread { [weak self] in self?.gameLoop() }
        game.name = "fc-server"
        game.start()
        log("Field Command server '\(name)' listening on port \(port)")
    }

    func stop() {
        guard running else { return }
        running = false
        shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        for c in clients { closeClient(c) }
        if announceFD >= 0 { Darwin.close(announceFD) }
    }

    private func serverError(_ s: String) -> NSError { NSError(domain: "server", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

    // MARK: Networking threads

    private func acceptLoop() {
        while running {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                if !running { return }
                continue
            }
            var one: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            inboxLock.lock()
            let c = Client(fd: fd, id: nextClientId)
            nextClientId += 1
            inbox.append((c, ["t": "_connect"]))
            inboxLock.unlock()
            Thread { [weak self] in self?.readLoop(c) }.start()
        }
    }

    private func recvExact(_ fd: Int32, _ n: Int) -> Data? {
        var buf = Data(count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, n - got, 0) }
            if r <= 0 { return nil }
            got += r
        }
        return buf
    }

    private func readLoop(_ c: Client) {
        while running {
            guard let h = recvExact(c.fd, 4) else { break }
            let header = h.withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
            let n = Int(header & 0x7FFF_FFFF)
            guard n < 4_000_000, var payload = recvExact(c.fd, n) else { break }
            if header & 0x8000_0000 != 0 {
                guard let raw = NetProtocol.inflate(payload) else { break }
                payload = raw
            }
            if let m = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                inboxLock.lock()
                inbox.append((c, m))
                inboxLock.unlock()
            }
        }
        inboxLock.lock()
        inbox.append((c, ["t": "_disconnect"]))
        inboxLock.unlock()
    }

    private func send(_ c: Client, _ msg: [String: Any]) {
        guard c.alive, let body = try? JSONSerialization.data(withJSONObject: msg) else { return }
        var payload = body
        var header = UInt32(body.count)
        if body.count > 512, let z = deflate(body) {
            payload = z
            header = UInt32(z.count) | 0x8000_0000
        }
        var be = header.bigEndian
        var frame = Data(bytes: &be, count: 4)
        frame.append(payload)
        let ok = frame.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < frame.count {
                let r = Darwin.send(c.fd, buf.baseAddress! + off, frame.count - off, 0)
                if r <= 0 { return false }
                off += r
            }
            return true
        }
        if !ok { closeClient(c) }
    }

    private func deflate(_ data: Data) -> Data? {
        var out = Data(count: data.count + 1024)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, data.count + 1024,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        out.count = n
        return out
    }

    private func closeClient(_ c: Client) {
        guard c.alive else { return }
        c.alive = false
        shutdown(c.fd, SHUT_RDWR)
        Darwin.close(c.fd)
    }

    private func sendAll(_ msg: [String: Any]) { for c in clients { send(c, msg) } }

    // MARK: Game thread

    private func gameLoop() {
        let dt = 1.0 / 30
        var next = ProcessInfo.processInfo.systemUptime
        var lastAnnounce = 0.0
        while running {
            next += dt
            inboxLock.lock()
            let batch = inbox
            inbox.removeAll()
            inboxLock.unlock()
            for (c, m) in batch { handle(c, m) }
            if state == "game", world != nil, !paused { gameTick(dt) }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastAnnounce > 1 {
                lastAnnounce = now
                announce()
            }
            let delay = next - ProcessInfo.processInfo.systemUptime
            if delay < -0.5 { next = ProcessInfo.processInfo.systemUptime }
            if delay > 0 { usleep(useconds_t(delay * 1_000_000)) }
        }
    }

    private func announce() {
        guard announceFD >= 0 else { return }
        let info: [String: Any] = ["fc": NetProtocol.version, "name": name, "port": Int(port),
                                   "players": slots.filter { $0.kind == "human" }.count,
                                   "open": slots.filter { $0.kind == "open" }.count, "state": state]
        guard let data = try? JSONSerialization.data(withJSONObject: info) else { return }
        for ip in ["255.255.255.255", "127.0.0.1"] {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = NetProtocol.discoveryPort.bigEndian
            addr.sin_addr.s_addr = inet_addr(ip)
            _ = data.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(announceFD, buf.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private func broadcastLobby() {
        let meta = SMapGen.info(mapId)
        var msg: [String: Any] = ["t": "lobby", "slots": slots.map { $0.json }, "difficulty": difficulty, "state": state, "name": name,
                                  "map": mapId, "map_name": meta?.name ?? "Auto (by player count)", "map_players": meta?.players ?? maxPlayers]
        msg["host_slot"] = host?.slot ?? NSNull()
        sendAll(msg)
    }

    private func handle(_ c: Client, _ m: [String: Any]) {
        let t = jStr(m["t"])
        switch t {
        case "_connect":
            clients.append(c)
            return
        case "_disconnect":
            disconnect(c)
            return
        case "hello":
            guard jInt(m["version"]) == NetProtocol.version else {
                send(c, ["t": "error", "text": "Version mismatch (server \(NetProtocol.version), client \(jInt(m["version"])))"])
                return
            }
            guard state == "lobby" else {
                send(c, ["t": "error", "text": "A game is already in progress"])
                return
            }
            guard let free = slots.first(where: { $0.kind == "open" }) ?? slots.first(where: { $0.kind == "ai" }) else {
                send(c, ["t": "error", "text": "The game is full"])
                return
            }
            c.name = String(jStr(m["name"]).prefix(20))
            if c.name.isEmpty { c.name = "Player" }
            free.kind = "human"
            free.name = c.name
            free.client = c
            free.ready = false
            c.slot = free.index
            if host == nil { host = c }
            send(c, ["t": "welcome", "slot": free.index, "host": c === host, "server": name])
            log("\(c.name) (\(jStr(m["client"]))) joined slot \(free.index + 1)")
            broadcastLobby()
            return
        default:
            break
        }
        guard let slot = c.slot else { return }
        if t == "cmd" && state == "game" {
            pending.append((slot, jArr(m["c"])))
            return
        }
        if t == "pause" && localOnly {
            // Only private single-player servers can be paused; nobody else is waiting on the clock.
            paused = (m["paused"] as? Bool) ?? false
            return
        }
        if t == "chat" {
            let text = String(jStr(m["text"]).prefix(200))
            if let w = world { w.emit(["chat", slot, text]) } else { sendAll(["t": "chat", "slot": slot, "name": c.name, "text": text]) }
            return
        }
        guard state == "lobby" else { return }
        let isHost = c === host
        switch t {
        case "ready":
            slots[slot].ready = (m["ready"] as? Bool) ?? false
            broadcastLobby()
        case "slot":
            let i = jInt(m["slot"])
            guard (0..<maxPlayers).contains(i) else { return }
            let s = slots[i]
            if m["team"] != nil, isHost || i == slot, (1...maxPlayers).contains(jInt(m["team"])) { s.team = jInt(m["team"]) }
            if let kind = m["kind"] as? String, isHost, s.kind != "human", ["open", "ai", "closed"].contains(kind) {
                s.kind = kind
                s.name = kind == "ai" ? "Computer \(i + 1)" : ""
            }
            broadcastLobby()
        case "difficulty" where isHost:
            difficulty = jInt(m["index"]) % 3
            broadcastLobby()
        case "map" where isHost:
            let id = jStr(m["id"])
            if id == "auto" || SMapGen.info(id) != nil {
                mapId = id
                broadcastLobby()
            }
        case "preset" where isHost:
            // "ffa" gives everyone their own team; otherwise the slots are dealt round-robin into `count` teams.
            let count = jStr(m["mode"]) == "ffa" ? maxPlayers : max(2, min(maxPlayers, m["count"].map { jInt($0) } ?? 2))
            for s in slots { s.team = s.index % count + 1 }
            broadcastLobby()
        case "start" where isHost:
            if let why = cannotStart() { send(c, ["t": "error", "text": why]) } else { startGame() }
        default:
            break
        }
    }

    private func disconnect(_ c: Client) {
        closeClient(c)
        clients.removeAll { $0 === c }
        if let s = c.slot.map({ slots[$0] }) {
            if state == "lobby" {
                s.kind = "open"
                s.name = ""
                s.client = nil
                s.ready = false
            } else {
                s.client = nil
                world?.emit(["chat", -1, "\(s.name) left the game"])
            }
        }
        if c === host { host = clients.first { $0.slot != nil } }
        if !clients.contains(where: { $0.slot != nil }) && state != "lobby" {
            log("All players left; returning to lobby")
            resetLobby()
        }
        broadcastLobby()
    }

    private func resetLobby() {
        state = "lobby"
        world = nil
        paused = false
        for s in slots {
            if s.kind == "human" && s.client == nil {
                s.kind = "open"
                s.name = ""
            }
            s.ready = false
        }
    }

    private func cannotStart() -> String? {
        let active = slots.filter { $0.kind == "human" || $0.kind == "ai" }
        if active.count < 2 { return "Need at least two players" }
        if Set(active.map { $0.team }).count < 2 { return "Everyone is on the same team" }
        if active.contains(where: { $0.kind == "human" && !$0.ready && $0.client !== host }) { return "Waiting for players to ready up" }
        if let meta = SMapGen.info(mapId), active.count > meta.players { return "\(meta.name) is for \(meta.players) players" }
        return nil
    }

    private func startGame() {
        let active = slots.filter { $0.kind == "human" || $0.kind == "ai" }
        let w: SWorld
        let map: [String: Any]
        let players: [SPlayer]
        if let restored = restoredWorld {
            w = restored
            map = restored.map
            players = restored.players.values.sorted { $0.slot < $1.slot }
            restoredWorld = nil
        } else {
            map = SMapGen.resolve(mapId, players: active.count)
            players = active.enumerated().map { i, s in
                SPlayer(slot: s.index, name: s.name.isEmpty ? "Computer \(s.index + 1)" : s.name, team: s.team, isAI: s.kind == "ai", start: i)
            }
            w = SWorld(map: map, players: players, difficulty: Difficulty(rawValue: difficulty) ?? .normal)
        }
        world = w
        pending = []
        state = "game"
        tick = 0
        let info = players.map { ["slot": $0.slot, "name": $0.name, "team": $0.team, "ai": $0.isAI] as [String: Any] }
        let crystals = w.crystals.map { [$0.id, $0.x, $0.y, $0.amount, $0.variant] as [Any] }
        for c in clients {
            guard let s = c.slot else { continue }
            var msg: [String: Any] = ["t": "start", "slot": s, "map": map, "players": info, "difficulty": difficulty, "crystals": crystals]
            // A resumed game: the client gets back the ground its side had explored.
            if w.elapsed > 0, let alliance = w.players[s]?.team, let g = w.fog[alliance] { msg["explored"] = SaveGame.bitsOut(g.explored) }
            send(c, msg)
        }
        log("Game started: \(active.count) players on \(jStr(map["name"]))")
    }

    private func gameTick(_ dt: Double) {
        guard let w = world else { return }
        for (slot, cmd) in pending { w.apply(slot, cmd) }
        pending = []
        for _ in 0..<simSpeed where !w.gameOver { w.step(dt * timeScale) }
        tick += 1
        if tick % 3 == 0 || w.gameOver {
            let events = w.events
            w.events = []
            for c in clients {
                if let s = c.slot, w.players[s] != nil { send(c, snapshot(w, s, events)) }
            }
        }
        if w.gameOver {
            var stats: [String: Any] = [:]
            for (s, p) in w.players {
                stats[String(s)] = ["name": p.name, "team": p.team, "trained": w.unitsTrained[s] ?? 0, "lost": w.unitsLost[s] ?? 0,
                                    "mined": w.crystalsMined[s] ?? 0, "alive": p.alive]
            }
            var end: [String: Any] = ["t": "end", "stats": stats]
            end["winner_team"] = w.winnerTeam ?? NSNull()
            sendAll(end)
            log("Game over; winning team \(w.winnerTeam.map(String.init) ?? "none")")
            resetLobby()
            broadcastLobby()
        }
    }

    // MARK: Snapshots

    private func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private func deg(_ a: Double) -> Int { ((Int(a * 180 / .pi) % 360) + 360) % 360 }

    private func visible(_ w: SWorld, _ slot: Int, _ e: [Any]) -> Bool {
        guard let kind = e.first as? String else { return false }
        func num(_ i: Int) -> Double { i < e.count ? Double(jNum(e[i])) : 0 }
        switch kind {
        case "msg", "alert", "income", "built", "wave", "trained", "upgraded", "rank", "kit": return jInt(e[1]) == slot
        case "elim", "gameover", "chat", "bridge", "tower": return true
        case "ping": return w.allied(jInt(e[1]), slot)        // an alert point is for the whole alliance
        case "recoil", "pulse":
            guard let ent = w.byId[jInt(e[1])] as? SEntity else { return false }
            return w.sees(slot, ent)
        case "bdead":
            let owner = jInt(e[1])
            return owner == slot || w.allied(owner, slot) || w.fogFor(slot).isVisible(num(3), num(4))
        case "sound": return w.fogFor(slot).isVisible(num(2), num(3))
        case "tracer", "shell": return w.fogFor(slot).isVisible(num(1), num(2)) || w.fogFor(slot).isVisible(num(3), num(4))
        case "muzzle", "sparks", "smoke", "explode", "flash", "wreck", "rubble", "shake": return w.fogFor(slot).isVisible(num(1), num(2))
        default: return false
        }
    }

    private func snapshot(_ w: SWorld, _ slot: Int, _ events: [[Any]]) -> [String: Any] {
        var units: [[Any]] = [], orders: [String: Any] = [:], buildings: [[Any]] = []
        for u in w.units where !u.dead && w.sees(slot, u) {
            units.append([u.id, u.team, NetProtocol.unitKinds.firstIndex(of: u.kind) ?? 0, r1(u.x), r1(u.y), deg(u.angle), deg(u.gunAngle),
                          Int(u.hp.rounded(.up)), u.carrying, u.mode.rawValue, u.rank])
            if u.team == slot {
                var pts: [Any] = []
                for o in [u.order] + u.queued {
                    switch o {
                    case .move(let x, let y): pts += [1, r1(x), r1(y)]
                    case .amove(let x, let y): pts += [2, r1(x), r1(y)]
                    case .attack(let t) where !t.dead: pts += [3, r1(t.x), r1(t.y)]
                    case .gather(let c) where !c.dead: pts += [4, r1(c.x), r1(c.y)]
                    case .build(_, let x, let y): pts += [6, r1(x), r1(y)]
                    case .rebuild(let b): pts += [6, r1(b.x), r1(b.y)]
                    case .repair(let b): if !b.dead { pts += [6, r1(b.x), r1(b.y)] }
                    default: break
                    }
                }
                orders[String(u.id)] = [u.order.code, u.queued.count, pts]
            }
        }
        for b in w.buildings where !b.dead && w.sees(slot, b) {
            let own = b.team == slot
            var rally: Any = 0
            if own, let r = b.rally { rally = [r1(r.0), r1(r.1)] }
            // [] when nothing is being researched: falsy in Python, an empty jArr in Swift.
            var upgradeInProgress: [Any] = []
            if own, let k = b.upgrading { upgradeInProgress = [k.rawValue, Int(b.upgradeProgress * 100)] }
            buildings.append([b.id, b.team, NetProtocol.buildingKinds.firstIndex(of: b.kind) ?? 0, r1(b.x), r1(b.y), Int(b.hp.rounded(.up)),
                              b.built ? 1 : 0, Int(b.progress * 100), own ? Int(b.queueProgress * 100) : 0, deg(b.gunAngle),
                              own ? b.queue.map { NetProtocol.unitKinds.firstIndex(of: $0) ?? 0 } : [], rally,
                              b.upgrades.reduce(0) { $0 | (1 << $1.rawValue) }, upgradeInProgress])
        }
        var alive: [String: Any] = [:]
        for (s, p) in w.players { alive[String(s)] = p.alive ? 1 : 0 }
        let packed: [[Any]] = events.filter { visible(w, slot, $0) }.map { e in e.map { v in (v as? Double).map { r1($0) } ?? v } }
        return ["t": "snap", "time": (w.elapsed * 100).rounded() / 100, "res": Int(w.resources[slot] ?? 0),
                "sup": [w.supplyUsed(slot), w.supplyCap(slot)], "u": units, "o": orders, "b": buildings,
                "br": w.bridges.map { [$0.id, $0.intact ? 1 : 0, Int($0.hp.rounded(.up)), Int($0.progress * 100)] },
                "kit": w.playerKits[slot].map { owned in kitIds.enumerated().reduce(0) { owned.contains($1.element) ? $0 | (1 << $1.offset) : $0 } } ?? 0,
                "tw": w.towers.map { [$0.id, r1($0.x), r1($0.y), $0.owner ?? -1, $0.capturing ?? -1, Int($0.progress * 100)] },
                "c": w.crystals.map { [$0.id, $0.amount] }, "p": alive, "e": packed]
    }
}
