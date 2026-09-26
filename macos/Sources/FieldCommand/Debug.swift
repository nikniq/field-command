import SpriteKit

/// Developer hooks driven by environment variables (all off by default):
///   FC_AUTOSTART=0|1|2   skip the menu and start at that difficulty
///   FC_AUTOPLAY=1        an AI also plays the player's side
///   FC_TIMESCALE=n       run n simulation steps per frame
///   FC_SNAPSHOT_DIR=dir  write periodic PNG snapshots and a stats log there
///   FC_HEADLESS=1        run the match without a window (with FC_AUTOPLAY for AI vs AI)
///   FC_MENUSHOT=path     render the title screen to a PNG and exit (FC_MENUSHOT_BRIEF=mission id: with its briefing up)
///   FC_NETTEST=host:port join a multiplayer server headlessly as a scripted bot (cross-platform testing)
enum Debug {
    static let env = ProcessInfo.processInfo.environment
    static let autostart: Difficulty? = env["FC_AUTOSTART"].flatMap(Int.init).flatMap(Difficulty.init(rawValue:))
    static let autoplay = env["FC_AUTOPLAY"] == "1"
    static let timeScale = max(1, env["FC_TIMESCALE"].flatMap(Int.init) ?? 1)
    static let snapshotDir = env["FC_SNAPSHOT_DIR"]
    static let headless = env["FC_HEADLESS"] == "1"
    private static var nextSnapshot: CGFloat = 5
    private static var shots = 0

    static func afterFrame(_ g: GameScene) {
        guard let dir = snapshotDir, g.elapsed >= nextSnapshot else { return }
        nextSnapshot += 60
        snapshot(g, dir: dir, name: String(format: "t%04d", Int(g.elapsed)))
    }

    static func gameEnded(_ g: GameScene, won: Bool) {
        guard let dir = snapshotDir else { return }
        log(g, dir: dir, extra: "GAME OVER player \(won ? "WON" : "LOST")")
        if headless {
            snapshot(g, dir: dir, name: "end")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            snapshot(g, dir: dir, name: "end")
            if autoplay { NSApp.terminate(nil) }
        }
    }

