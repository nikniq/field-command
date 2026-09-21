import SpriteKit
import AppKit

struct Obstacle {
    let position: CGPoint
    let radius: CGFloat
}

final class GameScene: SKScene {
    let difficulty: Difficulty

    var units: [Unit] = []
    var buildings: [Building] = []
    var crystals: [Crystal] = []
    var obstacles: [Obstacle] = []
    private var obstacleBuckets: [Int: [Int]] = [:]
    private let bucketSize: CGFloat = 128
    var resources: [CGFloat] = [250, 250]
    var selection: [Entity] = []

    // Map layout, also used to draw the minimap
    var playerStart = CGPoint.zero
    var enemyStart = CGPoint.zero
    var clearings: [(CGPoint, CGFloat)] = []
    var roads: [[CGPoint]] = []
    var walls: [CGRect] = []  // impassable water and cliffs
    var terrainImage: CGImage?
    /// Crossings, in map order. The server numbers them the same way, so the nth snapshot entry is this
    /// nth node; their condition arrives with every snapshot.
    var bridgeNodes: [BridgeNode] = []
    var mapKey = "twin_ridges"

    let world = SKNode()
    let decalLayer = SKNode()
    let entityLayer = SKNode()
    let effectLayer = SKNode()
    let cam = SKCameraNode()
    var fog = FogOfWar()
    var hud: HUD!
    var ai: AI!
    var autoPlayer: AI?

    var placing: BuildingKind?
    private let ghost = SKSpriteNode()
    private let ghostFrame = SKShapeNode()
    private let ghostRange = SKShapeNode()
    var attackMovePending = false
    var dragStart: CGPoint?
    private let selectionBox = SKShapeNode()
    private let rallyFlag = SKNode()
    private var orderLines: [SKShapeNode] = []
    private var dashPhase: CGFloat = 0
    private weak var lastBuilder: Unit?

    var keysDown = Set<UInt16>()
    var controlGroups: [Int: [Entity]] = [:]
    private var lastGroupTap: (group: Int, time: TimeInterval)?
    private var lastTime: TimeInterval = 0
    var elapsed: CGFloat = 0
    var gamePaused = false
    var gameOver = false
    var minimapDragging = false
    private var lastAlertTime: CGFloat = -100
    private var lastAlertPos: CGPoint?
    var fogTimer: CGFloat = 0
    var didSetup = false
    private var idleCycle = 0
    private var shakeAmount: CGFloat = 0
    private var shakeOffset = CGPoint.zero
    private weak var hovered: Entity?

    /// Set when this scene mirrors a multiplayer server game.
    var net: NetSession?
    var isNet: Bool { net != nil }
    /// A game with other people in it (a local skirmish runs on a private server but is still single player).
    var isMultiplayer: Bool { net.map { !$0.isLocal } ?? false }

    var myResources: CGFloat { net.map { CGFloat($0.resources) } ?? resources[0] }
    var mySupplyUsed: Int { net?.supplyUsed ?? supplyUsed(.player) }
    var mySupplyCap: Int { net?.supplyCap ?? supplyCap(.player) }

    func isComputer(_ t: Team) -> Bool {
        if let net { return net.players[t.rawValue]?.isAI ?? false }
        return t == .enemy || (Debug.autoplay && t == .player)
    }

    func playerName(_ t: Team) -> String {
        if let net { return net.players[t.rawValue]?.name ?? "Player \(t.rawValue + 1)" }
        return t == .player ? "You" : "Computer"
    }

    var unitsTrained = [0, 0]
    var unitsLost = [0, 0]
    var crystalsMined = [0, 0]
    var trainedKinds: [UnitKind: Int] = [:]

