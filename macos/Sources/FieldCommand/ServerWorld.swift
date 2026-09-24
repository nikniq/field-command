import Foundation

// Headless authoritative simulation used when the Mac hosts a multiplayer game.
// A faithful port of the Linux edition's world.py / entities.py / ai.py / fog.py / mapgen.py, so Mac-hosted and
// Linux-hosted games behave the same and speak the same protocol. No SpriteKit: everything here is plain data.

// MARK: - Helpers

private func hyp(_ x: Double, _ y: Double) -> Double { (x * x + y * y).squareRoot() }
private func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

/// The signed shortest turn from a to b.
private func angDiff(_ a: Double, _ b: Double) -> Double {
    var d = b - a
    while d > .pi { d -= 2 * .pi }
    while d < -.pi { d += 2 * .pi }
    return d
}

private func angLerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + angDiff(a, b) * min(1, t) }

struct SRect {
    var x0, y0, x1, y1: Double
    init(cx: Double, cy: Double, half h: Double) { x0 = cx - h; y0 = cy - h; x1 = cx + h; y1 = cy + h }
    init(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
    func distance(_ px: Double, _ py: Double) -> Double {
        hyp(max(x0 - px, 0, px - x1), max(y0 - py, 0, py - y1))
    }
    func intersects(_ o: SRect) -> Bool { x0 < o.x1 && o.x0 < x1 && y0 < o.y1 && o.y0 < y1 }
    func expanded(_ m: Double) -> SRect { SRect(x0 - m, y0 - m, x1 + m, y1 + m) }
}

var worldW: Double { Double(worldSize.width) }
var worldH: Double { Double(worldSize.height) }

// MARK: - Fog grid

final class SFogGrid {
    let cell = 20.0
    let cols: Int, rows: Int
    private(set) var visible: [Bool]
    private(set) var explored: [Bool]
    func restoreExplored(_ bits: [Bool]) { if bits.count == explored.count { explored = bits } }
    private var disks: [Int: [Bool]] = [:]

    init() {
        cols = Int((worldW / cell).rounded(.up))
        rows = Int((worldH / cell).rounded(.up))
        visible = Array(repeating: false, count: cols * rows)
        explored = visible
    }

    private func disk(_ n: Int) -> [Bool] {
        if let d = disks[n] { return d }
        let s = 2 * n + 1
        var d = [Bool](repeating: false, count: s * s)
        let r2 = (Double(n) + 0.3) * (Double(n) + 0.3)
        for y in -n...n {
            for x in -n...n where Double(x * x + y * y) <= r2 { d[(y + n) * s + (x + n)] = true }
        }
        disks[n] = d
        return d
    }

    func recompute(_ viewers: [(Double, Double, Double)]) {
        for i in visible.indices { visible[i] = false }
        for (x, y, r) in viewers {
            let cx = Int(x / cell), cy = Int(y / cell), n = Int(r / cell)
            let d = disk(n), s = 2 * n + 1
            for yy in max(0, cy - n)...min(rows - 1, cy + n) {
                for xx in max(0, cx - n)...min(cols - 1, cx + n) where d[(yy - cy + n) * s + (xx - cx + n)] {
                    let i = yy * cols + xx
                    visible[i] = true
                    explored[i] = true
                }
            }
        }
    }

    private func index(_ x: Double, _ y: Double) -> Int? {
        let cx = Int(x / cell), cy = Int(y / cell)
        guard x >= 0, y >= 0, cx < cols, cy < rows else { return nil }
        return cy * cols + cx
    }

    func isVisible(_ x: Double, _ y: Double) -> Bool { index(x, y).map { visible[$0] } ?? false }
    func isExplored(_ x: Double, _ y: Double) -> Bool { index(x, y).map { explored[$0] } ?? false }

    func anyVisible(_ r: SRect) -> Bool {
        let x0 = max(0, Int(r.x0 / cell)), x1 = min(cols - 1, Int(r.x1 / cell))
        let y0 = max(0, Int(r.y0 / cell)), y1 = min(rows - 1, Int(r.y1 / cell))
        guard x0 <= x1, y0 <= y1 else { return false }
        for y in y0...y1 {
            for x in x0...x1 where visible[y * cols + x] { return true }
        }
        return false
    }
}

// MARK: - Map generation

enum SMapGen {
    struct Start { let x, y, angle: Double }
    struct Info { let id, name: String; let players: Int; let desc: String }
    typealias Wall = (Double, Double, Double, Double, String)

    /// Same ids, names and layouts as the Linux edition's mapgen.CATALOG.
    static let catalog: [Info] = [
        Info(id: "twin_ridges", name: "Twin Ridges", players: 2, desc: "Open ground with bases in opposite corners."),
        Info(id: "river_crossing", name: "River Crossing", players: 2, desc: "A river splits the map; fight over three bridges."),
        Info(id: "highland_pass", name: "Highland Pass", players: 2, desc: "Cliff ridges funnel armies through narrow passes."),
        Info(id: "four_corners", name: "Four Corners", players: 4, desc: "A base in every corner and a rich centre."),
        Info(id: "crossroads", name: "Crossroads", players: 4, desc: "Bases on each edge; lakes guard the corners."),
        Info(id: "grand_arena", name: "Grand Arena", players: 12, desc: "Mega map: twelve bases ringing an open plain."),
        Info(id: "riverlands", name: "Riverlands", players: 12, desc: "Mega map: four rivers and a walled heartland."),
        Info(id: "continental_divide", name: "Continental Divide", players: 12, desc: "Giant map: a cliff spine splits north from south; five passes."),
        Info(id: "archipelago", name: "Archipelago", players: 12, desc: "Giant map: a bridged island in an inland sea, lakes along the rim."),
        Info(id: "six_rivers", name: "Six Rivers", players: 12, desc: "Giant map: six rivers run from the middle to the edges; two bases a wedge."),
        Info(id: "crater_fields", name: "Crater Fields", players: 12, desc: "Giant map: every base sits inside a broken crater on an open plain."),
        Info(id: "long_march", name: "The Long March", players: 12, desc: "Giant map: two rows of six bases face each other across a wide river."),
    ]

    /// The mega maps are half again as wide and tall to hold twelve bases; the giant maps are half again as
    /// wide and tall as those (9000 x 6300, five times the standard area).
    static let megaWorld = CGSize(width: 6000, height: 4200)
    static let giantWorld = CGSize(width: 9000, height: 6300)
    static let giantIds: Set<String> = ["continental_divide", "archipelago", "six_rivers", "crater_fields", "long_march"]
    static func size(_ id: String) -> CGSize {
        giantIds.contains(id) ? giantWorld : (info(id)?.players ?? 2) > 4 ? megaWorld : defaultWorldSize
    }
    static func info(_ id: String) -> Info? { catalog.first { $0.id == id } }

    static func map(players n: Int) -> [String: Any] {
        n <= 2 ? twinRidges() : (n <= 4 ? fourCorners() : grandArena())
    }

    static func generate(_ id: String) -> [String: Any] {
        switch id {
        case "river_crossing": return riverCrossing()
        case "highland_pass": return highlandPass()
        case "four_corners": return fourCorners()
        case "crossroads": return crossroads()
        case "grand_arena": return grandArena()
        case "riverlands": return riverlands()
        case "continental_divide": return continentalDivide()
        case "archipelago": return archipelago()
        case "six_rivers": return sixRivers()
        case "crater_fields": return craterFields()
        case "long_march": return longMarch()
        default: return twinRidges()
        }
    }

    /// Map for a lobby choice: "auto" picks by player count; too-small maps fall back to one that fits.
    static func resolve(_ id: String, players n: Int) -> [String: Any] {
        if let i = info(id), i.players >= n { return generate(id) }
        return map(players: n)
    }

    private static func distToRoads(_ roads: [[(Double, Double)]], _ x: Double, _ y: Double) -> Double {
        var best = 1e9
        for road in roads {
            for i in 0..<(road.count - 1) {
                let (ax, ay) = road[i], (bx, by) = road[i + 1]
                let abx = bx - ax, aby = by - ay
                let t = clampD(((x - ax) * abx + (y - ay) * aby) / max(1e-3, abx * abx + aby * aby), 0, 1)
                best = min(best, hyp(x - (ax + abx * t), y - (ay + aby * t)))
            }
        }
        return best
    }

    // Baked layouts (GiantMaps.swift) are strings: entries split by ";", numbers by " ", a road's points by ",".
    private static func nums(_ s: Substring) -> [Double] { s.split(separator: " ").compactMap { Double($0) } }
    static func starts(_ s: String) -> [Start] {
        s.split(separator: ";").map { let n = nums($0); return Start(x: n[0], y: n[1], angle: n[2]) }
    }
    static func expansions(_ s: String) -> [(Double, Double, Int, Int)] {
        s.split(separator: ";").map { let n = nums($0); return (n[0], n[1], Int(n[2]), Int(n[3])) }
    }
    static func roads(_ s: String) -> [[(Double, Double)]] {
        s.split(separator: ";").map { $0.split(separator: ",").map { let n = nums($0); return (n[0], n[1]) } }
    }
    static func walls(_ s: String) -> [Wall] {
        s.split(separator: ";").map { e in
            let f = e.split(separator: " ")
            return (Double(f[0])!, Double(f[1])!, Double(f[2])!, Double(f[3])!, String(f[4]))
        }
    }
    static func rects(_ s: String) -> [(Double, Double, Double, Double)] {
        s.isEmpty ? [] : s.split(separator: ";").map { let n = nums($0); return (n[0], n[1], n[2], n[3]) }
    }

    static func finish(_ id: String, _ starts: [Start], _ expansions: [(Double, Double, Int, Int)],
                               _ roads: [[(Double, Double)]], seed: UInt64, walls: [Wall] = [],
                               bridges: [(Double, Double, Double, Double)] = [],
                               ridges: [(Double, Double, Double, Double)] = []) -> [String: Any] {
        let meta = info(id)!
        setWorldSize(size(id).width, size(id).height)  // helpers below read worldW/worldH
        let blockers = walls.map { SRect($0.0, $0.1, $0.2, $0.3) } + bridges.map { SRect($0.0, $0.1, $0.2, $0.3) }
        var crystals: [[Any]] = [], clearings: [(Double, Double, Double)] = []
        var variant = 0
        for s in starts {
            clearings.append((s.x, s.y, 470))
            for i in 0..<8 {
                let a = s.angle + Double(i) / 7 * (.pi / 2)
                let d: Double = i % 2 == 0 ? 255 : 285
                crystals.append([s.x + cos(a) * d, s.y + sin(a) * d, 1500, variant % 3])
                variant += 1
            }
        }
        for (x, y, n, amount) in expansions {
            clearings.append((x, y, 300))
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * .pi + 0.3
                // A gold deposit is an expansion worth goldAmount a node; its nodes are drawn gold (variant 3).
                crystals.append([x + cos(a) * 70, y + sin(a) * 70, amount, amount >= goldAmount ? 3 : variant % 3])
                variant += 1
            }
        }
        var rng = SeededRNG(seed)
        var trees: [[Double]] = []
        func allowed(_ x: Double, _ y: Double) -> Bool {
            if x < 20 || y < 20 || x > worldW - 20 || y > worldH - 20 { return false }
            if clearings.contains(where: { hyp(x - $0.0, y - $0.1) < $0.2 + 40 }) { return false }
            if distToRoads(roads, x, y) < 150 { return false }
            if blockers.contains(where: { $0.distance(x, y) < 60 }) { return false }
            return !trees.contains { hyp(x - $0[0], y - $0[1]) < 46 }
        }
        var sites: [(Double, Double)] = []
        for _ in 0..<34 {
            let cx = Double.random(in: 150...(worldW - 150), using: &rng), cy = Double.random(in: 150...(worldH - 150), using: &rng)
            for _ in 0..<Int.random(in: 5...12, using: &rng) {
                let a = Double.random(in: 0...(2 * .pi), using: &rng), d = Double.random(in: 0...120, using: &rng)
                sites.append((cx + cos(a) * d, cy + sin(a) * d))
            }
        }
        var e = 30.0
        while e < max(worldW, worldH) {
            sites += [(e, Double.random(in: 25...110, using: &rng)), (e, worldH - Double.random(in: 25...110, using: &rng)),
                      (Double.random(in: 25...110, using: &rng), e), (worldW - Double.random(in: 25...110, using: &rng), e)]
            e += Double.random(in: 45...75, using: &rng)
        }
        for (x, y) in sites where allowed(x, y) {
            trees.append([x, y, 20, Double(Int.random(in: 0...2, using: &rng)), Double.random(in: 0...360, using: &rng),
                          Double.random(in: 0.8...1.15, using: &rng)])
        }
        return ["id": id, "name": meta.name, "players": meta.players, "w": worldW, "h": worldH, "seed": Int(seed),
                "walls": walls.map { [$0.0, $0.1, $0.2, $0.3, $0.4] as [Any] },
                "bridges": bridges.map { [$0.0, $0.1, $0.2, $0.3] },
                "ridges": ridges.map { [$0.0, $0.1, $0.2, $0.3] },
                "starts": starts.map { [$0.x, $0.y, $0.angle] },
                "expansions": expansions.map { [$0.0, $0.1, $0.2, $0.3] as [Any] },
                "crystals": crystals, "clearings": clearings.map { [$0.0, $0.1, $0.2] },
                "roads": roads.map { $0.map { [$0.0, $0.1] } },
                "trees": trees.map { [$0[0], $0[1], $0[2], Int($0[3]), $0[4], $0[5]] as [Any] }]
    }

    static func twinRidges() -> [String: Any] {
        setWorldSize(size("twin_ridges").width, size("twin_ridges").height)
        let ps = (560.0, 560.0), es = (worldW - 560, worldH - 560)
        return finish("twin_ridges", [Start(x: ps.0, y: ps.1, angle: .pi), Start(x: es.0, y: es.1, angle: 0)],
                      [(2000, 480, 6, 1000), (2000, 2320, 6, 1000), (520, 2280, 6, 1000), (3480, 520, 6, 1000), (2000, 1400, 4, goldAmount)],
                      [[ps, (1150, 820), (1600, 1250), (2000, 1400), (2400, 1550), (2850, 1980), es],
                       [(1600, 1250), (1850, 800), (2000, 600)], [(2400, 1550), (2150, 2000), (2000, 2200)],
                       [ps, (700, 1400), (560, 2150)], [es, (3300, 1400), (3440, 650)]], seed: 42, ridges: twinRidgesRidges)
    }

    // High ground, as mapgen.py places it: plateaus flanking the gold (Twin Ridges, Four Corners) and on the
    // middle side of each outer pass (Highland Pass).
    static let twinRidgesRidges: [(Double, Double, Double, Double)] = [(1350, 950, 1750, 1250), (2250, 1550, 2650, 1850)]
    static let highlandPassRidges: [(Double, Double, Double, Double)] = [(600, 1140, 940, 1380), (3060, 1420, 3400, 1660)]
    static let fourCornersRidges: [(Double, Double, Double, Double)] = [(1500, 1150, 1800, 1650), (2200, 1150, 2500, 1650)]

    static func fourCorners() -> [String: Any] {
        setWorldSize(size("four_corners").width, size("four_corners").height)
        let bl = (560.0, 560.0), br = (worldW - 560, 560.0), tl = (560.0, worldH - 560), tr = (worldW - 560, worldH - 560)
        let c = (worldW / 2, worldH / 2)
        return finish("four_corners",
                      [Start(x: bl.0, y: bl.1, angle: .pi), Start(x: tr.0, y: tr.1, angle: 0),
                       Start(x: br.0, y: br.1, angle: 1.5 * .pi), Start(x: tl.0, y: tl.1, angle: 0.5 * .pi)],
                      [(2000, 430, 6, 1000), (2000, 2370, 6, 1000), (430, 1400, 6, 1000), (3570, 1400, 6, 1000), (c.0, c.1, 4, goldAmount)],
                      [[bl, (1300, 950), c], [br, (2700, 950), c], [tl, (1300, 1850), c], [tr, (2700, 1850), c],
                       [bl, (1300, 520), (2000, 560), (2700, 520), br], [tl, (1300, 2280), (2000, 2240), (2700, 2280), tr],
                       [bl, (560, 1400), tl], [br, (3440, 1400), tr]], seed: 7, ridges: fourCornersRidges)
    }

    private static func rot(_ p: (Double, Double)) -> (Double, Double) { (worldW - p.0, worldH - p.1) }

    static func riverCrossing() -> [String: Any] {
        setWorldSize(size("river_crossing").width, size("river_crossing").height)
        let lb = (620.0, 1400.0), rb = rot(lb)
        return finish("river_crossing", [Start(x: lb.0, y: lb.1, angle: 0.75 * .pi), Start(x: rb.0, y: rb.1, angle: 1.75 * .pi)],
                      [(560, 380, 6, 1000), (560, 2420, 6, 1000), (3440, 380, 6, 1000), (3440, 2420, 6, 1000),
                       (1450, 1400, 4, goldAmount), (2550, 1400, 4, goldAmount)],
                      [[lb, (1150, 1400), (2000, 1400), (2850, 1400), rb],
                       [lb, (1100, 800), (2000, 660), (2900, 520), (3440, 520)],
                       [rb, (2900, 2000), (2000, 2140), (1100, 2280), (560, 2280)],
                       [lb, (560, 520)], [rb, (3440, 2280)]], seed: 11, walls: riverCrossingWalls, bridges: riverCrossingBridges)
    }

    static func highlandPass() -> [String: Any] {
        setWorldSize(size("highland_pass").width, size("highland_pass").height)
        let ps = (560.0, 560.0), es = rot(ps)
        return finish("highland_pass", [Start(x: ps.0, y: ps.1, angle: .pi), Start(x: es.0, y: es.1, angle: 0)],
                      [(420, 1400, 6, 1000), (3580, 1400, 6, 1000), (2000, 1400, 4, goldAmount), (2000, 480, 6, 1000), (2000, 2320, 6, 1000)],
                      [[ps, (770, 820), (770, 1300), (1660, 1500), (1660, 1950), (2600, 2200), es],
                       [ps, (1500, 700), (2340, 860), (2340, 1300), (3230, 1500), (3230, 1980), es],
                       [(770, 1300), (420, 1400)], [(3230, 1500), (3580, 1400)], [(1660, 1500), (2000, 1400), (2340, 1300)]],
                      seed: 23, walls: highlandPassWalls, ridges: highlandPassRidges)
    }

    static func crossroads() -> [String: Any] {
        setWorldSize(size("crossroads").width, size("crossroads").height)
        let left = (520.0, 1400.0), right = (worldW - 520, 1400.0), bottom = (2000.0, 520.0), top = (2000.0, worldH - 520)
        let c = (worldW / 2, worldH / 2)
        return finish("crossroads",
                      [Start(x: left.0, y: left.1, angle: 0.75 * .pi), Start(x: right.0, y: right.1, angle: 1.75 * .pi),
                       Start(x: bottom.0, y: bottom.1, angle: 1.25 * .pi), Start(x: top.0, y: top.1, angle: 0.25 * .pi)],
                      [(380, 380, 6, 1000), (3620, 380, 6, 1000), (380, 2420, 6, 1000), (3620, 2420, 6, 1000), (c.0, c.1, 4, goldAmount)],
                      [[left, c, right], [bottom, c, top],
                       [left, (560, 700), (380, 380)], [bottom, (1400, 420), (380, 380)],
                       [right, (3440, 2100), (3620, 2420)], [top, (2600, 2380), (3620, 2420)],
                       [left, (560, 2100), (380, 2420)], [top, (1400, 2380), (380, 2420)],
                       [right, (3440, 700), (3620, 380)], [bottom, (2600, 420), (3620, 380)]], seed: 31, walls: crossroadsWalls)
    }

