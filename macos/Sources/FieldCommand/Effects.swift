import SpriteKit

/// Particle emitter recipes.
enum FX {
    private static func base(_ texture: SKTexture = Art.glow) -> SKEmitterNode {
        let e = SKEmitterNode()
        e.particleTexture = texture
        e.particleColorBlendFactor = 1
        e.emissionAngleRange = .pi * 2
        return e
    }

    static func fireBurst(size: CGFloat) -> SKEmitterNode {
        let e = base()
        let n = Int(min(60, 10 + size * 0.8))
        e.numParticlesToEmit = n
        e.particleBirthRate = CGFloat(n) * 25
        e.particleLifetime = 0.45
        e.particleLifetimeRange = 0.3
        e.particleSpeed = size * 2.2
        e.particleSpeedRange = size * 1.8
        e.particleScale = size / 64 * 0.9
        e.particleScaleRange = size / 64 * 0.5
        e.particleScaleSpeed = -size / 64 * 0.6
        e.particleAlphaSpeed = -1.8
        e.particleColorSequence = SKKeyframeSequence(keyframeValues: [NSColor.rgb(1, 0.95, 0.7), NSColor.rgb(1, 0.55, 0.15), NSColor.rgb(0.45, 0.12, 0.05)],
                                                     times: [0, 0.35, 1])
        e.particleBlendMode = .add
        return e
    }

    static func smokeBurst(size: CGFloat) -> SKEmitterNode {
        let e = base(Art.blob)
        let n = Int(min(24, 5 + size * 0.3))
        e.numParticlesToEmit = n
        e.particleBirthRate = CGFloat(n) * 10
        e.particleLifetime = 1.6
        e.particleLifetimeRange = 0.6
        e.particleSpeed = size * 0.9
        e.particleSpeedRange = size * 0.6
        e.particleScale = size / 64 * 0.9
        e.particleScaleRange = size / 64 * 0.4
        e.particleScaleSpeed = size / 64 * 0.7
        e.particleAlpha = 0.75
        e.particleAlphaSpeed = -0.5
        e.particleRotationRange = .pi * 2
        e.particleRotationSpeed = 0.6
        e.particleColor = .rgb(0.16, 0.15, 0.14)
        e.yAcceleration = 12
        return e
    }

    /// A puff of dry earth kicked up by a unit on the move.
    static func dust(size: CGFloat) -> SKEmitterNode {
        let e = base(Art.blob)
        e.numParticlesToEmit = 2
        e.particleBirthRate = 40
        e.particleLifetime = 0.7
        e.particleLifetimeRange = 0.3
        e.particleSpeed = 10
        e.particleSpeedRange = 6
        e.emissionAngle = .pi / 2
        e.emissionAngleRange = 1.2
        e.particleScale = size / 64 * 0.9
        e.particleScaleRange = size / 64 * 0.3
        e.particleScaleSpeed = size / 64 * 1.2
        e.particleAlpha = 0.3
        e.particleAlphaSpeed = -0.4
        e.particleColor = .rgb(0.66, 0.59, 0.46)
        e.yAcceleration = 4
        return e
    }

    static func sparks(count: Int, speed: CGFloat, color: NSColor) -> SKEmitterNode {
        let e = base()
        e.numParticlesToEmit = count
        e.particleBirthRate = CGFloat(count) * 40
        e.particleLifetime = 0.35
        e.particleLifetimeRange = 0.2
        e.particleSpeed = speed
        e.particleSpeedRange = speed * 0.6
        e.particleScale = 0.07
        e.particleScaleRange = 0.03
        e.particleScaleSpeed = -0.12
        e.particleColor = color
        e.particleBlendMode = .add
        return e
    }

    /// Continuous smoke column (damaged buildings, chimneys).
    static func smokeColumn(rate: CGFloat, dark: Bool) -> SKEmitterNode {
        let e = base(Art.blob)
        e.particleBirthRate = rate
        e.particleLifetime = 2.6
        e.particleLifetimeRange = 0.8
        e.emissionAngle = .pi / 2 + 0.3
        e.emissionAngleRange = 0.5
        e.particleSpeed = 26
        e.particleSpeedRange = 10
        e.particleScale = 0.3
        e.particleScaleRange = 0.1
        e.particleScaleSpeed = 0.35
        e.particleAlpha = dark ? 0.55 : 0.35
        e.particleAlphaSpeed = dark ? -0.22 : -0.14
        e.particleRotationRange = .pi * 2
        e.particleRotationSpeed = 0.4
        e.particleColor = dark ? .rgb(0.12, 0.11, 0.1) : .rgb(0.7, 0.7, 0.72)
        e.xAcceleration = 8
        e.particlePositionRange = CGVector(dx: 6, dy: 6)
        return e
    }

    static func flames(rate: CGFloat) -> SKEmitterNode {
        let e = base()
        e.particleBirthRate = rate
        e.particleLifetime = 0.6
        e.particleLifetimeRange = 0.3
        e.emissionAngle = .pi / 2
        e.emissionAngleRange = 0.5
        e.particleSpeed = 30
        e.particleSpeedRange = 12
        e.particleScale = 0.28
        e.particleScaleRange = 0.1
        e.particleScaleSpeed = -0.35
        e.particleAlphaSpeed = -1.2
        e.particlePositionRange = CGVector(dx: 16, dy: 10)
        e.particleColorSequence = SKKeyframeSequence(keyframeValues: [NSColor.rgb(1, 0.9, 0.5), NSColor.rgb(1, 0.45, 0.1), NSColor.rgb(0.5, 0.1, 0.05)],
                                                     times: [0, 0.4, 1])
        e.particleBlendMode = .add
        return e
    }

