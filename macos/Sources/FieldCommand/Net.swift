import Foundation
import Compression

/// Multiplayer client for the Field Command server (the Linux edition's `fieldcommand/net.py`).
///
/// Wire format (TCP): 4-byte big-endian header, low 31 bits = payload length, top bit = raw-DEFLATE compressed.
/// Payload: UTF-8 JSON object with a "t" (type) field. The server is authoritative; this client sends commands and
/// mirrors snapshots.
enum NetProtocol {
    static let version = 14     // … 12 unbuild, history; 13 Barricades; 14 Gunships
    static let gamePort: UInt16 = 47777
    static let discoveryPort: UInt16 = 47778
    /// Order matters: a kind travels as its index here, so new kinds are appended at the end and
    /// `defs.UNIT_KINDS` / `defs.BUILDING_KINDS` in the Python edition must match exactly.
    static let unitKinds: [UnitKind] = [.worker, .marine, .tank, .sniper, .medic, .gunship]
    static let buildingKinds: [BuildingKind] = [.hq, .depot, .barracks, .factory, .turret, .radar, .artillery, .shield, .wall]

    static func name(_ k: BuildingKind) -> String {
        switch k {
        case .hq: return "hq"
        case .depot: return "depot"
        case .barracks: return "barracks"
        case .factory: return "factory"
        case .turret: return "turret"
        case .radar: return "radar"
        case .artillery: return "artillery"
        case .shield: return "shield"
        case .wall: return "wall"
        }
    }

    static func name(_ k: UnitKind) -> String {
        switch k {
        case .worker: return "worker"
        case .marine: return "marine"
        case .tank: return "tank"
        case .sniper: return "sniper"
        case .medic: return "medic"
        case .gunship: return "gunship"
        }
    }

    static func buildingKind(_ s: String) -> BuildingKind? { buildingKinds.first { name($0) == s } }

    static func encode(_ msg: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: msg) else { return nil }
        var header = UInt32(body.count).bigEndian
        var out = Data(bytes: &header, count: 4)
        out.append(body)
        return out
    }

    static func inflate(_ data: Data) -> Data? {
        var capacity = max(4096, data.count * 8)
        for _ in 0..<6 {
            var out = Data(count: capacity)
            let n = out.withUnsafeMutableBytes { dst -> Int in
                data.withUnsafeBytes { src -> Int in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 && n < capacity {
                out.count = n
                return out
            }
            capacity *= 4
        }
        return nil
    }
}

// MARK: - JSON helpers

func jInt(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
func jNum(_ v: Any?) -> CGFloat { CGFloat((v as? NSNumber)?.doubleValue ?? 0) }
func jArr(_ v: Any?) -> [Any] { v as? [Any] ?? [] }
func jDict(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }
func jStr(_ v: Any?) -> String { v as? String ?? "" }

// MARK: - Connection

/// Blocking TCP connection with a background reader thread. Poll `messages()` from the game loop.
final class NetConnection {
    private var fd: Int32 = -1
    private let lock = NSLock()
    private let sendLock = NSLock()
    private var inbox: [[String: Any]] = []
    private(set) var alive = false
    private(set) var error: String?
    let host: String
    let port: UInt16

    init(host: String, port: UInt16 = NetProtocol.gamePort) throws {
        self.host = host
        self.port = port
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else {
            throw NSError(domain: "net", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown host \(host)"])
        }
        defer { freeaddrinfo(res) }
        fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { throw NSError(domain: "net", code: 2, userInfo: [NSLocalizedDescriptionKey: "socket() failed"]) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) != 0 {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd)
            throw NSError(domain: "net", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not connect to \(host):\(port) — \(msg)"])
        }
        alive = true
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "fc-net"
        t.start()
    }

    private func recvExact(_ n: Int) -> Data? {
        var buf = Data(count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, n - got, 0) }
            if r <= 0 { return nil }
            got += r
        }
        return buf
    }

    private func readLoop() {
        while true {
            guard let h = recvExact(4) else { break }
            let header = h.withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
            let n = Int(header & 0x7FFF_FFFF)
            guard n < 16_000_000, var payload = recvExact(n) else { break }
            if header & 0x8000_0000 != 0 {
                guard let raw = NetProtocol.inflate(payload) else { break }
                payload = raw
            }
            if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                lock.lock()
                inbox.append(obj)
                lock.unlock()
            }
        }
        alive = false
        lock.lock()
        inbox.append(["t": "disconnected", "text": error ?? "Connection closed"])
        lock.unlock()
    }

    func send(_ msg: [String: Any]) {
        guard alive, let data = NetProtocol.encode(msg) else { return }
        sendLock.lock()
        defer { sendLock.unlock() }
        data.withUnsafeBytes { buf in
            var off = 0
            while off < data.count {
                let r = Darwin.send(fd, buf.baseAddress! + off, data.count - off, 0)
                if r <= 0 {
                    error = String(cString: strerror(errno))
                    alive = false
                    return
                }
                off += r
            }
        }
    }

    func messages() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        let out = inbox
        inbox.removeAll()
        return out
    }

    func close() {
        guard fd >= 0 else { return }
        alive = false
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        fd = -1
    }
}