    // river_crossing: generated by linux/fieldcommand/mapgen.py
    static let riverCrossingWalls: [Wall] = [(1836.6, 0, 2066.6, 140, "water"), (1827.7, 140, 2057.7, 280, "water"), (1825, 280, 2055, 420, "water"), (1829, 420, 2059, 560, "water"), (1862, 760, 2092, 900, "water"), (1881.4, 900, 2111.4, 1040, "water"), (1901.2, 1040, 2131.2, 1180, "water"), (1918, 1180, 2148, 1300, "water"), (1943.8, 1500, 2173.8, 1640, "water"), (1944.5, 1640, 2174.5, 1780, "water"), (1938.6, 1780, 2168.6, 1920, "water"), (1927.9, 1920, 2157.9, 2040, "water"), (1885.7, 2240, 2115.7, 2380, "water"), (1866, 2380, 2096, 2520, "water"), (1848.4, 2520, 2078.4, 2660, "water"), (1834.9, 2660, 2064.9, 2800, "water")]
    static let riverCrossingBridges: [(Double, Double, Double, Double)] = [(1805, 560, 2116, 760), (1894, 1300, 2197.8, 1500), (1861.7, 2040, 2181.9, 2240)]
    // highland_pass: generated by linux/fieldcommand/mapgen.py
    static let highlandPassWalls: [Wall] = [(0, 992.4, 139.2, 1118.3, "cliff"), (139.2, 978.7, 309.6, 1110, "cliff"), (309.6, 978.7, 429.7, 1124, "cliff"), (429.7, 981.1, 568.6, 1136.8, "cliff"), (568.6, 1004.3, 640, 1125.7, "cliff"), (900, 1007.9, 1039.1, 1104.7, "cliff"), (1039.1, 1009.3, 1171.2, 1103.7, "cliff"), (1171.2, 998.1, 1368.3, 1141, "cliff"), (1368.3, 989.3, 1506.1, 1114.7, "cliff"), (1506.1, 1001.2, 1639.8, 1098.2, "cliff"), (1639.8, 998.7, 1837.6, 1143.4, "cliff"), (1837.6, 1001.8, 2024.7, 1104.5, "cliff"), (2024.7, 1003.6, 2197, 1141.9, "cliff"), (2197, 1015.9, 2200, 1111.7, "cliff"), (2480, 1001.1, 2651.9, 1140.1, "cliff"), (2651.9, 1005.8, 2851.1, 1144.6, "cliff"), (2851.1, 1015.6, 2972.5, 1136.3, "cliff"), (2972.5, 971.3, 3146.7, 1120.8, "cliff"), (3146.7, 1008.4, 3305.6, 1114.7, "cliff"), (3305.6, 1004.4, 3473.3, 1095.2, "cliff"), (3473.3, 994.3, 3616.1, 1144.8, "cliff"), (3616.1, 975.7, 3748.7, 1118.3, "cliff"), (3748.7, 992.9, 3920.1, 1091.2, "cliff"), (3920.1, 997.8, 4000, 1101.7, "cliff"), (3860.8, 1681.7, 4000, 1807.6, "cliff"), (3690.4, 1690, 3860.8, 1821.3, "cliff"), (3570.3, 1676, 3690.4, 1821.3, "cliff"), (3431.4, 1663.2, 3570.3, 1818.9, "cliff"), (3360, 1674.3, 3431.4, 1795.7, "cliff"), (2960.9, 1695.3, 3100, 1792.1, "cliff"), (2828.8, 1696.3, 2960.9, 1790.7, "cliff"), (2631.7, 1659, 2828.8, 1801.9, "cliff"), (2493.9, 1685.3, 2631.7, 1810.7, "cliff"), (2360.2, 1701.8, 2493.9, 1798.8, "cliff"), (2162.4, 1656.6, 2360.2, 1801.3, "cliff"), (1975.3, 1695.5, 2162.4, 1798.2, "cliff"), (1803, 1658.1, 1975.3, 1796.4, "cliff"), (1800, 1688.3, 1803, 1784.1, "cliff"), (1348.1, 1659.9, 1520, 1798.9, "cliff"), (1148.9, 1655.4, 1348.1, 1794.2, "cliff"), (1027.5, 1663.7, 1148.9, 1784.4, "cliff"), (853.3, 1679.2, 1027.5, 1828.7, "cliff"), (694.4, 1685.3, 853.3, 1791.6, "cliff"), (526.7, 1704.8, 694.4, 1795.6, "cliff"), (383.9, 1655.2, 526.7, 1805.7, "cliff"), (251.3, 1681.7, 383.9, 1824.3, "cliff"), (79.9, 1708.8, 251.3, 1807.1, "cliff"), (0, 1698.3, 79.9, 1802.2, "cliff")]
    static let highlandPassBridges: [(Double, Double, Double, Double)] = []
    // crossroads: generated by linux/fieldcommand/mapgen.py
    static let crossroadsWalls: [Wall] = [(840, 690, 1400, 1030, "water"), (895.7, 977.8, 1156.5, 1128.6, "water"), (677.2, 794.6, 938.1, 965, "water"), (1309.6, 758.1, 1558.6, 936.9, "water"), (1116.2, 599.5, 1319.4, 729.8, "water"), (2600, 690, 3160, 1030, "water"), (2843.5, 977.8, 3104.3, 1128.6, "water"), (3061.9, 794.6, 3322.8, 965, "water"), (2441.4, 758.1, 2690.4, 936.9, "water"), (2680.6, 599.5, 2883.8, 729.8, "water"), (840, 1770, 1400, 2110, "water"), (895.7, 1671.4, 1156.5, 1822.2, "water"), (677.2, 1835, 938.1, 2005.4, "water"), (1309.6, 1863.1, 1558.6, 2041.9, "water"), (1116.2, 2070.2, 1319.4, 2200.5, "water"), (2600, 1770, 3160, 2110, "water"), (2843.5, 1671.4, 3104.3, 1822.2, "water"), (3061.9, 1835, 3322.8, 2005.4, "water"), (2441.4, 1863.1, 2690.4, 2041.9, "water"), (2680.6, 2070.2, 2883.8, 2200.5, "water")]
    static let crossroadsBridges: [(Double, Double, Double, Double)] = []

    static func grandArena() -> [String: Any] {
        setWorldSize(megaWorld.width, megaWorld.height)
        let cx = worldW / 2, cy = worldH / 2
        let rx = worldW * 0.385, ry = worldH * 0.375
        var starts: [Start] = [], expansions: [(Double, Double, Int, Int)] = [], roads: [[(Double, Double)]] = []
        var ring: [(Double, Double)] = []
        for i in 0..<12 {
            let a = Double(15 + i * 30) * .pi / 180
            let x = cx + cos(a) * rx, y = cy + sin(a) * ry
            starts.append(Start(x: x, y: y, angle: a - .pi / 4))
            ring.append((x, y))
            let ex = min(worldW - 200, max(200, cx + cos(a) * rx * 1.18))
            let ey = min(worldH - 200, max(200, cy + sin(a) * ry * 1.2))
            expansions.append((ex, ey, 6, 1000))
            if i % 2 == 0 {
                expansions.append((cx + cos(a + 0.26) * rx * 0.52, cy + sin(a + 0.26) * ry * 0.52, 5, 1400))
            }
        }
        expansions.append((cx, cy, 8, goldAmount))
        roads.append(ring + [ring[0]])
        for i in stride(from: 0, to: 12, by: 2) {
            roads.append([ring[i], (cx + (ring[i].0 - cx) * 0.4, cy + (ring[i].1 - cy) * 0.4), (cx, cy)])
        }
        return finish("grand_arena", starts, expansions, roads, seed: 61, walls: grandArenaWalls)
    }

    static func riverlands() -> [String: Any] {
        setWorldSize(megaWorld.width, megaWorld.height)
        let cx = worldW / 2, cy = worldH / 2
        var starts: [Start] = [], expansions: [(Double, Double, Int, Int)] = [], roads: [[(Double, Double)]] = []
        for q in 0..<4 {
            for off in [22.0, 45.0, 68.0] {
                let a = Double(q * 90) * .pi / 180 + off * .pi / 180
                let x = cx + cos(a) * worldW * 0.40, y = cy + sin(a) * worldH * 0.40
                starts.append(Start(x: x, y: y, angle: a - .pi / 4))
                expansions.append((cx + cos(a) * worldW * 0.27, cy + sin(a) * worldH * 0.27, 5, 1200))
                roads.append([(x, y), (cx + cos(a) * 1500, cy + sin(a) * 1050), (cx + cos(a) * 760, cy + sin(a) * 760)])
            }
            let a = Double(q * 90 + 45) * .pi / 180
            expansions.append((cx + cos(a) * 700, cy + sin(a) * 700, 6, 1600))
        }
        expansions.append((cx, cy, 8, goldAmount))
        let ring = (0..<12).map { k -> (Double, Double) in
            let a = Double(k * 30) * .pi / 180
            return (cx + cos(a) * worldW * 0.40, cy + sin(a) * worldH * 0.40)
        }
        roads.append(ring + [ring[0]])
        return finish("riverlands", starts, expansions, roads, seed: 73, walls: riverlandsWalls, bridges: riverlandsBridges)
    }

    // grand_arena: generated by linux/fieldcommand/mapgen.py
    static let grandArenaWalls: [Wall] = [(3475, 2431.2, 3995, 2771.2, "water"), (3543.3, 2298.8, 3784.9, 2492.4, "water"), (3345, 2500, 3553.8, 2683.8, "water"), (3612.3, 2734.3, 3910.8, 2864.3, "water"), (3553.9, 2312.2, 3758.9, 2482.6, "water"), (2005, 2431.2, 2525, 2771.2, "water"), (2265.2, 2730.9, 2496.7, 2869.5, "water"), (2240.2, 2330.8, 2459.1, 2473.4, "water"), (2280.2, 2724.3, 2519.3, 2856.5, "water"), (2199.6, 2312, 2471.4, 2480.6, "water"), (2005, 1428.8, 2525, 1768.8, "water"), (1837.9, 1459.4, 2103, 1580.5, "water"), (2425.7, 1445.2, 2704, 1610.6, "water"), (2447.1, 1531, 2707.4, 1697.7, "water"), (2473, 1452.5, 2655.8, 1640, "water"), (3475, 1428.8, 3995, 1768.8, "water"), (3794.5, 1713.6, 3981.5, 1891.8, "water"), (3642.4, 1312.9, 3836.9, 1482.8, "water"), (3882.4, 1437.2, 4187.5, 1631.6, "water"), (3639.9, 1728.9, 3838.1, 1860.9, "water")]
    // riverlands: generated by linux/fieldcommand/mapgen.py
    static let riverlandsWalls: [Wall] = [(5737.3, 2004.7, 6110, 2247.6, "water"), (5584.5, 1980, 5957.3, 2224.7, "water"), (5431.8, 1956.5, 5804.5, 2200, "water"), (4973.6, 1920, 5346.4, 2144.5, "water"), (4820.9, 1920, 5193.6, 2144.2, "water"), (4362.7, 1955.7, 4735.5, 2199.1, "water"), (4210, 1979.1, 4582.7, 2223.8, "water"), (2937.4, 3934, 3172.6, 4310, "water"), (2891.3, 3622, 3136.1, 3998, "water"), (2844.6, 3310, 3086.4, 3686, "water"), (-110, 2021.2, 262.7, 2261, "water"), (42.7, 2041, 415.5, 2274.5, "water"), (195.5, 2054.5, 568.2, 2279.9, "water"), (653.6, 2026.5, 1026.4, 2265, "water"), (806.4, 2003.5, 1179.1, 2246.5, "water"), (1264.5, 1936.4, 1637.3, 2175.4, "water"), (1417.3, 1924.1, 1790, 2156.4, "water"), (2821.2, -110, 3050.3, 266, "water"), (2847.2, 202, 3089.6, 578, "water"), (2894.7, 514, 3139.2, 890, "water"), (3882.2, 2273.9, 4053.1, 2444.7, "cliff"), (3868, 2337.2, 4056.1, 2525.3, "cliff"), (3840.1, 2407.6, 4010.6, 2578, "cliff"), (3810.3, 2470.9, 3981.5, 2642.1, "cliff"), (3781.6, 2531.8, 3971, 2721.2, "cliff"), (3746.4, 2594.6, 3933.6, 2781.8, "cliff"), (3693.2, 2646.3, 3851.7, 2804.7, "cliff"), (3664.6, 2713.9, 3836.3, 2885.6, "cliff"), (3593, 2742.3, 3767.2, 2916.4, "cliff"), (3566.5, 2818.1, 3724.5, 2976.1, "cliff"), (3498.5, 2845.2, 3654.1, 3000.8, "cliff"), (3450.6, 2902, 3607.5, 3058.9, "cliff"), (3378.7, 2916.3, 3530.5, 3068.1, "cliff"), (3314.5, 2941.9, 3463.6, 3091.1, "cliff"), (3237.9, 2953, 3408.1, 3123.2, "cliff"), (3177.7, 2986.7, 3341.4, 3150.4, "cliff"), (2654.9, 2992.2, 2822.1, 3159.4, "cliff"), (2588.3, 2974.8, 2752.7, 3139.1, "cliff"), (2523.1, 2963.3, 2678.2, 3118.3, "cliff"), (2452.3, 2908.3, 2632.3, 3088.3, "cliff"), (2384.9, 2876.1, 2570.8, 3061.9, "cliff"), (2343.4, 2839.5, 2506.7, 3002.7, "cliff"), (2291.8, 2802.5, 2445.8, 2956.4, "cliff"), (2236.8, 2742.6, 2406.5, 2912.3, "cliff"), (2180.4, 2697.6, 2352.9, 2870.1, "cliff"), (2107.4, 2651.3, 2296.9, 2840.8, "cliff"), (2083.4, 2604, 2245.5, 2766.1, "cliff"), (2045.1, 2525.3, 2230.6, 2710.8, "cliff"), (2017.4, 2462.9, 2199.9, 2645.4, "cliff"), (1995.2, 2407.6, 2162.2, 2574.5, "cliff"), (1949, 2335.5, 2137.1, 2523.5, "cliff"), (1924.8, 2272, 2107.9, 2455.1, "cliff"), (1952.4, 1757.5, 2121.1, 1926.3, "cliff"), (1950.6, 1676.9, 2139.1, 1865.3, "cliff"), (1969.4, 1610.4, 2150.5, 1791.5, "cliff"), (2016.8, 1561, 2171.8, 1716, "cliff"), (2038.3, 1489, 2204.7, 1655.3, "cliff"), (2093.9, 1442.7, 2246.5, 1595.3, "cliff"), (2128.9, 1377.1, 2312.1, 1560.4, "cliff"), (2195.2, 1344.4, 2347.2, 1496.4, "cliff"), (2234, 1284.5, 2396.9, 1447.4, "cliff"), (2280.3, 1231.1, 2448.8, 1399.6, "cliff"), (2353, 1207.8, 2501.5, 1356.3, "cliff"), (2402, 1158.2, 2563, 1319.2, "cliff"), (2455, 1113, 2626.6, 1284.6, "cliff"), (2519, 1079.8, 2685.7, 1246.5, "cliff"), (2585, 1061.4, 2760.1, 1236.5, "cliff"), (2646.9, 1022.4, 2822.7, 1198.2, "cliff"), (3169.5, 1032.6, 3353.3, 1216.5, "cliff"), (3241.9, 1077, 3406.1, 1241.1, "cliff"), (3300.6, 1097.6, 3475.9, 1272.9, "cliff"), (3372.8, 1129.4, 3534.1, 1290.7, "cliff"), (3450.7, 1149.1, 3601.5, 1299.8, "cliff"), (3491.7, 1202.4, 3652.6, 1363.3, "cliff"), (3558.6, 1222.3, 3726.7, 1390.4, "cliff"), (3599.1, 1265.2, 3784.7, 1450.8, "cliff"), (3648.1, 1334.4, 3815, 1501.3, "cliff"), (3685.2, 1381.6, 3866, 1562.3, "cliff"), (3723.3, 1440.7, 3903, 1620.5, "cliff"), (3775, 1496.5, 3947.2, 1668.7, "cliff"), (3796.4, 1553.1, 3983.3, 1740.1, "cliff"), (3840, 1624.3, 4007.3, 1791.6, "cliff"), (3883.3, 1679.5, 4056.4, 1852.6, "cliff"), (3890.4, 1761.3, 4048.4, 1919.3, "cliff")]
    static let riverlandsBridges: [(Double, Double, Double, Double)] = [(5298, 1940.7, 5526, 2160.7), (4693.2, 1934.8, 4921.2, 2154.8), (2921.7, 3858, 3141.7, 3996), (2877.5, 3577.2, 3097.5, 3715.2), (474, 2056.4, 702, 2276.4), (1078.8, 1983.6, 1306.8, 2203.6), (2842.6, 204, 3062.6, 342), (2883.3, 484.8, 3103.3, 622.8)]
}

/// Every random choice the simulation makes comes from this generator (seeded per world), so a game is a
/// pure function of its seed and the commands it receives — what makes replays and batch runs possible.
var simRNG = SeededRNG(1)

// MARK: - Entities

enum SOrder {
    case idle
    case move(Double, Double)
    case amove(Double, Double)
    case attack(SEntity)
    case gather(SCrystal)
    case ret
    case build(BuildingKind, Double, Double)
    case rebuild(SBridge)
    case repair(SEntity)          // a building, or a Siege Tank
    case heal(SUnit)

    var code: Int {
        switch self {
        case .idle: return 0
        case .move: return 1
        case .amove: return 2
        case .attack: return 3
        case .gather: return 4
        case .ret: return 5
        case .build: return 6
        case .rebuild: return 7
        case .repair: return 8
        case .heal: return 9
        }
    }
    var isIdle: Bool { if case .idle = self { return true }; return false }
}

/// A supply drop on the field: `kind` is a crateKinds entry, `amount` the crystal it holds.
final class SCrate {
    let id: Int
    let x, y: Double
    let kind: String
    let amount: Int
    let born: Double
    var dead = false
    let radius = crateRadius
    init(id: Int, x: Double, y: Double, kind: String, amount: Int, born: Double) {
        self.id = id; self.x = x; self.y = y; self.kind = kind; self.amount = amount; self.born = born
    }
}

final class SCrystal {
    let id: Int
    let x, y: Double
    let radius = 18.0
    var amount: Int
    let variant: Int
    var dead = false

    init(id: Int, x: Double, y: Double, amount: Int, variant: Int) {
        self.id = id; self.x = x; self.y = y; self.amount = amount; self.variant = variant
    }

    func extract(_ n: Int) -> Int {
        let a = min(n, amount)
        amount -= a
        if amount <= 0 { dead = true }
        return a
    }
}

/// A crossing the map ships with. Nobody owns it: any player can shell it down and any Engineer can
/// rebuild it. While it stands it is pure decoration — the water simply is not there. Once it falls, its
/// footprint blocks movement and line of fire exactly like the stream it spans.
final class SBridge: SEntity {
    let rect: SRect
    var intact = true
    var progress = 0.0          // rebuild progress, 0..1

    init(world: SWorld, rect: SRect) {
        self.rect = rect
        super.init(world: world, team: -1, maxHp: bridgeHP, sight: 0,
                   x: (rect.x0 + rect.x1) / 2, y: (rect.y0 + rect.y1) / 2)
    }

    override func surfaceDistance(_ px: Double, _ py: Double) -> Double { rect.distance(px, py) }

    /// Ruins are rebuilt, not shot at again.
    override func targetable(by slot: Int) -> Bool { intact }

    /// Neutral, so no owner is alerted — but everyone is told when a crossing goes down.
    override func takeDamage(_ amount: Double, from attacker: SEntity?) {
        guard intact else { return }
        hp -= amount
        guard hp <= 0 else { return }
        hp = 0
        intact = false
        progress = 0
        world.emit(["explode", x, y, 34, 1, 0])
        world.emit(["smoke", x, y, 30])
        world.emit(["sound", "explosion", x, y])
        world.emit(["bridge", id, 0, x, y])
        world.bridgesChanged()
    }

    func restore() {
        intact = true
        hp = maxHp
        progress = 0
        world.emit(["flash", x, y, 90, "build"])
        world.emit(["sound", "complete", x, y])
        world.emit(["bridge", id, 1, x, y])
        world.bridgesChanged()
    }
}

/// A neutral control point. Troops of one alliance alone inside its radius for `towerCaptureTime` take it; the
/// owner then sees `towerSight` around it. It is never damaged, only taken.
final class SWatchtower {
    unowned let world: SWorld
    let id: Int
    let x, y: Double
    let rect: SRect
    var owner: Int?          // slot of the player who holds it
    var capturing: Int?      // slot whose troops are taking it
    var progress = 0.0

    init(world: SWorld, x: Double, y: Double) {
        self.world = world
        id = world.nextId()
        self.x = x
        self.y = y
        rect = SRect(cx: x, cy: y, half: towerHalf)
    }

