import SpriteKit

enum Order {
    case idle
    case move(CGPoint)
    case attackMove(CGPoint)
    case attack(Entity)
    case gather(Crystal)
    case returnCargo
    case build(BuildingKind, CGPoint)

    var isIdle: Bool { if case .idle = self { return true }; return false }
    var isMove: Bool { if case .move = self { return true }; return false }
}

// MARK: - Crystal

final class Crystal: SKNode {
    var amount: Int
    let maxAmount: Int
    let radius: CGFloat = 18
    var dead = false
    var netId = 0
    private let sprite: SKSpriteNode
    private let glowNode = SKSpriteNode(texture: Art.glow)

    init(at p: CGPoint, amount: Int, variant: Int) {
        self.amount = amount
        self.maxAmount = amount
        sprite = SKSpriteNode(texture: Art.crystal(variant % 3))
        super.init()
        position = p
        zPosition = 1

        let shadow = SKSpriteNode(texture: Art.shadow)
        shadow.size = CGSize(width: 50, height: 30)
        shadow.position = CGPoint(x: 5, y: -10)
        shadow.zPosition = -1
        addChild(shadow)

        glowNode.size = CGSize(width: 90, height: 90)
        glowNode.color = Palette.crystal
        glowNode.colorBlendFactor = 1
        glowNode.blendMode = .add
        glowNode.alpha = 0.25
        glowNode.zPosition = -0.5
        addChild(glowNode)
        let t = Double.random(in: 1.6...2.4)
        glowNode.run(.repeatForever(.sequence([.fadeAlpha(to: 0.38, duration: t), .fadeAlpha(to: 0.18, duration: t)])))

        sprite.size = CGSize(width: 54, height: 60)
        sprite.position = CGPoint(x: 0, y: 6)
        sprite.xScale = Bool.random() ? 1 : -1
        addChild(sprite)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setAmount(_ a: Int) {
        guard a != amount else { return }
        amount = a
        let s = 0.55 + 0.45 * CGFloat(amount) / CGFloat(maxAmount)
        sprite.yScale = s
        sprite.xScale = sprite.xScale < 0 ? -s : s
    }

    func extract(_ n: Int) -> Int {
        let a = min(n, amount)
        amount -= a
        let s = 0.55 + 0.45 * CGFloat(amount) / CGFloat(maxAmount)
        sprite.yScale = s
        sprite.xScale = sprite.xScale < 0 ? -s : s
        if amount <= 0 { dead = true }
        return a
    }
}

// MARK: - Entity base

class Entity: SKNode {
    let team: Team
    var hp: CGFloat
    let maxHp: CGFloat
    var dead = false
    var netId = 0
    var sight: CGFloat
    var visibleToPlayer = true
    var revealed = false
    unowned let game: GameScene
    let selectionMarker: SKSpriteNode
    let hpBack: SKSpriteNode
    let hpFill: SKSpriteNode
    let hpBarWidth: CGFloat

    var isSelected = false { didSet { refreshMarker() } }
    var isHovered = false { didSet { refreshMarker() } }

    var bodyRadius: CGFloat { 0 }
    var displayName: String { "" }
    var glyph: String { "" }
    var portrait: SKTexture { SKTexture() }

    init(team: Team, maxHp: CGFloat, sight: CGFloat, game: GameScene, markerTexture: SKTexture, markerSize: CGSize,
         barWidth: CGFloat, barY: CGFloat) {
        self.team = team
        self.maxHp = maxHp
        self.hp = maxHp
        self.sight = sight
        self.game = game
        self.hpBarWidth = barWidth
        selectionMarker = SKSpriteNode(texture: markerTexture)
        hpBack = SKSpriteNode(color: NSColor(white: 0, alpha: 0.75), size: CGSize(width: barWidth + 2, height: 5))
        hpFill = SKSpriteNode(color: Palette.good, size: CGSize(width: barWidth, height: 3))
        super.init()

        selectionMarker.size = markerSize
        selectionMarker.colorBlendFactor = 1
        selectionMarker.zPosition = -1
        selectionMarker.isHidden = true
        addChild(selectionMarker)

        hpBack.position = CGPoint(x: 0, y: barY)
        hpBack.zPosition = 20
        hpFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        hpFill.position = CGPoint(x: -barWidth / 2, y: barY)
        hpFill.zPosition = 21
        addChild(hpBack)
        addChild(hpFill)
        updateHPBar()
    }

