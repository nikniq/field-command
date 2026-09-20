import AppKit

/// Organic terrain rendering, a port of the Linux edition's terrain.py: water and cliffs are drawn from a blurred,
/// noise-warped mask of the map's wall rectangles, so overlapping pieces merge into natural lakes, rivers and
/// ridges. Collision still uses the rects; the drawn shape covers them and extends a little beyond.
enum Terrain {
    static let res = 2.0  // world units per pixel

    struct Wall { let rect: CGRect; let water: Bool }

    static func walls(_ map: [String: Any]) -> [Wall] {
        jArr(map["walls"]).map { w in
            let v = jArr(w)
            return Wall(rect: CGRect(x: jNum(v[0]), y: jNum(v[1]), width: jNum(v[2]) - jNum(v[0]), height: jNum(v[3]) - jNum(v[1])),
                        water: jStr(v[4]) == "water")
        }
    }

    static func bridges(_ map: [String: Any]) -> [CGRect] {
        jArr(map["bridges"]).map { b in
            let v = jArr(b)
            return CGRect(x: jNum(v[0]), y: jNum(v[1]), width: jNum(v[2]) - jNum(v[0]), height: jNum(v[3]) - jNum(v[1]))
        }
    }

    // MARK: Field helpers (row 0 = top of the map)

    private struct Field {
        let w: Int, h: Int
        var a: [Float]
        init(_ w: Int, _ h: Int) { self.w = w; self.h = h; a = [Float](repeating: 0, count: w * h) }
    }

    private static func mask(_ rects: [CGRect], _ w: Int, _ h: Int) -> Field {
        var f = Field(w, h)
        let H = Double(worldSize.height)
        for r in rects {
            let c0 = max(0, Int(Double(r.minX) / res)), c1 = min(w, Int((Double(r.maxX) / res).rounded(.up)))
            let r0 = max(0, Int((H - Double(r.maxY)) / res)), r1 = min(h, Int(((H - Double(r.minY)) / res).rounded(.up)))
            guard c0 < c1, r0 < r1 else { continue }
            for y in r0..<r1 { for x in c0..<c1 { f.a[y * w + x] = 1 } }
        }
        return f
    }

    /// Separable box blur, repeated to approximate a gaussian.
    private static func blur(_ f: inout Field, _ r: Int, passes: Int = 3) {
        let w = f.w, h = f.h
        var tmp = [Float](repeating: 0, count: max(w, h) + 2 * r + 2)
        let norm = 1 / Float(2 * r + 1)
        for _ in 0..<passes {
            for y in 0..<h {  // horizontal
                var s: Float = 0
                let row = y * w
                for i in -r - 1..<r { s += f.a[row + min(w - 1, max(0, i))] }
                for x in 0..<w {
                    s += f.a[row + min(w - 1, x + r)] - f.a[row + max(0, x - r - 1)]
                    tmp[x] = s * norm
                }
                for x in 0..<w { f.a[row + x] = tmp[x] }
            }
            for x in 0..<w {  // vertical
                var s: Float = 0
                for i in -r - 1..<r { s += f.a[min(h - 1, max(0, i)) * w + x] }
                for y in 0..<h {
                    s += f.a[min(h - 1, y + r) * w + x] - f.a[max(0, y - r - 1) * w + x]
                    tmp[y] = s * norm
                }
                for y in 0..<h { f.a[y * w + x] = tmp[y] }
            }
        }
    }

    /// Smooth value noise in [-1, 1]; `period` is the feature size in pixels.
    private static func noise(_ w: Int, _ h: Int, period: Double, octaves: Int, seed: UInt64) -> Field {
        var f = Field(w, h)
        var rng = SeededRNG(seed)
        var amp: Float = 0.5, norm: Float = 0, p = period
        for _ in 0..<octaves {
            let gw = Int(Double(w) / p) + 2, gh = Int(Double(h) / p) + 2
            let lattice = (0..<(gw * gh)).map { _ in Float.random(in: 0...1, using: &rng) }
            for y in 0..<h {
                let fy = Double(y) / p, y0 = Int(fy)
                var ty = Float(fy - Double(y0)); ty = ty * ty * (3 - 2 * ty)
                for x in 0..<w {
                    let fx = Double(x) / p, x0 = Int(fx)
                    var tx = Float(fx - Double(x0)); tx = tx * tx * (3 - 2 * tx)
                    let a = lattice[y0 * gw + x0], b = lattice[y0 * gw + x0 + 1]
                    let c = lattice[(y0 + 1) * gw + x0], d = lattice[(y0 + 1) * gw + x0 + 1]
                    let top = a + (b - a) * tx, bottom = c + (d - c) * tx
                    f.a[y * w + x] += (top + (bottom - top) * ty) * amp
                }
            }
            norm += amp
            amp *= 0.5
            p /= 2
        }
        for i in f.a.indices { f.a[i] = f.a[i] / norm * 2 - 1 }
        return f
    }

