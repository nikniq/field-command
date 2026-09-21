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

    private static func snapshot(_ g: GameScene, dir: String, name: String) {
        log(g, dir: dir)
        guard let v = g.view, shots < 40 else { return }
        shots += 1
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let tex = v.texture(from: g, crop: g.visibleWorldRect()) {
            write(tex.cgImage(), to: "\(dir)/\(name)_view.png")
        }
        if let tex = v.texture(from: g.world, crop: CGRect(origin: .zero, size: worldSize)) {
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
            while !w.gameOver && w.elapsed < 1500 { w.step(1.0 / 30) }
            ok = ok && w.gameOver
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