    func update(_ dt: Double) {
        let g = world
        var present: [Int: Int] = [:]      // alliance -> a slot in it
        for u in g.units where !u.dead && hyp(u.x - x, u.y - y) <= towerRadius {
            if let a = g.players[u.team]?.team, present[a] == nil { present[a] = u.team }
        }
        let ownerAlliance = owner.flatMap { g.players[$0]?.team }
        if present.count == 1, let (alliance, slot) = present.first {
            if alliance == ownerAlliance {
                capturing = nil
                progress = 0
            } else {
                if capturing == nil || g.players[capturing!]?.team != alliance {
                    capturing = slot
                    progress = 0
                }
                progress += dt / towerCaptureTime
                if progress >= 1 {
                    owner = slot
                    capturing = nil
                    progress = 0
                    g.emit(["flash", x, y, 80, "team\(slot)"])
                    g.emit(["sound", "complete", x, y])
                    g.emit(["tower", slot, id, x, y])
                }
            }
        } else {
            // Nobody, or a contested ring: the clock winds back.
            progress = max(0, progress - dt / towerCaptureTime)
            if progress == 0 { capturing = nil }
        }
    }
}

class SEntity {
    /// Can this thing shoot an aircraft? Units answer from their stats, buildings from airGuns.
    var hitsAir: Bool { true }
    unowned let world: SWorld
    let id: Int
    let team: Int
    var hp: Double
    var maxHp: Double
    var sight: Double
    var x, y: Double
    var dead = false
    var visMask = 0
    var revealedMask = 0
    var isBuilding: Bool { false }
    var bodyRadius: Double { 0 }

    init(world: SWorld, team: Int, maxHp: Double, sight: Double, x: Double, y: Double) {
        self.world = world
        id = world.nextId()
        self.team = team
        hp = maxHp
        self.maxHp = maxHp
        self.sight = sight
        self.x = x
        self.y = y
    }

    func surfaceDistance(_ px: Double, _ py: Double) -> Double { hyp(px - x, py - y) }
    func distanceTo(_ o: SEntity) -> Double { o.surfaceDistance(x, y) - bodyRadius }

    func targetable(by slot: Int) -> Bool {
        if world.isAI(slot) || world.allied(team, slot) { return true }
        let bit = world.allianceBit(slot)
        return (visMask & bit) != 0 || (isBuilding && (revealedMask & bit) != 0)
    }

    func takeDamage(_ amount: Double, from attacker: SEntity?) {
        guard !dead else { return }
        hp -= amount
        if hp <= 0 {
            hp = 0
            dead = true
            if let a = attacker as? SUnit, !a.dead, a.team != team { a.creditKill() }
        }
        if let a = attacker { world.reveal(a, victim: team) }
        world.alertAttack(team, x, y)
        onDamaged(attacker)
    }

    func onDamaged(_ attacker: SEntity?) {}
}

final class SUnit: SEntity {
    let kind: UnitKind
    let stats: UnitStats
    var order: SOrder = .idle
    var queued: [SOrder] = []
    var resumePoint: (Double, Double)?
    var cooldown = 0.0
    var carrying = 0
    var homeCrystal: SCrystal?
    var resumeGather: SCrystal?
    var mineTimer = 0.0, buildTimer = 0.0, stuck = 0.0
    // Siege mode (tanks only) and the time left in a transition.
    var mode: SiegeMode = .mobile
    var modeTimer = 0.0
    // Veterancy: kills so far and the rank they have earned.
    var kills = 0
    var rank = 0
    var lastX: Double, lastY: Double
    var wasMoving = false
    var scan = Double.random(in: 0...0.3, using: &simRNG)
    var blocked: (Double, Double)?
    var slideSign = 0.0
    var angle = Double.random(in: 0...(2 * .pi), using: &simRNG)
    var gunAngle: Double
    // Path state (see navigate)
    var path: [(Double, Double)]?
    var pathGoal: (Double, Double)?
    var pathVersion = -1
    var repath = 0.0, shortcut = 0.0
    var radius: Double { Double(stats.radius) }
    override var bodyRadius: Double { radius }

    init(world: SWorld, kind: UnitKind, team: Int, x: Double, y: Double) {
        self.kind = kind
        stats = kind.stats
        lastX = x
        lastY = y
        gunAngle = 0
        super.init(world: world, team: team, maxHp: Double(kind.stats.hp), sight: Double(kind.stats.sight), x: x, y: y)
        gunAngle = angle
        // Kit bought from the Armory is worn from the moment the unit exists.
        let bonus = Double(kind.stats.hp) * kit("hp")
        maxHp += bonus
        hp = maxHp
    }

    // MARK: The Armory

    func kit(_ key: String) -> Double { world.kitBonus(team, kind, key) }
    var speed: Double { Double(stats.speed) * (1 + kit("speed")) }
    var carryCapacity: Int { carryCap + Int(kit("carry")) }
    var workMult: Double { 1 + kit("work") }

    var ghosting: Bool {
        guard kind == .worker else { return false }
        switch order {
        case .gather, .ret: return true
        default: return false
        }
    }

    override func surfaceDistance(_ px: Double, _ py: Double) -> Double { hyp(px - x, py - y) - radius }

    func refundBuilds(includeCurrent: Bool) {
        if includeCurrent, case .build(let k, _, _) = order { world.refund(k.stats.cost, team) }
        if includeCurrent, case .rebuild = order { world.refund(bridgeCost, team) }
        for q in queued {
            if case .build(let k, _, _) = q { world.refund(k.stats.cost, team) }
            if case .rebuild = q { world.refund(bridgeCost, team) }
        }
    }

    func command(_ o: SOrder) {
        refundBuilds(includeCurrent: true)
        queued = []
        order = o
        resumePoint = nil
        stuck = 0
        mineTimer = 0
        buildTimer = 0
    }

    func enqueue(_ o: SOrder) {
        if order.isIdle && queued.isEmpty { command(o) } else { queued.append(o) }
    }

    func orderHeal(_ u: SUnit, queue: Bool) {
        if queue && !(order.isIdle && queued.isEmpty) {
            queued.append(.heal(u))
            return
        }
        command(.heal(u))
    }

    func orderRepair(_ b: SEntity, queue: Bool) {
        if queue && !(order.isIdle && queued.isEmpty) {
            queued.append(.repair(b))
            return
        }
        switch order {
        case .gather(let c): resumeGather = c
        case .ret: resumeGather = homeCrystal
        default: resumeGather = nil
        }
        command(.repair(b))
    }

    /// After repairing, an Engineer goes back to what it was doing, as it does after placing a building.
    private func afterWork() {
        let rg = resumeGather
        resumeGather = nil
        if !queued.isEmpty { order = .idle }
        else if carrying > 0 { order = .ret }
        else if let rg, !rg.dead { order = .gather(rg) }
        else { order = .idle }
    }

    func orderBuild(_ k: BuildingKind, _ bx: Double, _ by: Double, queue: Bool) {
        if queue && !(order.isIdle && queued.isEmpty) {
            queued.append(.build(k, bx, by))
            return
        }
        switch order {
        case .gather(let c): resumeGather = c
        case .ret: resumeGather = homeCrystal
        default: resumeGather = nil
        }
        command(.build(k, bx, by))
    }

    private func finishAttack() {
        if let r = resumePoint {
            order = .amove(r.0, r.1)
            resumePoint = nil
        } else {
            order = .idle
        }
    }

    private func closeEnough(_ px: Double, _ py: Double, _ slack: Double) -> Bool {
        let d = hyp(px - x, py - y)
        return d < slack || (stuck > 0.5 && d < radius * 4 + 30) || stuck > 3
    }

    // MARK: Veterancy

    /// Damage multiplier: veterancy and kit together.
    var vetMult: Double { (1 + vetBonus * Double(rank)) * (1 + kit("damage")) }

    func creditKill() {
        kills += 1
        let newRank = vetThresholds.filter { kills >= $0 }.count
        if newRank > rank {
            let added = Double(stats.hp) * vetBonus * Double(newRank - rank)
            rank = newRank
            maxHp += added
            hp = min(maxHp, hp + added)
            world.emit(["flash", x, y, 40, "team\(team)"])
            world.emit(["rank", team, id, rank, x, y])
        }
    }

    // MARK: Siege mode

    var sieged: Bool { mode == .sieged }
    var canSiege: Bool { kind == .tank }
    var attackRange: Double { (sieged ? siegeRange : Double(stats.range)) + kit("range") + (world.onHigh(x, y) ? highRange : 0) }
    var minRange: Double { sieged ? siegeMinRange : 0 }
    override var sight: Double {
        get { (sieged ? siegeSight : super.sight) * (world.onHigh(x, y) ? highSight : 1) }
        set { super.sight = newValue }
    }

    func inRange(_ t: SEntity) -> Bool {
        let d = distanceTo(t)
        return d >= minRange && d <= attackRange
    }

    /// Starts digging in or packing up; a no-op if already there or on the way.
    func setSiege(_ on: Bool) {
        guard canSiege else { return }
        if on && (mode == .mobile || mode == .unsieging) {
            mode = .sieging
            modeTimer = siegeTransition
            path = nil
        } else if !on && (mode == .sieged || mode == .sieging) {
            mode = .unsieging
            modeTimer = siegeTransition
        }
    }

    func update(_ dt: Double) {
        let g = world
        cooldown = max(0, cooldown - dt)
        scan -= dt
        let moved = hyp(x - lastX, y - lastY)
        if wasMoving && moved < speed * dt * 0.3 { stuck += dt } else { stuck = max(0, stuck - dt * 2) }
        lastX = x
        lastY = y
        wasMoving = false
        if mode == .sieging || mode == .unsieging {
            modeTimer -= dt
            if modeTimer <= 0 {
                mode = mode == .sieging ? .sieged : .mobile
                modeTimer = 0
                if mode == .sieged { g.emit(["sound", "siege", x, y]) }
            }
            return          // switching: no orders, no shots
        }
        var target: (Double, Double)?

        switch order {
        case .idle:
            if kind == .medic {
                if scan <= 0 && queued.isEmpty {
                    scan = 0.3
                    if let w = g.findWounded(self, sight) { order = .heal(w) }
                }
            } else if kind != .worker && scan <= 0 && queued.isEmpty {
                scan = 0.3
                if let t = g.findTarget(self, sight, minRange: minRange) { order = .attack(t) }
            }
        case .move(let px, let py):
            if closeEnough(px, py, 5) {
                order = .idle
                stuck = 0
            } else {
                target = (px, py)
            }
        case .amove(let px, let py):
            var engaged = false
            if scan <= 0 {
                scan = 0.25
                if kind == .medic {
                    // A Medic on attack-move advances with the line and stops for anyone wounded on the way.
                    if let w = g.findWounded(self, sight) {
                        resumePoint = (px, py)
                        order = .heal(w)
                        engaged = true
                    }
                } else if let t = g.findTarget(self, sight, minRange: minRange) {
                    resumePoint = (px, py)
                    order = .attack(t)
                    engaged = true
                }
            }
            if !engaged {
                if closeEnough(px, py, 8) {
                    order = .idle
                    stuck = 0
                } else {
                    target = (px, py)
                }
            }
        case .heal(let w):
            if w.dead || w.hp >= w.maxHp || !g.allied(w.team, team) || stuck > 3 {
                finishAttack()      // back to the attack-move it was on, or idle
            } else if distanceTo(w) - w.radius - radius > healRange {
                target = (w.x, w.y)       // keeps up with a patient on the move
            } else {
                aim(w.x, w.y, dt)
                w.hp = min(w.maxHp, w.hp + healRate * (1 + kit("heal")) * dt)
                mineTimer += dt
                if mineTimer > 0.45 {
                    mineTimer = 0
                    g.emit(["pulse", id])
                    g.emit(["sparks", w.x, w.y, 3, 30, "heal"])
                }
                if w.hp >= w.maxHp { finishAttack() }
            }
        case .attack(let t):
            if t.dead || !t.targetable(by: team) || kind == .medic {
                finishAttack()
                break
            }
            if scan <= 0 && kind != .worker {
                scan = 0.4
                let armed = (t as? SUnit).map { $0.kind != .worker } ?? false
                if !armed, let better = g.findTarget(self, attackRange + 20, minRange: minRange) as? SUnit, better.kind != .worker {
                    order = .attack(better)
                    break
                }
            }
            if inRange(t) {
                aim(t.x, t.y, dt)
                if cooldown <= 0 { fire(t) }
            } else if sieged {
                // Dug in: hold and wait for it to come into the ring rather than chase it.
                if distanceTo(t) < minRange && scan <= 0 {
                    scan = 0.4
                    if let other = g.findTarget(self, attackRange, minRange: minRange) { order = .attack(other) }
                }
            } else {
                target = (t.x, t.y)
            }
        case .gather(let c):
            if carrying >= carryCapacity {
                order = .ret
            } else if c.dead {
                if let n = g.nearestCrystal(c.x, c.y, 500) { order = .gather(n) } else { order = carrying > 0 ? .ret : .idle }
            } else {
                homeCrystal = c
                let d = hyp(c.x - x, c.y - y) - c.radius - radius
                if d > 4 {
                    target = (c.x, c.y)
                    mineTimer = 0
                } else {
                    aim(c.x, c.y, dt)
                    let before = mineTimer
                    mineTimer += dt
                    if Int(before / 0.45) != Int(mineTimer / 0.45) {
                        let k = (radius + 4) / max(1e-3, hyp(c.x - x, c.y - y))
                        g.emit(["pulse", id])
                        g.emit(["sparks", x + (c.x - x) * k, y + (c.y - y) * k, 3, 35, "crystal"])
                    }
                    if mineTimer >= 1.6 {
                        mineTimer = 0
                        carrying = c.extract(8)
                        order = .ret
                    }
                }
            }
        case .ret:
            if carrying <= 0 {
                if let hc = homeCrystal, !hc.dead { order = .gather(hc) } else { order = .idle }
            } else if let hq = g.nearestDropoff(team, x, y) {
                if distanceTo(hq) > 6 {
                    target = (hq.x, hq.y)
                } else {
                    g.deposit(carrying, team, x, y)
                    carrying = 0
                    if !queued.isEmpty {
                        order = .idle
                    } else if let hc = homeCrystal, !hc.dead {
                        order = .gather(hc)
                    } else if let n = g.nearestCrystal(x, y, 700) {
                        order = .gather(n)
                    } else {
                        order = .idle
                    }
                }
            } else {
                order = .idle
            }
        case .build(let bk, let sx, let sy):
            let r = SRect(cx: sx, cy: sy, half: Double(bk.stats.half))
            buildTimer += dt
            if stuck > 3 || buildTimer > 45 {
                g.refund(bk.stats.cost, team)
                order = .idle
                buildTimer = 0
                g.emit(["msg", team, "An Engineer couldn't reach the build site", "bad"])
            } else if r.distance(x, y) - radius > 10 {
                target = (sx, sy)
            } else if g.canPlace(bk, sx, sy, ignoring: self) {
                g.startBuilding(bk, sx, sy, team)
                if !queued.isEmpty {
                    order = .idle
                } else if carrying > 0 {
                    order = .ret
                } else if let rg = resumeGather, !rg.dead {
                    order = .gather(rg)
                } else {
                    order = .idle
                }
                resumeGather = nil
            } else {
                g.refund(bk.stats.cost, team)
                order = .idle
                g.emit(["msg", team, "Build site blocked", "bad"])
            }
        case .rebuild(let b):
            buildTimer += dt
            if b.intact {
                // Someone else finished it first; the crystal goes back.
                g.refund(bridgeCost, team)
                order = .idle
                buildTimer = 0
            } else if stuck > 3 || buildTimer > 60 {
                g.refund(bridgeCost, team)
                order = .idle
                buildTimer = 0
                g.emit(["msg", team, "An Engineer couldn't reach the bridge", "bad"])
            } else if b.surfaceDistance(x, y) - radius > 12 {
                target = (b.x, b.y)
            } else {
                b.progress = min(1, b.progress + dt * workMult / bridgeRebuildTime)
                mineTimer += dt
                if mineTimer > 0.45 {       // reuse the mining bob so the work reads at a glance
                    mineTimer = 0
                    g.emit(["pulse", id])
                    g.emit(["sparks", x, y, 2, 30, "amber"])
                }
                if b.progress >= 1 {
                    b.restore()
                    order = .idle
                    buildTimer = 0
                }
            }
        case .repair(let b):                    // a building, or a Siege Tank
            if b.dead || b.hp >= b.maxHp || !g.allied(b.team, team) {
                afterWork()
            } else if stuck > 3 {
                afterWork()
                g.emit(["msg", team, "An Engineer couldn't reach the \(b.isBuilding ? "building" : "tank")", "bad"])
            } else if b.surfaceDistance(x, y) - radius > 12 {
                target = (b.x, b.y)
            } else {
                let cost = (b as? SBuilding).map { Double($0.stats.cost) } ?? (b as? SUnit).map { Double($0.stats.cost) } ?? 0
                let heal = min(b.maxHp - b.hp, b.maxHp * dt * workMult / repairTime)
                let price = heal / b.maxHp * cost * repairCostRatio
                if (g.resources[team] ?? 0) < price {
                    // Out of crystal: stop rather than repair on credit.
                    afterWork()
                    g.emit(["msg", team, "Not enough crystal to keep repairing", "bad"])
                } else {
                    g.resources[team, default: 0] -= price
                    b.hp += heal
                    mineTimer += dt
                    if mineTimer > 0.45 {       // the same work bob as mining and rebuilding
                        mineTimer = 0
                        g.emit(["pulse", id])
                        g.emit(["sparks", x, y, 2, 30, "amber"])
                    }
                    if b.hp >= b.maxHp {
                        b.hp = b.maxHp
                        afterWork()
                    }
                }
            }
        }
        if order.isIdle && !queued.isEmpty {
            order = queued.removeFirst()
            stuck = 0
            buildTimer = 0
        }
        if let (tx, ty) = target {
            if sieged { setSiege(false) } else { navigate(tx, ty, dt) }   // going somewhere packs the tank up first
        }
    }

    /// How much of the approach line to ignore: the target's own footprint is solid by design.
    private func goalClearance() -> Double {
        switch order {
        case .attack(let t): return (t as? SBuilding).map { $0.half + 30 } ?? 30
        case .gather: return 40
        case .rebuild: return 40
        case .repair(let b): return ((b as? SBuilding)?.half ?? 0) + 30
        case .heal: return 30
        case .ret: return 120
        default: return 0
        }
    }

    /// Walks straight at the goal when the way is clear, otherwise follows an A* path around obstacles.
    override var hitsAir: Bool { stats.hitsAir }

    private func navigate(_ tx: Double, _ ty: Double, _ dt: Double) {
        let g = world, nav = g.nav
        if stats.flies {                       // aircraft fly straight: nothing on the ground is in their way
            path = nil
            moveToward(tx, ty, dt)
            return
        }
        repath -= dt
        let goalMoved = pathGoal.map { hyp(tx - $0.0, ty - $0.1) > 60 } ?? true
        let need = goalMoved || pathVersion != nav.version || (stuck > 0.7 && path != nil)
        if need && repath <= 0 {
            if nav.lineClear(x, y, tx, ty, ignoreEnd: goalClearance()) {
                path = nil
                repath = 0.3
            } else if g.pathBudget > 0 {
                g.pathBudget -= 1
                let p = nav.findPath(x, y, tx, ty)
                path = p.isEmpty ? nil : p
                repath = 1.0
                stuck = 0
            } else {
                repath = 0.05  // out of pathfinding budget this tick; retry shortly
            }
            if repath >= 0.3 {
                pathGoal = (tx, ty)
                pathVersion = nav.version
            }
        }
        var sx = tx, sy = ty
        if var p = path, !p.isEmpty {
            while p.count > 1 && hyp(p[0].0 - x, p[0].1 - y) < 28 { p.removeFirst() }
            shortcut -= dt
            if shortcut <= 0 {
                shortcut = 0.3
                if p.count > 1 && nav.lineClear(x, y, p[1].0, p[1].1) {
                    p.removeFirst()
                } else if !nav.lineClear(x, y, p[0].0, p[0].1) {
                    // Pushed off course (e.g. by other units): the next waypoint is hidden, so re-plan.
                    pathGoal = nil
                    repath = 0
                }
            }
            path = p
            (sx, sy) = p[0]
            if p.count == 1 && hyp(sx - tx, sy - ty) <= 60 { (sx, sy) = (tx, ty) }
        }
        moveToward(sx, sy, dt)
    }