    @inline(__always) private static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Rendering

    /// A world-sized (at 1/`res` scale) image of all water, cliffs and bridges, or nil when the map has none.
    static func image(_ map: [String: Any]) -> CGImage? {
        let walls = walls(map), bridges = bridges(map)
        guard !walls.isEmpty else { return nil }
        let w = Int(Double(worldSize.width) / res), h = Int(Double(worldSize.height) / res)
        let seed = UInt64(max(1, jInt(map["seed"])))
        let warp = noise(w, h, period: 150 / res, octaves: 3, seed: seed &+ 11)
        let fine = noise(w, h, period: 40 / res, octaves: 2, seed: seed &+ 12)
        let patchy = noise(w, h, period: 30, octaves: 2, seed: seed &+ 13)
        // Premultiplied colour and coverage, 0...1
        var rgb = [Float](repeating: 0, count: w * h * 3)
        var alpha = [Float](repeating: 0, count: w * h)

        let water = walls.filter { $0.water }.map { $0.rect }
        if !water.isEmpty {
            var f = mask(water + bridges, w, h)
            blur(&f, 16)
            for y in 0..<h {
                let ripplePhase = Float(y) * 0.5
                for x in 0..<w {
                    let i = y * w + x
                    let b = f.a[i]
                    guard b > 0.001 else { continue }
                    let v = b + warp.a[i] * 0.24 * smooth(0, 0.2, b)
                    let shore = smooth(0.10, 0.17, v)
                    guard shore > 0 else { continue }
                    let wet = smooth(0.28, 0.33, v)
                    let depth = smooth(0.35, 0.95, v + fine.a[i] * 0.04)
                    // sand fading to damp mud at the waterline
                    let mud = smooth(0.18, 0.28, v)
                    var cr = 118 + fine.a[i] * 14, cg = 104 + fine.a[i] * 14, cb = 70 + fine.a[i] * 14
                    cr += (70 - cr) * mud; cg += (58 - cg) * mud; cb += (36 - cb) * mud
                    var wr = 46 + (16 - 46) * depth, wg = 112 + (50 - 112) * depth, wb = 128 + (76 - 128) * depth
                    let ripple = sin(ripplePhase + Float(x) * 0.04 + fine.a[i] * 2.5) * 0.5 + 0.5
                    let rp = pow(ripple, 14) * smooth(0, 0.6, patchy.a[i]) * 30 * (0.4 + depth)
                    let v2 = (v - 0.315) / 0.018
                    let foam = exp(-v2 * v2) * 60
                    wr += rp + foam; wg += rp + foam; wb += rp + foam
                    cr += (wr - cr) * wet; cg += (wg - cg) * wet; cb += (wb - cb) * wet
                    rgb[i * 3] = cr * shore; rgb[i * 3 + 1] = cg * shore; rgb[i * 3 + 2] = cb * shore
                    alpha[i] = shore * 0.97
                }
            }
        }

        let cliffs = walls.filter { !$0.water }.map { $0.rect }
        if !cliffs.isEmpty {
            var f = mask(cliffs, w, h)
            blur(&f, 10)
            var v = f.a, hgt = f.a
            for i in v.indices {
                let b = f.a[i]
                v[i] = b + warp.a[i] * 0.22 * smooth(0, 0.2, b)
                hgt[i] = smooth(0.22, 0.75, v[i]) * 40 + (fine.a[i] * 9 + abs(warp.a[i]) * 8) * smooth(0.2, 0.5, v[i])
            }
            var body = [Float](repeating: 0, count: w * h)
            for i in v.indices { body[i] = smooth(0.24, 0.30, v[i]) }
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    // cast shadow down-right
                    let sy = y - 7, sx = x - 5
                    let caster: Float = sy >= 0 && sx >= 0 ? body[sy * w + sx] : 0
                    let sh = caster * (1 - body[i]) * 0.4
                    if sh > 0 {
                        rgb[i * 3] *= 1 - sh; rgb[i * 3 + 1] *= 1 - sh; rgb[i * 3 + 2] *= 1 - sh
                        alpha[i] = max(alpha[i], sh)
                    }
                    let bd = body[i]
                    guard bd > 0 else { continue }
                    // height field -> lighting (light from the top-left of the screen)
                    let gx = (hgt[y * w + min(w - 1, x + 1)] - hgt[y * w + max(0, x - 1)]) * 0.5
                    let gy = (hgt[min(h - 1, y + 1) * w + x] - hgt[max(0, y - 1) * w + x]) * 0.5
                    let light = min(1.25, max(0.15, 0.62 + gx * 0.20 + gy * 0.26))
                    let top = smooth(0.55, 0.75, v[i])
                    let n = fine.a[i] * 26
                    let r = (92 + 36 * top + n) * light, g = (86 + 36 * top + n) * light, b = (76 + 32 * top + n) * light
                    rgb[i * 3] = rgb[i * 3] * (1 - bd) + r * bd
                    rgb[i * 3 + 1] = rgb[i * 3 + 1] * (1 - bd) + g * bd
                    rgb[i * 3 + 2] = rgb[i * 3 + 2] * (1 - bd) + b * bd
                    alpha[i] = max(alpha[i], bd)
                }
            }
        }

        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = min(1, alpha[i])
            // stored premultiplied: colour already weighted by coverage, capped to alpha
            px[i * 4] = UInt8(min(a * 255, max(0, rgb[i * 3])))
            px[i * 4 + 1] = UInt8(min(a * 255, max(0, rgb[i * 3 + 1])))
            px[i * 4 + 2] = UInt8(min(a * 255, max(0, rgb[i * 3 + 2])))
            px[i * 4 + 3] = UInt8(a * 255)
        }
        return px.withUnsafeMutableBytes { buf -> CGImage? in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: Art.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            // Bridges, drawn in world coordinates (the context's origin is bottom-left, y up).
            ctx.scaleBy(x: CGFloat(1 / res), y: CGFloat(1 / res))
            for (k, r) in bridges.enumerated() { drawBridge(ctx, r, seed: UInt64(k + 7)) }
            return ctx.makeImage()
        }
    }

    private static func drawBridge(_ ctx: CGContext, _ r: CGRect, seed: UInt64) {
        var rng = SeededRNG(seed)
        let deck = r.insetBy(dx: 0, dy: 6)
        Art.fill(ctx, Art.rr(deck.offsetBy(dx: 6, dy: -8), 4), .rgb(0, 0, 0, 0.35))
        Art.linear(ctx, Art.rr(deck, 4), [.rgb(0.58, 0.43, 0.26), .rgb(0.44, 0.31, 0.18)],
                   CGPoint(x: deck.midX, y: deck.maxY), CGPoint(x: deck.midX, y: deck.minY))
        ctx.setStrokeColor(NSColorRGB(0.25, 0.17, 0.09, 0.8))
        ctx.setLineWidth(1.4)
        var x = deck.minX + 12
        while x < deck.maxX {
            ctx.move(to: CGPoint(x: x, y: deck.minY + 1))
            ctx.addLine(to: CGPoint(x: x, y: deck.maxY - 1))
            x += 12 + CGFloat.random(in: -1...1, using: &rng)
        }
        ctx.strokePath()
        for y in [deck.minY + 2, deck.maxY - 2] {
            let rail = CGRect(x: deck.minX, y: y - 4, width: deck.width, height: 8)
            Art.fill(ctx, Art.rr(rail, 3), .rgb(0.40, 0.28, 0.15))
            Art.fill(ctx, Art.rr(rail.insetBy(dx: 1, dy: 3).offsetBy(dx: 0, dy: 1.5), 1.5), .rgb(0.55, 0.40, 0.24))
            var px = deck.minX + 8
            while px < deck.maxX {
                Art.fill(ctx, Art.circle(CGPoint(x: px, y: y), 3.2), .rgb(0.22, 0.15, 0.08))
                px += 40
            }
        }
        Art.stroke(ctx, Art.rr(deck, 4), .rgb(0.20, 0.13, 0.06, 0.9), 1.5)
    }

    private static func NSColorRGB(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