    /// Renders the title screen to a PNG (FC_MENUSHOT=path).
    static func menuShot(_ path: String) {
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 1400, height: 880))
        let scene = MenuScene(size: view.bounds.size)
        view.presentScene(scene)
        scene.didMove(to: view)
        if let m = missionNamed(env["FC_MENUSHOT_BRIEF"]) { scene.showBriefing(m) }   // with a mission's briefing up
        for i in 0..<5 { scene.update(Double(i) * 0.5 + 1) }
        if let tex = view.texture(from: scene) { write(tex.cgImage(), to: path) }
    }

    /// Runs a match without a window, stepping the simulation as fast as possible.
    static func runHeadless(maxTime: CGFloat = 2400) {
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 1400, height: 880))
        let scene = GameScene(size: view.bounds.size, difficulty: autostart ?? .normal)
        view.presentScene(scene)
        if !scene.didSetup { scene.didMove(to: view) }
        var t: TimeInterval = 1
        while !scene.gameOver && scene.elapsed < maxTime {
            t += 1.0 / 60
            scene.update(t)
        }
        if !scene.gameOver, let dir = snapshotDir { log(scene, dir: dir, extra: "TIME LIMIT") }
    }

    private static func log(_ g: GameScene, dir: String, extra: String = "") {
        func side(_ t: Team) -> String {
            let us = g.units.filter { $0.team == t }
            let bs = g.buildings.filter { $0.team == t }
            let kinds = Dictionary(grouping: bs, by: { $0.stats.short }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ",")
            return "res=\(Int(g.resources[t.rawValue])) workers=\(us.filter { $0.kind == .worker }.count) " +
                "rangers=\(us.filter { $0.kind == .marine }.count) tanks=\(us.filter { $0.kind == .tank }.count) " +
                "supply=\(g.supplyUsed(t))/\(g.supplyCap(t)) mined=\(g.crystalsMined[t.rawValue]) lost=\(g.unitsLost[t.rawValue]) [\(kinds)]"
        }
        let line = "t=\(Int(g.elapsed)) \(extra)\n  P: \(side(.player))\n  E: \(side(.enemy))\n"
        print(line, terminator: "")
        if let h = FileHandle(forWritingAtPath: "\(dir)/log.txt") {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            h.closeFile()
        } else {
            FileManager.default.createFile(atPath: "\(dir)/log.txt", contents: line.data(using: .utf8))
        }
    }

    /// F12 in a game: the view as shown, saved to ~/Pictures with a note on the environment, for bug reports.
    static func saveScreenshot(_ g: GameScene) -> String? {
        guard let v = g.view, let tex = v.texture(from: g) else { return nil }
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let path = pictures.appendingPathComponent("field-command-\(stamp).png").path
        write(tex.cgImage(), to: path)
        let note = "Field Command \(appVersion) macOS\nview \(Int(v.bounds.width))x\(Int(v.bounds.height)) points, scale \(v.window?.backingScaleFactor ?? 1)\n"
            + "command-card icon repairs this game: \(g.hud.iconRepairs)\n"
        try? note.write(toFile: path.replacingOccurrences(of: ".png", with: ".txt"), atomically: true, encoding: .utf8)
        print("screenshot: \(path)")
        return path
    }

    private static func snapshot(_ g: GameScene, dir: String, name: String) {
        log(g, dir: dir)
        guard let v = g.view, shots < 40 else { return }
        shots += 1
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let tex = v.texture(from: g, crop: g.visibleWorldRect()) {
            write(tex.cgImage(), to: "\(dir)/\(name)_view.png")
        }
        // Metal caps a texture at 16384 pixels a side; at the view's 2x backing scale a giant map (9000 wide)
        // would not fit, so the whole-map shot is the largest centred window that does.
        let limit = 16384 / max(1, v.window?.backingScaleFactor ?? 2) - 64
        let w = min(worldSize.width, limit), h = min(worldSize.height, limit)
        let crop = CGRect(x: (worldSize.width - w) / 2, y: (worldSize.height - h) / 2, width: w, height: h)
        if let tex = v.texture(from: g.world, crop: crop) {
            write(tex.cgImage(), to: "\(dir)/\(name)_map.png")
        }
    }

    private static func write(_ img: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Drives the real Mac UI: Multiplayer → Host Game → Lobby → Start, then plays a few seconds as the host.
    static var instantScenes = false

    static func runHostTest() {
        instantScenes = true
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 1400, height: 880))
        let mp = MultiplayerScene(size: view.bounds.size)
        view.presentScene(mp)
        mp.didMove(to: view)
        mp.pressHost()
        guard let lobby = view.scene as? LobbyScene else {
            print("host test: FAILED to reach lobby (server running: \(GameServer.hosted != nil))")
            return
        }
        lobby.didMove(to: view)
        print("host test: hosting, lobby reached; waiting for a guest to ready up")
        var t: TimeInterval = 1
        let deadline = Date().addingTimeInterval(30)
        var started = false
        while Date() < deadline {
            t += 1.0 / 30
            view.scene?.update(t)
            if let g = view.scene as? GameScene {
                if !started {
                    g.didMove(to: view)
                    started = true
                    if !g.didSetup { g.didMove(to: view) }
                    print("host test: game started (net mode \(g.isNet), slot \(g.net?.slot ?? -1), players \(g.net?.players.count ?? 0))")
                }
                if g.elapsed > 20 { break }
            } else if t > 8 && Int(t * 30) % 60 == 0 {
                lobby.pressPrimary()  // Start (fails politely until the guest is ready)
            }
            usleep(33_000)
        }
        if let g = view.scene as? GameScene, let dir = snapshotDir {
            snapshot(g, dir: dir, name: "hosttest")
            print("host test: OK — \(g.units.count) units, \(g.buildings.count) buildings visible at t=\(Int(g.elapsed))")
        } else if !started {
            print("host test: FAILED — game never started")
        }
        stopHostedServer()
    }

    // MARK: - Headless multiplayer bot

    static func runNetTest(_ address: String, maxSeconds: TimeInterval = 400) {
        let parts = address.split(separator: ":")
        let host = String(parts.first ?? "127.0.0.1")
        let port = parts.count > 1 ? UInt16(parts[1]) ?? NetProtocol.gamePort : NetProtocol.gamePort
        let conn: NetConnection
        do { conn = try NetConnection(host: host, port: port) } catch {
            print("net test: \(error.localizedDescription)")
            return
        }
        conn.send(["t": "hello", "name": env["FC_NAME"] ?? "MacBot", "version": NetProtocol.version, "client": "mac"])
        var start: [String: Any]?
        let lobbyDeadline = Date().addingTimeInterval(90)
        while start == nil && Date() < lobbyDeadline {
            for m in conn.messages() {
                switch jStr(m["t"]) {
                case "welcome":
                    print("net test: joined as slot \(jInt(m["slot"]))")
                    conn.send(["t": "ready", "ready": true])
                case "start": start = m
                case "error": print("net test: server error: \(jStr(m["text"]))")
                default: break
                }
            }
            usleep(20_000)
        }
        guard let startMsg = start else {
            print("net test: game never started")
            return
        }
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 1400, height: 880))
        let net = NetSession(conn: conn, start: startMsg)
        let scene = GameScene(size: view.bounds.size, difficulty: net.difficulty, net: net)
        view.presentScene(scene)
        if !scene.didSetup { scene.didMove(to: view) }
        print("net test: game started on \(jStr(net.map["name"])) as slot \(net.slot), team \(net.myAlliance)")
        let bot = MacBot(scene: scene)
        var t: TimeInterval = 1
        let began = Date()
        var nextShot: CGFloat = 60
        while !scene.gameOver && Date().timeIntervalSince(began) < maxSeconds {
            t += 1.0 / 30
            scene.update(t)
            bot.tick()
            if let dir = snapshotDir, scene.elapsed >= nextShot {
                nextShot += 90
                bot.lookAtArmy()
                snapshot(scene, dir: dir, name: String(format: "mac_t%04d", Int(scene.elapsed)))
            }
            usleep(33_000)
        }
        for _ in 0..<10 {
            t += 1.0 / 30
            scene.update(t)
            usleep(33_000)
        }
        let won = net.winnerTeam == net.myAlliance
        print("net test: game over=\(scene.gameOver) winner team=\(net.winnerTeam.map(String.init) ?? "none") mac won=\(won) "
              + "at t=\(Int(scene.elapsed)) units=\(scene.units.count) buildings=\(scene.buildings.count)")
        for line in scene.endStatsLines() { print("  " + line) }
        if let dir = snapshotDir { snapshot(scene, dir: dir, name: "mac_end") }
        conn.close()
    }
    /// FC_SKIRMISHTEST=map_id: plays a single-player skirmish (local server + MacBot) headless, checks pausing.
    static func runSkirmishTest(_ mapId: String) -> Never {
        instantScenes = true
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 1400, height: 880))
        let opponents = Int(env["FC_OPPONENTS"] ?? "") ?? 1
        startSkirmish(view, size: view.bounds.size, difficulty: .normal, mapId: mapId, opponents: opponents)
        guard let scene = view.scene as? GameScene, let net = scene.net, net.isLocal else {
            print("skirmish test: FAILED — no local game")
            exit(1)
        }
        if !scene.didSetup { scene.didMove(to: view) }
        GameServer.hosted?.simSpeed = max(1, Int(env["FC_SIMSPEED"] ?? "") ?? 4)
        print("skirmish test: started \(jStr(net.map["name"])) with \(net.players.count) players, walls=\(scene.walls.count) terrain=\(scene.terrainImage != nil)")
        let bot = MacBot(scene: scene)
        var t: TimeInterval = 1
        func frames(_ n: Int, play: Bool = true) {
            for _ in 0..<n {
                t += 1.0 / 30
                scene.update(t)
                if play { bot.tick() }
                usleep(33_000)
            }
        }
        frames(90)
        if let dir = snapshotDir { bot.lookAtArmy(); snapshot(scene, dir: dir, name: "skirmish_\(mapId)_start") }
        scene.togglePause()
        frames(15, play: false)
        let t0 = net.serverTime
        frames(45, play: false)
        let pausedOK = net.serverTime == t0
        scene.togglePause()
        frames(45, play: false)
        print("skirmish test: pause holds the clock=\(pausedOK), resumes=\(net.serverTime > t0)")
        let began = Date()
        while !scene.gameOver && Date().timeIntervalSince(began) < 240 { frames(1) }
        frames(10, play: false)
        if let dir = snapshotDir { snapshot(scene, dir: dir, name: "skirmish_\(mapId)_end") }
        print("skirmish test: over=\(scene.gameOver) winner team=\(net.winnerTeam.map(String.init) ?? "none") t=\(Int(net.serverTime))")
        stopHostedServer()
        exit(pausedOK && net.serverTime > t0 ? 0 : 1)
    }

    /// FC_BRIDGETEST=map_id: plays a skirmish on a map with bridges, shells one crossing down and has it
    /// rebuilt, checking that the span blocks while it is down. Writes screenshots when FC_SNAPSHOT_DIR is set.
    static func runBridgeTest(_ mapId: String) -> Never {
        instantScenes = true
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 1400, height: 880))
        startSkirmish(view, size: view.bounds.size, difficulty: .normal, mapId: mapId, opponents: 1)
        guard let scene = view.scene as? GameScene, let net = scene.net, net.isLocal,
              let world = GameServer.hosted?.simulation else {
            print("bridge test: FAILED — no local game")
            exit(1)
        }
        if !scene.didSetup { scene.didMove(to: view) }
        var t: TimeInterval = 1
        func frames(_ n: Int) {
            for _ in 0..<n {
                t += 1.0 / 30
                scene.update(t)
                usleep(12_000)
            }
        }
        frames(60)
        guard let br = world.bridges.first else {
            print("bridge test: FAILED — \(mapId) has no bridges")
            exit(1)
        }
        scene.centerCamera(on: CGPoint(x: br.x, y: br.y))
        frames(20)
        if let dir = snapshotDir { snapshot(scene, dir: dir, name: "bridge_intact") }
        // How much of the deck is walkable. Probing the centre cell or guessing the crossing axis is not
        // reliable across maps — riverlands has a near-square deck that also overlaps neighbouring river
        // segments — but the count must fall when the bridge does and come back when it is rebuilt.
        func walkableCells() -> Int {
            world.nav.rebuild(rects: world.walls, circles: [])
            let r = br.rect
            var n = 0
            for cx in Int(r.x0 / 40)...Int(r.x1 / 40) {
                for cy in Int(r.y0 / 40)...Int(r.y1 / 40) {
                    let i = cy * world.nav.cols + cx
                    if i >= 0 && i < world.nav.blocked.count && !world.nav.blocked[i] { n += 1 }
                }
            }
            return n
        }
        let intactCells = walkableCells()

        br.takeDamage(bridgeHP, from: nil)          // shell it down
        frames(45)
        let downCells = walkableCells()
        let clientSawDown = scene.bridgeNodes.first { $0.bridgeId == br.id }.map { !$0.intact } ?? false
        if let dir = snapshotDir { snapshot(scene, dir: dir, name: "bridge_down") }

        br.restore()                                 // and put it back
        frames(45)
        let rebuiltCells = walkableCells()
        let clientSawUp = scene.bridgeNodes.first { $0.bridgeId == br.id }.map { $0.intact } ?? false
        if let dir = snapshotDir { snapshot(scene, dir: dir, name: "bridge_rebuilt") }

        let ok = intactCells > 0 && downCells < intactCells && rebuiltCells == intactCells
                 && clientSawDown && clientSawUp
        print("bridge test: walkable cells over the deck — intact \(intactCells), down \(downCells), "
              + "rebuilt \(rebuiltCells); client saw it fall=\(clientSawDown) and rise=\(clientSawUp)")
        print(ok ? "BRIDGE TEST PASSED" : "BRIDGE TEST FAILED")
        stopHostedServer()
        exit(ok ? 0 : 1)
    }

    /// FC_REPAIRTEST=1: checks Engineer repair on the server simulation — time, cost, stacking, running out of
    /// crystal, and refusing enemy buildings — then exits. The Python edition's numbers must match exactly.
    static func runRepairTest() -> Never {
        func fresh() -> (SWorld, SBuilding) {
            let map = SMapGen.generate("twin_ridges")
            let players = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: map, players: players, difficulty: .normal)
            for u in w.units where u.team == 0 { u.command(.idle) }      // no income while we measure
            let hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
            return (w, hq)
        }
        func engineer(_ w: SWorld, _ hq: SBuilding, dy: Double = 0) -> SUnit {
            let u = SUnit(world: w, kind: .worker, team: 0, x: hq.x + 140, y: hq.y + dy)
            w.add(u)
            return u
        }
        func run(_ w: SWorld, _ secs: Double, until done: () -> Bool) {
            var t = 0.0
            while t < secs && !done() { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 }
        }
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }

        // One Engineer, half a Command Center.
        var (w, hq) = fresh()
        hq.hp = hq.maxHp * 0.5
        w.resources[0] = 1000
        let e = engineer(w, hq)
        w.apply(0, ["repair", [e.id], hq.id, false])
        let t0 = w.elapsed
        run(w, 40) { hq.hp >= hq.maxHp }
        let spent = 1000 - (w.resources[0] ?? 0)
        let expected = 0.5 * Double(BuildingKind.hq.stats.cost) * repairCostRatio
        print(String(format: "repair test: one Engineer, half an HQ: %.1fs, %.1f crystal (expected %.1f)",
                     w.elapsed - t0, spent, expected))
        check(hq.hp == hq.maxHp, "the HQ is back to full health")
        check(abs(spent - expected) < 0.5, "a half-bar repair costs half of 35% of the building's price")
        check({ if case .repair = e.order { return false }; return true }(), "the Engineer went back to work")

        // Three Engineers stack.
        (w, hq) = fresh()
        hq.hp = hq.maxHp * 0.5
        w.resources[0] = 1000
        let crew = [-40.0, 0, 40].map { engineer(w, hq, dy: $0) }
        w.apply(0, ["repair", crew.map { $0.id }, hq.id, false])
        let t1 = w.elapsed
        run(w, 40) { hq.hp >= hq.maxHp }
        check(w.elapsed - t1 < repairTime * 0.5 * 0.8, String(format: "three Engineers stack (%.1fs)", w.elapsed - t1))

        // Out of crystal: it stops, never goes into debt.
        (w, hq) = fresh()
        hq.hp = hq.maxHp * 0.5
        w.resources[0] = 3
        let broke = engineer(w, hq)
        w.apply(0, ["repair", [broke.id], hq.id, false])
        run(w, 20) { if case .repair = broke.order { return false }; return true }
        check((w.resources[0] ?? 0) >= 0 && hq.hp < hq.maxHp, "stops when the crystal runs out, without debt")

        // Enemy buildings and construction sites are refused.
        (w, hq) = fresh()
        let enemy = w.buildings.first { $0.team == 1 && $0.kind == .hq }!
        enemy.hp = 500
        let e2 = engineer(w, hq)
        w.apply(0, ["repair", [e2.id], enemy.id, false])
        check({ if case .repair = e2.order { return false }; return true }(), "refuses to repair an enemy building")

        print(ok ? "REPAIR TEST PASSED" : "REPAIR TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_REPLAYTEST=1: the simulation is a pure function of its seed and commands — the same seed and commands
    /// give the same game, a different seed a different one — and a recorded game replays exactly.
    /// FC_HIGHTEST=1: high ground — plateaus are walkable and buildable, and whatever stands on one sees and
    /// shoots further; matching linux/tests/test_highground.py.
    /// FC_COVERTEST=1: cover among trees on the server simulation — matching linux/tests/test_cover.py.
    /// FC_DERELICTTEST=1: the derelict Siege Tank — placement, salvage, contest, the wire and the save —
    /// matching linux/tests/test_derelict.py.
    /// FC_TECHTEST=1: side-wide tech — entrenchment and stabilisers — matching linux/tests/test_tech.py.
    /// FC_GASTEST=1: the second resource — mined from gold, spent on tanks, Gunships, Artillery and tech, refunded
    /// when undone, carried on the wire and in saves — matching linux/tests/test_gas.py.
    /// FC_STAKESTEST=1: campaign stakes — veterans, branching unlocks and the named unit — matching
    /// linux/tests/test_campaign_stakes.py.
    static func runStakesTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func world(_ id: String, veterans: [(String, Int)] = []) -> (SWorld, Mission) {
            let m = missionNamed(id)!
            let spec = SMapGen.resolve(m.map, players: 1 + m.opponents)
            let ps = (0..<(1 + m.opponents)).map { SPlayer(slot: $0, name: "P\($0)", team: m.teams >= 2 ? $0 % m.teams + 1 : $0 + 1, isAI: $0 > 0, start: $0) }
            let w = SWorld(map: spec, players: ps, difficulty: Difficulty(rawValue: m.difficulty) ?? .normal, seed: 3, veterans: veterans)
            w.mission = m
            w.placeVIP()
            return (w, m)
        }
        func run(_ w: SWorld, _ secs: Double) { var t = 0.0; while t < secs { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 } }
        do {
            let by = Dictionary(uniqueKeysWithValues: campaign.map { ($0.id, $0) })
            var good = by["first_light"]!.requires.isEmpty && by["hold_the_line"]!.requires == ["first_light"] && by["gold_run"]!.requires == ["first_light"]
            good = good && Set(by["crossfire"]!.requires) == ["hold_the_line", "gold_run"] && by["long_march"]!.requires == ["crossfire"]
            good = good && by["gold_run"]!.vip?.0 == "sniper" && by["gold_run"]!.vip?.1 == "Sergeant Kade" && by["long_march"]!.vip?.0 == "tank"
            check(good && veteranCarry == 8, "missions open in branches, two of them with a named unit")
        }
        do {
            let (w, _) = world("first_light", veterans: [("marine", vetThresholds[1]), ("tank", vetThresholds[0]), ("worker", 99)])
            let hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
            let vets = w.units.filter { $0.team == 0 && $0.rank > 0 }
            let kinds = Set(vets.map { NetProtocol.name($0.kind) })
            let rightKinds: Bool = kinds == ["marine", "tank"] && vets.count == 2
            var ranked = false, near = true
            if let r = vets.first(where: { $0.kind == .marine }) {
                let hpUp: Bool = r.maxHp > Double(UnitKind.marine.stats.hp)
                ranked = r.rank == 2 && r.kills == vetThresholds[1] && hpUp && r.hp == r.maxHp
            }
            for v in vets { if hypot(v.x - hq.x, v.y - hq.y) >= 200 { near = false } }
            check(rightKinds && ranked && near, "veterans stand by the Command Center with their rank; an Engineer is no veteran")
        }
        do {
            let (w, _) = world("gold_run")
            for u in w.units { u.command(.idle) }
            let v = w.vip
            let stands = v != nil && v!.kind == .sniper && v!.team == 0
            run(w, 1)
            let alive = !w.gameOver
            v!.hp = 0; v!.dead = true
            run(w, 0.5)
            check(stands && alive && w.gameOver && w.winnerTeam != w.players[0]!.team, "the named unit stands with you, and its death loses the mission")
            let (w2, _) = world("first_light", veterans: [("sniper", vetThresholds[0])])
            let rec = try! Replay(try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: Replay.encode(w2, viewer: 0))) as! [String: Any])
            check(w2.vip == nil && rec.veterans.count == 1 && rec.veterans[0].0 == "sniper" && rec.veterans[0].1 == vetThresholds[0],
                  "missions without a named unit, and a replay carries the veterans")
        }
        print(ok ? "STAKES TEST PASSED" : "STAKES TEST FAILED")
        exit(ok ? 0 : 1)
    }

    static func runGasTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func setup() -> (SWorld, SBuilding) {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal, seed: 3)
            for u in w.units { u.command(.idle); u.cooldown = 1e9 }
            w.resources[0] = 5000
            return (w, w.buildings.first { $0.team == 0 && $0.kind == .hq }!)
        }
        func stand(_ w: SWorld, _ k: BuildingKind, _ x: Double, _ y: Double, _ team: Int = 0) -> SBuilding {
            w.startBuilding(k, x, y, team)
            let b = w.buildings.last!
            b.built = true; b.progress = 1; b.hp = b.maxHp
            return b
        }
        func run(_ w: SWorld, _ secs: Double) { var t = 0.0; while t < secs { w.step(1.0 / 30); t += 1.0 / 30 } }
        do {
            let (w, _) = setup()
            check(w.gas[0] == Double(gasStart) && w.gas[1] == Double(gasStart) && gasStart == 100
                  && Set(gasCost.keys) == [.tank, .gunship] && Set(gasBuild.keys) == [.artillery] && Set(gasUpgrade.keys) == [.guns, .entrench, .stabilise],
                  "every side starts with some gas and the prices are set")
        }
        do {
            let (w, hq) = setup()
            let s = BuildingKind.refinery.stats
            let onCard = NetProtocol.buildingKinds.contains(.refinery) && s.requires == nil && s.cost == 150 && gasRate == 0.5
                && !BuildingKind.allCases.filter({ $0 != .refinery }).contains { $0.stats.hotkey == s.hotkey }
            _ = stand(w, .refinery, hq.x + 250, hq.y + 150)
            let g0 = w.gas[0]!
            run(w, 10)
            let one = abs((w.gas[0]! - g0) - gasRate * 10) < gasRate * 0.5
            _ = stand(w, .refinery, hq.x - 300, hq.y - 200)
            let g1 = w.gas[0]!
            run(w, 10)
            let two = abs((w.gas[0]! - g1) - gasRate * 20) < gasRate
            // Gold is minerals again: a trip from a gold node pays crystal, and no gas.
            let gold = w.crystals.first { $0.variant == 3 }!
            let e = SUnit(world: w, kind: .worker, team: 0, x: gold.x + 30, y: gold.y)
            w.add(e)
            e.carrying = e.carryCapacity
            e.homeCrystal = gold
            e.command(.ret)
            e.x = hq.x + hq.half + 4; e.y = hq.y
            let c0 = w.resources[0]!, g2 = w.gas[0]!
            run(w, 1)
            check(onCard && one && two && w.resources[0] == c0 + Double(e.carryCapacity) && w.gas[0]! - g2 < gasRate * 2.5,
                  "a Refinery draws gas anywhere, two draw twice as much, and gold yields crystal (card \(onCard) one \(one) two \(two) crystal \(w.resources[0]! - c0) gas \(w.gas[0]! - g2))")
        }
        do {
            let (w, hq) = setup()
            let fc = stand(w, .factory, hq.x + 400, hq.y)
            _ = stand(w, .barracks, hq.x + 400, hq.y + 250)
            w.gas[0] = Double(gasCost[.tank]! - 1)
            let refused = !w.train(.tank, [fc], 0) && fc.queue.isEmpty && w.events.contains { jStr($0.first) == "msg" && jStr($0[2]).contains("gas") }
            w.gas[0] = Double(gasCost[.tank]!)
            let bought = w.train(.tank, [fc], 0) && fc.queue == [.tank] && w.gas[0] == 0
            w.cancelQueue(fc, 0)
            check(refused && bought && w.gas[0] == Double(gasCost[.tank]!), "tanks cost gas, the bank says no when it is empty, and a cancel refunds it")
        }
        do {
            let (w, hq) = setup()
            let fc = stand(w, .factory, hq.x + 400, hq.y)
            _ = stand(w, .barracks, hq.x + 400, hq.y + 250)
            let e = w.units.first { $0.team == 0 && $0.kind == .worker }!
            w.updateVisibility()
            var spot: (Double, Double)? = nil
            outer: for dx in stride(from: -300.0, through: 300, by: 50) {
                for dy in stride(from: -300.0, through: 300, by: 50) where w.canPlace(.artillery, hq.x + dx, hq.y + dy) && w.fogFor(0).isExplored(hq.x + dx, hq.y + dy) {
                    spot = (hq.x + dx, hq.y + dy); break outer
                }
            }
            let (sx, sy) = spot!
            w.gas[0] = 10
            w.apply(0, ["build", e.id, "artillery", sx, sy, false])
            var isBuild = false
            if case .build = e.order { isBuild = true }
            let refused = !isBuild
            w.gas[0] = Double(gasBuild[.artillery]! + 5)
            w.apply(0, ["build", e.id, "artillery", sx, sy, false])
            if case .build = e.order { isBuild = true } else { isBuild = false }
            let placed = isBuild && w.gas[0] == 5
            e.command(.idle)
            let back = w.gas[0] == Double(gasBuild[.artillery]! + 5)
            w.gas[0] = Double(gasUpgrade[.stabilise]!)
            w.apply(0, ["upgrade", [fc.id], "stabilise"])
            let researching = fc.upgrading == .stabilise && w.gas[0] == 0
            fc.cancelUpgrade()
            check(refused && placed && back && researching && w.gas[0] == Double(gasUpgrade[.stabilise]!),
                  "Artillery and tech take gas too, and hand it back when undone")
        }
        do {
            let (w, _) = setup()
            w.gas[0] = 77
            let doc = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: SaveGame.encode(w))) as! [String: Any]
            let w2 = try! SaveGame.decode(doc)
            check(w2.gas[0] == 77 && w2.gas[1] == Double(gasStart), "gas travels in saves")
        }
        do {
            let (w, _) = setup()
            let ai = SAI(world: w, team: 1)
            func wanted(_ t: Double, _ k: BuildingKind) -> Int { ai.plan(t).filter { $0.0 == k }.map { $0.1 }.max() ?? 0 }
            check(wanted(200, .refinery) == 1 && wanted(200, .factory) == 1 && wanted(100, .refinery) == 0 && wanted(500, .refinery) == 2,
                  "the computer builds a Refinery after its Factory")
        }
        print(ok ? "GAS TEST PASSED" : "GAS TEST FAILED")
        exit(ok ? 0 : 1)
    }

    static func runTechTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func setup(_ kind: BuildingKind) -> (SWorld, SBuilding, SBuilding) {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal, seed: 3)
            for u in w.units { u.command(.idle); u.cooldown = 1e9 }
            w.resources[0] = 5000
            let hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
            w.startBuilding(kind, hq.x + 400, hq.y, 0)
            let b = w.buildings.last!
            b.built = true; b.progress = 1; b.hp = b.maxHp
            return (w, hq, b)
        }
        func unit(_ w: SWorld, _ k: UnitKind, _ team: Int, _ x: Double, _ y: Double, armed: Bool = false) -> SUnit {
            let u = SUnit(world: w, kind: k, team: team, x: x, y: y)
            w.add(u)
            u.command(.idle)
            if !armed { u.cooldown = 1e9 }
            return u
        }
        func run(_ w: SWorld, _ secs: Double, until done: () -> Bool = { false }) -> Bool {
            var t = 0.0
            while t < secs { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30; if done() { return true } }
            return done()
        }
        func research(_ w: SWorld, _ b: SBuilding, _ k: UpgradeKind) -> Bool {
            w.apply(0, ["upgrade", [b.id], k.wireName])
            return b.upgrading == k && run(w, k.stats.time + 1) { b.upgrades.contains(k) }
        }
        check(techKinds == [.entrench, .stabilise] && UpgradeKind.allCases.suffix(2).elementsEqual(techKinds)
              && UpgradeKind.entrench.applies(to: .barracks) && !UpgradeKind.entrench.applies(to: .factory)
              && UpgradeKind.stabilise.applies(to: .factory) && !UpgradeKind.stabilise.applies(to: .barracks),
              "the two techs are in the catalogue at their buildings")
        do {
            let (w, hq, bk) = setup(.barracks)
            let r = unit(w, .marine, 0, hq.x + 200, hq.y + 300)
            let foe = unit(w, .marine, 1, r.x + 100, r.y)
            _ = run(w, entrenchTime + 1)
            let none = !r.dugIn
            var hp = r.hp
            r.takeDamage(10, from: foe)
            let full = abs(hp - r.hp - 10) < 1e-9
            let got = research(w, bk, .entrench)
            let dug = w.hasTech(.entrench, 0) && r.stillFor >= entrenchTime && r.dugIn
            hp = r.hp
            r.takeDamage(10, from: foe)
            let less = abs(hp - r.hp - 10 * entrenchFactor) < 1e-9
            r.command(.move(r.x + 200, r.y))
            _ = run(w, 1)
            let up = r.stillFor < entrenchTime && !r.dugIn
            hp = r.hp
            r.takeDamage(10, from: foe)
            check(none && full && got && dug && less && up && abs(hp - r.hp - 10) < 1e-9, "entrenched infantry that holds still takes less; on the move it does not")
            let t = unit(w, .tank, 0, hq.x + 200, hq.y + 500)
            let e = unit(w, .worker, 0, hq.x + 260, hq.y + 500)
            _ = run(w, entrenchTime + 1)
            check(!t.dugIn && !e.dugIn, "tanks and Engineers do not dig in")
        }
        do {
            let (w, hq, bk) = setup(.barracks)
            w.startBuilding(.barracks, hq.x + 400, hq.y + 250, 0)
            let bk2 = w.buildings.last!
            bk2.built = true; bk2.progress = 1; bk2.hp = bk2.maxHp
            let before = bk2.canUpgrade(.entrench)
            let got = research(w, bk, .entrench)
            let money = w.resources[0] ?? 0
            w.apply(0, ["upgrade", [bk2.id], "entrench"])
            check(before && got && !bk2.canUpgrade(.entrench) && bk2.upgrading == nil && w.resources[0] == money, "tech is bought once for the whole side")
        }
        do {
            let (w, hq, fc) = setup(.factory)
            let t = unit(w, .tank, 0, hq.x + 200, hq.y + 400, armed: true)
            let target = unit(w, .marine, 1, hq.x + 500, hq.y + 520)
            let hp = target.hp
            t.command(.move(hq.x + 800, hq.y + 400))
            _ = run(w, 4)
            let held = target.hp == hp
            t.command(.move(hq.x + 200, hq.y + 400))
            _ = run(w, 10) { t.order.isIdle }
            let got = research(w, fc, .stabilise)
            t.command(.move(hq.x + 800, hq.y + 400))
            let fired = run(w, 4) { target.hp < hp }
            check(held && got && fired && t.order.isMove, "stabilised tanks fire on the move")
        }
        do {
            let (w, hq, bk) = setup(.barracks)
            w.startBuilding(.factory, hq.x + 400, hq.y + 250, 0)
            let fc = w.buildings.last!
            fc.built = true; fc.progress = 1; fc.hp = fc.maxHp
            let ai = SAI(world: w, team: 0)
            let bases = w.buildings.filter { $0.team == 0 }
            for b in bases { b.upgrades.insert(.prod) }
            w.resources[0] = 5000
            ai.upgradeForTests(hq, bases)
            let first = bk.upgrading == .entrench
            bk.upgrades.insert(.entrench); bk.upgrading = nil
            ai.upgradeForTests(hq, bases)
            check(first && fc.upgrading == .stabilise, "the computer researches both")
        }
        print(ok ? "TECH TEST PASSED" : "TECH TEST FAILED")
        exit(ok ? 0 : 1)
    }

    static func runDerelictTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func fresh(_ mapId: String = "twin_ridges") -> SWorld {
            let n = SMapGen.info(mapId)?.players ?? 2
            let ps = (0..<n).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: SMapGen.generate(mapId), players: ps, difficulty: .normal, seed: 3)
            for u in w.units { u.command(.idle) }
            return w
        }
        func unit(_ w: SWorld, _ k: UnitKind, _ team: Int, _ x: Double, _ y: Double) -> SUnit {
            let u = SUnit(world: w, kind: k, team: team, x: x, y: y)
            w.add(u)
            u.command(.idle)
            u.cooldown = 1e9
            return u
        }
        func run(_ w: SWorld, _ secs: Double) { var t = 0.0; while t < secs { w.step(1.0 / 30); t += 1.0 / 30 } }
        for m in SMapGen.catalog {
            let w = fresh(m.id)
            guard let d = w.derelicts.first, w.derelicts.count == 1 else { check(false, "\(m.id): one derelict"); continue }
            let (rx, ry) = w.ring
            let clear = !w.mapWallsForTests.contains { $0.distance(d.x, d.y) < 20 }
            check(clear && w.towers.allSatisfy { hypot($0.x - d.x, $0.y - d.y) >= 300 } && hypot(d.x - rx, d.y - ry) < 700 && w.byId[d.id] === d,
                  "\(m.id): one derelict on open ground near the middle")
        }
        do {
            let w = fresh()
            let d = w.derelicts[0]
            _ = unit(w, .worker, 0, d.x + 40, d.y)
            func tanks() -> [SUnit] { w.units.filter { $0.kind == .tank && $0.team == 0 && !$0.dead } }
            run(w, derelictTime - 0.5)
            let working = w.derelicts.count == 1 && d.capturing == 0 && d.progress > 0.8 && tanks().isEmpty
            run(w, 1)
            let said = w.events.contains { jStr($0.first) == "msg" && jStr($0[2]).contains("salvaged") }
            check(working && w.derelicts.isEmpty && w.byId[d.id] == nil && tanks().count == 1 && hypot(tanks()[0].x - d.x, tanks()[0].y - d.y) < 30 && said,
                  "an Engineer alone beside it salvages a Siege Tank")
        }
        do {
            let w = fresh()
            let d = w.derelicts[0]
            _ = unit(w, .marine, 0, d.x + 40, d.y)
            run(w, derelictTime + 1)
            let notTroops = w.derelicts.count == 1 && d.progress == 0
            _ = unit(w, .worker, 0, d.x - 40, d.y)
            run(w, derelictTime / 2)
            let half = d.progress > 0.3 && d.progress < 0.7 && d.capturing == 0
            let foe = unit(w, .marine, 1, d.x, d.y + 50)
            run(w, 2)
            let stalled = d.progress < 0.4
            foe.dead = true
            w.cleanupDead()
            run(w, derelictTime)
            check(notTroops && half && stalled && w.derelicts.isEmpty, "troops alone do not salvage, and an enemy inside stalls it")
        }
        do {
            let w = fresh()
            let d = w.derelicts[0]
            _ = unit(w, .worker, 1, d.x + 30, d.y)
            run(w, 3)
            let wired = d.capturing == 1 && d.progress > 0
            let doc = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: SaveGame.encode(w))) as! [String: Any]
            let w2 = try! SaveGame.decode(doc)
            let saved = w2.derelicts.count == 1 && w2.derelicts[0].id == d.id && w2.derelicts[0].capturing == 1 && w2.derelicts[0].progress > 0
            run(w, derelictTime)
            let doc2 = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: SaveGame.encode(w))) as! [String: Any]
            let w3 = try! SaveGame.decode(doc2)
            check(wired && saved && w.derelicts.isEmpty && w3.derelicts.isEmpty, "the derelict travels in saves, and a salvaged one stays gone")
        }
        do {
            let w = fresh()
            let ai = SAI(world: w, team: 1)
            w.elapsed = 25
            let hq = w.buildings.first { $0.team == 1 && $0.kind == .hq }!
            let home = w.units.filter { $0.team == 1 && $0.kind != .worker }
            let workers = w.units.filter { $0.team == 1 && $0.kind == .worker }
            ai.salvage(hq, workers, home)
            let d = w.derelicts[0]
            var going = false
            if let s = ai.salvagerForTests, workers.contains(where: { $0 === s }), case .move(let x, _) = s.order { going = abs(x - (d.x + 30)) < 1 }
            w.derelicts.removeAll()
            ai.salvage(hq, workers, home)
            check(going && ai.salvagerForTests == nil, "the computer sends an Engineer for it")
        }
        print(ok ? "DERELICT TEST PASSED" : "DERELICT TEST FAILED")
        exit(ok ? 0 : 1)
    }

    static func runCoverTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func fresh() -> (SWorld, (Double, Double, Double)) {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal, seed: 3)
            for u in w.units { u.command(.idle); u.cooldown = 1e9 }
            return (w, w.obstacles[0])
        }
        func unit(_ w: SWorld, _ k: UnitKind, _ team: Int, _ x: Double, _ y: Double) -> SUnit {
            let u = SUnit(world: w, kind: k, team: team, x: x, y: y)
            w.add(u)
            u.command(.idle)
            u.cooldown = 1e9
            return u
        }
        check(Set(coverKinds) == Set(UnitKind.allCases.filter { !$0.stats.flies && $0 != .tank }), "the rule covers everyone on foot and nobody else")
        do {
            let (w, t) = fresh()
            let r = unit(w, .marine, 0, t.0 + t.2 + coverReach - 2, t.1)
            let far = unit(w, .sniper, 1, r.x + smokeRanged + 300, r.y)
            let near = unit(w, .marine, 1, r.x + 30, r.y)
            let covered = w.inCover(r.x, r.y)
            var hp = r.hp
            r.takeDamage(10, from: far)
            let half = abs(hp - r.hp - 10 * coverFactor) < 1e-9
            hp = r.hp
            r.takeDamage(10, from: near)
            check(covered && half && abs(hp - r.hp - 10) < 1e-9, "infantry among trees takes half from a distance, all point blank")
            let tank = unit(w, .tank, 0, t.0 + t.2 + coverReach - 2, t.1 + 30)
            hp = tank.hp
            tank.takeDamage(10, from: far)
            check(abs(hp - tank.hp - 10) < 1e-9, "tanks get nothing from a forest")
        }
        do {
            let (w, t) = fresh()
            let r = unit(w, .marine, 0, t.0 + t.2 + coverReach - 2, t.1)
            let tank = unit(w, .tank, 0, r.x + 20, r.y)
            let popped = w.useAbility(0, [tank], 0, 0) == 1
            let far = unit(w, .sniper, 1, r.x + 400, r.y)
            let hp = r.hp
            r.takeDamage(10, from: far)
            check(popped && abs(hp - r.hp - 10 * coverFactor) < 1e-9, "cover and smoke do not stack")
        }
        print(ok ? "COVER TEST PASSED" : "COVER TEST FAILED")
        exit(ok ? 0 : 1)
    }

    static func runHighGroundTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        var withRidges: [String] = []
        for m in SMapGen.catalog {
            let spec = SMapGen.generate(m.id)
            let ridges = Terrain.ridges(spec), walls = Terrain.walls(spec).map { $0.rect }
            for r in ridges {
                check(r.minX >= 0 && r.maxX <= CGFloat(jNum(spec["w"])) && r.minY >= 0 && r.maxY <= CGFloat(jNum(spec["h"])) && r.width > 0 && r.height > 0,
                      "\(m.id): a plateau inside the world")
                check(!walls.contains { $0.intersects(r) }, "\(m.id): clear of water and cliffs")
                withRidges.append(m.id)
            }
        }
        let giants: Set<String> = ["continental_divide", "archipelago", "six_rivers", "crater_fields", "long_march"]
        check(Set(withRidges).isSuperset(of: ["twin_ridges", "highland_pass", "four_corners"]) && giants.isSubset(of: Set(withRidges)),
              "the three hand-drawn maps and every giant map have high ground")
        let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
        let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal)
        let r = w.ridges[0]
        let cx = (r.x0 + r.x1) / 2, cy = (r.y0 + r.y1) / 2
        let up = SUnit(world: w, kind: .marine, team: 0, x: cx, y: cy)
        let down = SUnit(world: w, kind: .marine, team: 0, x: r.x0 - 200, y: cy)
        check(w.onHigh(cx, cy) && !w.onHigh(r.x0 - 200, cy), "the plateau is high ground; beside it is not")
        check(up.attackRange == down.attackRange + highRange && up.attackRange == Double(UnitKind.marine.stats.range) + highRange, "a Ranger up there shoots further")
        check(up.sight == down.sight * highSight, "and sees further")
        w.startBuilding(.turret, cx, cy, 0)
        let t = w.buildings.last!
        t.built = true
        check(t.turretRange == Double(BuildingKind.turret.stats.range) + highRange, "so does a turret")
        let hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
        check(w.nav.reaches(hq.x, hq.y, cx, cy) && w.canPlace(.depot, cx, cy + 120), "plateaus are walkable and buildable")
        for u in w.units { u.dead = true }
        t.dead = true
        w.cleanupDeadForTests()
        let ranger = SUnit(world: w, kind: .marine, team: 0, x: cx, y: cy)
        w.add(ranger)
        w.updateVisibility()
        let far = Double(UnitKind.marine.stats.sight) * 1.2
        let team = w.players[0]!.team
        check(w.fog[team]?.isVisible(cx + far, cy) == true, "from the high ground a Ranger reveals beyond its plain sight")
        ranger.x = r.x0 - 200
        w.updateVisibility()
        check(w.fog[team]?.isVisible(r.x0 - 200 + far, cy) == false, "and not from the low ground")
        print(ok ? "HIGH GROUND TEST PASSED" : "HIGH GROUND TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_POLISHTEST=1: the army timeline for the end screen, undoing a placement, and rebindable keys —
    /// matching linux/tests/test_polish.py.
    static func runPolishTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
        let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal)
        for u in w.units { u.command(.idle) }
        func run(_ w: SWorld, _ seconds: Double) { var t = 0.0; while t < seconds { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 } }
        run(w, historyStep * 4 + 1)
        check(w.history.values.allSatisfy { $0.count == 5 }, "every side's army is sampled on the clock (5 samples in a minute)")
        let hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
        for i in 0..<3 { w.add(SUnit(world: w, kind: .marine, team: 0, x: hq.x + 200 + Double(i) * 30, y: hq.y)) }
        run(w, historyStep)
        check(w.history[0]?.last == 3 && w.history[1]?.last == 0, "and counts combat units only")
        let doc = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: SaveGame.encode(w))) as! [String: Any]
        let w2 = try! SaveGame.decode(doc)
        let kept = w2.history[0] == w.history[0]
        run(w2, historyStep)
        check(kept && (w2.history[0]?.count ?? 0) == (w.history[0]?.count ?? 0) + 1, "the timeline survives a save and carries on")

        w.resources[0] = 1000
        w.startBuilding(.depot, hq.x + 300, hq.y, 0)
        let site = w.buildings.last!
        w.resources[0]! -= Double(BuildingKind.depot.stats.cost)
        site.progress = undoProgress - 0.1
        w.apply(0, ["unbuild", site.id])
        check(!w.buildings.contains { $0 === site } && w.byId[site.id] == nil && w.resources[0] == 1000, "a placement barely started can be taken back for a full refund")
        w.startBuilding(.depot, hq.x + 300, hq.y, 0)
        let site2 = w.buildings.last!
        site2.progress = undoProgress + 0.1
        w.apply(0, ["unbuild", site2.id])
        w.apply(1, ["unbuild", site2.id])
        check(w.buildings.contains { $0 === site2 }, "one further along stays, and nobody else's can be touched")

        Settings.resetKeys()
        check(Settings.key("ping") == "z" && keyActions.count == 10, "keys have defaults")
        Settings.bind("ping", "x")
        let moved = Settings.key("ping") == "x"
        Settings.bind("undo", "x")
        check(moved && Settings.key("undo") == "x" && Settings.key("ping") == "", "a key moves between actions: one key per action")
        Settings.resetKeys()
        check(Settings.key("ping") == "z" && Settings.key("undo") == "backspace", "and reset brings the defaults back")
        print(ok ? "POLISH TEST PASSED" : "POLISH TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_MINETEST=1: land mines — laid by Engineers, hidden from the enemy, in nobody's way, gone when they go
    /// off — matching linux/tests/test_mines.py.
    /// FC_SELLTEST=1: cancelling a building under construction and selling a finished one — matching
    /// linux/tests/test_sell.py.
    static func runSellTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func setup() -> (SWorld, SBuilding) {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal, seed: 3)
            for u in w.units { u.command(.idle) }
            w.resources[0] = 5000; w.gas[0] = 100
            return (w, w.buildings.first { $0.team == 0 && $0.kind == .hq }!)
        }
        func stand(_ w: SWorld, _ k: BuildingKind, _ x: Double, _ y: Double, _ team: Int = 0) -> SBuilding {
            w.startBuilding(k, x, y, team)
            let b = w.buildings.last!
            b.built = true; b.progress = 1; b.hp = b.maxHp
            return b
        }
        func run(_ w: SWorld, _ secs: Double, until done: () -> Bool = { false }) -> Bool {
            var t = 0.0
            while t < secs { w.step(1.0 / 30); if done() { return true }; t += 1.0 / 30 }
            return done()
        }
        do {
            let (w, hq) = setup()
            _ = stand(w, .barracks, hq.x + 400, hq.y - 250)
            _ = stand(w, .factory, hq.x + 400, hq.y + 250)
            let e = w.units.first { $0.team == 0 && $0.kind == .worker }!
            w.updateVisibility()
            var spot: (Double, Double)? = nil
            outer: for dx in stride(from: -300.0, through: 300, by: 50) {
                for dy in stride(from: -300.0, through: 300, by: 50) where w.canPlace(.artillery, hq.x + dx, hq.y + dy) && w.fogFor(0).isExplored(hq.x + dx, hq.y + dy) {
                    spot = (hq.x + dx, hq.y + dy); break outer
                }
            }
            w.apply(0, ["build", e.id, "artillery", spot!.0, spot!.1, false])
            _ = run(w, 40) { w.buildings.contains { $0.kind == .artillery } }
            let site = w.buildings.first { $0.kind == .artillery }!
            _ = run(w, BuildingKind.artillery.stats.buildTime * 0.4)
            let partWay = site.progress > 0.3 && site.progress < 0.5 && !site.built
            let c0 = w.resources[0]!, g0 = w.gas[0]!
            w.apply(0, ["cancelbuild", site.id])
            let gone = site.dead && !w.buildings.contains { $0 === site } && w.byId[site.id] == nil
            let crystalBack = abs(w.resources[0]! - c0 - Double(BuildingKind.artillery.stats.cost) * (1 - site.progress)) <= 1
            let gasBack = abs(w.gas[0]! - g0 - Double(gasBuild[.artillery]!) * (1 - site.progress)) <= 1
            let said = w.events.contains { jStr($0.first) == "msg" && jStr($0[2]).contains("cancelled") }
            _ = run(w, 1)
            var free = true
            if case .build = e.order { free = false }
            check(partWay && gone && crystalBack && gasBack && said && free, "cancelling a site returns what has not been built yet")
        }
        do {
            let (w, hq) = setup()
            let bk = stand(w, .barracks, hq.x + 400, hq.y)
            _ = w.train(.marine, [bk], 0)
            w.apply(0, ["upgrade", [bk.id], "hp"])
            let c0 = w.resources[0]!, g0 = w.gas[0]!
            let noCancel = !w.cancelBuilding(bk)
            w.apply(0, ["sell", bk.id])
            let back = Double(Int(Double(BuildingKind.barracks.stats.cost) * sellFraction) + UnitKind.marine.stats.cost + UpgradeKind.hp.cost(for: .barracks))
            check(noCancel && w.resources[0] == c0 + back && w.gas[0] == g0 && bk.dead, "selling a finished building pays half and refunds its work")
        }
        do {
            let (w, hq) = setup()
            let enemy = w.buildings.first { $0.team == 1 && $0.kind == .hq }!
            w.apply(0, ["sell", enemy.id])
            w.startBuilding(.depot, hq.x + 300, hq.y, 0)
            let site = w.buildings.last!
            let noSell = !w.sellBuilding(site)
            w.apply(1, ["cancelbuild", site.id])
            check(!enemy.dead && noSell && !site.dead, "selling is yours alone, and a site cannot be sold")
            for b in w.buildings where b.team == 0 && b !== hq { b.dead = true }
            w.cleanupDead()
            w.apply(0, ["sell", hq.id])
            _ = run(w, 0.2)
            check(!(w.players[0]!.alive) && w.gameOver, "selling the last Command Center is the end")
        }
        print(ok ? "SELL TEST PASSED" : "SELL TEST FAILED")
        exit(ok ? 0 : 1)
    }

    static func runMineTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func fresh() -> (SWorld, SBuilding) {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal, seed: 3)
            for u in w.units { u.command(.idle) }
            return (w, w.buildings.first { $0.team == 0 && $0.kind == .hq }!)
        }
        func unit(_ w: SWorld, _ k: UnitKind, _ team: Int, _ x: Double, _ y: Double) -> SUnit {
            let u = SUnit(world: w, kind: k, team: team, x: x, y: y)
            w.add(u); u.command(.idle); u.cooldown = 1e9
            return u
        }
        func lay(_ w: SWorld, _ x: Double, _ y: Double, team: Int = 0) -> SBuilding {
            w.startBuilding(.mine, x, y, team)
            let m = w.buildings.last!
            m.built = true; m.progress = 1; m.hp = m.maxHp
            return m
        }
        func run(_ w: SWorld, _ secs: Double, until done: () -> Bool = { false }) -> Bool {
            var t = 0.0
            while t < secs { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30; if done() { return true } }
            return done()
        }
        let s = BuildingKind.mine.stats
        check(NetProtocol.buildingKinds.contains(.mine) && s.requires == .barracks && s.cost == 40
              && !BuildingKind.allCases.filter({ $0 != .mine }).contains { $0.stats.hotkey == s.hotkey },
              "the mine is in the catalogue on the Engineer card")
        do {
            let (w, hq) = fresh()
            w.startBuilding(.barracks, hq.x + 300, hq.y, 0)
            let bk = w.buildings.last!; bk.built = true; bk.progress = 1
            let e = w.units.first { $0.team == 0 && $0.kind == .worker }!
            w.resources[0] = 500
            w.apply(0, ["build", e.id, "mine", hq.x + 200, hq.y + 200, false])
            var ordered = false
            if case .build(let k, _, _) = e.order, k == .mine { ordered = true }
            let paid = w.resources[0] == 500 - Double(s.cost)
            let built = run(w, 20) { w.buildings.contains { $0.kind == .mine && $0.built } }
            let m = w.buildings.first { $0.kind == .mine }!
            let foe = unit(w, .marine, 1, m.x + 150, m.y)
            w.updateVisibility()
            let hidden = w.sees(0, m) && !w.sees(1, m) && !m.targetable(by: 1)
            let untargeted = !(w.findTarget(foe, 400) === m) && !(w.primaryTarget(1, foe.x, foe.y) === m)
            check(ordered && paid && built && hidden && untargeted, "an Engineer lays a mine and the enemy never sees it")
        }
        do {
            let (w, hq) = fresh()
            let m = lay(w, hq.x + 400, hq.y + 400)
            let own = unit(w, .marine, 0, m.x + 5, m.y)
            _ = unit(w, .gunship, 1, m.x, m.y)
            _ = run(w, 1)
            let quiet = !m.dead
            let foe = unit(w, .marine, 1, m.x + mineTrigger + 100, m.y)
            let far = unit(w, .tank, 1, m.x + mineSplash + 200, m.y)
            let (hp0, own0, far0) = (foe.hp, own.hp, far.hp)
            foe.x = m.x + mineTrigger - 1
            _ = run(w, 0.5)
            check(quiet && m.dead && !w.buildings.contains { $0 === m } && foe.hp <= hp0 - mineDamage * 0.5 && own.hp == own0 && far.hp == far0,
                  "the first hostile on the ground sets it off; friends and aircraft do not")
        }
        do {
            let (w, hq) = fresh()
            _ = lay(w, hq.x + 300, hq.y)
            w.rebuildNavForTests()
            let u = unit(w, .marine, 0, hq.x + 200, hq.y)
            u.command(.move(hq.x + 400, hq.y))
            _ = run(w, 6)
            let through = abs(u.x - (hq.x + 400)) < 20 && abs(u.y - hq.y) < 20
            for b in w.buildings where b.team == 1 { b.dead = true }
            _ = lay(w, hq.x - 300, hq.y, team: 1)
            w.cleanupDead()
            w.checkVictoryForTests()
            check(through && !(w.players[1]!.alive) && w.gameOver && w.winnerTeam == w.players[0]!.team,
                  "mines are in nobody's way and do not keep a side alive")
        }
        do {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal, seed: 3)
            let ai = SAI(world: w, team: 1, opening: "turtle")
            let hq = w.buildings.first { $0.team == 1 && $0.kind == .hq }!
            w.startBuilding(.barracks, hq.x - 300, hq.y, 1)
            let bk = w.buildings.last!; bk.built = true; bk.progress = 1
            w.resources[1] = 3000
            w.elapsed = 400
            ai.hitAt = w.elapsed
            let bases = w.buildings.filter { $0.team == 1 }
            let workers = w.units.filter { $0.team == 1 && $0.kind == .worker }
            ai.fortify(hq, bases, workers)
            var walls = 0, mines = 0
            for wk in workers { for o in [wk.order] + wk.queued { if case .build(let k, _, _) = o { if k == .wall { walls += 1 }; if k == .mine { mines += 1 } } } }
            check(walls > 0 && mines >= 1, "the computer mines the gap in its wall")
        }
        print(ok ? "MINE TEST PASSED" : "MINE TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_WALLTEST=1: Barricades block the way until they are shot down; the computer still attacks a walled base —
    /// matching linux/tests/test_walls.py.
    static func runWallTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func fresh(ai: Bool = false) -> SWorld {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: ai && $0 > 0, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal)
            for u in w.units { u.command(.idle) }
            return w
        }
        func wallLine(_ w: SWorld, x: Double, from y0: Double, to y1: Double, team: Int) -> [SBuilding] {
            var out: [SBuilding] = []
            var y = y0
            while y <= y1 {
                w.startBuilding(.wall, x, y, team)
                let b = w.buildings.last!
                b.built = true; b.progress = 1
                out.append(b)
                y += Double(BuildingKind.wall.stats.half) * 2
            }
            w.rebuildNavForTests()
            return out
        }
        let s = BuildingKind.wall.stats
        check(s.cost <= 40 && s.hp >= 500 && s.half <= 24 && s.requires == nil && NetProtocol.buildingKinds.suffix(3) == [.wall, .mine, .refinery], "the Barricade is cheap, tough and late on the wire")
        let w = fresh()
        let hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
        let x = hq.x + 500
        let walls = wallLine(w, x: x, from: 0, to: worldH, team: 0)          // edge to edge: no way round
        check(walls.count >= 60 && !w.nav.reaches(hq.x, hq.y, x + 200, hq.y), "a run of Barricades blocks the way")
        for b in walls { b.takeDamage(99999, from: nil) }
        w.cleanupDeadForTests()
        w.rebuildNavForTests()
        check(w.nav.reaches(hq.x, hq.y, x + 200, hq.y), "until it is shot down")
        let w2 = fresh()
        let hq2 = w2.buildings.first { $0.team == 0 && $0.kind == .hq }!
        let x2 = hq2.x + 500
        let walls2 = wallLine(w2, x: x2, from: hq2.y - 400, to: hq2.y + 400, team: 0)
        let hp0 = walls2.reduce(0.0) { $0 + $1.hp }
        let t = SUnit(world: w2, kind: .tank, team: 1, x: x2 + 300, y: hq2.y)
        w2.add(t)
        t.command(.amove(hq2.x, hq2.y))
        var el = 0.0
        while el < 25 { w2.step(1.0 / 30); w2.events.removeAll(); el += 1.0 / 30 }
        let hpNow = walls2.filter { !$0.dead }.reduce(0.0) { $0 + $1.hp }
        check(hpNow < hp0 - 100 && t.x > x2, "an attacker walks up to the wall and shoots it, not through it")
        let w3 = fresh(ai: true)
        let ai = w3.players[1]!.ai!
        let hq3 = w3.buildings.first { $0.team == 0 && $0.kind == .hq }!
        _ = wallLine(w3, x: hq3.x + 500, from: 0, to: worldH, team: 0)      // edge to edge: the base is walled off
        let hqE = w3.buildings.first { $0.team == 1 && $0.kind == .hq }!
        let cut = !w3.nav.reaches(hqE.x, hqE.y, hq3.x, hq3.y)
        ai.forceRouteCheck()
        var el3 = 0.0
        while el3 < 7 { w3.step(1.0 / 30); w3.events.removeAll(); el3 += 1.0 / 30 }
        check(cut && ai.routeOpen && ai.routeBridge == nil, "the computer still attacks a walled base: nothing to rebuild, so the wave goes")
        print(ok ? "WALL TEST PASSED" : "WALL TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_AIRTEST=1: the Gunship flies straight over walls, tanks cannot shoot it, and it passes over ground
    /// units without pushing them — matching linux/tests/test_gunship.py.
    static func runAirTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func fresh() -> (SWorld, SBuilding) {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal)
            for u in w.units { u.command(.idle) }
            return (w, w.buildings.first { $0.team == 0 && $0.kind == .hq }!)
        }
        func run(_ w: SWorld, _ seconds: Double) { var t = 0.0; while t < seconds { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 } }
        let s = UnitKind.gunship.stats
        check(s.flies && s.hitsAir && s.requires == .radar && s.speed > UnitKind.marine.stats.speed
              && BuildingKind.factory.stats.produces.contains(.gunship) && NetProtocol.unitKinds.last == .gunship
              && !UnitKind.tank.stats.hitsAir && UnitKind.marine.stats.hitsAir && airGuns == [.turret, .hq], "the Gunship is in the catalogue: flies, trained at the Factory after a Radar")
        do {
            let (w, hq) = fresh()
            let x = hq.x + 500
            var y = 0.0
            while y <= worldH { w.startBuilding(.wall, x, y, 1); w.buildings.last!.built = true; w.buildings.last!.progress = 1; y += Double(BuildingKind.wall.stats.half) * 2 }
            w.rebuildNavForTests()
            let ship = SUnit(world: w, kind: .gunship, team: 0, x: hq.x, y: hq.y + 300)
            let tank = SUnit(world: w, kind: .tank, team: 0, x: hq.x, y: hq.y - 300)
            w.add(ship); w.add(tank)
            ship.command(.move(x + 400, hq.y + 300))
            tank.command(.move(x + 400, hq.y - 300))
            run(w, 12)
            check(ship.x > x + 300 && ship.path == nil && tank.x < x, "it flies straight over a wall that stops a tank")
        }
        do {
            let (w, hq) = fresh()
            let ship = SUnit(world: w, kind: .gunship, team: 1, x: hq.x + 400, y: hq.y + 500)
            w.add(ship); ship.command(.idle)
            let tank = SUnit(world: w, kind: .tank, team: 0, x: hq.x + 400, y: hq.y + 380)
            w.add(tank); tank.command(.idle)
            w.updateVisibility()
            let tankBlind = w.findTarget(tank, 400) == nil
            let ranger = SUnit(world: w, kind: .marine, team: 0, x: hq.x + 400, y: hq.y + 400)
            w.add(ranger); ranger.command(.idle)
            let rangerSees = w.findTarget(ranger, 400) === ship
            w.startBuilding(.turret, hq.x + 400, hq.y + 300, 0)
            let t = w.buildings.last!; t.built = true
            w.startBuilding(.artillery, hq.x + 600, hq.y + 300, 0)
            let a = w.buildings.last!; a.built = true
            check(tankBlind && rangerSees && t.hitsAir && w.findTarget(t, 400) === ship && !a.hitsAir && w.findTarget(a, 600) == nil,
                  "tanks and artillery cannot shoot it; Rangers and turrets can")
        }
        do {
            let (w, hq) = fresh()
            let crowd = (0..<6).map { SUnit(world: w, kind: .marine, team: 0, x: hq.x + 300 + Double($0) * 22, y: hq.y + 400) }
            for u in crowd { w.add(u); u.command(.idle) }
            let before = crowd.map { ($0.x, $0.y) }
            let ship = SUnit(world: w, kind: .gunship, team: 0, x: hq.x + 100, y: hq.y + 400)
            w.add(ship)
            ship.command(.move(hq.x + 700, hq.y + 400))
            run(w, 6)
            let still = zip(crowd, before).allSatisfy { hypot($0.x - $1.0, $0.y - $1.1) < 1 }
            check(ship.x > hq.x + 600 && still, "it passes over ground units without pushing them")
        }
        do {
            let (w, hq0) = fresh()
            let ai = SAI(world: w, team: 1)
            let hq = w.buildings.first { $0.team == 1 && $0.kind == .hq }!
            _ = hq0
            for u in w.units { u.command(.idle) }
            let tank = SUnit(world: w, kind: .tank, team: 1, x: hq.x - 200, y: hq.y + 100)
            let ranger = SUnit(world: w, kind: .marine, team: 1, x: hq.x - 240, y: hq.y + 100)
            for u in [tank, ranger] { w.add(u); u.command(.idle) }
            let ship = SUnit(world: w, kind: .gunship, team: 0, x: hq.x - 400, y: hq.y - 300)
            w.add(ship); ship.command(.idle)
            let bases = w.buildings.filter { $0.team == 1 }
            ai.defend(bases, [tank, ranger])
            var rangerGoes = false
            if case .amove = ranger.order { rangerGoes = true }
            let alarm = ai.airAlarm.map { abs($0.0 - ship.x) < 1 } ?? false
            w.startBuilding(.barracks, hq.x + 300, hq.y, 1)
            let bk = w.buildings.last!
            bk.built = true; bk.progress = 1; bk.hp = bk.maxHp
            for dy in [-250.0, 250.0] {                                     // supply in hand, so the alarm comes first
                w.startBuilding(.depot, hq.x + 300, hq.y + dy, 1)
                let d = w.buildings.last!
                d.built = true; d.progress = 1; d.hp = d.maxHp
            }
            w.resources[1] = 1000
            let workers = w.units.filter { $0.team == 1 && $0.kind == .worker }
            ai.constructForTests(hq, w.buildings.filter { $0.team == 1 }, workers)
            var turretNear = false
            for wk in workers { if case .build(let k, let x, let y) = wk.order, k == .turret, hypot(x - ship.x, y - ship.y) < 500 { turretNear = true } }
            check(rangerGoes && tank.order.isIdle && alarm && turretNear, "the computer sends only what can shoot up, and puts a turret by the raided field")
        }
        print(ok ? "AIR TEST PASSED" : "AIR TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_ICONSOAK=1: minutes of a real game through the real client, selecting everything in turn; every
    /// command-card icon must still render as a picture in the view each time (linux/tests/test_ux.py has the same).
    static func runIconSoak() -> Never {
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 1400, height: 880))
        let scene = GameScene(size: view.bounds.size, difficulty: .normal)
        view.presentScene(scene)
        if !scene.didSetup { scene.didMove(to: view) }
        var rng = SeededRNG(5)
        var t: TimeInterval = 1
        var blanks: [String] = [], checks = 0
        var next = 0.0
        while scene.elapsed < 180 {
            t += 1.0 / 60
            scene.update(t)
            guard scene.elapsed >= next else { continue }
            next = Double(scene.elapsed) + 1.5
            let own: [Entity] = (scene.units as [Entity] + scene.buildings as [Entity]).filter { $0.team.isLocal && !$0.dead }
            if let pick = own.randomElement(using: &rng) {
                scene.setSelection(Double.random(in: 0..<1, using: &rng) < 0.7 ? [pick] : Array(own.filter { type(of: $0) == type(of: pick) }.prefix(12)))
            }
            scene.hud.update(0.3, mouse: nil)
            guard let tex = view.texture(from: scene) else { continue }
            let img = tex.cgImage()
            guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { continue }
            let bpp = img.bitsPerPixel / 8, row = img.bytesPerRow
            let sx = CGFloat(img.width) / view.bounds.width, sy = CGFloat(img.height) / view.bounds.height
            for (r, b) in zip(scene.hud.buttonRectsForTests, scene.hud.currentButtonsForTests) {
                checks += 1
                let cx = Int((r.midX + view.bounds.width / 2) * sx), cy = Int((view.bounds.height / 2 - (r.midY + 5)) * sy)
                var colours = Set<UInt32>()
                var yy = cy - 15
                while yy < cy + 15 {
                    var xx = cx - 15
                    while xx < cx + 15 {
                        if xx >= 0 && yy >= 0 && xx < img.width && yy < img.height {
                            let o = yy * row + xx * bpp
                            colours.insert(UInt32(p[o]) << 16 | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]))
                        }
                        xx += 3
                    }
                    yy += 3
                }
                if colours.count < 8 { blanks.append("t=\(Int(scene.elapsed)) \(b.icon) enabled=\(b.enabled) colours=\(colours.count)") }
            }
        }
        print("  icon soak: \(checks) icon checks over \(Int(scene.elapsed))s, \(blanks.count) blank, \(scene.hud.iconRepairs) repairs")
        for line in blanks.prefix(10) { print("  BLANK " + line) }
        let ok = checks > 300 && blanks.isEmpty
        print(ok ? "ICON SOAK PASSED" : "ICON SOAK FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_MODETEST=1: skirmish modes — King of the Hill's ring and timers, Sudden Death's elimination, the
    /// computer's objective, and how the mode travels — matching linux/tests/test_modes.py.
    static func runModeTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func world(_ mode: String) -> SWorld {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal, seed: 4)
            w.mode = mode
            for u in w.units { u.command(.idle) }
            return w
        }
        func run(_ w: SWorld, _ seconds: Double, until: () -> Bool = { false }) -> Bool {
            var t = 0.0
            while t < seconds { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30; if until() { return true } }
            return until()
        }
        check(modes.map { $0.id } == ["annihilation", "koth", "sudden"], "three modes in the catalogue")
        let w = world("koth")
        let (hx, hy) = w.ring
        check(w.crystals.contains { $0.variant == 3 && abs($0.x - hx) < kothRadius && abs($0.y - hy) < kothRadius }, "the ring sits on the gold")
        let r = SUnit(world: w, kind: .marine, team: 0, x: hx, y: hy); w.add(r); r.command(.idle)
        _ = run(w, 3)
        check((w.hold[1] ?? 0) > 2.5 && (w.hold[1] ?? 0) < 3.5 && (w.hold[2] ?? 0) == 0, "an uncontested hold runs the clock")
        let foe = SUnit(world: w, kind: .marine, team: 1, x: hx + 40, y: hy); w.add(foe); foe.command(.idle)
        r.hp = 9999; foe.hp = 9999
        _ = run(w, 0.5)
        check(w.hold[1] == 0 && w.hold[2] == 0, "contested: nobody's clock runs")
        foe.takeDamage(99999, from: nil)
        w.hold[1] = kothHold - 1
        check(run(w, 3) { w.gameOver } && w.winnerTeam == 1, "the first to three minutes wins")
        do {
            let w = world("sudden")
            let hq0 = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
            w.startBuilding(.depot, hq0.x + 300, hq0.y, 0); w.buildings.last!.built = true
            hq0.takeDamage(99999, from: nil)
            _ = run(w, 1)
            check(!w.players[0]!.alive && w.gameOver && w.winnerTeam == 2 && !w.buildings.contains { $0.team == 0 },
                  "Sudden Death knocks out a side with its last Command Center, depot and all")
            let w2 = world("annihilation")
            w2.buildings.first { $0.team == 0 && $0.kind == .hq }!.takeDamage(99999, from: nil)
            w2.startBuilding(.depot, 900, 900, 0); w2.buildings.last!.built = true
            _ = run(w2, 1)
            check(w2.players[0]!.alive, "under the usual rule a depot still stands")
        }
        do {
            let w = world("koth")
            let ai = SAI(world: w, team: 1, opening: "rush")
            let hq0 = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
            let ring = w.ring
            let toRing = ai.objective(hq0).map { $0.0 == ring.0 && $0.1 == ring.1 } ?? false
            w.hold[2] = 30; w.hold[1] = 5
            let toBase = ai.objective(hq0).map { $0.0 == hq0.x && $0.1 == hq0.y } ?? false
            w.hold[2] = 5; w.hold[1] = 30
            let backToRing = ai.objective(hq0).map { $0.0 == ring.0 } ?? false
            check(toRing && toBase && backToRing, "the computer goes for the ring until it leads there")
        }
        do {
            let w = world("koth")
            w.hold[1] = 12.5
            let doc = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: SaveGame.encode(w))) as! [String: Any]
            let w2 = try! SaveGame.decode(doc)
            let rec = try! Replay(try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: Replay.encode(w, viewer: 0))) as! [String: Any])
            check(w2.mode == "koth" && w2.hold[1] == 12.5 && rec.mode == "koth", "the mode travels in saves and replays")
        }
        print(ok ? "MODE TEST PASSED" : "MODE TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_STARTTEST=1: the start of a game — crystal in the bank, an established base, off-map reinforcements
    /// for crystal — matching linux/tests/test_start.py.
    /// FC_ABILITYTEST=1: unit abilities on the server simulation — the Ranger's grenade, the Sniper's mark, the
    /// Siege Tank's smoke, their cooldowns and reach, the wire and the save — matching linux/tests/test_abilities.py.
    /// FC_COUNTERTEST=1: the computer pulls a beaten wave back and counterattacks a repelled threat —
    /// matching linux/tests/test_ai_retreat.py.
    static func runCounterTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func fresh(_ d: Difficulty = .normal) -> (SWorld, SAI, SBuilding) {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: d, seed: 3)
            let ai = SAI(world: w, team: 1)
            return (w, ai, w.buildings.first { $0.team == 1 && $0.kind == .hq }!)
        }
        func unit(_ w: SWorld, _ k: UnitKind, _ team: Int, _ x: Double, _ y: Double) -> SUnit {
            let u = SUnit(world: w, kind: k, team: team, x: x, y: y)
            w.add(u)
            u.command(.idle)
            return u
        }
        do {
            let (w, ai, hq) = fresh()
            let wave = (0..<6).map { unit(w, .marine, 1, hq.x - 900 + Double($0) * 20, hq.y) }
            ai.attackers = wave; ai.launched = 6
            for u in wave.prefix(4) { u.dead = true }
            w.cleanupDead()
            ai.attackers.removeAll { $0.dead }
            ai.retreat(hq)
            let pressed = ai.retreats == 0 && !ai.attackers.isEmpty
            _ = unit(w, .tank, 0, hq.x - 1100, hq.y)
            let before = ai.nextWave
            ai.retreat(hq)
            var home = true
            for u in wave.suffix(2) { if case .move(let x, _) = u.order { home = home && abs(x - hq.x) < 1 } else { home = false } }
            check(pressed && ai.retreats == 1 && ai.attackers.isEmpty && ai.launched == 0 && home && ai.nextWave >= before && ai.nextWave >= w.elapsed + 40,
                  "a wave that has lost most of itself pulls back, and only with the enemy on it")
        }
        do {
            let (w, ai, hq) = fresh()
            let wave = (0..<6).map { unit(w, .marine, 1, hq.x - 900 + Double($0) * 20, hq.y) }
            ai.attackers = wave; ai.launched = 6
            for u in wave.prefix(3) { u.dead = true }
            w.cleanupDead()
            ai.attackers.removeAll { $0.dead }
            _ = unit(w, .tank, 0, hq.x - 1100, hq.y)
            ai.retreat(hq)
            check(ai.retreats == 0 && ai.attackers.count == 3, "a wave still mostly alive keeps going")
        }
        do {
            let (w, ai, hq) = fresh()
            let home = (0..<8).map { unit(w, .marine, 1, hq.x - 150 + Double($0) * 20, hq.y + 100) }
            let bases = w.buildings.filter { $0.team == 1 }
            let raider = unit(w, .marine, 0, hq.x - 500, hq.y)
            ai.defend(bases, home)
            let noticed = ai.threatSeenAt == w.elapsed && !ai.counterPending
            raider.dead = true
            w.cleanupDead()
            ai.setWave(size: 12, next: 1e9)
            ai.defend(bases, home)
            let pending = ai.counterPending
            ai.attack(hq, home)
            var went = true
            for u in home { if case .amove = u.order {} else { went = false } }
            check(noticed && pending && ai.counters == 1 && ai.attackers.count == 8 && went && !ai.counterPending && ai.lastCounter == w.elapsed,
                  "a repelled threat is answered with a counterattack")
            ai.attackers = []
            ai.defend(bases, home)
            _ = unit(w, .marine, 0, hq.x - 500, hq.y)
            ai.defend(bases, home)
            for u in w.units where u.team == 0 { u.dead = true }
            w.cleanupDead()
            ai.defend(bases, home)
            check(!ai.counterPending, "not again for a minute")
        }
        do {
            let (w, ai, hq) = fresh(.easy)
            let home = (0..<5).map { unit(w, .marine, 1, hq.x - 150 + Double($0) * 20, hq.y + 100) }
            let bases = w.buildings.filter { $0.team == 1 }
            let raider = unit(w, .marine, 0, hq.x - 500, hq.y)
            ai.defend(bases, home)
            raider.dead = true
            w.cleanupDead()
            ai.defend(bases, home)
            check(!ai.counterPending, "Easy never counterattacks")
        }
        print(ok ? "COUNTER TEST PASSED" : "COUNTER TEST FAILED")
        exit(ok ? 0 : 1)
    }

    static func runAbilityTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func fresh() -> (SWorld, SBuilding) {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal, seed: 3)
            for u in w.units { u.command(.idle); u.cooldown = 1e9 }        // nobody fires on their own
            return (w, w.buildings.first { $0.team == 0 && $0.kind == .hq }!)
        }
        func unit(_ w: SWorld, _ k: UnitKind, _ team: Int, _ x: Double, _ y: Double, armed: Bool = false) -> SUnit {
            let u = SUnit(world: w, kind: k, team: team, x: x, y: y)
            w.add(u)
            u.command(.idle)
            if !armed { u.cooldown = 1e9 }
            return u
        }
        func run(_ w: SWorld, _ secs: Double) { var t = 0.0; while t < secs { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 } }

        check(abilities.count == 3 && abilities[.marine]?.id == "grenade" && abilities[.sniper]?.id == "mark" && abilities[.tank]?.id == "smoke",
              "Rangers, Snipers and Siege Tanks each have an ability")
        do {
            let (w, hq) = fresh()
            let r = unit(w, .marine, 0, hq.x + 300, hq.y)
            let foes = (0..<3).map { unit(w, .marine, 1, hq.x + 450 + Double($0) * 20, hq.y) }
            let before = foes.map { $0.hp }
            let thrown = w.useAbility(0, [r], hq.x + 470, hq.y) == 1 && r.abilityCd == abilities[.marine]!.cooldown
            run(w, 3)
            let hurt = zip(foes, before).allSatisfy { $0.hp < $1 }
            let again = w.useAbility(0, [r], hq.x + 470, hq.y) == 0
            run(w, abilities[.marine]!.cooldown + 1)
            check(thrown && hurt && again && r.abilityCd == 0 && w.useAbility(0, [r], hq.x + 470, hq.y) == 1,
                  "a grenade bursts where it lands, then recharges")
            check(w.useAbility(0, [r], hq.x + 300 + abilities[.marine]!.reach + 50, hq.y) == 0, "a grenade cannot be thrown beyond its reach")
        }
        do {
            let (w, hq) = fresh()
            let s = unit(w, .sniper, 0, hq.x + 300, hq.y)
            let t = unit(w, .tank, 1, hq.x + 500, hq.y)
            var hp = t.hp
            t.takeDamage(10, from: s)
            let plain = abs(hp - t.hp - 10) < 1e-9
            let marked = w.useAbility(0, [s], t.x, t.y, t.id) == 1 && t.markedUntil > w.elapsed
            hp = t.hp
            t.takeDamage(10, from: s)
            let more = abs(hp - t.hp - 10 * (1 + markBonus)) < 1e-9
            run(w, markDuration + 0.5)
            hp = t.hp
            t.takeDamage(10, from: s)
            check(plain && marked && more && t.markedUntil <= w.elapsed && abs(hp - t.hp - 10) < 1e-9,
                  "a marked target takes half again as much until the mark fades")
            let friend = unit(w, .marine, 0, hq.x + 400, hq.y)
            let far = unit(w, .marine, 1, hq.x + 300 + abilities[.sniper]!.reach + 100, hq.y)
            run(w, abilities[.sniper]!.cooldown + 1)
            check(w.useAbility(0, [s], friend.x, friend.y, friend.id) == 0 && w.useAbility(0, [s], far.x, far.y, far.id) == 0 && s.abilityCd == 0,
                  "a mark needs an enemy in reach")
        }
        do {
            let (w, hq) = fresh()
            let tank = unit(w, .tank, 0, hq.x + 300, hq.y)
            let ranger = unit(w, .marine, 0, hq.x + 330, hq.y)
            let far = unit(w, .sniper, 1, hq.x + 700, hq.y)
            let near = unit(w, .marine, 1, hq.x + 360, hq.y)
            let popped = w.useAbility(0, [tank], 0, 0) == 1 && w.smokes.count == 1 && w.smokes[0].x == tank.x
            var hp = ranger.hp
            ranger.takeDamage(10, from: far)
            let halved = abs(hp - ranger.hp - 10 * smokeFactor) < 1e-9
            hp = ranger.hp
            ranger.takeDamage(10, from: near)
            let pointBlank = abs(hp - ranger.hp - 10) < 1e-9
            let outside = unit(w, .marine, 0, hq.x + 300 + smokeRadius + 40, hq.y)
            hp = outside.hp
            outside.takeDamage(10, from: far)
            let clear = abs(hp - outside.hp - 10) < 1e-9
            run(w, smokeDuration + 0.5)
            hp = ranger.hp
            ranger.takeDamage(10, from: far)
            check(popped && halved && pointBlank && clear && w.smokes.isEmpty && abs(hp - ranger.hp - 10) < 1e-9,
                  "smoke halves ranged damage inside it, not point-blank hits, and clears")
        }
        do {
            let (w, hq) = fresh()
            let s = unit(w, .sniper, 0, hq.x + 300, hq.y)
            let t = unit(w, .tank, 1, hq.x + 500, hq.y)
            let tank = unit(w, .tank, 0, hq.x + 200, hq.y)
            w.apply(0, ["ability", [s.id], t.x, t.y, t.id])
            w.apply(0, ["ability", [tank.id], 0, 0, NSNull()])
            run(w, 0.5)
            let applied = t.markedUntil > w.elapsed && s.abilityCd > 0 && w.smokes.count == 1
            let doc = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: SaveGame.encode(w))) as! [String: Any]
            let w2 = try! SaveGame.decode(doc)
            let s2 = w2.byId[s.id] as! SUnit, t2 = w2.byId[t.id] as! SUnit
            check(applied && w2.smokes.count == 1 && s2.abilityCd > 0 && t2.markedUntil > w2.elapsed,
                  "the ability command goes through the wire and the save")
        }
        do {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: true, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal, seed: 3)
            for u in w.units { u.command(.idle); u.cooldown = 1e9 }
            let hq = w.buildings.first { $0.team == 1 && $0.kind == .hq }!
            let r = unit(w, .marine, 1, hq.x - 300, hq.y, armed: true)
            let sn = unit(w, .sniper, 1, hq.x - 320, hq.y + 40, armed: true)
            let foes = (0..<3).map { unit(w, .marine, 0, hq.x - 450 - Double($0) * 15, hq.y, armed: true) }
            run(w, 2)
            check(r.abilityCd > 0 && sn.abilityCd > 0 && foes.contains { $0.markedUntil > 0 }, "the computer uses its abilities")
        }
        print(ok ? "ABILITY TEST PASSED" : "ABILITY TEST FAILED")
        exit(ok ? 0 : 1)
    }

    static func runStartTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func world(crystal: Int = startCrystal, base: String = "fresh") -> SWorld {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal, seed: 6, startCrystal: crystal, startBase: base)
            for u in w.units { u.command(.idle) }
            return w
        }
        check(startCrystal == 5000 && startCrystalOptions.contains(startCrystal) && world().resources[0] == 5000 && world(crystal: 20000).resources[1] == 20000,
              "starting crystal defaults to 5000 and can be set")
        let fresh = world()
        let w = world(base: "established")
        var layout = fresh.buildings.filter { $0.team == 0 }.count == 1 && established.count == 5
        for slot in 0..<2 {
            let mine = w.buildings.filter { $0.team == slot && $0.built }
            let kinds = mine.map { $0.kind }
            let hq = mine.first { $0.kind == .hq }!
            layout = layout && kinds.filter { $0 == .depot }.count == 2 && kinds.contains(.barracks) && kinds.contains(.factory) && kinds.contains(.turret)
            for b in mine where b.kind != .hq { let d = hypot(b.x - hq.x, b.y - hq.y); layout = layout && d > 150 && d < 420 }
        }
        check(layout && w.supplyCap(0) > fresh.supplyCap(0), "an established base stands from the first second, facing the middle")
        do {
            let w = world()
            let hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
            let before = w.units.count
            w.apply(0, ["reinforce", "marine"])
            let (count, cost) = reinforcements[.marine]!
            let new = w.units.filter { $0.team == 0 && $0.kind == .marine }
            let (ex, ey) = w.edgePoint(0)
            var walking = new.count == count && w.units.count == before + count && w.resources[0] == Double(startCrystal - cost)
            walking = walking && min(ex, ey, worldW - ex, worldH - ey) == 80 && new.allSatisfy { hypot($0.x - ex, $0.y - ey) < 120 }
            for u in new { if case .move(let x, let y) = u.order { let d = hypot(x - hq.x, y - hq.y); walking = walking && d > 150 && d < 300 } else { walking = false } }
            check(walking && w.events.contains { jStr($0.first) == "msg" && jStr($0[2]).contains("Reinforcements") }, "reinforcements walk in from your edge for crystal")
            w.apply(0, ["reinforce", "tank"])
            let tooSoon = !w.units.contains { $0.team == 0 && $0.kind == .tank } && abs(w.reinforceLeft(0) - reinforceCooldown) < 1e-6
            w.elapsed += reinforceCooldown
            w.apply(0, ["reinforce", "tank"])
            let later = w.units.filter { $0.team == 0 && $0.kind == .tank }.count == reinforcements[.tank]!.count
            w.resources[1] = 10
            w.apply(1, ["reinforce", "marine"])
            check(tooSoon && later && !w.units.contains { $0.team == 1 && $0.kind == .marine }, "one call a minute, and only with the crystal")
            let doc = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: SaveGame.encode(w))) as! [String: Any]
            let w2 = try! SaveGame.decode(doc)
            let rec = try! Replay(try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: Replay.encode(w, viewer: 0))) as! [String: Any])
            check(w2.startCrystal == startCrystal && w2.reinforceLeft(0) > 0 && rec.startCrystal == startCrystal && rec.startBase == "fresh",
                  "the setup and the cooldown travel in saves and replays")
        }
        print(ok ? "START TEST PASSED" : "START TEST FAILED")
        exit(ok ? 0 : 1)
    }

    static func runReplayTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func fresh(_ seed: UInt64) -> SWorld {
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: $0 > 0, start: $0) }
            return SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal, seed: seed)
        }
        func signature(_ w: SWorld) -> String {
            let u = w.units.filter { !$0.dead }.map { "\($0.id):\(NetProtocol.name($0.kind)):\($0.team):\(Int($0.x * 100)):\(Int($0.y * 100)):\(Int($0.hp * 100)):\($0.order.code)" }
            let b = w.buildings.filter { !$0.dead }.map { "\($0.id):\(NetProtocol.name($0.kind)):\(Int($0.hp * 100)):\($0.built):\($0.queue.count)" }
            let r = w.resources.keys.sorted().map { "\($0)=\(Int(w.resources[$0]! * 100))" }
            return "\(w.tick)|\(u)|\(b)|\(r)|\(w.crates.count)"
        }
        func scripted(_ w: SWorld) {
            let hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
            let eng = w.units.filter { $0.team == 0 && $0.kind == .worker }
            for t in 1...(30 * 90) {
                if t == 10 { w.apply(0, ["train", [hq.id], "worker"]) }
                if t == 40 { w.apply(0, ["build", eng[0].id, "barracks", hq.x + 300, hq.y, false]) }
                if t == 900 { w.apply(0, ["move", [eng[1].id, eng[2].id], hq.x + 500, hq.y + 200, false, false]) }
                w.step(1.0 / 30); w.events.removeAll()
            }
        }
        let a = fresh(7), b = fresh(7), c = fresh(8)
        scripted(a); scripted(b); scripted(c)
        check(signature(a) == signature(b), "the same seed and commands give the same game")
        if signature(a) != signature(b) {
            // Say where the two runs part ways: the first tick whose signatures differ, and the first differing entry.
            let x = fresh(7), y = fresh(7)
            let hq = x.buildings.first { $0.team == 0 && $0.kind == .hq }!
            let ex = x.units.filter { $0.team == 0 && $0.kind == .worker }, ey = y.units.filter { $0.team == 0 && $0.kind == .worker }
            for t in 1...(30 * 90) {
                if t == 10 { x.apply(0, ["train", [hq.id], "worker"]); y.apply(0, ["train", [hq.id], "worker"]) }
                if t == 40 { x.apply(0, ["build", ex[0].id, "barracks", hq.x + 300, hq.y, false]); y.apply(0, ["build", ey[0].id, "barracks", hq.x + 300, hq.y, false]) }
                if t == 900 { x.apply(0, ["move", [ex[1].id, ex[2].id], hq.x + 500, hq.y + 200, false, false]); y.apply(0, ["move", [ey[1].id, ey[2].id], hq.x + 500, hq.y + 200, false, false]) }
                x.step(1.0 / 30); x.events.removeAll(); y.step(1.0 / 30); y.events.removeAll()
                let sx = signature(x).split(separator: ","), sy = signature(y).split(separator: ",")
                if sx != sy {
                    print("  first divergence at tick \(t)")
                    for (i, pair) in zip(sx, sy).enumerated() where pair.0 != pair.1 { print("    [\(i)] \(pair.0)  vs  \(pair.1)"); break }
                    if sx.count != sy.count { print("    counts \(sx.count) vs \(sy.count)") }
                    break
                }
            }
        }
        check(signature(a) != signature(c), "a different seed gives a different one")
        check(a.record.count == 3, "only people's commands are recorded (\(a.record.count))")
        let doc = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: Replay.encode(a, viewer: 0))) as! [String: Any]
        guard let rec = try? Replay(doc) else { print("  FAIL replay decode"); exit(1) }
        let ps = rec.players.map { SPlayer(slot: $0.slot, name: $0.name, team: $0.team, isAI: $0.ai, start: $0.slot) }
        let d = SWorld(map: SMapGen.generate(rec.map), players: ps, difficulty: Difficulty(rawValue: rec.difficulty) ?? .normal, seed: rec.seed)
        while d.tick < a.tick {
            while rec.next < rec.commands.count, rec.commands[rec.next].0 <= d.tick {
                d.applyQuietly(rec.commands[rec.next].1, rec.commands[rec.next].2)
                rec.next += 1
            }
            d.step(1.0 / 30); d.events.removeAll()
        }
        check(signature(d) == signature(a), "a recorded game replays exactly")
        // The browser's view of a recording: filed by date and map, with its result; the oldest are pruned.
        check(Replay.name(for: a, at: Date(timeIntervalSince1970: 0)).hasSuffix("_twin_ridges"), "a recording is filed by date and map")
        let url = try! Replay.write(a, viewer: 0)
        let newest = Replay.list().first!
        check(url.lastPathComponent == newest.name + ".json" && newest.map == "twin_ridges" && newest.result == "Unfinished" && newest.difficulty == 1,
              "and the browser reads its map, length and result")
        for i in 0..<(Replay.keep + 3) { _ = try? Replay.write(a, name: String(format: "old%03d", i), viewer: 0) }
        check(Replay.list().count == Replay.keep, "the oldest recordings are pruned past \(Replay.keep)")
        var doc2 = Replay.encode(a, viewer: 0)
        doc2["winner_team"] = 1
        check(Replay.result(of: doc2) == "Won" && Replay.result(of: { var d = doc2; d["viewer"] = 1; return d }()) == "Lost", "won or lost is read from the viewer's side")
        Settings.career = [:]
        Settings.recordResult(won: true, difficulty: 1); Settings.recordResult(won: true, difficulty: 2); Settings.recordResult(won: false, difficulty: 1)
        let cr = Settings.career
        check(cr["wins"] == 2 && cr["losses"] == 1 && cr["wins_1"] == 1 && cr["wins_2"] == 1 && cr["losses_1"] == 1
              && Settings.careerText == "Career: 2 won · 1 lost · 66%", "the career record counts wins and losses by difficulty")
        Settings.career = [:]
        print(ok ? "REPLAY TEST PASSED" : "REPLAY TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_CAMPAIGNTEST=1: the mission rules — survive wins when the clock runs out, hold counts only while the
    /// ring is yours and clear, progress and the mission travel in snapshots and saves.
    static func runCampaignTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func world(_ id: String) -> (SWorld, Mission) {
            let m = missionNamed(id)!
            let spec = SMapGen.resolve(m.map, players: 1 + m.opponents)
            let ps = (0..<(1 + m.opponents)).map { SPlayer(slot: $0, name: "P\($0)", team: m.teams >= 2 ? $0 % m.teams + 1 : $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: spec, players: ps, difficulty: Difficulty(rawValue: m.difficulty) ?? .normal)
            w.mission = m
            for u in w.units { u.command(.idle) }
            return (w, m)
        }
        func run(_ w: SWorld, _ seconds: Double, until: () -> Bool = { false }) -> Bool {
            var t = 0.0
            while t < seconds { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30; if until() { return true } }
            return until()
        }
        check(campaign.count == 5 && Set(campaign.map { $0.id }).count == 5, "five missions with distinct ids")
        check(campaign.allSatisfy { (SMapGen.info($0.map)?.players ?? 0) >= 1 + $0.opponents && (($0.win == "hold") == ($0.hold != nil)) }, "each on a map that fits it")
        do {
            let (w, m) = world("hold_the_line")
            w.elapsed = m.seconds - 2
            check(run(w, 4) { w.gameOver } && w.winnerTeam == w.players[0]!.team, "survive is won when the clock runs out and you still stand")
        }
        do {
            let (w, m) = world("gold_run")
            let (hx, hy, hr) = m.hold!
            check(w.crystals.contains { $0.variant == 3 && abs($0.x - hx) < hr && abs($0.y - hy) < hr }, "the gold is inside the hold ring")
            let r = SUnit(world: w, kind: .marine, team: 0, x: hx, y: hy); w.add(r); r.command(.idle)
            _ = run(w, 3)
            check(w.missionTimer > 2.5 && w.missionTimer < 3.5, "holding the ring runs the clock")
            let foe = SUnit(world: w, kind: .marine, team: 1, x: hx + 40, y: hy); w.add(foe); foe.command(.idle)
            r.hp = 9999
            _ = run(w, 0.5)
            check(w.missionTimer == 0, "an enemy in the ring resets it")
            foe.takeDamage(99999, from: nil)
            w.missionTimer = m.seconds - 1
            check(run(w, 3) { w.gameOver } && w.winnerTeam == w.players[0]!.team, "and the hold is won once the count is full")
        }
        do {
            let (w, _) = world("hold_the_line")
            w.elapsed = 100
            check(Int(w.missionProgress()) == 100, "progress is the clock for a survive mission")
            let doc = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: SaveGame.encode(w))) as! [String: Any]
            let w2 = try! SaveGame.decode(doc)
            check(w2.mission?.id == "hold_the_line", "the mission survives a save")
        }
        // The script (1.21): Command speaks, columns come in from the map edge, enemies attack-move on their target.
        check(campaign.allSatisfy { m in !m.events.isEmpty && m.events.map { $0.at } == m.events.map { $0.at }.sorted() }, "every mission has a script in clock order")
        func quiet(_ id: String) -> (SWorld, Mission) {
            let (w, m) = world(id)
            for p in w.players.values { p.ai = nil }
            return (w, m)
        }
        func fireNext(_ w: SWorld, _ m: Mission) -> (MissionEvent, [SUnit]) {
            let ev = m.events[w.missionFired]
            w.elapsed = ev.at - 1.0 / 60
            let before = Set(w.units.map { $0.id })
            w.events.removeAll()
            w.step(1.0 / 30)
            return (ev, w.units.filter { !before.contains($0.id) })
        }
        func said(_ w: SWorld, _ text: String, _ tone: String) -> Bool {
            w.events.contains { e in jStr(e.first) == "msg" && jStr(e[2]) == text && jStr(e[3]) == tone }
        }
        do {
            let (w, m) = quiet("first_light")
            var (ev, new) = fireNext(w, m)
            check(ev.kind == "text" && new.isEmpty && said(w, ev.text, "good"), "Command speaks on the clock")
            (ev, new) = fireNext(w, m)
            let (ex, ey) = w.edgePoint(0)
            let onEdge = min(ex, ey, worldW - ex, worldH - ey) == 80
            check(ev.kind == "spawn" && new.count == ev.count && new.allSatisfy { $0.team == 0 && NetProtocol.name($0.kind) == ev.unit }, "reinforcements arrive")
            check(onEdge && new.allSatisfy { hypot($0.x - ex, $0.y - ey) < 120 }, "on the map edge nearest your start")
            let hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
            var walkHome = !new.isEmpty
            for u in new { if case .move(let x, let y) = u.order { walkHome = walkHome && hypot(x - hq.x, y - hq.y) > 150 && hypot(x - hq.x, y - hq.y) < 300 } else { walkHome = false } }
            check(walkHome && said(w, ev.text, "good") && w.missionFired == 2, "and walk home, stopping short of the Command Center")
        }
        do {
            let (w, m) = quiet("hold_the_line")
            while m.events[w.missionFired].owner != 1 { _ = fireNext(w, m) }
            let (ev, new) = fireNext(w, m)
            let hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
            var onUs = new.count == ev.count
            for u in new { if case .amove(let x, let y) = u.order { onUs = onUs && x == hq.x && y == hq.y && u.team == 1 } else { onUs = false } }
            check(onUs && said(w, ev.text, "bad"), "an enemy column attack-moves on your Command Center")
            let (w2, m2) = quiet("gold_run")
            while m2.events[w2.missionFired].kind != "spawn" { _ = fireNext(w2, m2) }
            let (ev2, new2) = fireNext(w2, m2)
            var onRing = ev2.target == -1 && !new2.isEmpty
            for u in new2 { if case .amove(let x, let y) = u.order { onRing = onRing && x == m2.hold!.0 && y == m2.hold!.1 } else { onRing = false } }
            check(onRing, "target -1 sends it at the hold ring")
            let (w3, m3) = quiet("crossfire")
            while m3.events[w3.missionFired].kind != "spawn" { _ = fireNext(w3, m3) }
            let (ev3, new3) = fireNext(w3, m3)
            let ally = w3.buildings.first { $0.team == 2 && $0.kind == .hq }!
            var onAlly = ev3.target == 2 && !new3.isEmpty
            for u in new3 { if case .amove(let x, let y) = u.order { onAlly = onAlly && x == ally.x && y == ally.y && u.team == 1 } else { onAlly = false } }
            check(onAlly, "and a raid on your ally goes for their Command Center")
        }
        do {
            let (w, m) = quiet("first_light")
            _ = fireNext(w, m); _ = fireNext(w, m)
            let doc = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: SaveGame.encode(w))) as! [String: Any]
            let w2 = try! SaveGame.decode(doc)
            w2.elapsed = 1000
            w2.step(1.0 / 30)
            check(w2.missionFired == m.events.count, "the script's position survives a save and carries on")
        }
        // The briefing's words match the Python edition's.
        check(MenuScene.objectiveText(campaign[1]) == "Be standing after 8:00" && MenuScene.objectiveText(campaign[2]) == "Hold the ring for 3:00 with no enemy inside"
              && MenuScene.objectiveText(campaign[0]) == "Destroy every enemy building", "the briefing states the objective")
        let tl = MenuScene.timeline(campaign[1])
        check(tl.count == campaign[1].events.count && tl[0] == ("0:10", "Word from Command") && tl[1] == ("1:30", "Reinforcements arrive")
              && tl[2] == ("2:30", "Enemy column on the move"), "and the timeline")
        let ts = MenuScene.mapThumb(campaign[1], width: 300).size()
        check(ts.width == 600 && ts.height > 200, "with a map of the mission (rendered at 2x: \(Int(ts.width))x\(Int(ts.height)))")
        print(ok ? "CAMPAIGN TEST PASSED" : "CAMPAIGN TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_CRATETEST=1: supply crates drop on open ground, are collected by the first unit to reach them, give
    /// crystal or troops to that side, expire, and survive a save.
    static func runCrateTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        let w = SWorld(map: SMapGen.generate("twin_ridges"),
                       players: [SPlayer(slot: 0, name: "P0", team: 1, isAI: false, start: 0),
                                 SPlayer(slot: 1, name: "P1", team: 2, isAI: false, start: 1)], difficulty: .normal)
        for u in w.units { u.command(.idle) }
        var heard: [[Any]] = []
        func run(_ seconds: Double, until: () -> Bool = { false }) {
            var t = 0.0
            while t < seconds {
                w.step(1.0 / 30)
                heard += w.events.filter { jStr($0.first) == "crate" }
                w.events.removeAll()
                t += 1.0 / 30
                if until() { return }
            }
        }
        run(crateFirst + 1)
        check(w.crates.count == 1, "the first crate drops at \(Int(crateFirst))s")
        if let c = w.crates.first {
            // Spelled out in steps: one long expression here defeats older compilers' type checker.
            let openGround = !w.nav.isBlocked(Int(c.x / 40), Int(c.y / 40))
            func near(_ b: SBuilding) -> Bool {
                let dx: Double = b.x - c.x
                let dy: Double = b.y - c.y
                return (dx * dx + dy * dy).squareRoot() < 600
            }
            let clear = openGround && !w.buildings.contains(where: near)
            check(clear, "on open ground away from every base")
        }
        let cash = w.dropCrate(kind: "crystal")!
        let bank = w.resources[0] ?? 0
        let runner = SUnit(world: w, kind: .marine, team: 0, x: cash.x + 60, y: cash.y); w.add(runner)
        runner.command(.move(cash.x, cash.y))
        run(6) { cash.dead }
        check(cash.dead && (w.resources[0] ?? 0) == bank + Double(cash.amount), "the first unit to reach a crystal crate banks \(cash.amount)")
        let squad = w.dropCrate(kind: "squad")!
        let before = w.units.filter { $0.team == 0 && $0.kind == .marine }.count
        let r2 = SUnit(world: w, kind: .worker, team: 0, x: squad.x + 60, y: squad.y); w.add(r2)
        r2.command(.move(squad.x, squad.y))
        heard = []
        run(6) { squad.dead }
        check(squad.dead && w.units.filter { $0.team == 0 && $0.kind == .marine }.count == before + crateSquad, "a squad crate spawns \(crateSquad) Rangers for the taker's side")
        check(heard.first.map { jInt($0[1]) == 0 && jStr($0[4]) == "squad" } ?? false, "and the pickup is an event")
        let old = w.dropCrate(kind: "tank")!
        run(crateLife + 2)
        check(old.dead, "a crate nobody reaches expires after \(Int(crateLife))s")
        let far = w.dropCrate(kind: "crystal")!
        let doc = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: SaveGame.encode(w))) as! [String: Any]
        let w2 = try! SaveGame.decode(doc)
        check(w2.crates.contains { $0.id == far.id && $0.kind == "crystal" && $0.amount == far.amount } && w2.nextCrate == w.nextCrate, "crates survive a save")
        print(ok ? "CRATE TEST PASSED" : "CRATE TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_ARTYTEST=1: Artillery reaches beyond its sight only with a spotter, lobs arcing shells with splash,
    /// is blind up close; Shield Generators soak damage within their radius, recharge, and collapse when lost.
    static func runArtilleryTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func field() -> (SWorld, SBuilding) {
            let w = SWorld(map: SMapGen.generate("twin_ridges"),
                           players: [SPlayer(slot: 0, name: "P0", team: 1, isAI: false, start: 0),
                                     SPlayer(slot: 1, name: "P1", team: 2, isAI: false, start: 1)], difficulty: .normal)
            for u in w.units { u.command(.idle) }
            return (w, w.buildings.first { $0.team == 0 && $0.kind == .hq }!)
        }
        func built(_ w: SWorld, _ k: BuildingKind, _ x: Double, _ y: Double, team: Int = 0) -> SBuilding {
            w.startBuilding(k, x, y, team)
            let b = w.buildings.last!
            b.built = true; b.progress = 1; b.hp = b.maxHp
            w.bridgesChanged()
            return b
        }
        func run(_ w: SWorld, _ seconds: Double, until: () -> Bool = { false }) -> Bool {
            var t = 0.0
            while t < seconds { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30; if until() { return true } }
            return until()
        }
        do {
            let (w, hq) = field()
            let a = built(w, .artillery, hq.x + 300, hq.y)
            let rng = Double(BuildingKind.artillery.stats.range)
            check(rng > Double(BuildingKind.artillery.stats.sight), "artillery reaches further than it sees")
            // A building: it stays put, so a shell aimed where it stood still lands on it.
            let target = built(w, .depot, a.x + rng - 30, a.y, team: 1)
            let hp0 = target.hp
            _ = run(w, 6)
            check(target.hp == hp0, "and stays quiet while nobody of ours can see the target")
            let spotter = SUnit(world: w, kind: .marine, team: 0, x: target.x - 120, y: target.y); w.add(spotter)
            w.updateVisibility()
            check(run(w, 12) { target.hp < hp0 }, "a spotter lets it fire at the edge of its reach")
        }
        do {
            let (w, hq) = field()
            let a = built(w, .artillery, hq.x + 300, hq.y)
            let close = SUnit(world: w, kind: .marine, team: 1, x: a.x + artilleryMinRange - 40, y: a.y); w.add(close)
            w.updateVisibility()
            let hp0 = close.hp
            _ = run(w, 6)
            check(close.hp == hp0, "inside the minimum range it is blind")
            let far = built(w, .depot, a.x + 250, a.y, team: 1)      // in sight, beyond the minimum, and it stays put
            w.updateVisibility()
            var shell: [Any]?
            var t = 0.0
            while t < 8 && shell == nil {
                w.step(1.0 / 30)
                shell = w.events.first { jStr($0.first) == "shell" }
                w.events.removeAll()
                t += 1.0 / 30
            }
            check(shell != nil && jInt(shell![7]) == 1 && jNum(shell![5]) > 0.4, "it lobs an arcing shell slow enough to watch")
            check(w.shellSplashesForTests.first == artillerySplash, "with artillery splash")
        }
        do {
            let (w, hq) = field()
            let gen = built(w, .shield, hq.x + 200, hq.y)
            let depot = built(w, .depot, hq.x, hq.y + 200)
            let outside = built(w, .depot, hq.x + shieldRadius + 400, hq.y)
            _ = run(w, shieldMax / shieldRegen + shieldDelay + 1)
            check(hq.shield == shieldMax && depot.shield == shieldMax && gen.shield == shieldMax && outside.shield == 0,
                  "every building within \(Int(shieldRadius)) carries a full shield; one outside carries none")
            let hp0 = hq.hp
            hq.takeDamage(120, from: nil)
            check(hq.hp == hp0 && hq.shield == shieldMax - 120, "the shield takes a hit whole")
            hq.takeDamage(shieldMax, from: nil)
            check(hq.shield == 0 && hq.hp == hp0 - 120, "what spills over hits the walls")
            _ = run(w, shieldDelay - 1)
            let early = hq.shield
            _ = run(w, 3)
            check(early == 0 && hq.shield > 0, "it recharges after \(Int(shieldDelay))s without a hit")
            gen.takeDamage(99999, from: nil)
            _ = run(w, 6)
            check(hq.shield == 0 && !hq.shielded, "and collapses when the generator dies")
        }
        do {
            let (w, hq) = field()
            _ = built(w, .shield, hq.x + 200, hq.y)
            _ = run(w, shieldMax / shieldRegen + shieldDelay + 1)
            let doc = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: SaveGame.encode(w))) as! [String: Any]
            let w2 = try! SaveGame.decode(doc)
            check((w2.byId[hq.id] as? SBuilding)?.shield == shieldMax, "the shield survives a save")
        }
        print(ok ? "ARTILLERY TEST PASSED" : "ARTILLERY TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_PINGTEST=1: alert points — an event for the whole alliance only, rate-limited, clamped to the map,
    /// and answered by a computer ally's idle troops.
    static func runPingTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        let map = SMapGen.generate("four_corners")
        // Slot 2 is a computer player allied with slot 0.
        let players = (0..<4).map { SPlayer(slot: $0, name: "P\($0)", team: $0 % 2 + 1, isAI: $0 == 2, start: $0) }
        let w = SWorld(map: map, players: players, difficulty: .normal)
        w.apply(0, ["ping", 1000, 900])
        let ev = w.events.first { jStr($0.first) == "ping" }
        check(ev != nil && jInt(ev![1]) == 0 && jNum(ev![2]) == 1000 && jNum(ev![3]) == 900 && jInt(ev![4]) == 0, "a ping is an event (kind 0: attack here)")
        check(w.pings.last.map { $0.slot == 0 && $0.x == 1000 && $0.y == 900 } ?? false, "and is remembered on the server")
        w.events.removeAll()
        w.apply(0, ["ping", 100, 100])
        check(!w.events.contains { jStr($0.first) == "ping" }, "a second one within 3 seconds is dropped")
        var t = 0.0
        while t < 3.1 { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 }
        w.apply(1, ["ping", -500, 99999])       // from the enemy side, so the ally below never sees it
        check(w.pings.last.map { $0.x == 0 && $0.y == worldH } ?? false, "and coordinates are clamped to the map")

        let hq = w.buildings.first { $0.team == 2 && $0.kind == .hq }!
        for u in w.units where u.team == 2 { u.command(.idle) }
        var troops: [SUnit] = []
        for i in 0..<4 {
            let u = SUnit(world: w, kind: .marine, team: 2, x: hq.x + 200 + Double(i) * 30, y: hq.y + 200); w.add(u); troops.append(u)
        }
        t = 0
        while t < 3.1 { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 }
        let target = (hq.x - 900, hq.y + 900)
        w.apply(0, ["ping", target.0, target.1])
        t = 0
        while t < 1.5 { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 }
        func going(_ u: SUnit) -> Bool { if case .amove(let x, let y) = u.order { return abs(x - target.0) < 5 && abs(y - target.1) < 5 }; return false }
        let moving = troops.filter(going)
        check(moving.count >= 2, "a computer ally sends its idle troops to the alert point (\(moving.count) went)")
        for u in troops { u.command(.idle) }
        t = 0
        while t < 3.5 { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 }
        w.apply(1, ["ping", target.0, target.1])
        t = 0
        while t < 1.5 { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 }
        check(!troops.contains(where: going), "an enemy's ping is ignored, and the same ping is not answered twice")
        print(ok ? "PING TEST PASSED" : "PING TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_MEDICTEST=1: Medics heal infantry at the advertised rate, find the wounded themselves, never shoot,
    /// and stop for casualties on an attack-move; Engineers repair Siege Tanks at the repair price.
    static func runMedicTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func field(_ bank: Double = 1000) -> (SWorld, SBuilding) {
            let w = SWorld(map: SMapGen.generate("twin_ridges"),
                           players: [SPlayer(slot: 0, name: "P0", team: 1, isAI: false, start: 0),
                                     SPlayer(slot: 1, name: "P1", team: 2, isAI: false, start: 1)], difficulty: .normal)
            for u in w.units where u.team == 0 { u.command(.idle) }
            w.resources[0] = bank
            return (w, w.buildings.first { $0.team == 0 && $0.kind == .hq }!)
        }
        func unit(_ w: SWorld, _ k: UnitKind, _ team: Int, _ x: Double, _ y: Double) -> SUnit {
            let u = SUnit(world: w, kind: k, team: team, x: x, y: y); w.add(u); return u
        }
        func run(_ w: SWorld, _ seconds: Double, until: () -> Bool) -> Bool {
            var t = 0.0
            while t < seconds { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30; if until() { return true } }
            return until()
        }
        do {
            let (w, hq) = field()
            let m = unit(w, .medic, 0, hq.x + 200, hq.y)
            let r = unit(w, .marine, 0, hq.x + 200 + healRange - 5, hq.y)
            r.hp = r.maxHp - 30
            w.apply(0, ["repair", [m.id], r.id, false])
            check({ if case .heal = m.order { return true }; return false }(), "a Medic takes a heal order from the repair command")
            let t0 = w.elapsed
            let healed = run(w, 20) { r.hp >= r.maxHp }
            check(healed && abs((w.elapsed - t0) - 30 / healRate) < 1, String(format: "and treats 30 HP in %.1fs (expected %.1f)", w.elapsed - t0, 30 / healRate))
            check(m.order.isIdle, "then stands down")
        }
        do {
            let (w, hq) = field()
            let m = unit(w, .medic, 0, hq.x + 200, hq.y)
            let far = unit(w, .sniper, 0, hq.x + 200, hq.y + 180)
            far.hp = 10
            check(run(w, 20) { far.hp >= far.maxHp }, "an idle Medic finds the wounded by itself and walks over")
        }
        do {
            let (w, hq) = field()
            let m = unit(w, .medic, 0, hq.x + 200, hq.y)
            let enemy = unit(w, .marine, 1, hq.x + 260, hq.y)
            w.apply(0, ["attack", [m.id], enemy.id, false])
            check({ if case .amove = m.order { return true }; return false }(), "an attack order becomes an attack-move: Medics never shoot")
            _ = run(w, 3) { false }
            check(enemy.hp == enemy.maxHp, "and the enemy is untouched")
            let t = unit(w, .tank, 0, hq.x + 200, hq.y + 40)
            t.hp = 100
            w.apply(0, ["repair", [m.id], t.id, false])
            check({ if case .heal = m.order { return false }; return true }(), "tanks are not a Medic's business")
        }
        do {
            let (w, hq) = field()
            let m = unit(w, .medic, 0, hq.x + 200, hq.y)
            let r = unit(w, .marine, 0, hq.x + 300, hq.y + 30)
            r.hp = r.maxHp - 12
            w.apply(0, ["move", [m.id], hq.x + 600, hq.y, false, true])
            let stopped = run(w, 10) { if case .heal = m.order { return true }; return false }
            let done = run(w, 20) { r.hp >= r.maxHp }
            check(stopped && done && { if case .amove = m.order { return true }; return false }(), "on attack-move it stops for the wounded, then carries on")
        }
        do {
            let (w, hq) = field()
            _ = w.buyKit(0, "trauma")
            let m = unit(w, .medic, 0, hq.x + 200, hq.y)
            let r = unit(w, .marine, 0, hq.x + 230, hq.y)
            r.hp = r.maxHp - 30
            w.apply(0, ["repair", [m.id], r.id, false])
            let t0 = w.elapsed
            _ = run(w, 20) { r.hp >= r.maxHp }
            check(abs((w.elapsed - t0) - 30 / (healRate * 1.5)) < 1, "the trauma kit speeds healing by half")
        }
        do {
            let (w, hq) = field()
            let e = unit(w, .worker, 0, hq.x + 200, hq.y)
            let t = unit(w, .tank, 0, hq.x + 260, hq.y)
            t.hp = t.maxHp * 0.5
            w.apply(0, ["repair", [e.id], t.id, false])
            check({ if case .repair = e.order { return true }; return false }(), "an Engineer takes a repair order for a tank")
            let t0 = w.elapsed
            let done = run(w, 40) { t.hp >= t.maxHp }
            let spent = 1000 - (w.resources[0] ?? 0)
            check(done && abs((w.elapsed - t0) - repairTime * 0.5) < 2, String(format: "half a tank takes %.1fs", w.elapsed - t0))
            check(abs(spent - 0.5 * Double(UnitKind.tank.stats.cost) * repairCostRatio) < 0.5, String(format: "and costs %.1f crystal", spent))
            let enemy = unit(w, .tank, 1, hq.x + 300, hq.y + 200)
            enemy.hp = 50
            w.apply(0, ["repair", [e.id], enemy.id, false])
            check({ if case .repair = e.order { return false }; return true }(), "refuses an enemy tank")
            let r = unit(w, .marine, 0, hq.x + 200, hq.y + 60)
            r.hp = 10
            w.apply(0, ["repair", [e.id], r.id, false])
            check({ if case .repair = e.order { return false }; return true }(), "and infantry, which is a Medic's job")
        }
        do {
            let (w, hq) = field()
            let m = unit(w, .medic, 0, hq.x + 200, hq.y)
            let r = unit(w, .marine, 0, hq.x + 230, hq.y); r.hp = 20
            let e = unit(w, .worker, 0, hq.x + 200, hq.y + 60)
            let t = unit(w, .tank, 0, hq.x + 260, hq.y + 60); t.hp = 100
            w.apply(0, ["repair", [m.id], r.id, false])
            w.apply(0, ["repair", [e.id], t.id, false])
            let doc = try! JSONSerialization.jsonObject(with: try! JSONSerialization.data(withJSONObject: SaveGame.encode(w))) as! [String: Any]
            let w2 = try! SaveGame.decode(doc)
            let m2 = w2.byId[m.id] as! SUnit, e2 = w2.byId[e.id] as! SUnit
            var okOrders = false
            if case .heal(let p) = m2.order, p.id == r.id, case .repair(let q) = e2.order, q.id == t.id { okOrders = true }
            check(okOrders, "heal and tank-repair orders survive a save")
        }
        print(ok ? "MEDIC TEST PASSED" : "MEDIC TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_SAVETEST=1: a mid-game world survives a save round trip and plays on; and a save written by the
    /// Python edition (tests/fixtures/save_python.json, path in FC_SAVE_FIXTURE) loads here and plays on too.
    static func runSaveTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func signature(_ w: SWorld) -> String {
            let units = w.units.filter { !$0.dead }.map { "\($0.id):\(NetProtocol.name($0.kind)):\($0.team):\(Int($0.x)):\(Int($0.y)):\(Int($0.hp)):\($0.mode.rawValue):\($0.rank):\($0.order.code)" }.sorted()
            let bld = w.buildings.filter { !$0.dead }.map { "\($0.id):\(NetProtocol.name($0.kind)):\($0.built):\(Int($0.hp)):\($0.upgrades.count):\($0.queue.count)" }.sorted()
            let fog = w.fog.map { "\($0.key):\($0.value.explored.filter { $0 }.count)" }.sorted()
            let res = w.resources.keys.sorted().map { "\($0)=\(Int(w.resources[$0]!))" }
            return "\(Int(w.elapsed))|\(units)|\(bld)|\(w.bridges.map { $0.intact })|\(w.towers.map { $0.owner ?? -1 })|\(fog)|\(w.playerKits.keys.sorted().map { "\($0)=\(w.playerKits[$0]!.sorted())" })|\(res)"
        }
        let map = SMapGen.generate("river_crossing")
        let players = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: true, start: $0) }
        let w = SWorld(map: map, players: players, difficulty: .hard)
        var t = 0.0
        while t < 240 { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 }
        let hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
        w.resources[0] = 3000
        _ = w.buyKit(0, "flak")
        w.apply(0, ["upgrade", [hq.id], "armor"])
        let tank = SUnit(world: w, kind: .tank, team: 0, x: hq.x + 200, y: hq.y)
        w.add(tank); tank.kills = 5; tank.rank = 2; tank.mode = .sieged
        w.bridges[0].takeDamage(bridgeHP, from: nil)
        w.towers[0].owner = 1
        for _ in 0..<90 { w.step(1.0 / 30); w.events.removeAll() }
        w.updateVisibility()      // the sight pass is throttled; loading runs it at once, so settle it here too
        let before = signature(w)
        var doc = SaveGame.encode(w, label: "macOS fixture")
        doc["saved_at"] = 0
        let json = try! JSONSerialization.data(withJSONObject: doc)
        if let out = env["FC_SAVE_OUT"] { try! json.write(to: URL(fileURLWithPath: out)) }
        let back = try! JSONSerialization.jsonObject(with: json) as! [String: Any]
        guard let w2 = try? SaveGame.decode(back) else { print("  FAIL decode"); exit(1) }
        let after = signature(w2)
        check(after == before, "a save round trip keeps the whole game")
        if after != before { print("  before: \(before)\n  after:  \(after)") }
        while !w2.gameOver && w2.elapsed < 3000 { w2.step(1.0 / 30); w2.events.removeAll() }
        check(w2.gameOver, "and the loaded game plays on to a result")
        check((try? SaveGame.decode(["game": "field-command", "format": 99])) == nil, "unknown formats are refused")

        if let path = env["FC_SAVE_FIXTURE"], let data = FileManager.default.contents(atPath: path),
           let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            do {
                let w3 = try SaveGame.decode(d)
                let n = w3.units.count, b = w3.buildings.count
                let kits = w3.playerKits[0] ?? []
                while !w3.gameOver && w3.elapsed < 3000 { w3.step(1.0 / 30); w3.events.removeAll() }
                check(n == jArr(d["units"]).count && b == jArr(d["buildings"]).count && kits.contains("flak") && w3.gameOver,
                      "a save written by the Python edition loads (\(n) units, \(b) buildings, kit \(kits.sorted())) and plays on")
            } catch {
                check(false, "a save written by the Python edition loads: \(error)")
            }
        }
        print(ok ? "SAVE TEST PASSED" : "SAVE TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_AUDIOTEST=1: synthesises every effect and checks each has the length and loudness the recipe implies —
    /// no audio device needed, so it runs in CI.
    static func runAudioTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        let sounds = Audio.synthesise()
        check(Set(sounds.keys) == Set(Audio.names) && Audio.names.count == 43, "thirteen effects and thirty unit voice lines")
        let expected: [String: Double] = ["rifle": 0.08, "cannon": 0.5, "explosion": 0.9, "turret": 0.1, "complete": 0.37,
                                          "alert": 0.45, "wave": 0.75, "snipe": 0.35, "siege": 0.68, "pop": 0.08,
                                          "click": 0.03, "victory": 0.72, "defeat": 0.9]
        for name in Audio.names where !name.hasPrefix("voice_") && !name.hasPrefix("ack_") {
            guard let s = sounds[name] else { continue }
            let secs = Double(s.count) / Audio.rate
            let peak = s.map { abs($0) }.max() ?? 0
            let mean = s.map { abs($0) }.reduce(0, +) / Float(s.count)
            check(abs(secs - expected[name]!) < 0.02 && peak > 0.05 && peak <= 1 && mean > 0.002,
                  String(format: "%-10@ %.2fs peak %.2f", name as NSString, secs, peak))
        }
        // The music (1.23): three seamless eight-second loops, gains by threat, a meter that rises fast and falls slow.
        let loops = Audio.Music.synthesise()
        check(Set(loops.keys) == Set(Audio.Music.layers) && Audio.Music.layers.count == 5 && Audio.Music.chords.count == 4, "five music layers over four chords")
        for kind in Audio.voicePitch.keys.sorted() {
            let sels = Audio.voiceLinesSelect.indices.map { sounds["voice_\(kind)_\($0)"]! }
            let acks = Audio.voiceLinesAck.indices.map { sounds["ack_\(kind)_\($0)"]! }
            var good = Set(sels.map { $0.count }).count == 3 && acks.map { $0.count }.max()! < sels.map { $0.count }.min()!
            for s in sels { let l = Double(s.count) / Audio.rate; good = good && l > 0.2 && l < 0.4 && s.map { abs($0) }.max()! > 0.29 }
            for a in acks { let l = Double(a.count) / Audio.rate; good = good && l > 0.15 && l < 0.3 && a.map { abs($0) }.max()! > 0.29 }
            check(good, "\(kind) has three lines and two quicker acknowledgements in its own voice (\(Audio.voiceTimbre[kind]!))")
        }
        do {
            let a = sounds["voice_tank_0"]!, b = sounds["voice_sniper_0"]!
            let ma = a.reduce(0, +) / Float(a.count), mb = b.reduce(0, +) / Float(b.count)
            var num: Float = 0, da: Float = 0, db: Float = 0
            for i in 0..<min(a.count, b.count) { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
            var rng = SeededRNG(1)
            let seen = (0..<40).map { _ in Audio.pickLine("voice_", "marine", &rng) }
            let varied = zip(seen, seen.dropFirst()).allSatisfy { $0 != $1 } && Set(seen) == [0, 1, 2]
            check(a.count == b.count && num / (da * db).squareRoot() < 0.5 && varied, "two kinds do not sound alike, and a unit never repeats itself")
        }
        let n = Int(Audio.rate * Audio.Music.loopSeconds)
        for name in Audio.Music.layers {
            guard let x = loops[name] else { continue }
            let peak = x.map { abs($0) }.max() ?? 0
            let mean = x.map { abs($0) }.reduce(0, +) / Float(x.count)
            check(x.count == n && peak > 0.1 && peak <= 1 && abs(x[0]) < 0.01 && abs(x[n - 1]) < 0.01 && mean > 0.002,
                  String(format: "%-6@ %.1fs peak %.2f, faded at the seam", name as NSString, Double(x.count) / Audio.rate, peak))
        }
        let calm = Audio.Music.layerGains(0), edge = Audio.Music.layerGains(0.5), war = Audio.Music.layerGains(1)
        check(calm == ["pad": 1, "melody": 1, "pulse": 0, "drums": 0, "brass": 0] && edge["pad"] == 1 && edge["pulse"]! > 0.5
              && edge["drums"] == 0 && edge["melody"]! > 0.4 && edge["melody"]! < 1
              && war == ["pad": 1, "melody": 0, "pulse": 1, "drums": 1, "brass": 1], "layer gains follow the threat")
        var t = Audio.Music.Threat()
        t.enemiesSeen = 2
        check(t.target(10) == Audio.Music.threatSeen, "an enemy in sight is a low threat")
        t.note("rifle", 10)
        check(t.target(11) == Audio.Music.threatShots && t.target(10 + Audio.Music.shotHold + 1) == Audio.Music.threatSeen, "gunfire a higher one, for a while")
        t.note("alert", 20)
        var now = 20.0
        for _ in 0..<30 { now += 1.0 / 30; t.update(1.0 / 30, now) }
        check(t.target(21) == Audio.Music.threatAlert && t.level > 0.5, "an attack alert is the top, and the meter is most of the way up in a second")
        for _ in 0..<9 { now += 1; t.update(1, now) }
        let full = t.level > 0.95
        t.enemiesSeen = 0
        now = 20 + Audio.Music.alertHold + 0.1
        t.update(1, now)
        let started = full && t.level > 0.6 && t.level < 1
        for _ in 0..<12 { now += 1; t.update(1, now) }
        check(started && t.level < 0.15, "and it settles over a dozen seconds once the alert lapses")
        print(ok ? "AUDIO TEST PASSED" : "AUDIO TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_AITEST=1: the computer opponent notices what it faces and answers it — matching linux/tests/test_ai.py.
    static func runAITest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        let map = SMapGen.generate("twin_ridges")
        let players = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
        let w = SWorld(map: map, players: players, difficulty: .normal)
        let ai = SAI(world: w, team: 1)
        let hq = w.buildings.first { $0.team == 1 && $0.kind == .hq }!
        for i in 0..<5 { w.add(SUnit(world: w, kind: .tank, team: 0, x: hq.x + 250 + Double(i) * 30, y: hq.y)) }
        w.updateVisibility()
        ai.observe()
        check((ai.seen[.tank] ?? 0) >= 4, "it notices enemy tanks in its sight")
        for u in w.units where u.team == 0 { u.dead = true }
        for _ in 0..<40 { ai.observe() }
        check((ai.seen[.tank] ?? 0) < 0.5, "and forgets them once they are gone")

        let ai2 = SAI(world: w, team: 1)
        ai2.seen = [.marine: 0, .sniper: 0, .tank: 12]
        check(ai2.wanted([]) == .sniper, "massed tanks are answered with Snipers")
        ai2.seen = [.marine: 12, .sniper: 0, .tank: 0]
        check(ai2.wanted([]) == .tank, "massed Rangers are answered with tanks")
        ai2.seen = [.marine: 0, .sniper: 0, .tank: 0]
        check(ai2.wanted([]) == .marine, "the base mix opens with Rangers")
        ai2.seen = [.marine: 0, .sniper: 0, .tank: 12, .gunship: 0]
        let vsTanks = ai2.composition()
        ai2.seen = [.marine: 0, .sniper: 0, .tank: 0, .gunship: 12]
        let vsAir = ai2.composition()
        check(vsTanks[.gunship]! > 0.25 && vsTanks[.sniper]! > vsTanks[.tank]! && vsAir[.marine]! > 0.5 && vsAir[.gunship]! < 0.1,
              "Gunships answer massed tanks; Rangers answer Gunships")
        do {
            // A turtle walls its approach with a gap; the Factory trains a Gunship once a Radar stands.
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .normal)
            for u in w.units { u.command(.idle) }
            let ai = SAI(world: w, team: 1, opening: "turtle")
            let hq = w.buildings.first { $0.team == 1 && $0.kind == .hq }!
            let workers = w.units.filter { $0.team == 1 && $0.kind == .worker }
            w.resources[1] = 2000
            w.elapsed = 100 * Double(w.difficulty.pace)
            let bases = w.buildings.filter { $0.team == 1 }
            let tooEarly = ai.fortify(hq, bases, workers) == 0
            w.elapsed = 200 * Double(w.difficulty.pace)
            let placed = ai.fortify(hq, bases, workers)
            var orders = 0
            var inLine = true
            for u in workers {
                for o in [u.order] + u.queued {
                    if case .build(.wall, let x, let y) = o { orders += 1; let dd = hypot(x - hq.x, y - hq.y); inLine = inLine && dd > 300 && dd < 600 }
                }
            }
            check(tooEarly && placed >= 4 && orders == placed && inLine && w.resources[1] == 2000 - Double(placed) * Double(BuildingKind.wall.stats.cost),
                  "a turtle walls its approach at 150s: \(placed) blocks in a line with a gap, paid for")
            w.startBuilding(.factory, hq.x - 300, hq.y, 1)
            let fac = w.buildings.last!; fac.built = true
            for i in 0..<3 { w.startBuilding(.depot, hq.x - 500, hq.y - 200 + Double(i) * 100, 1); w.buildings.last!.built = true }
            ai.seen = [.marine: 0, .sniper: 0, .tank: 12, .gunship: 0]
            w.resources[1] = 5000
            var army = (0..<6).map { SUnit(world: w, kind: .marine, team: 1, x: hq.x, y: hq.y + 200 + Double($0)) }
            army += (0..<3).map { SUnit(world: w, kind: .sniper, team: 1, x: hq.x, y: hq.y + 240 + Double($0)) }
            for u in army { w.add(u) }
            let wantAir = ai.wanted(army) == .gunship
            ai.produceForTest(hq, w.buildings.filter { $0.team == 1 }, [], 0)
            let tankFirst = fac.queue == [.tank]
            fac.queue = []
            w.startBuilding(.radar, hq.x - 300, hq.y + 200, 1)
            w.buildings.last!.built = true
            ai.produceForTest(hq, w.buildings.filter { $0.team == 1 }, [], 0)
            check(wantAir && tankFirst && fac.queue == [.gunship], "the Factory trains a Gunship once one is wanted and a Radar stands")
        }

        let sn = SUnit(world: w, kind: .sniper, team: 1, x: hq.x, y: hq.y)
        let r = SUnit(world: w, kind: .marine, team: 1, x: hq.x, y: hq.y)
        let (sx, sy) = ai.standoff(sn, hq.x - 1000, hq.y)
        let (rx, ry) = ai.standoff(r, hq.x - 1000, hq.y)
        check(abs(sx - (hq.x - 1000)) == 200 && sy == hq.y && rx == hq.x - 1000 && ry == hq.y, "Snipers stop 200 short; Rangers go all the way")

        // The strategist: openings by difficulty, seed and map size.
        do {
            func picks(_ d: Difficulty, giant: Bool) -> Set<String> {
                var out = Set<String>()
                for s in 0..<40 { simRNG = SeededRNG(UInt64(s)); out.insert(chooseOpening(d, giant: giant)) }
                return out
            }
            let easy = picks(.easy, giant: false), hard = picks(.hard, giant: false), giant = picks(.hard, giant: true)
            check(!easy.contains("rush") && hard.contains("rush") && hard.count == 3, "Easy never rushes; Hard tries every opening")
            check(!giant.contains("rush"), "nobody rushes across a giant map")
            func seeded(_ seed: UInt64) -> String {
                let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: true, start: $0) }
                return SWorld(map: SMapGen.generate("twin_ridges"), players: ps, difficulty: .hard, seed: seed).players[1]!.ai!.opening
            }
            let a = (0..<12).map { seeded(UInt64($0)) }, b = (0..<12).map { seeded(UInt64($0)) }
            check(a == b && Set(a).count > 1, "the opening comes from the seed: a replay picks the same one")
            let rush = SAI(world: w, team: 1, opening: "rush"), turtle = SAI(world: w, team: 1, opening: "turtle")
            func by(_ ai: SAI, _ t: Double, _ k: BuildingKind) -> Int { ai.plan(t).filter { $0.0 == k }.map { $0.1 }.max() ?? 0 }
            check(by(rush, 25, .barracks) == 1 && by(turtle, 25, .barracks) == 0 && by(turtle, 80, .turret) == 1, "the opening bends the build plan")
            check(rush.nextWave < turtle.nextWave && rush.waveSize < turtle.waveSize, "a rush attacks earlier with less; a turtle later with more")
        }
        // A scout walks to the enemy's door and comes home.
        do {
            let ai = SAI(world: w, team: 1, opening: "economy")
            let home = (0..<3).map { SUnit(world: w, kind: .marine, team: 1, x: hq.x + 100 + Double($0) * 20, y: hq.y) }
            for u in home { w.add(u) }
            w.elapsed = ai.nextScout
            ai.scoutRun(hq, home)
            let start = jArr(jArr(w.map["starts"])[0])
            let ex = Double(jNum(start[0])), ey = Double(jNum(start[1]))
            var toDoor = false
            if let s = ai.scout, case .move(let x, let y) = s.order { toDoor = abs(x - ex) < 1 && abs(y - ey) < 1 }
            check(toDoor, "a scout is sent to the enemy Command Center's ground")
            ai.scout?.command(.idle)
            for _ in 0..<4 { ai.scoutRun(hq, home); ai.scout?.command(.idle) }   // walks the rest of the route
            check(ai.scout == nil && ai.nextScout > w.elapsed, "and once home the next one waits")
        }
        // The expansion comes early when the home field runs low or the Engineers crowd it.
        do {
            let ai = SAI(world: w, team: 1, opening: "turtle")
            let workers = w.units.filter { $0.team == 1 && $0.kind == .worker }
            check(!ai.shouldExpand(50, [hq], workers), "no expansion at 50s with a full field")
            for c in w.crystals where abs(c.x - hq.x) < 700 && abs(c.y - hq.y) < 700 { c.amount = Int(Double(c.amount) * 0.3) }
            check(ai.shouldExpand(50, [hq], workers), "but at once when the field is under 45% of what it was")
            let crowd = (0..<40).map { _ in SUnit(world: w, kind: .worker, team: 1, x: hq.x, y: hq.y) }
            let ai2 = SAI(world: w, team: 1, opening: "turtle")
            check(ai2.shouldExpand(50, [hq], crowd), "or with more Engineers than the field can feed")
        }
        // An expansion gets a turret and a garrison.
        do {
            let map = SMapGen.generate("twin_ridges")
            let ps = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: map, players: ps, difficulty: .normal)
            let ai = SAI(world: w, team: 1, opening: "turtle")
            let hq = w.buildings.first { $0.team == 1 && $0.kind == .hq }!
            w.startBuilding(.hq, hq.x - 900, hq.y, 1)       // toward the middle: the far corner's +900 leaves the map
            let e = w.buildings.last!
            e.built = true
            let bases = w.buildings.filter { $0.team == 1 }
            check(ai.unguardedExpansion(hq, bases) === e, "a new expansion has no turret of its own")
            w.resources[1] = 2000
            w.elapsed = 200 * Double(w.difficulty.pace)
            let workers = w.units.filter { $0.team == 1 && $0.kind == .worker }
            _ = ai.constructForTest(hq, bases, workers)
            var turretNear = false
            for u in workers { if case .build(.turret, let x, let y) = u.order { turretNear = abs(x - e.x) < 500 && abs(y - e.y) < 500 } }
            check(turretNear, "so an Engineer goes to put one up beside it")
            let home = (0..<8).map { SUnit(world: w, kind: .marine, team: 1, x: hq.x + 100 + Double($0) * 20, y: hq.y) }
            for u in home { w.add(u) }
            ai.garrisonRun(hq, bases, home)
            var posted = true
            for u in ai.guards { if case .amove(let x, _) = u.order { posted = posted && abs(x - e.x) < 200 } else { posted = false } }
            check(ai.guards.count == 3 && posted, "and three troops are posted at it on Normal")
        }

        // A game between two reacting opponents still finishes.
        let map2 = SMapGen.generate("twin_ridges")
        let bots = (0..<2).map { SPlayer(slot: $0, name: "AI\($0)", team: $0 + 1, isAI: true, start: $0) }
        let w2 = SWorld(map: map2, players: bots, difficulty: .normal)
        while !w2.gameOver && w2.elapsed < 3000 { w2.step(1.0 / 30); w2.events.removeAll() }
        check(w2.gameOver, String(format: "two reacting opponents finish a game (%.0fs)", w2.elapsed))

        // With every crossing down the enemy is unreachable: the computer rebuilds the one on its route.
        do {
            let map = SMapGen.generate("river_crossing")
            let ps = (0..<2).map { SPlayer(slot: $0, name: "AI\($0)", team: $0 + 1, isAI: true, start: $0) }
            let w = SWorld(map: map, players: ps, difficulty: .normal)
            var t = 0.0
            while t < 5 { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 }
            for b in w.bridges { b.takeDamage(bridgeHP, from: nil) }
            w.resources[1] = 400
            let ai = w.players[1]!.ai!
            ai.forceRouteCheck()
            t = 0
            while t < 7 { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 }
            check(!ai.routeOpen && ai.routeBridge != nil, "with every crossing down it knows its route is cut")
            let building = w.units.contains { u in u.team == 1 && u.kind == .worker && { if case .rebuild = u.order { return true }; return false }() }
            check(building, "and sends an Engineer to the crossing on its route")
            t = 0
            while t < 240 && !w.bridges.contains(where: { $0.intact }) { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 }
            check(w.bridges.contains { $0.intact }, "which stands again within \(Int(t))s")
            ai.forceRouteCheck()
            t = 0
            while t < 7 { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30 }
            check(ai.routeOpen, "and the route is open again")
        }
        print(ok ? "AI TEST PASSED" : "AI TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_STORETEST=1: the Armory on the server simulation — every kit effect, the price rules and the wire mask —
    /// matching linux/tests/test_store.py.
    static func runStoreTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func fresh(bank: Double = 5000) -> (SWorld, SBuilding) {
            let map = SMapGen.generate("twin_ridges")
            let players = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: map, players: players, difficulty: .normal)
            for u in w.units where u.team == 0 { u.command(.idle) }
            w.resources[0] = bank
            return (w, w.buildings.first { $0.team == 0 && $0.kind == .hq }!)
        }
        check(kits.count == 18 && Set(kitIds).count == 18, "eighteen distinct kits")

        var (w, hq) = fresh()
        let vet = SUnit(world: w, kind: .marine, team: 0, x: hq.x + 100, y: hq.y)
        w.add(vet)
        vet.hp = 30
        let base = Double(UnitKind.marine.stats.hp)
        check(w.buyKit(0, "flak") && vet.maxHp == base * 1.25 && vet.hp == 30 + base * 0.25, "a hit-point kit is worn by units already in the field")
        let recruit = SUnit(world: w, kind: .marine, team: 0, x: hq.x + 140, y: hq.y)
        check(recruit.maxHp == base * 1.25 && recruit.hp == recruit.maxHp, "and by every unit that follows")

        (w, hq) = fresh()
        for id in ["hollowpoint", "boots", "scope", "autoloader", "barrel"] { _ = w.buyKit(0, id) }
        let r = SUnit(world: w, kind: .marine, team: 0, x: hq.x + 100, y: hq.y)
        let sn = SUnit(world: w, kind: .sniper, team: 0, x: hq.x + 100, y: hq.y + 50)
        let t = SUnit(world: w, kind: .tank, team: 0, x: hq.x + 100, y: hq.y + 100)
        check(abs(r.vetMult - 1.2) < 1e-9 && abs(r.speed - Double(UnitKind.marine.stats.speed) * 1.15) < 1e-9, "damage and speed kit")
        check(sn.attackRange == Double(UnitKind.sniper.stats.range) + 30 && t.attackRange == Double(UnitKind.tank.stats.range) + 20, "range kit")
        t.mode = .sieged
        check(t.attackRange == siegeRange + 20, "range kit applies dug in too")

        (w, hq) = fresh()
        let eng = SUnit(world: w, kind: .worker, team: 0, x: hq.x + 100, y: hq.y)
        w.add(eng)
        let before = (eng.carryCapacity, eng.workMult)
        _ = w.buyKit(0, "cargorig"); _ = w.buyKit(0, "powertools")
        check(before == (carryCap, 1.0) && eng.carryCapacity == carryCap + 4 && abs(eng.workMult - 1.3) < 1e-9, "Cargo rig and Power tools")

        (w, hq) = fresh(bank: 250)
        let refused = !w.buyKit(0, "scope")
        let bought = w.buyKit(0, "flak") && (w.resources[0] ?? 0) == 50
        check(refused && bought && !w.buyKit(0, "flak") && !w.buyKit(0, "nope"), "price once, never twice, only with crystal")

        print(ok ? "STORE TEST PASSED" : "STORE TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_CARDSHOT=dir: starts a skirmish, selects the Command Center, an Engineer, a Barracks and a mixed
    /// group in turn, and writes the view after each — including a frame with the mouse over a button and
    /// one after pressing one — so the command card can be inspected in the real client.
    static func runCardShot(_ dir: String) -> Never {
        instantScenes = true
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 1400, height: 880))
        startSkirmish(view, size: view.bounds.size, difficulty: .normal, mapId: "twin_ridges", opponents: 1)
        guard let scene = view.scene as? GameScene, let net = scene.net, net.isLocal,
              let world = GameServer.hosted?.simulation else {
            print("card shot: FAILED — no local game")
            exit(1)
        }
        if !scene.didSetup { scene.didMove(to: view) }
        var t: TimeInterval = 1
        func frames(_ n: Int) { for _ in 0..<n { t += 1.0 / 30; scene.update(t); usleep(12_000) } }
        frames(60)
        // Give the player a base to select: the server builds it, the snapshot brings it to the client.
        let hq = world.buildings.first { $0.team == 0 && $0.kind == .hq }!
        for (k, dx, dy) in [(BuildingKind.barracks, 300.0, 0.0), (.factory, 300, 250), (.depot, -300, 0)] {
            world.startBuilding(k, hq.x + dx, hq.y + dy, 0)
            let b = world.buildings.last!
            b.built = true; b.progress = 1; b.hp = b.maxHp
        }
        world.bridgesChanged()
        world.resources[0] = 9999
        frames(30)
        func pick(_ kinds: [BuildingKind], _ name: String) {
            let sel = scene.buildings.filter { $0.team.isLocal && kinds.contains($0.kind) }
            scene.setSelection(sel)
            frames(10)
            snapshot(scene, dir: dir, name: "card_\(name)")
        }
        pick([.hq], "hq")
        if let e = scene.units.first(where: { $0.team.isLocal && $0.kind == .worker }) {
            scene.setSelection([e]); frames(10); snapshot(scene, dir: dir, name: "card_engineer")
            scene.hud.pressButton(2)          // begin placing a building
            frames(10); snapshot(scene, dir: dir, name: "card_engineer_placing")
            scene.cancelModes()
        }
        pick([.barracks], "barracks")
        pick([.barracks, .factory, .depot], "mixed")
        scene.setSelection([]); frames(10); snapshot(scene, dir: dir, name: "card_none")
        // The Armory, with one piece already issued.
        world.resources[0] = 640
        _ = world.buyKit(0, "flak")
        frames(10)
        scene.toggleStore()
        frames(10)
        snapshot(scene, dir: dir, name: "store")
        scene.toggleStore()
        print("card shot: wrote \(dir)")
        stopHostedServer()
        exit(0)
    }

    /// FC_TOWERTEST=1: veterancy and watchtowers on the server simulation — ranks from kills, the health and
    /// damage they add, tower placement on every map, capture, contest and vision — matching the Python tests.
    static func runTowerTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func fresh(_ mapId: String = "twin_ridges") -> SWorld {
            let map = SMapGen.generate(mapId)
            let n = SMapGen.info(mapId)?.players ?? 2
            let players = (0..<n).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: map, players: players, difficulty: .normal)
            for u in w.units { u.command(.idle) }
            return w
        }
        func unit(_ w: SWorld, _ k: UnitKind, _ team: Int, _ x: Double, _ y: Double) -> SUnit {
            let u = SUnit(world: w, kind: k, team: team, x: x, y: y)
            w.add(u)
            w.updateVisibility()
            return u
        }
        func run(_ w: SWorld, _ secs: Double, until done: () -> Bool = { false }) -> Bool {
            var t = 0.0
            while t < secs { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30; if done() { return true } }
            return done()
        }

        // Veterancy
        var w = fresh()
        var hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
        let r = unit(w, .marine, 0, hq.x + 100, hq.y)
        r.hp = 30
        for _ in 0..<vetThresholds[0] { r.creditKill() }
        check(r.rank == 1 && r.maxHp == Double(UnitKind.marine.stats.hp) * (1 + vetBonus)
              && r.hp == 30 + Double(UnitKind.marine.stats.hp) * vetBonus, "two kills: rank 1, more health, the difference granted")
        for _ in 0..<(vetThresholds[2] - vetThresholds[0]) { r.creditKill() }
        check(r.rank == 3 && r.vetMult == 1 + 3 * vetBonus, "ten kills: rank 3")

        w = fresh()
        hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
        let sn = unit(w, .sniper, 0, hq.x + 100, hq.y)
        let victims = (0..<2).map { unit(w, .worker, 1, sn.x + 200 + Double($0) * 20, sn.y) }
        var killed = true
        for v in victims {
            w.apply(0, ["attack", [sn.id], v.id, false])
            killed = run(w, 20) { v.dead } && killed
        }
        check(killed && sn.kills == 2 && sn.rank == 1, "kills in combat are credited to the shooter")

        w = fresh()
        let enemyHQ = w.buildings.first { $0.team == 1 && $0.kind == .hq }!
        let vet = unit(w, .marine, 0, enemyHQ.x - 150, enemyHQ.y)
        vet.kills = 10; vet.rank = 3
        w.apply(0, ["attack", [vet.id], enemyHQ.id, false])
        let hp0 = enemyHQ.hp
        _ = run(w, 0.6)
        check(abs((hp0 - enemyHQ.hp) - Double(UnitKind.marine.stats.damage) * 1.3) < 1e-6, "veterans hit harder (+30% at rank 3)")

        // Watchtowers
        for m in SMapGen.catalog {
            let w = fresh(m.id)
            let clear = w.towers.allSatisfy { t in !w.mapWallsForTests.contains { $0.distance(t.x, t.y) < 20 } }
            check(w.towers.count == 3 && clear, "\(m.id): three towers on open ground")
            print("TOWERS \(m.id) " + w.towers.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: ";"))
        }
        w = fresh()
        let t = w.towers[0]
        _ = unit(w, .marine, 0, t.x + 60, t.y)
        _ = run(w, towerCaptureTime - 0.5)
        let pending = t.owner == nil && t.capturing == 0 && t.progress > 0.8
        _ = run(w, 1.0)
        check(pending && t.owner == 0 && t.progress == 0, "troops alone in the ring take it in eight seconds")

        w = fresh()
        let t2 = w.towers[0]
        let a = unit(w, .marine, 0, t2.x + 60, t2.y), b = unit(w, .marine, 1, t2.x - 60, t2.y)
        a.hp = 1e6; b.hp = 1e6
        _ = run(w, 6)
        check(t2.owner == nil && t2.progress == 0, "a contested ring does not flip")

        w = fresh()
        let t3 = w.towers[0]
        let holder = unit(w, .marine, 0, t3.x + 60, t3.y)
        _ = run(w, towerCaptureTime + 0.5)
        w.updateVisibility()
        let far = (t3.x + towerSight - 40, t3.y)
        let sees = w.fogFor(0).isVisible(far.0, far.1) && !w.fogFor(1).isVisible(far.0, far.1)
        holder.dead = true
        _ = run(w, 0.1)
        _ = unit(w, .marine, 1, t3.x - 60, t3.y)
        _ = run(w, towerCaptureTime + 0.5)
        w.updateVisibility()
        check(t3.owner == 0 || t3.owner == 1, "someone holds it")
        check(sees && t3.owner == 1 && w.fogFor(1).isVisible(far.0, far.1), "the owner sees around it, and can lose it")

        // Attacker reveal
        w = fresh()
        hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
        w.startBuilding(.depot, hq.x + 400, hq.y, 0)          // sees 200; cannot walk towards its attacker
        let depot = w.buildings.last!
        depot.built = true; depot.progress = 1; depot.hp = 1e6
        let hidden = unit(w, .sniper, 1, depot.x + depot.half + Double(UnitKind.sniper.stats.range) - 10, depot.y)
        let startsHidden = !w.sees(0, hidden)
        w.apply(1, ["attack", [hidden.id], depot.id, false])
        let shown = run(w, 5) { w.sees(0, hidden) }
        hidden.command(.idle)
        _ = run(w, revealTime + 0.5)
        w.updateVisibility()
        check(startsHidden && shown && !w.sees(0, hidden), "a hidden Sniper is revealed by its own shot, then fades again")

        print(ok ? "TOWER TEST PASSED" : "TOWER TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_UPGRADETEST=1: building upgrades on the server simulation — each effect, price and research time,
    /// and the rules around buying them — matching linux/tests/test_upgrades.py.
    static func runUpgradeTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func setup(_ kind: BuildingKind = .hq) -> (SWorld, SBuilding) {
            let map = SMapGen.generate("twin_ridges")
            let players = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: map, players: players, difficulty: .normal)
            for u in w.units where u.team == 0 { u.command(.idle) }
            w.resources[0] = 5000
            let hq = w.buildings.first { $0.team == 0 && $0.kind == .hq }!
            if kind == .hq { return (w, hq) }
            w.startBuilding(kind, hq.x + 400, hq.y, 0)
            let b = w.buildings.last!
            b.built = true; b.progress = 1; b.hp = b.maxHp
            return (w, b)
        }
        func run(_ w: SWorld, _ secs: Double, until done: () -> Bool = { false }) -> Bool {
            var t = 0.0
            while t < secs { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30; if done() { return true } }
            return done()
        }
        func buy(_ w: SWorld, _ b: SBuilding, _ k: UpgradeKind) -> Bool {
            w.apply(0, ["upgrade", [b.id], k.wireName])
            guard b.upgrading == k else { return false }
            return run(w, k.stats.time + 1) { b.upgrades.contains(k) }
        }

        var (w, b) = setup()
        b.hp = 1000
        check(buy(w, b, .hp) && b.maxHp == 3000 && b.hp == 2500, "Reinforce doubles hit points and keeps the building sound")

        (w, b) = setup()
        _ = buy(w, b, .armor)
        b.takeDamage(100, from: nil)
        check(b.hp == b.maxHp - 100 * armorFactor, "Armour plating takes 30% less")

        func trainTime(_ upgraded: Bool) -> Double {
            let (w, hq) = setup()
            if upgraded { _ = buy(w, hq, .prod) }
            _ = w.train(.worker, [hq], 0)
            let t0 = w.elapsed, n0 = w.units.filter { $0.team == 0 }.count
            _ = run(w, 30) { w.units.filter { $0.team == 0 }.count > n0 }
            return w.elapsed - t0
        }
        let fast = trainTime(true), slow = trainTime(false)
        check(abs(fast * 2 - slow) < 0.2, String(format: "Assembly line trains twice as fast (%.1fs vs %.1fs)", fast, slow))

        (w, b) = setup(.depot)
        let before = w.supplyCap(0)
        _ = buy(w, b, .supply)
        check(w.supplyCap(0) == before + depotUpgradedSupply && b.supply == BuildingKind.depot.stats.supply * 2,
              "Expanded storage doubles a depot")

        (w, b) = setup(.turret)
        _ = buy(w, b, .guns)
        let victim = SUnit(world: w, kind: .marine, team: 1, x: b.x + 240, y: b.y)     // outside 210, inside 260
        w.add(victim)
        w.updateVisibility()
        check(b.turretDamage == turretUpgradedDamage && b.turretRange == turretUpgradedRange && run(w, 10) { victim.dead },
              "Twin cannon hits harder and further")

        (w, b) = setup()
        let bank = w.resources[0] ?? 0, t0 = w.elapsed
        _ = buy(w, b, .hp)
        check(bank - (w.resources[0] ?? 0) == Double(UpgradeKind.hp.cost(for: .hq)) && abs((w.elapsed - t0) - UpgradeKind.hp.stats.time) < 0.2,
              "price and time are as advertised")

        (w, b) = setup()
        w.apply(0, ["upgrade", [b.id], "hp"])
        w.apply(0, ["upgrade", [b.id], "armor"])
        check(b.upgrading == .hp, "one at a time")
        _ = run(w, UpgradeKind.hp.stats.time + 1)
        let bank2 = w.resources[0] ?? 0
        w.apply(0, ["upgrade", [b.id], "hp"])
        check(b.upgrading == nil && (w.resources[0] ?? 0) == bank2, "never twice")
        w.apply(0, ["upgrade", [b.id], "guns"])
        w.apply(0, ["upgrade", [b.id], "supply"])
        check(b.upgrading == nil, "only where it applies")

        (w, b) = setup()
        let bank3 = w.resources[0] ?? 0
        w.apply(0, ["upgrade", [b.id], "armor"])
        _ = run(w, 5)
        w.apply(0, ["cancelup", b.id])
        check(b.upgrading == nil && (w.resources[0] ?? 0) == bank3, "cancelling refunds")

        (w, b) = setup()
        w.resources[0] = 10
        w.apply(0, ["upgrade", [b.id], "hp"])
        check(b.upgrading == nil && (w.resources[0] ?? 0) == 10, "not enough crystal")

        // Point defence: the Command Center shoots back once it has the gun, and not before.
        (w, b) = setup()
        let raider = SUnit(world: w, kind: .marine, team: 1, x: b.x + hqGunRange - 30, y: b.y); w.add(raider)
        raider.command(.idle)
        w.updateVisibility()
        let hpBefore = raider.hp
        _ = run(w, 4)
        check(raider.hp == hpBefore, "an unupgraded Command Center is unarmed")
        w.apply(0, ["upgrade", [b.id], "defense"])
        _ = run(w, UpgradeKind.defense.stats.time + 1)
        check(b.upgrades.contains(.defense) && b.armed, "point defence installs on the Command Center")
        raider.hp = hpBefore
        _ = run(w, 4)
        check(raider.hp < hpBefore, "and then it fires on a raider at \(Int(hqGunRange))")

        print(ok ? "UPGRADE TEST PASSED" : "UPGRADE TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_SIEGETEST=1: siege mode on the server simulation — the transition, reach, blind spot, auto-unsiege on
    /// a move, and heavier shells — matching linux/tests/test_siege.py.
    static func runSiegeTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }
        func fresh() -> (SWorld, SBuilding) {
            let map = SMapGen.generate("twin_ridges")
            let players = (0..<2).map { SPlayer(slot: $0, name: "P\($0)", team: $0 + 1, isAI: false, start: $0) }
            let w = SWorld(map: map, players: players, difficulty: .normal)
            return (w, w.buildings.first { $0.team == 0 && $0.kind == .hq }!)
        }
        func unit(_ w: SWorld, _ k: UnitKind, _ team: Int, _ x: Double, _ y: Double) -> SUnit {
            let u = SUnit(world: w, kind: k, team: team, x: x, y: y)
            w.add(u)
            w.updateVisibility()     // placed after the first fog pass: let it see, as the next tick would
            return u
        }
        func run(_ w: SWorld, _ secs: Double, until done: () -> Bool = { false }) -> Bool {
            var t = 0.0
            while t < secs { w.step(1.0 / 30); w.events.removeAll(); t += 1.0 / 30; if done() { return true } }
            return done()
        }

        var (w, hq) = fresh()
        let r = unit(w, .marine, 0, hq.x + 100, hq.y)
        w.apply(0, ["siege", [r.id], true])
        check(r.mode == .mobile, "only tanks can siege")

        (w, hq) = fresh()
        var t = unit(w, .tank, 0, hq.x + 200, hq.y)
        w.apply(0, ["siege", [t.id], true])
        let bait = unit(w, .marine, 1, t.x + 150, t.y)
        let hp0 = bait.hp
        _ = run(w, siegeTransition - 0.2)
        check(t.mode == .sieging && bait.hp == hp0, "nothing fires while digging in")
        _ = run(w, 0.4)
        check(t.mode == .sieged && t.attackRange == siegeRange, "dug in after \(siegeTransition)s")

        (w, hq) = fresh()
        t = unit(w, .tank, 0, hq.x + 200, hq.y)
        t.mode = .sieged
        let far = unit(w, .marine, 1, t.x + 300, t.y)          // beyond mobile 230, inside sieged 340
        let x0 = t.x
        w.apply(0, ["attack", [t.id], far.id, false])
        check(run(w, 15) { far.dead } && t.x == x0, "a sieged tank hits at 300 and holds its position")

        (w, hq) = fresh()
        t = unit(w, .tank, 0, hq.x + 200, hq.y)
        t.mode = .sieged
        let close = unit(w, .worker, 1, t.x + 40, t.y)          // inside the 90 minimum
        w.apply(0, ["attack", [t.id], close.id, false])
        _ = run(w, 8)
        check(!close.dead && !t.inRange(close), "the blind spot is real")

        (w, hq) = fresh()
        t = unit(w, .tank, 0, hq.x + 200, hq.y)
        t.mode = .sieged
        w.apply(0, ["move", [t.id], hq.x + 700, hq.y, false, false])
        _ = run(w, 1.0 / 30)
        check(t.mode == .unsieging, "a move order packs the tank up first")
        _ = run(w, siegeTransition + 0.2)
        let x1 = t.x
        _ = run(w, 2)
        check(t.mode == .mobile && t.x > x1 + 30, "and then it goes")

        func damage(sieged: Bool) -> Double {
            let (w, _) = fresh()
            let target = w.buildings.first { $0.team == 1 && $0.kind == .hq }!
            let t = unit(w, .tank, 0, target.x - 200, target.y)     // in range for both modes, outside the blind spot
            t.mode = sieged ? .sieged : .mobile
            w.apply(0, ["attack", [t.id], target.id, false])
            let before = target.hp
            _ = run(w, 6)
            return before - target.hp
        }
        let ds = damage(sieged: true), dm = damage(sieged: false)
        check(ds > dm && dm > 0, String(format: "sieged shells hit harder (%.0f vs %.0f in 6s)", ds, dm))

        print(ok ? "SIEGE TEST PASSED" : "SIEGE TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_TEAMSTEST=1: single-player teams — the deal, a 2v2 played to the finish, and the title-screen lineup
    /// text (printed so it can be compared with the Python edition's).
    static func runTeamsTest() -> Never {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print("  \(cond ? "ok  " : "FAIL") \(what)"); ok = ok && cond }

        let server = GameServer.singlePlayer(opponents: 3, difficulty: 1, mapId: "four_corners", teams: 2)
        let dealt = Array(server.slotTeams.prefix(4))
        print("teams test: four_corners, 3 opponents, 2 teams -> \(dealt)")
        check(dealt == [1, 2, 1, 2], "players are dealt round-robin, like the lobby presets")

        let map = SMapGen.generate("four_corners")
        let players = (0..<4).map { SPlayer(slot: $0, name: "P\($0)", team: teamOf(slot: $0, teams: 2), isAI: true, start: $0) }
        let w = SWorld(map: map, players: players, difficulty: .normal)
        check(w.allied(0, 2) && !w.allied(0, 1) && !w.allied(0, 3), "You and Computer 2 are allies; 1 and 3 are not")
        while !w.gameOver && w.elapsed < 1500 { w.step(1.0 / 30); w.events.removeAll() }
        let alive = w.players.values.filter { $0.alive }.map { $0.slot }.sorted()
        let alliances = Set(alive.map { teamOf(slot: $0, teams: 2) })
        print(String(format: "teams test: 2v2 over=%@ at t=%.0fs, winning alliance %@, survivors %@",
                     "\(w.gameOver)", w.elapsed, "\(w.winnerTeam ?? -1)", "\(alive)"))
        check(w.gameOver, "a 2v2 plays to a finish")
        check(alliances.count == 1 && alliances.first == w.winnerTeam, "every survivor is on the winning alliance")

        for (o, t) in [(1, 0), (3, 2), (3, 3), (5, 3), (5, 4), (11, 2), (11, 4)] {
            print("LINEUP \(o) \(t) \(lineupText(opponents: o, teams: t))")
        }
        print(ok ? "TEAMS TEST PASSED" : "TEAMS TEST FAILED")
        exit(ok ? 0 : 1)
    }

    /// FC_WORLDTEST=1: plays an AI-only game on every map with the server simulation and exits.
    static func runWorldTest() -> Never {
        var ok = true
        for m in SMapGen.catalog {
            let map = SMapGen.generate(m.id)
            let players = (0..<m.players).map { SPlayer(slot: $0, name: "AI\($0)", team: $0 + 1, isAI: true, start: $0) }
            let w = SWorld(map: map, players: players, difficulty: .normal, seed: 11)     // seeded: the same game every run
            let t0 = Date()
            let limit = m.players > 4 ? 2700.0 : 1500.0     // twelve sides, shields and artillery: longer games
            while !w.gameOver && w.elapsed < limit { w.step(1.0 / 30) }
            // A twelve-way game with shields can outlast the limit without anything being wrong: what the test
            // needs is that the map plays — so on a big map, somebody being eliminated is enough.
            let eliminated = w.players.values.filter { !$0.alive }.count
            ok = ok && (w.gameOver || (m.players > 4 && eliminated > 0))
            let snipers = w.units.filter { $0.kind == .sniper }.count
            let radars = w.buildings.filter { $0.kind == .radar && $0.built }.count
            print(String(format: "%-15@ over=%@ winner=%@ t=%.0fs real=%.1fs walls=%d units=%d snipers=%d radars=%d",
                         m.id as NSString, "\(w.gameOver)", "\(w.winnerTeam ?? -1)", w.elapsed,
                         Date().timeIntervalSince(t0), w.walls.count, w.units.count, snipers, radars))
        }
        print(ok ? "WORLD TEST PASSED" : "WORLD TEST FAILED")
        exit(ok ? 0 : 1)
    }
}

