import SpriteKit

/// Multiplayer client mode for GameScene: the scene mirrors a server-hosted game instead of simulating it.
/// Entities are created and updated from snapshots, effects are replayed from server events, and player
/// orders are sent to the server as commands.
extension GameScene {
    // MARK: Setup

    func setupNetMap(_ net: NetSession) {
        let map = net.map
        setWorldSize(map: map)
        fog = FogOfWar()  // sized from the map just loaded
        if let bits = net.explored { fog.restore(explored: SaveGame.bitsIn(bits, count: fog.cellCount)) }
        clearings = jArr(map["clearings"]).map { a in
            let v = jArr(a)
            return (CGPoint(x: jNum(v[0]), y: jNum(v[1])), jNum(v[2]))
        }
        roads = jArr(map["roads"]).map { r in jArr(r).map { p in CGPoint(x: jNum(jArr(p)[0]), y: jNum(jArr(p)[1])) } }
        walls = Terrain.walls(map).map { $0.rect }
        mapKey = jStr(map["id"]).isEmpty ? jStr(map["name"]) : jStr(map["id"])
        // The server hands out start positions in slot order.
        let order = net.players.keys.sorted()
        let starts = jArr(map["starts"])
        if let i = order.firstIndex(of: net.slot), i < starts.count {
            let s = jArr(starts[i])
            playerStart = CGPoint(x: jNum(s[0]), y: jNum(s[1]))
        }
        for c in net.startCrystals {
            let crystal = Crystal(at: CGPoint(x: jNum(c[1]), y: jNum(c[2])), amount: jInt(c[3]), variant: jInt(c[4]))
            crystal.netId = jInt(c[0])
            net.crystals[crystal.netId] = crystal
            addCrystal(crystal)
        }
    }

    /// Trees from the server's map data: [x, y, radius, variant, angleDegrees, scale].
    var netTrees: [(CGPoint, CGFloat, Int, CGFloat, CGFloat)]? {
        guard let net else { return nil }
        return jArr(net.map["trees"]).map { t in
            let v = jArr(t)
            return (CGPoint(x: jNum(v[0]), y: jNum(v[1])), jNum(v[2]), jInt(v[3]), jNum(v[4]) * .pi / 180, jNum(v[5]))
        }
    }

    // MARK: Per-frame

    func netUpdate(_ dt: CGFloat) {
        guard let net else { return }
        for m in net.conn.messages() {
            switch jStr(m["t"]) {
            case "snap": applySnapshot(m, net)
            case "end":
                net.winnerTeam = m["winner_team"] is NSNull ? nil : jInt(m["winner_team"])
                net.finalStats = jDict(m["stats"])
                var series: [Int: [Int]] = [:]
                for (k, v) in jDict(m["history"]) { if let s = Int(k) { series[s] = jArr(v).map { jInt($0) } } }
                if !series.isEmpty { net.finalHistory = ((m["history_step"] as? NSNumber)?.doubleValue ?? historyStep, series) }
                if !gameOver { endGame(won: net.winnerTeam == net.myAlliance) }
            case "lobby": net.lobbyMessage = m
            case "chat": netEvent(["chat", jInt(m["slot"]), jStr(m["text"])], net)
            case "disconnected":
                net.disconnected = jStr(m["text"])
                if !gameOver {
                    gameOver = true
                    hud.showDisconnected(net.disconnected ?? "")
                }
            default: break
            }
        }
        // Interpolate between the previous and latest snapshot.
        if let t0 = net.snapTime {
            let k = CGFloat(min(1, (ProcessInfo.processInfo.systemUptime - t0) / net.interval))
            for u in units {
                guard let (p0, a0, g0) = u.netFrom, let (p1, a1, g1) = u.netTo else { continue }
                u.position = p0 + (p1 - p0) * k
                u.body.zRotation = angleLerp(a0, a1, k)
                u.gun?.zRotation = angleLerp(g0, g1, k)
                if !gamePaused { u.trackTravel() }
            }
        }
        elapsed = net.serverTime
        updateNetShells(dt)
        fogTimer -= dt
        if fogTimer <= 0 {
            fogTimer = 0.1
            updateFog()
        }
    }

