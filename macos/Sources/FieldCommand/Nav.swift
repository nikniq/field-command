import Foundation

/// Navigation grid and A* pathfinding for the server simulation; a port of the Linux edition's nav.py.
///
/// The map is divided into 40-unit cells. A cell is blocked if its centre lies inside a wall, building, tree or
/// crystal, padded by `clearance` so unit bodies keep off the edges. Units walk straight at their goal when the
/// line is clear, and otherwise follow a smoothed A* path. The grid is rebuilt when buildings appear or disappear.
final class SNavGrid {
    static let cell = 40.0
    static let clearance = 14.0
    private static let sqrt2 = 2.0.squareRoot()
    private static let neighbours: [(Int, Int, Double)] = [(1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1),
                                                           (1, 1, sqrt2), (1, -1, sqrt2), (-1, 1, sqrt2), (-1, -1, sqrt2)]
    let cols: Int, rows: Int
    private(set) var blocked: [Bool]
    private(set) var version = 0

    init() {
        cols = Int((worldW / Self.cell).rounded(.up))
        rows = Int((worldH / Self.cell).rounded(.up))
        blocked = Array(repeating: false, count: cols * rows)
    }

    // MARK: Building the grid

    func rebuild(rects: [SRect], circles: [(Double, Double, Double)]) {
        var b = [Bool](repeating: false, count: cols * rows)
        let pad = Self.clearance, cell = Self.cell
        for r in rects {
            let cx0 = max(0, Int(((r.x0 - pad) / cell).rounded(.down))), cx1 = min(cols - 1, Int((r.x1 + pad) / cell))
            let cy0 = max(0, Int(((r.y0 - pad) / cell).rounded(.down))), cy1 = min(rows - 1, Int((r.y1 + pad) / cell))
            guard cx0 <= cx1, cy0 <= cy1 else { continue }
            for cy in cy0...cy1 {
                let py = (Double(cy) + 0.5) * cell
                if py < r.y0 - pad || py > r.y1 + pad { continue }
                for cx in cx0...cx1 {
                    let px = (Double(cx) + 0.5) * cell
                    if px >= r.x0 - pad && px <= r.x1 + pad { b[cy * cols + cx] = true }
                }
            }
        }
        for (x, y, r) in circles {
            let rr = r + pad, r2 = rr * rr
            let cx0 = max(0, Int(((x - rr) / cell).rounded(.down))), cx1 = min(cols - 1, Int((x + rr) / cell))
            let cy0 = max(0, Int(((y - rr) / cell).rounded(.down))), cy1 = min(rows - 1, Int((y + rr) / cell))
            guard cx0 <= cx1, cy0 <= cy1 else { continue }
            for cy in cy0...cy1 {
                let dy = (Double(cy) + 0.5) * cell - y
                for cx in cx0...cx1 {
                    let dx = (Double(cx) + 0.5) * cell - x
                    if dx * dx + dy * dy <= r2 { b[cy * cols + cx] = true }
                }
            }
        }
        blocked = b
        version += 1
    }

    // MARK: Queries

    func cell(_ x: Double, _ y: Double) -> (Int, Int) {
        (min(cols - 1, max(0, Int((x / Self.cell).rounded(.down)))), min(rows - 1, max(0, Int((y / Self.cell).rounded(.down)))))
    }

    func center(_ cx: Int, _ cy: Int) -> (Double, Double) { ((Double(cx) + 0.5) * Self.cell, (Double(cy) + 0.5) * Self.cell) }