    required init?(coder: NSCoder) { fatalError() }

    func addShadow(size: CGSize, offset: CGPoint = CGPoint(x: 5, y: -6)) {
        let s = SKSpriteNode(texture: Art.shadow)
        s.size = size
        s.position = offset
        s.zPosition = -2
        addChild(s)
    }

    private func refreshMarker() {
        let own = team.isLocal
        if isSelected {
            selectionMarker.isHidden = false
            selectionMarker.color = own ? Palette.good : Palette.bad
            selectionMarker.alpha = 1
        } else if isHovered {
            selectionMarker.isHidden = false
            selectionMarker.color = own ? .white : Palette.bad
            selectionMarker.alpha = 0.55
        } else {
            selectionMarker.isHidden = true
        }
        updateHPBar()
    }

    /// Distance from a point to this entity's outer surface.
    func surfaceDistance(from p: CGPoint) -> CGFloat { p.distance(to: position) }

    /// Gap between this entity's surface and another's.
    func distanceTo(_ other: Entity) -> CGFloat { other.surfaceDistance(from: position) - bodyRadius }

    func isTargetable(by t: Team) -> Bool {
        if game.isComputer(t) || !team.isHostile(to: t) { return true }
        return visibleToPlayer || (self is Building && revealed)
    }

    func takeDamage(_ amount: CGFloat, from attacker: Entity?) {
        guard !dead else { return }
        hp -= amount
        if hp <= 0 {
            hp = 0
            dead = true
        }
        updateHPBar()
        if team.isLocal { game.alertAttack(at: position) }
        onDamaged(by: attacker)
    }

    func onDamaged(by attacker: Entity?) {}

    func updateHPBar() {
        let frac = max(0, min(1, hp / maxHp))
        let show = isSelected || isHovered || frac < 0.999
        hpBack.isHidden = !show
        hpFill.isHidden = !show
        hpFill.size = CGSize(width: hpBarWidth * frac, height: 3)
        hpFill.color = frac > 0.6 ? Palette.good : (frac > 0.3 ? Palette.amber : Palette.bad)
    }
}

// MARK: - Unit

final class Unit: Entity {
    let kind: UnitKind
    let stats: UnitStats
    var order: Order = .idle
    var queued: [Order] = []
    var resumePoint: CGPoint?
    var cooldown: CGFloat = 0
    var carrying = 0
    var homeCrystal: Crystal?
    var resumeGather: Crystal?
    var mineTimer: CGFloat = 0
    var buildTimer: CGFloat = 0
    var stuckTimer: CGFloat = 0
    var lastPos = CGPoint.zero
    var wasMoving = false
    var scanTimer = CGFloat.random(in: 0...0.3)
    var blockedNormal: CGPoint?
    var slideSign: CGFloat = 0
    let body = SKNode()
    let bodySprite: SKSpriteNode
    var gun: SKSpriteNode?
    var cargoNode: SKNode?

    var radius: CGFloat { stats.radius }
    override var bodyRadius: CGFloat { stats.radius }
    override var displayName: String { stats.name }
    override var glyph: String { stats.glyph }
    override var portrait: SKTexture { Art.unit(kind, team) }

    /// Gathering workers pass through each other so they don't clog mineral lines.
    var ghosting: Bool {
        guard kind == .worker else { return false }
        switch order {
        case .gather, .returnCargo: return true
        default: return false
        }
    }

    var isIdleWorker: Bool {
        guard kind == .worker else { return false }
        return game.isNet ? (netStatus == 0 && netQueued == 0) : (order.isIdle && queued.isEmpty)
    }
    var queuedCount: Int { game.isNet ? netQueued : queued.count }

    // Network-mirrored state (multiplayer clients only)
    var netStatus = 0
    var netQueued = 0
    var netPoints: [(Int, CGPoint)] = []
    var netFrom: (CGPoint, CGFloat, CGFloat)?
    var netTo: (CGPoint, CGFloat, CGFloat)?