    init(size: CGSize, difficulty: Difficulty, net: NetSession? = nil) {
        self.difficulty = difficulty
        self.net = net
        super.init(size: size)
        scaleMode = .resizeFill
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    override func didMove(to view: SKView) {
        guard !didSetup else { return }
        didSetup = true
        if net == nil { Team.resetForSinglePlayer() }
        backgroundColor = .rgb(0.03, 0.04, 0.05)

        addChild(world)
        decalLayer.zPosition = -5
        effectLayer.zPosition = 30
        world.addChild(decalLayer)
        world.addChild(entityLayer)
        world.addChild(effectLayer)
        world.addChild(fog.node)

        addChild(cam)
        camera = cam
        let vignette = SKSpriteNode(texture: Art.vignette)
        vignette.zPosition = 90
        vignette.name = "vignette"
        cam.addChild(vignette)

        selectionBox.strokeColor = Palette.good
        selectionBox.fillColor = Palette.good.withAlphaComponent(0.08)
        selectionBox.lineWidth = 1.5
        selectionBox.zPosition = 70
        selectionBox.isHidden = true
        world.addChild(selectionBox)

        ghost.zPosition = 60
        ghost.alpha = 0.6
        ghost.colorBlendFactor = 0.45
        ghost.isHidden = true
        world.addChild(ghost)
        ghostFrame.zPosition = 61
        ghostFrame.lineWidth = 2
        ghostFrame.isHidden = true
        world.addChild(ghostFrame)
        ghostRange.zPosition = 59
        ghostRange.isHidden = true
        ghostRange.strokeColor = NSColor(white: 1, alpha: 0.35)
        ghostRange.fillColor = NSColor(white: 1, alpha: 0.04)
        ghostRange.lineWidth = 1
        world.addChild(ghostRange)

        for color in [Palette.good, Palette.bad, Palette.crystal, Palette.amber] {
            let n = SKShapeNode()
            n.strokeColor = color.withAlphaComponent(0.6)
            n.lineWidth = 1.5
            n.zPosition = 48
            world.addChild(n)
            orderLines.append(n)
        }
        let pole = SKSpriteNode(color: .white, size: CGSize(width: 2, height: 26))
        pole.position = CGPoint(x: 0, y: 13)
        let flagPath = CGMutablePath()
        flagPath.addLines(between: [CGPoint(x: 1, y: 26), CGPoint(x: 16, y: 20), CGPoint(x: 1, y: 14)])
        flagPath.closeSubpath()
        let flag = SKShapeNode(path: flagPath)
        flag.fillColor = Palette.good
        flag.strokeColor = .clear
        rallyFlag.addChild(pole)
        rallyFlag.addChild(flag)
        rallyFlag.zPosition = 49
        rallyFlag.isHidden = true
        world.addChild(rallyFlag)

        if let net {
            net.applyTeams()
            setupNetMap(net)
        } else {
            ai = AI(game: self)
            if Debug.autoplay { autoPlayer = AI(game: self, team: .player) }
            setupMap()
        }
        buildScenery()

        hud = HUD(game: self)
        hud.zPosition = 100
        cam.addChild(hud)
        hud.layout(size: size)
        layoutVignette()

        updateFog()
        fog.render(dt: 10)
        hud.setFog(fog.texture)
        centerCamera(on: playerStart + CGPoint(x: 150, y: 120))
        hud.flash("Mine crystal, build an army, and destroy every enemy building.", color: Palette.text)
        hud.flash(isMultiplayer ? "Multiplayer: press Enter to chat, H for the field manual." : "Press H at any time for the field manual.",
                  color: Palette.dim)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard didSetup else { return }
        hud?.layout(size: size)
        layoutVignette()
        clampCamera()
    }

    private func layoutVignette() {
        (cam.childNode(withName: "vignette") as? SKSpriteNode)?.size = CGSize(width: size.width * 1.1, height: size.height * 1.1)
    }

    private func setupMap() {
        setWorldSize(defaultWorldSize.width, defaultWorldSize.height)  // the built-in skirmish map is the standard size
        fog = FogOfWar()
        playerStart = CGPoint(x: 560, y: 560)
        enemyStart = CGPoint(x: worldSize.width - 560, y: worldSize.height - 560)
        var variant = 0

        for (team, hqPos, baseAngle) in [(Team.player, playerStart, CGFloat.pi), (Team.enemy, enemyStart, CGFloat(0))] {
            clearings.append((hqPos, 470))
            let hq = Building(kind: .hq, team: team, at: hqPos, built: true, game: self)
            addBuilding(hq)
            var line: [Crystal] = []
            for i in 0..<8 {
                let a = baseAngle + CGFloat(i) / 7 * (.pi / 2)
                let d: CGFloat = i % 2 == 0 ? 255 : 285
                let c = Crystal(at: hqPos + CGPoint(x: cos(a) * d, y: sin(a) * d), amount: 1500, variant: variant)
                variant += 1
                addCrystal(c)
                line.append(c)
            }
            for i in 0..<5 {
                let a = baseAngle + .pi / 4 + CGFloat(i - 2) * 0.28
                let u = Unit(kind: .worker, team: team, at: hqPos + CGPoint(x: cos(a) * 130, y: sin(a) * 130), game: self)
                addUnit(u)
                u.order = .gather(line[(i * 2 + 1) % line.count])
            }
        }

        let expansions: [(CGPoint, Int, Int)] = [
            (CGPoint(x: 2000, y: 480), 6, 1000), (CGPoint(x: 2000, y: 2320), 6, 1000),
            (CGPoint(x: 520, y: 2280), 6, 1000), (CGPoint(x: 3480, y: 520), 6, 1000),
            (CGPoint(x: 2000, y: 1400), 4, 2000),
        ]
        for (center, n, amount) in expansions {
            clearings.append((center, 300))
            for i in 0..<n {
                let a = CGFloat(i) / CGFloat(n) * .pi * 2 + 0.3
                addCrystal(Crystal(at: center + CGPoint(x: cos(a) * 70, y: sin(a) * 70), amount: amount, variant: variant))
                variant += 1
            }
        }

        let mid = CGPoint(x: 2000, y: 1400)
        roads = [
            [playerStart, CGPoint(x: 1150, y: 820), CGPoint(x: 1600, y: 1250), mid, CGPoint(x: 2400, y: 1550), CGPoint(x: 2850, y: 1980), enemyStart],
            [CGPoint(x: 1600, y: 1250), CGPoint(x: 1850, y: 800), CGPoint(x: 2000, y: 600)],
            [CGPoint(x: 2400, y: 1550), CGPoint(x: 2150, y: 2000), CGPoint(x: 2000, y: 2200)],
            [playerStart, CGPoint(x: 700, y: 1400), CGPoint(x: 560, y: 2150)],
            [enemyStart, CGPoint(x: 3300, y: 1400), CGPoint(x: 3440, y: 650)],
        ]
    }

    private func distanceToRoads(_ p: CGPoint) -> CGFloat {
        var best = CGFloat.infinity
        for road in roads {
            for i in 0..<(road.count - 1) {
                let a = road[i], b = road[i + 1]
                let ab = b - a
                let t = clamp((p - a).dot(ab) / max(0.001, ab.dot(ab)), 0, 1)
                best = min(best, p.distance(to: a + ab * t))
            }
        }
        return best
    }

    private func buildScenery() {
        let tex = Art.ground()
        let ts: CGFloat = 1024
        var y: CGFloat = 0
        while y < worldSize.height {
            var x: CGFloat = 0
            while x < worldSize.width {
                let s = SKSpriteNode(texture: tex)
                s.anchorPoint = .zero
                s.size = CGSize(width: ts, height: ts)
                s.position = CGPoint(x: x, y: y)
                s.zPosition = -10
                world.addChild(s)
                x += ts
            }
            y += ts
        }
        if let net, let img = Terrain.image(net.map) {
            terrainImage = img
            let t = SKTexture(cgImage: img)
            t.filteringMode = .linear
            let s = SKSpriteNode(texture: t)
            s.anchorPoint = .zero
            s.size = worldSize
            s.zPosition = -7.9
            world.addChild(s)
        }
        // Bridges. Ids are assigned by the server in map order, and the first snapshot fills in condition.
        if let net {
            for (i, r) in Terrain.bridges(net.map).enumerated() {
                let node = BridgeNode(rect: r, seed: UInt64(i + 7))
                world.addChild(node)
                bridgeNodes.append(node)
            }
        }
        func onTerrain(_ p: CGPoint) -> Bool { walls.contains { rectDistance($0, p) < 50 } }
        // Dark void beyond the map edge.
        let pad: CGFloat = 3000
        for r in [CGRect(x: worldSize.width, y: -pad, width: pad, height: worldSize.height + 2 * pad),
                  CGRect(x: -pad, y: worldSize.height, width: worldSize.width + 2 * pad, height: pad),
                  CGRect(x: -pad, y: -pad, width: pad, height: worldSize.height + 2 * pad),
                  CGRect(x: -pad, y: -pad, width: worldSize.width + 2 * pad, height: pad)] {
            let s = SKSpriteNode(color: backgroundColor, size: r.size)
            s.anchorPoint = .zero
            s.position = r.origin
            s.zPosition = -8
            world.addChild(s)
        }

        var rng = SeededRNG(42)
        let dirt = NSColor.rgb(0.42, 0.34, 0.22)
        func stamp(_ p: CGPoint, _ size: CGFloat, _ alpha: CGFloat) {
            let s = SKSpriteNode(texture: Art.blob)
            s.size = CGSize(width: size, height: size * CGFloat.random(in: 0.7...1, using: &rng))
            s.color = dirt
            s.colorBlendFactor = 1
            s.alpha = alpha
            s.zRotation = CGFloat.random(in: 0...(2 * .pi), using: &rng)
            s.position = p
            s.zPosition = -9
            world.addChild(s)
        }
        for (c, r) in clearings {
            for _ in 0..<Int(r / 22) {
                let a = CGFloat.random(in: 0...(2 * .pi), using: &rng)
                let d = CGFloat.random(in: 0...(r * 0.6), using: &rng)
                stamp(c + CGPoint(x: cos(a) * d, y: sin(a) * d), r * CGFloat.random(in: 0.6...1.0, using: &rng), 0.5)
            }
        }
        for road in roads {
            for i in 0..<(road.count - 1) {
                let a = road[i], b = road[i + 1]
                let n = Int(a.distance(to: b) / 28)
                for k in 0...max(1, n) {
                    let t = CGFloat(k) / CGFloat(max(1, n))
                    let p = a + (b - a) * t + CGPoint(x: CGFloat.random(in: -8...8, using: &rng), y: CGFloat.random(in: -8...8, using: &rng))
                    stamp(p, CGFloat.random(in: 110...150, using: &rng), 0.42)
                }
            }
        }
        for _ in 0..<500 {
            let t = SKSpriteNode(texture: Art.tuft)
            t.size = CGSize(width: 16, height: 16)
            t.position = CGPoint(x: CGFloat.random(in: 0...worldSize.width, using: &rng), y: CGFloat.random(in: 0...worldSize.height, using: &rng))
            if onTerrain(t.position) { continue }
            t.zPosition = -8.5
            t.alpha = 0.8
            world.addChild(t)
        }
        for i in 0..<70 {
            let p = CGPoint(x: CGFloat.random(in: 0...worldSize.width, using: &rng), y: CGFloat.random(in: 0...worldSize.height, using: &rng))
            let r = SKSpriteNode(texture: Art.rock(i % 4))
            let s = CGFloat.random(in: 0.5...1.1, using: &rng)
            if onTerrain(p) { continue }
            r.size = CGSize(width: 44 * s, height: 36 * s)
            r.position = p
            r.zRotation = CGFloat.random(in: -0.5...0.5, using: &rng)
            r.zPosition = -8
            world.addChild(r)
        }

        // Forests: blocking obstacles kept clear of bases, crystal fields and roads.
        func treeAllowed(_ p: CGPoint) -> Bool {
            if p.x < 20 || p.y < 20 || p.x > worldSize.width - 20 || p.y > worldSize.height - 20 { return false }
            for (c, r) in clearings where p.distance(to: c) < r + 40 { return false }
            if distanceToRoads(p) < 150 { return false }
            for o in obstacles where o.position.distance(to: p) < 46 { return false }
            return true
        }
        var sites: [CGPoint] = []
        for _ in 0..<34 {
            let c = CGPoint(x: CGFloat.random(in: 150...(worldSize.width - 150), using: &rng),
                            y: CGFloat.random(in: 150...(worldSize.height - 150), using: &rng))
            for _ in 0..<Int.random(in: 5...12, using: &rng) {
                let a = CGFloat.random(in: 0...(2 * .pi), using: &rng)
                sites.append(c + CGPoint(x: cos(a), y: sin(a)) * CGFloat.random(in: 0...120, using: &rng))
            }
        }
        var edge: CGFloat = 30
        while edge < max(worldSize.width, worldSize.height) {
            for p in [CGPoint(x: edge, y: CGFloat.random(in: 25...110, using: &rng)),
                      CGPoint(x: edge, y: worldSize.height - CGFloat.random(in: 25...110, using: &rng)),
                      CGPoint(x: CGFloat.random(in: 25...110, using: &rng), y: edge),
                      CGPoint(x: worldSize.width - CGFloat.random(in: 25...110, using: &rng), y: edge)] {
                sites.append(p)
            }
            edge += CGFloat.random(in: 45...75, using: &rng)
        }
        if let trees = netTrees {
            for (p, r, variant, angle, scale) in trees {
                obstacles.append(Obstacle(position: p, radius: r))
                addTree(at: p, variant: variant, angle: angle, scale: scale)
            }
            sites = []
        }
        for p in sites where treeAllowed(p) {
            obstacles.append(Obstacle(position: p, radius: 20))
            let s = CGFloat.random(in: 0.8...1.15, using: &rng)
            let shadow = SKSpriteNode(texture: Art.shadow)
            shadow.size = CGSize(width: 90 * s, height: 80 * s)
            shadow.position = p + CGPoint(x: 10, y: -12)
            shadow.zPosition = 3.5
            world.addChild(shadow)
            let tree = SKSpriteNode(texture: Art.tree(Int.random(in: 0...2, using: &rng)))
            tree.size = CGSize(width: 84 * s, height: 84 * s)
            tree.position = p
            tree.zRotation = CGFloat.random(in: 0...(2 * .pi), using: &rng)
            tree.zPosition = 4
            world.addChild(tree)
        }
        for (i, o) in obstacles.enumerated() {
            obstacleBuckets[bucketKey(o.position), default: []].append(i)
        }
    }

    private func addTree(at p: CGPoint, variant: Int, angle: CGFloat, scale s: CGFloat) {
        let shadow = SKSpriteNode(texture: Art.shadow)
        shadow.size = CGSize(width: 90 * s, height: 80 * s)
        shadow.position = p + CGPoint(x: 10, y: -12)
        shadow.zPosition = 3.5
        world.addChild(shadow)
        let tree = SKSpriteNode(texture: Art.tree(variant))
        tree.size = CGSize(width: 84 * s, height: 84 * s)
        tree.position = p
        tree.zRotation = angle
        tree.zPosition = 4
        world.addChild(tree)
    }

    func addWreck(at p: CGPoint, angle: CGFloat, team: Team) {
        let wreck = SKSpriteNode(texture: Art.unit(.tank, team))
        wreck.size = Art.unitSize(.tank)
        wreck.color = .black
        wreck.colorBlendFactor = 0.7
        wreck.zRotation = angle
        wreck.position = p
        decalLayer.addChild(wreck)
        wreck.run(.sequence([.wait(forDuration: 30), .fadeOut(withDuration: 4), .removeFromParent()]))
    }

    private func bucketKey(_ p: CGPoint) -> Int {
        Int(p.x / bucketSize) * 1000 + Int(p.y / bucketSize)
    }

    private func nearbyObstacles(_ p: CGPoint) -> [Obstacle] {
        let bx = Int(p.x / bucketSize), by = Int(p.y / bucketSize)
        var out: [Obstacle] = []
        for x in (bx - 1)...(bx + 1) {
            for y in (by - 1)...(by + 1) {
                for i in obstacleBuckets[x * 1000 + y] ?? [] { out.append(obstacles[i]) }
            }
        }
        return out
    }

    func addUnit(_ u: Unit) {
        units.append(u)
        entityLayer.addChild(u)
    }

    func addBuilding(_ b: Building) {
        buildings.append(b)
        entityLayer.addChild(b)
    }

    func addCrystal(_ c: Crystal) {
        crystals.append(c)
        entityLayer.addChild(c)
    }

    // MARK: - Main loop

    override func update(_ currentTime: TimeInterval) {
        let rawDt = lastTime == 0 ? 1.0 / 60 : currentTime - lastTime
        lastTime = currentTime
        let realDt = CGFloat(min(rawDt, 1.0 / 15))
        let mouse = currentMouse()

        updateCamera(realDt, mouse: mouse)
        updateGhost(mouse)
        updateHover(mouse)
        hud.update(realDt, mouse: mouse?.hud)
        updateOrderLines(realDt)
        if fog.render(dt: realDt) { hud.setFog(fog.texture) }
        if let net, net.isLocal, net.sentPause != gamePaused {
            net.sentPause = gamePaused
            net.conn.send(["t": "pause", "paused": gamePaused])
        }
        if let net, net.isLocal { GameServer.hosted?.timeScale = Double(Settings.gameSpeed) }
        if isNet {
            netUpdate(realDt)
            Debug.afterFrame(self)
            return
        }
        if gamePaused || gameOver { return }

        let dt = realDt * Settings.gameSpeed
        for _ in 0..<Debug.timeScale where !gameOver { step(dt) }
        Debug.afterFrame(self)
    }

    private func step(_ dt: CGFloat) {
        elapsed += dt
        for u in units where !u.dead { u.update(dt) }
        resolveCollisions()
        for b in buildings where !b.dead { b.update(dt) }
        updateShells(dt)
        ai.update(dt)
        autoPlayer?.update(dt)
        cleanupDead()
        fogTimer -= dt
        if fogTimer <= 0 {
            fogTimer = 0.1
            updateFog()
        }
        checkVictory()
    }

    private func resolveCollisions() {
        for u in units { u.blockedNormal = nil }
        let n = units.count
        if n > 1 {
            for i in 0..<(n - 1) {
                let a = units[i]
                for j in (i + 1)..<n {
                    let b = units[j]
                    let dx = b.position.x - a.position.x
                    let dy = b.position.y - a.position.y
                    let minD = a.radius + b.radius
                    if abs(dx) > minD || abs(dy) > minD { continue }
                    let d2 = dx * dx + dy * dy
                    if d2 >= minD * minD { continue }
                    if a.ghosting && b.ghosting { continue }
                    let d = sqrt(d2)
                    let nrm = d > 0.01 ? CGPoint(x: dx / d, y: dy / d) : CGPoint(x: 1, y: 0)
                    let overlap = minD - d
                    // Moving units shove idle ones aside more than the reverse.
                    var wa: CGFloat = 0.5
                    if a.wasMoving && !b.wasMoving { wa = 0.2 } else if b.wasMoving && !a.wasMoving { wa = 0.8 }
                    a.position -= nrm * (overlap * wa)
                    b.position += nrm * (overlap * (1 - wa))
                }
            }
        }

        for u in units {
            let r = u.radius
            for b in buildings {
                let br = b.rect
                if u.position.x < br.minX - r || u.position.x > br.maxX + r ||
                    u.position.y < br.minY - r || u.position.y > br.maxY + r { continue }
                let cx = clamp(u.position.x, br.minX, br.maxX)
                let cy = clamp(u.position.y, br.minY, br.maxY)
                let dx = u.position.x - cx, dy = u.position.y - cy
                let d2 = dx * dx + dy * dy
                if d2 >= r * r { continue }
                if d2 > 0.0001 {
                    let d = sqrt(d2)
                    let nrm = CGPoint(x: dx / d, y: dy / d)
                    u.position += nrm * (r - d)
                    u.blockedNormal = nrm
                } else {
                    let left = u.position.x - br.minX, right = br.maxX - u.position.x
                    let bottom = u.position.y - br.minY, top = br.maxY - u.position.y
                    let m = min(left, right, bottom, top)
                    if m == left { u.position.x = br.minX - r; u.blockedNormal = CGPoint(x: -1, y: 0) }
                    else if m == right { u.position.x = br.maxX + r; u.blockedNormal = CGPoint(x: 1, y: 0) }
                    else if m == bottom { u.position.y = br.minY - r; u.blockedNormal = CGPoint(x: 0, y: -1) }
                    else { u.position.y = br.maxY + r; u.blockedNormal = CGPoint(x: 0, y: 1) }
                }
            }
            func pushCircle(_ c: CGPoint, _ cr: CGFloat) {
                let minD = r + cr
                let dx = u.position.x - c.x, dy = u.position.y - c.y
                if abs(dx) > minD || abs(dy) > minD { return }
                let d = hypot(dx, dy)
                if d >= minD { return }
                let nrm = d > 0.01 ? CGPoint(x: dx / d, y: dy / d) : CGPoint(x: 0, y: -1)
                u.position += nrm * (minD - d)
                if u.blockedNormal == nil { u.blockedNormal = nrm }
            }
            for c in crystals { pushCircle(c.position, c.radius) }
            for o in nearbyObstacles(u.position) { pushCircle(o.position, o.radius) }
            u.position.x = clamp(u.position.x, r + 4, worldSize.width - r - 4)
            u.position.y = clamp(u.position.y, r + 4, worldSize.height - r - 4)
        }
    }

    private func cleanupDead() {
        if units.contains(where: { $0.dead }) {
            for u in units where u.dead {
                let seen = u.visibleToPlayer || u.team.isFriendly
                if seen {
                    explosion(at: u.position, size: u.kind == .tank ? 30 : u.radius * 1.3, scorch: u.kind == .tank)
                    if u.kind == .tank { addWreck(at: u.position, angle: u.body.zRotation, team: u.team) }
                }
                if case .build(let k, _) = u.order { refund(k.stats.cost, team: u.team) }
                u.refundBuilds(includeCurrent: false)
                unitsLost[u.team.rawValue] += 1
                u.removeFromParent()
            }
            units.removeAll { $0.dead }
            pruneSelection()
        }
        if buildings.contains(where: { $0.dead }) {
            for b in buildings where b.dead {
                explosion(at: b.position, size: b.half * 0.9)
                for i in 0..<5 {
                    let off = CGPoint(x: CGFloat.random(in: -b.half...b.half), y: CGFloat.random(in: -b.half...b.half))
                    explosion(at: b.position + off, size: b.half * 0.5, delay: Double(i) * 0.12 + 0.05, scorch: false)
                }
                decal(Art.rubble, at: b.position, size: b.half * 2.4, life: 60)
                b.removeFromParent()
                if b.team.isLocal {
                    hud.flash("\(b.stats.name) destroyed", color: Palette.bad)
                } else {
                    hud.flash("Enemy \(b.stats.name) destroyed", color: Palette.good)
                }
            }
            buildings.removeAll { $0.dead }
            pruneSelection()
        }
        if crystals.contains(where: { $0.dead }) {
            for c in crystals where c.dead {
                c.run(.sequence([.group([.fadeOut(withDuration: 0.5), .scale(to: 0.3, duration: 0.5)]), .removeFromParent()]))
            }
            crystals.removeAll { $0.dead }
        }
    }

    private func pruneSelection() {
        let before = selection.count
        selection.removeAll { $0.dead }
        for (k, v) in controlGroups { controlGroups[k] = v.filter { !$0.dead } }
        if selection.count != before { hud.selectionChanged() }
    }

    func updateFog() {
        var viewers: [(CGPoint, CGFloat)] = []
        for u in units where u.team.isFriendly { viewers.append((u.position, u.sight)) }
        for b in buildings where b.team.isFriendly { viewers.append((b.position, b.sight)) }
        fog.recompute(viewers: viewers)

        var lostSelection = false
        for u in units where !u.team.isFriendly {
            let v = isNet || fog.isVisible(u.position)
            u.visibleToPlayer = v
            u.isHidden = !v
            if !v && u.isSelected {
                u.isSelected = false
                lostSelection = true
            }
        }
        for b in buildings where !b.team.isFriendly {
            let v = isNet || fog.anyVisible(in: b.rect)
            b.visibleToPlayer = v
            if v { b.revealed = true }
            b.isHidden = !b.revealed
        }
        if lostSelection {
            selection.removeAll { !$0.isSelected }
            hud.selectionChanged()
        }
    }

    private func checkVictory() {
        guard !gameOver else { return }
        let playerAlive = buildings.contains { $0.team == .player }
        let enemyAlive = buildings.contains { $0.team == .enemy }
        if !enemyAlive { endGame(won: true) } else if !playerAlive { endGame(won: false) }
    }

    func endGame(won: Bool) {
        gameOver = true
        cancelModes()
        fog.revealAll = true
        for u in units { u.isHidden = false }
        for b in buildings { b.isHidden = false }
        playSound(won ? "Hero" : "Basso")
        hud.showEnd(won: won)
        Debug.gameEnded(self, won: won)
    }

    func restart() {
        if let net, let sk = net.skirmish {
            leaveNetGame()
            startSkirmish(view, size: size, difficulty: net.difficulty, mapId: sk.mapId, opponents: sk.opponents,
                          teams: sk.teams)
            return
        }
        if isNet {
            backToLobby()
            return
        }
        view?.presentScene(GameScene(size: size, difficulty: difficulty), transition: .fade(withDuration: 0.5))
    }

    func toMenu() {
        NSCursor.arrow.set()
        leaveNetGame()
        view?.presentScene(MenuScene(size: size), transition: .fade(withDuration: 0.5))
    }

    func togglePause() {
        if gameOver { return }
        if hud.overlayVisible {
            hud.clearOverlay()
            gamePaused = false
        } else {
            gamePaused = !isMultiplayer
            hud.showPause()
        }
    }

    func toggleHelp() {
        if gameOver { return }
        if hud.overlayVisible {
            hud.clearOverlay()
            gamePaused = false
        } else {
            gamePaused = !isMultiplayer
            hud.showHelp()
        }
    }

    // MARK: - Camera

    func currentMouse() -> (world: CGPoint, hud: CGPoint)? {
        guard let v = view, let win = v.window else { return nil }
        let vp = v.convert(win.mouseLocationOutsideOfEventStream, from: nil)
        guard v.bounds.contains(vp) else { return nil }
        let sp = convertPoint(fromView: vp)
        return (sp, convert(sp, to: cam))
    }

    private func updateCamera(_ dt: CGFloat, mouse: (world: CGPoint, hud: CGPoint)?) {
        cam.position -= shakeOffset
        var v = CGPoint.zero
        if keysDown.contains(123) { v.x -= 1 }
        if keysDown.contains(124) { v.x += 1 }
        if keysDown.contains(125) { v.y -= 1 }
        if keysDown.contains(126) { v.y += 1 }
        if Settings.edgeScroll, let m = mouse, view?.window?.isKeyWindow == true, !hud.overlayVisible, dragStart == nil {
            let e: CGFloat = 6
            if m.hud.x < -size.width / 2 + e { v.x -= 1 } else if m.hud.x > size.width / 2 - e { v.x += 1 }
            if m.hud.y < -size.height / 2 + e { v.y -= 1 } else if m.hud.y > size.height / 2 - e { v.y += 1 }
        }
        if v != .zero {
            cam.position += v.normalized * (1050 * cam.xScale * dt)
            clampCamera()
        }
        if shakeAmount > 0.3 {
            shakeOffset = CGPoint(x: CGFloat.random(in: -1...1), y: CGFloat.random(in: -1...1)) * shakeAmount
            shakeAmount *= pow(0.004, dt)
        } else {
            shakeAmount = 0
            shakeOffset = .zero
        }
        cam.position += shakeOffset
    }

    func shake(_ amount: CGFloat) {
        shakeAmount = min(14, max(shakeAmount, amount))
    }

    func clampCamera() {
        let s = cam.xScale
        let hw = size.width * s / 2, hh = size.height * s / 2
        let minX = hw - 80, maxX = worldSize.width - hw + 80
        let minY = hh - HUD.panelHeight * s - 40, maxY = worldSize.height - hh + HUD.topHeight * s + 40
        cam.position.x = minX > maxX ? worldSize.width / 2 : clamp(cam.position.x, minX, maxX)
        cam.position.y = minY > maxY ? worldSize.height / 2 : clamp(cam.position.y, minY, maxY)
    }

    func centerCamera(on p: CGPoint) {
        // Offset so the point sits in the middle of the area above the HUD panel.
        let offset = (HUD.panelHeight - HUD.topHeight) / 2 * cam.yScale
        cam.position = CGPoint(x: p.x, y: p.y - offset)
        clampCamera()
    }

    /// Zooms while keeping `anchor` (a world point, usually under the cursor) fixed on screen.
    func zoom(by f: CGFloat, anchor: CGPoint? = nil) {
        let old = cam.xScale
        let s = clamp(old * f, 0.55, 1.9)
        guard abs(s - old) > 0.0001 else { return }
        if let a = anchor { cam.position = a + (cam.position - a) * (s / old) }
        cam.setScale(s)
        clampCamera()
    }

    func visibleWorldRect() -> CGRect {
        let s = cam.xScale
        return CGRect(x: cam.position.x - size.width * s / 2, y: cam.position.y - size.height * s / 2,
                      width: size.width * s, height: size.height * s)
    }

    func jumpCamera() {
        if let p = lastAlertPos, elapsed - lastAlertTime < 12 {
            centerCamera(on: p)
            lastAlertPos = nil
        } else if !selection.isEmpty {
            let sum = selection.reduce(CGPoint.zero) { $0 + $1.position }
            centerCamera(on: sum * (1 / CGFloat(selection.count)))
        } else if let hq = buildings.first(where: { $0.team.isLocal && $0.kind == .hq }) {
            centerCamera(on: hq.position)
        }
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        let w = event.location(in: self)
        let h = event.location(in: cam)
        if hud.handleClick(h, right: false) { return }
        if gamePaused || gameOver { return }
        let shift = event.modifierFlags.contains(.shift)
        if let k = placing {
            tryPlace(k, at: snapped(w), keep: shift)
            return
        }
        if attackMovePending {
            attackMovePending = false
            issueAttackMove(at: w, queue: shift)
            return
        }
        dragStart = w
        selectionBox.path = nil
        selectionBox.isHidden = false
    }

    override func mouseDragged(with event: NSEvent) {
        if minimapDragging {
            hud.minimapDrag(event.location(in: cam))
            return
        }
        guard let s = dragStart else { return }
        let w = event.location(in: self)
        selectionBox.path = CGPath(rect: CGRect(x: min(s.x, w.x), y: min(s.y, w.y),
                                                width: abs(w.x - s.x), height: abs(w.y - s.y)), transform: nil)
    }

    override func mouseUp(with event: NSEvent) {
        if minimapDragging {
            minimapDragging = false
            return
        }
        guard let s = dragStart else { return }
        dragStart = nil
        selectionBox.isHidden = true
        let w = event.location(in: self)
        let shift = event.modifierFlags.contains(.shift)
        let r = CGRect(x: min(s.x, w.x), y: min(s.y, w.y), width: abs(w.x - s.x), height: abs(w.y - s.y))
        if r.width < 6 && r.height < 6 {
            clickSelect(at: w, shift: shift, doubleClick: event.clickCount >= 2)
        } else {
            boxSelect(r, shift: shift)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if gamePaused || gameOver { return }
        if placing != nil || attackMovePending {
            cancelModes()
            return
        }
        let h = event.location(in: cam)
        if hud.handleClick(h, right: true, queue: event.modifierFlags.contains(.shift)) { return }
        smartCommand(at: event.location(in: self), queue: event.modifierFlags.contains(.shift))
    }

    override func scrollWheel(with event: NSEvent) {
        if hud.overlayVisible { return }
        if event.hasPreciseScrollingDeltas {
            cam.position.x -= event.scrollingDeltaX * cam.xScale
            cam.position.y += event.scrollingDeltaY * cam.yScale
            clampCamera()
        } else if event.scrollingDeltaY != 0 {
            zoom(by: event.scrollingDeltaY > 0 ? 0.9 : 1.1, anchor: event.location(in: self))
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 - event.magnification, anchor: event.location(in: self))
    }

    override func keyDown(with event: NSEvent) {
        let code = event.keyCode
        if let text = hud.chatText {
            switch code {
            case 36, 76:
                let t = text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { net?.chat(t) }
                hud.chatText = nil
            case 53: hud.chatText = nil
            case 51: hud.chatText = String(text.dropLast())
            default:
                if let c = event.characters, !c.isEmpty, c.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 0xF700 }) {
                    hud.chatText = String((text + c).prefix(120))
                }
            }
            return
        }
        if isMultiplayer && !gameOver && !hud.overlayVisible && (code == 36 || code == 76) {
            hud.chatText = ""
            return
        }
        if [123, 124, 125, 126].contains(code) {
            keysDown.insert(code)
            return
        }
        if event.isARepeat { return }
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()

        if gameOver {
            if code == 36 || code == 76 { restart() } else if code == 53 { toMenu() }
            return
        }
        if code == 53 { // Esc
            if placing != nil || attackMovePending { cancelModes() }
            else if hud.overlayVisible { hud.clearOverlay(); gamePaused = false }
            else if !selection.isEmpty { setSelection([]) }
            else { togglePause() }
            return
        }
        if chars == "p" { togglePause(); return }
        if chars == "h" || chars == "?" || chars == "/" { toggleHelp(); return }
        if gamePaused { return }
        if code == 49 { jumpCamera(); return }
        if chars == "=" || chars == "+" { zoom(by: 0.9); return }
        if chars == "-" || chars == "_" { zoom(by: 1.1); return }
        if chars == "o" {
            Settings.objectives.toggle()
            hud.selectionChanged()
            return
        }
        if code == 120 || chars == "`" { selectArmy(); return } // F2 or backtick
        if chars.count == 1, let d = Int(chars) {
            let mods = event.modifierFlags
            if mods.contains(.control) || mods.contains(.command) {
                let own = selection.filter { $0.team.isLocal }
                controlGroups[d] = own
                hud.flash("Group \(d) assigned (\(own.count))", color: Palette.text)
            } else if let g = controlGroups[d], !g.isEmpty {
                setSelection(g)
                let now = event.timestamp
                if let last = lastGroupTap, last.group == d, now - last.time < 0.4 { jumpCamera() }
                lastGroupTap = (d, now)
            }
            return
        }
        if chars == "i" || chars == "." { selectIdleWorker(); return }
        for (i, b) in hud.currentButtons.enumerated() where b.hotkey.lowercased() == chars {
            hud.pressButton(i)
            return
        }
    }

