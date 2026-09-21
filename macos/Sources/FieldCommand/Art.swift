import SpriteKit
import AppKit

/// Procedurally drawn textures. Everything is rendered once with Core Graphics (2× for Retina) and cached.
/// Drawing callbacks use a centred coordinate system with y up and a key light from the top-left.
enum Art {
    private static var cache: [String: SKTexture] = [:]
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - Core

    static func texture(_ key: String, size: CGSize, scale: CGFloat = 2, _ draw: (CGContext) -> Void) -> SKTexture {
        if let t = cache[key] { return t }
        let t = render(size: size, scale: scale, draw)
        cache[key] = t
        return t
    }

    static func render(size: CGSize, scale: CGFloat = 2, _ draw: (CGContext) -> Void) -> SKTexture {
        guard let img = image(size: size, scale: scale, draw) else { return SKTexture() }
        let t = SKTexture(cgImage: img)
        t.filteringMode = .linear
        return t
    }

    static func image(size: CGSize, scale: CGFloat = 2, _ draw: (CGContext) -> Void) -> CGImage? {
        let w = max(1, Int(ceil(size.width * scale))), h = max(1, Int(ceil(size.height * scale)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        draw(ctx)
        return ctx.makeImage()
    }

    // MARK: - Path & paint helpers

    static func rr(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        let c = max(0, min(radius, r.width / 2 - 0.01, r.height / 2 - 0.01))
        return CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil)
    }

    static func ellipse(_ r: CGRect) -> CGPath { CGPath(ellipseIn: r, transform: nil) }

    static func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        ellipse(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    static func poly(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: pts)
        p.closeSubpath()
        return p
    }

    static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    static func fill(_ ctx: CGContext, _ p: CGPath, _ c: NSColor) {
        ctx.addPath(p)
        ctx.setFillColor(c.cgColor)
        ctx.fillPath()
    }

    static func stroke(_ ctx: CGContext, _ p: CGPath, _ c: NSColor, _ w: CGFloat) {
        ctx.addPath(p)
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(w)
        ctx.strokePath()
    }

    static func lines(_ ctx: CGContext, _ segs: [(CGPoint, CGPoint)], _ c: NSColor, _ w: CGFloat) {
        for (a, b) in segs {
            ctx.move(to: a)
            ctx.addLine(to: b)
        }
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(w)
        ctx.strokePath()
    }

    static func linear(_ ctx: CGContext, _ p: CGPath, _ colors: [NSColor], _ a: CGPoint, _ b: CGPoint) {
        ctx.saveGState()
        ctx.addPath(p)
        ctx.clip()
        if let g = CGGradient(colorsSpace: srgb, colors: colors.map { $0.cgColor } as CFArray, locations: nil) {
            ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    static func radial(_ ctx: CGContext, _ p: CGPath?, _ colors: [NSColor], _ c: CGPoint, _ r: CGFloat) {
        ctx.saveGState()
        if let p = p {
            ctx.addPath(p)
            ctx.clip()
        }
        if let g = CGGradient(colorsSpace: srgb, colors: colors.map { $0.cgColor } as CFArray, locations: nil) {
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    /// Fills a shape with a top-left lit gradient of the base colour.
    static func lit(_ ctx: CGContext, _ p: CGPath, _ base: NSColor, _ strength: CGFloat = 1) {
        let b = p.boundingBox
        linear(ctx, p, [base.mix(.white, 0.34 * strength), base, base.mix(.black, 0.42 * strength)],
               CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.minY))
    }

    /// Thin highlight along the top-left edge of a shape.
    static func rim(_ ctx: CGContext, _ p: CGPath, _ alpha: CGFloat = 0.35) {
        let b = p.boundingBox
        ctx.saveGState()
        ctx.addPath(p)
        ctx.clip()
        ctx.addPath(p)
        ctx.setLineWidth(2)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        if let g = CGGradient(colorsSpace: srgb, colors: [NSColor.white.withAlphaComponent(alpha).cgColor,
                                                          NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: nil) {
            ctx.drawLinearGradient(g, start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.midX, y: b.midY), options: [])
        }
        ctx.restoreGState()
    }

    static let concrete = NSColor.rgb(0.47, 0.48, 0.46)
    static let steel = NSColor.rgb(0.36, 0.38, 0.41)
    static let gunmetal = NSColor.rgb(0.22, 0.23, 0.25)

    static func metal(_ team: Team) -> NSColor { steel.mix(team.color, 0.38) }

    // MARK: - Generic soft shapes

    /// White radial falloff; tint with `color` + `colorBlendFactor` and use additive blending for glows.
    static var glow: SKTexture {
        texture("glow", size: CGSize(width: 64, height: 64), scale: 1) { ctx in
            radial(ctx, nil, [NSColor.white, NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0)], .zero, 32)
        }
    }

    static var shadow: SKTexture {
        texture("shadow", size: CGSize(width: 64, height: 64), scale: 1) { ctx in
            radial(ctx, nil, [NSColor(white: 0, alpha: 0.55), NSColor(white: 0, alpha: 0.35), NSColor(white: 0, alpha: 0)], .zero, 32)
        }
    }

    /// Soft irregular blob for smoke particles, dirt stamps and scorch marks.
    static var blob: SKTexture {
        texture("blob", size: CGSize(width: 64, height: 64), scale: 1) { ctx in
            var rng = SeededRNG(7)
            for _ in 0..<9 {
                let c = CGPoint(x: CGFloat.random(in: -10...10, using: &rng), y: CGFloat.random(in: -10...10, using: &rng))
                radial(ctx, nil, [NSColor(white: 1, alpha: 0.35), NSColor(white: 1, alpha: 0)], c, CGFloat.random(in: 14...22, using: &rng))
            }
        }
    }

    static var ring: SKTexture {
        texture("ring", size: CGSize(width: 64, height: 64)) { ctx in
            let p = circle(.zero, 28)
            stroke(ctx, p, NSColor(white: 1, alpha: 0.25), 6)
            stroke(ctx, p, .white, 2.2)
        }
    }

    static var squareRing: SKTexture {
        texture("squareRing", size: CGSize(width: 64, height: 64)) { ctx in
            let p = rr(box(-29, -29, 58, 58), 7)
            stroke(ctx, p, NSColor(white: 1, alpha: 0.25), 5)
            stroke(ctx, p, .white, 1.6)
        }
    }

    // MARK: - Units

    static func unitSize(_ k: UnitKind) -> CGSize {
        switch k {
        case .worker: return CGSize(width: 34, height: 34)
        case .marine: return CGSize(width: 38, height: 36)
        case .tank: return CGSize(width: 54, height: 42)
        case .sniper: return CGSize(width: 44, height: 36)
        }
    }

    static func unit(_ k: UnitKind, _ team: Team) -> SKTexture {
        texture("unit-\(k)-\(team.rawValue)", size: unitSize(k)) { ctx in
            switch k {
            case .worker: drawWorker(ctx, team)
            case .marine: drawMarine(ctx, team)
            case .tank: drawTankHull(ctx, team)
            case .sniper: drawSniper(ctx, team)
            }
        }
    }

    private static func drawWorker(_ ctx: CGContext, _ team: Team) {
        let c = team.color
        let pack = rr(box(-12, -6, 8, 12), 2)
        lit(ctx, pack, .rgb(0.40, 0.40, 0.38))
        stroke(ctx, pack, NSColor(white: 0, alpha: 0.5), 0.8)
        // Drill arm
        let arm = rr(box(2, -7.5, 10, 4), 1.5)
        lit(ctx, arm, steel)
        fill(ctx, poly([CGPoint(x: 11.5, y: -8), CGPoint(x: 17, y: -5.5), CGPoint(x: 11.5, y: -3)]), Palette.amber)
        let body = ellipse(box(-7.5, -9.5, 15, 19))
        lit(ctx, body, c)
        rim(ctx, body)
        stroke(ctx, body, c.mix(.black, 0.5), 1)
        let helm = circle(CGPoint(x: 0.5, y: 0), 5.2)
        lit(ctx, helm, Palette.amber)
        stroke(ctx, helm, Palette.amber.mix(.black, 0.5), 0.9)
        fill(ctx, ellipse(box(-2.5, 0.8, 3.5, 2.2)), NSColor(white: 1, alpha: 0.6))
    }

    private static func drawMarine(_ ctx: CGContext, _ team: Team) {
        let c = team.color
        // Rifle
        let rifle = rr(box(-1, -6.2, 19, 3), 1)
        fill(ctx, rifle, gunmetal)
        fill(ctx, rr(box(16.5, -6.6, 3, 3.8), 0.8), .rgb(0.12, 0.12, 0.13))
        fill(ctx, rr(box(4, -7.5, 5, 2), 0.5), .rgb(0.35, 0.3, 0.22))
        let body = ellipse(box(-7, -10.5, 14, 21))
        lit(ctx, body, c)
        rim(ctx, body)
        stroke(ctx, body, c.mix(.black, 0.55), 1)
        for y: CGFloat in [7.8, -7.8] {
            let pad = circle(CGPoint(x: -0.5, y: y), 3.4)
            lit(ctx, pad, c.mix(.black, 0.3))
            stroke(ctx, pad, c.mix(.black, 0.6), 0.7)
        }
        let armR = ellipse(box(3, -7, 6, 4.5))
        lit(ctx, armR, c.mix(.black, 0.15))
        let helm = circle(.zero, 5.4)
        lit(ctx, helm, c.mix(.black, 0.35))
        stroke(ctx, helm, NSColor(white: 0, alpha: 0.6), 0.8)
        fill(ctx, rr(box(2.2, -2.8, 3, 5.6), 1.2), .rgb(0.45, 0.95, 1.0))
        fill(ctx, ellipse(box(-3, 0.8, 3.2, 2)), NSColor(white: 1, alpha: 0.45))
    }

    /// Lankier than a Ranger, with a long barrel, a bipod and a cold scope glint.
    private static func drawSniper(_ ctx: CGContext, _ team: Team) {
        let c = team.color
        let barrel = rr(box(-1, -5.6, 25, 2.6), 0.8)
        lit(ctx, barrel, gunmetal)
        stroke(ctx, barrel, NSColor(white: 0, alpha: 0.5), 0.6)
        fill(ctx, rr(box(22, -6.2, 3.4, 3.8), 0.8), .rgb(0.1, 0.1, 0.11))      // muzzle brake
        lines(ctx, [(CGPoint(x: 16, y: -4.3), CGPoint(x: 13, y: -1.2)),
                    (CGPoint(x: 16, y: -4.3), CGPoint(x: 19, y: -1.2))], .rgb(0.14, 0.14, 0.15), 1.2)   // bipod
        let scope = rr(box(5, -8.4, 8, 2.6), 1)
        lit(ctx, scope, .rgb(0.2, 0.21, 0.23))
        fill(ctx, circle(CGPoint(x: 12.4, y: -7.1), 1.5), .rgb(0.55, 0.95, 1.0))
        let body = ellipse(box(-7, -9.5, 14, 19))
        lit(ctx, body, c.mix(.black, 0.12))
        rim(ctx, body)
        stroke(ctx, body, c.mix(.black, 0.6), 1)
        let cloak = poly([CGPoint(x: -7, y: -9), CGPoint(x: -12.5, y: -4),
                          CGPoint(x: -13.5, y: 4), CGPoint(x: -7, y: 9)])      // ghillie drape
        fill(ctx, cloak, c.mix(.black, 0.45).withAlphaComponent(0.85))
        stroke(ctx, cloak, NSColor(white: 0, alpha: 0.45), 0.7)
        let helm = circle(CGPoint(x: 0.4, y: 0), 5.0)
        lit(ctx, helm, c.mix(.black, 0.45))
        stroke(ctx, helm, NSColor(white: 0, alpha: 0.6), 0.8)
        fill(ctx, rr(box(2.0, -2.4, 2.8, 4.8), 1.1), .rgb(0.78, 0.95, 1.0))
        fill(ctx, ellipse(box(-3, 0.8, 3.0, 1.9)), NSColor(white: 1, alpha: 0.4))
    }

    private static func drawTankHull(_ ctx: CGContext, _ team: Team) {
        for y: CGFloat in [-14, 14] {
            let tr = rr(box(-24, y - 5.5, 48, 11), 4)
            lit(ctx, tr, .rgb(0.2, 0.2, 0.21))
            var segs: [(CGPoint, CGPoint)] = []
            var x: CGFloat = -21
            while x < 22 {
                segs.append((CGPoint(x: x, y: y - 4.8), CGPoint(x: x, y: y + 4.8)))
                x += 3.5
            }
            lines(ctx, segs, NSColor(white: 1, alpha: 0.13), 1)
            stroke(ctx, tr, NSColor(white: 0, alpha: 0.6), 1)
        }
        let hull = rr(box(-20, -11, 40, 22), 4)
        lit(ctx, hull, metal(team))
        rim(ctx, hull, 0.45)
        stroke(ctx, hull, NSColor(white: 0, alpha: 0.6), 1.1)
        fill(ctx, poly([CGPoint(x: 13, y: -10), CGPoint(x: 20, y: -7), CGPoint(x: 20, y: 7), CGPoint(x: 13, y: 10)]),
             NSColor(white: 1, alpha: 0.12))
        var grill: [(CGPoint, CGPoint)] = []
        var gy: CGFloat = -6
        while gy <= 6 {
            grill.append((CGPoint(x: -18, y: gy), CGPoint(x: -12, y: gy)))
            gy += 2.4
        }
        lines(ctx, grill, NSColor(white: 0, alpha: 0.45), 1)
        fill(ctx, rr(box(-9, -11, 3.5, 22), 0), team.color.withAlphaComponent(0.8))
    }

    static let turretSize = CGSize(width: 68, height: 30)

    static func tankTurret(_ team: Team) -> SKTexture {
        texture("turret-\(team.rawValue)", size: turretSize) { ctx in
            let barrel = rr(box(4, -2.7, 25, 5.4), 1.5)
            linear(ctx, barrel, [.rgb(0.62, 0.64, 0.66), .rgb(0.3, 0.31, 0.33)], CGPoint(x: 0, y: 3), CGPoint(x: 0, y: -3))
            let brake = rr(box(27, -4, 6, 8), 1.5)
            lit(ctx, brake, gunmetal)
            let dome = rr(box(-12, -9.5, 21, 19), 7)
            lit(ctx, dome, team.color.mix(steel, 0.25))
            rim(ctx, dome, 0.5)
            stroke(ctx, dome, NSColor(white: 0, alpha: 0.6), 1)
            let hatch = circle(CGPoint(x: -3.5, y: 2.5), 3.6)
            lit(ctx, hatch, team.color.mix(.black, 0.45))
            stroke(ctx, hatch, NSColor(white: 0, alpha: 0.5), 0.7)
        }
    }

    // MARK: - Buildings

    static func buildingCanvas(_ k: BuildingKind) -> CGSize {
        let h = k.stats.half
        return CGSize(width: h * 2 + 28, height: h * 2 + 28)
    }

    static func building(_ k: BuildingKind, _ team: Team) -> SKTexture {
        texture("bld-\(k)-\(team.rawValue)", size: buildingCanvas(k)) { ctx in
            let h = k.stats.half
            if k != .turret { foundation(ctx, h) }
            extrude(ctx, k, h, team)
            switch k {
            case .hq: drawHQ(ctx, h, team)
            case .depot: drawDepot(ctx, h, team)
            case .barracks: drawBarracks(ctx, h, team)
            case .factory: drawFactory(ctx, h, team)
            case .turret: drawTurretBase(ctx, h, team)
            case .radar: drawRadar(ctx, h, team)
            }
            roofKit(ctx, k, h, team)
        }
    }

    static func octagon(_ r: CGFloat) -> CGPath {
        poly((0..<8).map { i in
            let a = CGFloat(i) * .pi / 4 + .pi / 8
            return CGPoint(x: cos(a) * r, y: sin(a) * r)
        })
    }

    /// The outline of a building's body, used for its walls, shadow and roof trim.
    private static func silhouette(_ k: BuildingKind, _ h: CGFloat) -> CGPath {
        switch k {
        case .hq: return octagon(h * 0.98)
        case .turret: return circle(.zero, h * 0.8)
        case .radar: return octagon(h * 0.92)
        case .depot: return rr(box(-h * 0.86, -h * 0.87, h * 1.72, h * 1.74), 4)
        case .barracks: return rr(box(-h * 0.9, -h * 0.62, h * 1.8, h * 1.52), 4)
        case .factory: return rr(box(-h * 0.92, -h * 0.66, h * 1.84, h * 1.5), 4)
        }
    }

    /// Fakes height: a ground shadow plus stacked wall slices offset towards the bottom right.
    private static func extrude(_ ctx: CGContext, _ k: BuildingKind, _ h: CGFloat, _ team: Team) {
        let body = silhouette(k, h)
        ctx.saveGState()
        ctx.translateBy(x: 7, y: -9)
        fill(ctx, body, NSColor(white: 0, alpha: 0.34))
        ctx.restoreGState()
        let depth = [BuildingKind.hq, .factory, .barracks].contains(k) ? 7 : 5
        for i in stride(from: depth, through: 1, by: -1) {
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(i) * 0.55, y: -CGFloat(i) * 0.7)
            fill(ctx, body, metal(team).mix(.black, 0.55 + 0.04 * CGFloat(i)))
            ctx.restoreGState()
        }
    }

    /// Shared roof clutter: vents, hatches, rivets, weather streaks and an antenna beacon.
    private static func roofKit(_ ctx: CGContext, _ k: BuildingKind, _ h: CGFloat, _ team: Team) {
        var rng = SeededRNG(UInt64((NetProtocol.buildingKinds.firstIndex(of: k) ?? 0) + 31))
        let body = silhouette(k, h)
        stroke(ctx, body, NSColor(white: 0, alpha: 0.5), 1.2)

        func vent(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ hh: CGFloat) {
            let v = rr(box(x - w / 2, y - hh / 2, w, hh), 2)
            lit(ctx, v, .rgb(0.34, 0.35, 0.37))
            stroke(ctx, v, NSColor(white: 0, alpha: 0.55), 1)
            var slats: [(CGPoint, CGPoint)] = []
            var yy = y - hh / 2 + 2.5
            while yy < y + hh / 2 - 1 {
                slats.append((CGPoint(x: x - w / 2 + 2, y: yy), CGPoint(x: x + w / 2 - 2, y: yy)))
                yy += 2.6
            }
            lines(ctx, slats, NSColor(white: 0, alpha: 0.45), 1)
        }
        func mast(_ x: CGFloat, _ y: CGFloat, _ length: CGFloat) {
            lines(ctx, [(CGPoint(x: x, y: y), CGPoint(x: x + length * 0.5, y: y + length * 0.72))], .rgb(0.1, 0.1, 0.11), 2)
            fill(ctx, circle(CGPoint(x: x, y: y), 2.6), .rgb(0.26, 0.27, 0.29))
            let tip = CGPoint(x: x + length * 0.5, y: y + length * 0.72)
            fill(ctx, circle(tip, 2.6), team.lightColor)
            fill(ctx, circle(tip, 1.2), NSColor(white: 1, alpha: 0.9))
        }
        switch k {
        case .hq:
            vent(-0.62 * h, -0.58 * h, h * 0.3, h * 0.2)
            vent(0.62 * h, -0.58 * h, h * 0.3, h * 0.2)
            mast(-h * 0.66, h * 0.6, h * 0.34)
        case .barracks:
            vent(-h * 0.62, -h * 0.34, h * 0.34, h * 0.22)
            vent(h * 0.62, -h * 0.34, h * 0.34, h * 0.22)
            mast(h * 0.7, h * 0.5, h * 0.3)
            for sx in [-0.5, 0.5] as [CGFloat] {
                lines(ctx, [(CGPoint(x: sx * h - 9, y: h * 0.34), CGPoint(x: sx * h + 9, y: h * 0.34))],
                      Palette.amber.withAlphaComponent(0.7), 1.5)
            }
        case .factory:
            vent(-h * 0.6, h * 0.1, h * 0.36, h * 0.26)
            let hatch = rr(box(h * 0.2, -h * 0.2, h * 0.38, h * 0.38), 3)
            lit(ctx, hatch, .rgb(0.3, 0.31, 0.33))
            stroke(ctx, hatch, NSColor(white: 0, alpha: 0.5), 1)
            fill(ctx, circle(CGPoint(x: h * 0.39, y: -h * 0.01), h * 0.07), .rgb(0.5, 0.5, 0.52))
        case .depot:
            for sy in [-0.62, 0.0, 0.62] as [CGFloat] {
                fill(ctx, rr(box(-h * 0.2, sy * h - 2, h * 0.4, 4), 2), .rgb(0.1, 0.1, 0.11))
            }
            mast(-h * 0.72, -h * 0.72, h * 0.22)
        case .turret, .radar:
            break
        }

        let n = k == .turret ? 12 : 18
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            let f: CGFloat = k == .hq ? 0.8 : 0.74
            fill(ctx, circle(CGPoint(x: cos(a) * h * f, y: sin(a) * h * f), 1.1), NSColor(white: 1, alpha: 0.25))
        }
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        for _ in 0..<7 {
            let x = CGFloat.random(in: (-h * 0.8)...(h * 0.8), using: &rng)
            let y0 = CGFloat.random(in: (-h * 0.2)...(h * 0.7), using: &rng)
            let dx = CGFloat.random(in: -2...2, using: &rng), dy = CGFloat.random(in: (h * 0.3)...(h * 0.8), using: &rng)
            lines(ctx, [(CGPoint(x: x, y: y0), CGPoint(x: x + dx, y: y0 - dy))], NSColor(white: 0, alpha: 0.12),
                  CGFloat.random(in: 1.5...4, using: &rng))
        }
        ctx.restoreGState()
    }

    private static func foundation(_ ctx: CGContext, _ h: CGFloat) {
        let pad = rr(box(-h - 5, -h - 5, 2 * h + 10, 2 * h + 10), 9)
        lit(ctx, pad, concrete, 0.7)
        stroke(ctx, pad, NSColor(white: 0, alpha: 0.45), 1.2)
        // Hazard corners
        for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] as [(CGFloat, CGFloat)] {
            let c = CGPoint(x: sx * (h + 1), y: sy * (h + 1))
            fill(ctx, poly([c, CGPoint(x: c.x - sx * 9, y: c.y), CGPoint(x: c.x, y: c.y - sy * 9)]), Palette.amber.withAlphaComponent(0.8))
        }
    }