// MARK: - LAN discovery

struct LanGame {
    let name: String
    let ip: String
    let port: Int
    let players: Int
    let open: Int
    let state: String
    var seen: Date
    var joinable: Bool { state == "lobby" && open > 0 }
}

/// Listens for server announcements broadcast on the local network.
final class LanBrowser {
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var games: [String: LanGame] = [:]
    private(set) var running = false

    init() {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = NetProtocol.discoveryPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else {
            Darwin.close(fd)
            fd = -1
            return
        }
        running = true
        Thread { [weak self] in self?.listen() }.start()
    }

    private func listen() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while running {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let data = Data(buf[0..<n])
            guard let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  jInt(info["fc"]) == NetProtocol.version else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            let port = jInt(info["port"])
            let key = "\(ip):\(port)"
            lock.lock()
            if ip == "127.0.0.1" && games.values.contains(where: { $0.port == port && $0.ip != ip }) {
                lock.unlock()
                continue
            }
            games[key] = LanGame(name: jStr(info["name"]), ip: ip, port: port, players: jInt(info["players"]),
                                 open: jInt(info["open"]), state: jStr(info["state"]), seen: Date())
            lock.unlock()
        }
    }

    func list() -> [LanGame] {
        lock.lock()
        defer { lock.unlock() }
        return games.values.filter { Date().timeIntervalSince($0.seen) < 3.5 }
            .sorted { ($0.ip == "127.0.0.1" ? 1 : 0, $0.name) < ($1.ip == "127.0.0.1" ? 1 : 0, $1.name) }
    }

    func close() {
        running = false
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

// MARK: - Session state

struct NetPlayer {
    let slot: Int
    let name: String
    let team: Int
    let isAI: Bool
    var alive = true
}

/// The client's view of a server-hosted game: players, map, and the latest snapshot bookkeeping.
final class NetSession {
    let conn: NetConnection
    let slot: Int
    let map: [String: Any]
    let difficulty: Difficulty
    var players: [Int: NetPlayer] = [:]
    var resources = startCrystal
    /// Base64 fog bits from a resumed game, applied once the scene's fog exists.
    let explored: String?
    /// The campaign mission this game is, if any, and the seconds run up toward its timed objective.
    let mission: Mission?
    /// Watching a replay: the server feeds the commands, and input here is ignored.
    let spectating: Bool
    var missionProgress = 0
    /// Kit bought from the Armory this match.
    var kits: Set<String> = []
    var supplyUsed = 0
    var supplyCap = 10
    var serverTime: CGFloat = 0
    var snapTime: TimeInterval?
    var interval: TimeInterval = 0.1
    var winnerTeam: Int?
    var finalStats: [String: Any]?
    /// (seconds per sample, army size per slot) for the end screen's timeline.
    var finalHistory: (step: Double, series: [Int: [Int]])?
    var lobbyMessage: [String: Any]?
    var disconnected: String?
    let startCrystals: [[Any]]
    var units: [Int: Unit] = [:]
    var buildings: [Int: Building] = [:]
    var crystals: [Int: Crystal] = [:]
    var shells: [NetShell] = []
    var cameraPending = true
    /// Set for a single-player skirmish against a private local server.
    var skirmish: (mapId: String, opponents: Int, teams: Int)?
    var isLocal: Bool { skirmish != nil }
    var sentPause = false

    init(conn: NetConnection, start: [String: Any]) {
        self.conn = conn
        slot = jInt(start["slot"])
        map = jDict(start["map"])
        explored = start["explored"] as? String
        mission = missionNamed(start["mission"] as? String)
        spectating = jInt(start["replay"]) == 1
        difficulty = Difficulty(rawValue: jInt(start["difficulty"])) ?? .normal
        for p in jArr(start["players"]) {
            let d = jDict(p)
            let s = jInt(d["slot"])
            players[s] = NetPlayer(slot: s, name: jStr(d["name"]), team: jInt(d["team"]), isAI: (d["ai"] as? Bool) ?? false)
        }
        startCrystals = jArr(start["crystals"]).map { jArr($0) }
    }

    var myAlliance: Int { players[slot]?.team ?? 0 }

    func send(_ cmd: [Any]) { conn.send(["t": "cmd", "c": cmd]) }
    func chat(_ text: String) { conn.send(["t": "chat", "text": text]) }

    func applyTeams() {
        Team.local = Team(rawValue: slot)
        Team.alliances = Dictionary(uniqueKeysWithValues: players.map { ($0.key, $0.value.team) })
    }
}