    var statusText: String {
        if game.isNet {
            switch netStatus {
            case 1: return "Moving"
            case 2: return "Attack-moving"
            case 3: return "Engaging target"
            case 4: return carrying > 0 ? "Returning cargo" : "Mining crystal"
            case 5: return "Returning cargo"
            case 6: return "Heading to build"
            default: return "Idle"
            }
        }
        switch order {
        case .idle: return "Idle"
        case .move: return "Moving"
        case .attackMove: return "Attack-moving"
        case .attack(let t): return "Engaging \(t.displayName)"
        case .gather: return carrying > 0 ? "Returning cargo" : "Mining crystal"
        case .returnCargo: return "Returning cargo"
        case .build(let k, _): return "Heading to build \(k.stats.name)"
        }
    }

    init(kind: UnitKind, team: Team, at p: CGPoint, game: GameScene) {
        self.kind = kind
        self.stats = kind.stats
        let r = kind.stats.radius
        bodySprite = SKSpriteNode(texture: Art.unit(kind, team))
        super.init(team: team, maxHp: kind.stats.hp, sight: kind.stats.sight, game: game,
                   markerTexture: Art.ring, markerSize: CGSize(width: r * 2 + 12, height: r * 2 + 12),
                   barWidth: max(22, r * 2.2), barY: r + 10)
        position = p
        lastPos = p
        zPosition = 3
        addShadow(size: CGSize(width: r * 2.8, height: r * 2.4), offset: CGPoint(x: 3, y: -4))
        bodySprite.size = Art.unitSize(kind)
        body.addChild(bodySprite)
        addChild(body)
        switch kind {
        case .tank:
            let t = SKSpriteNode(texture: Art.tankTurret(team))
            t.size = Art.turretSize
            t.zPosition = 1
            addChild(t)
            gun = t
        case .worker:
            let c = SKSpriteNode(texture: Art.crystalIcon)
            c.size = CGSize(width: 10, height: 10)
            c.position = CGPoint(x: -9, y: 0)
            c.zPosition = 1
            c.isHidden = true
            body.addChild(c)
            cargoNode = c
        case .marine, .sniper:
            break
        }
        body.zRotation = CGFloat.random(in: 0...(2 * .pi))
        gun?.zRotation = body.zRotation
    }

    required init?(coder: NSCoder) { fatalError() }

    override func surfaceDistance(from p: CGPoint) -> CGFloat { p.distance(to: position) - radius }

    // MARK: Orders

    /// Replaces all orders. Pending build orders are refunded.
    func command(_ o: Order) {
        refundBuilds(includeCurrent: true)
        queued = []
        order = o
        resumePoint = nil
        stuckTimer = 0
        mineTimer = 0
        buildTimer = 0
    }

    /// Adds an order after the current ones (shift-queue).
    func enqueue(_ o: Order) {
        if order.isIdle && queued.isEmpty { command(o) } else { queued.append(o) }
    }

    func refundBuilds(includeCurrent: Bool) {
        if includeCurrent, case .build(let k, _) = order { game.refund(k.stats.cost, team: team) }
        for q in queued {
            if case .build(let k, _) = q { game.refund(k.stats.cost, team: team) }
        }
    }

    func orderBuild(_ k: BuildingKind, at p: CGPoint, queue: Bool = false) {
        if queue && !(order.isIdle && queued.isEmpty) {
            queued.append(.build(k, p))
            return
        }
        switch order {
        case .gather(let c): resumeGather = c
        case .returnCargo: resumeGather = homeCrystal
        default: resumeGather = nil
        }
        command(.build(k, p))
    }

    private func finishAttack() {
        if let r = resumePoint {
            order = .attackMove(r)
            resumePoint = nil
        } else {
            order = .idle
        }
    }

    private func closeEnough(to p: CGPoint, slack: CGFloat) -> Bool {
        let d = position.distance(to: p)
        return d < slack || (stuckTimer > 0.5 && d < radius * 4 + 30) || stuckTimer > 3
    }

    // MARK: Update

