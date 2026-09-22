import Foundation

/// Saving and loading a single-player game — the same JSON document the Linux edition's save.py writes and
/// reads, key for key, so a game saved on one platform loads on the other. The format is versioned; older
/// formats are refused, not guessed at. Files live in ~/Library/Application Support/FieldCommand/saves.
enum SaveGame {
    static let format = 1

    /// JSON booleans arrive as NSNumber; Python writes true/false.
    static func jBoolean(_ v: Any?) -> Bool { (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false) }

    static var savesDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("FieldCommand/saves")
    }

    // MARK: Orders

    private static func orderOut(_ o: SOrder) -> [Any] {
        switch o {
        case .idle: return ["idle"]
        case .move(let x, let y): return ["move", x, y]
        case .amove(let x, let y): return ["amove", x, y]
        case .attack(let t): return ["attack", t.id]
        case .gather(let c): return ["gather", c.id]
        case .ret: return ["return"]
        case .build(let k, let x, let y): return ["build", NetProtocol.name(k), x, y]
        case .rebuild(let b): return ["rebuild", b.id]
        case .repair(let b): return ["repair", b.id]
        case .heal(let u): return ["heal", u.id]
        }
    }

    private static func orderIn(_ d: [Any], _ w: SWorld) -> SOrder {
        guard let k = d.first as? String else { return .idle }
        switch k {
        case "move" where d.count >= 3: return .move(Double(jNum(d[1])), Double(jNum(d[2])))
        case "amove" where d.count >= 3: return .amove(Double(jNum(d[1])), Double(jNum(d[2])))
        case "attack" where d.count >= 2: return (w.byId[jInt(d[1])] as? SEntity).map { .attack($0) } ?? .idle
        case "gather" where d.count >= 2: return (w.byId[jInt(d[1])] as? SCrystal).map { .gather($0) } ?? .idle
        case "return": return .ret
        case "build" where d.count >= 4: return NetProtocol.buildingKind(jStr(d[1])).map { .build($0, Double(jNum(d[2])), Double(jNum(d[3]))) } ?? .idle
        case "rebuild" where d.count >= 2: return (w.byId[jInt(d[1])] as? SBridge).map { .rebuild($0) } ?? .idle
        case "repair" where d.count >= 2: return (w.byId[jInt(d[1])] as? SEntity).map { .repair($0) } ?? .idle
        case "heal" where d.count >= 2: return (w.byId[jInt(d[1])] as? SUnit).map { .heal($0) } ?? .idle
        default: return .idle
        }
    }

    // MARK: Fog bits (numpy.packbits layout: row-major cells, most significant bit first)

    static func bitsOut(_ cells: [Bool]) -> String {
        var bytes = [UInt8](repeating: 0, count: (cells.count + 7) / 8)
        for (i, on) in cells.enumerated() where on { bytes[i / 8] |= UInt8(0x80) >> UInt8(i % 8) }
        return Data(bytes).base64EncodedString()
    }

    static func bitsIn(_ text: String, count: Int) -> [Bool] {
        guard let data = Data(base64Encoded: text) else { return Array(repeating: false, count: count) }
        let bytes = [UInt8](data)
        return (0..<count).map { i in i / 8 < bytes.count && (bytes[i / 8] & (UInt8(0x80) >> UInt8(i % 8))) != 0 }
    }

    // MARK: Out

    static func encode(_ w: SWorld, label: String = "") -> [String: Any] {
        func slots<T>(_ m: [Int: T], _ f: (T) -> Any) -> [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in m { out[String(k)] = f(v) }
            return out
        }
        let units: [[String: Any]] = w.units.filter { !$0.dead }.map { u in
            ["id": u.id, "kind": NetProtocol.name(u.kind), "team": u.team, "x": u.x, "y": u.y, "angle": u.angle,
             "gun_angle": u.gunAngle, "hp": u.hp, "max_hp": u.maxHp, "carrying": u.carrying, "mode": u.mode.rawValue,
             "mode_timer": u.modeTimer, "kills": u.kills, "rank": u.rank, "cooldown": u.cooldown,
             "order": orderOut(u.order), "queued": u.queued.map(orderOut),
             "home_crystal": u.homeCrystal.map { $0.id as Any } ?? NSNull(),
             "resume_gather": u.resumeGather.map { $0.id as Any } ?? NSNull(),
             "resume_point": u.resumePoint.map { [$0.0, $0.1] as Any } ?? NSNull()]
        }
        let buildings: [[String: Any]] = w.buildings.filter { !$0.dead }.map { b in
            ["id": b.id, "kind": NetProtocol.name(b.kind), "team": b.team, "x": b.x, "y": b.y, "hp": b.hp, "max_hp": b.maxHp,
             "built": b.built, "progress": b.progress, "queue": b.queue.map { NetProtocol.name($0) }, "queue_progress": b.queueProgress,
             "rally": b.rally.map { [$0.0, $0.1] as Any } ?? NSNull(), "gun_angle": b.gunAngle,
             "upgrades": b.upgrades.map { $0.wireName }.sorted(), "upgrading": b.upgrading.map { $0.wireName as Any } ?? NSNull(),
             "upgrade_progress": b.upgradeProgress]
        }
        var ai: [String: Any] = [:]
        for (s, p) in w.players { if let a = p.ai { ai[String(s)] = a.saveState() } }
        var fogOut: [String: Any] = [:]
        for (t, g) in w.fog { fogOut[String(t)] = bitsOut(g.explored) }
        var reveals: [String: Any] = [:]
        for (t, r) in w.revealsForSave { var m: [String: Any] = [:]; for (i, u) in r { m[String(i)] = u }; reveals[String(t)] = m }
        return [
            "format": format, "game": "field-command", "version": appVersion, "label": label,
            "saved_at": Int(Date().timeIntervalSince1970), "map": w.map, "difficulty": w.difficulty.rawValue,
            "elapsed": w.elapsed, "next_id": w.nextIdForSave,
            "players": w.players.values.sorted { $0.slot < $1.slot }.map {
                ["slot": $0.slot, "name": $0.name, "team": $0.team, "is_ai": $0.isAI, "start": $0.start, "alive": $0.alive] as [String: Any] },
            "resources": slots(w.resources) { $0 }, "kits": slots(w.playerKits) { $0.sorted() },
            "units_trained": slots(w.unitsTrained) { $0 }, "units_lost": slots(w.unitsLost) { $0 },
            "crystals_mined": slots(w.crystalsMined) { $0 }, "trained_kinds": slots(w.unitsTrained) { _ in [String: Int]() },
            "crystals": w.crystals.filter { !$0.dead }.map {
                ["id": $0.id, "x": $0.x, "y": $0.y, "amount": $0.amount, "max_amount": $0.amount, "variant": $0.variant] as [String: Any] },
            "units": units, "buildings": buildings,
            "bridges": w.bridges.map { ["id": $0.id, "intact": $0.intact, "hp": $0.hp, "progress": $0.progress] as [String: Any] },
            "towers": w.towers.map { ["id": $0.id, "owner": $0.owner.map { $0 as Any } ?? NSNull(),
                                      "capturing": $0.capturing.map { $0 as Any } ?? NSNull(), "progress": $0.progress] as [String: Any] },
            "reveals": reveals, "ai": ai, "fog": fogOut,
        ]
    }

    // MARK: In

    struct Unreadable: Error, CustomStringConvertible { let description: String }

    static func decode(_ d: [String: Any]) throws -> SWorld {
        guard jStr(d["game"]) == "field-command", jInt(d["format"]) == format else {
            throw Unreadable(description: "not a Field Command save this version can read (format \(jInt(d["format"])))")
        }
        let map = d["map"] as? [String: Any] ?? [:]
        let players = jArr(d["players"]).map { jDict($0) }.map {
            SPlayer(slot: jInt($0["slot"]), name: jStr($0["name"]), team: jInt($0["team"]), isAI: jBoolean($0["is_ai"]), start: jInt($0["start"]))
        }
        let w = SWorld(map: map, players: players, difficulty: Difficulty(rawValue: jInt(d["difficulty"])) ?? .normal)
        for p in jArr(d["players"]).map({ jDict($0) }) { w.players[jInt(p["slot"])]?.alive = jBoolean(p["alive"]) }
        w.beginRestore()          // drops the opening base; bridges and towers keep their constructor ids
        for c in jArr(d["crystals"]).map({ jDict($0) }) {
            let cr = SCrystal(id: jInt(c["id"]), x: Double(jNum(c["x"])), y: Double(jNum(c["y"])), amount: jInt(c["amount"]), variant: jInt(c["variant"]))
            w.crystals.append(cr)
            w.byId[cr.id] = cr
        }
        for (s, live) in zip(jArr(d["bridges"]).map({ jDict($0) }), w.bridges) {
            live.intact = jBoolean(s["intact"]); live.hp = Double(jNum(s["hp"])); live.progress = Double(jNum(s["progress"]))
        }
        for (s, live) in zip(jArr(d["towers"]).map({ jDict($0) }), w.towers) {
            live.owner = s["owner"] is NSNull || s["owner"] == nil ? nil : jInt(s["owner"])
            live.capturing = s["capturing"] is NSNull || s["capturing"] == nil ? nil : jInt(s["capturing"])
            live.progress = Double(jNum(s["progress"]))
        }
        for (s, k) in jDict(d["kits"]) { w.playerKits[Int(s) ?? -1] = Set(jArr(k).map { jStr($0) }) }
        for b in jArr(d["buildings"]).map({ jDict($0) }) {
            guard let kind = NetProtocol.buildingKind(jStr(b["kind"])) else { continue }
            w.setNextId(jInt(b["id"]))
            let bd = SBuilding(world: w, kind: kind, team: jInt(b["team"]), x: Double(jNum(b["x"])), y: Double(jNum(b["y"])), built: jBoolean(b["built"]))
            bd.hp = Double(jNum(b["hp"])); bd.maxHp = Double(jNum(b["max_hp"])); bd.progress = Double(jNum(b["progress"]))
            bd.queue = jArr(b["queue"]).compactMap { q in NetProtocol.unitKinds.first { NetProtocol.name($0) == jStr(q) } }
            bd.queueProgress = Double(jNum(b["queue_progress"]))
            let r = jArr(b["rally"]); bd.rally = r.count == 2 ? (Double(jNum(r[0])), Double(jNum(r[1]))) : nil
            bd.gunAngle = Double(jNum(b["gun_angle"]))
            bd.upgrades = Set(jArr(b["upgrades"]).compactMap { u in UpgradeKind.allCases.first { $0.wireName == jStr(u) } })
            bd.upgrading = UpgradeKind.allCases.first { $0.wireName == jStr(b["upgrading"]) }
            bd.upgradeProgress = Double(jNum(b["upgrade_progress"]))
            w.add(bd)
        }
        var pending: [(SUnit, [String: Any])] = []
        for u in jArr(d["units"]).map({ jDict($0) }) {
            guard let kind = NetProtocol.unitKinds.first(where: { NetProtocol.name($0) == jStr(u["kind"]) }) else { continue }
            w.setNextId(jInt(u["id"]))
            let un = SUnit(world: w, kind: kind, team: jInt(u["team"]), x: Double(jNum(u["x"])), y: Double(jNum(u["y"])))
            un.angle = Double(jNum(u["angle"])); un.gunAngle = Double(jNum(u["gun_angle"]))
            un.hp = Double(jNum(u["hp"])); un.maxHp = Double(jNum(u["max_hp"])); un.carrying = jInt(u["carrying"])
            un.mode = SiegeMode(rawValue: jInt(u["mode"])) ?? .mobile; un.modeTimer = Double(jNum(u["mode_timer"]))
            un.kills = jInt(u["kills"]); un.rank = jInt(u["rank"]); un.cooldown = Double(jNum(u["cooldown"]))
            un.lastX = un.x; un.lastY = un.y
            w.add(un)
            pending.append((un, u))
        }
        for (un, u) in pending {              // orders after every entity exists, so references resolve
            un.order = orderIn(jArr(u["order"]), w)
            un.queued = jArr(u["queued"]).map { orderIn(jArr($0), w) }
            un.homeCrystal = w.byId[jInt(u["home_crystal"])] as? SCrystal
            un.resumeGather = w.byId[jInt(u["resume_gather"])] as? SCrystal
            let rp = jArr(u["resume_point"]); un.resumePoint = rp.count == 2 ? (Double(jNum(rp[0])), Double(jNum(rp[1]))) : nil
        }
        w.setNextId(max(jInt(d["next_id"]), (w.byId.keys.max() ?? 0) + 1))
        w.elapsed = Double(jNum(d["elapsed"]))
        for (s, v) in jDict(d["resources"]) { w.resources[Int(s) ?? -1] = Double(jNum(v)) }
        for (s, v) in jDict(d["units_trained"]) { w.unitsTrained[Int(s) ?? -1] = jInt(v) }
        for (s, v) in jDict(d["units_lost"]) { w.unitsLost[Int(s) ?? -1] = jInt(v) }
        for (s, v) in jDict(d["crystals_mined"]) { w.crystalsMined[Int(s) ?? -1] = jInt(v) }
        for (s, a) in jDict(d["ai"]) {
            guard let slot = Int(s), let p = w.players[slot] else { continue }
            let ai = SAI(world: w, team: slot)
            ai.restore(jDict(a), w)
            p.ai = ai
        }
        w.restoreReveals(jDict(d["reveals"]))
        for (t, bits) in jDict(d["fog"]) {
            if let alliance = Int(t), let g = w.fog[alliance] { g.restoreExplored(bitsIn(jStr(bits), count: g.cols * g.rows)) }
        }
        w.bridgesChanged()
        w.updateVisibility()
        return w
    }

    // MARK: Files

    static func path(_ name: String) -> URL { savesDir.appendingPathComponent("\(name).json") }

    @discardableResult
    static func write(_ w: SWorld, name: String, label: String = "") throws -> URL {
        try FileManager.default.createDirectory(at: savesDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: encode(w, label: label))
        let url = path(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func read(_ name: String) throws -> SWorld {
        let data = try Data(contentsOf: path(name))
        guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Unreadable(description: "not JSON") }
        return try decode(d)
    }

    /// (name, label, savedAt, elapsed), newest first.
    static func list() -> [(String, String, Int, Double)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: savesDir.path) else { return [] }
        var out: [(String, String, Int, Double)] = []
        for fn in names where fn.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: savesDir.appendingPathComponent(fn)),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            out.append((String(fn.dropLast(5)), jStr(d["label"]), jInt(d["saved_at"]), Double(jNum(d["elapsed"]))))
        }
        return out.sorted { $0.2 > $1.2 }
    }
}