    private func applySnapshot(_ m: [String: Any], _ net: NetSession) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = net.snapTime { net.interval = max(0.05, min(0.3, 0.8 * net.interval + 0.2 * (now - last))) }
        net.snapTime = now
        net.serverTime = jNum(m["time"])
        net.missionProgress = jInt(m["ms"])
        var hold: [Int: Double] = [:]
        for (k, v) in jDict(m["hold"]) { if let t = Int(k) { hold[t] = Double(jNum(v)) } }
        net.hold = hold
        net.reinforceLeft = Double(jNum(m["rf"]))
        net.smokes = jArr(m["sm"]).map { jArr($0) }.filter { $0.count == 3 }.map { (CGPoint(x: jNum($0[0]), y: jNum($0[1])), Double(jNum($0[2]))) }
        updateSmokes()
        net.resources = jInt(m["res"])
        let mask = jInt(m["kit"])
        let owned = Set(kitIds.enumerated().filter { mask & (1 << $0.offset) != 0 }.map { $0.element })
        if owned != net.kits {
            net.kits = owned
            hud.refreshOverlay()          // the Armory, if open, shows what was just issued
        }
        let sup = jArr(m["sup"])
        if sup.count == 2 {
            net.supplyUsed = jInt(sup[0])
            net.supplyCap = jInt(sup[1])
        }
        let orders = jDict(m["o"])

        var seen = Set<Int>()
        for raw in jArr(m["u"]) {
            let v = jArr(raw)
            guard v.count >= 9 else { continue }
            let id = jInt(v[0])
            seen.insert(id)
            let pos = CGPoint(x: jNum(v[3]), y: jNum(v[4]))
            let angle = jNum(v[5]) * .pi / 180, gunAngle = jNum(v[6]) * .pi / 180
            let u: Unit
            if let existing = net.units[id] {
                u = existing
                u.netFrom = (u.position, u.body.zRotation, u.gun?.zRotation ?? angle)
            } else {
                let kind = NetProtocol.unitKinds[min(NetProtocol.unitKinds.count - 1, max(0, jInt(v[2])))]
                u = Unit(kind: kind, team: Team(rawValue: jInt(v[1])), at: pos, game: self)
                u.netId = id
                u.body.zRotation = angle
                u.gun?.zRotation = gunAngle
                u.netFrom = (pos, angle, gunAngle)
                net.units[id] = u
                addUnit(u)
            }
            u.netTo = (pos, angle, gunAngle)
            if v.count > 9 { u.setMode(SiegeMode(rawValue: jInt(v[9])) ?? .mobile) }
            if v.count > 10 { u.setRank(jInt(v[10])) }
            if v.count > 12 {
                u.abilityCd = Double(jNum(v[11]))
                u.setMarked(jInt(v[12]) == 1)
            }
            let hp = jNum(v[7])
            if hp != u.hp {
                if hp < u.hp { u.flashHit() }
                u.hp = hp
                u.updateHPBar()
            }
            u.carrying = jInt(v[8])
            u.cargoNode?.isHidden = u.carrying == 0
            if let o = orders[String(id)] as? [Any], o.count == 3 {
                u.netStatus = jInt(o[0])
                u.netQueued = jInt(o[1])
                let p = jArr(o[2])
                u.netPoints = stride(from: 0, to: p.count - 2, by: 3).map { (jInt(p[$0]), CGPoint(x: jNum(p[$0 + 1]), y: jNum(p[$0 + 2]))) }
            }
        }
        for (id, u) in net.units where !seen.contains(id) {
            u.dead = true
            if u.kind != .tank && fog.isVisible(u.position) { addFallen(kind: u.kind, team: u.team, at: u.position, angle: u.body.zRotation) }
            u.removeFromParent()
            net.units[id] = nil
        }
        units.removeAll { $0.dead }

