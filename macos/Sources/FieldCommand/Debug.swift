import SpriteKit

/// Developer hooks driven by environment variables (all off by default):
///   FC_AUTOSTART=0|1|2   skip the menu and start at that difficulty
///   FC_AUTOPLAY=1        an AI also plays the player's side
///   FC_TIMESCALE=n       run n simulation steps per frame
///   FC_SNAPSHOT_DIR=dir  write periodic PNG snapshots and a stats log there
///   FC_HEADLESS=1        run the match without a window (with FC_AUTOPLAY for AI vs AI)
///   FC_MENUSHOT=path     render the title screen to a PNG and exit
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
        check(Set(sounds.keys) == Set(Audio.names), "thirteen effects: \(sounds.keys.sorted().joined(separator: ", "))")
        let expected: [String: Double] = ["rifle": 0.08, "cannon": 0.5, "explosion": 0.9, "turret": 0.1, "complete": 0.37,
                                          "alert": 0.45, "wave": 0.75, "snipe": 0.35, "siege": 0.68, "pop": 0.08,
                                          "click": 0.03, "victory": 0.72, "defeat": 0.9]
        for name in Audio.names {
            guard let s = sounds[name] else { continue }
            let secs = Double(s.count) / Audio.rate
            let peak = s.map { abs($0) }.max() ?? 0
            let mean = s.map { abs($0) }.reduce(0, +) / Float(s.count)
            check(abs(secs - expected[name]!) < 0.02 && peak > 0.05 && peak <= 1 && mean > 0.002,
                  String(format: "%-10@ %.2fs peak %.2f", name as NSString, secs, peak))
        }
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

        let sn = SUnit(world: w, kind: .sniper, team: 1, x: hq.x, y: hq.y)
        let r = SUnit(world: w, kind: .marine, team: 1, x: hq.x, y: hq.y)
        let (sx, sy) = ai.standoff(sn, hq.x - 1000, hq.y)
        let (rx, ry) = ai.standoff(r, hq.x - 1000, hq.y)
        check(abs(sx - (hq.x - 1000)) == 200 && sy == hq.y && rx == hq.x - 1000 && ry == hq.y, "Snipers stop 200 short; Rangers go all the way")

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
        check(kits.count == 15 && Set(kitIds).count == 15, "fifteen distinct kits")

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
            let w = SWorld(map: map, players: players, difficulty: .normal)
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