    override func keyUp(with event: NSEvent) {
        keysDown.remove(event.keyCode)
    }

    // MARK: - Hover & cursor

    private func updateHover(_ mouse: (world: CGPoint, hud: CGPoint)?) {
        var target: Entity?
        var crystal: Crystal?
        var hoveredBridge: BridgeNode?
        let active = mouse != nil && !hud.overlayVisible && dragStart == nil && placing == nil
        if active, let m = mouse, !hud.isOverHUD(m.hud) {
            target = entity(at: m.world)
            if target == nil, fog.isExplored(m.world) { crystal = self.crystal(at: m.world) }
            if target == nil, crystal == nil { hoveredBridge = bridge(at: m.world) }
        }
        for b in bridgeNodes where b.hovered != (b === hoveredBridge) { b.hovered = (b === hoveredBridge) }
        if target !== hovered {
            hovered?.isHovered = false
            target?.isHovered = true
            hovered = target
        }
        if let m = mouse {
            if let t = target {
                var label = "\(t.displayName)  \(Int(ceil(t.hp)))/\(Int(t.maxHp))"
                if let b = t as? Building, isRepairable(b), selectedOwnUnits.contains(where: { $0.kind == .worker }) {
                    label += "    right-click to repair"
                }
                hud.setHover(label, color: t.team.isLocal ? Palette.text : (t.team.isFriendly ? t.team.lightColor : Palette.bad), at: m.hud)
            } else if let c = crystal {
                hud.setHover("Crystal  \(c.amount)", color: Palette.crystal, at: m.hud)
            } else if let br = hoveredBridge {
                if br.intact {
                    hud.setHover("Bridge  \(Int(ceil(br.hp)))/\(Int(bridgeHP))    A then click to demolish",
                                 color: Palette.amber, at: m.hud)
                } else {
                    hud.setHover("Bridge down    Engineer + right-click to rebuild (\(bridgeCost))",
                                 color: Palette.dim, at: m.hud)
                }
            } else {
                hud.setHover(nil, color: .clear, at: m.hud)
            }
        } else {
            hud.setHover(nil, color: .clear, at: .zero)
        }

        guard let m = mouse, view?.window?.isKeyWindow == true else { return }
        var kind = Art.CursorKind.normal
        if !hud.isOverHUD(m.hud) && !hud.overlayVisible {
            let own = selectedOwnUnits
            if attackMovePending {
                kind = .attack
            } else if !own.isEmpty && placing == nil {
                if let t = target, !t.team.isFriendly { kind = .attack }
                else if crystal != nil && own.contains(where: { $0.kind == .worker }) { kind = .gather }
                else if let b = target as? Building, isRepairable(b), own.contains(where: { $0.kind == .worker }) {
                    kind = .gather      // the work cursor: this Engineer can mend it
                }
                else if let br = hoveredBridge, !br.intact, own.contains(where: { $0.kind == .worker }) {
                    kind = .gather      // the build cursor: this Engineer can put the crossing back
                }
            }
        }
        Art.cursor(kind).set()
    }