    private func moveToward(_ px: Double, _ py: Double, _ dt: Double) {
        let dx = px - x, dy = py - y
        let d = hyp(dx, dy)
        guard d >= 0.5 else { return }
        var ux = dx / d, uy = dy / d
        if let (nx, ny) = blocked {
            let dot = ux * nx + uy * ny
            if dot < 0 {
                if slideSign == 0 { slideSign = nx * uy - ny * ux >= 0 ? 1 : -1 }
                let tx = ux - nx * dot, ty = uy - ny * dot
                let tl = hyp(tx, ty)
                if tl < 0.35 { ux = -ny * slideSign; uy = nx * slideSign } else { ux = tx / tl; uy = ty / tl }
            }
        } else {
            slideSign = 0
        }
        let step = min(d, speed * dt)
        x += ux * step
        y += uy * step
        angle = angLerp(angle, atan2(uy, ux), dt * 10)
        if kind == .tank, case .attack = order {} else if kind == .tank { gunAngle = angLerp(gunAngle, angle, dt * 6) }
        wasMoving = true
    }

    private func aim(_ px: Double, _ py: Double, _ dt: Double) {
        let a = atan2(py - y, px - x)
        if kind == .tank { gunAngle = angLerp(gunAngle, a, dt * 8) } else { angle = angLerp(angle, a, dt * 14) }
    }

    private func fire(_ t: SEntity) {
        let g = world
        cooldown = (sieged ? siegeCooldown : Double(stats.cooldown)) * (1 - kit("cooldown"))
        let d = max(1e-3, hyp(t.x - x, t.y - y))
        let ux = (t.x - x) / d, uy = (t.y - y) / d
        let ang = atan2(uy, ux)
        let jx = Double.random(in: -6...6, using: &simRNG), jy = Double.random(in: -6...6, using: &simRNG)
        g.emit(["recoil", id])
        switch kind {
        case .tank:
            let mx = x + ux * 33, my = y + uy * 33
            g.launchShell(mx, my, t.x + jx, t.y + jy, (sieged ? siegeDamage : Double(stats.damage)) * vetMult,
                          sieged ? siegeSplash : Double(stats.splash), team, self)
            g.emit(["muzzle", mx, my, ang, sieged ? 32 : 26])
            g.emit(["smoke", mx, my, sieged ? 11 : 8])
            g.emit(["sound", "cannon", x, y])
        case .sniper:
            let mx = x + ux * 26 + uy * 3, my = y + uy * 26 - ux * 3
            t.takeDamage(Double(stats.damage) * vetMult, from: self)
            g.emit(["tracer", mx, my, t.x, t.y, 2])
            g.emit(["muzzle", mx, my, ang, 18])
            g.emit(["sparks", t.x, t.y, 6, 90, "hit"])
            g.emit(["sound", "snipe", x, y])
        case .marine:
            let mx = x + ux * 20 + uy * 4.5, my = y + uy * 20 - ux * 4.5
            t.takeDamage(Double(stats.damage) * vetMult, from: self)
            g.emit(["tracer", mx, my, t.x + jx, t.y + jy, 0])
            g.emit(["muzzle", mx, my, ang, 12])
            if Bool.random(using: &simRNG) { g.emit(["sparks", t.x + jx, t.y + jy, 4, 60, "hit"]) }
            g.emit(["sound", "rifle", x, y])
        case .worker:
            t.takeDamage(Double(stats.damage) * vetMult, from: self)
            g.emit(["sparks", x + ux * (radius + 5), y + uy * (radius + 5), 3, 35, "amber"])
        case .gunship:
            // The chain gun under the nose: a bright tracer and a spark on every hit.
            let mx = x + ux * 16, my = y + uy * 16
            t.takeDamage(Double(stats.damage) * vetMult, from: self)
            g.emit(["tracer", mx, my, t.x + jx, t.y + jy, 1])
            g.emit(["muzzle", mx, my, ang, 10])
            g.emit(["sparks", t.x + jx, t.y + jy, 3, 50, "hit"])
            g.emit(["sound", "turret", x, y])
        case .medic:
            break                       // unarmed
        }
    }

    override func onDamaged(_ attacker: SEntity?) {
        guard let a = attacker, !a.dead, a.team != team, kind != .worker, kind != .medic else { return }
        if order.isIdle && queued.isEmpty { order = .attack(a) }
    }
}

final class SBuilding: SEntity {
    let kind: BuildingKind
    let stats: BuildingStats
    let half: Double
    let rect: SRect
    var built: Bool
    var progress: Double
    var queue: [UnitKind] = []
    var queueProgress = 0.0
    var rally: (Double, Double)?
    var cooldown = 0.0, scan = 0.0
    var turretTarget: SEntity?
    var gunAngle = Double.random(in: 0...(2 * .pi), using: &simRNG)
    // Shield points from a generator in range (see SWorld.updateShields), and when they were last hit.
    var shield = 0.0
    var shieldHit = -100.0
    var shielded = false
    // Upgrades: the set installed, and the one being researched with its progress 0..1, if any.
    var upgrades: Set<UpgradeKind> = []
    var upgrading: UpgradeKind?
    var upgradeProgress = 0.0
    override var isBuilding: Bool { true }

    // MARK: Upgrades

    func canUpgrade(_ k: UpgradeKind) -> Bool {
        built && !dead && k.applies(to: kind) && !upgrades.contains(k) && upgrading == nil
    }

    func startUpgrade(_ k: UpgradeKind) { upgrading = k; upgradeProgress = 0 }

    /// Stops the research and hands the crystal back.
    func cancelUpgrade() {
        guard let k = upgrading else { return }
        world.refund(k.cost(for: kind), team)
        upgrading = nil
        upgradeProgress = 0
    }

    private func install(_ k: UpgradeKind) {
        upgrades.insert(k)
        if k == .hp {
            let added = maxHp
            maxHp *= 2
            hp += added         // the new structure is sound
        }
        world.emit(["flash", x, y, half * 2.6, "team\(team)"])
        world.emit(["upgraded", team, NetProtocol.name(kind), k.wireName, id])
    }

    var supply: Int { stats.supply + (upgrades.contains(.supply) ? depotUpgradedSupply : 0) }
    var trainSpeed: Double { upgrades.contains(.prod) ? 2 : 1 }
    override var hitsAir: Bool { airGuns.contains(kind) }

    var turretRange: Double {
        (kind == .hq ? hqGunRange : (upgrades.contains(.guns) ? turretUpgradedRange : Double(stats.range))) + (world.onHigh(x, y) ? highRange : 0)
    }
    var turretDamage: Double { kind == .hq ? hqGunDamage : (upgrades.contains(.guns) ? turretUpgradedDamage : Double(stats.damage)) }

    override func takeDamage(_ amount: Double, from attacker: SEntity?) {
        var left = upgrades.contains(.armor) ? amount * armorFactor : amount
        if shield > 0 && left > 0 {
            let soaked = min(shield, left)
            shield -= soaked
            left -= soaked
            shieldHit = world.elapsed
            world.emit(["flash", x, y, half * 2.4, "shield"])
        }
        super.takeDamage(left, from: attacker)
    }

    init(world: SWorld, kind: BuildingKind, team: Int, x: Double, y: Double, built: Bool) {
        self.kind = kind
        stats = kind.stats
        half = Double(kind.stats.half)
        rect = SRect(cx: x, cy: y, half: Double(kind.stats.half))
        self.built = built
        progress = built ? 1 : 0
        super.init(world: world, team: team, maxHp: Double(kind.stats.hp), sight: Double(kind.stats.sight), x: x, y: y)
        if !built { hp = maxHp * 0.1 }
    }

    override func surfaceDistance(_ px: Double, _ py: Double) -> Double { rect.distance(px, py) }

    func update(_ dt: Double) {
        let g = world
        if !built {
            progress += dt / Double(stats.buildTime)
            hp = min(maxHp, hp + maxHp * 0.9 * dt / Double(stats.buildTime))
            if progress >= 1 {
                built = true
                progress = 1
                g.emit(["flash", x, y, half * 3, "team\(team)"])
                g.emit(["built", team, NetProtocol.name(kind), id])
            }
            return
        }
        if let k = queue.first {
            queueProgress += dt * trainSpeed / Double(k.stats.buildTime)
            if queueProgress >= 1 {
                queueProgress = 0
                queue.removeFirst()
                g.spawnUnit(k, self)
            }
        }
        if let k = upgrading {
            upgradeProgress += dt / k.stats.time
            if upgradeProgress >= 1 {
                upgrading = nil
                upgradeProgress = 0
                install(k)
            }
        }
        if shielded {
            if world.elapsed - shieldHit >= shieldDelay { shield = min(shieldMax, shield + shieldRegen * dt) }
        } else if shield > 0 {
            shield = max(0, shield - 60 * dt)      // the generator is gone: the field collapses
        }
        if armed { updateGun(dt) }
        else if kind == .radar { gunAngle = (gunAngle + dt * 0.8).truncatingRemainder(dividingBy: 2 * .pi) }
    }

    /// Turrets and artillery always; a Command Center once it has its point-defence gun.
    var armed: Bool { kind == .turret || kind == .artillery || (kind == .hq && upgrades.contains(.defense)) }
    var minRange: Double { kind == .artillery ? artilleryMinRange : 0 }

    /// Turrets and artillery: acquire, turn, fire. Artillery lobs shells and cannot hit inside its minimum
    /// range; its reach exceeds its sight, so what it can shoot is what its side can see.
    private func updateGun(_ dt: Double) {
        let g = world
        cooldown = max(0, cooldown - dt)
        scan -= dt
        if let t = turretTarget, t.dead || !(minRange...turretRange).contains(distanceTo(t)) || !t.targetable(by: team) { turretTarget = nil }
        if turretTarget == nil && scan <= 0 {
            scan = 0.3
            turretTarget = g.findTarget(self, turretRange, minRange: minRange)
        }
        guard let t = turretTarget else { return }
        let a = atan2(t.y - y, t.x - x)
        gunAngle = angLerp(gunAngle, a, dt * (kind == .artillery ? 4 : 10))
        guard cooldown <= 0 else { return }
        cooldown = kind == .hq ? hqGunCooldown : Double(stats.cooldown)
        let ux = cos(a), uy = sin(a)
        if kind == .artillery {
            if abs(angDiff(gunAngle, a)) > 0.35 {
                cooldown = 0.2          // still traversing: wait for the barrel
                return
            }
            let mx = x + ux * 44, my = y + uy * 44
            let jx = Double.random(in: -14...14, using: &simRNG), jy = Double.random(in: -14...14, using: &simRNG)
            g.launchShell(mx, my, t.x + jx, t.y + jy, Double(stats.damage), artillerySplash, team, self, arc: true)
            g.emit(["muzzle", mx, my, a, 34])
            g.emit(["smoke", mx, my, 14])
            g.emit(["sound", "cannon", x, y])
            return
        }
        t.takeDamage(turretDamage, from: self)
        let side = Bool.random(using: &simRNG) ? 4.5 : -4.5
        let mx = x + ux * 36 + uy * side, my = y + uy * 36 - ux * side
        g.emit(["tracer", mx, my, t.x, t.y, 1])
        g.emit(["muzzle", mx, my, a, 16])
        g.emit(["sparks", t.x, t.y, 4, 60, "hit"])
        g.emit(["sound", "turret", x, y])
    }
}

// MARK: - World

final class SPlayer {
    let slot: Int
    let name: String
    let team: Int
    let isAI: Bool
    let start: Int
    var ai: SAI?
    var alive = true

    init(slot: Int, name: String, team: Int, isAI: Bool, start: Int) {
        self.slot = slot; self.name = name; self.team = team; self.isAI = isAI; self.start = start
    }
}

final class SWorld {
    let map: [String: Any]
    let difficulty: Difficulty
    var players: [Int: SPlayer] = [:]
    private var idCounter = 1
    var units: [SUnit] = []
    var buildings: [SBuilding] = []
    var crystals: [SCrystal] = []
    var byId: [Int: AnyObject] = [:]
    var events: [[Any]] = []
    var elapsed = 0.0
    var gameOver = false
    var winnerTeam: Int?
    var resources: [Int: Double] = [:]
    var unitsTrained: [Int: Int] = [:], unitsLost: [Int: Int] = [:], crystalsMined: [Int: Int] = [:]
    private var alertTime: [Int: Double] = [:]
    /// A campaign mission or nil; `missionTimer` is the hold time run up so far.
    var mission: Mission?
    var missionTimer = 0.0
    /// How many of the mission's scripted events have gone off.
    var missionFired = 0
    /// The skirmish mode (Defs.modes); King of the Hill keeps a hold timer per alliance around the gold.
    var mode = "annihilation"
    var hold: [Int: Double] = [:]
    /// Army size per side every historyStep seconds, for the end screen's timeline.
    var history: [Int: [Int]] = [:]
    var nextSample = 0.0
    /// Supply crates on the field, and when the next one drops.
    private(set) var crates: [SCrate] = []
    var nextCrate = crateFirst
    /// Alert points: a player marks a spot and every ally is shown it; computer allies send troops.
    private(set) var pings: [(slot: Int, x: Double, y: Double, t: Double, kind: Int)] = []
    private var pingTime: [Int: Double] = [:]
    private var fogTimer = 0.0
    var allianceIndex: [Int: Int] = [:]
    var fog: [Int: SFogGrid] = [:]
    /// alliance -> attacker id -> revealed until (elapsed seconds)
    private var reveals: [Int: [Int: Double]] = [:]
    /// slot -> kit ids bought from the Armory
    var playerKits: [Int: Set<String>] = [:]
    var obstacles: [(Double, Double, Double)] = []
    private var obstacleGrid: [Int: [Int]] = [:]
    /// `walls` is derived: the map's own water and cliffs plus the span of every fallen bridge.
    private(set) var walls: [SRect]
    private var mapWalls: [SRect] = []
    /// High ground: walkable plateaus; sight and reach are better from up there.
    private(set) var ridges: [SRect] = []
    func onHigh(_ x: Double, _ y: Double) -> Bool { ridges.contains { x >= $0.x0 && x <= $0.x1 && y >= $0.y0 && y <= $0.y1 } }
    /// The map's own water and cliffs, for the automated tests in Debug.swift.
    var mapWallsForTests: [SRect] { mapWalls }
    var bridges: [SBridge] = []
    var towers: [SWatchtower] = []
    let nav: SNavGrid
    var navDirty = true
    var pathBudget = 0
    private var shells: [(x0: Double, y0: Double, x1: Double, y1: Double, dur: Double, t: Double, damage: Double, splash: Double, team: Int, attacker: SEntity?)] = []

    let seed: UInt64
    /// The command record: (tick, slot, command) for everything people sent through apply(), for the replay
    /// file. Computer players are deterministic and re-decide the same things on replay, so they are not kept.
    private(set) var tick = 0
    private(set) var record: [(Int, Int, [Any])] = []
    func setTick(_ t: Int) { tick = t }
    /// This world's random stream. The simulation draws from the global simRNG, so it is swapped in for
    /// the length of every step and command and kept here between them: two worlds built back to back
    /// (a replay check, a batch) each keep their own sequence.
    private var rng = SeededRNG(1)
    private func withRNG<T>(_ body: () -> T) -> T { simRNG = rng; defer { rng = simRNG }; return body() }

    init(map: [String: Any], players list: [SPlayer], difficulty: Difficulty, seed: UInt64? = nil) {
        self.seed = seed ?? UInt64.random(in: 1..<(1 << 31))
        simRNG = SeededRNG(self.seed)
        self.map = map
        self.difficulty = difficulty
        setWorldSize(map: map)  // the map carries its own size; grids below are sized from it
        nav = SNavGrid()
        mapWalls = jArr(map["walls"]).map { w in
            let v = jArr(w)
            return SRect(Double(jNum(v[0])), Double(jNum(v[1])), Double(jNum(v[2])), Double(jNum(v[3])))
        }
        walls = mapWalls
        ridges = jArr(map["ridges"]).map { r in let v = jArr(r); return SRect(Double(jNum(v[0])), Double(jNum(v[1])), Double(jNum(v[2])), Double(jNum(v[3]))) }
        for p in list {
            players[p.slot] = p
            resources[p.slot] = Double(startCrystal)
            playerKits[p.slot] = []
            unitsTrained[p.slot] = 0
            unitsLost[p.slot] = 0
            crystalsMined[p.slot] = 0
        }
        for (i, t) in Set(list.map { $0.team }).sorted().enumerated() {
            allianceIndex[t] = i
            fog[t] = SFogGrid()
        }
        for (i, t) in jArr(map["trees"]).enumerated() {
            let v = jArr(t)
            let o = (Double(jNum(v[0])), Double(jNum(v[1])), Double(jNum(v[2])))
            obstacles.append(o)
            obstacleGrid[Int(o.0 / 128) * 1000 + Int(o.1 / 128), default: []].append(i)
        }
        for b in jArr(map["bridges"]) {
            let v = jArr(b)
            let br = SBridge(world: self, rect: SRect(Double(jNum(v[0])), Double(jNum(v[1])),
                                                      Double(jNum(v[2])), Double(jNum(v[3]))))
            bridges.append(br)
            byId[br.id] = br
        }
        for c in jArr(map["crystals"]) {
            let v = jArr(c)
            let cr = SCrystal(id: nextId(), x: Double(jNum(v[0])), y: Double(jNum(v[1])), amount: jInt(v[2]), variant: jInt(v[3]))
            crystals.append(cr)
            byId[cr.id] = cr
        }
        for (tx, ty) in towerSites() {
            let t = SWatchtower(world: self, x: tx, y: ty)
            towers.append(t)
        }
        bridgesChanged()
        let starts = jArr(map["starts"]).map { jArr($0) }
        for p in list {
            let s = starts[p.start]
            let sx = Double(jNum(s[0])), sy = Double(jNum(s[1])), base = Double(jNum(s[2]))
            add(SBuilding(world: self, kind: .hq, team: p.slot, x: sx, y: sy, built: true))
            let line = Array(crystals[(p.start * 8)..<(p.start * 8 + 8)])
            for i in 0..<5 {
                let a = base + .pi / 4 + Double(i - 2) * 0.28
                let u = SUnit(world: self, kind: .worker, team: p.slot, x: sx + cos(a) * 130, y: sy + sin(a) * 130)
                u.order = .gather(line[(i * 2 + 1) % line.count])
                add(u)
            }
            if p.isAI { p.ai = SAI(world: self, team: p.slot) }
        }
        updateVisibility()
        rng = simRNG
    }

    func nextId() -> Int {
        defer { idCounter += 1 }
        return idCounter
    }

    /// Internal rather than private so the automated tests in Debug.swift can place units.
    func add(_ e: SEntity) {
        if let b = e as? SBuilding {
            buildings.append(b)
            navDirty = true
        } else if let u = e as? SUnit {
            units.append(u)
        }
        byId[e.id] = e
    }

    func isAI(_ slot: Int) -> Bool { players[slot]?.isAI ?? false }
    func allied(_ a: Int, _ b: Int) -> Bool { players[a]?.team == players[b]?.team }
    func enemies(_ a: Int, _ b: Int) -> Bool { !allied(a, b) }
    func allianceBit(_ slot: Int) -> Int { 1 << (allianceIndex[players[slot]?.team ?? 0] ?? 0) }
    func fogFor(_ slot: Int) -> SFogGrid { fog[players[slot]?.team ?? 0]! }

    func sees(_ slot: Int, _ e: SEntity) -> Bool {
        if allied(e.team, slot) { return true }
        let bit = allianceBit(slot)
        return (e.visMask & bit) != 0 || (e.isBuilding && (e.revealedMask & bit) != 0)
    }

    func emit(_ e: [Any]) { events.append(e) }

    // MARK: Simulation

    func step(_ dt: Double) {
        guard !gameOver else { return }
        withRNG { stepTick(dt) }
    }

    private func stepTick(_ dt: Double) {
        tick += 1
        elapsed += dt
        if navDirty { rebuildNav() }
        pathBudget = 6
        for u in units where !u.dead { u.update(dt) }
        resolveCollisions()
        updateShields()
        for b in buildings where !b.dead { b.update(dt) }
        updateShells(dt)
        updateCrates()
        for t in towers { t.update(dt) }
        checkMission(dt)
        runScript()
        checkMode(dt)
        if elapsed >= nextSample {
            nextSample += historyStep
            for s in players.keys.sorted() {
                history[s, default: []].append(units.filter { $0.team == s && $0.kind != .worker && !$0.dead }.count)
            }
        }
        for p in players.values.sorted(by: { $0.slot < $1.slot }) where p.alive { p.ai?.update(dt) }
        cleanupDead()
        fogTimer -= dt
        if fogTimer <= 0 {
            fogTimer = 0.1
            updateVisibility()
        }
        checkVictory()
    }

