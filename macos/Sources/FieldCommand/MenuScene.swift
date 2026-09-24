import SpriteKit

/// Title screen: an animated skirmish in the background, difficulty cards and quick settings.
final class MenuScene: SKScene {
    private var cards: [(CGRect, Difficulty, SKSpriteNode)] = []
    private var toggles: [(CGRect, SKSpriteNode, () -> Void)] = []
    private let backdrop = SKNode()
    private let content = SKNode()
    private var built = false
    private var battleTimer: TimeInterval = 0
    private var lastTime: TimeInterval = 0

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMove(to view: SKView) {
        backgroundColor = .rgb(0.03, 0.04, 0.05)
        if !built {
            built = true
            addChild(backdrop)
            addChild(content)
            content.zPosition = 10
        }
        layout()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        if built { layout() }
    }

    private func layout() {
        buildBackdrop()
        buildContent()
    }

    // MARK: - Backdrop

    private func buildBackdrop() {
        backdrop.removeAllChildren()
        let w = size.width, h = size.height
        let tex = Art.ground()
        var y = -h / 2 - 200
        while y < h / 2 {
            var x = -w / 2 - 200
            while x < w / 2 {
                let s = SKSpriteNode(texture: tex)
                s.anchorPoint = .zero
                s.size = CGSize(width: 1024, height: 1024)
                s.position = CGPoint(x: x, y: y)
                s.zPosition = -10
                backdrop.addChild(s)
                x += 1024
            }
            y += 1024
        }
        // Slow drift for a living feel.
        backdrop.run(.repeatForever(.sequence([.moveBy(x: -60, y: 30, duration: 20), .moveBy(x: 60, y: -30, duration: 20)])))

        var rng = SeededRNG(77)
        func place(_ node: SKNode, _ p: CGPoint, z: CGFloat) {
            node.position = p
            node.zPosition = z
            backdrop.addChild(node)
        }
        // Bases in opposite corners
        for (team, sx, sy) in [(Team.player, CGFloat(-1), CGFloat(-1)), (Team.enemy, CGFloat(1), CGFloat(1))] {
            let base = CGPoint(x: sx * (w / 2 - 140), y: sy * (h / 2 - 120))
            for (k, off) in [(BuildingKind.hq, CGPoint.zero), (.barracks, CGPoint(x: -sx * 190, y: 0)), (.turret, CGPoint(x: -sx * 120, y: -sy * 150)),
                             (.depot, CGPoint(x: 0, y: -sy * 160))] {
                let b = SKSpriteNode(texture: Art.building(k, team))
                b.size = Art.buildingCanvas(k)
                place(b, base + off, z: 2)
                if k == .turret {
                    let g = SKSpriteNode(texture: Art.turretGun(team))
                    g.size = CGSize(width: 76, height: 36)
                    g.zRotation = sx > 0 ? .pi + 0.6 : 0.6
                    place(g, base + off, z: 3)
                }
            }
        }
        for i in 0..<8 {
            let a = CGFloat(i) * 0.7
            let c = SKSpriteNode(texture: Art.crystal(i % 3))
            c.size = CGSize(width: 54, height: 60)
            place(c, CGPoint(x: -w / 2 + 330 + cos(a) * 70, y: -h / 2 + 260 + sin(a) * 55), z: 1)
        }
        for _ in 0..<24 {
            let t = SKSpriteNode(texture: Art.tree(Int.random(in: 0...2, using: &rng)))
            t.size = CGSize(width: 84, height: 84)
            t.zRotation = CGFloat.random(in: 0...6, using: &rng)
            let edge = Bool.random(using: &rng)
            let p = edge ? CGPoint(x: CGFloat.random(in: -w / 2...w / 2, using: &rng), y: (Bool.random(using: &rng) ? 1 : -1) * (h / 2 - 10))
                         : CGPoint(x: (Bool.random(using: &rng) ? 1 : -1) * (w / 2 - 10), y: CGFloat.random(in: -h / 2...h / 2, using: &rng))
            place(t, p, z: 4)
        }
        // Advancing squads
        for i in 0..<10 {
            let team: Team = i % 2 == 0 ? .player : .enemy
            let kind: UnitKind = i % 3 == 0 ? .tank : .marine
            let unit = SKNode()
            let body = SKSpriteNode(texture: Art.unit(kind, team))
            body.size = Art.unitSize(kind)
            unit.addChild(body)
            if kind == .tank {
                let t = SKSpriteNode(texture: Art.tankTurret(team))
                t.size = Art.turretSize
                unit.addChild(t)
            }
            let dir: CGFloat = team == .player ? 1 : -1
            let start = CGPoint(x: -dir * (w / 2 + 60), y: CGFloat.random(in: -h / 3...h / 3, using: &rng))
            unit.zRotation = team == .player ? 0.25 : .pi + 0.25
            place(unit, start, z: 3)
            let travel = CGVector(dx: dir * (w + 120), dy: dir * (w + 120) * 0.25)
            let dur = TimeInterval.random(in: 16...28, using: &rng)
            unit.run(.sequence([.wait(forDuration: .random(in: 0...10, using: &rng)),
                                .repeatForever(.sequence([.move(by: travel, duration: dur),
                                                          .move(to: start, duration: 0)]))]))
        }
        let shade = SKSpriteNode(color: NSColor(white: 0, alpha: 0.5), size: CGSize(width: w * 2, height: h * 2))
        place(shade, .zero, z: 8)
        let vignette = SKSpriteNode(texture: Art.vignette)
        vignette.size = CGSize(width: w * 1.15, height: h * 1.15)
        place(vignette, .zero, z: 9)
    }