        seen.removeAll()
        for raw in jArr(m["b"]) {
            let v = jArr(raw)
            guard v.count >= 12 else { continue }
            let id = jInt(v[0])
            seen.insert(id)
            let b: Building
            if let existing = net.buildings[id] {
                b = existing
            } else {
                let kind = NetProtocol.buildingKinds[min(NetProtocol.buildingKinds.count - 1, max(0, jInt(v[2])))]
                let built = jInt(v[6]) == 1
                b = Building(kind: kind, team: Team(rawValue: jInt(v[1])), at: CGPoint(x: jNum(v[3]), y: jNum(v[4])),
                             built: built, game: self)
                b.netId = id
                net.buildings[id] = b
                addBuilding(b)
                if b.team.isLocal && b.kind == .hq && net.cameraPending {
                    net.cameraPending = false
                    centerCamera(on: b.position + (CGPoint(x: worldSize.width / 2, y: worldSize.height / 2) - b.position) * 0.08)
                }
            }
            let rally = jArr(v[11])
            b.applyNet(hp: jNum(v[5]), built: jInt(v[6]) == 1, progress: jNum(v[7]) / 100,
                       queueProgress: jNum(v[8]) / 100, gunAngle: jNum(v[9]) * .pi / 180,
                       queue: jArr(v[10]).map { NetProtocol.unitKinds[min(NetProtocol.unitKinds.count - 1, max(0, jInt($0)))] },
                       rally: rally.count == 2 ? CGPoint(x: jNum(rally[0]), y: jNum(rally[1])) : nil)
            if v.count > 14 { b.applyShield(CGFloat(jNum(v[14]))) }
            if v.count > 13 {
                let up = jArr(v[13])
                let inProgress = up.count == 2 ? UpgradeKind(rawValue: jInt(up[0])).map { ($0, jNum(up[1]) / 100) } : nil
                b.applyUpgrades(mask: jInt(v[12]), inProgress: inProgress)
            }
        }
        for (id, b) in net.buildings where !seen.contains(id) {
            b.dead = true
            b.removeFromParent()
            net.buildings[id] = nil
        }
        buildings.removeAll { $0.dead }

        for t in jArr(m["tw"]) {
            let v = jArr(t)
            guard v.count >= 6 else { continue }
            let id = jInt(v[0])
            let node: TowerNode
            if let existing = towerNodes.first(where: { $0.towerId == id }) {
                node = existing
            } else {
                node = TowerNode(id: id, at: CGPoint(x: jNum(v[1]), y: jNum(v[2])))
                world.addChild(node)
                towerNodes.append(node)
            }
            let o = jInt(v[3]), c = jInt(v[4])
            node.apply(owner: o < 0 ? nil : o, capturing: c < 0 ? nil : c, progress: jNum(v[5]) / 100)
        }
        var liveDerelicts = Set<Int>()
        for raw in jArr(m["dr"]) {
            let v = jArr(raw)
            guard v.count >= 6 else { continue }
            let id = jInt(v[0])
            liveDerelicts.insert(id)
            let node: DerelictNode
            if let existing = derelictNodes.first(where: { $0.derelictId == id }) {
                node = existing
            } else {
                node = DerelictNode(id: id, at: CGPoint(x: jNum(v[1]), y: jNum(v[2])), angle: jNum(v[3]) * .pi / 180)
                world.addChild(node)
                derelictNodes.append(node)
            }
            let c = jInt(v[4])
            node.apply(capturing: c < 0 ? nil : c, progress: jNum(v[5]) / 100)
        }
        for node in derelictNodes where !liveDerelicts.contains(node.derelictId) { node.removeFromParent() }
        derelictNodes.removeAll { !liveDerelicts.contains($0.derelictId) }
        // Crates arrive only while in sight, so what the server sent is the whole list.
        var liveCrates = Set<Int>()
        for c in jArr(m["cr"]) {
            let v = jArr(c)
            guard v.count >= 5 else { continue }
            let id = jInt(v[0])
            liveCrates.insert(id)
            if crateNodes[id] == nil {
                let k = crateKinds[min(crateKinds.count - 1, max(0, jInt(v[3])))]
                let node = CrateNode(id: id, kind: k, amount: jInt(v[4]), at: CGPoint(x: jNum(v[1]), y: jNum(v[2])))
                world.addChild(node)
                crateNodes[id] = node
            }
        }
        for (id, node) in crateNodes where !liveCrates.contains(id) {
            node.removeFromParent()
            crateNodes[id] = nil
        }
        for (i, b) in jArr(m["br"]).enumerated() {
            let v = jArr(b)
            guard v.count >= 4, i < bridgeNodes.count else { continue }
            let node = bridgeNodes[i]
            node.bridgeId = jInt(v[0])
            node.apply(intact: jInt(v[1]) == 1, hp: jNum(v[2]), progress: jNum(v[3]) / 100)
        }

