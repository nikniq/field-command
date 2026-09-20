import SpriteKit
import AppKit

/// Size of the map in play. Maps carry their own size (the mega maps are larger), so this is set from the map
/// data when a game starts — see `setWorldSize`.
private(set) var worldSize = defaultWorldSize
let defaultWorldSize = CGSize(width: 4000, height: 2800)
let maxPlayers = 12

func setWorldSize(_ w: CGFloat, _ h: CGFloat) {
    worldSize = CGSize(width: w, height: h)
}

/// Reads the map's own size out of a map spec sent by the server (or generated locally).
func setWorldSize(map: [String: Any]) {
    let w = jNum(map["w"]), h = jNum(map["h"])
    setWorldSize(w > 0 ? w : defaultWorldSize.width, h > 0 ? h : defaultWorldSize.height)
}

// MARK: - Geometry helpers

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    static func += (a: inout CGPoint, b: CGPoint) { a = a + b }
    static func -= (a: inout CGPoint, b: CGPoint) { a = a - b }
    var length: CGFloat { hypot(x, y) }
    func distance(to p: CGPoint) -> CGFloat { hypot(p.x - x, p.y - y) }
    var normalized: CGPoint {
        let l = length
        return l > 0.0001 ? CGPoint(x: x / l, y: y / l) : .zero
    }
    var angle: CGFloat { atan2(y, x) }
    func dot(_ o: CGPoint) -> CGFloat { x * o.x + y * o.y }
}

func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }

func rectDistance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
    let dx = max(r.minX - p.x, 0, p.x - r.maxX)
    let dy = max(r.minY - p.y, 0, p.y - r.maxY)
    return hypot(dx, dy)
}

func angleLerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    var d = b - a
    while d > .pi { d -= 2 * .pi }
    while d < -.pi { d += 2 * .pi }
    return a + d * min(1, t)
}

func formatTime(_ t: CGFloat) -> String {
    let s = Int(t)
    return String(format: "%02d:%02d", s / 60, s % 60)
}

func squareRect(center p: CGPoint, half h: CGFloat) -> CGRect {
    CGRect(x: p.x - h, y: p.y - h, width: h * 2, height: h * 2)
}

// MARK: - Look & feel

extension NSColor {
    func mix(_ other: NSColor, _ t: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self }
        let u = 1 - t
        return NSColor(srgbRed: a.redComponent * u + b.redComponent * t,
                       green: a.greenComponent * u + b.greenComponent * t,
                       blue: a.blueComponent * u + b.blueComponent * t,
                       alpha: a.alphaComponent * u + b.alphaComponent * t)
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

enum Palette {
    static let crystal = NSColor.rgb(0.40, 0.92, 1.0)
    static let text = NSColor.rgb(0.90, 0.93, 0.95)
    static let dim = NSColor.rgb(0.55, 0.62, 0.68)
    static let amber = NSColor.rgb(1.0, 0.76, 0.30)
    static let good = NSColor.rgb(0.45, 0.95, 0.50)
    static let bad = NSColor.rgb(1.0, 0.40, 0.35)
    static let panel = NSColor.rgb(0.06, 0.08, 0.09, 0.96)
    static let button = NSColor.rgb(0.12, 0.16, 0.19)
    static let buttonEdge = NSColor.rgb(0.35, 0.55, 0.75)
}

enum Fonts {
    static let bold = "AvenirNext-Bold"
    static let demi = "AvenirNext-DemiBold"
    static let medium = "AvenirNext-Medium"
    static let heavy = "AvenirNextCondensed-Heavy"
    static let condensed = "AvenirNextCondensed-DemiBold"
    static let mono = "Menlo-Bold"
}

func makeLabel(_ text: String, size: CGFloat, color: NSColor = Palette.text, font: String = Fonts.demi,
               align: SKLabelHorizontalAlignmentMode = .left,
               valign: SKLabelVerticalAlignmentMode = .baseline) -> SKLabelNode {
    let l = SKLabelNode(fontNamed: font)
    l.text = text
    l.fontSize = size
    l.fontColor = color
    l.horizontalAlignmentMode = align
    l.verticalAlignmentMode = valign
    return l
}

func playSound(_ name: String) {
    guard Settings.sound, !Debug.headless else { return }
    (NSSound(named: NSSound.Name(name))?.copy() as? NSSound)?.play()
}

// MARK: - Teams

/// A player slot (0-3). Single player uses `.player` (0) vs `.enemy` (1); multiplayer uses up to four slots
/// grouped into alliances. `Team.local` is the slot this client controls.
struct Team: Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let player = Team(rawValue: 0)
    static let enemy = Team(rawValue: 1)

