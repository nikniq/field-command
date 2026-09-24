import Foundation

/// A recorded game: its seed, its setup and every command people sent, by tick — the same JSON document the
/// Linux edition's replay.py writes. Fed back into a fresh simulation it gives exactly the same game.
final class Replay {
    static let format = 1
    static let keep = 40          // the newest this many are kept; older ones are pruned as new games are recorded
    let map: String
    let players: [(slot: Int, name: String, team: Int, ai: Bool)]
    let difficulty: Int
    let seed: UInt64
    let mission: String?
    let viewer: Int
    let commands: [(Int, Int, [Any])]
    let elapsed: Double
    let label: String
    var next = 0

    struct Unreadable: Error, CustomStringConvertible { let description: String }

    init(_ d: [String: Any]) throws {
        guard jStr(d["game"]) == "field-command", jInt(d["format"]) == Replay.format else {
            throw Unreadable(description: "not a Field Command replay this version can read")
        }
        map = jStr(d["map"])
        players = jArr(d["players"]).map { jDict($0) }.map { (jInt($0["slot"]), jStr($0["name"]), jInt($0["team"]), SaveGame.jBoolean($0["ai"])) }
        difficulty = jInt(d["difficulty"])
        seed = UInt64(max(1, jInt(d["seed"])))
        mission = d["mission"] as? String
        viewer = jInt(d["viewer"])
        commands = jArr(d["commands"]).map { jArr($0) }.compactMap { $0.count >= 3 ? (jInt($0[0]), jInt($0[1]), jArr($0[2])) : nil }
        elapsed = Double(jNum(d["elapsed"]))
        label = jStr(d["label"])
    }

    static var replaysDir: URL { SaveGame.savesDir.deletingLastPathComponent().appendingPathComponent("replays") }
    static func path(_ name: String) -> URL { replaysDir.appendingPathComponent("\(name).json") }

    static func encode(_ w: SWorld, viewer: Int, label: String = "") -> [String: Any] {
        ["game": "field-command", "format": format, "version": appVersion, "label": label,
         "saved_at": Int(Date().timeIntervalSince1970), "map": jStr(w.map["id"]), "difficulty": w.difficulty.rawValue,
         "seed": Int(w.seed), "mission": w.mission.map { $0.id as Any } ?? NSNull(), "viewer": viewer,
         "players": w.players.values.sorted { $0.slot < $1.slot }.map {
             ["slot": $0.slot, "name": $0.name, "team": $0.team, "ai": $0.isAI] as [String: Any] },
         "elapsed": w.elapsed, "ticks": w.tick, "winner_team": w.winnerTeam.map { $0 as Any } ?? NSNull(),
         "commands": w.record.map { [$0.0, $0.1, $0.2] as [Any] }]
    }

    /// A file name for a game: the date and time it was recorded and the map, so the browser reads well.
    static func name(for w: SWorld, at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date) + "_" + jStr(w.map["id"])
    }

    @discardableResult
    static func write(_ w: SWorld, name: String? = nil, viewer: Int = 0, label: String = "") throws -> URL {
        try FileManager.default.createDirectory(at: replaysDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: encode(w, viewer: viewer, label: label))
        let url = path(name ?? Replay.name(for: w))
        try data.write(to: url, options: .atomic)
        prune()
        return url
    }

    /// Drops the oldest recordings beyond `keep`.
    static func prune(keep: Int = Replay.keep) {
        for r in list().dropFirst(keep) { try? FileManager.default.removeItem(at: path(r.name)) }
    }

    /// "Won", "Lost" or "Unfinished" from the viewer's side of a recorded game.
    static func result(of d: [String: Any]) -> String {
        guard let winner = d["winner_team"] as? NSNumber else { return "Unfinished" }
        let viewer = jInt(d["viewer"])
        let mine = jArr(d["players"]).map { jDict($0) }.first { jInt($0["slot"]) == viewer }.map { jInt($0["team"]) }
        return mine == winner.intValue ? "Won" : "Lost"
    }

    static func read(_ name: String = "last") throws -> Replay {
        let data = try Data(contentsOf: path(name))
        guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Unreadable(description: "not JSON") }
        return try Replay(d)
    }

    struct Entry { let name: String, label: String, savedAt: Int, elapsed: Double, map: String, result: String, difficulty: Int }

    /// Every recording, newest first.
    static func list() -> [Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: replaysDir.path) else { return [] }
        var out: [Entry] = []
        for fn in names where fn.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: replaysDir.appendingPathComponent(fn)),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            out.append(Entry(name: String(fn.dropLast(5)), label: jStr(d["label"]), savedAt: jInt(d["saved_at"]),
                             elapsed: Double(jNum(d["elapsed"])), map: jStr(d["map"]), result: result(of: d), difficulty: jInt(d["difficulty"])))
        }
        return out.sorted { $0.savedAt > $1.savedAt }
    }
}