        var amounts: [Int: Int] = [:]
        for c in jArr(m["c"]) {
            let v = jArr(c)
            if v.count == 2 { amounts[jInt(v[0])] = jInt(v[1]) }
        }
        for (id, c) in net.crystals {
            if let a = amounts[id] {
                c.setAmount(a)
            } else if !c.dead {
                c.dead = true
                c.run(.sequence([.group([.fadeOut(withDuration: 0.5), .scale(to: 0.3, duration: 0.5)]), .removeFromParent()]))
                net.crystals[id] = nil
            }
        }
        crystals.removeAll { $0.dead }
        for (s, alive) in jDict(m["p"]) {
            if let slot = Int(s) { net.players[slot]?.alive = jInt(alive) == 1 }
        }
        let before = selection.count
        selection.removeAll { $0.dead }
        if selection.count != before { hud.selectionChanged() }
        for e in jArr(m["e"]) { netEvent(jArr(e), net) }
        autosaveIfDue()
    }

    // MARK: Events

    private func netEvent(_ e: [Any], _ net: NetSession) {
        guard let kind = e.first as? String else { return }
        func p(_ i: Int) -> CGPoint { CGPoint(x: jNum(e[i]), y: jNum(e[i + 1])) }
        switch kind {
        case "tracer":
            // 0 rifle, 1 turret, 2 sniper — same table as the Python client's TRACER_COLORS.
            let style = jInt(e[5])
            let colors: [NSColor] = [.rgb(1, 0.88, 0.5), .rgb(1, 0.75, 0.4), .rgb(0.78, 0.95, 1.0)]
            let widths: [CGFloat] = [1.4, 2, 1.1]
            let i = min(max(0, style), colors.count - 1)
            tracer(from: p(1), to: p(3), color: colors[i], width: widths[i])
        case "sound":
            // Heard when it happens on screen (or just off it), as in the Python client.
            if visibleWorldRect().insetBy(dx: -150, dy: -150).contains(p(2)) {
                let name = jStr(e[1])
                Audio.play(name, minGap: Audio.minGaps[name] ?? 0)
                threat.note(name, Double(elapsed))
            }
        case "muzzle": muzzleFlash(at: p(1), angle: jNum(e[3]), size: jNum(e[4]))
        case "sparks":
            let colors: [String: NSColor] = ["hit": .rgb(1, 0.8, 0.4), "crystal": Palette.crystal, "amber": Palette.amber,
                                             "heal": .rgb(0.55, 1, 0.67)]
            emit(FX.sparks(count: jInt(e[3]), speed: jNum(e[4]), color: colors[jStr(e[5])] ?? Palette.amber), at: p(1), life: 0.6)
        case "smoke": emit(FX.smokeBurst(size: jNum(e[3])), at: p(1), life: 3)
        case "explode":
            explosion(at: p(1), size: jNum(e[3]), delay: e.count > 5 ? Double(jNum(e[5])) : 0, scorch: jInt(e[4]) == 1)
        case "flash":
            let key = jStr(e[4])
            let color = key.hasPrefix("team") ? Team(rawValue: Int(key.dropFirst(4)) ?? 0).lightColor
                : key == "shield" ? NSColor.rgb(0.45, 0.85, 1.0) : key == "mark" ? Palette.amber : NSColor.rgb(1, 0.7, 0.3)
            glowFlash(at: p(1), size: jNum(e[3]), color: color, duration: 0.5)
        case "recoil": net.units[jInt(e[1])]?.netRecoil()
        case "pulse": net.units[jInt(e[1])]?.netPulse()
        case "shell": netShell(from: p(1), to: p(3), duration: jNum(e[5]), arc: e.count > 7 && jInt(e[7]) == 1)
        case "wreck": addWreck(at: p(1), angle: jNum(e[3]) * .pi / 180, team: Team(rawValue: jInt(e[4])))
        case "rubble": decal(Art.rubble, at: p(1), size: jNum(e[3]), life: 60)
        case "shake": if visibleWorldRect().contains(p(1)) { shake(jNum(e[3])) }
        case "msg":
            hud.flash(jStr(e[2]), color: jStr(e[3]) == "bad" ? Palette.bad : Palette.text)
        case "alert": alertAttack(at: p(2))
        case "ping": allyPing(slot: jInt(e[1]), at: p(2), kind: e.count > 4 ? jInt(e[4]) : 0)
        case "crate": crateTaken(slot: jInt(e[1]), at: p(2), kind: jStr(e[4]), amount: jInt(e[5]))
        case "income":
            let at = p(2)
            if visibleWorldRect().contains(at) { floatText("+\(jInt(e[4]))", at: at + CGPoint(x: 0, y: 14), color: Palette.crystal) }
        case "built":
            if let k = NetProtocol.buildingKind(jStr(e[2])) {
                hud.flash("\(k.stats.name) complete", color: Palette.good)
                playSound("Glass")
            }
            hud.selectionChanged()
        case "trained":
            if let k = NetProtocol.unitKinds.first(where: { NetProtocol.name($0) == jStr(e[2]) }) { trainedKinds[k, default: 0] += 1 }
        case "wave": enemyWaveLaunched()
        case "bdead":
            guard let k = NetProtocol.buildingKind(jStr(e[2])) else { break }
            let owner = Team(rawValue: jInt(e[1]))
            if owner.isLocal {
                hud.flash("\(k.stats.name) destroyed", color: Palette.bad)
            } else if owner.isFriendly {
                hud.flash("Ally's \(k.stats.name) destroyed", color: Palette.amber)
            } else {
                hud.flash("Enemy \(k.stats.name) destroyed", color: Palette.good)
            }
        case "kit":
            if let k = kits.first(where: { $0.id == jStr(e[2]) }) {
                hud.flash("\(k.name) issued to every \(k.unit.stats.name)", color: Palette.good)
                playSound("Glass")
            }
        case "tower":
            let slot = jInt(e[1])
            if slot == net.slot {
                hud.flash("Watchtower captured — you now see far around it", color: Palette.good)
            } else if Team(rawValue: slot).isFriendly {
                hud.flash("\(playerName(Team(rawValue: slot))) captured a Watchtower", color: Palette.amber)
            } else {
                hud.flash("\(playerName(Team(rawValue: slot))) took a Watchtower", color: Palette.bad)
                alertAttack(at: p(3))
            }
        case "rank":
            if jInt(e[1]) == net.slot, let u = net.units[jInt(e[2])] {
                hud.flash("\(u.displayName) promoted to rank \(jInt(e[3]))", color: Palette.good)
            }
        case "upgraded":
            if let bk = NetProtocol.buildingKind(jStr(e[2])),
               let uk = UpgradeKind.allCases.first(where: { $0.wireName == jStr(e[3]) }) {
                hud.flash("\(bk.stats.name): \(uk.stats.name) installed", color: Palette.good)
                playSound("Glass")
            }
        case "bridge":
            let down = jInt(e[2]) == 0
            hud.flash(down ? "Bridge destroyed" : "Bridge rebuilt", color: down ? Palette.bad : Palette.good)
            if down { alertAttack(at: p(3)) }
        case "elim":
            if jInt(e[1]) == net.slot {
                hud.flash("You have been eliminated", color: Palette.bad)
                if !gameOver { hud.showEliminated() }
            } else if net.players.count > 2 {
                hud.flash("\(jStr(e[2])) has been eliminated", color: Palette.amber)
            }
        case "gameover":
            let winner = jInt(e[1])
            net.winnerTeam = winner < 0 ? nil : winner
            if !gameOver { endGame(won: net.winnerTeam == net.myAlliance) }
        case "chat":
            let slot = jInt(e[1])
            let who = slot < 0 ? "Server" : (net.players[slot]?.name ?? "?")
            hud.flash("\(who): \(jStr(e[2]))", color: slot < 0 ? Palette.text : Team(rawValue: slot).lightColor)
            playSound("Pop")
        default:
            break
        }
    }

    // MARK: Visual-only shells

    private func netShell(from a: CGPoint, to b: CGPoint, duration: CGFloat, arc: Bool = false) {
        guard let net else { return }
        let node = SKSpriteNode(texture: Art.glow)
        node.size = arc ? CGSize(width: 26, height: 26) : CGSize(width: 14, height: 14)
        if arc {        // the shell itself, so an artillery round reads as a thing in the air, not a spark
            let body = SKShapeNode(circleOfRadius: 4)
            body.fillColor = .rgb(0.24, 0.2, 0.16); body.strokeColor = .clear; body.blendMode = .alpha
            node.addChild(body)
        }
        node.color = .rgb(1, 0.85, 0.45)
        node.colorBlendFactor = 1
        node.blendMode = .add
        node.position = a
        effectLayer.addChild(node)
        let trail = FX.trail()
        trail.targetNode = effectLayer
        node.addChild(trail)
        net.shells.append(NetShell(node: node, from: a, to: b, duration: max(0.05, duration), t: 0, arc: arc))
    }

    private func updateNetShells(_ dt: CGFloat) {
        guard let net, !net.shells.isEmpty else { return }
        for i in net.shells.indices {
            net.shells[i].t += dt
            let s = net.shells[i]
            let f = min(1, s.t / s.duration)
            // Artillery shells climb high and slow so you can follow them across the screen
            let d = s.from.distance(to: s.to)
            let arc = sin(f * .pi) * (s.arc ? min(220, d * 0.35) : min(40, d * 0.12))
            s.node.position = s.from + (s.to - s.from) * f + CGPoint(x: 0, y: arc)
            if f >= 1 { s.node.removeFromParent() }
        }
        net.shells.removeAll { $0.t >= $0.duration }
    }

    // MARK: Commands

    func sendNet(_ cmd: [Any]) { if net?.spectating != true { net?.send(cmd) } }

    /// A single-player game is recorded on its way out, so the last one can always be watched again.
    func recordReplay() {
        guard let net, net.isLocal, !net.spectating, let w = GameServer.hosted?.simulation else { return }
        try? Replay.write(w, viewer: net.slot)
    }

    func netSmartCommand(at p: CGPoint, queue: Bool) {
        unitVoice("ack_")
        let us = selectedOwnUnits
        if !us.isEmpty {
            // A standing bridge is a road: right-click walks across it. Demolition is deliberate — A then click.
            if let br = bridge(at: p), !br.intact, let w = us.first(where: { $0.kind == .worker }) {
                sendNet(["rebuild", w.netId, br.bridgeId, queue])
                marker(at: br.position, color: Palette.amber, size: 34)
                let rest = us.filter { $0 !== w }
                if !rest.isEmpty { sendNet(["move", netIds(rest), p.x, p.y, queue, false]) }
                return
            }
            let target = entity(at: p)
            if let t = target, !t.team.isFriendly {
                sendNet(["attack", netIds(us), t.netId, queue])
                marker(at: t.position, color: Palette.bad, size: 26)
                return
            }
            if fog.isExplored(p), let c = crystal(at: p) {
                sendNet(["gather", netIds(us), c.netId, queue])
                marker(at: c.position, color: Palette.crystal, size: 26)
                return
            }
            // Engineers mend a damaged friendly building or tank, Medics treat the wounded on foot. Ahead of the
            // HQ branch, so an Engineer carrying crystal to a damaged Command Center repairs it rather than only
            // dropping off.
            if let t = target {
                let menders = menders(us, for: t)
                if !menders.isEmpty {
                    sendNet(["repair", netIds(menders), t.netId, queue])
                    marker(at: t.position, color: Palette.amber, size: ((t as? Building)?.half ?? (t as? Unit)?.radius ?? 10) + 10)
                    let rest = us.filter { u in !menders.contains { $0 === u } }
                    if !rest.isEmpty { sendNet(["move", netIds(rest), p.x, p.y, queue, false]) }
                    return
                }
            }
            if let b = target as? Building, b.team.isLocal, b.kind == .hq, b.built {
                let carriers = us.filter { $0.kind == .worker && $0.carrying > 0 }
                let rest = us.filter { !($0.kind == .worker && $0.carrying > 0) }
                if !carriers.isEmpty { sendNet(["return", netIds(carriers), queue]) }
                if !rest.isEmpty { sendNet(["move", netIds(rest), p.x, p.y, queue, false]) }
                return
            }
            sendNet(["move", netIds(us), p.x, p.y, queue, false])
            marker(at: p, color: Palette.good, size: 18)
            return
        }
        let producers = selectedOwnBuildings.filter { !$0.stats.produces.isEmpty }
        if !producers.isEmpty {
            sendNet(["rally", netIds(producers), p.x, p.y])
            marker(at: p, color: Palette.good, size: 18)
        }
    }

    func netIds(_ es: [Entity]) -> [Int] { es.map { $0.netId } }

    // MARK: Leaving

    func backToLobby() {
        guard let net, net.conn.alive else {
            toMenu()
            return
        }
        Team.resetForSinglePlayer()
        view?.presentScene(LobbyScene(size: size, conn: net.conn, slot: net.slot, initial: net.lobbyMessage),
                           transition: .fade(withDuration: 0.4))
    }

    func leaveNetGame() {
        net?.conn.close()
        stopHostedServer()
        Team.resetForSinglePlayer()
    }

    func endStatsLines() -> [String] {
        guard let net else {
            return ["Mission time  \(formatTime(elapsed))   ·   Difficulty  \(difficulty.name)",
                    "Units trained  \(unitsTrained[0])   ·   Units lost  \(unitsLost[0])   ·   Enemies destroyed  \(unitsLost[1])",
                    "Crystal mined  \(crystalsMined[0])"]
        }
        var lines = ["Mission time  \(formatTime(elapsed))   ·   \(jStr(net.map["name"]))   ·   AI  \(net.difficulty.name)"]
        let stats = net.finalStats ?? [:]
        for (key, value) in stats.sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }) {
            let s = jDict(value)
            let you = Int(key) == net.slot ? " (you)" : ""
            lines.append("\(jStr(s["name"]))\(you)  ·  Team \(jInt(s["team"]))  ·  trained \(jInt(s["trained"]))  ·  lost \(jInt(s["lost"]))  ·  mined \(jInt(s["mined"]))")
        }
        return lines
    }
}