    private static func drawHQ(_ ctx: CGContext, _ h: CGFloat, _ team: Team) {
        let outer = octagon(h * 0.98)
        lit(ctx, outer, metal(team))
        rim(ctx, outer, 0.4)
        stroke(ctx, outer, team.color, 2)
        var seams: [(CGPoint, CGPoint)] = []
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            seams.append((CGPoint(x: cos(a) * h * 0.66, y: sin(a) * h * 0.66), CGPoint(x: cos(a) * h * 0.9, y: sin(a) * h * 0.9)))
        }
        lines(ctx, seams, NSColor(white: 0, alpha: 0.3), 1.2)
        let inner = octagon(h * 0.66)
        lit(ctx, inner, metal(team).mix(.white, 0.12))
        stroke(ctx, inner, NSColor(white: 0, alpha: 0.45), 1.2)
        // Landing pads on the diagonals
        for i in 0..<4 {
            let a = CGFloat(i) * .pi / 2 + .pi / 4
            let c = CGPoint(x: cos(a) * h * 0.72, y: sin(a) * h * 0.72)
            let pad = circle(c, h * 0.15)
            fill(ctx, pad, .rgb(0.16, 0.17, 0.18))
            stroke(ctx, pad, Palette.amber, 1.5)
        }
        let dome = circle(.zero, h * 0.38)
        radial(ctx, dome, [team.lightColor, team.color, team.color.mix(.black, 0.45)], CGPoint(x: -h * 0.12, y: h * 0.12), h * 0.5)
        stroke(ctx, dome, NSColor(white: 1, alpha: 0.55), 1.5)
        fill(ctx, ellipse(box(-h * 0.22, h * 0.08, h * 0.2, h * 0.12)), NSColor(white: 1, alpha: 0.45))
        for i in 0..<16 {
            let a = CGFloat(i) * .pi / 8
            fill(ctx, circle(CGPoint(x: cos(a) * h * 0.83, y: sin(a) * h * 0.83), 1.6),
                 i % 2 == 0 ? NSColor(white: 1, alpha: 0.9) : team.lightColor)
        }
    }

    static var dish: SKTexture {
        texture("dish", size: CGSize(width: 44, height: 24)) { ctx in
            fill(ctx, rr(box(0, -1.5, 14, 3), 1), .rgb(0.8, 0.82, 0.85))
            let d = ellipse(box(12, -9, 8, 18))
            lit(ctx, d, .rgb(0.85, 0.87, 0.9))
            stroke(ctx, d, NSColor(white: 0, alpha: 0.4), 0.8)
        }
    }

    private static func drawDepot(_ ctx: CGContext, _ h: CGFloat, _ team: Team) {
        for i in 0..<3 {
            let y = -h * 0.62 + CGFloat(i) * h * 0.62
            let r = box(-h * 0.86, y - h * 0.25, h * 1.72, h * 0.5)
            let c = rr(r, 3)
            lit(ctx, c, i == 1 ? team.color.mix(steel, 0.35) : metal(team))
            var ribs: [(CGPoint, CGPoint)] = []
            var x = r.minX + 7
            while x < r.maxX - 5 {
                ribs.append((CGPoint(x: x, y: r.minY + 2), CGPoint(x: x, y: r.maxY - 2)))
                x += 5
            }
            lines(ctx, ribs, NSColor(white: 0, alpha: 0.2), 1)
            fill(ctx, rr(box(r.minX, r.minY, 5, r.height), 2), NSColor(white: 0, alpha: 0.3))
            fill(ctx, rr(box(r.maxX - 5, r.minY, 5, r.height), 2), NSColor(white: 0, alpha: 0.3))
            rim(ctx, c)
            stroke(ctx, c, NSColor(white: 0, alpha: 0.5), 1)
        }
    }

    private static func drawBarracks(_ ctx: CGContext, _ h: CGFloat, _ team: Team) {
        let m = metal(team)
        let top = box(-h * 0.9, h * 0.12, h * 1.8, h * 0.78)
        let bottom = box(-h * 0.9, -h * 0.62, h * 1.8, h * 0.74)
        linear(ctx, rr(top, 4), [m.mix(.white, 0.28), m.mix(.white, 0.08)], CGPoint(x: 0, y: top.maxY), CGPoint(x: 0, y: top.minY))
        linear(ctx, rr(bottom, 4), [m.mix(.black, 0.15), m.mix(.black, 0.4)], CGPoint(x: 0, y: bottom.maxY), CGPoint(x: 0, y: bottom.minY))
        var seams: [(CGPoint, CGPoint)] = []
        var x = -h * 0.9 + 12
        while x < h * 0.9 {
            seams.append((CGPoint(x: x, y: top.minY - bottom.height + 2), CGPoint(x: x, y: top.maxY - 2)))
            x += 12
        }
        lines(ctx, seams, NSColor(white: 0, alpha: 0.14), 1)
        lines(ctx, [(CGPoint(x: -h * 0.9, y: h * 0.12), CGPoint(x: h * 0.9, y: h * 0.12))], NSColor(white: 1, alpha: 0.4), 2)
        let whole = rr(box(-h * 0.9, -h * 0.62, h * 1.8, h * 1.52), 4)
        stroke(ctx, whole, NSColor(white: 0, alpha: 0.55), 1.2)
        for sx: CGFloat in [-0.5, 0.5] {
            let v = rr(box(sx * h - 6, h * 0.42, 12, 10), 2)
            fill(ctx, v, .rgb(0.15, 0.16, 0.17))
            lines(ctx, [(CGPoint(x: sx * h - 4, y: h * 0.47), CGPoint(x: sx * h + 4, y: h * 0.47))], NSColor(white: 1, alpha: 0.2), 1)
        }
        let door = rr(box(-h * 0.24, -h * 0.66, h * 0.48, h * 0.2), 2)
        fill(ctx, door, .rgb(0.1, 0.1, 0.11))
        fill(ctx, rr(box(-h * 0.2, -h * 0.5, h * 0.4, 2.5), 1), team.lightColor)
        var rng = SeededRNG(3)
        for side: CGFloat in [-1, 1] {
            var sx = side * h * 0.34
            while abs(sx) < h * 0.88 {
                let bag = ellipse(box(sx - 5, -h * 0.86 + CGFloat.random(in: -1...1, using: &rng), 10, 6))
                lit(ctx, bag, .rgb(0.62, 0.55, 0.4))
                sx += side * 9
            }
        }
    }

    static let chimneyOffsets: [(CGFloat, CGFloat)] = [(0.58, 0.55), (0.28, 0.62)]

    private static func drawFactory(_ ctx: CGContext, _ h: CGFloat, _ team: Team) {
        let m = metal(team)
        let hall = box(-h * 0.92, -h * 0.66, h * 1.84, h * 1.5)
        let bandW = hall.width / 4
        for i in 0..<4 {
            let r = box(hall.minX + CGFloat(i) * bandW, hall.minY, bandW, hall.height)
            linear(ctx, rr(r, 0), [m.mix(.white, 0.3), m.mix(.black, 0.35)], CGPoint(x: r.minX, y: 0), CGPoint(x: r.maxX, y: 0))
            let glass = box(r.maxX - bandW * 0.22, r.minY + 4, bandW * 0.18, r.height - 8)
            linear(ctx, rr(glass, 1), [.rgb(0.45, 0.75, 0.85), .rgb(0.12, 0.22, 0.3)], CGPoint(x: 0, y: glass.maxY), CGPoint(x: 0, y: glass.minY))
        }
        stroke(ctx, rr(hall, 4), NSColor(white: 0, alpha: 0.55), 1.3)
        fill(ctx, rr(box(hall.minX, hall.maxY - 5, hall.width, 5), 1), team.color)
        for (ox, oy) in chimneyOffsets {
            let c = CGPoint(x: ox * h, y: oy * h)
            let r = h * (ox > 0.5 ? 0.14 : 0.11)
            let stack = circle(c, r)
            lit(ctx, stack, .rgb(0.45, 0.43, 0.4))
            stroke(ctx, stack, NSColor(white: 0, alpha: 0.5), 1)
            fill(ctx, circle(c, r * 0.6), .rgb(0.05, 0.05, 0.05))
        }
        let door = box(-h * 0.38, -h * 0.8, h * 0.76, h * 0.2)
        fill(ctx, rr(door, 2), .rgb(0.12, 0.12, 0.13))
        ctx.saveGState()
        ctx.addPath(rr(box(door.minX, door.maxY - 5, door.width, 5), 0))
        ctx.clip()
        fill(ctx, rr(box(door.minX, door.maxY - 5, door.width, 5), 0), Palette.amber)
        var stripes: [(CGPoint, CGPoint)] = []
        var x = door.minX
        while x < door.maxX {
            stripes.append((CGPoint(x: x, y: door.maxY - 6), CGPoint(x: x + 6, y: door.maxY + 1)))
            x += 7
        }
        lines(ctx, stripes, .black, 2.5)
        ctx.restoreGState()
    }

    private static func drawTurretBase(_ ctx: CGContext, _ h: CGFloat, _ team: Team) {
        let base = circle(.zero, h + 2)
        lit(ctx, base, concrete, 0.8)
        stroke(ctx, base, NSColor(white: 0, alpha: 0.5), 1.2)
        for i in 0..<10 {
            let a = CGFloat(i) * .pi / 5
            fill(ctx, circle(CGPoint(x: cos(a) * h * 0.86, y: sin(a) * h * 0.86), 1.8), .rgb(0.2, 0.2, 0.2))
        }
        let ring = circle(.zero, h * 0.66)
        lit(ctx, ring, team.color.mix(.black, 0.35))
        stroke(ctx, ring, team.color, 1.5)
    }

    /// Ringed concrete pad with a lit mounting collar; the dish itself is a separate sprite.
    private static func drawRadar(_ ctx: CGContext, _ h: CGFloat, _ team: Team) {
        let pad = octagon(h * 0.92)
        lit(ctx, pad, concrete, 0.8)
        stroke(ctx, pad, NSColor(white: 0, alpha: 0.5), 1.2)
        for i in 0..<3 {
            let r = h * (0.72 - CGFloat(i) * 0.16)
            stroke(ctx, circle(.zero, r), team.color.withAlphaComponent(0.35 - CGFloat(i) * 0.07), 1.1)
        }
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            fill(ctx, circle(CGPoint(x: cos(a) * h * 0.8, y: sin(a) * h * 0.8), 1.7), .rgb(0.2, 0.2, 0.2))
        }
        let collar = circle(.zero, h * 0.2)
        lit(ctx, collar, team.color.mix(steel, 0.35))
        stroke(ctx, collar, team.color, 1.3)
        let boxNode = rr(box(-h * 0.78, -h * 0.18, h * 0.3, h * 0.36), 2)      // console, so it does not read as a turret
        lit(ctx, boxNode, .rgb(0.3, 0.31, 0.33))
        stroke(ctx, boxNode, NSColor(white: 0, alpha: 0.55), 0.9)
        fill(ctx, circle(CGPoint(x: -h * 0.63, y: 0), 1.6), .rgb(0.45, 0.95, 0.5))
    }

    /// The sweeping dish: a lattice parabola on a short mast, drawn on top of the station.
    static func radarDish(_ team: Team) -> SKTexture {
        texture("rdish-\(team.rawValue)", size: CGSize(width: 84, height: 50)) { ctx in
            let arm = rr(box(-3, -2.6, 14, 5.2), 1.6)
            lit(ctx, arm, steel)
            stroke(ctx, arm, NSColor(white: 0, alpha: 0.5), 0.8)
            let back = ellipse(box(9, -19, 9, 38))
            fill(ctx, back, team.color.mix(.black, 0.25).withAlphaComponent(0.7))
            let face = ellipse(box(13, -20, 13, 40))
            lit(ctx, face, .rgb(0.88, 0.90, 0.92))
            stroke(ctx, face, NSColor(white: 0, alpha: 0.45), 1.1)
            lines(ctx, (0..<6).map { i in
                let y = -15 + CGFloat(i) * 6
                return (CGPoint(x: 14, y: y), CGPoint(x: 25, y: y))
            }, NSColor(white: 0, alpha: 0.16), 1)
            lines(ctx, [(CGPoint(x: 19, y: -19), CGPoint(x: 19, y: 19))], NSColor(white: 0, alpha: 0.16), 1)
            fill(ctx, rr(box(24, -2, 9, 4), 1.2), gunmetal)                    // feed horn on its boom
            fill(ctx, circle(CGPoint(x: 33, y: 0), 2.6), team.lightColor)
            fill(ctx, circle(.zero, 4.0), .rgb(0.26, 0.27, 0.29))
        }
    }

    static func turretGun(_ team: Team) -> SKTexture {
        texture("tgun-\(team.rawValue)", size: CGSize(width: 76, height: 36)) { ctx in
            for y: CGFloat in [-4.5, 4.5] {
                let b = rr(box(4, y - 2.2, 30, 4.4), 1.2)
                linear(ctx, b, [.rgb(0.7, 0.72, 0.74), .rgb(0.3, 0.31, 0.33)], CGPoint(x: 0, y: y + 2), CGPoint(x: 0, y: y - 2))
                fill(ctx, rr(box(31, y - 2.8, 4, 5.6), 1), gunmetal)
            }
            let body = rr(box(-13, -11, 25, 22), 7)
            lit(ctx, body, team.color.mix(steel, 0.25))
            rim(ctx, body, 0.5)
            stroke(ctx, body, NSColor(white: 0, alpha: 0.6), 1)
            fill(ctx, circle(CGPoint(x: 5, y: 0), 2.2), .rgb(1, 0.35, 0.3))
        }
    }

    static func scaffold(_ half: CGFloat) -> SKTexture {
        texture("scaffold-\(Int(half))", size: CGSize(width: half * 2 + 10, height: half * 2 + 10)) { ctx in
            let r = box(-half, -half, half * 2, half * 2)
            ctx.saveGState()
            ctx.addPath(rr(r, 6))
            ctx.clip()
            var segs: [(CGPoint, CGPoint)] = []
            var k = -2 * half
            while k < 2 * half {
                segs.append((CGPoint(x: -half, y: -half + k), CGPoint(x: half, y: half + k)))
                k += 18
            }
            lines(ctx, segs, Palette.amber.withAlphaComponent(0.55), 2)
            ctx.restoreGState()
            ctx.setLineDash(phase: 0, lengths: [8, 5])
            stroke(ctx, rr(r, 6), Palette.amber, 2.5)
        }
    }

    // MARK: - Crystals & nature

    static func crystal(_ variant: Int) -> SKTexture {
        texture("crystal-\(variant)", size: CGSize(width: 54, height: 60)) { ctx in
            var rng = SeededRNG(UInt64(100 + variant))
            var shards: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, tilt: CGFloat)] = []
            for _ in 0..<5 {
                shards.append((CGFloat.random(in: -13...13, using: &rng), CGFloat.random(in: -18 ... -6, using: &rng),
                               CGFloat.random(in: 7...12, using: &rng), CGFloat.random(in: 16...34, using: &rng),
                               CGFloat.random(in: -5...5, using: &rng)))
            }
            // Back to front
            for s in shards.sorted(by: { $0.y > $1.y }) {
                let bl = CGPoint(x: s.x - s.w / 2, y: s.y)
                let bm = CGPoint(x: s.x, y: s.y - s.w * 0.3)
                let br = CGPoint(x: s.x + s.w / 2, y: s.y)
                let tl = CGPoint(x: s.x - s.w / 2 + s.tilt, y: s.y + s.h * 0.78)
                let tr = CGPoint(x: s.x + s.w / 2 + s.tilt, y: s.y + s.h * 0.78)
                let tip = CGPoint(x: s.x + s.tilt, y: s.y + s.h)
                let left = poly([bl, bm, tip, tl])
                let right = poly([bm, br, tr, tip])
                linear(ctx, left, [.rgb(0.75, 1, 1), .rgb(0.3, 0.85, 1)], tip, bm)
                linear(ctx, right, [.rgb(0.25, 0.7, 0.95), .rgb(0.08, 0.35, 0.6)], tip, bm)
                stroke(ctx, poly([bl, bm, br, tr, tip, tl]), NSColor(white: 1, alpha: 0.6), 0.8)
                lines(ctx, [(bm, tip)], NSColor(white: 1, alpha: 0.5), 0.8)
                lines(ctx, [(CGPoint(x: bl.x + 1.5, y: bl.y + 2), CGPoint(x: tl.x + 1.5, y: tl.y - 2))], NSColor(white: 1, alpha: 0.7), 1)
            }
        }
    }

    static func tree(_ variant: Int) -> SKTexture {
        texture("tree-\(variant)", size: CGSize(width: 84, height: 84)) { ctx in
            var rng = SeededRNG(UInt64(200 + variant))
            let base = [NSColor.rgb(0.14, 0.30, 0.13), .rgb(0.18, 0.33, 0.12), .rgb(0.12, 0.26, 0.16)][variant % 3]
            var blobs: [(CGPoint, CGFloat)] = [(.zero, 20)]
            for _ in 0..<6 {
                let a = CGFloat.random(in: 0...(2 * .pi), using: &rng)
                let d = CGFloat.random(in: 9...17, using: &rng)
                blobs.append((CGPoint(x: cos(a) * d, y: sin(a) * d), CGFloat.random(in: 11...17, using: &rng)))
            }
            for (c, r) in blobs {
                fill(ctx, circle(c, r + 1.5), base.mix(.black, 0.55))
            }
            for (c, r) in blobs.sorted(by: { $0.0.y - $0.0.x < $1.0.y - $1.0.x }) {
                radial(ctx, circle(c, r), [base.mix(.white, 0.28), base, base.mix(.black, 0.35)],
                       CGPoint(x: c.x - r * 0.35, y: c.y + r * 0.35), r * 1.3)
            }
            for _ in 0..<14 {
                let p = CGPoint(x: CGFloat.random(in: -22...16, using: &rng), y: CGFloat.random(in: -14...22, using: &rng))
                fill(ctx, circle(p, CGFloat.random(in: 1.5...3.5, using: &rng)), base.mix(.white, 0.35).withAlphaComponent(0.5))
            }
        }
    }

    static func rock(_ variant: Int) -> SKTexture {
        texture("rock-\(variant)", size: CGSize(width: 44, height: 36)) { ctx in
            var rng = SeededRNG(UInt64(300 + variant))
            let n = 7
            let pts = (0..<n).map { i -> CGPoint in
                let a = CGFloat(i) / CGFloat(n) * .pi * 2
                let r = CGFloat.random(in: 11...16, using: &rng)
                return CGPoint(x: cos(a) * r * 1.2, y: sin(a) * r * 0.9)
            }
            let p = poly(pts)
            lit(ctx, p, .rgb(0.5, 0.5, 0.47))
            lines(ctx, [(pts[1], CGPoint(x: -2, y: 1)), (CGPoint(x: -2, y: 1), pts[4])], NSColor(white: 0, alpha: 0.25), 1)
            stroke(ctx, p, NSColor(white: 0, alpha: 0.45), 1)
        }
    }

    static var tuft: SKTexture {
        texture("tuft", size: CGSize(width: 16, height: 16)) { ctx in
            var rng = SeededRNG(9)
            var segs: [(CGPoint, CGPoint)] = []
            for _ in 0..<7 {
                let x = CGFloat.random(in: -4...4, using: &rng)
                segs.append((CGPoint(x: x, y: -5), CGPoint(x: x + CGFloat.random(in: -4...4, using: &rng), y: CGFloat.random(in: 1...7, using: &rng))))
            }
            lines(ctx, segs, .rgb(0.42, 0.55, 0.26), 1.1)
        }
    }

    static var scorch: SKTexture {
        texture("scorch", size: CGSize(width: 64, height: 64), scale: 1) { ctx in
            var rng = SeededRNG(11)
            radial(ctx, nil, [NSColor(white: 0.02, alpha: 0.6), NSColor(white: 0.05, alpha: 0.3), NSColor(white: 0, alpha: 0)], .zero, 30)
            for _ in 0..<10 {
                let a = CGFloat.random(in: 0...(2 * .pi), using: &rng)
                let d = CGFloat.random(in: 10...24, using: &rng)
                radial(ctx, nil, [NSColor(white: 0.05, alpha: 0.35), NSColor(white: 0, alpha: 0)],
                       CGPoint(x: cos(a) * d, y: sin(a) * d), CGFloat.random(in: 4...9, using: &rng))
            }
        }
    }

    static var rubble: SKTexture {
        texture("rubble", size: CGSize(width: 96, height: 96)) { ctx in
            var rng = SeededRNG(13)
            radial(ctx, nil, [NSColor(white: 0.03, alpha: 0.65), NSColor(white: 0.03, alpha: 0.4), NSColor(white: 0, alpha: 0)], .zero, 46)
            for _ in 0..<26 {
                let c = CGPoint(x: CGFloat.random(in: -34...34, using: &rng), y: CGFloat.random(in: -34...34, using: &rng))
                let s = CGFloat.random(in: 3...8, using: &rng)
                let p = poly([CGPoint(x: c.x - s, y: c.y), CGPoint(x: c.x, y: c.y + s * 0.8), CGPoint(x: c.x + s, y: c.y - s * 0.2),
                              CGPoint(x: c.x + s * 0.2, y: c.y - s)])
                lit(ctx, p, .rgb(0.38, 0.37, 0.35))
            }
        }
    }

    // MARK: - Terrain

    /// Seamless tiling grass/dirt texture built from layered value noise.
    static func ground() -> SKTexture {
        if let t = cache["ground"] { return t }
        let n = 1024
        var noiseA = ValueNoise(seed: 1), noiseB = ValueNoise(seed: 2), grain = SeededRNG(5)
        var px = [UInt8](repeating: 255, count: n * n * 4)
        let inv = 1 / Float(n)
        for y in 0..<n {
            for x in 0..<n {
                let u = Float(x) * inv, v = Float(y) * inv
                let a = noiseA.fbm(u, v, basePeriod: 4, octaves: 5)
                let b = noiseB.fbm(u, v, basePeriod: 3, octaves: 4)
                let g = Float(grain.next() & 0xFF) / 255
                // Grass tones
                var r: Float = 0.13 + 0.11 * a, gg: Float = 0.21 + 0.14 * a, bb: Float = 0.11 + 0.06 * a
                // Dirt patches
                let dirt = max(0, min(1, (b - 0.56) / 0.14)) * 0.85
                r += (0.34 + 0.06 * a - r) * dirt
                gg += (0.28 + 0.05 * a - gg) * dirt
                bb += (0.19 + 0.03 * a - bb) * dirt
                let k: Float = 0.9 + 0.2 * g
                let o = (y * n + x) * 4
                px[o] = UInt8(min(255, r * k * 255))
                px[o + 1] = UInt8(min(255, gg * k * 255))
                px[o + 2] = UInt8(min(255, bb * k * 255))
            }
        }
        let data = Data(px)
        guard let provider = CGDataProvider(data: data as CFData),
              let base = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: srgb,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                                 decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let img = image(size: CGSize(width: n, height: n), scale: 1, { ctx in
                  let f = CGFloat(n)
                  ctx.draw(base, in: CGRect(x: -f / 2, y: -f / 2, width: f, height: f))
                  // Grass strokes, drawn with wrap-around so the tile stays seamless
                  var rng = SeededRNG(21)
                  for _ in 0..<2600 {
                      let p = CGPoint(x: CGFloat.random(in: -f / 2 ..< f / 2, using: &rng), y: CGFloat.random(in: -f / 2 ..< f / 2, using: &rng))
                      let d = CGPoint(x: CGFloat.random(in: -3...3, using: &rng), y: CGFloat.random(in: 3...7, using: &rng))
                      let light = Bool.random(using: &rng)
                      let c = light ? NSColor.rgb(0.40, 0.52, 0.25, 0.35) : NSColor.rgb(0.05, 0.10, 0.04, 0.35)
                      for dx in [-f, 0, f] {
                          for dy in [-f, 0, f] {
                              let q = CGPoint(x: p.x + dx, y: p.y + dy)
                              if abs(q.x) > f / 2 + 8 || abs(q.y) > f / 2 + 8 { continue }
                              ctx.move(to: q)
                              ctx.addLine(to: q + d)
                          }
                      }
                      ctx.setStrokeColor(c.cgColor)
                      ctx.setLineWidth(1)
                      ctx.strokePath()
                  }
              }) else { return SKTexture() }
        let t = SKTexture(cgImage: img)
        t.filteringMode = .linear
        cache["ground"] = t
        return t
    }

    // MARK: - Interface

    static func panel(_ size: CGSize, radius: CGFloat = 10, accent: NSColor = Palette.buttonEdge) -> SKTexture {
        texture("panel-\(Int(size.width))x\(Int(size.height))-\(radius)-\(accent.hash)", size: size) { ctx in
            let r = box(-size.width / 2 + 1, -size.height / 2 + 1, size.width - 2, size.height - 2)
            let p = rr(r, radius)
            linear(ctx, p, [.rgb(0.11, 0.14, 0.17, 0.97), .rgb(0.05, 0.065, 0.08, 0.97)], CGPoint(x: 0, y: r.maxY), CGPoint(x: 0, y: r.minY))
            stroke(ctx, p, accent.withAlphaComponent(0.45), 1.2)
            lines(ctx, [(CGPoint(x: r.minX + radius, y: r.maxY - 1.5), CGPoint(x: r.maxX - radius, y: r.maxY - 1.5))],
                  NSColor(white: 1, alpha: 0.10), 1)
        }
    }

    enum ButtonState: String { case normal, hover, disabled, active }

    static func button(_ size: CGSize, _ state: ButtonState, accent: NSColor = Palette.buttonEdge) -> SKTexture {
        texture("btn-\(Int(size.width))x\(Int(size.height))-\(state.rawValue)-\(accent.hash)", size: size) { ctx in
            let r = box(-size.width / 2 + 1.5, -size.height / 2 + 1.5, size.width - 3, size.height - 3)
            let p = rr(r, 8)
            let top: NSColor, bottom: NSColor, edge: NSColor
            switch state {
            case .normal: (top, bottom, edge) = (.rgb(0.17, 0.22, 0.27), .rgb(0.09, 0.12, 0.15), accent.withAlphaComponent(0.8))
            case .hover: (top, bottom, edge) = (.rgb(0.24, 0.32, 0.40), .rgb(0.12, 0.17, 0.22), Palette.amber)
            case .disabled: (top, bottom, edge) = (.rgb(0.11, 0.12, 0.13), .rgb(0.07, 0.08, 0.09), NSColor(white: 1, alpha: 0.15))
            case .active: (top, bottom, edge) = (accent.withAlphaComponent(0.55), accent.withAlphaComponent(0.25), accent)
            }
            linear(ctx, p, [top, bottom], CGPoint(x: 0, y: r.maxY), CGPoint(x: 0, y: r.minY))
            lines(ctx, [(CGPoint(x: r.minX + 7, y: r.maxY - 1.5), CGPoint(x: r.maxX - 7, y: r.maxY - 1.5))], NSColor(white: 1, alpha: 0.14), 1)
            stroke(ctx, p, edge, state == .hover ? 2 : 1.3)
        }
    }

    static func icon(_ icon: ButtonIcon) -> SKTexture {
        switch icon {
        case .unit(let k): return unit(k, Team.local)
        case .building(let k): return building(k, Team.local)
        case .attack:
            return texture("icon-attack", size: CGSize(width: 40, height: 40)) { ctx in
                let c = Palette.bad
                stroke(ctx, circle(.zero, 11), NSColor(white: 0, alpha: 0.6), 5)
                stroke(ctx, circle(.zero, 11), c, 2.5)
                let t: [(CGPoint, CGPoint)] = [(CGPoint(x: 0, y: 7), CGPoint(x: 0, y: 17)), (CGPoint(x: 0, y: -7), CGPoint(x: 0, y: -17)),
                                               (CGPoint(x: 7, y: 0), CGPoint(x: 17, y: 0)), (CGPoint(x: -7, y: 0), CGPoint(x: -17, y: 0))]
                lines(ctx, t, NSColor(white: 0, alpha: 0.6), 5)
                lines(ctx, t, c, 2.5)
                fill(ctx, circle(.zero, 2.5), c)
            }
        case .stop:
            return texture("icon-stop", size: CGSize(width: 40, height: 40)) { ctx in
                let oct = poly((0..<8).map { i in
                    let a = CGFloat(i) * .pi / 4 + .pi / 8
                    return CGPoint(x: cos(a) * 15, y: sin(a) * 15)
                })
                lit(ctx, oct, .rgb(0.75, 0.2, 0.18))
                stroke(ctx, oct, .white, 2)
                fill(ctx, rr(box(-7, -2.5, 14, 5), 1), .white)
            }
        }
    }

    static var vignette: SKTexture {
        texture("vignette", size: CGSize(width: 256, height: 256), scale: 1) { ctx in
            ctx.scaleBy(x: 1, y: 1)
            radial(ctx, nil, [NSColor(white: 0, alpha: 0), NSColor(white: 0, alpha: 0), NSColor(white: 0, alpha: 0.5)], .zero, 182)
        }
    }

    static var crystalIcon: SKTexture {
        texture("crystalIcon", size: CGSize(width: 20, height: 20)) { ctx in
            let p = poly([CGPoint(x: 0, y: 9), CGPoint(x: 6, y: 1), CGPoint(x: 0, y: -9), CGPoint(x: -6, y: 1)])
            linear(ctx, p, [.rgb(0.8, 1, 1), .rgb(0.2, 0.7, 1)], CGPoint(x: -5, y: 8), CGPoint(x: 5, y: -8))
            lines(ctx, [(CGPoint(x: 0, y: 9), CGPoint(x: 0, y: -9))], NSColor(white: 1, alpha: 0.6), 0.8)
            stroke(ctx, p, NSColor(white: 1, alpha: 0.8), 1)
        }
    }

    static var supplyIcon: SKTexture {
        texture("supplyIcon", size: CGSize(width: 20, height: 20)) { ctx in
            let p = rr(box(-7, -7, 14, 11), 2)
            lit(ctx, p, .rgb(0.85, 0.75, 0.45))
            fill(ctx, poly([CGPoint(x: -8, y: 4), CGPoint(x: 0, y: 9), CGPoint(x: 8, y: 4)]), .rgb(0.95, 0.85, 0.55))
            stroke(ctx, p, NSColor(white: 0, alpha: 0.5), 1)
        }
    }

    // MARK: - Cursors

    enum CursorKind { case normal, attack, gather }

    private static var cursors: [CursorKind: NSCursor] = [:]

    static func cursor(_ kind: CursorKind) -> NSCursor {
        if kind == .normal { return .arrow }
        if let c = cursors[kind] { return c }
        let img = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: 16, y: 16)
            ctx.setLineCap(.round)
            switch kind {
            case .attack:
                let t: [(CGPoint, CGPoint)] = [(CGPoint(x: 0, y: 5), CGPoint(x: 0, y: 13)), (CGPoint(x: 0, y: -5), CGPoint(x: 0, y: -13)),
                                               (CGPoint(x: 5, y: 0), CGPoint(x: 13, y: 0)), (CGPoint(x: -5, y: 0), CGPoint(x: -13, y: 0))]
                stroke(ctx, circle(.zero, 9), .black, 4.5)
                lines(ctx, t, .black, 4.5)
                stroke(ctx, circle(.zero, 9), Palette.bad, 2)
                lines(ctx, t, Palette.bad, 2)
                fill(ctx, circle(.zero, 1.8), Palette.bad)
            case .gather:
                let p = poly([CGPoint(x: 0, y: 11), CGPoint(x: 7, y: 1), CGPoint(x: 0, y: -11), CGPoint(x: -7, y: 1)])
                stroke(ctx, p, .black, 4)
                linear(ctx, p, [.rgb(0.8, 1, 1), .rgb(0.2, 0.7, 1)], CGPoint(x: -6, y: 10), CGPoint(x: 6, y: -10))
                stroke(ctx, p, .white, 1.3)
            case .normal:
                break
            }
            return true
        }
        let c = NSCursor(image: img, hotSpot: NSPoint(x: 16, y: 16))
        cursors[kind] = c
        return c
    }
}