    static func trail() -> SKEmitterNode {
        let e = base()
        e.particleBirthRate = 90
        e.particleLifetime = 0.25
        e.particleSpeed = 0
        e.particleScale = 0.12
        e.particleScaleSpeed = -0.3
        e.particleAlpha = 0.7
        e.particleAlphaSpeed = -2.5
        e.particleColor = .rgb(1, 0.75, 0.35)
        e.particleBlendMode = .add
        return e
    }
}

extension GameScene {
    /// Adds a one-shot emitter to the effect layer and removes it once its particles are gone.
    func emit(_ e: SKEmitterNode, at p: CGPoint, life: TimeInterval = 2.5) {
        e.position = p
        effectLayer.addChild(e)
        e.run(.sequence([.wait(forDuration: life), .removeFromParent()]))
    }

    func glowFlash(at p: CGPoint, size: CGFloat, color: NSColor, duration: TimeInterval = 0.25) {
        let g = SKSpriteNode(texture: Art.glow)
        g.size = CGSize(width: size, height: size)
        g.color = color
        g.colorBlendFactor = 1
        g.blendMode = .add
        g.position = p
        effectLayer.addChild(g)
        g.run(.sequence([.group([.scale(to: 1.4, duration: duration), .fadeOut(withDuration: duration)]), .removeFromParent()]))
    }

    func tracer(from a: CGPoint, to b: CGPoint, color: NSColor, width: CGFloat) {
        let d = b - a
        let len = d.length
        guard len > 1 else { return }
        let line = SKSpriteNode(color: color, size: CGSize(width: len, height: width))
        line.anchorPoint = CGPoint(x: 0, y: 0.5)
        line.position = a
        line.zRotation = d.angle
        line.blendMode = .add
        effectLayer.addChild(line)
        line.run(.sequence([.fadeOut(withDuration: 0.1), .removeFromParent()]))
    }

    func muzzleFlash(at p: CGPoint, angle: CGFloat, size: CGFloat) {
        glowFlash(at: p, size: size, color: .rgb(1, 0.85, 0.5), duration: 0.08)
        let streak = SKSpriteNode(texture: Art.glow)
        streak.size = CGSize(width: size * 1.6, height: size * 0.5)
        streak.color = .rgb(1, 0.9, 0.6)
        streak.colorBlendFactor = 1
        streak.blendMode = .add
        streak.position = p + CGPoint(x: cos(angle), y: sin(angle)) * (size * 0.5)
        streak.zRotation = angle
        effectLayer.addChild(streak)
        streak.run(.sequence([.fadeOut(withDuration: 0.07), .removeFromParent()]))
    }

    func impact(at p: CGPoint) {
        emit(FX.sparks(count: 4, speed: 60, color: .rgb(1, 0.8, 0.4)), at: p, life: 0.6)
    }

    func spark(at p: CGPoint, color: NSColor) {
        emit(FX.sparks(count: 3, speed: 35, color: color), at: p, life: 0.6)
    }

    func explosion(at p: CGPoint, size: CGFloat, delay: TimeInterval = 0, scorch: Bool = true) {
        let run = { [weak self] in
            guard let self else { return }
            self.glowFlash(at: p, size: size * 3, color: .rgb(1, 0.7, 0.3), duration: 0.3)
            self.emit(FX.fireBurst(size: size), at: p)
            self.emit(FX.smokeBurst(size: size), at: p, life: 3)
            self.emit(FX.sparks(count: Int(6 + size / 3), speed: size * 4, color: .rgb(1, 0.85, 0.5)), at: p, life: 1)
            if scorch { self.decal(Art.scorch, at: p, size: size * 2.2, life: 90) }      // craters stay a good while
            if size > 25 && self.visibleWorldRect().contains(p) { self.shake(min(10, size * 0.18)) }
        }
        if delay > 0 { effectLayer.run(.sequence([.wait(forDuration: delay), .run(run)])) } else { run() }
    }

    func decal(_ tex: SKTexture, at p: CGPoint, size: CGFloat, life: TimeInterval) {
        let d = SKSpriteNode(texture: tex)
        d.size = CGSize(width: size, height: size)
        d.position = p
        d.zRotation = CGFloat.random(in: 0...(2 * .pi))
        decalLayer.addChild(d)
        d.run(.sequence([.wait(forDuration: life), .fadeOut(withDuration: 4), .removeFromParent()]))
        if decalLayer.children.count > 160 { decalLayer.children.first?.removeFromParent() }
    }

    func marker(at p: CGPoint, color: NSColor, size: CGFloat) {
        let m = SKSpriteNode(texture: Art.ring)
        m.size = CGSize(width: size * 2, height: size * 2)
        m.color = color
        m.colorBlendFactor = 1
        m.position = p
        effectLayer.addChild(m)
        m.run(.sequence([.group([.scale(to: 0.25, duration: 0.4), .fadeOut(withDuration: 0.4)]), .removeFromParent()]))
    }

    func alertRing(at p: CGPoint) {
        for i in 0..<3 {
            let m = SKSpriteNode(texture: Art.ring)
            m.size = CGSize(width: 60, height: 60)
            m.color = Palette.bad
            m.colorBlendFactor = 1
            m.position = p
            m.alpha = 0
            m.zPosition = 20
            effectLayer.addChild(m)
            m.run(.sequence([.wait(forDuration: Double(i) * 0.35), .fadeIn(withDuration: 0),
                             .group([.scale(to: 4, duration: 0.8), .fadeOut(withDuration: 0.8)]), .removeFromParent()]))
        }
    }
}