struct NetShell {
    let node: SKNode
    let from: CGPoint
    let to: CGPoint
    let duration: CGFloat
    var t: CGFloat
    var arc = false
}

/// Starts a single-player skirmish. The game runs on a private loopback server with the same simulation as
/// multiplayer (maps, pathfinding, AI), so single player and multiplayer always behave the same. Falls back to
/// the built-in SpriteKit simulation if the local server cannot be started.
/// A campaign mission on a private server.
func startMissionGame(_ view: SKView?, size: CGSize, mission m: Mission) {
    startSkirmish(view, size: size, difficulty: Difficulty(rawValue: m.difficulty) ?? .normal, mapId: m.map,
                  opponents: m.opponents, teams: m.teams, mission: m)
}

/// Resumes a saved single-player game on a private server, like `startSkirmish` but from a loaded world.
func resumeSkirmish(_ view: SKView?, size: CGSize, world w: SWorld) {
    let alliances = Set(w.players.values.map { $0.team })
    let teams = alliances.count < w.players.count ? alliances.count : 0
    startSkirmish(view, size: size, difficulty: w.difficulty, mapId: jStr(w.map["id"]), opponents: w.players.count - 1,
                  teams: teams, restoring: w)
}

/// Watches the newest recorded game on a private server.
func watchReplay(_ view: SKView?, size: CGSize, name: String? = nil) {
    guard let which = name ?? Replay.list().first?.name, let r = try? Replay.read(which) else { return }
    startSkirmish(view, size: size, difficulty: Difficulty(rawValue: r.difficulty) ?? .normal, mapId: r.map,
                  opponents: r.players.count - 1, replay: r)
}