    static var local = Team.player
    /// slot -> alliance id; single player: each side on its own team.
    static var alliances: [Int: Int] = [0: 1, 1: 2]

    static func resetForSinglePlayer() {
        local = .player
        alliances = [0: 1, 1: 2]
    }

    var alliance: Int { Team.alliances[rawValue] ?? rawValue + 1 }
    var isLocal: Bool { self == Team.local }
    var isFriendly: Bool { alliance == Team.local.alliance }
    func isHostile(to other: Team) -> Bool { alliance != other.alliance }
    /// Single-player opponent.
    var opponent: Team { self == .player ? .enemy : .player }

    // Player colours by slot; up to twelve play at once on the mega maps. Same palette as the Linux edition.
    private static let colors: [NSColor] = [
        .rgb(0.28, 0.62, 1.00), .rgb(0.95, 0.32, 0.26), .rgb(0.30, 0.82, 0.38), .rgb(0.72, 0.46, 1.00),
        .rgb(1.00, 0.76, 0.25), .rgb(0.20, 0.85, 0.82), .rgb(1.00, 0.52, 0.80), .rgb(0.98, 0.56, 0.18),
        .rgb(0.60, 0.93, 0.25), .rgb(0.45, 0.50, 0.95), .rgb(0.85, 0.83, 0.78), .rgb(0.66, 0.44, 0.24),
    ]
    private static let lights: [NSColor] = colors.map { $0.mix(.white, 0.45) }
    private static let darks: [NSColor] = colors.map { $0.mix(.black, 0.68) }
    static let colorNames = ["Blue", "Red", "Green", "Violet", "Gold", "Teal", "Rose", "Orange", "Lime", "Indigo", "Bone", "Umber"]

    static func colorName(_ i: Int) -> String { colorNames[i % colorNames.count] }
    var color: NSColor { Team.colors[rawValue % Team.colors.count] }
    var lightColor: NSColor { Team.lights[rawValue % Team.lights.count] }
    var darkColor: NSColor { Team.darks[rawValue % Team.darks.count] }
}

// MARK: - Units

struct UnitStats {
    let name: String
    let glyph: String
    let cost: Int
    let supply: Int
    let hp: CGFloat
    let speed: CGFloat
    let range: CGFloat
    let damage: CGFloat
    let cooldown: CGFloat
    let radius: CGFloat
    let buildTime: CGFloat
    let sight: CGFloat
    let splash: CGFloat
    let hotkey: String
    let desc: String
}

enum UnitKind: CaseIterable {
    case worker, marine, tank

    var stats: UnitStats {
        switch self {
        case .worker:
            return UnitStats(name: "Engineer", glyph: "EN", cost: 50, supply: 1, hp: 45, speed: 95, range: 6,
                             damage: 4, cooldown: 1.2, radius: 9, buildTime: 10, sight: 220, splash: 0, hotkey: "W",
                             desc: "Mines crystal and constructs buildings.")
        case .marine:
            return UnitStats(name: "Ranger", glyph: "RG", cost: 50, supply: 1, hp: 60, speed: 88, range: 150,
                             damage: 7, cooldown: 0.75, radius: 10, buildTime: 12, sight: 260, splash: 0, hotkey: "R",
                             desc: "Versatile rifle infantry.")
        case .tank:
            return UnitStats(name: "Siege Tank", glyph: "TK", cost: 150, supply: 3, hp: 220, speed: 62, range: 230,
                             damage: 32, cooldown: 2.2, radius: 17, buildTime: 22, sight: 280, splash: 45, hotkey: "T",
                             desc: "Long-range armor. Shells deal splash damage.")
        }
    }
}