    /// A fallen bridge blocks its span exactly like the water it crossed; a rebuilt one opens it again.
    /// Everything that consults `walls` — navigation, collision and building placement — follows from this.
    // MARK: Saving

    var nextIdForSave: Int { idCounter }
    var shellSplashesForTests: [Double] { shells.map { $0.7 } }
    var shellsForSave: [(Double, Double, Double, Double, Double, Double, Double, Double, Int, Int)] {
        shells.map { ($0.x0, $0.y0, $0.x1, $0.y1, $0.dur, $0.t, $0.damage, $0.splash, $0.team, $0.attacker?.id ?? -1) }
    }
    func restoreShell(_ s: (Double, Double, Double, Double, Double, Double, Double, Double, Int, SEntity?)) {
        shells.append((s.0, s.1, s.2, s.3, s.4, s.5, s.6, s.7, s.8, s.9))
    }
    func setNextId(_ n: Int) { idCounter = n }
    var revealsForSave: [Int: [Int: Double]] { reveals }
    func restoreReveals(_ d: [String: Any]) {
        for (t, m) in d { guard let alliance = Int(t) else { continue }; var r: [Int: Double] = [:]
            for (i, u) in jDict(m) { if let id = Int(i) { r[id] = Double(jNum(u)) } }; reveals[alliance] = r }
    }
    /// Clears the opening base so a save can be rebuilt from nothing but the map. Bridges and towers stay:
    /// both editions create them first, in map order, so their ids are the ones in the save.
    func beginRestore() {
        units = []; buildings = []; crystals = []
        byId = [:]
        for b in bridges { byId[b.id] = b }
        for t in towers { byId[t.id] = t }
        for p in players.values { p.ai = nil }
    }

    // MARK: The Armory

    /// The summed effect `key` of every kit `slot` has bought for `kind`.
    func kitBonus(_ slot: Int, _ kind: UnitKind, _ key: String) -> Double {
        guard let owned = playerKits[slot], !owned.isEmpty else { return 0 }
        return kits.filter { $0.unit == kind && owned.contains($0.id) }.reduce(0) { $0 + $1.bonus(key) }
    }

    @discardableResult
    func buyKit(_ slot: Int, _ id: String) -> Bool {
        guard let kit = kits.first(where: { $0.id == id }), var owned = playerKits[slot], !owned.contains(id) else { return false }
        guard (resources[slot] ?? 0) >= Double(kit.cost) else {
            emit(["msg", slot, "Not enough crystal", "bad"])
            return false
        }
        resources[slot, default: 0] -= Double(kit.cost)
        owned.insert(id)
        playerKits[slot] = owned
        // Kit is worn at once: units already in the field get the extra health, not just a taller bar.
        let hp = kit.bonus("hp")
        if hp > 0 {
            for u in units where !u.dead && u.team == slot && u.kind == kit.unit {
                let added = Double(u.stats.hp) * hp
                u.maxHp += added
                u.hp += added
            }
        }
        emit(["kit", slot, id])
        return true
    }

    /// Whoever just hit `victim` shows itself to that player's alliance for a moment.
    func reveal(_ attacker: SEntity, victim: Int) {
        guard attacker.team >= 0, players[victim] != nil, !allied(attacker.team, victim),
              let alliance = players[victim]?.team else { return }
        reveals[alliance, default: [:]][attacker.id] = elapsed + revealTime
    }

    func bridgesChanged() {
        walls = mapWalls + bridges.filter { !$0.intact }.map { $0.rect } + towers.map { $0.rect }
        navDirty = true
    }

    /// Centre and the two flanks, each nudged to the nearest open ground. The Python edition runs the same
    /// search over the same map data, so both place the towers identically.
    private func towerSites() -> [(Double, Double)] {
        var sites: [(Double, Double)] = []
        for (cx, cy) in [(worldW / 2, worldH / 2), (worldW / 4, worldH / 2), (3 * worldW / 4, worldH / 2)] {
            if let spot = openGroundNear(cx, cy, placed: sites) { sites.append(spot) }
        }
        return sites
    }

    /// Spirals outwards in 40-unit steps for a square of `towerHalf` clear of water, cliffs, crystals, trees,
    /// buildings and other towers.
    private func openGroundNear(_ cx: Double, _ cy: Double, placed: [(Double, Double)]) -> (Double, Double)? {
        for ring in 0..<12 {
            let step = 40.0 * Double(ring)
            var candidates: [(Double, Double)] = []
            if ring == 0 {
                candidates = [(cx, cy)]
            } else {
                for dx in [-1.0, 0, 1] { for dy in [-1.0, 0, 1] where dx != 0 || dy != 0 { candidates.append((cx + dx * step, cy + dy * step)) } }
            }
            for (rawX, rawY) in candidates {
                let (x, y) = snapped(rawX, rawY)
                let r = SRect(cx: x, cy: y, half: towerHalf + 20)
                if r.x0 < 60 || r.y0 < 60 || r.x1 > worldW - 60 || r.y1 > worldH - 60 { continue }
                if mapWalls.contains(where: { $0.intersects(r) }) { continue }
                if crystals.contains(where: { r.distance($0.x, $0.y) < $0.radius + 30 }) { continue }
                if nearbyObstacles(x, y).contains(where: { r.distance($0.0, $0.1) < $0.2 + 10 }) { continue }
                if buildings.contains(where: { $0.rect.intersects(r) }) { continue }
                if placed.contains(where: { hyp($0.0 - x, $0.1 - y) < 300 }) { continue }
                return (x, y)
            }
        }
        return nil
    }

    func bridge(at x: Double, _ y: Double, slack: Double = 0) -> SBridge? {
        bridges.first { $0.rect.distance(x, y) <= slack }
    }

    func rebuildNavForTests() { rebuildNav() }

    private func rebuildNav() {
        nav.rebuild(rects: walls + buildings.filter { !$0.dead }.map { $0.rect },
                    circles: obstacles + crystals.filter { !$0.dead }.map { ($0.x, $0.y, $0.radius) })
        navDirty = false
    }

    func updateVisibility() {
        for (team, grid) in fog {
            var viewers: [(Double, Double, Double)] = []
            for u in units where players[u.team]?.team == team { viewers.append((u.x, u.y, u.sight)) }
            for b in buildings where players[b.team]?.team == team { viewers.append((b.x, b.y, b.sight * (onHigh(b.x, b.y) ? highSight : 1))) }
            for t in towers { if let o = t.owner, players[o]?.team == team { viewers.append((t.x, t.y, towerSight)) } }
            if var active = reveals[team] {
                for (id, until) in active where until <= elapsed { active[id] = nil }
                for id in active.keys {
                    if let e = byId[id] as? SEntity, !e.dead { viewers.append((e.x, e.y, revealRadius)) } else { active[id] = nil }
                }
                reveals[team] = active
            }
            grid.recompute(viewers)
        }
        func mark(_ e: SEntity) {
            var mask = 0
            let owner = players[e.team]?.team
            for (team, grid) in fog {
                let bit = 1 << allianceIndex[team]!
                let seen: Bool
                if let b = e as? SBuilding { seen = grid.anyVisible(b.rect) } else { seen = grid.isVisible(e.x, e.y) }
                if team == owner || seen { mask |= bit }
            }
            e.visMask = mask
            if e.isBuilding { e.revealedMask |= mask }
        }
        units.forEach(mark)
        buildings.forEach(mark)
    }

    func nearbyObstacles(_ x: Double, _ y: Double) -> [(Double, Double, Double)] {
        let bx = Int(x / 128), by = Int(y / 128)
        var out: [(Double, Double, Double)] = []
        for gx in (bx - 1)...(bx + 1) {
            for gy in (by - 1)...(by + 1) {
                for i in obstacleGrid[gx * 1000 + gy] ?? [] { out.append(obstacles[i]) }
            }
        }
        return out
    }

    private func resolveCollisions() {
        var grid: [Int: [SUnit]] = [:]
        for u in units {
            u.blocked = nil
            grid[Int(u.x / 48) * 1000 + Int(u.y / 48), default: []].append(u)
        }
        for key in grid.keys.sorted() {
            let cell = grid[key]!
            let gx = key / 1000, gy = key % 1000
            var neighbours: [SUnit] = []
            for (ox, oy) in [(0, 1), (1, -1), (1, 0), (1, 1)] { neighbours += grid[(gx + ox) * 1000 + (gy + oy)] ?? [] }
            for (i, a) in cell.enumerated() {
                for b in cell[(i + 1)...] + neighbours {
                    if a.stats.flies != b.stats.flies { continue }      // aircraft pass over everything on the ground
                    let dx = b.x - a.x, dy = b.y - a.y
                    let minD = a.radius + b.radius
                    if abs(dx) > minD || abs(dy) > minD { continue }
                    let d2 = dx * dx + dy * dy
                    if d2 >= minD * minD || (a.ghosting && b.ghosting) { continue }
                    let d = d2.squareRoot()
                    let (nx, ny) = d > 0.01 ? (dx / d, dy / d) : (1.0, 0.0)
                    let overlap = minD - d
                    var wa = 0.5
                    if a.wasMoving && !b.wasMoving { wa = 0.2 } else if b.wasMoving && !a.wasMoving { wa = 0.8 }
                    a.x -= nx * overlap * wa
                    a.y -= ny * overlap * wa
                    b.x += nx * overlap * (1 - wa)
                    b.y += ny * overlap * (1 - wa)
                }
            }
        }
        let rects = buildings.map { $0.rect } + walls
        for u in units {
            let r = u.radius
            if u.stats.flies {
                u.x = clampD(u.x, r + 4, worldW - r - 4)
                u.y = clampD(u.y, r + 4, worldH - r - 4)
                continue
            }
            for br in rects {
                if u.x < br.x0 - r || u.x > br.x1 + r || u.y < br.y0 - r || u.y > br.y1 + r { continue }
                let cx = clampD(u.x, br.x0, br.x1), cy = clampD(u.y, br.y0, br.y1)
                let dx = u.x - cx, dy = u.y - cy
                let d2 = dx * dx + dy * dy
                if d2 >= r * r { continue }
                if d2 > 1e-4 {
                    let d = d2.squareRoot()
                    u.x += dx / d * (r - d)
                    u.y += dy / d * (r - d)
                    u.blocked = (dx / d, dy / d)
                } else {
                    let m = min(u.x - br.x0, br.x1 - u.x, u.y - br.y0, br.y1 - u.y)
                    if m == u.x - br.x0 { u.x = br.x0 - r; u.blocked = (-1, 0) }
                    else if m == br.x1 - u.x { u.x = br.x1 + r; u.blocked = (1, 0) }
                    else if m == u.y - br.y0 { u.y = br.y0 - r; u.blocked = (0, -1) }
                    else { u.y = br.y1 + r; u.blocked = (0, 1) }
                }
            }
            var circles = crystals.filter { abs($0.x - u.x) < 60 && abs($0.y - u.y) < 60 }.map { ($0.x, $0.y, $0.radius) }
            circles += nearbyObstacles(u.x, u.y)
            for (cx, cy, cr) in circles {
                let minD = r + cr
                let dx = u.x - cx, dy = u.y - cy
                if abs(dx) > minD || abs(dy) > minD { continue }
                let d = hyp(dx, dy)
                if d >= minD { continue }
                let (nx, ny) = d > 0.01 ? (dx / d, dy / d) : (0.0, -1.0)
                u.x += nx * (minD - d)
                u.y += ny * (minD - d)
                if u.blocked == nil { u.blocked = (nx, ny) }
            }
            u.x = clampD(u.x, r + 4, worldW - r - 4)
            u.y = clampD(u.y, r + 4, worldH - r - 4)
        }
    }

    func cleanupDeadForTests() { cleanupDead() }

    private func cleanupDead() {
        let lost = units.contains { $0.dead } || buildings.contains { $0.dead }
        if units.contains(where: { $0.dead }) {
            for u in units where u.dead {
                emit(["explode", u.x, u.y, u.kind == .tank ? 30 : u.radius * 1.3, u.kind == .tank ? 1 : 0, 0])
                if u.kind == .tank {
                    emit(["wreck", u.x, u.y, u.angle * 180 / .pi, u.team])
                    emit(["sound", "explosion", u.x, u.y])
                }
                u.refundBuilds(includeCurrent: true)
                unitsLost[u.team, default: 0] += 1
                byId[u.id] = nil
            }
            units.removeAll { $0.dead }
        }
        if buildings.contains(where: { $0.dead }) {
            for b in buildings where b.dead {
                emit(["explode", b.x, b.y, b.half * 0.9, 1, 0])
                for i in 0..<5 {
                    emit(["explode", b.x + Double.random(in: -b.half...b.half, using: &simRNG), b.y + Double.random(in: -b.half...b.half, using: &simRNG),
                          b.half * 0.5, 0, Double(i) * 0.12 + 0.05])
                }
                emit(["rubble", b.x, b.y, b.half * 2.4])
                emit(["sound", "explosion", b.x, b.y])
                emit(["shake", b.x, b.y, min(10, b.half * 0.15)])
                emit(["bdead", b.team, NetProtocol.name(b.kind), b.x, b.y])
                byId[b.id] = nil
            }
            buildings.removeAll { $0.dead }
            navDirty = true
        }
        if crystals.contains(where: { $0.dead }) {
            for c in crystals where c.dead { byId[c.id] = nil }
            crystals.removeAll { $0.dead }
            navDirty = true
        }
        if lost {
            // Orders on what just died are dropped at once, so a unit re-targets this tick and a save taken now
            // says the same as the game does.
            func onDead(_ o: SOrder) -> Bool {
                switch o {
                case .attack(let t), .repair(let t): return t.dead
                case .heal(let u): return u.dead
                default: return false
                }
            }
            for u in units {
                if onDead(u.order) { u.order = .idle }
                u.queued.removeAll { onDead($0) }
            }
        }
    }

    /// Seconds toward a timed objective (survive: the clock; hold: time held in a row), else 0.
    func missionProgress() -> Double {
        guard let m = mission, m.win != "destroy" else { return 0 }
        return m.win == "survive" ? elapsed : missionTimer
    }

    /// A timed mission ends in victory for the player's side when its clock or its hold is done.
    private func checkMission(_ dt: Double) {
        guard let m = mission, !gameOver, m.win != "destroy", let me = players[0], me.alive else { return }
        if m.win == "hold", let (hx, hy, hr) = m.hold {
            let mine = units.contains { !$0.dead && allied($0.team, 0) && hyp($0.x - hx, $0.y - hy) <= hr }
                || buildings.contains { !$0.dead && allied($0.team, 0) && hyp($0.x - hx, $0.y - hy) <= hr }
            let enemy = units.contains { !$0.dead && enemies($0.team, 0) && hyp($0.x - hx, $0.y - hy) <= hr }
            missionTimer = (mine && !enemy) ? missionTimer + dt : 0
        }
        if missionProgress() >= m.seconds {
            gameOver = true
            winnerTeam = me.team
            emit(["gameover", me.team])
        }
    }

    // MARK: Skirmish modes

    /// King of the Hill's ring: the gold deposit's centre, or the middle of the map without one.
    var ring: (Double, Double) {
        let gold = crystals.filter { $0.variant == 3 }
        guard !gold.isEmpty else { return (worldW / 2, worldH / 2) }
        return (gold.reduce(0.0) { $0 + $1.x } / Double(gold.count), gold.reduce(0.0) { $0 + $1.y } / Double(gold.count))
    }

    private func checkMode(_ dt: Double) {
        guard mode == "koth", !gameOver else { return }
        let (hx, hy) = ring
        var inside = Set<Int>()
        for u in units where !u.dead && hyp(u.x - hx, u.y - hy) <= kothRadius { if let t = players[u.team]?.team { inside.insert(t) } }
        for b in buildings where !b.dead && hyp(b.x - hx, b.y - hy) <= kothRadius { if let t = players[b.team]?.team { inside.insert(t) } }
        let teams = Set(players.values.filter { $0.alive }.map { $0.team })
        for t in teams.sorted() {
            hold[t] = (inside.contains(t) && inside.count == 1) ? (hold[t] ?? 0) + dt : 0
            if hold[t]! >= kothHold {
                gameOver = true
                winnerTeam = t
                emit(["gameover", t])
                return
            }
        }
    }

    /// (this side's hold, the best enemy hold), in seconds.
    func holdStanding(_ slot: Int) -> (Double, Double) {
        let mine = players[slot]?.team ?? -1
        let best = hold.filter { $0.key != mine }.values.max() ?? 0
        return (hold[mine] ?? 0, best)
    }

    // MARK: Mission script

    /// Where a column for `slot` comes onto the map: the map edge nearest that side's start.
    func edgePoint(_ slot: Int) -> (Double, Double) {
        let starts = jArr(map["starts"]).map { jArr($0) }
        let idx = min(players[slot]?.start ?? 0, starts.count - 1)
        let sx = Double(jNum(starts[idx][0])), sy = Double(jNum(starts[idx][1]))
        let edges: [(Double, (Double, Double))] = [(sx, (80, sy)), (worldW - sx, (worldW - 80, sy)), (sy, (sx, 80)), (worldH - sy, (sx, worldH - 80))]
        return edges.min { $0.0 < $1.0 }!.1
    }

    /// Where a scripted column goes: a slot's Command Center (its start, if that has fallen), or with -1 the
    /// hold ring or the middle of the map.
    func scriptTarget(_ slot: Int) -> (Double, Double) {
        if slot < 0 {
            if let h = mission?.hold { return (h.0, h.1) }
            return (worldW / 2, worldH / 2)
        }
        if let hq = buildings.first(where: { $0.team == slot && $0.kind == .hq && !$0.dead }) { return (hq.x, hq.y) }
        let starts = jArr(map["starts"]).map { jArr($0) }
        let idx = min(players[slot]?.start ?? 0, starts.count - 1)
        return (Double(jNum(starts[idx][0])), Double(jNum(starts[idx][1])))
    }

    private func runScript() {
        guard let m = mission, !gameOver else { return }
        while missionFired < m.events.count && elapsed >= m.events[missionFired].at {
            fire(m.events[missionFired])
            missionFired += 1
        }
    }

    private func fire(_ ev: MissionEvent) {
        if ev.kind == "text" { emit(["msg", 0, ev.text, "good"]); return }
        guard let p = players[ev.owner], p.alive,
              let kind = NetProtocol.unitKinds.first(where: { NetProtocol.name($0) == ev.unit }) else { return }
        let (x0, y0) = edgePoint(ev.from)
        var (tx, ty) = scriptTarget(ev.target)
        let friendly = ev.target >= 0 && allied(ev.owner, ev.target)
        if friendly {                                  // allies stop short of the Command Center, not on it
            let d = max(1, hyp(tx - x0, ty - y0))
            tx -= (tx - x0) / d * 220
            ty -= (ty - y0) / d * 220
        }
        for i in 0..<ev.count {
            let a = Double(i) * 2.4, r = 30 + 14 * Double(i)      // a loose knot at the edge
            let u = SUnit(world: self, kind: kind, team: ev.owner, x: x0 + cos(a) * r, y: y0 + sin(a) * r)
            add(u)
            u.command(friendly ? .move(tx, ty) : .amove(tx, ty))
        }
        emit(["msg", 0, ev.text, allied(ev.owner, 0) ? "good" : "bad"])
    }

    private func checkVictory() {
        if mode == "sudden" {
            // A side without a standing Command Center is out, and everything it owns goes with it.
            var fell = false
            for p in players.values.sorted(by: { $0.slot < $1.slot }) where p.alive
                && !buildings.contains(where: { $0.team == p.slot && $0.kind == .hq && !$0.dead })
                && buildings.contains(where: { $0.team == p.slot }) {
                for b in buildings where b.team == p.slot { b.dead = true }
                for u in units where u.team == p.slot { u.dead = true }
                fell = true
            }
            if fell { cleanupDead() }
        }
        for p in players.values.sorted(by: { $0.slot < $1.slot }) where p.alive && !buildings.contains(where: { $0.team == p.slot }) {
            p.alive = false
            for u in units where u.team == p.slot { u.dead = true }
            emit(["elim", p.slot, p.name])
        }
        let teams = Set(players.values.filter { $0.alive }.map { $0.team })
        if teams.count <= 1 && !gameOver {
            gameOver = true
            winnerTeam = teams.min()
            emit(["gameover", winnerTeam ?? -1])
        }
    }

    // MARK: Commands (same list format as the Python server)