func startSkirmish(_ view: SKView?, size: CGSize, difficulty: Difficulty, mapId: String, opponents: Int, teams: Int = 0,
                   restoring: SWorld? = nil, mission: Mission? = nil, replay: Replay? = nil, mode: String = "annihilation",
                   startCrystal crystal: Int = startCrystalOptions[1], startBase base: String = "fresh") {
    func fallback() { showScene(view, GameScene(size: size, difficulty: difficulty), fade: 0.6) }
    stopHostedServer()
    let server = restoring.map { GameServer.singlePlayer(restoring: $0) }
        ?? replay.map { GameServer.singlePlayer(replay: $0) }
        ?? mission.map { GameServer.singlePlayer(mission: $0) }
        ?? GameServer.singlePlayer(opponents: opponents, difficulty: difficulty.rawValue, mapId: mapId, teams: teams, mode: mode,
                                   startCrystal: crystal, startBase: base)
    server.log = { _ in }
    server.timeScale = Double(Settings.gameSpeed)
    do { try server.start() } catch { return fallback() }
    GameServer.hosted = server
    guard let conn = try? NetConnection(host: "127.0.0.1", port: server.port) else {
        stopHostedServer()
        return fallback()
    }
    conn.send(["t": "hello", "name": "You", "version": NetProtocol.version, "client": "mac"])
    var sentStart = false
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        for m in conn.messages() {
            switch jStr(m["t"]) {
            case "lobby" where !sentStart:
                sentStart = true
                conn.send(["t": "start"])
            case "start":
                let net = NetSession(conn: conn, start: m)
                net.skirmish = (mapId, opponents, teams)
                showScene(view, GameScene(size: size, difficulty: difficulty, net: net), fade: 0.6)
                return
            default: break
            }
        }
        usleep(5_000)
    }
    conn.close()
    stopHostedServer()
    fallback()
}
