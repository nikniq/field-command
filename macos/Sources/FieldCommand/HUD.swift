import SpriteKit

/// Screen-space interface, attached to the camera. Coordinates are points relative to the screen centre.
final class HUD: SKNode {
    static let panelHeight: CGFloat = 192
    static let topHeight: CGFloat = 42
    private static let buttonSize: CGFloat = 64
    private static let buttonGap: CGFloat = 7

    unowned let game: GameScene
    private(set) var size = CGSize.zero

    // Top bar
    private let topBar = SKSpriteNode()
    private let crystalIcon = SKSpriteNode(texture: Art.crystalIcon)
    private let supplyIcon = SKSpriteNode(texture: Art.supplyIcon)
    private let resLabel = makeLabel("", size: 17, color: Palette.crystal, font: Fonts.mono, valign: .center)
    private let supplyLabel = makeLabel("", size: 17, color: Palette.text, font: Fonts.mono, valign: .center)
    private let clockLabel = makeLabel("", size: 16, color: Palette.text, font: Fonts.mono, align: .center, valign: .center)
    private let topButtonLayer = SKNode()
    private var topButtons: [(CGRect, () -> Void)] = []
    private var lastTopSignature = ""

    // Bottom panel
    private let panelBG = SKSpriteNode()
    private let minimapFrame = SKSpriteNode()
    private let infoFrame = SKSpriteNode()
    private let cardFrame = SKSpriteNode()

    // Minimap
    private let minimapTerrain = SKSpriteNode()
    private let minimapFog = SKSpriteNode()
    private let minimapLayer = SKNode()
    private var dots: [SKSpriteNode] = []
    private let camFrame = SKShapeNode()
    private(set) var minimapRect = CGRect.zero
    private var mmScale: CGFloat = 0.05

    // Selection info & command card
    private let infoLayer = SKNode()
    private let cardLayer = SKNode()
    private(set) var currentButtons: [CommandButton] = []
    private var buttonRects: [CGRect] = []
    private var buttonBGs: [SKSpriteNode] = []
    private var cardSignature = ""
    private var hoverButton: Int?
    private var queueRects: [(CGRect, Int)] = []
    private var iconRects: [(CGRect, Entity)] = []
    private var infoRect = CGRect.zero
    private var cardOrigin = CGPoint.zero

    // Messages, objectives, tooltips
    private let messageLayer = SKNode()
    private var messages: [SKNode] = []
    private let objectivesLayer = SKNode()
    private var objectiveDone: [Int: CGFloat] = [:]
    private let tooltip = SKNode()
    private let tooltipBG = SKSpriteNode()
    private let tooltipTitle = makeLabel("", size: 14, font: Fonts.bold, valign: .top)
    private let tooltipCost = makeLabel("", size: 13, color: Palette.crystal, font: Fonts.mono, align: .right, valign: .top)
    private let tooltipBody = makeLabel("", size: 12, color: Palette.dim, font: Fonts.medium, valign: .top)
    private let hoverTag = SKNode()
    private let hoverBG = SKSpriteNode()
    private let hoverLabel = makeLabel("", size: 12, font: Fonts.demi, valign: .center)

    // Overlays
    private let overlay = SKNode()
    let chatLabel = makeLabel("", size: 15, color: Palette.text, font: Fonts.demi, align: .center, valign: .center)
    private var overlayButtons: [(CGRect, SKSpriteNode, () -> Void)] = []
    private var overlayBuilder: (() -> Void)?
    var overlayVisible: Bool { overlayBuilder != nil }

    private var refreshTimer: CGFloat = 0
    private var mmTimer: CGFloat = 0
    private var needsRefresh = true
    private var lastRes = -1, lastSupply = "", lastClock = ""