    func update(_ dt: CGFloat) {
        cooldown = max(0, cooldown - dt)
        scanTimer -= dt
        let moved = position.distance(to: lastPos)
        if wasMoving && moved < stats.speed * dt * 0.3 {
            stuckTimer += dt
        } else {
            stuckTimer = max(0, stuckTimer - dt * 2)
        }
        lastPos = position
        wasMoving = false
        var target: CGPoint?

        switch order {
        case .idle:
            if kind != .worker && scanTimer <= 0 && queued.isEmpty {
                scanTimer = 0.3
                if let t = game.findTarget(for: self, radius: stats.sight) { order = .attack(t) }
            }

        case .move(let p):
            if closeEnough(to: p, slack: 5) {
                order = .idle
                stuckTimer = 0
            } else {
                target = p
            }

        case .attackMove(let p):
            if scanTimer <= 0 {
                scanTimer = 0.25
                if let t = game.findTarget(for: self, radius: stats.sight) {
                    resumePoint = p
                    order = .attack(t)
                    break
                }
            }
            if closeEnough(to: p, slack: 8) {
                order = .idle
                stuckTimer = 0
            } else {
                target = p
            }

        case .attack(let t):
            if t.dead || !t.isTargetable(by: team) {
                finishAttack()
                break
            }
            // Prefer shooting armed units over structures when they come in range.
            if scanTimer <= 0 && kind != .worker {
                scanTimer = 0.4
                let targetIsArmed = (t as? Unit).map { $0.kind != .worker } ?? false
                if !targetIsArmed, let better = game.findTarget(for: self, radius: stats.range + 20) as? Unit,
                   better.kind != .worker {
                    order = .attack(better)
                    break
                }
            }
            let d = distanceTo(t)
            if d > stats.range {
                target = t.position
            } else {
                aim(at: t.position, dt)
                if cooldown <= 0 { fire(at: t) }
            }

        case .gather(let c):
            if carrying >= 8 {
                order = .returnCargo
                break
            }
            if c.dead {
                if let n = game.nearestCrystal(to: c.position, within: 500) {
                    order = .gather(n)
                } else {
                    order = carrying > 0 ? .returnCargo : .idle
                }
                break
            }
            homeCrystal = c
            let d = position.distance(to: c.position) - c.radius - radius
            if d > 4 {
                target = c.position
                mineTimer = 0
            } else {
                aim(at: c.position, dt)
                let before = mineTimer
                mineTimer += dt
                if Int(before / 0.45) != Int(mineTimer / 0.45) {
                    bodySprite.run(.sequence([.scale(to: 0.88, duration: 0.08), .scale(to: 1, duration: 0.12)]))
                    if visibleToPlayer && team.isLocal {
                        game.spark(at: position + (c.position - position).normalized * (radius + 4), color: Palette.crystal)
                    }
                }
                if mineTimer >= 1.6 {
                    mineTimer = 0
                    carrying = c.extract(8)
                    order = .returnCargo
                }
            }

        case .returnCargo:
            guard carrying > 0 else {
                if let hc = homeCrystal, !hc.dead { order = .gather(hc) } else { order = .idle }
                break
            }
            guard let hq = game.nearestDropoff(for: team, from: position) else {
                order = .idle
                break
            }
            if distanceTo(hq) > 6 {
                target = hq.position
            } else {
                game.deposit(carrying, team: team, at: position)
                carrying = 0
                if !queued.isEmpty {
                    order = .idle
                } else if let hc = homeCrystal, !hc.dead {
                    order = .gather(hc)
                } else if let n = game.nearestCrystal(to: position, within: 700) {
                    order = .gather(n)
                } else {
                    order = .idle
                }
            }

        case .build(let bk, let site):
            let r = squareRect(center: site, half: bk.stats.half)
            buildTimer += dt
            if stuckTimer > 3 || buildTimer > 45 {
                // Site unreachable (boxed in by trees or buildings): give up and refund.
                game.refund(bk.stats.cost, team: team)
                order = .idle
                buildTimer = 0
                if team.isLocal { game.hud.flash("An Engineer couldn't reach the build site", color: Palette.bad) }
            } else if rectDistance(r, position) - radius > 10 {
                target = site
            } else if game.canPlace(bk, at: site, ignoring: self) {
                game.startBuilding(bk, at: site, team: team)
                if !queued.isEmpty {
                    order = .idle
                } else if carrying > 0 {
                    order = .returnCargo
                } else if let c = resumeGather, !c.dead {
                    order = .gather(c)
                } else {
                    order = .idle
                }
                resumeGather = nil
            } else {
                game.refund(bk.stats.cost, team: team)
                order = .idle
                if team.isLocal { game.hud.flash("Build site blocked", color: Palette.bad) }
            }
        }

        if order.isIdle && !queued.isEmpty {
            order = queued.removeFirst()
            stuckTimer = 0
            buildTimer = 0
        }
        if let p = target { moveToward(p, dt) }
        cargoNode?.isHidden = carrying == 0
    }