    func apply(_ slot: Int, _ cmd: [Any]) {
        if let p = players[slot], !p.isAI { record.append((tick, slot, cmd)) }
        applyQuietly(slot, cmd)
    }

    /// A command from a replay: applied, not recorded again.
    func applyQuietly(_ slot: Int, _ cmd: [Any]) {
        guard !gameOver, let p = players[slot], p.alive, cmd.first is String else { return }
        withRNG { applyCommand(slot, p, cmd) }
    }

    private func applyCommand(_ slot: Int, _ p: SPlayer, _ cmd: [Any]) {
        let op = cmd.first as! String
        func ids(_ v: Any?) -> [Int] { jArr(v).map { jInt($0) } }
        func flag(_ i: Int) -> Bool { i < cmd.count && ((cmd[i] as? Bool) ?? (jInt(cmd[i]) != 0)) }
        func num(_ i: Int) -> Double { i < cmd.count ? Double(jNum(cmd[i])) : 0 }
        switch op {
        case "move" where cmd.count >= 6:
            let us = ownUnits(slot, ids(cmd[1]))
            if !us.isEmpty { moveGroup(us, num(2), num(3), attack: flag(5), queue: flag(4)) }
        case "attack" where cmd.count >= 4:
            if let t = byId[jInt(cmd[2])] as? SEntity, !t.dead {
                let neutral = (t as? SBridge)?.intact ?? false      // anyone may bring a crossing down
                if neutral || enemies(t.team, slot) {
                    for u in ownUnits(slot, ids(cmd[1])) where !(neutral && u.kind == .worker) {
                        give(u, u.kind == .medic ? .amove(t.x, t.y) : .attack(t), flag(3))   // a Medic goes along to treat
                    }
                }
            }
        case "upgrade" where cmd.count >= 3:
            if let k = UpgradeKind.allCases.first(where: { $0.wireName == jStr(cmd[2]) }) {
                upgrade(slot, ownBuildings(slot, ids(cmd[1])), k)
            }
        case "cancelup" where cmd.count >= 2:
            ownBuildings(slot, [jInt(cmd[1])]).first?.cancelUpgrade()
        case "buy" where cmd.count >= 2:
            buyKit(slot, jStr(cmd[1]))
        case "siege" where cmd.count >= 3:
            for u in ownUnits(slot, ids(cmd[1])) { u.setSiege(flag(2)) }
        case "ping" where cmd.count >= 3:
            placePing(slot, Double(jNum(cmd[1])), Double(jNum(cmd[2])), kind: cmd.count > 3 ? jInt(cmd[3]) : 0)
        case "repair" where cmd.count >= 3:
            // Engineers mend a finished building or a Siege Tank; Medics treat anyone on foot.
            if let b = byId[jInt(cmd[2])] as? SEntity, !b.dead, allied(b.team, slot) {
                let queue = cmd.count > 3 && flag(3)
                let mendable = ((b as? SBuilding)?.built ?? false) || (b as? SUnit)?.kind == .tank
                let treatable = (b as? SUnit).map { $0.kind != .tank } ?? false
                for u in ownUnits(slot, ids(cmd[1])) {
                    if u.kind == .worker && mendable { u.orderRepair(b, queue: queue) }
                    else if u.kind == .medic && treatable && u !== b, let w = b as? SUnit { u.orderHeal(w, queue: queue) }
                }
            }
        case "rebuild" where cmd.count >= 3:
            rebuildBridge(slot, jInt(cmd[1]), jInt(cmd[2]), queue: cmd.count > 3 && flag(3))
        case "gather" where cmd.count >= 4:
            if let c = byId[jInt(cmd[2])] as? SCrystal, !c.dead {
                let us = ownUnits(slot, ids(cmd[1]))
                for w in us where w.kind == .worker {
                    w.homeCrystal = c
                    give(w, .gather(c), flag(3))
                }
                let others = us.filter { $0.kind != .worker }
                if !others.isEmpty { moveGroup(others, c.x, c.y, attack: false, queue: flag(3)) }
            }
        case "return" where cmd.count >= 3:
            for u in ownUnits(slot, ids(cmd[1])) where u.kind == .worker && u.carrying > 0 { give(u, .ret, flag(2)) }
        case "stop" where cmd.count >= 2:
            for u in ownUnits(slot, ids(cmd[1])) { u.command(.idle) }
        case "build" where cmd.count >= 6:
            build(slot, jInt(cmd[1]), jStr(cmd[2]), num(3), num(4), queue: flag(5))
        case "train" where cmd.count >= 3:
            if let k = NetProtocol.unitKinds.first(where: { NetProtocol.name($0) == jStr(cmd[2]) }) {
                _ = train(k, ownBuildings(slot, ids(cmd[1])), slot)
            }
        case "cancel" where cmd.count >= 3:
            if let b = ownBuildings(slot, [jInt(cmd[1])]).first { cancelQueue(b, jInt(cmd[2])) }
        case "unbuild" where cmd.count >= 2:
            if let b = ownBuildings(slot, [jInt(cmd[1])]).first { _ = unbuild(b) }
        case "rally" where cmd.count >= 4:
            for b in ownBuildings(slot, ids(cmd[1])) where !b.stats.produces.isEmpty { b.rally = (num(2), num(3)) }
        default:
            break
        }
    }

    private func ownUnits(_ slot: Int, _ ids: [Int]) -> [SUnit] {
        ids.compactMap { byId[$0] as? SUnit }.filter { $0.team == slot && !$0.dead }
    }

    private func ownBuildings(_ slot: Int, _ ids: [Int]) -> [SBuilding] {
        ids.compactMap { byId[$0] as? SBuilding }.filter { $0.team == slot && !$0.dead }
    }

    private func give(_ u: SUnit, _ o: SOrder, _ queue: Bool) {
        if queue { u.enqueue(o) } else { u.command(o) }
    }

    func moveGroup(_ us: [SUnit], _ x: Double, _ y: Double, attack: Bool, queue: Bool) {
        func order(_ tx: Double, _ ty: Double) -> SOrder { attack ? .amove(tx, ty) : .move(tx, ty) }
        if us.count == 1 {
            give(us[0], order(x, y), queue)
            return
        }
        let cols = Int(Double(us.count).squareRoot().rounded(.up))
        let rows = (us.count + cols - 1) / cols
        let spacing = (us.map { $0.radius }.max() ?? 10) * 2 + 8
        let byY = us.sorted { $0.y > $1.y }
        var ordered: [SUnit] = []
        var i = 0
        while i < byY.count {
            ordered += byY[i..<min(i + cols, byY.count)].sorted { $0.x < $1.x }
            i += cols
        }
        for (idx, u) in ordered.enumerated() {
            let r = idx / cols, c = idx % cols
            let tx = clampD(x + (Double(c) - Double(cols - 1) / 2) * spacing, 20, worldW - 20)
            let ty = clampD(y + (Double(rows - 1) / 2 - Double(r)) * spacing, 20, worldH - 20)
            give(u, order(tx, ty), queue)
        }
    }

    private func build(_ slot: Int, _ workerId: Int, _ kindName: String, _ x: Double, _ y: Double, queue: Bool) {
        guard let k = NetProtocol.buildingKind(kindName), let w = ownUnits(slot, [workerId]).first, w.kind == .worker else { return }
        let (sx, sy) = snapped(x, y)
        let s = k.stats
        if let req = s.requires, !hasBuilt(req, slot) {
            emit(["msg", slot, "Requires \(req.stats.name)", "bad"])
        } else if !fogFor(slot).isExplored(sx, sy) {
            emit(["msg", slot, "Can't build in unexplored territory", "bad"])
        } else if !canPlace(k, sx, sy) {
            emit(["msg", slot, "Can't build there", "bad"])
        } else if (resources[slot] ?? 0) < Double(s.cost) {
            emit(["msg", slot, "Not enough crystal", "bad"])
        } else {
            resources[slot, default: 0] -= Double(s.cost)
            w.orderBuild(k, sx, sy, queue: queue)
        }
    }

    // MARK: Construction & production

    /// Starts `k` on every selected building that can take it, one price each, stopping when the crystal runs out.
    private func upgrade(_ slot: Int, _ bs: [SBuilding], _ k: UpgradeKind) {
        for b in bs where b.canUpgrade(k) {
            let cost = Double(k.cost(for: b.kind))
            guard (resources[slot] ?? 0) >= cost else {
                emit(["msg", slot, "Not enough crystal", "bad"])
                return
            }
            resources[slot, default: 0] -= cost
            b.startUpgrade(k)
        }
    }

    private func rebuildBridge(_ slot: Int, _ workerId: Int, _ bridgeId: Int, queue: Bool) {
        guard let b = byId[bridgeId] as? SBridge, !b.intact,
              let w = ownUnits(slot, [workerId]).first, w.kind == .worker else { return }
        guard (resources[slot] ?? 0) >= Double(bridgeCost) else {
            emit(["msg", slot, "Not enough crystal", "bad"])
            return
        }
        resources[slot, default: 0] -= Double(bridgeCost)
        give(w, .rebuild(b), queue)
    }

    func hasBuilt(_ k: BuildingKind, _ team: Int) -> Bool { buildings.contains { $0.team == team && $0.kind == k && $0.built } }

    func snapped(_ x: Double, _ y: Double) -> (Double, Double) { ((x / 16).rounded() * 16, (y / 16).rounded() * 16) }

    func canPlace(_ k: BuildingKind, _ x: Double, _ y: Double, margin: Double = 4, ignoring: SUnit? = nil) -> Bool {
        let r = SRect(cx: x, cy: y, half: Double(k.stats.half))
        if r.x0 < 30 || r.y0 < 30 || r.x1 > worldW - 30 || r.y1 > worldH - 30 { return false }
        let rm = r.expanded(margin)
        if buildings.contains(where: { !$0.dead && $0.rect.intersects(rm) }) { return false }
        if walls.contains(where: { $0.intersects(rm) }) { return false }
        if crystals.contains(where: { !$0.dead && rm.distance($0.x, $0.y) < $0.radius + 20 }) { return false }
        if nearbyObstacles(x, y).contains(where: { rm.distance($0.0, $0.1) < $0.2 }) { return false }
        for u in units where u !== ignoring {
            for o in [u.order] + u.queued {
                if case .build(let bk, let bx, let by) = o, SRect(cx: bx, cy: by, half: Double(bk.stats.half)).intersects(rm) { return false }
            }
        }
        return true
    }

    func startBuilding(_ k: BuildingKind, _ x: Double, _ y: Double, _ team: Int) {
        add(SBuilding(world: self, kind: k, team: team, x: x, y: y, built: false))
        emit(["smoke", x, y, Double(k.stats.half) * 0.6])
    }

    func refund(_ amount: Int, _ team: Int) { resources[team, default: 0] += Double(amount) }

    func supplyUsed(_ team: Int) -> Int {
        units.filter { $0.team == team }.reduce(0) { $0 + $1.stats.supply }
            + buildings.filter { $0.team == team }.reduce(0) { $0 + $1.queue.reduce(0) { $0 + $1.stats.supply } }
    }

    func supplyCap(_ team: Int) -> Int {
        min(200, buildings.filter { $0.team == team && $0.built }.reduce(0) { $0 + $1.supply })
    }

    func train(_ k: UnitKind, _ bs: [SBuilding], _ team: Int) -> Bool {
        if let req = k.stats.requires, !hasBuilt(req, team) {
            emit(["msg", team, "Requires \(req.stats.name)", "bad"])
            return false
        }
        let cands = bs.filter { $0.built && !$0.dead && $0.stats.produces.contains(k) && $0.queue.count < 5 }
        guard let b = cands.min(by: { $0.queue.count < $1.queue.count }) else {
            emit(["msg", team, "Production queue full", "bad"])
            return false
        }
        guard (resources[team] ?? 0) >= Double(k.stats.cost) else {
            emit(["msg", team, "Not enough crystal", "bad"])
            return false
        }
        guard supplyUsed(team) + k.stats.supply <= supplyCap(team) else {
            emit(["msg", team, "Not enough supply — build a Supply Depot (E)", "bad"])
            return false
        }
        resources[team, default: 0] -= Double(k.stats.cost)
        b.queue.append(k)
        return true
    }

    /// Takes back a building that has barely started: the site goes and the full price comes back.
    @discardableResult
    func unbuild(_ b: SBuilding) -> Bool {
        guard !b.built, !b.dead, b.progress < undoProgress else { return false }
        refund(b.stats.cost, b.team)
        b.dead = true
        buildings.removeAll { $0 === b }
        byId[b.id] = nil
        navDirty = true
        emit(["msg", b.team, "\(b.stats.name) placement undone", "good"])
        return true
    }

    func cancelQueue(_ b: SBuilding, _ index: Int) {
        guard index >= 0, index < b.queue.count else { return }
        let k = b.queue.remove(at: index)
        if index == 0 { b.queueProgress = 0 }
        refund(k.stats.cost, b.team)
    }

    func spawnUnit(_ k: UnitKind, _ b: SBuilding) {
        let (tx, ty) = b.rally ?? (b.x, b.y - 1)
        let dx = tx - b.x, dy = ty - b.y, d = hyp(dx, dy)
        let (ux, uy) = d > 1e-3 ? (dx / d, dy / d) : (0.0, -1.0)
        let off = b.half + Double(k.stats.radius) + 4
        let u = SUnit(world: self, kind: k, team: b.team, x: b.x + ux * off, y: b.y + uy * off)
        u.angle = atan2(uy, ux)
        u.gunAngle = u.angle
        add(u)
        unitsTrained[b.team, default: 0] += 1
        emit(["trained", b.team, NetProtocol.name(k)])
        if let (rx, ry) = b.rally {
            if k == .worker, let c = crystalAt(rx, ry) { u.order = .gather(c) } else { u.order = .move(rx, ry) }
        } else if k == .worker, let c = nearestCrystal(b.x, b.y, 700) {
            u.order = .gather(c)
        }
    }

    func crystalAt(_ x: Double, _ y: Double) -> SCrystal? {
        crystals.first { !$0.dead && hyp($0.x - x, $0.y - y) < $0.radius + 10 }
    }

    func deposit(_ amount: Int, _ team: Int, _ x: Double, _ y: Double) {
        let mult = isAI(team) ? Double(difficulty.incomeMultiplier) : 1
        resources[team, default: 0] += Double(amount) * mult
        crystalsMined[team, default: 0] += amount
        emit(["income", team, x, y, amount])
    }

    func nearestCrystal(_ x: Double, _ y: Double, _ within: Double) -> SCrystal? {
        var best: SCrystal?
        var bestD = within
        for c in crystals where !c.dead {
            let d = hyp(c.x - x, c.y - y)
            if d < bestD {
                best = c
                bestD = d
            }
        }
        return best
    }

    func nearestDropoff(_ team: Int, _ x: Double, _ y: Double) -> SBuilding? {
        buildings.filter { $0.team == team && $0.kind == .hq && $0.built && !$0.dead }.min { hyp($0.x - x, $0.y - y) < hyp($1.x - x, $1.y - y) }
    }

    /// The best enemy within `radius` of `e` — and, for a sieged tank, no closer than `minRange`.
    /// The ally on foot most worth a Medic's attention within `radius`: near and badly hurt.
    func findWounded(_ e: SUnit, _ radius: Double) -> SUnit? {
        var best: SUnit?
        var bestScore = 1e9
        let lim = radius + 40
        for u in units where u !== e && !u.dead && u.kind != .tank && u.hp < u.maxHp && allied(u.team, e.team)
            && abs(u.x - e.x) <= lim && abs(u.y - e.y) <= lim {
            let d = e.distanceTo(u)
            if d > radius { continue }
            let score = d * (0.4 + 0.6 * u.hp / u.maxHp)
            if score < bestScore {
                best = u
                bestScore = score
            }
        }
        return best
    }

    func findTarget(_ e: SEntity, _ radius: Double, minRange: Double = 0) -> SEntity? {
        var best: SEntity?
        var bestScore = 1e9
        let lim = radius + 40
        for u in units where !u.dead && !allied(u.team, e.team) && abs(u.x - e.x) <= lim && abs(u.y - e.y) <= lim {
            let d = e.distanceTo(u)
            if d > radius || d < minRange || !u.targetable(by: e.team) { continue }
            if u.stats.flies && !e.hitsAir { continue }         // a tank cannot lift its gun that far
            let score = d + (u.kind == .worker ? 60 : 0)
            if score < bestScore {
                best = u
                bestScore = score
            }
        }
        for b in buildings where !b.dead && !allied(b.team, e.team) {
            let d = e.distanceTo(b)
            if d > radius || d < minRange || !b.targetable(by: e.team) { continue }
            let score = d + (b.kind == .turret ? 30 : 200)
            if score < bestScore {
                best = b
                bestScore = score
            }
        }
        return best
    }

    /// The nearest enemy building — unless a Shield Generator covers it, in which case the generator: drop the
    /// field first and the rest comes down.
    func primaryTarget(_ team: Int, _ x: Double, _ y: Double) -> SEntity? {
        let bs = buildings.filter { !$0.dead && enemies($0.team, team) }
        if let near = bs.min(by: { hyp($0.x - x, $0.y - y) < hyp($1.x - x, $1.y - y) }) {
            let gens = bs.filter { $0.kind == .shield && $0.team == near.team && $0.built && hyp($0.x - near.x, $0.y - near.y) <= shieldRadius }
            return gens.min(by: { hyp($0.x - x, $0.y - y) < hyp($1.x - x, $1.y - y) }) ?? near
        }
        return units.filter { !$0.dead && enemies($0.team, team) }.min { hyp($0.x - x, $0.y - y) < hyp($1.x - x, $1.y - y) }
    }

    /// An alert point — kind 0 "attack here", 1 "help here" — shown to the whole alliance and answered by its
    /// computer players. One every 3 seconds.
    func placePing(_ slot: Int, _ x: Double, _ y: Double, kind: Int = 0) {
        guard elapsed - (pingTime[slot] ?? -100) >= 3 else { return }
        let px = clampD(x, 0, worldW), py = clampD(y, 0, worldH)
        let k = kind == 0 ? 0 : 1
        pingTime[slot] = elapsed
        pings = pings.filter { elapsed - $0.t < 30 } + [(slot, px, py, elapsed, k)]
        emit(["ping", slot, px, py, k])
    }

    func alertAttack(_ team: Int, _ x: Double, _ y: Double) {
        if elapsed - (alertTime[team] ?? -100) > 1 {
            alertTime[team] = elapsed
            emit(["alert", team, x, y])
        }
    }

    func waveLaunched(_ team: Int) {
        for (s, p) in players where !p.isAI && enemies(s, team) { emit(["wave", s]) }
    }

    // MARK: Shells

    /// A shell in flight. Artillery shells (`arc`) fly slowly in a high arc that the clients draw.
    func launchShell(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ damage: Double, _ splash: Double, _ team: Int,
                     _ attacker: SEntity, arc: Bool = false) {
        let dur = max(0.05, hyp(x1 - x0, y1 - y0) / (arc ? artilleryShellSpeed : tankShellSpeed))
        shells.append((x0, y0, x1, y1, dur, 0, damage, splash, team, attacker))
        emit(["shell", x0, y0, x1, y1, dur, team, arc ? 1 : 0])
    }

    // MARK: Supply crates

    /// Drops a crate now and then, retires old ones, and hands a crate to the first unit to reach it.
    private func updateCrates() {
        if elapsed >= nextCrate {
            nextCrate = elapsed + crateInterval
            if crates.count < crateMax { _ = dropCrate() }
        }
        guard !crates.isEmpty else { return }
        for c in crates {
            if elapsed - c.born > crateLife { removeCrate(c); continue }
            if let taker = units.first(where: { u in !u.dead && abs(u.x - c.x) < 60 && abs(u.y - c.y) < 60
                                                && hyp(u.x - c.x, u.y - c.y) <= c.radius + u.radius }) {
                collectCrate(c, team: taker.team)
            }
        }
    }

    /// A crate somewhere open: clear of water and cliffs, away from every base and every mineral field.
    @discardableResult
    func dropCrate(kind: String? = nil) -> SCrate? {
        for _ in 0..<60 {
            let x = Double.random(in: 200...(worldW - 200), using: &simRNG), y = Double.random(in: 200...(worldH - 200), using: &simRNG)
            if nav.isBlocked(Int(x / 40), Int(y / 40)) { continue }
            if buildings.contains(where: { !$0.dead && hyp($0.x - x, $0.y - y) < 600 }) { continue }
            if crystals.contains(where: { !$0.dead && hyp($0.x - x, $0.y - y) < 120 }) { continue }
            if walls.contains(where: { $0.distance(x, y) < 40 }) { continue }
            let roll = Int.random(in: 0..<100, using: &simRNG)
            let k = kind ?? (roll < 50 ? "crystal" : roll < 85 ? "squad" : "tank")
            let amount = k == "crystal" ? crateCrystal.randomElement(using: &simRNG)! : 0
            let c = SCrate(id: nextId(), x: x, y: y, kind: k, amount: amount, born: elapsed)
            crates.append(c)
            byId[c.id] = c
            return c
        }
        return nil
    }