    /// Periodic distant explosions.
    override func update(_ currentTime: TimeInterval) {
        Audio.Music.update(0)                     // the calm layer alone on the title screen
        let dt = lastTime == 0 ? 0 : currentTime - lastTime
        lastTime = currentTime
        battleTimer -= dt
        if battleTimer <= 0 {
            battleTimer = .random(in: 0.6...1.8)
            let p = CGPoint(x: CGFloat.random(in: -size.width / 2...size.width / 2), y: CGFloat.random(in: -size.height / 2...size.height / 2))
            let s = CGFloat.random(in: 14...30)
            let e = FX.fireBurst(size: s)
            e.position = p
            e.zPosition = 5
            backdrop.addChild(e)
            e.run(.sequence([.wait(forDuration: 2), .removeFromParent()]))
            let sm = FX.smokeBurst(size: s)
            sm.position = p
            sm.zPosition = 5
            backdrop.addChild(sm)
            sm.run(.sequence([.wait(forDuration: 3), .removeFromParent()]))
        }
        guard let v = view, let win = v.window else { return }
        let m = convertPoint(fromView: v.convert(win.mouseLocationOutsideOfEventStream, from: nil))
        for (r, _, bg) in cards {
            let hover = r.contains(m)
            bg.texture = Art.button(r.size, hover ? .hover : .normal)
            bg.setScale(hover ? 1.03 : 1)
        }
        for (r, bg, _) in toggles {
            if bg.name == "accent" {
                bg.texture = Art.button(r.size, r.contains(m) ? .hover : .active, accent: Palette.amber)
            } else {
                bg.texture = Art.button(r.size, r.contains(m) ? .hover : .normal)
            }
        }
    }

    // MARK: - Content