    private func moveToward(_ p: CGPoint, _ dt: CGFloat) {
        let d = p - position
        let dist = d.length
        guard dist > 0.5 else { return }
        var dir = d * (1 / dist)
        if let n = blockedNormal {
            // Slide along obstacles instead of pushing straight into them.
            let dot = dir.dot(n)
            if dot < 0 {
                if slideSign == 0 {
                    let cross = n.x * dir.y - n.y * dir.x
                    slideSign = cross >= 0 ? 1 : -1
                }
                let tangential = dir - n * dot
                dir = tangential.length < 0.35 ? CGPoint(x: -n.y * slideSign, y: n.x * slideSign) : tangential.normalized
            }
        } else {
            slideSign = 0
        }
        position += dir * min(dist, stats.speed * dt)
        body.zRotation = angleLerp(body.zRotation, dir.angle, dt * 10)
        if let g = gun {
            var attacking = false
            if case .attack = order { attacking = true }
            if !attacking { g.zRotation = angleLerp(g.zRotation, body.zRotation, dt * 6) }
        }
        wasMoving = true
    }

    private func aim(at p: CGPoint, _ dt: CGFloat) {
        let a = (p - position).angle
        if let g = gun {
            g.zRotation = angleLerp(g.zRotation, a, dt * 8)
        } else {
            body.zRotation = angleLerp(body.zRotation, a, dt * 14)
        }
    }

    private func fire(at t: Entity) {
        cooldown = stats.cooldown
        let dir = (t.position - position).normalized
        let angle = dir.angle
        let jitter = CGPoint(x: CGFloat.random(in: -6...6), y: CGFloat.random(in: -6...6))
        let visible = team.isFriendly || visibleToPlayer
        switch kind {
        case .tank:
            let muzzle = position + dir * 33
            game.launchShell(from: muzzle, to: t.position + jitter, damage: stats.damage, splash: stats.splash,
                             team: team, attacker: self)
            if visible {
                game.muzzleFlash(at: muzzle, angle: angle, size: 26)
                game.emit(FX.smokeBurst(size: 8), at: muzzle, life: 2)
            }
            gun?.run(.sequence([.move(by: CGVector(dx: -dir.x * 4, dy: -dir.y * 4), duration: 0.05),
                                .move(to: .zero, duration: 0.25)]))
        case .sniper:
            let side = CGPoint(x: dir.y, y: -dir.x) * 3
            let muzzle = position + dir * 26 + side
            t.takeDamage(stats.damage, from: self)
            if visible {
                game.tracer(from: muzzle, to: t.position, color: .rgb(0.78, 0.95, 1.0), width: 1.1)
                game.muzzleFlash(at: muzzle, angle: angle, size: 18)
                game.impact(at: t.position)
            }
        case .marine:
            let side = CGPoint(x: dir.y, y: -dir.x) * 4.5
            let muzzle = position + dir * 20 + side
            t.takeDamage(stats.damage, from: self)
            if visible {
                game.tracer(from: muzzle, to: t.position + jitter, color: .rgb(1, 0.88, 0.5), width: 1.4)
                game.muzzleFlash(at: muzzle, angle: angle, size: 12)
                if Bool.random() { game.impact(at: t.position + jitter) }
            }
            body.run(.sequence([.move(to: dir * -1.5, duration: 0.03), .move(to: .zero, duration: 0.1)]))
        case .worker:
            t.takeDamage(stats.damage, from: self)
            if visible { game.spark(at: position + dir * (radius + 5), color: Palette.amber) }
        }
    }

    override func onDamaged(by attacker: Entity?) {
        guard let a = attacker, !a.dead, a.team != team, kind != .worker else { return }
        if order.isIdle && queued.isEmpty { order = .attack(a) }
    }

    /// Firing recoil replayed from a server event.
    func netRecoil() {
        let dir = CGPoint(x: cos(gun?.zRotation ?? body.zRotation), y: sin(gun?.zRotation ?? body.zRotation))
        if kind == .tank {
            gun?.run(.sequence([.move(by: CGVector(dx: -dir.x * 4, dy: -dir.y * 4), duration: 0.05), .move(to: .zero, duration: 0.25)]))
        } else if kind == .marine {
            body.run(.sequence([.move(to: dir * -1.5, duration: 0.03), .move(to: .zero, duration: 0.1)]))
        }
    }