    private func orderTarget(_ o: Order) -> (CGPoint, Int)? {
        switch o {
        case .idle: return nil
        case .move(let p): return (p, 0)
        case .attackMove(let p): return (p, 1)
        case .attack(let t): return t.dead ? nil : (t.position, 1)
        case .gather(let c): return c.dead ? nil : (c.position, 2)
        case .returnCargo: return nil
        case .build(_, let p): return (p, 3)
        }
    }

    private func updateOrderLines(_ dt: CGFloat) {
        dashPhase -= dt * 22
        let paths = (0..<4).map { _ in CGMutablePath() }
        var any = false
        for u in selectedOwnUnits.prefix(80) {
            var from = u.position
            let targets: [(CGPoint, Int)] = isNet
                ? u.netPoints.compactMap { code, p in [1: 0, 2: 1, 3: 1, 4: 2, 6: 3][code].map { (p, $0) } }
                : ([u.order] + u.queued).compactMap { orderTarget($0) }
            for (to, kind) in targets {
                paths[kind].move(to: from)
                paths[kind].addLine(to: to)
                from = to
                any = true
            }
        }
        var rally: CGPoint?
        for b in selectedOwnBuildings {
            guard let r = b.rally else { continue }
            paths[0].move(to: b.position)
            paths[0].addLine(to: r)
            rally = r
            any = true
        }
        rallyFlag.isHidden = rally == nil
        if let r = rally { rallyFlag.position = r }
        for (i, node) in orderLines.enumerated() {
            node.isHidden = !any
            if any { node.path = paths[i].copy(dashingWithPhase: dashPhase, lengths: [7, 6]) }
        }
    }

