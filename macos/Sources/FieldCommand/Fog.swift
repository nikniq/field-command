import SpriteKit

/// Grid-based fog of war for the player. Cells are unexplored (dark), explored (dimmed) or visible (clear).
/// Rendered as a tiny texture stretched over the map; linear filtering gives soft edges.
final class FogOfWar {
    let cell: CGFloat = 20
    let cols: Int
    let rows: Int
    private var visible: [Bool]
    private var explored: [Bool]
    var cellCount: Int { explored.count }
    func restore(explored bits: [Bool]) { if bits.count == explored.count { explored = bits; dirty = true } }
    private var shade: [Float]
    private var pixels: [UInt8]
    private var blurred: [Float]
    private var dirty = true
    var revealAll = false
    let node = SKSpriteNode()
    private(set) var texture: SKTexture?

    init() {
        cols = Int(ceil(worldSize.width / cell))
        rows = Int(ceil(worldSize.height / cell))
        let n = cols * rows
        visible = Array(repeating: false, count: n)
        explored = Array(repeating: false, count: n)
        shade = Array(repeating: 0.94, count: n)
        pixels = [UInt8](repeating: 0, count: n * 4)
        blurred = Array(repeating: 0.94, count: n)
        node.anchorPoint = .zero
        node.size = CGSize(width: CGFloat(cols) * cell, height: CGFloat(rows) * cell)
        node.zPosition = 45
    }

    private func index(_ p: CGPoint) -> Int? {
        let cx = Int(p.x / cell), cy = Int(p.y / cell)
        guard p.x >= 0, p.y >= 0, cx < cols, cy < rows else { return nil }
        return cy * cols + cx
    }

    func isVisible(_ p: CGPoint) -> Bool {
        revealAll || (index(p).map { visible[$0] } ?? false)
    }

    func isExplored(_ p: CGPoint) -> Bool {
        revealAll || (index(p).map { explored[$0] } ?? false)
    }

    func anyVisible(in r: CGRect) -> Bool {
        if revealAll { return true }
        let x0 = max(0, Int(r.minX / cell)), x1 = min(cols - 1, Int(r.maxX / cell))
        let y0 = max(0, Int(r.minY / cell)), y1 = min(rows - 1, Int(r.maxY / cell))
        guard x0 <= x1, y0 <= y1 else { return false }
        for y in y0...y1 {
            for x in x0...x1 where visible[y * cols + x] { return true }
        }
        return false
    }

    func recompute(viewers: [(CGPoint, CGFloat)]) {
        for i in visible.indices { visible[i] = false }
        for (p, r) in viewers {
            let r2 = r * r
            let x0 = max(0, Int((p.x - r) / cell)), x1 = min(cols - 1, Int((p.x + r) / cell))
            let y0 = max(0, Int((p.y - r) / cell)), y1 = min(rows - 1, Int((p.y + r) / cell))
            guard x0 <= x1, y0 <= y1 else { continue }
            for cy in y0...y1 {
                let dy = (CGFloat(cy) + 0.5) * cell - p.y
                let dy2 = dy * dy
                if dy2 > r2 { continue }
                for cx in x0...x1 {
                    let dx = (CGFloat(cx) + 0.5) * cell - p.x
                    if dx * dx + dy2 <= r2 {
                        let i = cy * cols + cx
                        visible[i] = true
                        explored[i] = true
                    }
                }
            }
        }
        dirty = true
    }

    /// Eases cell shading toward its target and rebuilds the texture when anything changed.
    @discardableResult
    func render(dt: CGFloat) -> Bool {
        let k = Float(min(1, dt * 6))
        var changed = false
        for i in shade.indices {
            let target: Float = revealAll || visible[i] ? 0 : (explored[i] ? 0.5 : 0.93)
            let d = target - shade[i]
            if abs(d) > 0.003 {
                shade[i] += abs(d) < 0.01 ? d : d * k
                changed = true
            }
        }
        guard changed || dirty || texture == nil else { return false }
        dirty = false
        // 5-tap blur softens the cell edges before upload.
        for cy in 0..<rows {
            for cx in 0..<cols {
                let i = cy * cols + cx
                let l = shade[cx > 0 ? i - 1 : i], r = shade[cx < cols - 1 ? i + 1 : i]
                let d = shade[cy > 0 ? i - cols : i], u = shade[cy < rows - 1 ? i + cols : i]
                blurred[i] = shade[i] * 0.4 + (l + r + d + u) * 0.15
            }
        }
        for cy in 0..<rows {
            let row = rows - 1 - cy
            for cx in 0..<cols {
                let a = blurred[cy * cols + cx]
                let o = (row * cols + cx) * 4
                pixels[o] = UInt8(a * 5)
                pixels[o + 1] = UInt8(a * 8)
                pixels[o + 2] = UInt8(a * 13)
                pixels[o + 3] = UInt8(a * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let img = CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                                space: Art.srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return false }
        let t = SKTexture(cgImage: img)
        t.filteringMode = .linear
        texture = t
        node.texture = t
        return true
    }
}