    /// Mining bob replayed from a server event.
    func netPulse() {
        bodySprite.run(.sequence([.scale(to: 0.88, duration: 0.08), .scale(to: 1, duration: 0.12)]))
    }
}

// MARK: - Building

final class Building: Entity {
    let kind: BuildingKind
    let stats: BuildingStats
    var built: Bool
    var progress: CGFloat
    var queue: [UnitKind] = []
    var queueProgress: CGFloat = 0
    var rally: CGPoint?
    var cooldown: CGFloat = 0
    var scanTimer: CGFloat = 0
    var turretTarget: Entity?
    let body: SKSpriteNode
    var gun: SKSpriteNode?
    private var scaffold: SKSpriteNode?
    private var chimneys: [SKEmitterNode] = []
    private var damageSmoke: SKEmitterNode?
    private var damageFire: SKEmitterNode?
    private var sparkEmitter: SKEmitterNode?
    private let progressBack = SKSpriteNode(color: NSColor(white: 0, alpha: 0.75), size: .zero)
    private let progressFill = SKSpriteNode(color: Palette.crystal, size: .zero)

    var half: CGFloat { stats.half }
    var rect: CGRect { squareRect(center: position, half: half) }
    override var displayName: String { stats.name }
    override var glyph: String { stats.glyph }
    override var portrait: SKTexture { Art.building(kind, team) }