    /// True if the straight line crosses no blocked cell. The first cell and the final `ignoreEnd` units
    /// (e.g. the target building's own footprint) are not checked.
    func lineClear(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, ignoreEnd: Double = 0) -> Bool {
        let d = ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)).squareRoot()
        let length = d - ignoreEnd
        if length <= 0 { return true }
        let step = Self.cell * 0.4
        let n = Int(length / step)
        if n <= 0 { return true }
        let ux = (x1 - x0) / d, uy = (y1 - y0) / d
        let start = cell(x0, y0)
        for i in 1...n {
            let t = Double(i) * step
            let fx = ((x0 + ux * t) / Self.cell).rounded(.down), fy = ((y0 + uy * t) / Self.cell).rounded(.down)
            let cx = Int(fx), cy = Int(fy)
            if cx == start.0 && cy == start.1 { continue }
            if cx < 0 || cy < 0 || cx >= cols || cy >= rows || blocked[cy * cols + cx] { return false }
        }
        return true
    }

    func nearestFree(_ cx: Int, _ cy: Int, maxR: Int = 8) -> (Int, Int) {
        if !blocked[cy * cols + cx] { return (cx, cy) }
        for r in 1...maxR {
            var best: (Int, Int)?, bestD = Int.max
            for dy in -r...r {
                for dx in -r...r where max(abs(dx), abs(dy)) == r {
                    let x = cx + dx, y = cy + dy
                    if x >= 0 && y >= 0 && x < cols && y < rows && !blocked[y * cols + x] {
                        let d = dx * dx + dy * dy
                        if d < bestD { best = (x, y); bestD = d }
                    }
                }
            }
            if let best { return best }
        }
        return (cx, cy)
    }

    // MARK: A*

    /// Waypoints from (x0, y0) toward (x1, y1), ending at the goal itself. If the goal is unreachable the path
    /// leads to the reachable cell closest to it.
    func findPath(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, maxNodes: Int = 9000) -> [(Double, Double)] {
        let s0 = cell(x0, y0), g0 = cell(x1, y1)
        let (sx, sy) = nearestFree(s0.0, s0.1), (gx, gy) = nearestFree(g0.0, g0.1)
        let start = sy * cols + sx, goal = gy * cols + gx
        if start == goal { return [(x1, y1)] }
        let cols = self.cols, rows = self.rows
        func h(_ i: Int) -> Double {
            let dx = Double(abs(i % cols - gx)), dy = Double(abs(i / cols - gy))
            return dx + dy + (Self.sqrt2 - 2) * min(dx, dy)
        }
        var g = [Double](repeating: .infinity, count: cols * rows)
        var came = [Int](repeating: -1, count: cols * rows)
        var closed = [Bool](repeating: false, count: cols * rows)
        var heap = MinHeap()
        g[start] = 0
        heap.push(h(start), start)
        var best = start, bestH = h(start), expanded = 0
        while let (_, cur) = heap.pop() {
            if closed[cur] { continue }
            if cur == goal { best = goal; break }
            closed[cur] = true
            expanded += 1
            if expanded > maxNodes { break }
            let hc = h(cur)
            if hc < bestH { best = cur; bestH = hc }
            let cx = cur % cols, cy = cur / cols
            for (dx, dy, cost) in Self.neighbours {
                let nx = cx + dx, ny = cy + dy
                if nx < 0 || ny < 0 || nx >= cols || ny >= rows { continue }
                let ni = ny * cols + nx
                if blocked[ni] || closed[ni] { continue }
                if dx != 0 && dy != 0 && (blocked[cy * cols + nx] || blocked[ny * cols + cx]) { continue }  // no corner cutting
                let ng = g[cur] + cost
                if ng < g[ni] {
                    g[ni] = ng
                    came[ni] = cur
                    heap.push(ng + h(ni), ni)
                }
            }
        }
        var cells = [best]
        while came[cells[cells.count - 1]] >= 0 { cells.append(came[cells[cells.count - 1]]) }
        cells.reverse()
        var pts = cells.dropFirst().map { center($0 % cols, $0 / cols) }
        if best == goal { pts.append((x1, y1)) }
        return smooth((x0, y0), pts)
    }

    /// String-pulling: skip waypoints that can be seen directly from the previous kept point.
    private func smooth(_ origin: (Double, Double), _ pts: [(Double, Double)]) -> [(Double, Double)] {
        if pts.count <= 1 { return pts }
        var out: [(Double, Double)] = []
        var anchor = origin
        var i = 0
        while i < pts.count {
            var j = pts.count - 1
            while j > i && !lineClear(anchor.0, anchor.1, pts[j].0, pts[j].1) { j -= 1 }
            out.append(pts[j])
            anchor = pts[j]
            i = j + 1
        }
        return out
    }
}

/// Binary min-heap of (priority, cell index).
private struct MinHeap {
    private var items: [(Double, Int)] = []

    mutating func push(_ p: Double, _ v: Int) {
        items.append((p, v))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if items[parent].0 <= items[i].0 { break }
            items.swapAt(parent, i)
            i = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && items[l].0 < items[m].0 { m = l }
                if r < items.count && items[r].0 < items[m].0 { m = r }
                if m == i { break }
                items.swapAt(m, i)
                i = m
            }
        }
        return top
    }
}