/// Plays through GameScene's own UI entry points (selection, command card, placement, attack-move),
/// so a headless run exercises the same code paths as a human player on the Mac client.
final class MacBot {
    unowned let scene: GameScene
    private var lastAct: CGFloat = -1
    private var attackAt: CGFloat = 200

    init(scene: GameScene) { self.scene = scene }

    private var mine: [Building] { scene.buildings.filter { $0.team.isLocal } }

    private func press(_ title: String) {
        scene.commandButtons().first { $0.title == title }?.action()
    }

    private func site(for k: BuildingKind, near hq: Building) -> CGPoint? {
        for _ in 0..<60 {
            let a = CGFloat.random(in: 0...(2 * .pi)), d = CGFloat.random(in: 200...420)
            let p = scene.snapped(hq.position + CGPoint(x: cos(a), y: sin(a)) * d)
            if scene.canPlace(k, at: p, margin: 24) && scene.fog.isExplored(p)
                && scene.crystals.allSatisfy({ $0.position.distance(to: p) > 150 }) { return p }
        }
        return nil
    }

    func tick() {
        guard scene.elapsed - lastAct > 0.5, let hq = mine.first(where: { $0.kind == .hq }) else { return }
        lastAct = scene.elapsed
        let units = scene.units.filter { $0.team.isLocal }
        let workers = units.filter { $0.kind == .worker }
        if workers.count < 12 && hq.queue.isEmpty {
            scene.setSelection([hq])
            press("Engineer")
        }
        let building = workers.contains { $0.netStatus == 6 }
        if !building, let w = workers.first(where: { [0, 4, 5].contains($0.netStatus) }) {
            var want: BuildingKind?
            if scene.mySupplyCap - scene.mySupplyUsed < 4 && scene.myResources >= 100 { want = .depot }
            else if !mine.contains(where: { $0.kind == .barracks }) && scene.myResources >= 150 { want = .barracks }
            else if mine.filter({ $0.kind == .barracks }).count < 2 && scene.myResources >= 300 { want = .barracks }
            if let k = want, let p = site(for: k, near: hq) {
                scene.setSelection([w])
                scene.beginPlacement(k)
                scene.tryPlace(k, at: p, keep: false)
            }
        }
        for b in mine where b.kind == .barracks && b.built && b.queue.count < 2 {
            scene.setSelection([b])
            press("Ranger")
        }
        let army = units.filter { $0.kind != .worker }
        if scene.elapsed > attackAt && !army.isEmpty {
            attackAt = scene.elapsed + 45
            let enemies = scene.buildings.filter { !$0.team.isFriendly }
            let target = enemies.min { $0.position.distance(to: hq.position) < $1.position.distance(to: hq.position) }?.position
                ?? jArr(scene.net?.map["starts"]).map { CGPoint(x: jNum(jArr($0)[0]), y: jNum(jArr($0)[1])) }
                    .filter { $0.distance(to: hq.position) > 500 }.randomElement()
            if let tp = target {
                scene.setSelection(army)
                scene.issueAttackMove(at: tp)
            }
        }
        scene.setSelection([])
    }

    func lookAtArmy() {
        let army = scene.units.filter { $0.team.isLocal && $0.kind != .worker }
        if let u = army.first {
            scene.setSelection(army)
            scene.centerCamera(on: u.position)
        } else if let hq = mine.first {
            scene.centerCamera(on: hq.position)
        }
    }
}