    init(kind: BuildingKind, team: Team, at p: CGPoint, built: Bool, game: GameScene) {
        self.kind = kind
        self.stats = kind.stats
        self.built = built
        self.progress = built ? 1 : 0
        let h = kind.stats.half
        body = SKSpriteNode(texture: Art.building(kind, team))
        super.init(team: team, maxHp: kind.stats.hp, sight: kind.stats.sight, game: game,
                   markerTexture: kind == .turret ? Art.ring : Art.squareRing,
                   markerSize: CGSize(width: h * 2 + 22, height: h * 2 + 22),
                   barWidth: max(44, h * 1.6), barY: h + 12)
        position = p
        zPosition = 2
        addShadow(size: CGSize(width: h * 2.6, height: h * 2.6), offset: CGPoint(x: 8, y: -10))
        body.size = Art.buildingCanvas(kind)
        addChild(body)

        switch kind {
        case .hq:
            let dish = SKSpriteNode(texture: Art.dish)
            dish.size = CGSize(width: 44, height: 24)
            dish.zPosition = 1
            dish.run(.repeatForever(.rotate(byAngle: .pi * 2, duration: 7)))
            body.addChild(dish)
        case .turret:
            let g = SKSpriteNode(texture: Art.turretGun(team))
            g.size = CGSize(width: 76, height: 36)
            g.zPosition = 1
            addChild(g)
            gun = g
        case .radar:
            let d = SKSpriteNode(texture: Art.radarDish(team))
            d.size = CGSize(width: 84, height: 50)
            d.zPosition = 1
            addChild(d)
            gun = d        // the server turns it, and applyNet follows that angle
        case .factory:
            for (ox, oy) in Art.chimneyOffsets {
                let e = FX.smokeColumn(rate: 0.6, dark: false)
                e.position = CGPoint(x: ox * h, y: oy * h)
                e.zPosition = 6
                e.targetNode = game.effectLayer
                addChild(e)
                chimneys.append(e)
            }
        default:
            break
        }

        progressBack.zPosition = 20
        progressFill.zPosition = 21
        progressFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        progressBack.position = CGPoint(x: 0, y: -h - 10)
        progressFill.position = CGPoint(x: -h * 0.8, y: -h - 10)
        addChild(progressBack)
        addChild(progressFill)
        progressBack.isHidden = true
        progressFill.isHidden = true

        if !built {
            hp = maxHp * 0.1
            body.alpha = 0.35
            body.setScale(0.92)
            let s = SKSpriteNode(texture: Art.scaffold(h))
            s.size = CGSize(width: h * 2 + 10, height: h * 2 + 10)
            s.zPosition = 5
            addChild(s)
            scaffold = s
            let sp = FX.sparks(count: 0, speed: 50, color: Palette.amber)
            sp.numParticlesToEmit = 0
            sp.particleBirthRate = 6
            sp.particlePositionRange = CGVector(dx: h * 1.6, dy: h * 1.6)
            sp.zPosition = 6
            sp.targetNode = game.effectLayer
            addChild(sp)
            sparkEmitter = sp
            updateHPBar()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func surfaceDistance(from p: CGPoint) -> CGFloat { rectDistance(rect, p) }

    override func updateHPBar() {
        super.updateHPBar()
        guard !dead else { return }
        let frac = hp / maxHp
        if built && frac < 0.55 && damageSmoke == nil {
            let e = FX.smokeColumn(rate: 7, dark: true)
            e.position = CGPoint(x: -half * 0.3, y: half * 0.2)
            e.zPosition = 7
            e.targetNode = game.effectLayer
            addChild(e)
            damageSmoke = e
        } else if frac >= 0.55, let e = damageSmoke {
            e.removeFromParent()
            damageSmoke = nil
        }
        if built && frac < 0.28 && damageFire == nil {
            let f = FX.flames(rate: 26)
            f.position = CGPoint(x: half * 0.25, y: -half * 0.1)
            f.zPosition = 7
            f.targetNode = game.effectLayer
            addChild(f)
            damageFire = f
        } else if frac >= 0.28, let f = damageFire {
            f.removeFromParent()
            damageFire = nil
        }
    }

    private func showProgress(_ frac: CGFloat?, color: NSColor) {
        guard let f = frac, team.isFriendly || visibleToPlayer else {
            progressBack.isHidden = true
            progressFill.isHidden = true
            return
        }
        let w = half * 1.6
        progressBack.isHidden = false
        progressFill.isHidden = false
        progressBack.size = CGSize(width: w + 2, height: 5)
        progressFill.size = CGSize(width: w * max(0, min(1, f)), height: 3)
        progressFill.color = color
    }

    private func finishConstruction() {
        built = true
        progress = 1
        body.alpha = 1
        body.setScale(1)
        scaffold?.run(.sequence([.fadeOut(withDuration: 0.4), .removeFromParent()]))
        scaffold = nil
        sparkEmitter?.particleBirthRate = 0
        sparkEmitter?.run(.sequence([.wait(forDuration: 1), .removeFromParent()]))
        sparkEmitter = nil
        showProgress(nil, color: .clear)
        if team.isFriendly || visibleToPlayer {
            game.glowFlash(at: position, size: half * 3, color: team.lightColor, duration: 0.5)
        }
    }

    /// Applies state mirrored from a multiplayer server snapshot.
    func applyNet(hp newHp: CGFloat, built nowBuilt: Bool, progress p: CGFloat, queueProgress qp: CGFloat,
                  gunAngle: CGFloat, queue q: [UnitKind], rally r: CGPoint?) {
        if newHp != hp {
            hp = newHp
            updateHPBar()
        }
        if !built {
            if nowBuilt {
                finishConstruction()
            } else {
                progress = p
                body.alpha = 0.35 + 0.55 * progress
                body.setScale(0.92 + 0.08 * progress)
                showProgress(progress, color: Palette.amber)
            }
        }
        queue = q
        queueProgress = qp
        rally = r
        if built {
            showProgress(queue.isEmpty ? nil : queueProgress, color: Palette.crystal)
            if !chimneys.isEmpty {
                let rate: CGFloat = queue.isEmpty ? 0.6 : 5
                for c in chimneys where c.particleBirthRate != rate { c.particleBirthRate = rate }
            }
        }
        if let g = gun { g.zRotation = angleLerp(g.zRotation, gunAngle, 0.5) }
    }

    func update(_ dt: CGFloat) {
        if !built {
            progress += dt / stats.buildTime
            hp = min(maxHp, hp + maxHp * 0.9 * dt / stats.buildTime)
            body.alpha = 0.35 + 0.55 * progress
            body.setScale(0.92 + 0.08 * progress)
            updateHPBar()
            showProgress(progress, color: Palette.amber)
            if progress >= 1 {
                finishConstruction()
                game.buildingCompleted(self)
            }
            return
        }

        if let k = queue.first {
            queueProgress += dt / k.stats.buildTime
            showProgress(queueProgress, color: Palette.crystal)
            if queueProgress >= 1 {
                queueProgress = 0
                queue.removeFirst()
                game.spawnUnit(k, from: self)
            }
        } else {
            showProgress(nil, color: .clear)
        }
        if !chimneys.isEmpty {
            let rate: CGFloat = queue.isEmpty ? 0.6 : 5
            for c in chimneys where c.particleBirthRate != rate { c.particleBirthRate = rate }
        }

        if kind == .turret { updateTurret(dt) }
    }

    private func updateTurret(_ dt: CGFloat) {
        cooldown = max(0, cooldown - dt)
        scanTimer -= dt
        if let t = turretTarget, t.dead || distanceTo(t) > stats.range || !t.isTargetable(by: team) {
            turretTarget = nil
        }
        if turretTarget == nil && scanTimer <= 0 {
            scanTimer = 0.3
            turretTarget = game.findTarget(for: self, radius: stats.range)
        }
        guard let t = turretTarget, let g = gun else { return }
        let a = (t.position - position).angle
        g.zRotation = angleLerp(g.zRotation, a, dt * 10)
        if cooldown <= 0 {
            cooldown = stats.cooldown
            t.takeDamage(stats.damage, from: self)
            if team.isFriendly || visibleToPlayer {
                let dir = CGPoint(x: cos(a), y: sin(a))
                let side = CGPoint(x: dir.y, y: -dir.x) * (Bool.random() ? 4.5 : -4.5)
                let muzzle = position + dir * 36 + side
                game.tracer(from: muzzle, to: t.position, color: .rgb(1, 0.75, 0.4), width: 2)
                game.muzzleFlash(at: muzzle, angle: a, size: 16)
                game.impact(at: t.position)
            }
        }
    }
}

// MARK: - Bridges

/// A crossing on the client. The footprint comes from the map, the condition from the server: intact it is
/// a deck you walk over, down it is ruins that block the span until an Engineer puts it back.
final class BridgeNode: SKNode {
    /// Assigned from the first snapshot: the server numbers bridges in map order.
    var bridgeId = -1
    let rect: CGRect
    var intact = true
    var hp: CGFloat = bridgeHP
    var progress: CGFloat = 0
    var hovered = false { didSet { marker.isHidden = !hovered } }

    private let deck: SKSpriteNode
    private let marker: SKSpriteNode
    private let barBack = SKSpriteNode(color: NSColor(white: 0, alpha: 0.75), size: CGSize(width: 74, height: 6))
    private let barFill = SKSpriteNode(color: Palette.good, size: CGSize(width: 70, height: 4))
    private let deckTexture: SKTexture
    private let ruinsTexture: SKTexture

    init(rect: CGRect, seed: UInt64) {
        self.rect = rect
        deckTexture = Terrain.bridgeTexture(rect.size, seed: seed)
        ruinsTexture = Terrain.bridgeRuinsTexture(rect.size, seed: seed)
        deck = SKSpriteNode(texture: deckTexture)
        marker = SKSpriteNode(texture: Art.squareRing)
        super.init()
        position = CGPoint(x: rect.midX, y: rect.midY)
        zPosition = -7.5                     // on the ground, under everything that walks across
        deck.size = rect.size
        addChild(deck)
        marker.size = CGSize(width: rect.width + 18, height: rect.height + 18)
        marker.color = Palette.amber
        marker.colorBlendFactor = 1
        marker.alpha = 0.7
        marker.isHidden = true
        addChild(marker)
        barBack.zPosition = 20
        barFill.zPosition = 21
        barFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        barBack.position = CGPoint(x: 0, y: rect.height / 2 + 12)
        barFill.position = CGPoint(x: -35, y: rect.height / 2 + 12)
        barBack.isHidden = true
        barFill.isHidden = true
        addChild(barBack)
        addChild(barFill)
    }

    required init?(coder: NSCoder) { fatalError() }

    func contains(world p: CGPoint) -> Bool { rect.insetBy(dx: -4, dy: -4).contains(p) }

    func apply(intact nowIntact: Bool, hp newHp: CGFloat, progress p: CGFloat) {
        if nowIntact != intact {
            intact = nowIntact
            deck.texture = nowIntact ? deckTexture : ruinsTexture
        }
        hp = newHp
        progress = p
        marker.color = intact ? Palette.amber : Palette.dim
        // Health while it stands, rebuild progress while it does not.
        let frac: CGFloat? = intact ? (hp < bridgeHP ? hp / bridgeHP : nil) : (p > 0 ? p : nil)
        if let f = frac {
            barBack.isHidden = false
            barFill.isHidden = false
            barFill.size = CGSize(width: 70 * max(0, min(1, f)), height: 4)
            barFill.color = intact ? Palette.good : Palette.amber
        } else {
            barBack.isHidden = true
            barFill.isHidden = true
        }
    }
}