    // MARK: - Selection

    func setSelection(_ es: [Entity]) {
        for e in selection { e.isSelected = false }
        selection = es.filter { !$0.dead }
        for e in selection { e.isSelected = true }
        hud.selectionChanged()
    }

    private func clickSelect(at p: CGPoint, shift: Bool, doubleClick: Bool) {
        guard let e = entity(at: p) else {
            if !shift { setSelection([]) }
            return
        }
        if doubleClick && e.team.isLocal {
            let vr = visibleWorldRect()
            if let u = e as? Unit {
                setSelection(units.filter { $0.team.isLocal && $0.kind == u.kind && vr.contains($0.position) })
                return
            }
            if let b = e as? Building {
                setSelection(buildings.filter { $0.team.isLocal && $0.kind == b.kind && vr.contains($0.position) })
                return
            }
        }
        if shift && e.team.isLocal && selection.allSatisfy({ $0.team.isLocal }) {
            if selection.contains(where: { $0 === e }) {
                setSelection(selection.filter { $0 !== e })
            } else {
                setSelection(selection + [e])
            }
        } else {
            setSelection([e])
        }
    }

    private func boxSelect(_ r: CGRect, shift: Bool) {
        let us = units.filter { $0.team.isLocal && r.insetBy(dx: -$0.radius, dy: -$0.radius).contains($0.position) }
        if !us.isEmpty {
            if shift {
                let extra = us.filter { u in !selection.contains { $0 === u } }
                setSelection(selection.filter { $0.team.isLocal } + extra)
            } else {
                setSelection(us)
            }
            return
        }
        let bs = buildings.filter { $0.team.isLocal && r.intersects($0.rect) }
        if let f = bs.first {
            setSelection(bs.filter { $0.kind == f.kind })
        } else if !shift {
            setSelection([])
        }
    }