// MARK: - Noise

/// Periodic 2D value noise (tiles seamlessly over the unit square).
struct ValueNoise {
    private var lattice: [Float]
    private let size = 256

    init(seed: UInt64) {
        var rng = SeededRNG(seed)
        lattice = (0..<(256 * 256)).map { _ in Float(rng.next() & 0xFFFF) / 65535 }
    }

    private func at(_ x: Int, _ y: Int, _ period: Int) -> Float {
        let xi = ((x % period) + period) % period, yi = ((y % period) + period) % period
        return lattice[yi * size + xi]
    }

    func sample(_ u: Float, _ v: Float, period: Int) -> Float {
        let x = u * Float(period), y = v * Float(period)
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        var fx = x - Float(x0), fy = y - Float(y0)
        fx = fx * fx * (3 - 2 * fx)
        fy = fy * fy * (3 - 2 * fy)
        let a = at(x0, y0, period), b = at(x0 + 1, y0, period)
        let c = at(x0, y0 + 1, period), d = at(x0 + 1, y0 + 1, period)
        let top = a + (b - a) * fx, bottom = c + (d - c) * fx
        return top + (bottom - top) * fy
    }

    mutating func fbm(_ u: Float, _ v: Float, basePeriod: Int, octaves: Int) -> Float {
        var sum: Float = 0, amp: Float = 0.5, norm: Float = 0, period = basePeriod
        for _ in 0..<octaves {
            sum += sample(u, v, period: period) * amp
            norm += amp
            amp *= 0.5
            period *= 2
        }
        return sum / norm
    }
}
