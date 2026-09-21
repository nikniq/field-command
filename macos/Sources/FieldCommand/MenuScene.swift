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
            ("Objectives: \(Settings.objectives ? "On" : "Off")", { Settings.objectives.toggle() }),
        ]
        let tw: CGFloat = 150, th: CGFloat = 34, tg: CGFloat = 12
        let tt = CGFloat(rows.count) * tw + CGFloat(rows.count - 1) * tg
        let mr = CGRect(x: -160, y: cy - ch / 2 - 66, width: 320, height: 44)
        let mbg = SKSpriteNode(texture: Art.button(mr.size, .active, accent: Palette.amber))
        mbg.size = mr.size
        mbg.name = "accent"
        mbg.position = CGPoint(x: mr.midX, y: mr.midY)
        content.addChild(mbg)
        let ml = makeLabel("MULTIPLAYER  (M)", size: 16, font: Fonts.bold, align: .center, valign: .center)
        ml.position = mbg.position
        content.addChild(ml)
        toggles.append((mr, mbg, { [unowned self] in self.multiplayer() }))
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
        let picks: [(CGFloat, String, () -> Void)] = [
            (360, "Map: \(meta.name)  (\(meta.players)p)", { Settings.cycleMap() }),
            (170, "Opponents: \(Settings.opponents)", { Settings.cycleOpponents() }),
            (170, Settings.teamCount < 2 ? "Teams: Free-for-all" : "Teams: \(Settings.teamCount)", { Settings.cycleTeams() }),
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
        let desc = makeLabel(meta.desc, size: 12, color: Palette.dim, font: Fonts.medium, align: .center, valign: .center)
        desc.position = CGPoint(x: 0, y: py - th / 2 - 14)
        content.addChild(desc)
        // Who is with whom — the round-robin deal is otherwise invisible until the game starts.
        let tc = Settings.teamCount
        let lineup = makeLabel(lineupText(opponents: Settings.opponents, teams: tc), size: 13,
                               color: tc >= 2 ? Palette.amber : Palette.dim, font: tc >= 2 ? Fonts.demi : Fonts.medium,
                               align: .center, valign: .center)
        lineup.position = CGPoint(x: 0, y: py - th / 2 - 34)
        content.addChild(lineup)

        let lines = [
            "Mine crystal with Engineers, expand, and train an army of Rangers and Siege Tanks.",
            "Destroy every enemy building to win. Objectives on screen will guide your first minutes.",
        ]
        for (i, l) in lines.enumerated() {
            let t = makeLabel(l, size: 14, color: Palette.text.withAlphaComponent(0.85), font: Fonts.medium, align: .center, valign: .center)
            t.position = CGPoint(x: 0, y: ty - 52 - th - 38 - CGFloat(i) * 24)
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
        if let hit = cards.first(where: { $0.0.contains(p) }) {
            start(hit.1)
        } else if let t = toggles.first(where: { $0.0.contains(p) }) {
            t.2()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "m", "M": multiplayer()
        case "1": start(.easy)
        case "2": start(.normal)
        case "3": start(.hard)
        case "\r": start(Difficulty(rawValue: Settings.lastDifficulty) ?? .normal)
        default: break
        }
    }

    private func multiplayer() {
        view?.presentScene(MultiplayerScene(size: size), transition: .fade(withDuration: 0.4))
    }

    private func start(_ d: Difficulty) {
        Settings.lastDifficulty = d.rawValue
        startSkirmish(view, size: size, difficulty: d, mapId: Settings.mapId, opponents: Settings.opponents,
                      teams: Settings.teamCount)
    }
}