    private func removeCrate(_ c: SCrate) {
        c.dead = true
        crates.removeAll { $0 === c }
        byId[c.id] = nil
    }

    /// The gift: crystal into the bank, or troops spawned around the crate for that side.
    func collectCrate(_ c: SCrate, team: Int) {
        if c.kind == "crystal" {
            resources[team, default: 0] += Double(c.amount)
        } else {
            let kinds: [UnitKind] = c.kind == "squad" ? Array(repeating: .marine, count: crateSquad) : [.tank]
            for (i, k) in kinds.enumerated() {
                let a = Double(i) / Double(kinds.count) * 2 * .pi
                add(SUnit(world: self, kind: k, team: team, x: c.x + cos(a) * 26, y: c.y + sin(a) * 26))
            }
        }
        emit(["crate", team, c.x, c.y, c.kind, c.amount])
        removeCrate(c)
    }

    /// For tests and saves.
    func restoreCrate(id: Int, x: Double, y: Double, kind: String, amount: Int, born: Double) {
        let c = SCrate(id: id, x: x, y: y, kind: kind, amount: amount, born: born)
        crates.append(c)
        byId[c.id] = c
    }

    /// Every building within shieldRadius of a finished friendly Shield Generator carries a shield.
    private func updateShields() {
        let gens = buildings.filter { $0.kind == .shield && $0.built && !$0.dead }
        for b in buildings {
            b.shielded = b.built && !b.dead && gens.contains { $0.team == b.team && hyp($0.x - b.x, $0.y - b.y) <= shieldRadius }
        }
    }

    private func updateShells(_ dt: Double) {
        guard !shells.isEmpty else { return }
        for i in shells.indices { shells[i].t += dt }
        let landed = shells.filter { $0.t >= $0.dur }
        shells.removeAll { $0.t >= $0.dur }
        for s in landed {
            emit(["explode", s.x1, s.y1, s.splash * 0.55, 1, 0])
            emit(["sound", "explosion", s.x1, s.y1])
            for u in units where !u.dead && enemies(u.team, s.team) {
                let d = hyp(u.x - s.x1, u.y - s.y1) - u.radius
                if d <= s.splash { u.takeDamage(s.damage * (1 - 0.5 * max(0, d) / s.splash), from: s.attacker) }
            }
            // Bridges belong to nobody, so shells hit them whoever fired: a tank shelling a crossing is
            // the ordinary way to break one.
            for br in bridges where br.intact && br.rect.distance(s.x1, s.y1) <= s.splash * 0.5 {
                br.takeDamage(s.damage, from: s.attacker)
            }
            for b in buildings where !b.dead && enemies(b.team, s.team) && b.rect.distance(s.x1, s.y1) <= s.splash * 0.5 {
                b.takeDamage(s.damage, from: s.attacker)
            }
        }
    }
}

// MARK: - Computer player

/// The openings, as linux/fieldcommand/ai.py has them: how the first minutes are played. `barracks` and
/// `turret` multiply the plan times for those buildings (turret covers the shield too), `attack` the time of
/// the first wave; `wave` adds to its size, `workers` to the Engineer target; `expand` multiplies the time
/// before the first expansion.
let openings: [String: [String: Double]] = [
    "rush": ["barracks": 0.55, "turret": 1.4, "attack": 0.6, "wave": -2, "workers": -3, "expand": 1.4],
    "economy": ["barracks": 1.0, "turret": 1.0, "attack": 1.3, "wave": 2, "workers": 4, "expand": 0.6],
    "turtle": ["barracks": 1.0, "turret": 0.5, "attack": 1.5, "wave": 4, "workers": 0, "expand": 1.0],
]
let openingOrder = ["rush", "economy", "turtle"]
/// Odds of each opening by difficulty (easy, normal, hard); a giant map never rushes.
let openingWeights: [[Double]] = [[0, 1, 2], [1, 2, 1], [2, 2, 1]]
let giantW: Double = 6000
let garrison = [2, 3, 4]
let scoutAt: Double = 45
let scoutEvery: Double = 150
let expandAt: Double = 300
let fortifyAt: Double = 150          // a turtle walls its approach from here (times the pace); others once hit
let fortifyDist: Double = 380        // the wall line sits this far from the Command Center, toward the middle
let fortifyOffsets: [Double] = [-4, -3, -2, 2, 3, 4]   // blocks either side of a two-block gap, in wall widths
let fortifyBlocks = 6

/// One draw from the seeded stream, weighted by difficulty; the same rule as the Python edition's.
func chooseOpening(_ difficulty: Difficulty, giant: Bool) -> String {
    var weights = openingWeights[difficulty.rawValue]
    if giant { weights[0] = 0 }
    var r = Double.random(in: 0..<1, using: &simRNG) * weights.reduce(0, +)
    for (name, w) in zip(openingOrder, weights) {
        r -= w
        if r < 0 { return name }
    }
    return openingOrder[openingOrder.count - 1]
}

final class SAI {
    unowned let world: SWorld
    let team: Int
    private var think = 1.0
    private(set) var waveSize: Int
    private(set) var nextWave: Double
    private var attackers: [SUnit] = []
    /// The opening being played, the scout and the way it still has to go, the troops posted at expansions,
    /// and the crystal that lay near the Command Center when the game began.
    private(set) var opening: String
    private(set) var scout: SUnit?
    private var scoutRoute: [(Double, Double)] = []
    private(set) var nextScout: Double
    private(set) var guards: [SUnit] = []
    private var homeCrystalStart: Int?
    private var factor: [String: Double] { openings[opening]! }
    /// A decaying tally of enemy units this side has seen, by kind — what the army is built to answer.
    var seen: [UnitKind: Double] = [.marine: 0, .sniper: 0, .tank: 0, .gunship: 0]
    /// When a building of this side last took damage: the walls go up after.
    var hitAt = -1e9
    private var nextRaid = 240.0
    /// Time of the last allied alert point this side sent troops to.
    private var answeredPing = -1.0
    /// The route to the enemy: checked every few seconds; when it is cut, the crossing that reopens it.
    private(set) var routeOpen = true
    private var nextRouteCheck = 0.0
    private(set) var routeBridge: SBridge?
    func forceRouteCheck() { nextRouteCheck = 0 }
    var attackersCount: Int { attackers.count }

    init(world: SWorld, team: Int, opening: String? = nil) {
        self.world = world
        self.team = team
        self.opening = opening ?? chooseOpening(world.difficulty, giant: worldW >= giantW)
        let o = openings[self.opening]!
        waveSize = max(3, world.difficulty.initialWave + Int(o["wave"]!))
        nextWave = Double(world.difficulty.firstAttack) * o["attack"]!
        nextScout = scoutAt * Double(world.difficulty.pace)
    }

    // MARK: Saving

    func saveState() -> [String: Any] {
        var seenOut: [String: Double] = [:]
        for (k, v) in seen { seenOut[NetProtocol.name(k)] = v }
        return ["wave_size": waveSize, "next_wave": nextWave, "attackers": attackers.filter { !$0.dead }.map { $0.id },
                "seen": seenOut, "next_raid": nextRaid, "opening": opening, "hit_at": hitAt,
                "scout": scout.flatMap { $0.dead ? nil : $0.id as Any } ?? NSNull(),
                "scout_route": scoutRoute.map { [$0.0, $0.1] }, "next_scout": nextScout,
                "guards": guards.filter { !$0.dead }.map { $0.id }, "home_crystal_start": homeCrystalStart as Any? ?? NSNull()]
    }

    func restore(_ d: [String: Any], _ w: SWorld) {
        waveSize = jInt(d["wave_size"]); nextWave = Double(jNum(d["next_wave"])); nextRaid = Double(jNum(d["next_raid"]))
        attackers = jArr(d["attackers"]).compactMap { w.byId[jInt($0)] as? SUnit }
        for (k, v) in jDict(d["seen"]) { if let kind = NetProtocol.unitKinds.first(where: { NetProtocol.name($0) == k }) { seen[kind] = Double(jNum(v)) } }
        if let o = d["opening"] as? String, openings[o] != nil { opening = o }
        if let h = d["hit_at"] as? NSNumber { hitAt = h.doubleValue }
        scout = (d["scout"] as? NSNumber).flatMap { w.byId[$0.intValue] as? SUnit }
        scoutRoute = jArr(d["scout_route"]).map { let p = jArr($0); return (Double(jNum(p[0])), Double(jNum(p[1]))) }
        if let t = d["next_scout"] as? NSNumber { nextScout = t.doubleValue }
        guards = jArr(d["guards"]).compactMap { w.byId[jInt($0)] as? SUnit }
        homeCrystalStart = (d["home_crystal_start"] as? NSNumber)?.intValue
    }

    // MARK: Intelligence

    func observe() {
        let g = world
        for k in seen.keys { seen[k]! *= 0.85 }
        for u in g.units where !u.dead && seen[u.kind] != nil && g.enemies(u.team, team) && g.sees(team, u) {
            seen[u.kind]! += 1
        }
    }

    /// Target shares by unit kind, from a base mix bent by what has been seen: tanks answer massed Rangers,
    /// Snipers answer tanks, tanks and Rangers together answer Snipers.
    func composition() -> [UnitKind: Double] {
        var w: [UnitKind: Double] = [.marine: 3, .sniper: 1, .tank: 2, .gunship: 0.6]
        let total = [UnitKind.marine, .sniper, .tank, .gunship].reduce(0.0) { $0 + (seen[$1] ?? 0) }
        if total >= 3 {
            func share(_ k: UnitKind) -> Double { (seen[k] ?? 0) / total }
            w[.sniper]! += 3 * share(.tank) + 1 * share(.gunship)
            w[.tank]! += 2 * share(.marine) + 1 * share(.sniper)
            w[.marine]! += 1.5 * share(.sniper) + 2 * share(.gunship)
            w[.gunship]! += 2.5 * share(.tank)
        }
        let s = [UnitKind.marine, .sniper, .tank, .gunship].reduce(0.0) { $0 + w[$1]! }
        return w.mapValues { $0 / s }
    }

    /// The unit kind furthest below its target share.
    func wanted(_ army: [SUnit]) -> UnitKind {
        var counts: [UnitKind: Int] = [.marine: 0, .sniper: 0, .tank: 0, .gunship: 0]
        for u in army where counts[u.kind] != nil { counts[u.kind]! += 1 }
        let n = Double(max(1, counts.values.reduce(0, +)))
        let comp = composition()
        let order: [UnitKind] = [.marine, .sniper, .tank, .gunship]
        let deficit = order.map { ($0, comp[$0]! * (n + 1) - Double(counts[$0] ?? 0)) }
        return deficit.max { $0.1 < $1.1 }!.0
    }

    /// Where a unit should go for a target: Snipers stop 200 short so they fight at their range and never
    /// walk into the line; Medics 120 short, behind it; everyone else goes to the target.
    static let standoffs: [UnitKind: Double] = [.sniper: 200, .medic: 120]

    func standoff(_ u: SUnit, _ tx: Double, _ ty: Double) -> (Double, Double) {
        guard let short = SAI.standoffs[u.kind] else { return (tx, ty) }
        let dx = u.x - tx, dy = u.y - ty
        let d = max(1, hyp(dx, dy))
        let back = min(short, max(0, d - 60))
        return (tx + dx / d * back, ty + dy / d * back)
    }

    private var diff: Difficulty { world.difficulty }

    func update(_ dt: Double) {
        think -= dt
        guard think <= 0 else { return }
        think = 0.5
        let g = world
        let mine = g.units.filter { $0.team == team }
        let bases = g.buildings.filter { $0.team == team }
        guard !bases.isEmpty else { return }
        let hq = bases.first { $0.kind == .hq } ?? bases[0]
        let workers = mine.filter { $0.kind == .worker }
        let army = mine.filter { $0.kind != .worker }
        attackers.removeAll { $0.dead }
        guards.removeAll { $0.dead }
        if let s = scout, s.dead { scout = nil }
        let home = army.filter { u in !attackers.contains { $0 === u } && !guards.contains { $0 === u } && u !== scout }
        let dropoffs = bases.filter { $0.kind == .hq && $0.built }
        for w in workers where w.order.isIdle {
            let served = g.crystals.filter { c in !c.dead && dropoffs.contains { hyp($0.x - c.x, $0.y - c.y) < 700 } }
            if let c = served.min(by: { hyp($0.x - w.x, $0.y - w.y) < hyp($1.x - w.x, $1.y - w.y) }) ?? g.nearestCrystal(w.x, w.y, 6000) {
                w.command(.gather(c))
            }
        }
        observe()
        let reserve = construct(hq, bases, workers)
        produce(hq, bases, workers, reserve)
        rebuildBridges(hq, workers)
        repair(bases, workers)
        upgrade(hq, bases)
        shop(army)
        defend(bases, home)
        fortify(hq, bases, workers)
        garrisonRun(hq, bases, home)
        scoutRun(hq, home)
        grabCrates(hq, home)
        openRoute(hq, home, workers)
        attack(hq, home)
    }

    // MARK: Strategy

    /// The timed build plan, bent by the opening: (kind, how many by now).
    func plan(_ t: Double) -> [(BuildingKind, Int)] {
        let o = factor
        let base: [(BuildingKind, Double, Int)] = [(.barracks, 35, 1), (.turret, 140, 1), (.factory, 170, 1), (.barracks, 230, 2),
                                                   (.radar, 260, 1), (.turret, 300, 2), (.shield, 380, 1), (.factory, 420, 2),
                                                   (.artillery, 480, 1), (.barracks, 520, 3), (.turret, 560, 4), (.artillery, 720, 2)]
        return base.map { k, at, n in
            let f = k == .barracks ? o["barracks"]! : (k == .turret || k == .shield) ? o["turret"]! : 1.0
            return (k, t > at * f ? n : 0)
        }
    }

    /// Take a new field on the clock, when the home field is running low, or when the Engineers crowd it.
    func shouldExpand(_ t: Double, _ bases: [SBuilding], _ workers: [SUnit]) -> Bool {
        let left = homeCrystalLeft(bases)
        if homeCrystalStart == nil { homeCrystalStart = max(1, left) }
        let hqs = bases.filter { $0.kind == .hq }
        let live = world.crystals.filter { c in !c.dead && hqs.contains { hyp($0.x - c.x, $0.y - c.y) < 700 } }.count
        if t > expandAt * factor["expand"]! || left < 5000 { return true }
        if Double(left) < 0.45 * Double(homeCrystalStart!) { return true }
        return Double(workers.count) > 2.5 * Double(live) + 2
    }

    private func expansions(_ hq: SBuilding, _ bases: [SBuilding]) -> [SBuilding] {
        bases.filter { $0.kind == .hq && $0.built && !$0.dead && $0 !== hq }
    }

    /// The first expansion with no turret of its own.
    func unguardedExpansion(_ hq: SBuilding, _ bases: [SBuilding]) -> SBuilding? {
        expansions(hq, bases).first { e in !bases.contains { $0.kind == .turret && hyp($0.x - e.x, $0.y - e.y) < 450 } }
    }

    /// Barricades across the approach: a turtle walls up early, anyone once the base has been hit. Two lines
    /// of blocks either side of a gap, so its own army still marches out — through a funnel.
    @discardableResult
    func fortify(_ hq: SBuilding, _ bases: [SBuilding], _ workers: [SUnit]) -> Int {
        let g = world
        let t = g.elapsed / Double(diff.pace)
        if bases.contains(where: { $0.built && $0.hp < $0.maxHp }) { hitAt = g.elapsed }
        let early = opening == "turtle" && t > fortifyAt
        guard early || g.elapsed - hitAt < 60 else { return 0 }
        let walls = bases.filter { $0.kind == .wall }.count + pending(.wall, workers)
        let cost = Double(BuildingKind.wall.stats.cost)
        guard walls < fortifyBlocks, (g.resources[team] ?? 0) >= cost * 2 + 150 else { return 0 }
        let free = workers.filter { w in
            w.order.isIdle || { if case .gather = w.order { return true }; if case .ret = w.order { return true }; return false }() }
        let d = max(1, hyp(worldW / 2 - hq.x, worldH / 2 - hq.y))
        let ux = (worldW / 2 - hq.x) / d, uy = (worldH / 2 - hq.y) / d
        let cx = hq.x + ux * fortifyDist, cy = hq.y + uy * fortifyDist
        guard let builder = free.min(by: { hyp($0.x - cx, $0.y - cy) < hyp($1.x - cx, $1.y - cy) }) else { return 0 }
        let span = Double(BuildingKind.wall.stats.half) * 2
        var placed = 0
        for k in fortifyOffsets {
            let p = g.snapped(cx - uy * k * span, cy + ux * k * span)
            if !g.canPlace(.wall, p.0, p.1, margin: 4) { continue }
            if bases.contains(where: { $0.kind == .wall && abs($0.x - p.0) < span / 2 && abs($0.y - p.1) < span / 2 }) { continue }
            if (g.resources[team] ?? 0) < cost + 150 { break }
            g.resources[team, default: 0] -= cost
            builder.orderBuild(.wall, p.0, p.1, queue: placed > 0)
            placed += 1
        }
        return placed
    }

    /// Every expansion keeps a few troops of its own, so a raid on it meets more than Engineers.
    func garrisonRun(_ hq: SBuilding, _ bases: [SBuilding], _ home: [SUnit]) {
        let exps = expansions(hq, bases)
        if exps.isEmpty { guards = []; return }
        let need = garrison[diff.rawValue]
        for e in exps {
            let posted = guards.filter { u in hyp(u.x - e.x, u.y - e.y) < 500 || { if case .amove = u.order { return true }; return false }() }
            let missing = need - posted.count
            if missing <= 0 { continue }
            let idle = home.filter { $0.order.isIdle }
            if idle.count < missing + 2 { continue }                 // never strip the main base bare
            let party = idle.sorted { hyp($0.x - e.x, $0.y - e.y) < hyp($1.x - e.x, $1.y - e.y) }.prefix(missing)
            for (i, u) in party.enumerated() {
                let a = Double(posted.count + i) * 2.1
                u.command(.amove(e.x + cos(a) * 130, e.y + sin(a) * 130))
                guards.append(u)
            }
        }
        // A guard whose post has fallen goes back to the home army.
        guards = guards.filter { u in exps.contains { hyp(u.x - $0.x, u.y - $0.y) < 900 } || { if case .amove = u.order { return true }; return false }() }
    }

    /// The nearest enemy Command Center's ground, then the two fields nearest the way there.
    func scoutRoute(_ hq: SBuilding) -> [(Double, Double)] {
        let g = world
        let startList = jArr(g.map["starts"]).map { jArr($0) }
        var starts: [(Double, Double)] = []
        for p in g.players.values.sorted(by: { $0.slot < $1.slot }) where p.alive && g.enemies(p.slot, team) && p.start < startList.count {
            starts.append((Double(jNum(startList[p.start][0])), Double(jNum(startList[p.start][1]))))
        }
        guard let (ex, ey) = starts.min(by: { hyp($0.0 - hq.x, $0.1 - hq.y) < hyp($1.0 - hq.x, $1.1 - hq.y) }) else { return [] }
        let mx = (hq.x + ex) / 2, my = (hq.y + ey) / 2
        let fields = jArr(g.map["expansions"]).map { e -> (Double, Double) in let a = jArr(e); return (Double(jNum(a[0])), Double(jNum(a[1]))) }
        let near = fields.sorted { hyp($0.0 - mx, $0.1 - my) < hyp($1.0 - mx, $1.1 - my) }.prefix(2)
        return [(ex, ey)] + near
    }