    init(game: GameScene) {
        self.game = game
        super.init()
        for n in [panelBG, topBar] { n.zPosition = -1; addChild(n) }
        for n in [minimapFrame, infoFrame, cardFrame] { n.zPosition = 0; addChild(n) }
        crystalIcon.size = CGSize(width: 18, height: 18)
        supplyIcon.size = CGSize(width: 18, height: 18)
        for n in [crystalIcon, supplyIcon, resLabel, supplyLabel, clockLabel] as [SKNode] { n.zPosition = 2; addChild(n) }
        topButtonLayer.zPosition = 2
        addChild(topButtonLayer)

        minimapTerrain.anchorPoint = .zero
        minimapTerrain.zPosition = 1
        minimapFog.anchorPoint = .zero
        minimapFog.zPosition = 2
        addChild(minimapTerrain)
        addChild(minimapFog)
        minimapLayer.zPosition = 3
        addChild(minimapLayer)
        camFrame.strokeColor = .white
        camFrame.lineWidth = 1.2
        camFrame.zPosition = 5
        minimapLayer.addChild(camFrame)

        infoLayer.zPosition = 2
        cardLayer.zPosition = 2
        addChild(infoLayer)
        addChild(cardLayer)
        messageLayer.zPosition = 4
        addChild(messageLayer)
        objectivesLayer.zPosition = 3
        addChild(objectivesLayer)

        tooltipBG.anchorPoint = .zero
        tooltipBody.numberOfLines = 0
        tooltipBody.preferredMaxLayoutWidth = 270
        for n in [tooltipBG, tooltipTitle, tooltipCost, tooltipBody] as [SKNode] { tooltip.addChild(n) }
        tooltip.zPosition = 50
        tooltip.isHidden = true
        addChild(tooltip)

        hoverBG.anchorPoint = CGPoint(x: 0, y: 0.5)
        hoverTag.addChild(hoverBG)
        hoverTag.addChild(hoverLabel)
        hoverLabel.position = CGPoint(x: 8, y: 0)
        hoverTag.zPosition = 45
        hoverTag.isHidden = true
        addChild(hoverTag)

        overlay.zPosition = 200
        chatLabel.zPosition = 60
        chatLabel.isHidden = true
        addChild(chatLabel)
        addChild(overlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    func layout(size: CGSize) {
        self.size = size
        chatLabel.position = CGPoint(x: 0, y: -size.height / 2 + Self.panelHeight + 34)
        let w = size.width, h = size.height
        let topH = Self.topHeight, panelH = Self.panelHeight

        topBar.texture = Art.panel(CGSize(width: w + 4, height: topH + 2), radius: 0)
        topBar.size = CGSize(width: w + 4, height: topH + 2)
        topBar.position = CGPoint(x: 0, y: h / 2 - topH / 2)
        let ty = h / 2 - topH / 2
        crystalIcon.position = CGPoint(x: -w / 2 + 24, y: ty)
        resLabel.position = CGPoint(x: -w / 2 + 38, y: ty)
        supplyIcon.position = CGPoint(x: -w / 2 + 128, y: ty)
        supplyLabel.position = CGPoint(x: -w / 2 + 142, y: ty)
        clockLabel.position = CGPoint(x: 0, y: ty)
        lastTopSignature = ""

        panelBG.texture = Art.panel(CGSize(width: w + 4, height: panelH + 2), radius: 0)
        panelBG.size = CGSize(width: w + 4, height: panelH + 2)
        panelBG.position = CGPoint(x: 0, y: -h / 2 + panelH / 2)

        let mmW: CGFloat = 236
        mmScale = mmW / worldSize.width
        let mmH = worldSize.height * mmScale
        let pad: CGFloat = 8
        minimapRect = CGRect(x: -w / 2 + 16, y: -h / 2 + (panelH - mmH) / 2, width: mmW, height: mmH)
        let mmFrame = minimapRect.insetBy(dx: -pad, dy: -pad)
        minimapFrame.texture = Art.panel(mmFrame.size, radius: 8)
        minimapFrame.size = mmFrame.size
        minimapFrame.position = CGPoint(x: mmFrame.midX, y: mmFrame.midY)
        minimapTerrain.texture = minimapTerrainTexture()
        minimapTerrain.size = minimapRect.size
        minimapTerrain.position = minimapRect.origin
        minimapFog.position = minimapRect.origin
        minimapFog.size = CGSize(width: CGFloat(game.fog.cols) * game.fog.cell * mmScale,
                                 height: CGFloat(game.fog.rows) * game.fog.cell * mmScale)
        minimapLayer.position = minimapRect.origin

        let bs = Self.buttonSize, gap = Self.buttonGap
        let cardW = 4 * bs + 3 * gap, cardH = 2 * bs + gap
        cardOrigin = CGPoint(x: w / 2 - 22 - cardW, y: -h / 2 + (panelH - cardH) / 2)
        let cf = CGRect(x: cardOrigin.x - 10, y: cardOrigin.y - 10, width: cardW + 20, height: cardH + 20)
        cardFrame.texture = Art.panel(cf.size, radius: 8)
        cardFrame.size = cf.size
        cardFrame.position = CGPoint(x: cf.midX, y: cf.midY)

        let infoX = mmFrame.maxX + 14
        let infoFrameRect = CGRect(x: infoX, y: mmFrame.minY, width: cf.minX - 14 - infoX, height: mmFrame.height)
        infoFrame.texture = Art.panel(infoFrameRect.size, radius: 8)
        infoFrame.size = infoFrameRect.size
        infoFrame.position = CGPoint(x: infoFrameRect.midX, y: infoFrameRect.midY)
        infoRect = infoFrameRect.insetBy(dx: 16, dy: 14)

        messageLayer.position = CGPoint(x: 0, y: h / 2 - topH - 34)
        objectivesLayer.position = CGPoint(x: -w / 2 + 14, y: h / 2 - topH - 12)

        needsRefresh = true
        cardSignature = ""
        mmTimer = 0
        overlayBuilder?()
    }

    private func minimapTerrainTexture() -> SKTexture {
        let size = CGSize(width: 236, height: worldSize.height * 236 / worldSize.width)
        let s = size.width / worldSize.width
        return Art.texture("minimap-terrain-\(game.mapKey)", size: size) { ctx in
            ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
            let full = CGRect(origin: .zero, size: size)
            Art.linear(ctx, CGPath(rect: full, transform: nil), [.rgb(0.2, 0.29, 0.16), .rgb(0.14, 0.21, 0.12)],
                       CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: 0))
            for (c, r) in game.clearings {
                Art.radial(ctx, nil, [NSColor.rgb(0.42, 0.34, 0.22, 0.8), NSColor.rgb(0.42, 0.34, 0.22, 0)], c * s, r * s)
            }
            for road in game.roads {
                let p = CGMutablePath()
                p.addLines(between: road.map { $0 * s })
                Art.stroke(ctx, p, .rgb(0.45, 0.37, 0.25, 0.8), 3)
            }
            if let img = game.terrainImage { ctx.draw(img, in: full) }
            for o in game.obstacles {
                Art.fill(ctx, Art.circle(o.position * s, 2.2), .rgb(0.07, 0.15, 0.07))
            }
        }
    }

    func isOverHUD(_ p: CGPoint) -> Bool {
        p.y < -size.height / 2 + Self.panelHeight || p.y > size.height / 2 - Self.topHeight
    }

    // MARK: - Update

    func selectionChanged() { needsRefresh = true }

    func setFog(_ t: SKTexture?) { minimapFog.texture = t }

    func update(_ dt: CGFloat, mouse: CGPoint?) {
        let res = Int(game.myResources)
        if res != lastRes {
            lastRes = res
            resLabel.text = "\(res)"
        }
        let used = game.mySupplyUsed, cap = game.mySupplyCap
        let supply = "\(used)/\(cap)"
        if supply != lastSupply {
            lastSupply = supply
            supplyLabel.text = supply
            supplyLabel.fontColor = used >= cap ? Palette.bad : Palette.text
        }
        let clock = "\(formatTime(game.elapsed))" + (game.isMultiplayer ? "  ·  ONLINE" : (Settings.speedIndex == 1 ? "" : "  ·  \(Settings.speedName)"))
        if clock != lastClock {
            lastClock = clock
            clockLabel.text = clock
        }
        refreshTopButtons(mouse)

        refreshTimer -= dt
        if needsRefresh || refreshTimer <= 0 {
            refreshTimer = 0.2
            needsRefresh = false
            rebuildInfo()
            rebuildCard()
            rebuildObjectives()
        }
        mmTimer -= dt
        if mmTimer <= 0 {
            mmTimer = 0.12
            updateMinimap()
        }
        updateHoverStates(mouse)
    }

    // MARK: - Top bar

    private func topButton(_ title: String, icon: SKTexture?, x: CGFloat, width: CGFloat, highlight: Bool, hover: Bool,
                           action: @escaping () -> Void) -> CGFloat {
        let h: CGFloat = 30
        let r = CGRect(x: x, y: size.height / 2 - Self.topHeight / 2 - h / 2, width: width, height: h)
        let bg = SKSpriteNode(texture: Art.button(r.size, hover ? .hover : (highlight ? .active : .normal),
                                                  accent: highlight ? Palette.amber : Palette.buttonEdge))
        bg.size = r.size
        bg.position = CGPoint(x: r.midX, y: r.midY)
        topButtonLayer.addChild(bg)
        var lx = r.minX + 10
        if let icon {
            let s = SKSpriteNode(texture: icon)
            s.size = CGSize(width: 24, height: 24)
            s.position = CGPoint(x: r.minX + 17, y: r.midY)
            topButtonLayer.addChild(s)
            lx = r.minX + 32
        }
        let l = makeLabel(title, size: 13, color: highlight ? Palette.amber : Palette.text, font: Fonts.demi, valign: .center)
        l.position = CGPoint(x: lx, y: r.midY)
        topButtonLayer.addChild(l)
        topButtons.append((r, action))
        return r.maxX + 8
    }

    private func refreshTopButtons(_ mouse: CGPoint?) {
        let idle = game.idleWorkers.count, army = game.army.count
        let hoverIdx = mouse.flatMap { m in topButtons.firstIndex { $0.0.contains(m) } }
        let sig = "\(idle)-\(army)-\(String(describing: hoverIdx))-\(size.width)"
        guard sig != lastTopSignature else { return }
        lastTopSignature = sig
        topButtonLayer.removeAllChildren()
        topButtons = []
        var x = -size.width / 2 + 220
        x = topButton(idle == 1 ? "1 idle" : "\(idle) idle", icon: Art.unit(.worker, Team.local), x: x, width: 96,
                      highlight: idle > 0, hover: hoverIdx == 0) { [unowned self] in self.game.selectIdleWorker() }
        _ = topButton("Army \(army)", icon: Art.unit(.marine, Team.local), x: x, width: 104, highlight: false,
                      hover: hoverIdx == 1) { [unowned self] in self.game.selectArmy() }
        let right = size.width / 2 - 14
        _ = topButton("Menu", icon: nil, x: right - 72, width: 72, highlight: false, hover: hoverIdx == 2) { [unowned self] in
            self.game.togglePause()
        }
        _ = topButton("Help", icon: nil, x: right - 72 - 8 - 64, width: 64, highlight: false, hover: hoverIdx == 3) { [unowned self] in
            self.game.toggleHelp()
        }
    }

    // MARK: - Messages

    func flash(_ text: String, color: NSColor) {
        if let same = messages.first(where: { ($0.userData?["text"] as? String) == text }) {
            same.removeAllActions()
            same.alpha = 1
            same.run(.sequence([.wait(forDuration: 4), .fadeOut(withDuration: 0.6), .removeFromParent()]))
            return
        }
        let node = SKNode()
        node.userData = ["text": text]
        let shadow = makeLabel(text, size: 16, color: NSColor(white: 0, alpha: 0.85), font: Fonts.demi, align: .center, valign: .center)
        shadow.position = CGPoint(x: 1, y: -1.5)
        let l = makeLabel(text, size: 16, color: color, font: Fonts.demi, align: .center, valign: .center)
        node.addChild(shadow)
        node.addChild(l)
        node.alpha = 0
        messageLayer.addChild(node)
        messages.insert(node, at: 0)
        node.run(.sequence([.fadeIn(withDuration: 0.15), .wait(forDuration: 4), .fadeOut(withDuration: 0.6), .removeFromParent()]))
        messages = messages.filter { $0.parent != nil }
        if messages.count > 4 {
            messages.suffix(from: 4).forEach { $0.removeFromParent() }
            messages = Array(messages.prefix(4))
        }
        for (i, m) in messages.enumerated() {
            m.run(.move(to: CGPoint(x: 0, y: -CGFloat(i) * 24), duration: 0.15))
        }
    }

    // MARK: - Objectives

    private struct Objective {
        let text: String
        let done: (GameScene) -> Bool
    }

    private let objectives: [Objective] = [
        Objective(text: "Train an Engineer — select the Command Center, press W") { $0.trainedKinds[.worker, default: 0] >= 1 },
        Objective(text: "Build a Supply Depot — select an Engineer, press E") { $0.hasBuilt(.depot, team: Team.local) },
        Objective(text: "Build a Barracks (B)") { $0.hasBuilt(.barracks, team: Team.local) },
        Objective(text: "Train 5 Rangers at the Barracks (R)") { $0.trainedKinds[.marine, default: 0] >= 5 },
        Objective(text: "Build a Factory (F)") { $0.hasBuilt(.factory, team: Team.local) },
        Objective(text: "Train a Siege Tank (T)") { $0.trainedKinds[.tank, default: 0] >= 1 },
        Objective(text: "Train a Sniper at the Barracks (N)") { $0.trainedKinds[.sniper, default: 0] >= 1 },
        Objective(text: "Build a Radar Station (D) to watch the map") { $0.hasBuilt(.radar, team: Team.local) },
        Objective(text: "Destroy every enemy building") { _ in false },
    ]

    private func rebuildObjectives() {
        objectivesLayer.removeAllChildren()
        if let net = game.net {
            if !overlayVisible { drawScoreboard(net) }
            return
        }
        guard Settings.objectives, !overlayVisible else { return }
        var rows: [(String, Bool)] = []
        for (i, o) in objectives.enumerated() {
            let done = o.done(game)
            if done && objectiveDone[i] == nil {
                objectiveDone[i] = game.elapsed
                if i < objectives.count - 1 {
                    flash("Objective complete: \(o.text.components(separatedBy: " —").first ?? o.text)", color: Palette.good)
                    playSound("Pop")
                }
            }
            if let t = objectiveDone[i], game.elapsed - t > 4 { continue }
            rows.append((o.text, done))
            if rows.count >= 3 { break }
        }
        guard !rows.isEmpty else { return }
        let w: CGFloat = 360, rowH: CGFloat = 22
        let h = 30 + CGFloat(rows.count) * rowH
        let bg = SKSpriteNode(texture: Art.panel(CGSize(width: w, height: h), radius: 8, accent: Palette.amber))
        bg.size = CGSize(width: w, height: h)
        bg.anchorPoint = CGPoint(x: 0, y: 1)
        bg.alpha = 0.92
        objectivesLayer.addChild(bg)
        let title = makeLabel("OBJECTIVES", size: 11, color: Palette.amber, font: Fonts.bold, valign: .center)
        title.position = CGPoint(x: 12, y: -14)
        objectivesLayer.addChild(title)
        let hint = makeLabel("O to hide", size: 10, color: Palette.dim, font: Fonts.medium, align: .right, valign: .center)
        hint.position = CGPoint(x: w - 12, y: -14)
        objectivesLayer.addChild(hint)
        for (i, (text, done)) in rows.enumerated() {
            let y = -32 - CGFloat(i) * rowH
            let mark = makeLabel(done ? "✓" : "○", size: 13, color: done ? Palette.good : Palette.dim, font: Fonts.bold, valign: .center)
            mark.position = CGPoint(x: 12, y: y)
            let l = makeLabel(text, size: 12.5, color: done ? Palette.good : Palette.text, font: Fonts.medium, valign: .center)
            l.position = CGPoint(x: 30, y: y)
            objectivesLayer.addChild(mark)
            objectivesLayer.addChild(l)
        }
    }

    // MARK: - Clicks

    func handleClick(_ p: CGPoint, right: Bool, queue: Bool = false) -> Bool {
        if overlayVisible {
            if !right, let hit = overlayButtons.first(where: { $0.0.contains(p) }) { hit.2() }
            return true
        }
        if minimapRect.contains(p) {
            let w = minimapToWorld(p)
            if right {
                game.smartCommand(at: w, queue: queue)
            } else {
                game.centerCamera(on: w)
                game.minimapDragging = true
            }
            return true
        }
        guard isOverHUD(p) else { return false }
        if right { return true }
        if let hit = topButtons.first(where: { $0.0.contains(p) }) {
            hit.1()
            return true
        }
        if let i = buttonRects.firstIndex(where: { $0.contains(p) }) {
            pressButton(i)
            return true
        }
        if let b = game.selection.first as? Building, game.selection.count == 1,
           let hit = queueRects.first(where: { $0.0.contains(p) }) {
            game.cancelQueue(b, index: hit.1)
            return true
        }
        if let hit = iconRects.first(where: { $0.0.contains(p) }) {
            game.setSelection([hit.1])
            return true
        }
        return true
    }

    func pressButton(_ i: Int) {
        guard i < currentButtons.count else { return }
        let b = currentButtons[i]
        if i < buttonBGs.count {
            let bg = buttonBGs[i]
            bg.run(.sequence([.scale(to: 0.9, duration: 0.05), .scale(to: 1, duration: 0.1)]))
        }
        if b.enabled {
            b.action()
        } else {
            flash("Requirements not met", color: Palette.bad)
        }
    }

    func minimapDrag(_ p: CGPoint) {
        let c = CGPoint(x: clamp(p.x, minimapRect.minX, minimapRect.maxX), y: clamp(p.y, minimapRect.minY, minimapRect.maxY))
        game.centerCamera(on: minimapToWorld(c))
    }

    private func minimapToWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - minimapRect.minX) / mmScale, y: (p.y - minimapRect.minY) / mmScale)
    }

    // MARK: - Minimap

    private func updateMinimap() {
        var i = 0
        func put(_ p: CGPoint, _ c: NSColor, _ s: CGFloat) {
            let d: SKSpriteNode
            if i < dots.count {
                d = dots[i]
            } else {
                d = SKSpriteNode(color: c, size: .zero)
                d.zPosition = 1
                minimapLayer.addChild(d)
                dots.append(d)
            }
            d.color = c
            d.size = CGSize(width: s, height: s)
            d.position = CGPoint(x: p.x * mmScale, y: p.y * mmScale)
            d.isHidden = false
            i += 1
        }
        for c in game.crystals where !c.dead && game.fog.isExplored(c.position) { put(c.position, Palette.crystal, 3) }
        // Crossings are strategic, so they are marked: amber while they stand, red once they are down.
        for br in game.bridgeNodes {
            put(br.position, br.intact ? Palette.amber : Palette.bad,
                max(4, min(br.rect.width, br.rect.height) * mmScale))
        }
        for b in game.buildings where b.team.isFriendly || b.revealed {
            put(b.position, b.team.color, max(6, b.half * 2 * mmScale))
        }
        for u in game.units where u.team.isFriendly || u.visibleToPlayer {
            put(u.position, u.team.lightColor, u.kind == .tank ? 4 : 3)
        }
        while i < dots.count {
            dots[i].isHidden = true
            i += 1
        }
        let vr = game.visibleWorldRect().intersection(CGRect(origin: .zero, size: worldSize))
        if !vr.isNull {
            camFrame.path = CGPath(rect: CGRect(x: vr.minX * mmScale, y: vr.minY * mmScale,
                                                width: vr.width * mmScale, height: vr.height * mmScale), transform: nil)
        }
    }

    func ping(at p: CGPoint) {
        let r = SKSpriteNode(texture: Art.ring)
        r.size = CGSize(width: 34, height: 34)
        r.color = Palette.bad
        r.colorBlendFactor = 1
        r.position = CGPoint(x: p.x * mmScale, y: p.y * mmScale)
        r.zPosition = 6
        minimapLayer.addChild(r)
        let pulse = SKAction.sequence([.scale(to: 0.2, duration: 0), .fadeIn(withDuration: 0),
                                       .group([.scale(to: 1, duration: 0.6), .fadeOut(withDuration: 0.6)])])
        r.run(.sequence([.repeat(pulse, count: 4), .removeFromParent()]))
    }

    // MARK: - Selection info

    private func portrait(_ tex: SKTexture, team: Team, size s: CGFloat, fit: CGFloat) -> SKNode {
        let n = SKNode()
        let bg = SKSpriteNode(texture: Art.button(CGSize(width: s, height: s), .active, accent: team.color))
        bg.size = CGSize(width: s, height: s)
        n.addChild(bg)
        let img = SKSpriteNode(texture: tex)
        let ts = tex.size()
        let k = fit / max(ts.width, ts.height)
        img.size = CGSize(width: ts.width * k, height: ts.height * k)
        img.zRotation = .pi / 2
        n.addChild(img)
        return n
    }

    private func bar(width: CGFloat, frac: CGFloat, color: NSColor, at p: CGPoint, height: CGFloat = 6) -> SKNode {
        let n = SKNode()
        let back = SKSpriteNode(color: NSColor(white: 0, alpha: 0.5), size: CGSize(width: width, height: height))
        back.anchorPoint = CGPoint(x: 0, y: 0.5)
        let fill = SKSpriteNode(color: color, size: CGSize(width: width * max(0, min(1, frac)), height: height))
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        n.addChild(back)
        n.addChild(fill)
        n.position = p
        return n
    }

    private func at(_ n: SKNode, _ x: CGFloat, _ y: CGFloat) -> SKNode {
        n.position = CGPoint(x: x, y: y)
        return n
    }

    private func hpColor(_ f: CGFloat) -> NSColor { f > 0.6 ? Palette.good : (f > 0.3 ? Palette.amber : Palette.bad) }

    private func rebuildInfo() {
        infoLayer.removeAllChildren()
        queueRects = []
        iconRects = []
        let sel = game.selection
        let x0 = infoRect.minX, top = infoRect.maxY
        if sel.isEmpty {
            infoLayer.addChild(at(makeLabel("NO SELECTION", size: 13, color: Palette.amber, font: Fonts.bold), x0, top - 14))
            let tips = ["Drag to select units · right-click to move, attack or mine",
                        "Shift+right-click queues orders · A attack-move · S stop",
                        "I idle engineer · ` select army · Space jump to alert",
                        "Scroll or pinch to zoom · H opens the field manual"]
            for (i, t) in tips.enumerated() {
                infoLayer.addChild(at(makeLabel(t, size: 13, color: Palette.dim, font: Fonts.medium), x0, top - 42 - CGFloat(i) * 22))
            }
            return
        }
        if sel.count == 1 { single(sel[0], x0: x0, top: top) } else { multi(sel, x0: x0, top: top) }
    }

    private func single(_ e: Entity, x0: CGFloat, top: CGFloat) {
        let ps: CGFloat = 92
        infoLayer.addChild(at(portrait(e.portrait, team: e.team, size: ps, fit: e is Building ? 80 : 64), x0 + ps / 2, top - ps / 2))
        let tx = x0 + ps + 16
        infoLayer.addChild(at(makeLabel(e.displayName.uppercased(), size: 18, font: Fonts.heavy), tx, top - 18))
        infoLayer.addChild(at(makeLabel(e.team.isLocal ? "Your forces" : "\(e.team.isFriendly ? "Allied" : "Hostile") · \(game.playerName(e.team))", size: 12, color: e.team.color, font: Fonts.demi), tx, top - 36))
        let frac = e.hp / e.maxHp
        infoLayer.addChild(bar(width: 180, frac: frac, color: hpColor(frac), at: CGPoint(x: tx, y: top - 52), height: 8))
        infoLayer.addChild(at(makeLabel("\(Int(ceil(e.hp))) / \(Int(e.maxHp))", size: 11, color: Palette.text, font: Fonts.mono), tx + 188, top - 56))

        if let u = e as? Unit {
            let s = u.stats
            let stats = "DMG \(Int(s.damage))\(s.splash > 0 ? "+splash" : "")   RANGE \(Int(s.range))   SPEED \(Int(s.speed))"
            infoLayer.addChild(at(makeLabel(stats, size: 11, color: Palette.dim, font: Fonts.mono), tx, top - 76))
            var status = u.team.isLocal ? u.statusText : (u.team.isFriendly ? "Allied unit" : "Hostile unit")
            if u.carrying > 0 && u.team.isLocal { status += " · carrying \(u.carrying)" }
            if u.queuedCount > 0 && u.team.isLocal { status += " · +\(u.queuedCount) queued" }
            infoLayer.addChild(at(makeLabel(status, size: 14, color: Palette.text, font: Fonts.demi), x0, top - ps - 22))
            return
        }
        guard let b = e as? Building else { return }
        if !b.built {
            infoLayer.addChild(at(makeLabel("Under construction  \(Int(b.progress * 100))%", size: 13, color: Palette.amber), tx, top - 78))
            infoLayer.addChild(bar(width: min(260, infoRect.maxX - tx), frac: b.progress, color: Palette.amber,
                                   at: CGPoint(x: x0, y: top - ps - 18), height: 8))
            return
        }
        if !b.team.isLocal {
            infoLayer.addChild(at(makeLabel(b.stats.desc, size: 13, color: Palette.dim, font: Fonts.medium), x0, top - ps - 22))
            return
        }
        if !b.queue.isEmpty {
            infoLayer.addChild(at(makeLabel("Training \(b.queue[0].stats.name)  \(Int(b.queueProgress * 100))%", size: 12,
                                            color: Palette.text, font: Fonts.demi), tx, top - 78))
            let slot: CGFloat = 44
            for i in 0..<5 {
                let r = CGRect(x: x0 + CGFloat(i) * (slot + 6), y: top - ps - slot - 12, width: slot, height: slot)
                if i < b.queue.count {
                    infoLayer.addChild(at(portrait(Art.unit(b.queue[i], b.team), team: b.team, size: slot, fit: 34), r.midX, r.midY))
                    let x = makeLabel("✕", size: 9, color: NSColor(white: 1, alpha: 0.6), font: Fonts.bold, align: .right, valign: .top)
                    infoLayer.addChild(at(x, r.maxX - 3, r.maxY - 3))
                    queueRects.append((r, i))
                } else {
                    let s = SKSpriteNode(texture: Art.button(r.size, .disabled))
                    s.size = r.size
                    infoLayer.addChild(at(s, r.midX, r.midY))
                }
            }
            infoLayer.addChild(bar(width: slot, frac: b.queueProgress, color: Palette.crystal,
                                   at: CGPoint(x: x0, y: top - ps - slot - 18), height: 4))
        } else {
            var line = b.stats.desc
            if !b.stats.produces.isEmpty { line += "  Right-click the map to set a rally point." }
            let l = makeLabel(line, size: 13, color: Palette.dim, font: Fonts.medium, valign: .top)
            l.numberOfLines = 0
            l.preferredMaxLayoutWidth = max(200, infoRect.maxX - tx)
            infoLayer.addChild(at(l, tx, top - 68))
        }
    }

    private func multi(_ sel: [Entity], x0: CGFloat, top: CGFloat) {
        var counts: [String: Int] = [:]
        for e in sel { counts[e.displayName, default: 0] += 1 }
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: "  ·  ")
        infoLayer.addChild(at(makeLabel("\(sel.count) SELECTED", size: 13, color: Palette.amber, font: Fonts.bold), x0, top - 14))
        infoLayer.addChild(at(makeLabel(summary, size: 13, color: Palette.text, font: Fonts.medium), x0 + 110, top - 14))
        let s: CGFloat = 40, g: CGFloat = 5
        let cols = max(1, Int((infoRect.width + g) / (s + g)))
        for (i, e) in sel.prefix(cols * 3).enumerated() {
            let c = i % cols, r = i / cols
            let rect = CGRect(x: x0 + CGFloat(c) * (s + g), y: top - 34 - s - CGFloat(r) * (s + g + 3), width: s, height: s)
            infoLayer.addChild(at(portrait(e.portrait, team: e.team, size: s, fit: e is Building ? 36 : 30), rect.midX, rect.midY))
            let f = e.hp / e.maxHp
            infoLayer.addChild(bar(width: s - 6, frac: f, color: hpColor(f), at: CGPoint(x: rect.minX + 3, y: rect.minY + 4), height: 3))
            iconRects.append((rect, e))
        }
    }

    // MARK: - Command card

    private func rebuildCard() {
        let buttons = game.commandButtons()
        let sig = buttons.map { b -> String in
            let afford = b.cost.map { game.myResources >= CGFloat($0) } ?? true
            return "\(b.title)\(b.enabled)\(afford)"
        }.joined(separator: "|")
        currentButtons = buttons
        guard sig != cardSignature else { return }
        cardSignature = sig
        cardLayer.removeAllChildren()
        buttonRects = []
        buttonBGs = []
        hoverButton = nil
        let bs = Self.buttonSize, gap = Self.buttonGap
        for i in 0..<8 {
            let col = i % 4, row = i / 4
            let r = CGRect(x: cardOrigin.x + CGFloat(col) * (bs + gap), y: cardOrigin.y + CGFloat(1 - row) * (bs + gap),
                           width: bs, height: bs)
            guard i < buttons.count else {
                let empty = SKSpriteNode(texture: Art.button(r.size, .disabled))
                empty.size = r.size
                empty.alpha = 0.5
                cardLayer.addChild(at(empty, r.midX, r.midY))
                continue
            }
            let b = buttons[i]
            let afford = b.cost.map { game.myResources >= CGFloat($0) } ?? true
            let bg = SKSpriteNode(texture: Art.button(r.size, b.enabled ? .normal : .disabled))
            bg.size = r.size
            cardLayer.addChild(at(bg, r.midX, r.midY))
            buttonBGs.append(bg)
            buttonRects.append(r)

            // Locked, not missing: a greyscale icon keeps saying what the button builds. (At the old 35% alpha
            // the art vanished into the dark disabled button.)
            let icon = SKSpriteNode(texture: b.enabled ? Art.icon(b.icon)
                                                       : Art.greyscale(Art.icon(b.icon), key: "\(b.icon)-\(Team.local.rawValue)"))
            let ts = icon.texture!.size()
            let fit: CGFloat
            switch b.icon {
            case .unit(let k): fit = k == .tank ? 40 : 30
            case .building: fit = 38
            case .siege: fit = 34
            default: fit = 30
            }
            let k = fit / max(ts.width, ts.height)
            icon.size = CGSize(width: ts.width * k, height: ts.height * k)
            if case .unit = b.icon { icon.zRotation = .pi / 2 }
            icon.alpha = b.enabled ? 1 : 0.65
            bg.addChild(at(icon, 0, 5))

            let badge = SKSpriteNode(color: NSColor(white: 0, alpha: 0.55), size: CGSize(width: 16, height: 16))
            bg.addChild(at(badge, -bs / 2 + 11, bs / 2 - 11))
            let key = makeLabel(b.hotkey, size: 11, color: Palette.amber, font: Fonts.bold, align: .center, valign: .center)
            bg.addChild(at(key, -bs / 2 + 11, bs / 2 - 11))
            let title = makeLabel(b.title, size: 9.5, color: b.enabled ? Palette.text : Palette.dim, font: Fonts.demi, align: .center, valign: .center)
            bg.addChild(at(title, 0, -bs / 2 + 10))
            if let c = b.cost {
                let cl = makeLabel("\(c)", size: 10, color: afford ? Palette.crystal : Palette.bad, font: Fonts.mono, align: .right, valign: .center)
                bg.addChild(at(cl, bs / 2 - 6, bs / 2 - 11))
            }
        }
    }

    private func updateHoverStates(_ mouse: CGPoint?) {
        // Command buttons
        let idx = mouse.flatMap { m in buttonRects.firstIndex { $0.contains(m) } }
        if idx != hoverButton && !overlayVisible {
            if let old = hoverButton, old < buttonBGs.count, old < currentButtons.count {
                buttonBGs[old].texture = Art.button(buttonRects[old].size, currentButtons[old].enabled ? .normal : .disabled)
            }
            if let i = idx, i < buttonBGs.count, i < currentButtons.count, currentButtons[i].enabled {
                buttonBGs[i].texture = Art.button(buttonRects[i].size, .hover)
            }
            hoverButton = idx
        }
        if let i = idx, i < currentButtons.count, !overlayVisible {
            showTooltip(currentButtons[i])
        } else {
            tooltip.isHidden = true
        }
        // Overlay buttons
        if overlayVisible {
            for (r, bg, _) in overlayButtons {
                let hover = mouse.map { r.contains($0) } ?? false
                let want = Art.button(r.size, hover ? .hover : .normal)
                if bg.texture !== want { bg.texture = want }
            }
        }
    }

    private func showTooltip(_ b: CommandButton) {
        tooltipTitle.text = "\(b.title)   [\(b.hotkey)]"
        tooltipCost.text = b.cost.map { "◆ \($0)" } ?? ""
        tooltipBody.text = b.tip
        let pad: CGFloat = 12
        let w = max(tooltipBody.frame.width, tooltipTitle.frame.width + tooltipCost.frame.width + 20) + pad * 2
        let h = tooltipTitle.frame.height + tooltipBody.frame.height + pad * 2 + 8
        tooltipBG.texture = Art.panel(CGSize(width: ceil(w), height: ceil(h)), radius: 8, accent: Palette.amber)
        tooltipBG.size = CGSize(width: ceil(w), height: ceil(h))
        tooltipTitle.position = CGPoint(x: pad, y: h - pad)
        tooltipCost.position = CGPoint(x: w - pad, y: h - pad)
        tooltipBody.position = CGPoint(x: pad, y: h - pad - tooltipTitle.frame.height - 8)
        tooltip.position = CGPoint(x: min(cardOrigin.x, size.width / 2 - w - 12), y: -size.height / 2 + Self.panelHeight + 10)
        tooltip.isHidden = false
    }

    func setHover(_ text: String?, color: NSColor, at p: CGPoint) {
        guard let text, !overlayVisible else {
            hoverTag.isHidden = true
            return
        }
        if hoverLabel.text != text {
            hoverLabel.text = text
            let w = ceil(hoverLabel.frame.width + 16)
            hoverBG.texture = Art.panel(CGSize(width: w, height: 22), radius: 6)
            hoverBG.size = CGSize(width: w, height: 22)
        }
        hoverLabel.fontColor = color
        hoverTag.position = CGPoint(x: p.x + 18, y: p.y - 24)
        hoverTag.isHidden = false
    }

    // MARK: - Overlays

    func clearOverlay() {
        overlay.removeAllChildren()
        overlayButtons = []
        overlayBuilder = nil
        needsRefresh = true
    }

    private func present(_ builder: @escaping () -> Void) {
        overlayBuilder = builder
        tooltip.isHidden = true
        hoverTag.isHidden = true
        objectivesLayer.removeAllChildren()
        builder()
    }

    private func settingsRows() -> [[(String, () -> Void)]] {
        [
            [("Speed: \(Settings.speedName)", { [unowned self] in Settings.speedIndex += 1; self.overlayBuilder?() }),
             ("Edge scroll: \(Settings.edgeScroll ? "On" : "Off")", { [unowned self] in Settings.edgeScroll.toggle(); self.overlayBuilder?() })],
            [("Sound: \(Settings.sound ? "On" : "Off")", { [unowned self] in Settings.sound.toggle(); self.overlayBuilder?() }),
             ("Objectives: \(Settings.objectives ? "On" : "Off")", { [unowned self] in Settings.objectives.toggle(); self.overlayBuilder?() })],
        ]
    }

    func showPause() {
        if game.isMultiplayer {
            present { [unowned self] in
                var rows = self.settingsRows()
                rows[0] = [rows[0][1]]  // game speed is set by the server
                self.drawOverlay(title: "GAME MENU", color: Palette.text, subtitle: "The game keeps running while this menu is open.",
                                 lines: [], rows: rows + [[("Resume", { [unowned self] in self.game.togglePause() }),
                                                           ("Leave Game", { [unowned self] in self.game.toMenu() })]])
            }
            return
        }
        present { [unowned self] in
            self.drawOverlay(title: "PAUSED", color: Palette.text, subtitle: "Settings are saved automatically.", lines: [],
                             rows: self.settingsRows() + [[("Resume", { [unowned self] in self.game.togglePause() }),
                                                           ("Main Menu", { [unowned self] in self.game.toMenu() })]])
        }
    }

    func showHelp() {
        present { [unowned self] in
            self.drawOverlay(title: "FIELD MANUAL", color: Palette.amber, subtitle: "Destroy every enemy building to win.",
                             lines: [
                                "Left-click / drag — select · Shift adds · Double-click selects all of a type",
                                "Right-click — move · attack · mine crystal · set rally point (buildings)",
                                "Shift + right-click — queue orders    A then click — attack-move    S — stop",
                                "Engineer: C Command Center · E Supply Depot · B Barracks · F Factory · T Turret",
                                "Command Center: W Engineer · Barracks: R Ranger · Factory: T Siege Tank",
                                "Ctrl+1–9 — assign group · 1–9 — recall (double-tap to jump there)",
                                "I — next idle engineer · ` or F2 — select army · Space — jump to alert",
                                "Arrows / screen edge / two-finger swipe — pan · Pinch, wheel, +/− — zoom",
                                "P or Esc — pause & settings · O — toggle objectives",
                             ],
                             rows: [[("Close", { [unowned self] in self.game.toggleHelp() })]])
        }
    }

    func showEnd(won: Bool) {
        let g = game
        present { [unowned self] in
            let online = g.isMultiplayer
            self.drawOverlay(
                title: won ? "VICTORY" : "DEFEAT",
                color: won ? Palette.good : Palette.bad,
                subtitle: won ? (online ? "Your team is victorious." : "The enemy base has fallen.")
                              : (online ? "Your forces have been defeated." : "Your base has been overrun."),
                lines: g.endStatsLines() + [online ? "Return — back to lobby · Esc — main menu" : "Return — play again · Esc — main menu"],
                rows: [[(online ? "Back to Lobby" : "Play Again", { [unowned self] in self.game.restart() }),
                        ("Main Menu", { [unowned self] in self.game.toMenu() })]])
        }
    }

    func showEliminated() {
        present { [unowned self] in
            self.drawOverlay(title: "ELIMINATED", color: Palette.bad, subtitle: "All your buildings were destroyed. The match continues.",
                             lines: ["You can keep watching with your team's vision, or leave the game."],
                             rows: [[("Keep Watching", { [unowned self] in self.clearOverlay() }),
                                     ("Leave Game", { [unowned self] in self.game.toMenu() })]])
        }
    }

    func showDisconnected(_ reason: String) {
        present { [unowned self] in
            self.drawOverlay(title: "DISCONNECTED", color: Palette.bad, subtitle: "The connection to the server was lost.",
                             lines: [String(reason.prefix(80))], rows: [[("Main Menu", { [unowned self] in self.game.toMenu() })]])
        }
    }

    // MARK: Multiplayer extras

    private func drawScoreboard(_ net: NetSession) {
        let players = net.players.values.sorted { ($0.team, $0.slot) < ($1.team, $1.slot) }
        let w: CGFloat = 260, rowH: CGFloat = 22
        let h = 30 + CGFloat(players.count) * rowH
        let bg = SKSpriteNode(texture: Art.panel(CGSize(width: w, height: h), radius: 8))
        bg.size = CGSize(width: w, height: h)
        bg.anchorPoint = CGPoint(x: 0, y: 1)
        objectivesLayer.addChild(bg)
        let title = makeLabel("PLAYERS", size: 11, color: Palette.amber, font: Fonts.bold, valign: .center)
        title.position = CGPoint(x: 12, y: -14)
        objectivesLayer.addChild(title)
        let hint = makeLabel("Return to chat", size: 10, color: Palette.dim, font: Fonts.medium, align: .right, valign: .center)
        hint.position = CGPoint(x: w - 12, y: -14)
        hint.isHidden = net.isLocal
        objectivesLayer.addChild(hint)
        for (i, p) in players.enumerated() {
            let y = -34 - CGFloat(i) * rowH
            let dot = SKShapeNode(circleOfRadius: 5)
            dot.fillColor = Team(rawValue: p.slot).color
            dot.strokeColor = .clear
            dot.position = CGPoint(x: 18, y: y)
            objectivesLayer.addChild(dot)
            let name = p.name + (p.slot == net.slot && !net.isLocal ? " (you)" : "") + (p.isAI ? " · AI" : "")
            let l = makeLabel(name, size: 12, color: p.alive ? Palette.text : Palette.dim, font: p.slot == net.slot ? Fonts.bold : Fonts.medium, valign: .center)
            l.position = CGPoint(x: 30, y: y)
            objectivesLayer.addChild(l)
            let t = makeLabel(p.alive ? "Team \(p.team)" : "Out", size: 11, color: p.alive ? Palette.dim : Palette.bad, font: Fonts.medium, align: .right, valign: .center)
            t.position = CGPoint(x: w - 12, y: y)
            objectivesLayer.addChild(t)
        }
    }

    var chatText: String? {
        didSet {
            chatLabel.isHidden = chatText == nil
            chatLabel.text = "Say: " + (chatText ?? "") + "_"
        }
    }

    private func drawOverlay(title: String, color: NSColor, subtitle: String?, lines: [String], rows: [[(String, () -> Void)]]) {
        overlay.removeAllChildren()
        overlayButtons = []
        let dim = SKSpriteNode(color: NSColor(white: 0, alpha: 0.6), size: size)
        overlay.addChild(dim)

        let lineH: CGFloat = 24, bh: CGFloat = 42, rowGap: CGFloat = 12
        let boxW = min(size.width - 40, 740)
        let boxH = 104 + CGFloat(lines.count) * lineH + (subtitle == nil ? 0 : 30) + CGFloat(rows.count) * (bh + rowGap) + 16
        let box = SKSpriteNode(texture: Art.panel(CGSize(width: boxW, height: boxH), radius: 16, accent: color))
        box.size = CGSize(width: boxW, height: boxH)
        overlay.addChild(box)
        let glow = SKSpriteNode(texture: Art.glow)
        glow.size = CGSize(width: boxW * 1.3, height: boxH * 1.6)
        glow.color = color
        glow.colorBlendFactor = 1
        glow.alpha = 0.12
        glow.zPosition = -1
        overlay.addChild(glow)

        var y = boxH / 2 - 52
        overlay.addChild(at(makeLabel(title, size: 42, color: color, font: Fonts.heavy, align: .center, valign: .center), 0, y))
        y -= 40
        if let s = subtitle {
            overlay.addChild(at(makeLabel(s, size: 16, color: Palette.text, font: Fonts.demi, align: .center, valign: .center), 0, y))
            y -= 32
        }
        for l in lines {
            overlay.addChild(at(makeLabel(l, size: 14, color: Palette.dim, font: Fonts.medium, align: .center, valign: .center), 0, y))
            y -= lineH
        }
        y -= 8
        let bw: CGFloat = 220, bg: CGFloat = 16
        for row in rows {
            let total = CGFloat(row.count) * bw + CGFloat(max(0, row.count - 1)) * bg
            var bx = -total / 2
            for (label, action) in row {
                let r = CGRect(x: bx, y: y - bh, width: bw, height: bh)
                let s = SKSpriteNode(texture: Art.button(r.size, .normal))
                s.size = r.size
                overlay.addChild(at(s, r.midX, r.midY))
                overlay.addChild(at(makeLabel(label, size: 15, font: Fonts.bold, align: .center, valign: .center), r.midX, r.midY))
                overlayButtons.append((r, s, action))
                bx += bw + bg
            }
            y -= bh + rowGap
        }
    }
}