    private func buildContent() {
        content.removeAllChildren()
        cards = []
        toggles = []
        let w = size.width, h = size.height

        let titleY = h * 0.27
        let glow = SKSpriteNode(texture: Art.glow)
        glow.size = CGSize(width: 900, height: 260)
        glow.color = Palette.buttonEdge
        glow.colorBlendFactor = 1
        glow.alpha = 0.35
        glow.position = CGPoint(x: 0, y: titleY)
        content.addChild(glow)
        let shadow = makeLabel("FIELD COMMAND", size: min(92, w / 9), color: NSColor(white: 0, alpha: 0.7), font: Fonts.heavy, align: .center, valign: .center)
        shadow.position = CGPoint(x: 3, y: titleY - 4)
        content.addChild(shadow)
        let title = makeLabel("FIELD COMMAND", size: min(92, w / 9), color: Palette.text, font: Fonts.heavy, align: .center, valign: .center)
        title.position = CGPoint(x: 0, y: titleY)
        content.addChild(title)
        let sub = makeLabel("A  REAL-TIME  STRATEGY  OPERATION", size: 15, color: Palette.amber, font: Fonts.condensed, align: .center, valign: .center)
        sub.position = CGPoint(x: 0, y: titleY - 58)
        content.addChild(sub)

        let cw: CGFloat = 230, ch: CGFloat = 150, gap: CGFloat = 24
        let total = 3 * cw + 2 * gap
        let cy = h * 0.02
        let prompt = makeLabel("SELECT DIFFICULTY", size: 13, color: Palette.dim, font: Fonts.bold, align: .center, valign: .center)
        prompt.position = CGPoint(x: 0, y: cy + ch / 2 + 26)
        content.addChild(prompt)
        let icons: [UnitKind] = [.worker, .marine, .tank]
        for (i, d) in Difficulty.allCases.enumerated() {
            let r = CGRect(x: -total / 2 + CGFloat(i) * (cw + gap), y: cy - ch / 2, width: cw, height: ch)
            let bg = SKSpriteNode(texture: Art.button(r.size, .normal))
            bg.size = r.size
            bg.position = CGPoint(x: r.midX, y: r.midY)
            content.addChild(bg)
            let icon = SKSpriteNode(texture: Art.unit(icons[i], d == .hard ? .enemy : .player))
            let s = Art.unitSize(icons[i])
            let k = 58 / max(s.width, s.height)
            icon.size = CGSize(width: s.width * k, height: s.height * k)
            icon.zRotation = .pi / 2
            icon.position = CGPoint(x: 0, y: 30)
            bg.addChild(icon)
            let name = makeLabel(d.name.uppercased(), size: 24, font: Fonts.heavy, align: .center, valign: .center)
            name.position = CGPoint(x: 0, y: -18)
            bg.addChild(name)
            let blurb = makeLabel(d.blurb, size: 12, color: Palette.dim, font: Fonts.medium, align: .center, valign: .center)
            blurb.position = CGPoint(x: 0, y: -42)
            bg.addChild(blurb)
            let key = makeLabel("\(i + 1)", size: 12, color: Palette.amber, font: Fonts.bold, align: .center, valign: .center)
            key.position = CGPoint(x: -cw / 2 + 16, y: ch / 2 - 16)
            bg.addChild(key)
            if i == Settings.lastDifficulty {
                let tag = makeLabel("LAST PLAYED", size: 9, color: Palette.amber, font: Fonts.bold, align: .right, valign: .center)
                tag.position = CGPoint(x: cw / 2 - 12, y: ch / 2 - 16)
                bg.addChild(tag)
            }
            cards.append((r, d, bg))
        }

        // Quick settings
        let rows: [(String, () -> Void)] = [
            ("Speed: \(Settings.speedName)", { Settings.speedIndex += 1 }),
            ("Edge scroll: \(Settings.edgeScroll ? "On" : "Off")", { Settings.edgeScroll.toggle() }),
            ("Sound: \(Settings.sound ? "On" : "Off")", { Settings.sound.toggle() }),
            ("Music: \(Settings.music ? "On" : "Off")", { Settings.music.toggle() }),
            ("Objectives: \(Settings.objectives ? "On" : "Off")", { Settings.objectives.toggle() }),
        ]
        let tw: CGFloat = 150, th: CGFloat = 34, tg: CGFloat = 12
        let tt = CGFloat(rows.count) * tw + CGFloat(rows.count - 1) * tg
        // Campaign, Multiplayer and Load Game in a row under the difficulty cards.
        // Four buttons in a row under the difficulty cards: Campaign, Multiplayer, Load Game, Replays.
        let kr = CGRect(x: -455, y: cy - ch / 2 - 66, width: 210, height: 44)
        let kbg = SKSpriteNode(texture: Art.button(kr.size, .active, accent: Palette.good))
        kbg.name = "accent"
        kbg.size = kr.size
        kbg.position = CGPoint(x: kr.midX, y: kr.midY)
        content.addChild(kbg)
        let done = Settings.campaignDone.count
        let kl = makeLabel("CAMPAIGN  (C)", size: 16, font: Fonts.bold, align: .center, valign: .center)
        kl.position = kbg.position
        content.addChild(kl)
        let ksub = makeLabel("\(done) of \(campaign.count) missions done", size: 11, color: Palette.dim, font: Fonts.medium, align: .center, valign: .center)
        ksub.position = CGPoint(x: kr.midX, y: kr.minY - 11)
        content.addChild(ksub)
        toggles.append((kr, kbg, { [unowned self] in self.toggleCampaign() }))
        let mr = CGRect(x: -230, y: cy - ch / 2 - 66, width: 240, height: 44)
        let mbg = SKSpriteNode(texture: Art.button(mr.size, .active, accent: Palette.amber))
        mbg.size = mr.size
        mbg.name = "accent"
        mbg.position = CGPoint(x: mr.midX, y: mr.midY)
        content.addChild(mbg)
        let ml = makeLabel("MULTIPLAYER  (M)", size: 16, font: Fonts.bold, align: .center, valign: .center)
        ml.position = mbg.position
        content.addChild(ml)
        toggles.append((mr, mbg, { [unowned self] in self.multiplayer() }))
        let latest = SaveGame.list().first
        let lr = CGRect(x: 25, y: cy - ch / 2 - 66, width: 210, height: 44)
        let lbg = SKSpriteNode(texture: Art.button(lr.size, latest == nil ? .disabled : .normal))
        lbg.size = lr.size
        lbg.position = CGPoint(x: lr.midX, y: lr.midY)
        content.addChild(lbg)
        let ll = makeLabel("LOAD GAME  (L)", size: 16, color: latest == nil ? Palette.dim : Palette.text, font: Fonts.bold, align: .center, valign: .center)
        ll.position = lbg.position
        content.addChild(ll)
        let reps = Replay.list()
        let rr = CGRect(x: 250, y: cy - ch / 2 - 66, width: 210, height: 44)
        let rbg = SKSpriteNode(texture: Art.button(rr.size, reps.isEmpty ? .disabled : .normal))
        rbg.size = rr.size
        rbg.position = CGPoint(x: rr.midX, y: rr.midY)
        content.addChild(rbg)
        let rl = makeLabel("REPLAYS  (R)" + (reps.isEmpty ? "" : "  ·  \(reps.count)"), size: 16, color: reps.isEmpty ? Palette.dim : Palette.text, font: Fonts.bold, align: .center, valign: .center)
        rl.position = rbg.position
        content.addChild(rl)
        if !reps.isEmpty { toggles.append((rr, rbg, { [unowned self] in self.toggleReplays() })) }
        let career = makeLabel(Settings.careerText, size: 11, color: Palette.dim, font: Fonts.medium, align: .center, valign: .center)
        career.position = CGPoint(x: rr.midX, y: rr.minY - 11)
        content.addChild(career)
        if let (name, label, _, elapsed) = latest {
            let sub = makeLabel("\(label.isEmpty ? name : label) · \(Int(elapsed) / 60):\(String(format: "%02d", Int(elapsed) % 60)) in",
                                size: 11, color: Palette.dim, font: Fonts.medium, align: .center, valign: .center)
            sub.position = CGPoint(x: lr.midX, y: lr.minY - 11)
            content.addChild(sub)
            toggles.append((lr, lbg, { [unowned self] in self.loadLatest() }))
        }
        let ty = cy - ch / 2 - 112
        for (i, (label, action)) in rows.enumerated() {
            let r = CGRect(x: -tt / 2 + CGFloat(i) * (tw + tg), y: ty - th / 2, width: tw, height: th)
            let bg = SKSpriteNode(texture: Art.button(r.size, .normal))
            bg.size = r.size
            bg.position = CGPoint(x: r.midX, y: r.midY)
            content.addChild(bg)
            let l = makeLabel(label, size: 13, font: Fonts.demi, align: .center, valign: .center)
            l.position = bg.position
            content.addChild(l)
            toggles.append((r, bg, { [unowned self] in action(); self.buildContent() }))
        }

        // Map and opponent pickers
        let meta = SMapGen.info(Settings.mapId) ?? SMapGen.catalog[0]
        let mode = modes.first { $0.id == Settings.mode } ?? modes[0]
        let picks: [(CGFloat, String, () -> Void)] = [
            (300, "Map: \(meta.name)  (\(meta.players)p)", { Settings.cycleMap() }),
            (150, "Opponents: \(Settings.opponents)", { Settings.cycleOpponents() }),
            (170, Settings.teamCount < 2 ? "Teams: Free-for-all" : "Teams: \(Settings.teamCount)", { Settings.cycleTeams() }),
            (210, "Mode: \(mode.name)", { Settings.cycleMode() }),
        ]
        let py = ty - th - 12
        var px = -(picks.reduce(0) { $0 + $1.0 } + tg * CGFloat(picks.count - 1)) / 2
        for (pw, label, action) in picks {
            let r = CGRect(x: px, y: py - th / 2, width: pw, height: th)
            let bg = SKSpriteNode(texture: Art.button(r.size, .active, accent: Palette.amber))
            bg.name = "accent"
            bg.size = r.size
            bg.position = CGPoint(x: r.midX, y: r.midY)
            content.addChild(bg)
            let l = makeLabel(label, size: 13, font: Fonts.demi, align: .center, valign: .center)
            l.position = bg.position
            content.addChild(l)
            toggles.append((r, bg, { [unowned self] in action(); self.buildContent() }))
            px += pw + tg
        }
        // The start: crystal in the bank and what already stands.
        let base = startBases.first { $0.id == Settings.startBase } ?? startBases[0]
        let picks2: [(CGFloat, String, () -> Void)] = [
            (190, "Crystal: \(Settings.startCrystal)", { Settings.cycleStartCrystal() }),
            (250, "Base: \(base.name)", { Settings.cycleStartBase() }),
        ]
        let py2 = py - th - 10
        px = -(picks2.reduce(0) { $0 + $1.0 } + tg * CGFloat(picks2.count - 1)) / 2
        for (pw, label, action) in picks2 {
            let r = CGRect(x: px, y: py2 - th / 2, width: pw, height: th)
            let bg = SKSpriteNode(texture: Art.button(r.size, .active, accent: Palette.amber))
            bg.name = "accent"
            bg.size = r.size
            bg.position = CGPoint(x: r.midX, y: r.midY)
            content.addChild(bg)
            let l = makeLabel(label, size: 13, font: Fonts.demi, align: .center, valign: .center)
            l.position = bg.position
            content.addChild(l)
            toggles.append((r, bg, { [unowned self] in action(); self.buildContent() }))
            px += pw + tg
        }
        let desc = makeLabel("\(meta.desc)  ·  \(mode.rule)", size: 12, color: Palette.dim, font: Fonts.medium, align: .center, valign: .center)
        desc.position = CGPoint(x: 0, y: py2 - th / 2 - 14)
        content.addChild(desc)
        // Who is with whom — the round-robin deal is otherwise invisible until the game starts.
        let tc = Settings.teamCount
        let lineup = makeLabel(lineupText(opponents: Settings.opponents, teams: tc), size: 13,
                               color: tc >= 2 ? Palette.amber : Palette.dim, font: tc >= 2 ? Fonts.demi : Fonts.medium,
                               align: .center, valign: .center)
        lineup.position = CGPoint(x: 0, y: py2 - th / 2 - 34)
        content.addChild(lineup)

        let lines = [
            "Mine crystal with Engineers, expand, and train an army of Rangers and Siege Tanks.",
            "Destroy every enemy building to win. Objectives on screen will guide your first minutes.",
        ]
        for (i, l) in lines.enumerated() {
            let t = makeLabel(l, size: 14, color: Palette.text.withAlphaComponent(0.85), font: Fonts.medium, align: .center, valign: .center)
            t.position = CGPoint(x: 0, y: ty - 52 - th * 2 - 48 - CGFloat(i) * 24)
            content.addChild(t)
        }
        let foot = makeLabel("1 / 2 / 3 or Return to deploy  ·  ⌃⌘F full screen  ·  ⌘Q quit", size: 12, color: Palette.dim,
                             font: Fonts.medium, align: .center, valign: .center)
        foot.position = CGPoint(x: 0, y: -h / 2 + 26)
        content.addChild(foot)
        let version = makeLabel("v\(appVersion)", size: 12, color: Palette.dim, font: Fonts.medium,
                                align: .right, valign: .center)
        version.position = CGPoint(x: w / 2 - 18, y: -h / 2 + 26)
        content.addChild(version)
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        if let m = briefing {
            if deployRect.contains(p) { deploy(m) }
            return
        }
        if replaysOpen {
            if let hit = replayRows.first(where: { $0.0.contains(p) }) { watchReplay(view, size: size, name: hit.1) }
            return
        }
        if campaignOpen {
            if let hit = campaignRows.first(where: { $0.0.contains(p) }) { startMission(hit.1) }
            return
        }
        if let hit = cards.first(where: { $0.0.contains(p) }) {
            start(hit.1)
        } else if let t = toggles.first(where: { $0.0.contains(p) }) {
            t.2()
        }
    }