    /// A single trooper walks the enemy's door and the fields between, so `seen` has something to see.
    func scoutRun(_ hq: SBuilding, _ home: [SUnit]) {
        let g = world
        if let s = scout, s.dead { scout = nil }
        if let s = scout {
            if s.order.isIdle {
                if !scoutRoute.isEmpty {
                    let (x, y) = scoutRoute.removeFirst()
                    s.command(.move(x, y))
                } else {
                    scout = nil
                    nextScout = g.elapsed + scoutEvery
                }
            }
            return
        }
        guard g.elapsed >= nextScout else { return }
        let idle = home.filter { $0.order.isIdle && $0.kind == .marine }
        let route = scoutRoute(hq)
        guard !idle.isEmpty, let first = route.first else { return }
        scout = idle.min { hyp($0.x - first.0, $0.y - first.1) < hyp($1.x - first.0, $1.y - first.1) }
        scoutRoute = Array(route.dropFirst()) + [(hq.x, hq.y)]
        scout!.command(.move(first.0, first.1))
    }

    private func pending(_ k: BuildingKind, _ workers: [SUnit]) -> Int {
        workers.reduce(0) { n, w in
            n + ([w.order] + w.queued).filter { if case .build(let bk, _, _) = $0 { return bk == k }; return false }.count
        }
    }

    func constructForTest(_ hq: SBuilding, _ bases: [SBuilding], _ workers: [SUnit]) -> Double { construct(hq, bases, workers) }

    private func construct(_ hq: SBuilding, _ bases: [SBuilding], _ workers: [SUnit]) -> Double {
        let g = world
        let t = g.elapsed / Double(diff.pace)
        func count(_ k: BuildingKind) -> Int { bases.filter { $0.kind == k }.count + pending(k, workers) }
        let used = g.supplyUsed(team)
        let pendingSupply = bases.filter { !$0.built }.reduce(0) { $0 + $1.stats.supply } + pending(.depot, workers) * 8
        let cap = g.supplyCap(team) + pendingSupply
        let producers = bases.filter { [.barracks, .factory, .hq].contains($0.kind) }.count
        let bank = g.resources[team] ?? 0
        var want: BuildingKind?
        var site: (Double, Double)?
        if cap < 200 && cap - used < 4 + producers * 3 && pending(.depot, workers) < (bank > 400 ? 2 : 1) {
            want = .depot
        } else if count(.hq) < (worldW >= giantW ? 4 : 3), shouldExpand(t, bases, workers), let e = expansionSite(hq.x, hq.y) {
            want = .hq
            site = e
        }
        if want == nil && t > 120, let e = unguardedExpansion(hq, bases), pending(.turret, workers) == 0,
           let spot = findSpot(.turret, e.x, e.y) {
            // An expansion without a turret of its own gets one before the plan goes on.
            want = .turret
            site = spot
        }
        if want == nil {
            for (k, n) in plan(t) where n > 0 && count(k) < n {
                if let r = k.stats.requires, !g.hasBuilt(r, team) { continue }
                want = k
                break
            }
            if want == nil && bank > 450 && g.hasBuilt(.barracks, team) {
                if count(.factory) < 3 && count(.factory) * 2 < count(.barracks) { want = .factory }
                else if count(.barracks) < 6 { want = .barracks }
            }
        }
        guard let k = want, !workers.isEmpty else { return 0 }
        let cost = Double(k.stats.cost)
        if bank < cost { return cost }
        let cands = workers.filter { if case .build = $0.order { return false }; return true }
        guard let builder = cands.min(by: { hyp($0.x - hq.x, $0.y - hq.y) < hyp($1.x - hq.x, $1.y - hq.y) }),
              let spot = site ?? findSpot(k, hq.x, hq.y) else { return 0 }
        g.resources[team, default: 0] -= cost
        builder.orderBuild(k, spot.0, spot.1, queue: false)
        return 0
    }

    /// A fallen crossing near home is worth putting back: it is the road its attacks travel on.
    /// One Engineer at a time, and only with crystal to spare, so this never starves the army.
    private func rebuildBridges(_ hq: SBuilding, _ workers: [SUnit]) {
        let g = world
        guard (g.resources[team] ?? 0) >= Double(bridgeCost) + 250 else { return }
        if workers.contains(where: { if case .rebuild = $0.order { return true }; return false }) { return }
        let down = g.bridges.filter { !$0.intact && hyp($0.x - hq.x, $0.y - hq.y) < 2200 }
        guard let b = down.min(by: { hyp($0.x - hq.x, $0.y - hq.y) < hyp($1.x - hq.x, $1.y - hq.y) }) else { return }
        let free = workers.filter { $0.order.isIdle || { if case .gather = $0.order { return true }; return false }($0) }
        guard let builder = free.min(by: { hyp($0.x - b.x, $0.y - b.y) < hyp($1.x - b.x, $1.y - b.y) }) else { return }
        g.resources[team, default: 0] -= Double(bridgeCost)
        builder.command(.rebuild(b))
    }

    /// Sitting on crystal after the opening, buy the cheapest kit for whatever it fields most of.
    private func shop(_ army: [SUnit]) {
        let g = world
        guard g.elapsed >= 240, (g.resources[team] ?? 0) >= 800, !army.isEmpty else { return }
        var counts: [UnitKind: Int] = [:]
        for u in army { counts[u.kind, default: 0] += 1 }
        guard let kind = NetProtocol.unitKinds.max(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) }), let owned = g.playerKits[team] else { return }
        if let cheapest = kits.filter({ $0.unit == kind && !owned.contains($0.id) }).min(by: { $0.cost < $1.cost }) {
            g.buyKit(team, cheapest.id)
        }
    }

    /// With crystal to spare: production first, then armour on the Command Center, then the guns.
    private func upgrade(_ hq: SBuilding, _ bases: [SBuilding]) {
        let g = world
        guard (g.resources[team] ?? 0) >= 500, !bases.contains(where: { $0.upgrading != nil }) else { return }
        var wants: [(SBuilding, UpgradeKind)] = bases.filter { $0.kind == .barracks || $0.kind == .factory }.map { ($0, .prod) }
        wants += [(hq, .armor), (hq, .hp)]
        wants += bases.filter { $0.kind == .turret }.map { ($0, .guns) }
        wants += bases.filter { $0.kind == .hq }.map { ($0, .defense) }
        wants += bases.filter { $0.kind == .depot }.map { ($0, .supply) }
        for (b, k) in wants where b.canUpgrade(k) && (g.resources[team] ?? 0) >= Double(k.cost(for: b.kind)) + 300 {
            g.apply(team, ["upgrade", [b.id], k.wireName])
            return
        }
    }

    /// Send one Engineer to the worst-hit building below 70%, if there is crystal to spare. One at a time,
    /// so the economy keeps running while the base is patched up.
    private func repair(_ bases: [SBuilding], _ workers: [SUnit]) {
        let g = world
        guard (g.resources[team] ?? 0) >= 150 else { return }
        if workers.contains(where: { if case .repair = $0.order { return true }; return false }) { return }
        // The worst-hit building below 70%, or a tank below 60% resting at home.
        var hurt: [SEntity] = bases.filter { $0.built && !$0.dead && $0.hp < $0.maxHp * 0.7 }
        hurt += g.units.filter { u in u.team == team && u.kind == .tank && !u.dead && u.hp < u.maxHp * 0.6
            && u.order.isIdle && bases.contains { hyp($0.x - u.x, $0.y - u.y) < 400 } }
        guard let b = hurt.min(by: { $0.hp / $0.maxHp < $1.hp / $1.maxHp }) else { return }
        let free = workers.filter { $0.order.isIdle || { if case .gather = $0.order { return true }; return false }($0) }
        free.min(by: { hyp($0.x - b.x, $0.y - b.y) < hyp($1.x - b.x, $1.y - b.y) })?.orderRepair(b, queue: false)
    }

    private func homeCrystalLeft(_ bases: [SBuilding]) -> Int {
        let hqs = bases.filter { $0.kind == .hq }
        return world.crystals.filter { c in !c.dead && hqs.contains { hyp($0.x - c.x, $0.y - c.y) < 700 } }.reduce(0) { $0 + $1.amount }
    }

    private func expansionSite(_ hx: Double, _ hy: Double) -> (Double, Double)? {
        let g = world
        let claimed = g.buildings.filter { $0.kind == .hq }
        var pendingHQ: [(Double, Double)] = []
        for u in g.units {
            for o in [u.order] + u.queued { if case .build(.hq, let x, let y) = o { pendingHQ.append((x, y)) } }
        }
        let free = g.crystals.filter { c in
            !c.dead && !claimed.contains { hyp($0.x - c.x, $0.y - c.y) < 800 } && !pendingHQ.contains { hyp($0.0 - c.x, $0.1 - c.y) < 800 }
        }
        guard let target = free.min(by: { hyp($0.x - hx, $0.y - hy) < hyp($1.x - hx, $1.y - hy) }) else { return nil }
        let field = free.filter { hyp($0.x - target.x, $0.y - target.y) < 250 }
        let cx = field.reduce(0) { $0 + $1.x } / Double(field.count), cy = field.reduce(0) { $0 + $1.y } / Double(field.count)
        let toHome = atan2(hy - cy, hx - cx)
        for i in 0..<16 {
            let a = toHome + Double((i + 1) / 2) * (i % 2 == 0 ? 0.35 : -0.35)
            for d in [250.0, 290, 330] {
                let p = g.snapped(cx + cos(a) * d, cy + sin(a) * d)
                if g.canPlace(.hq, p.0, p.1, margin: 10) { return p }
            }
        }
        return nil
    }

    private func findSpot(_ k: BuildingKind, _ cx: Double, _ cy: Double) -> (Double, Double)? {
        let g = world
        let toCenter = atan2(worldH / 2 - cy, worldW / 2 - cx)
        let half = Double(k.stats.half)
        for attempt in 0..<90 {
            let guns = k == .turret || k == .artillery
            let spread = guns ? 0.7 : (attempt < 30 ? Double.pi * 0.65 : .pi)
            let a = toCenter + Double.random(in: -spread...spread, using: &simRNG)
            let d = Double.random(in: 190...(260 + Double(attempt) * 8), using: &simRNG) + (guns ? 90 : 0)
            let p = g.snapped(cx + cos(a) * d, cy + sin(a) * d)
            let r = SRect(cx: p.0, cy: p.1, half: half)
            if g.crystals.allSatisfy({ r.distance($0.x, $0.y) > 90 }) && g.canPlace(k, p.0, p.1, margin: attempt < 45 ? 26 : 14) { return p }
        }
        return nil
    }

    func produceForTest(_ hq: SBuilding, _ bases: [SBuilding], _ workers: [SUnit], _ reserve: Double) { produce(hq, bases, workers, reserve) }

    private func produce(_ hq: SBuilding, _ bases: [SBuilding], _ workers: [SUnit], _ reserve: Double) {
        let g = world
        func money() -> Double { (g.resources[team] ?? 0) - reserve }
        let queuedWorkers = hq.queue.filter { $0 == .worker }.count
        let target = diff.workerTarget + Int(factor["workers"]!)
        if hq.kind == .hq && hq.built && workers.count + queuedWorkers < target && hq.queue.count < 2 {
            if workers.count < 8 || money() >= 50 { _ = g.train(.worker, [hq], team) }
        }
        let tx = worldW / 2 - hq.x, ty = worldH / 2 - hq.y
        let tl = max(1, hyp(tx, ty))
        for b in bases where b.built && b.queue.isEmpty {
            if b.rally == nil && (b.kind == .barracks || b.kind == .factory) { b.rally = (hq.x + tx / tl * 260, hq.y + ty / tl * 260) }
            let army = g.units.filter { $0.team == team && $0.kind != .worker && !$0.dead }
            let want = wanted(army)
            if b.kind == .barracks {
                let foot = army.filter { $0.kind == .marine || $0.kind == .sniper }.count
                let medics = army.filter { $0.kind == .medic }.count
                if foot >= 4 && medics * 4 < foot && money() >= 75 {
                    _ = g.train(.medic, [b], team)      // one Medic for every four on foot
                } else if want == .sniper && money() >= 125 && g.hasBuilt(.factory, team) {
                    _ = g.train(.sniper, [b], team)
                } else if money() >= 50 && (want != .tank || !g.hasBuilt(.factory, team) || money() >= 200) {
                    _ = g.train(.marine, [b], team)
                }
            } else if b.kind == .factory {
                if want == .gunship && money() >= 200 && g.hasBuilt(.radar, team) {
                    _ = g.train(.gunship, [b], team)
                } else if money() >= 150 && (want != .gunship || !g.hasBuilt(.radar, team) || money() >= 350) {
                    _ = g.train(.tank, [b], team)
                }
            }
        }
    }

    private func defend(_ bases: [SBuilding], _ home: [SUnit]) {
        let g = world
        guard let threat = g.units.first(where: { u in g.enemies(u.team, team) && bases.contains { hyp($0.x - u.x, $0.y - u.y) < 650 } })
        else { return }
        for u in home {
            switch u.order {
            case .idle, .move:
                let (x, y) = standoff(u, threat.x, threat.y)
                u.command(.amove(x, y))
            default: break
            }
        }
        // A garrison answers what comes at its own post.
        for u in guards where u.order.isIdle && hyp(u.x - threat.x, u.y - threat.y) < 700 {
            let (x, y) = standoff(u, threat.x, threat.y)
            u.command(.amove(x, y))
        }
    }

    /// A supply crate in sight and not too far from home is worth a trooper's walk.
    private func grabCrates(_ hq: SBuilding, _ home: [SUnit]) {
        let g = world
        for c in g.crates where hyp(c.x - hq.x, c.y - hq.y) <= 1400 && g.fog[g.players[team]!.team]?.isVisible(c.x, c.y) == true {
            let taken = home.contains { u in if case .move(let x, let y) = u.order { return abs(x - c.x) < 1 && abs(y - c.y) < 1 }; return false }
            if taken { continue }
            if let u = home.filter({ $0.order.isIdle }).min(by: { hyp($0.x - c.x, $0.y - c.y) < hyp($1.x - c.x, $1.y - c.y) }) {
                u.command(.move(c.x, c.y))
            }
        }
    }

    /// When the way to the enemy is cut — the crossings are down — an attack must not bounce off the water:
    /// an Engineer goes to put back the bridge on the route, an escort holds the near bank, and the wave
    /// waits for the span. Rebuilding pays the bridge's price even with nothing else in the bank.
    private func openRoute(_ hq: SBuilding, _ home: [SUnit], _ workers: [SUnit]) {
        let g = world
        guard g.elapsed >= nextRouteCheck else { return }
        nextRouteCheck = g.elapsed + 6
        guard let target = g.primaryTarget(team, hq.x, hq.y) else { routeOpen = true; routeBridge = nil; return }
        routeOpen = g.nav.reaches(hq.x, hq.y, target.x, target.y)
        if routeOpen { routeBridge = nil; return }
        let down = g.bridges.filter { !$0.intact }
        guard let b = down.min(by: { hyp($0.x - hq.x, $0.y - hq.y) + hyp(target.x - $0.x, target.y - $0.y)
                                   < hyp($1.x - hq.x, $1.y - hq.y) + hyp(target.x - $1.x, target.y - $1.y) })
        else { routeOpen = true; return }      // nothing to rebuild: the way is walled off, and walls are shot down on arrival
        routeBridge = b
        let busy = workers.contains { if case .rebuild = $0.order { return true }; return false }
        if !busy && (g.resources[team] ?? 0) >= Double(bridgeCost) {
            let free = workers.filter { w in
                w.order.isIdle || { if case .gather = w.order { return true }; if case .ret = w.order { return true }; return false }() }
            if let builder = free.min(by: { hyp($0.x - b.x, $0.y - b.y) < hyp($1.x - b.x, $1.y - b.y) }) {
                g.resources[team, default: 0] -= Double(bridgeCost)
                builder.command(.rebuild(b))
            }
        }
        // The escort holds the near bank: a little short of the ruins, on this side of the water.
        let d = max(1, hyp(b.x - hq.x, b.y - hq.y))
        let px = b.x - (b.x - hq.x) / d * 150, py = b.y - (b.y - hq.y) / d * 150
        for u in home.filter({ $0.order.isIdle }).prefix(6) { let (x, y) = standoff(u, px, py); u.command(.amove(x, y)) }
    }

    private func attack(_ hq: SBuilding, _ home: [SUnit]) {
        let g = world
        let overdue = g.elapsed > nextWave + 120 && home.count >= 4
        if !routeOpen { nextWave = max(nextWave, g.elapsed + 10) }      // the wave waits for the crossing
        if g.elapsed >= nextWave && (home.count >= waveSize || overdue), let goal = objective(g.primaryTarget(team, hq.x, hq.y)) {
            for u in home { let (x, y) = standoff(u, goal.0, goal.1); u.command(.amove(x, y)) }
            attackers += home
            waveSize = min(40, waveSize + 2 + diff.rawValue * 2)
            nextWave = g.elapsed + 50
            g.waveLaunched(team)
        }
        for u in attackers where u.order.isIdle {
            if let goal = objective(g.primaryTarget(team, u.x, u.y)) { let (x, y) = standoff(u, goal.0, goal.1); u.command(.amove(x, y)) }
        }
        raid(hq, home)
        siege(home)
        towersRun(hq, home)
        answerPings(home)
    }

    /// Where a wave goes: in King of the Hill the gold ring, unless this side already holds the lead there;
    /// otherwise the enemy's nearest building.
    func objective(_ target: SEntity?) -> (Double, Double)? {
        let g = world
        if g.mode == "koth" {
            let (mine, best) = g.holdStanding(team)
            if mine <= best || mine <= 0 { return g.ring }
        }
        return target.map { ($0.x, $0.y) }
    }

    /// An ally's alert point: whatever is standing idle at home goes there (at least a pair, up to a wave),
    /// and stays out as attackers — so a human ally can call the computer's army onto a fight.
    private func answerPings(_ home: [SUnit]) {
        let g = world
        let calls = g.pings.filter { $0.slot != team && g.allied($0.slot, team) && $0.t > answeredPing && g.elapsed - $0.t < 30 }
        guard let call = calls.last else { return }
        answeredPing = call.t
        // Standing idle, or on a home errand (a watchtower, a defence): the call takes priority.
        let idle = home.filter { u in u.order.isIdle || { if case .amove = u.order { return true }; return false }() }
        guard idle.count >= 2 else { return }
        let party = Array(idle.prefix(max(4, waveSize)))
        for u in party { let (x, y) = standoff(u, call.x, call.y); u.command(.amove(x, y)) }
        attackers += party
    }

    /// Between waves, two or three troops go for the enemy building nearest this base — usually an expansion
    /// or a forward depot — so the enemy has to watch its edges as well as its front.
    func raid(_ hq: SBuilding, _ home: [SUnit]) {
        let g = world
        guard g.elapsed >= nextRaid, home.count >= waveSize / 2 + 3, diff != .easy else { return }
        let idle = home.filter { $0.order.isIdle && ($0.kind == .marine || $0.kind == .sniper) }
        guard idle.count >= 2 else { return }
        let targets = g.buildings.filter { !$0.dead && g.enemies($0.team, team) && $0.targetable(by: team) }
        guard let t = targets.min(by: { hyp($0.x - hq.x, $0.y - hq.y) < hyp($1.x - hq.x, $1.y - hq.y) }) else { return }
        let party = Array(idle.prefix(3))
        for u in party { let (x, y) = standoff(u, t.x, t.y); u.command(.amove(x, y)) }
        attackers += party
        nextRaid = g.elapsed + 90
    }

    /// Between waves, a few idle troops go and sit on the nearest watchtower nobody on this side holds.
    private func towersRun(_ hq: SBuilding, _ home: [SUnit]) {
        let g = world
        guard !g.towers.isEmpty, home.count >= 4, g.elapsed >= 120, let mine = g.players[team]?.team else { return }
        let unheld = g.towers.filter { $0.owner.flatMap { g.players[$0]?.team } != mine }
        guard let t = unheld.min(by: { hyp($0.x - hq.x, $0.y - hq.y) < hyp($1.x - hq.x, $1.y - hq.y) }) else { return }
        for u in home.filter({ $0.order.isIdle && $0.kind != .worker }).prefix(3) {
            u.command(.amove(t.x + Double.random(in: -40...40, using: &simRNG), t.y + Double.random(in: -40...40, using: &simRNG)))
        }
    }

    /// Tanks dig in when an enemy building is within sieged range and pack up when nothing is.
    private func siege(_ home: [SUnit]) {
        let g = world
        for u in home + attackers where u.canSiege && u.mode != .sieging && u.mode != .unsieging {
            let near = g.findTarget(u, siegeRange - 20, minRange: siegeMinRange)
            if !u.sieged, let n = near, n.isBuilding { u.setSiege(true) }
            else if u.sieged && near == nil { u.setSiege(false) }
        }
    }
}