    var idleWorkers: [Unit] { units.filter { $0.team.isLocal && $0.isIdleWorker } }
    var army: [Unit] { units.filter { $0.team.isLocal && $0.kind != .worker } }

    func selectIdleWorker() {
        let idle = idleWorkers
        guard !idle.isEmpty else {
            hud.flash("No idle engineers", color: Palette.dim)
            return
        }
        idleCycle = (idleCycle + 1) % idle.count
        let w = idle[idleCycle]
        setSelection([w])
        centerCamera(on: w.position)
    }

    func selectArmy() {
        let a = army
        guard !a.isEmpty else {
            hud.flash("You have no combat units yet", color: Palette.dim)
            return
        }
        setSelection(a)
    }

    var selectedOwnUnits: [Unit] {
        selection.compactMap { $0 as? Unit }.filter { $0.team.isLocal && !$0.dead }
    }

    var selectedOwnBuildings: [Building] {
        selection.compactMap { $0 as? Building }.filter { $0.team.isLocal && !$0.dead }
    }

    func entity(at p: CGPoint) -> Entity? {
        var best: Entity?
        var bestD = CGFloat.infinity
        for u in units where !u.dead && (u.team.isFriendly || u.visibleToPlayer) {
            let d = u.position.distance(to: p)
            if d < u.radius + 6 && d < bestD {
                best = u
                bestD = d
            }
        }
        if best != nil { return best }
        return buildings.first { !$0.dead && ($0.team.isFriendly || $0.revealed) && $0.rect.insetBy(dx: -2, dy: -2).contains(p) }
    }

    func crystal(at p: CGPoint) -> Crystal? {
        crystals.first { !$0.dead && $0.position.distance(to: p) < $0.radius + 10 }
    }

    // MARK: - Commands

    private func give(_ u: Unit, _ o: Order, queue: Bool) {
        if queue { u.enqueue(o) } else { u.command(o) }
    }

    func isRepairable(_ b: Building) -> Bool {
        !b.dead && b.built && b.hp < b.maxHp && b.team.isFriendly
    }

    func bridge(at p: CGPoint) -> BridgeNode? {
        bridgeNodes.first { $0.contains(world: p) }
    }

    func smartCommand(at p: CGPoint, queue: Bool = false) {
        if isNet {
            netSmartCommand(at: p, queue: queue)
            return
        }
        let us = selectedOwnUnits
        if !us.isEmpty {
            if let t = entity(at: p), !t.team.isFriendly {
                for u in us { give(u, .attack(t), queue: queue) }
                marker(at: t.position, color: Palette.bad, size: 26)
                return
            }
            if let c = crystal(at: p) {
                let workers = us.filter { $0.kind == .worker }
                for w in workers {
                    w.homeCrystal = c
                    give(w, .gather(c), queue: queue)
                }
                let others = us.filter { $0.kind != .worker }
                if !others.isEmpty { moveGroup(others, to: p, attack: false, queue: queue) }
                marker(at: c.position, color: Palette.crystal, size: 26)
                return
            }
            if let b = entity(at: p) as? Building, b.team.isLocal, b.kind == .hq, b.built {
                let carriers = us.filter { $0.kind == .worker && $0.carrying > 0 }
                for w in carriers { give(w, .returnCargo, queue: queue) }
                let rest = us.filter { !($0.kind == .worker && $0.carrying > 0) }
                if !rest.isEmpty { moveGroup(rest, to: p, attack: false, queue: queue) }
                return
            }
            moveGroup(us, to: p, attack: false, queue: queue)
            marker(at: p, color: Palette.good, size: 18)
            return
        }
        let producers = selectedOwnBuildings.filter { !$0.stats.produces.isEmpty }
        if !producers.isEmpty {
            for b in producers { b.rally = p }
            marker(at: p, color: Palette.good, size: 18)
        }
    }

    func moveGroup(_ us: [Unit], to p: CGPoint, attack: Bool, queue: Bool = false) {
        if us.count == 1 {
            give(us[0], attack ? .attackMove(p) : .move(p), queue: queue)
            return
        }
        let cols = Int(ceil(sqrt(Double(us.count))))
        let rows = (us.count + cols - 1) / cols
        let spacing = (us.map { $0.radius }.max() ?? 10) * 2 + 8
        // Keep units roughly in their current relative layout: sort into rows by y, then by x.
        let byY = us.sorted { $0.position.y > $1.position.y }
        var ordered: [Unit] = []
        var i = 0
        while i < byY.count {
            ordered += byY[i..<min(i + cols, byY.count)].sorted { $0.position.x < $1.position.x }
            i += cols
        }
        for (idx, u) in ordered.enumerated() {
            let r = idx / cols, c = idx % cols
            let off = CGPoint(x: (CGFloat(c) - CGFloat(cols - 1) / 2) * spacing,
                              y: (CGFloat(rows - 1) / 2 - CGFloat(r)) * spacing)
            var t = p + off
            t.x = clamp(t.x, 20, worldSize.width - 20)
            t.y = clamp(t.y, 20, worldSize.height - 20)
            give(u, attack ? .attackMove(t) : .move(t), queue: queue)
        }
    }

    func issueAttackMove(at p: CGPoint, queue: Bool = false) {
        let us = selectedOwnUnits
        guard !us.isEmpty else { return }
        if let br = bridge(at: p), br.intact {
            let armed = us.filter { $0.kind != .worker }
            if !armed.isEmpty {
                sendNet(["attack", netIds(armed), br.bridgeId, queue])
                marker(at: br.position, color: Palette.bad, size: 34)
                hud.flash("Demolishing the bridge", color: Palette.bad)
                return
            }
        }
        if isNet {
            if let t = entity(at: p), !t.team.isFriendly {
                sendNet(["attack", netIds(us), t.netId, queue])
                marker(at: t.position, color: Palette.bad, size: 26)
            } else {
                sendNet(["move", netIds(us), p.x, p.y, queue, true])
                marker(at: p, color: Palette.bad, size: 18)
            }
            return
        }
        if let t = entity(at: p), !t.team.isFriendly {
            for u in us { give(u, .attack(t), queue: queue) }
            marker(at: t.position, color: Palette.bad, size: 26)
            return
        }
        moveGroup(us, to: p, attack: true, queue: queue)
        marker(at: p, color: Palette.bad, size: 18)
    }

    func stopSelected() {
        if isNet {
            sendNet(["stop", netIds(selectedOwnUnits)])
            return
        }
        for u in selectedOwnUnits { u.command(.idle) }
    }

    func cancelModes() {
        placing = nil
        attackMovePending = false
        ghost.isHidden = true
        ghostFrame.isHidden = true
        ghostRange.isHidden = true
    }

    // MARK: - Construction

    func hasBuilt(_ k: BuildingKind, team: Team) -> Bool {
        buildings.contains { $0.team == team && $0.kind == k && $0.built }
    }

    func beginPlacement(_ k: BuildingKind) {
        if let req = k.stats.requires, !hasBuilt(req, team: Team.local) {
            hud.flash("Requires \(req.stats.name)", color: Palette.bad)
            return
        }
        if myResources < CGFloat(k.stats.cost) {
            hud.flash("Not enough crystal", color: Palette.bad)
            return
        }
        attackMovePending = false
        placing = k
        ghost.texture = Art.building(k, Team.local)
        ghost.size = Art.buildingCanvas(k)
        let h = k.stats.half
        ghostFrame.path = k == .turret
            ? CGPath(ellipseIn: CGRect(x: -h, y: -h, width: h * 2, height: h * 2), transform: nil)
            : CGPath(roundedRect: CGRect(x: -h, y: -h, width: h * 2, height: h * 2), cornerWidth: 8, cornerHeight: 8, transform: nil)
        if k == .turret {
            let r = k.stats.range
            ghostRange.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        }
        hud.flash("Place \(k.stats.name): click to build · Shift to place several · right-click to cancel", color: Palette.text)
    }

