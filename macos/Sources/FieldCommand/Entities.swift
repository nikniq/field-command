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
    let isGold: Bool
    let radius: CGFloat = 18
    var dead = false
    var netId = 0
    private let sprite: SKSpriteNode
    private let glowNode = SKSpriteNode(texture: Art.glow)

    init(at p: CGPoint, amount: Int, variant: Int) {
        self.amount = amount
        self.maxAmount = amount
        sprite = SKSpriteNode(texture: Art.crystal(variant % 4))      // 3 is gold
        isGold = variant % 4 == 3
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
    var maxHp: CGFloat
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
    /// The same sort of thing: two units of one kind, or two buildings of one kind.
    func sameKind(as other: Entity) -> Bool {
        if let a = self as? Unit, let b = other as? Unit { return a.kind == b.kind }
        if let a = self as? Building, let b = other as? Building { return a.kind == b.kind }
        return false
    }
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
        selectionGlow.size = CGSize(width: markerSize.width * 1.7, height: markerSize.height * 1.7)
        selectionGlow.colorBlendFactor = 1
        selectionGlow.blendMode = .add
        selectionGlow.alpha = 0.28
        selectionGlow.zPosition = -1.5
        selectionGlow.isHidden = true
        addChild(selectionGlow)

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

    /// A soft glow in the side's colour under a selected unit of your own, so a picked squad reads at a glance.
    let selectionGlow = SKSpriteNode(texture: Art.glow)

    private func refreshMarker() {
        let own = team.isLocal
        selectionGlow.isHidden = !(isSelected && own && self is Unit)
        selectionGlow.color = team.lightColor
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

    /// Just hit: whiten the sprite for a few frames.
    func flashHit() {
        guard let body = hitFlashNode else { return }
        body.removeAction(forKey: "hit")
        body.run(.sequence([.colorize(with: .white, colorBlendFactor: 0.55, duration: 0.03),
                            .colorize(withColorBlendFactor: 0, duration: 0.12)]), withKey: "hit")
    }
    var hitFlashNode: SKSpriteNode? { nil }

    func updateHPBar() {
        let frac = max(0, min(1, hp / maxHp))
        let show = isSelected || isHovered || frac < 0.999 || (Settings.barsAlways && team.isFriendly)
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
    override var hitFlashNode: SKSpriteNode? { bodySprite }
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
    /// Siege mode, from the server. The outriggers fold out under the hull while it is anything but mobile.
    private(set) var mode: SiegeMode = .mobile
    private var outriggers: SKSpriteNode?
    /// The control group this unit is in, shown as a small numbered plate on its shoulder.
    private var groupBadge: SKSpriteNode?
    func setGroup(_ n: Int?) {
        groupBadge?.removeFromParent()
        groupBadge = nil
        guard let n else { return }
        let b = SKSpriteNode(texture: Art.groupBadge(n))
        b.size = CGSize(width: 16, height: 16)
        b.position = CGPoint(x: radius + 4, y: -(radius + 4))
        b.zPosition = 6
        addChild(b)
        groupBadge = b
    }

    /// Veterancy rank, from the server; chevrons above the unit show it.
    private(set) var rank = 0
    private var chevrons: SKSpriteNode?

    func setRank(_ r: Int) {
        guard r != rank else { return }
        rank = r
        maxHp = stats.hp * (1 + CGFloat(vetBonus) * CGFloat(r))
        updateHPBar()
        chevrons?.removeFromParent()
        chevrons = nil
        guard r > 0 else { return }
        let c = SKSpriteNode(texture: Art.chevrons(r, team))
        c.size = CGSize(width: 16, height: 20)
        c.position = CGPoint(x: 0, y: radius + 16)
        c.zPosition = 6
        addChild(c)
        chevrons = c
    }
    var sieged: Bool { mode == .sieged }
    var canSiege: Bool { kind == .tank }

    /// The kind's ability: seconds until it is ready again, from the server.
    var abilityCd = 0.0
    /// A Sniper's mark, shown as a pulsing amber reticle above the unit.
    private(set) var marked = false
    private var markNode: SKNode?

    func setMarked(_ m: Bool) {
        guard m != marked else { return }
        marked = m
        markNode?.removeFromParent()
        markNode = nil
        guard m else { return }
        let n = SKNode()
        let ring = SKShapeNode(circleOfRadius: 7)
        ring.strokeColor = Palette.amber
        ring.lineWidth = 2
        ring.fillColor = .clear
        n.addChild(ring)
        let stem = SKShapeNode(rect: CGRect(x: -1, y: -15, width: 2, height: 7))
        stem.fillColor = Palette.amber
        stem.strokeColor = .clear
        n.addChild(stem)
        n.position = CGPoint(x: 0, y: radius + 30)
        n.zPosition = 6
        n.run(.repeatForever(.sequence([.scale(to: 1.3, duration: 0.4), .scale(to: 0.9, duration: 0.4)])))
        addChild(n)
        markNode = n
    }

    func setMode(_ m: SiegeMode) {
        guard m != mode else { return }
        mode = m
        guard let legs = outriggers else { return }
        legs.removeAllActions()
        if m == .mobile {
            legs.run(.sequence([.scale(to: 0.35, duration: 0.6), .hide()]))
        } else {
            legs.isHidden = false
            legs.run(.scale(to: 1, duration: m == .sieged ? 0.1 : 0.6))
        }
    }
    var netQueued = 0
    var netPoints: [(Int, CGPoint)] = []
    var netFrom: (CGPoint, CGFloat, CGFloat)?
    var netTo: (CGPoint, CGFloat, CGFloat)?
    /// Where the unit was last drawn and how far it has gone since the last puff of dust.
    private var travelFrom: CGPoint?
    private var travelAcc: CGFloat = 0

    /// Dust behind anything on the move, and tracks pressed into the ground behind a tank.
    func trackTravel() {
        defer { travelFrom = position }
        guard let from = travelFrom, !stats.flies, mode == .mobile else { return }
        travelAcc += position.distance(to: from)
        let step: CGFloat = kind == .tank ? 26 : 22
        guard travelAcc > step else { return }
        travelAcc = 0
        let a = body.zRotation
        let behind = CGPoint(x: position.x - cos(a) * radius * 0.9, y: position.y - sin(a) * radius * 0.9)
        game.emit(FX.dust(size: kind == .tank ? 9 : 6), at: behind, life: 1.2)
        if kind == .tank {
            let d = SKSpriteNode(texture: Art.tread)
            d.size = CGSize(width: 30, height: 22)
            d.position = behind
            d.zRotation = a
            d.zPosition = 0.2
            d.alpha = 0.9
            game.world.addChild(d)
            d.run(.sequence([.wait(forDuration: 5), .fadeOut(withDuration: 4), .removeFromParent()]))
        }
    }

    var statusText: String {
        let text = baseStatusText
        return game.inCover(self) ? text + " · in cover" : text
    }

    /// In cover: a small green leaf-shaped badge beside the health bar while selected or hovered.
    private var coverBadge: SKShapeNode?

    override func updateHPBar() {
        super.updateHPBar()
        let show = (isSelected || isHovered) && !dead && game.inCover(self)
        if show && coverBadge == nil {
            let b = SKShapeNode(path: {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: 0, y: 5)); p.addLine(to: CGPoint(x: 4, y: 0)); p.addLine(to: CGPoint(x: 0, y: -5)); p.addLine(to: CGPoint(x: -4, y: 0)); p.closeSubpath()
                return p
            }())
            b.fillColor = .rgb(0.43, 0.78, 0.35)
            b.strokeColor = .black
            b.lineWidth = 1
            b.position = CGPoint(x: hpBarWidth / 2 + 7, y: hpBack.position.y)
            b.zPosition = 22
            addChild(b)
            coverBadge = b
        } else if !show, let b = coverBadge {
            b.removeFromParent()
            coverBadge = nil
        }
    }

    private var baseStatusText: String {
        if mode == .sieging { return "Digging in" }
        if mode == .unsieging { return "Packing up" }
        if game.isNet {
            if sieged { return netStatus == 3 ? "Sieged — engaging target" : "Sieged" }
            switch netStatus {
            case 1: return "Moving"
            case 2: return "Attack-moving"
            case 3: return "Engaging target"
            case 4: return carrying > 0 ? "Returning cargo" : "Mining crystal"
            case 5: return "Returning cargo"
            case 6: return "Heading to build"
            case 7: return "Rebuilding a bridge"
            case 8: return "Repairing"
            case 9: return "Treating a casualty"
            default: return "Idle"
            }
        }
        if rank > 0 { return "Rank \(rank) veteran" }
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
        zPosition = kind.stats.flies ? 5 : 3
        if kind.stats.flies {
            // Drawn up in the air, the shadow left on the ground.
            addShadow(size: CGSize(width: r * 2.2, height: r * 1.9), offset: CGPoint(x: 14, y: -16))
            body.position = CGPoint(x: 0, y: 22)
        } else {
            addShadow(size: CGSize(width: r * 2.8, height: r * 2.4), offset: CGPoint(x: 3, y: -4))
        }
        bodySprite.size = Art.unitSize(kind)
        body.addChild(bodySprite)
        addChild(body)
        switch kind {
        case .tank:
            let legs = SKSpriteNode(texture: Art.tankOutriggers(team))
            legs.size = CGSize(width: 76, height: 56)
            legs.zPosition = -0.5
            legs.setScale(0.35)
            legs.isHidden = true
            body.addChild(legs)
            outriggers = legs
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
        case .marine, .sniper, .medic, .gunship:
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
                playSound("cannon")
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
                playSound("snipe")
            }
        case .marine, .gunship:
            let side = CGPoint(x: dir.y, y: -dir.x) * 4.5
            let muzzle = position + dir * 20 + side
            t.takeDamage(stats.damage, from: self)
            if visible {
                game.tracer(from: muzzle, to: t.position + jitter, color: .rgb(1, 0.88, 0.5), width: 1.4)
                game.muzzleFlash(at: muzzle, angle: angle, size: 12)
                if Bool.random() { game.impact(at: t.position + jitter) }
                playSound("rifle")
            }
            body.run(.sequence([.move(to: dir * -1.5, duration: 0.03), .move(to: .zero, duration: 0.1)]))
        case .worker:
            t.takeDamage(stats.damage, from: self)
            if visible { game.spark(at: position + dir * (radius + 5), color: Palette.amber) }
        case .medic:
            break                       // unarmed
        }
    }

    override func onDamaged(by attacker: Entity?) {
        guard let a = attacker, !a.dead, a.team != team, kind != .worker, kind != .medic else { return }
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
    /// Upgrades, from the server: installed set, and the one being researched with its progress.
    private(set) var upgrades: Set<UpgradeKind> = []
    private(set) var upgrading: UpgradeKind?
    private(set) var upgradeProgress: CGFloat = 0
    let body: SKSpriteNode
    private var walls: [SKSpriteNode] = []
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
                   markerTexture: kind == .turret || kind == .artillery ? Art.ring : Art.squareRing,
                   markerSize: CGSize(width: h * 2 + 22, height: h * 2 + 22),
                   barWidth: max(44, h * 1.6), barY: h + 12)
        position = p
        zPosition = 2
        addShadow(size: CGSize(width: h * 2.6, height: h * 2.6), offset: CGPoint(x: 8, y: -10))
        body.size = Art.buildingCanvas(kind)
        // The walls: the tilt shows a building's height as dark slices of its own outline stacked below the roof.
        let wallH = h * (kind == .turret || kind == .artillery || kind == .shield ? 0.28 : 0.45) * tilt
        let slices = max(2, Int(wallH / 3))
        for i in stride(from: slices, through: 1, by: -1) {
            let dy = wallH * CGFloat(i) / CGFloat(slices)
            let w = SKSpriteNode(texture: body.texture)
            w.size = body.size
            w.color = .rgb(0.055, 0.063, 0.08)
            w.colorBlendFactor = 0.82
            w.alpha = 0.92
            w.position = CGPoint(x: dy * 0.18, y: -dy)
            w.zPosition = -0.3
            addChild(w)
            walls.append(w)
        }
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
        case .artillery:
            let g = SKSpriteNode(texture: Art.artilleryGun(team))
            g.size = CGSize(width: 104, height: 40)
            g.zPosition = 1
            addChild(g)
            gun = g
        case .shield:
            let d = SKSpriteNode(texture: Art.shieldDome)
            d.size = CGSize(width: 88, height: 88)
            d.zPosition = 5
            d.alpha = built ? 0.7 : 0
            d.run(.repeatForever(.sequence([.fadeAlpha(to: 0.35, duration: 1.1), .fadeAlpha(to: 0.8, duration: 1.1)])))
            addChild(d)
            dome = d
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
    /// Shield points from a generator in range: a field-blue bar above the health bar.
    private(set) var shield: CGFloat = 0
    private var shieldBack: SKSpriteNode?
    private var shieldFill: SKSpriteNode?
    var dome: SKSpriteNode?

    func applyShield(_ v: CGFloat) {
        guard v != shield else { return }
        shield = v
        if shieldBack == nil {
            let w = hpBarWidth, y = stats.half + 19
            let back = SKSpriteNode(color: NSColor(white: 0, alpha: 0.75), size: CGSize(width: w + 2, height: 5))
            back.position = CGPoint(x: 0, y: y); back.zPosition = 20
            let fill = SKSpriteNode(color: .rgb(0.43, 0.84, 1.0), size: CGSize(width: w, height: 3))
            fill.anchorPoint = CGPoint(x: 0, y: 0.5); fill.position = CGPoint(x: -w / 2, y: y); fill.zPosition = 21
            addChild(back); addChild(fill)
            shieldBack = back; shieldFill = fill
        }
        let frac = max(0, min(1, v / CGFloat(shieldMax)))
        shieldBack?.isHidden = v <= 0
        shieldFill?.isHidden = v <= 0
        shieldFill?.size = CGSize(width: hpBarWidth * frac, height: 3)
        if kind == .shield, let d = dome, built, d.alpha == 0 { d.alpha = 0.7 }
    }

    override var hitFlashNode: SKSpriteNode? { body }

    func applyNet(hp newHp: CGFloat, built nowBuilt: Bool, progress p: CGFloat, queueProgress qp: CGFloat,
                  gunAngle: CGFloat, queue q: [UnitKind], rally r: CGPoint?) {
        if newHp != hp {
            if newHp < hp { flashHit() }
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

    func canUpgrade(_ k: UpgradeKind) -> Bool {
        built && !dead && k.applies(to: kind) && !upgrades.contains(k) && upgrading == nil
    }

    func applyUpgrades(mask: Int, inProgress: (UpgradeKind, CGFloat)?) {
        let set = Set(UpgradeKind.allCases.filter { mask & (1 << $0.rawValue) != 0 })
        if set != upgrades {
            upgrades = set
            maxHp = stats.hp * (set.contains(.hp) ? 2 : 1)      // the bar must know the new ceiling
            updateHPBar()
            if kind == .hq && set.contains(.defense) && gun == nil {      // the point-defence gun on the roof
                let g = SKSpriteNode(texture: Art.turretGun(team))
                g.size = CGSize(width: 76 * 0.85, height: 36 * 0.85)
                g.zPosition = 2
                addChild(g)
                gun = g
            }
        }
        upgrading = inProgress?.0
        upgradeProgress = inProgress?.1 ?? 0
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

// MARK: - Watchtowers

/// A control point on the client: the tower art in the holder's colour, and the capture ring while someone
/// is taking it. Position comes with the first snapshot; condition with every one.
/// A supply crate on the field: bobs a little, its beacon glows, and a hover ring when the mouse is on it.
final class CrateNode: SKNode {
    let crateId: Int
    let kind: String
    let amount: Int
    let radius: CGFloat = CGFloat(crateRadius)
    var hovered = false { didSet { marker.isHidden = !hovered } }
    private let marker = SKSpriteNode(texture: Art.ring)

    init(id: Int, kind: String, amount: Int, at p: CGPoint) {
        crateId = id; self.kind = kind; self.amount = amount
        super.init()
        position = p
        zPosition = 1.6
        let shadow = SKSpriteNode(texture: Art.shadow)
        shadow.size = CGSize(width: 46, height: 46)
        shadow.position = CGPoint(x: 4, y: -5)
        shadow.zPosition = -0.5
        addChild(shadow)
        let glow = SKSpriteNode(texture: Art.glow)
        glow.size = CGSize(width: 70, height: 70)
        glow.color = .rgb(1, 0.67, 0.31)
        glow.colorBlendFactor = 1
        glow.blendMode = .add
        glow.alpha = 0.55
        glow.zPosition = -0.2
        glow.run(.repeatForever(.sequence([.fadeAlpha(to: 0.25, duration: 0.8), .fadeAlpha(to: 0.7, duration: 0.8)])))
        addChild(glow)
        let body = SKSpriteNode(texture: Art.crate)
        body.size = CGSize(width: 44, height: 38)
        body.zRotation = CGFloat(id * 37 % 360) * .pi / 180
        body.run(.repeatForever(.sequence([.moveBy(x: 0, y: 2, duration: 1.2), .moveBy(x: 0, y: -2, duration: 1.2)])))
        addChild(body)
        marker.size = CGSize(width: radius * 2 + 12, height: radius * 2 + 12)
        marker.alpha = 0.7
        marker.isHidden = true
        marker.zPosition = -0.1
        addChild(marker)
    }

    required init?(coder: NSCoder) { fatalError() }

    func contains(world p: CGPoint) -> Bool { position.distance(to: p) < radius + 8 }
}

final class TowerNode: SKNode {
    var towerId = -1
    private(set) var owner: Int?
    private(set) var capturing: Int?
    private(set) var progress: CGFloat = 0
    let half: CGFloat = CGFloat(towerHalf)
    private let art = SKSpriteNode()
    private let ring = SKShapeNode(circleOfRadius: CGFloat(towerRadius))
    private let arc = SKShapeNode()
    private let barBack = SKSpriteNode(color: NSColor(white: 0, alpha: 0.75), size: CGSize(width: 64, height: 6))
    private let barFill = SKSpriteNode(color: Palette.amber, size: CGSize(width: 60, height: 4))
    var hovered = false { didSet { marker.isHidden = !hovered } }
    private let marker: SKSpriteNode

    init(id: Int, at p: CGPoint) {
        towerId = id
        marker = SKSpriteNode(texture: Art.squareRing)
        super.init()
        position = p
        zPosition = 1.5
        let shadow = SKSpriteNode(texture: Art.shadow)
        shadow.size = CGSize(width: 70, height: 70)
        shadow.position = CGPoint(x: 6, y: -8)
        shadow.zPosition = -0.5
        addChild(shadow)
        art.texture = Art.watchtower(nil)
        art.size = CGSize(width: 84, height: 84)
        addChild(art)
        ring.strokeColor = NSColor(white: 1, alpha: 0.25)
        ring.lineWidth = 1
        ring.isHidden = true
        addChild(ring)
        arc.lineWidth = 4
        arc.isHidden = true
        addChild(arc)
        barBack.position = CGPoint(x: 0, y: -40)
        barFill.position = CGPoint(x: -30, y: -40)
        barFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        barBack.isHidden = true
        barFill.isHidden = true
        addChild(barBack)
        addChild(barFill)
        marker.size = CGSize(width: half * 2 + 22, height: half * 2 + 22)
        marker.color = Palette.dim
        marker.colorBlendFactor = 1
        marker.alpha = 0.7
        marker.isHidden = true
        addChild(marker)
    }

    required init?(coder: NSCoder) { fatalError() }

    func contains(world p: CGPoint) -> Bool { abs(p.x - position.x) <= half + 6 && abs(p.y - position.y) <= half + 6 }

    func apply(owner o: Int?, capturing c: Int?, progress p: CGFloat) {
        if o != owner {
            owner = o
            art.texture = Art.watchtower(o.map { Team(rawValue: $0) })
            marker.color = o.map { Team(rawValue: $0).lightColor } ?? Palette.dim
        }
        capturing = c
        progress = p
        let taking = c != nil && p > 0
        ring.isHidden = !taking
        arc.isHidden = !taking
        barBack.isHidden = !taking
        barFill.isHidden = !taking
        if taking, let c {
            let color = Team(rawValue: c).lightColor
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: CGFloat(towerRadius), startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * p, clockwise: true)
            arc.path = path
            arc.strokeColor = color
            barFill.color = color
            barFill.size = CGSize(width: 60 * max(0, min(1, p)), height: 4)
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