    override func keyDown(with event: NSEvent) {
        if let m = briefing {
            switch event.charactersIgnoringModifiers {
            case "\r": deploy(m)
            case "\u{1B}", "c", "C": hideBriefing(); toggleCampaign()
            default: break
            }
            return
        }
        switch event.charactersIgnoringModifiers {
        case "m", "M": multiplayer()
        case "c", "C": toggleCampaign()
        case "\u{1B}": if campaignOpen { toggleCampaign() } else if replaysOpen { toggleReplays() } else { NSApp.terminate(nil) }
        case "l", "L": loadLatest()
        case "r", "R": toggleReplays()
        case "1": start(.easy)
        case "2": start(.normal)
        case "3": start(.hard)
        case "\r": start(Difficulty(rawValue: Settings.lastDifficulty) ?? .normal)
        default: break
        }
    }

    // MARK: - Campaign

    private var campaignOpen = false
    private let campaignLayer = SKNode()
    private var campaignRows: [(CGRect, Mission)] = []

    private func toggleCampaign() {
        campaignOpen.toggle()
        campaignLayer.removeAllChildren()
        campaignRows = []
        if campaignLayer.parent == nil { campaignLayer.zPosition = 50; addChild(campaignLayer) }
        guard campaignOpen else { return }
        let done = Settings.campaignDone
        let boxW: CGFloat = 640, rowH: CGFloat = 78
        let boxH = 120 + rowH * CGFloat(campaign.count) + 60
        let dim = SKSpriteNode(color: NSColor(white: 0, alpha: 0.6), size: size)
        campaignLayer.addChild(dim)
        let box = SKSpriteNode(texture: Art.panel(CGSize(width: boxW, height: boxH), radius: 16, accent: Palette.good))
        box.size = CGSize(width: boxW, height: boxH)
        campaignLayer.addChild(box)
        let top = boxH / 2
        let title = makeLabel("CAMPAIGN", size: 36, color: Palette.good, font: Fonts.heavy, align: .center, valign: .center)
        title.position = CGPoint(x: 0, y: top - 44)
        campaignLayer.addChild(title)
        let sub = makeLabel("Five missions, played in order. Each unlocks the next.", size: 13, color: Palette.text, font: Fonts.demi, align: .center, valign: .center)
        sub.position = CGPoint(x: 0, y: top - 78)
        campaignLayer.addChild(sub)
        var y = top - 118
        for (i, m) in campaign.enumerated() {
            let unlocked = i == 0 || done.contains(campaign[i - 1].id)
            let finished = done.contains(m.id)
            let r = CGRect(x: -boxW / 2 + 20, y: y - rowH + 6, width: boxW - 40, height: rowH - 8)
            let bg = SKSpriteNode(texture: Art.button(r.size, unlocked ? (finished ? .active : .normal) : .disabled,
                                                      accent: finished ? Palette.good : Palette.amber))
            bg.size = r.size
            bg.position = CGPoint(x: r.midX, y: r.midY)
            campaignLayer.addChild(bg)
            let head = makeLabel("\(i + 1). \(m.title)" + (finished ? "  ✓" : (unlocked ? "" : "  — locked")), size: 16,
                                 color: unlocked ? Palette.text : Palette.dim, font: Fonts.bold, align: .left, valign: .center)
            head.position = CGPoint(x: r.minX + 16, y: r.maxY - 20)
            campaignLayer.addChild(head)
            let info = SMapGen.info(m.map)?.name ?? m.map
            let meta = makeLabel("\(info) · \(m.opponents) opponent\(m.opponents == 1 ? "" : "s") · \(Difficulty(rawValue: m.difficulty)?.name ?? "")",
                                 size: 11, color: Palette.dim, font: Fonts.medium, align: .right, valign: .center)
            meta.position = CGPoint(x: r.maxX - 16, y: r.maxY - 20)
            campaignLayer.addChild(meta)
            let brief = makeLabel(m.brief, size: 12, color: unlocked ? Palette.text : Palette.dim, font: Fonts.medium, align: .left, valign: .center)
            brief.position = CGPoint(x: r.minX + 16, y: r.minY + 20)
            campaignLayer.addChild(brief)
            if unlocked { campaignRows.append((r, m)) }
            y -= rowH
        }
        let close = makeLabel("Click a mission to deploy · C or Esc closes", size: 12, color: Palette.dim, font: Fonts.medium, align: .center, valign: .center)
        close.position = CGPoint(x: 0, y: -top + 28)
        campaignLayer.addChild(close)
    }