// MARK: - Buildings

struct BuildingStats {
    let name: String
    let short: String
    let glyph: String
    let cost: Int
    let hp: CGFloat
    let half: CGFloat
    let buildTime: CGFloat
    let supply: Int
    let produces: [UnitKind]
    let requires: BuildingKind?
    let range: CGFloat
    let damage: CGFloat
    let cooldown: CGFloat
    let sight: CGFloat
    let hotkey: String
    let desc: String
}

enum BuildingKind: CaseIterable {
    case hq, depot, barracks, factory, turret

    var stats: BuildingStats {
        switch self {
        case .hq:
            return BuildingStats(name: "Command Center", short: "HQ", glyph: "HQ", cost: 400, hp: 1500, half: 80,
                                 buildTime: 60, supply: 10, produces: [.worker], requires: nil, range: 0, damage: 0,
                                 cooldown: 0, sight: 340, hotkey: "C",
                                 desc: "Trains Engineers. Crystal drop-off. +10 supply.")
        case .depot:
            return BuildingStats(name: "Supply Depot", short: "Depot", glyph: "SD", cost: 100, hp: 400, half: 42,
                                 buildTime: 20, supply: 8, produces: [], requires: nil, range: 0, damage: 0,
                                 cooldown: 0, sight: 200, hotkey: "E", desc: "Provides +8 supply.")
        case .barracks:
            return BuildingStats(name: "Barracks", short: "Barracks", glyph: "BK", cost: 150, hp: 900, half: 64,
                                 buildTime: 35, supply: 0, produces: [.marine], requires: .hq, range: 0, damage: 0,
                                 cooldown: 0, sight: 240, hotkey: "B", desc: "Trains Rangers.")
        case .factory:
            return BuildingStats(name: "Factory", short: "Factory", glyph: "FC", cost: 200, hp: 1100, half: 70,
                                 buildTime: 45, supply: 0, produces: [.tank], requires: .barracks, range: 0,
                                 damage: 0, cooldown: 0, sight: 240, hotkey: "F", desc: "Builds Siege Tanks.")
        case .turret:
            return BuildingStats(name: "Gun Turret", short: "Turret", glyph: "GT", cost: 100, hp: 380, half: 30,
                                 buildTime: 22, supply: 0, produces: [], requires: .barracks, range: 210,
                                 damage: 11, cooldown: 0.7, sight: 270, hotkey: "T",
                                 desc: "Static defense. Fires on nearby enemies.")
        }
    }
}

// MARK: - Difficulty

enum Difficulty: Int, CaseIterable {
    case easy, normal, hard

    var name: String { ["Easy", "Normal", "Hard"][rawValue] }
    var blurb: String { ["Relaxed foe, late attacks", "A balanced commander", "Aggressive, rich economy"][rawValue] }
    var incomeMultiplier: CGFloat { [0.7, 1.0, 1.35][rawValue] }
    var firstAttack: CGFloat { [480, 330, 230][rawValue] }
    var initialWave: Int { [5, 8, 10][rawValue] }
    var pace: CGFloat { [1.35, 1.0, 0.75][rawValue] }
    var workerTarget: Int { [12, 16, 20][rawValue] }
}

enum ButtonIcon {
    case attack, stop, unit(UnitKind), building(BuildingKind)
}

struct CommandButton {
    let icon: ButtonIcon
    let title: String
    let hotkey: String
    let cost: Int?
    let enabled: Bool
    let tip: String
    let action: () -> Void
}

/// Small deterministic RNG so generated art and maps are stable between runs.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