    func snapped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x / 16).rounded() * 16, y: (p.y / 16).rounded() * 16)
    }

    private func updateGhost(_ mouse: (world: CGPoint, hud: CGPoint)?) {
        guard let k = placing else { return }
        guard let m = mouse, !hud.isOverHUD(m.hud) else {
            ghost.isHidden = true
            ghostFrame.isHidden = true
            ghostRange.isHidden = true
            return
        }
        let p = snapped(m.world)
        let ok = canPlace(k, at: p) && fog.isExplored(p)
        let c = ok ? Palette.good : Palette.bad
        ghost.isHidden = false
        ghostFrame.isHidden = false
        ghost.position = p
        ghostFrame.position = p
        ghost.color = c
        ghostFrame.strokeColor = c
        ghostFrame.fillColor = c.withAlphaComponent(0.12)
        ghostRange.position = p
        ghostRange.isHidden = k != .turret
    }

    func canPlace(_ k: BuildingKind, at p: CGPoint, margin: CGFloat = 4, ignoring: Unit? = nil) -> Bool {
        let r = squareRect(center: p, half: k.stats.half)
        if r.minX < 30 || r.minY < 30 || r.maxX > worldSize.width - 30 || r.maxY > worldSize.height - 30 { return false }
        let rm = r.insetBy(dx: -margin, dy: -margin)
        for b in buildings where !b.dead && b.rect.intersects(rm) { return false }
        for c in crystals where !c.dead && rectDistance(rm, c.position) < c.radius + 20 { return false }
        for w in walls where w.intersects(rm) { return false }
        for o in obstacles where rectDistance(rm, o.position) < o.radius { return false }
        for u in units where u !== ignoring {
            for o in [u.order] + u.queued {
                if case .build(let bk, let bp) = o, squareRect(center: bp, half: bk.stats.half).intersects(rm) { return false }
            }
        }
        return true
    }

    func tryPlace(_ k: BuildingKind, at p: CGPoint, keep: Bool) {
        guard fog.isExplored(p) else {
            hud.flash("Can't build in unexplored territory", color: Palette.bad)
            return
        }
        guard canPlace(k, at: p) else {
            hud.flash("Can't build there", color: Palette.bad)
            return
        }
        guard myResources >= CGFloat(k.stats.cost) else {
            hud.flash("Not enough crystal", color: Palette.bad)
            cancelModes()
            return
        }
        let workers = selectedOwnUnits.filter { $0.kind == .worker }
        var builder = workers.min(by: { $0.position.distance(to: p) < $1.position.distance(to: p) })
        if keep, let last = lastBuilder, !last.dead, workers.contains(where: { $0 === last }) { builder = last }
        guard let w = builder else {
            cancelModes()
            return
        }
        if isNet {
            sendNet(["build", w.netId, NetProtocol.name(k), p.x, p.y, keep])
            lastBuilder = w
            marker(at: p, color: Palette.amber, size: k.stats.half)
            if !keep || myResources - CGFloat(k.stats.cost) < CGFloat(k.stats.cost) { cancelModes() }
            return
        }
        resources[0] -= CGFloat(k.stats.cost)
        w.orderBuild(k, at: p, queue: keep)
        lastBuilder = w
        marker(at: p, color: Palette.amber, size: k.stats.half)
        if !keep || resources[0] < CGFloat(k.stats.cost) { cancelModes() }
    }

    @discardableResult
    func startBuilding(_ k: BuildingKind, at p: CGPoint, team: Team) -> Building {
        let b = Building(kind: k, team: team, at: p, built: false, game: self)
        addBuilding(b)
        if team.isFriendly || fog.isVisible(p) { emit(FX.smokeBurst(size: k.stats.half * 0.6), at: p, life: 3) }
        return b
    }

    func buildingCompleted(_ b: Building) {
        if b.team.isLocal {
            hud.flash("\(b.stats.name) complete", color: Palette.good)
            playSound("Glass")
            if b.isSelected { hud.selectionChanged() }
        }
    }

    func refund(_ amount: Int, team: Team) {
        resources[team.rawValue] += CGFloat(amount)
    }

    // MARK: - Production & economy

    func supplyUsed(_ team: Team) -> Int {
        units.filter { $0.team == team }.reduce(0) { $0 + $1.stats.supply } +
            buildings.filter { $0.team == team }.reduce(0) { $0 + $1.queue.reduce(0) { $0 + $1.stats.supply } }
    }

    func supplyCap(_ team: Team) -> Int {
        min(200, buildings.filter { $0.team == team && $0.built }.reduce(0) { $0 + $1.stats.supply })
    }

    @discardableResult
    func train(_ k: UnitKind, from bs: [Building], team: Team = Team.local) -> Bool {
        if isNet {
            sendNet(["train", netIds(bs.filter { $0.team.isLocal }), NetProtocol.name(k)])
            return true
        }
        let candidates = bs.filter { $0.built && !$0.dead && $0.stats.produces.contains(k) && $0.queue.count < 5 }
        guard let b = candidates.min(by: { $0.queue.count < $1.queue.count }) else {
            if team.isLocal { hud.flash("Production queue full", color: Palette.bad) }
            return false
        }
        guard resources[team.rawValue] >= CGFloat(k.stats.cost) else {
            if team.isLocal { hud.flash("Not enough crystal", color: Palette.bad) }
            return false
        }
        guard supplyUsed(team) + k.stats.supply <= supplyCap(team) else {
            if team.isLocal { hud.flash("Not enough supply — build a Supply Depot (E)", color: Palette.bad) }
            return false
        }
        resources[team.rawValue] -= CGFloat(k.stats.cost)
        b.queue.append(k)
        if team.isLocal { hud.selectionChanged() }
        return true
    }

    func cancelUpgrade(_ b: Building) { sendNet(["cancelup", b.netId]) }

    func cancelQueue(_ b: Building, index: Int) {
        guard index < b.queue.count else { return }
        if isNet {
            sendNet(["cancel", b.netId, index])
            return
        }
        let k = b.queue.remove(at: index)
        if index == 0 { b.queueProgress = 0 }
        refund(k.stats.cost, team: b.team)
        hud.selectionChanged()
    }

    func spawnUnit(_ k: UnitKind, from b: Building) {
        let target = b.rally ?? CGPoint(x: b.position.x, y: b.position.y - 1)
        var dir = (target - b.position).normalized
        if dir == .zero { dir = CGPoint(x: 0, y: -1) }
        let u = Unit(kind: k, team: b.team, at: b.position + dir * (b.half + k.stats.radius + 4), game: self)
        u.body.zRotation = dir.angle
        u.gun?.zRotation = dir.angle
        addUnit(u)
        unitsTrained[b.team.rawValue] += 1
        if b.team.isLocal { trainedKinds[k, default: 0] += 1 }
        if let r = b.rally {
            if k == .worker, let c = crystal(at: r) { u.order = .gather(c) } else { u.order = .move(r) }
        } else if k == .worker, let c = nearestCrystal(to: b.position, within: 700) {
            u.order = .gather(c)
        }
        if b.team.isLocal && b.isSelected { hud.selectionChanged() }
    }

    func deposit(_ amount: Int, team: Team, at p: CGPoint) {
        let mult = team == .enemy ? difficulty.incomeMultiplier : 1
        resources[team.rawValue] += CGFloat(amount) * mult
        crystalsMined[team.rawValue] += amount
        if team.isLocal && visibleWorldRect().contains(p) { floatText("+\(amount)", at: p + CGPoint(x: 0, y: 14), color: Palette.crystal) }
    }

    func floatText(_ s: String, at p: CGPoint, color: NSColor) {
        let l = makeLabel(s, size: 12, color: color, font: Fonts.bold, align: .center, valign: .center)
        l.position = p
        l.zPosition = 5
        effectLayer.addChild(l)
        l.run(.sequence([.group([.moveBy(x: 0, y: 22, duration: 0.9), .sequence([.wait(forDuration: 0.5), .fadeOut(withDuration: 0.4)])]),
                         .removeFromParent()]))
    }

    func nearestCrystal(to p: CGPoint, within r: CGFloat) -> Crystal? {
        var best: Crystal?
        var bestD = r
        for c in crystals where !c.dead {
            let d = c.position.distance(to: p)
            if d < bestD {
                bestD = d
                best = c
            }
        }
        return best
    }

    func nearestDropoff(for team: Team, from p: CGPoint) -> Building? {
        buildings.filter { $0.team == team && $0.kind == .hq && $0.built && !$0.dead }
            .min { $0.position.distance(to: p) < $1.position.distance(to: p) }
    }

    func findTarget(for e: Entity, radius: CGFloat) -> Entity? {
        var best: Entity?
        var bestScore = CGFloat.infinity
        for u in units where u.team.isHostile(to: e.team) && !u.dead {
            if abs(u.position.x - e.position.x) > radius + 40 || abs(u.position.y - e.position.y) > radius + 40 { continue }
            let d = e.distanceTo(u)
            if d > radius || !u.isTargetable(by: e.team) { continue }
            let score = d + (u.kind == .worker ? 60 : 0)
            if score < bestScore {
                bestScore = score
                best = u
            }
        }
        for b in buildings where b.team.isHostile(to: e.team) && !b.dead {
            let d = e.distanceTo(b)
            if d > radius || !b.isTargetable(by: e.team) { continue }
            let score = d + (b.kind == .turret ? 30 : 200)
            if score < bestScore {
                bestScore = score
                best = b
            }
        }
        return best
    }

    func primaryTarget(for team: Team, from p: CGPoint) -> Entity? {
        if let b = buildings.filter({ $0.team.isHostile(to: team) && !$0.dead }).min(by: { $0.position.distance(to: p) < $1.position.distance(to: p) }) {
            return b
        }
        return units.filter { $0.team.isHostile(to: team) && !$0.dead }.min { $0.position.distance(to: p) < $1.position.distance(to: p) }
    }

    func alertAttack(at p: CGPoint) {
        guard elapsed - lastAlertTime > 12 else { return }
        if visibleWorldRect().insetBy(dx: 100, dy: 100).contains(p) { return }
        lastAlertTime = elapsed
        lastAlertPos = p
        hud.flash("⚠ Your forces are under attack!  (Space to view)", color: Palette.bad)
        hud.ping(at: p)
        alertRing(at: p)
        playSound("Submarine")
    }

    func enemyWaveLaunched() {
        hud.flash("Intel: an enemy attack wave is inbound!", color: Palette.amber)
        playSound("Funk")
    }

    // MARK: - HUD command card

    func commandButtons() -> [CommandButton] {
        let us = selectedOwnUnits
        if !us.isEmpty {
            var list: [CommandButton] = [
                CommandButton(icon: .attack, title: "Attack", hotkey: "A", cost: nil, enabled: true,
                              tip: "Attack-move: units engage any enemy they meet on the way. Shift+click to queue.") { [weak self] in
                    guard let self else { return }
                    self.cancelModes()
                    self.attackMovePending = true
                    self.hud.flash("Attack: click a location or target", color: Palette.text)
                },
                CommandButton(icon: .stop, title: "Stop", hotkey: "S", cost: nil, enabled: true,
                              tip: "Halt all current and queued orders.") { [weak self] in self?.stopSelected() },
            ]
            let tanks = us.filter { $0.canSiege }
            if !tanks.isEmpty {
                // One button for the whole selection: it digs in unless every tank is already dug in.
                let on = !tanks.allSatisfy { $0.sieged }
                let tip = on ? "Dig in: cannot move, but fires further (340) and harder, with a blind spot inside 90.\n"
                               + "Takes 2.5 seconds either way. A move order packs the tank up again."
                             : "Pack up and become mobile again. Takes 2.5 seconds."
                list.append(CommandButton(icon: .siege(on), title: on ? "Siege" : "Unsiege", hotkey: "G", cost: nil,
                                          enabled: true, tip: tip) { [weak self] in
                    guard let self else { return }
                    let ids = self.selectedOwnUnits.filter { $0.canSiege }.map { $0.netId }
                    if !ids.isEmpty { self.sendNet(["siege", ids, on]) }
                })
            }
            if us.contains(where: { $0.kind == .worker }) {
                for k in [BuildingKind.hq, .depot, .barracks, .factory, .turret, .radar] {
                    let s = k.stats
                    let reqOK = s.requires.map { hasBuilt($0, team: Team.local) } ?? true
                    let tip = s.desc + (reqOK ? "" : "\nRequires \(s.requires!.stats.name).")
                    list.append(CommandButton(icon: .building(k), title: s.short, hotkey: s.hotkey, cost: s.cost, enabled: reqOK, tip: tip) { [weak self] in
                        self?.beginPlacement(k)
                    })
                }
            }
            return list
        }
        let bs = selectedOwnBuildings.filter { $0.built }
        if let first = bs.first, bs.allSatisfy({ $0.kind == first.kind }) {
            var list: [CommandButton] = first.stats.produces.map { k in
                let s = k.stats
                let reqOK = s.requires.map { hasBuilt($0, team: Team.local) } ?? true
                var tip = "\(s.desc)\nSupply \(s.supply) · \(Int(s.buildTime))s build time.\nRight-click the map to set a rally point."
                if !reqOK { tip += "\nRequires \(s.requires!.stats.name)." }
                return CommandButton(icon: .unit(k), title: s.name, hotkey: s.hotkey, cost: s.cost, enabled: reqOK,
                                     tip: tip) { [weak self] in
                    guard let self else { return }
                    self.train(k, from: self.selectedOwnBuildings)
                }
            }
            for k in UpgradeKind.allCases where k.applies(to: first.kind) {
                let u = k.stats
                let installed = bs.allSatisfy { $0.upgrades.contains(k) }
                let busy = bs.contains { $0.upgrading != nil } && !installed
                let ok = !installed && bs.contains { $0.canUpgrade(k) }
                var tip = "\(u.desc)\n\(Int(u.time))s to research; this building only."
                if installed { tip += "\nAlready installed." } else if busy { tip += "\nAlready researching something." }
                list.append(CommandButton(icon: .upgrade(k), title: u.name, hotkey: u.hotkey,
                                          cost: installed ? nil : k.cost(for: first.kind), enabled: ok, tip: tip) { [weak self] in
                    guard let self else { return }
                    let ids = self.selectedOwnBuildings.filter { $0.canUpgrade(k) }.map { $0.netId }
                    if !ids.isEmpty { self.sendNet(["upgrade", ids, k.wireName]) }
                })
            }
            return list
        }
        return []
    }

    // MARK: - Shells

    private struct Shell {
        let node: SKNode
        let trail: SKEmitterNode
        let from: CGPoint
        let to: CGPoint
        let duration: CGFloat
        var t: CGFloat
        let damage: CGFloat
        let splash: CGFloat
        let team: Team
        weak var attacker: Entity?
    }
    private var shells: [Shell] = []

    func launchShell(from a: CGPoint, to b: CGPoint, damage: CGFloat, splash: CGFloat, team: Team, attacker: Entity) {
        let node = SKSpriteNode(texture: Art.glow)
        node.size = CGSize(width: 14, height: 14)
        node.color = .rgb(1, 0.85, 0.45)
        node.colorBlendFactor = 1
        node.blendMode = .add
        node.position = a
        effectLayer.addChild(node)
        let trail = FX.trail()
        trail.targetNode = effectLayer
        node.addChild(trail)
        shells.append(Shell(node: node, trail: trail, from: a, to: b, duration: max(0.05, a.distance(to: b) / 650), t: 0,
                            damage: damage, splash: splash, team: team, attacker: attacker))
    }

    private func updateShells(_ dt: CGFloat) {
        guard !shells.isEmpty else { return }
        var landed: [Shell] = []
        for i in shells.indices {
            shells[i].t += dt
            let s = shells[i]
            let f = min(1, s.t / s.duration)
            // Slight arc for a lobbed look
            let arc = sin(f * .pi) * min(40, s.from.distance(to: s.to) * 0.12)
            s.node.position = s.from + (s.to - s.from) * f + CGPoint(x: 0, y: arc)
            s.node.setScale(1 + sin(f * .pi) * 0.4)
            if f >= 1 { landed.append(s) }
        }
        shells.removeAll { $0.t >= $0.duration }
        for s in landed {
            s.node.removeFromParent()
            if s.team.isFriendly || fog.isVisible(s.to) { explosion(at: s.to, size: s.splash * 0.55) }
            splashDamage(at: s.to, radius: s.splash, damage: s.damage, team: s.team, attacker: s.attacker)
        }
    }

    private func splashDamage(at p: CGPoint, radius: CGFloat, damage: CGFloat, team: Team, attacker: Entity?) {
        guard !gameOver else { return }
        for u in units where u.team.isHostile(to: team) && !u.dead {
            let d = u.position.distance(to: p) - u.radius
            if d <= radius { u.takeDamage(damage * (1 - 0.5 * max(0, d) / radius), from: attacker) }
        }
        for b in buildings where b.team.isHostile(to: team) && !b.dead && rectDistance(b.rect, p) <= radius * 0.5 {
            b.takeDamage(damage, from: attacker)
        }
    }
}