    /// A mission is briefed before it is deployed: the map, the objective and what the clock will bring.
    private func startMission(_ m: Mission) {
        if campaignOpen { toggleCampaign() }
        showBriefing(m)
    }

    private func deploy(_ m: Mission) {
        startMissionGame(view, size: size, mission: m)
    }

    // MARK: - Replays

    private var replaysOpen = false
    private let replaysLayer = SKNode()
    private var replayRows: [(CGRect, String)] = []

    /// The replay browser: every recorded game, newest first, with its map, date, length and result.
    private func toggleReplays() {
        let reps = Array(Replay.list().prefix(12))
        if reps.isEmpty && !replaysOpen { return }
        replaysOpen.toggle()
        replaysLayer.removeAllChildren()
        replayRows = []
        if replaysLayer.parent == nil { replaysLayer.zPosition = 50; addChild(replaysLayer) }
        guard replaysOpen else { return }
        let boxW: CGFloat = 700, rowH: CGFloat = 40
        let boxH = 110 + rowH * CGFloat(max(1, reps.count)) + 50
        let dim = SKSpriteNode(color: NSColor(white: 0, alpha: 0.6), size: size)
        replaysLayer.addChild(dim)
        let box = SKSpriteNode(texture: Art.panel(CGSize(width: boxW, height: boxH), radius: 16, accent: Palette.amber))
        box.size = CGSize(width: boxW, height: boxH)
        replaysLayer.addChild(box)
        let top = boxH / 2
        let title = makeLabel("REPLAYS", size: 36, color: Palette.amber, font: Fonts.heavy, align: .center, valign: .center)
        title.position = CGPoint(x: 0, y: top - 44)
        replaysLayer.addChild(title)
        let sub = makeLabel("The last \(reps.count) games, newest first. Click one to watch it.", size: 13, color: Palette.text, font: Fonts.demi, align: .center, valign: .center)
        sub.position = CGPoint(x: 0, y: top - 78)
        replaysLayer.addChild(sub)
        let f = DateFormatter()
        f.dateFormat = "dd MMM HH:mm"
        var y = top - 104
        for e in reps {
            let r = CGRect(x: -boxW / 2 + 20, y: y - rowH + 6, width: boxW - 40, height: rowH - 6)
            let bg = SKSpriteNode(texture: Art.button(r.size, .normal))
            bg.size = r.size
            bg.position = CGPoint(x: r.midX, y: r.midY)
            replaysLayer.addChild(bg)
            let when = e.savedAt > 0 ? f.string(from: Date(timeIntervalSince1970: TimeInterval(e.savedAt))) : "?"
            let mname = SMapGen.info(e.map)?.name ?? e.map
            let diff = Difficulty(rawValue: e.difficulty)?.name ?? ""
            let l = makeLabel("\(when)  ·  \(mname)  ·  \(diff)", size: 13, color: Palette.text, font: Fonts.bold, align: .left, valign: .center)
            l.position = CGPoint(x: r.minX + 14, y: r.midY)
            replaysLayer.addChild(l)
            let colour = e.result == "Won" ? Palette.good : (e.result == "Lost" ? Palette.bad : Palette.dim)
            let res = makeLabel(String(format: "%d:%02d   %@", Int(e.elapsed) / 60, Int(e.elapsed) % 60, e.result as NSString), size: 13, color: colour, font: Fonts.bold, align: .right, valign: .center)
            res.position = CGPoint(x: r.maxX - 14, y: r.midY)
            replaysLayer.addChild(res)
            replayRows.append((r, e.name))
            y -= rowH
        }
        let close = makeLabel("R or Esc closes", size: 12, color: Palette.dim, font: Fonts.medium, align: .center, valign: .center)
        close.position = CGPoint(x: 0, y: -top + 24)
        replaysLayer.addChild(close)
    }

    // MARK: - Briefing

    private(set) var briefing: Mission?
    private let briefingLayer = SKNode()
    private var deployRect = CGRect.zero

    static func objectiveText(_ m: Mission) -> String {
        let clock = String(format: "%d:%02d", Int(m.seconds) / 60, Int(m.seconds) % 60)
        switch m.win {
        case "survive": return "Be standing after \(clock)"
        case "hold": return "Hold the ring for \(clock) with no enemy inside"
        default: return "Destroy every enemy building"
        }
    }

    /// The script as the briefing shows it: (m:ss, line) per event, columns named by whose they are.
    static func timeline(_ m: Mission) -> [(String, String)] {
        m.events.map { e in
            let at = String(format: "%d:%02d", Int(e.at) / 60, Int(e.at) % 60)
            if e.kind == "text" { return (at, "Word from Command") }
            return (at, e.owner == 0 ? "Reinforcements arrive" : "Enemy column on the move")
        }
    }

    /// The mission's map, small: water and cliffs, crystal and gold, every side's start, the hold ring.
    static func mapThumb(_ m: Mission, width tw: CGFloat) -> SKTexture {
        let spec = SMapGen.resolve(m.map, players: 1 + m.opponents)
        let mw = CGFloat(jNum(spec["w"])), mh = CGFloat(jNum(spec["h"]))
        let s = tw / mw
        let size = CGSize(width: tw, height: max(1, mh * s))
        return Art.texture("brief-\(m.id)-\(Int(tw))", size: size) { ctx in
            ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
            Art.fill(ctx, CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), .rgb(0.19, 0.27, 0.16))
            for wl in jArr(spec["walls"]).map({ jArr($0) }) where wl.count >= 5 {
                let x0 = CGFloat(jNum(wl[0])) * s, y0 = CGFloat(jNum(wl[1])) * s, x1 = CGFloat(jNum(wl[2])) * s, y1 = CGFloat(jNum(wl[3])) * s
                let water = jStr(wl[4]) == "water"
                Art.fill(ctx, CGPath(rect: CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0)), transform: nil),
                         water ? .rgb(0.15, 0.26, 0.41) : .rgb(0.29, 0.24, 0.20))
            }
            for r in jArr(spec["ridges"]).map({ jArr($0) }) where r.count >= 4 {
                let x0 = CGFloat(jNum(r[0])) * s, y0 = CGFloat(jNum(r[1])) * s, x1 = CGFloat(jNum(r[2])) * s, y1 = CGFloat(jNum(r[3])) * s
                Art.fill(ctx, CGPath(rect: CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0)), transform: nil), .rgb(0.38, 0.44, 0.23))
            }
            for b in jArr(spec["bridges"]).map({ jArr($0) }) where b.count >= 4 {
                let x0 = CGFloat(jNum(b[0])) * s, y0 = CGFloat(jNum(b[1])) * s, x1 = CGFloat(jNum(b[2])) * s, y1 = CGFloat(jNum(b[3])) * s
                Art.fill(ctx, CGPath(rect: CGRect(x: x0, y: y0, width: max(2, x1 - x0), height: max(2, y1 - y0)), transform: nil), Palette.amber)
            }
            for c in jArr(spec["crystals"]).map({ jArr($0) }) where c.count >= 2 {
                let gold = c.count > 3 && jInt(c[3]) == 3
                let r: CGFloat = gold ? 3 : 1
                Art.fill(ctx, CGPath(rect: CGRect(x: CGFloat(jNum(c[0])) * s - r, y: CGFloat(jNum(c[1])) * s - r, width: 2 * r + 1, height: 2 * r + 1), transform: nil),
                         gold ? Palette.amber : Palette.crystal)
            }
            for (i, st) in jArr(spec["starts"]).map({ jArr($0) }).prefix(1 + m.opponents).enumerated() where st.count >= 2 {
                let p = CGPoint(x: CGFloat(jNum(st[0])) * s, y: CGFloat(jNum(st[1])) * s)
                Art.fill(ctx, CGPath(rect: CGRect(x: p.x - 4, y: p.y - 4, width: 9, height: 9), transform: nil), Team(rawValue: i).color)
                Art.stroke(ctx, CGPath(rect: CGRect(x: p.x - 5, y: p.y - 5, width: 11, height: 11), transform: nil), i == 0 ? .white : NSColor(white: 1, alpha: 0.35), 1)
            }
            if let h = m.hold {
                Art.stroke(ctx, Art.circle(CGPoint(x: CGFloat(h.0) * s, y: CGFloat(h.1) * s), max(4, CGFloat(h.2) * s)), Palette.amber, 1)
            }
        }
    }

    func showBriefing(_ m: Mission) {
        briefing = m
        briefingLayer.removeAllChildren()
        if briefingLayer.parent == nil { briefingLayer.zPosition = 60; addChild(briefingLayer) }
        let boxW = min(size.width - 40, 780), boxH = min(size.height - 20, 540)
        let dim = SKSpriteNode(color: NSColor(white: 0, alpha: 0.67), size: size)
        briefingLayer.addChild(dim)
        let box = SKSpriteNode(texture: Art.panel(CGSize(width: boxW, height: boxH), radius: 16, accent: Palette.amber))
        box.size = CGSize(width: boxW, height: boxH)
        briefingLayer.addChild(box)
        let top = boxH / 2, left = -boxW / 2
        let n = (campaign.firstIndex { $0.id == m.id } ?? 0) + 1
        let title = makeLabel(m.title.uppercased(), size: 34, color: Palette.amber, font: Fonts.heavy, align: .center, valign: .center)
        title.position = CGPoint(x: 0, y: top - 42)
        briefingLayer.addChild(title)
        let info = SMapGen.info(m.map)?.name ?? m.map
        let meta = makeLabel("Mission \(n) of \(campaign.count) · \(info) · \(m.opponents) opponent\(m.opponents == 1 ? "" : "s") · \(Difficulty(rawValue: m.difficulty)?.name ?? "")",
                             size: 13, color: Palette.dim, font: Fonts.demi, align: .center, valign: .center)
        meta.position = CGPoint(x: 0, y: top - 74)
        briefingLayer.addChild(meta)
        let tw = min(300, boxW / 2 - 40)
        let thumb = SKSpriteNode(texture: Self.mapThumb(m, width: tw))
        let ts = thumb.texture!.size()                  // rendered at 2x; shown at the width asked for
        thumb.size = CGSize(width: tw, height: ts.height / ts.width * tw)
        thumb.anchorPoint = CGPoint(x: 0, y: 1)
        thumb.position = CGPoint(x: left + 24, y: top - 100)
        let frame = SKSpriteNode(color: NSColor.rgb(0.08, 0.09, 0.10), size: CGSize(width: thumb.size.width + 6, height: thumb.size.height + 6))
        frame.anchorPoint = CGPoint(x: 0, y: 1)
        frame.position = CGPoint(x: left + 21, y: top - 97)
        briefingLayer.addChild(frame)
        briefingLayer.addChild(thumb)
        let legend = makeLabel("You are the white-edged square; the ring is the hold.", size: 10, color: Palette.dim, font: Fonts.medium, align: .left, valign: .center)
        legend.position = CGPoint(x: left + 24, y: top - 100 - thumb.size.height - 14)
        briefingLayer.addChild(legend)
        let rx = left + 24 + tw + 28
        let rw = boxW / 2 - 24 - rx
        var y = top - 100
        for line in wrapText(m.brief, size: 13, width: rw).prefix(4) {
            let l = makeLabel(line, size: 13, color: Palette.text, font: Fonts.medium, align: .left, valign: .center)
            l.position = CGPoint(x: rx, y: y)
            briefingLayer.addChild(l)
            y -= 18
        }
        y -= 10
        let oh = makeLabel("OBJECTIVE", size: 12, color: Palette.amber, font: Fonts.bold, align: .left, valign: .center)
        oh.position = CGPoint(x: rx, y: y)
        briefingLayer.addChild(oh)
        let ot = makeLabel(Self.objectiveText(m), size: 13, color: Palette.text, font: Fonts.medium, align: .left, valign: .center)
        ot.position = CGPoint(x: rx, y: y - 18)
        briefingLayer.addChild(ot)
        y -= 46
        let th = makeLabel("TIMELINE", size: 12, color: Palette.amber, font: Fonts.bold, align: .left, valign: .center)
        th.position = CGPoint(x: rx, y: y)
        briefingLayer.addChild(th)
        y -= 18
        for (at, line) in Self.timeline(m).prefix(6) {
            let a = makeLabel(at, size: 12, color: Palette.dim, font: Fonts.mono, align: .left, valign: .center)
            a.position = CGPoint(x: rx, y: y)
            briefingLayer.addChild(a)
            let l = makeLabel(line, size: 12, color: Palette.text, font: Fonts.medium, align: .left, valign: .center)
            l.position = CGPoint(x: rx + 44, y: y)
            briefingLayer.addChild(l)
            y -= 16
        }
        deployRect = CGRect(x: -110, y: -top + 30, width: 220, height: 44)
        let bg = SKSpriteNode(texture: Art.button(deployRect.size, .normal, accent: Palette.good))
        bg.size = deployRect.size
        bg.position = CGPoint(x: deployRect.midX, y: deployRect.midY)
        briefingLayer.addChild(bg)
        let dl = makeLabel("DEPLOY  (Enter)", size: 16, color: Palette.text, font: Fonts.bold, align: .center, valign: .center)
        dl.position = bg.position
        briefingLayer.addChild(dl)
        let back = makeLabel("Esc back to the mission list", size: 11, color: Palette.dim, font: Fonts.medium, align: .center, valign: .center)
        back.position = CGPoint(x: 0, y: -top + 18)
        briefingLayer.addChild(back)
    }

    private func hideBriefing() {
        briefing = nil
        briefingLayer.removeAllChildren()
    }

    private func loadLatest() {
        guard let latest = SaveGame.list().first, let w = try? SaveGame.read(latest.0) else { return }
        resumeSkirmish(view, size: size, world: w)
    }

    private func multiplayer() {
        view?.presentScene(MultiplayerScene(size: size), transition: .fade(withDuration: 0.4))
    }

    private func start(_ d: Difficulty) {
        Settings.lastDifficulty = d.rawValue
        startSkirmish(view, size: size, difficulty: d, mapId: Settings.mapId, opponents: Settings.opponents,
                      teams: Settings.teamCount, mode: Settings.mode, startCrystal: Settings.startCrystal, startBase: Settings.startBase)
    }
}
