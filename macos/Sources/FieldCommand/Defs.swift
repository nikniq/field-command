import SpriteKit
import AppKit

/// Version shown on the title screen. `build_app.sh` reads this line for the bundle's Info.plist,
/// so the version on screen and the version in the bundle cannot drift apart.
let appVersion = "1.16.0"

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

/// Plays a synthesised effect (see Audio.swift). The old macOS system-sound names still work, mapped to
/// their equivalents, so call sites written before the synthesiser need not change.
func playSound(_ name: String) {
    let mapped = ["Glass": "complete", "Pop": "pop", "Tink": "click", "Hero": "victory", "Basso": "defeat",
                  "Submarine": "alert", "Funk": "wave"][name] ?? name
    Audio.play(mapped, minGap: Audio.minGaps[mapped] ?? 0)
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
    /// Building that must be finished before this unit can be trained.
    var requires: BuildingKind? = nil
}

enum UnitKind: CaseIterable {
    case worker, marine, tank, sniper, medic

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
        case .sniper:
            return UnitStats(name: "Sniper", glyph: "SN", cost: 125, supply: 2, hp: 55, speed: 74, range: 330,
                             damage: 55, cooldown: 3.2, radius: 10, buildTime: 24, sight: 360, splash: 0, hotkey: "N",
                             desc: "Outranges tanks and turrets, one heavy shot at a time. Helpless up close.",
                             requires: .factory)
        case .medic:
            return UnitStats(name: "Medic", glyph: "MD", cost: 75, supply: 1, hp: 50, speed: 90, range: 0,
                             damage: 0, cooldown: 0.0, radius: 10, buildTime: 14, sight: 240, splash: 0, hotkey: "M",
                             desc: "Heals wounded infantry nearby. Unarmed: keep it behind the line.")
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
    case hq, depot, barracks, factory, turret, radar, artillery, shield

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
                                 buildTime: 35, supply: 0, produces: [.marine, .sniper, .medic], requires: .hq, range: 0, damage: 0,
                                 cooldown: 0, sight: 240, hotkey: "B",
                                 desc: "Trains Rangers and Medics, and Snipers once a Factory is up.")
        case .factory:
            return BuildingStats(name: "Factory", short: "Factory", glyph: "FC", cost: 200, hp: 1100, half: 70,
                                 buildTime: 45, supply: 0, produces: [.tank], requires: .barracks, range: 0,
                                 damage: 0, cooldown: 0, sight: 240, hotkey: "F", desc: "Builds Siege Tanks.")
        case .turret:
            return BuildingStats(name: "Gun Turret", short: "Turret", glyph: "GT", cost: 100, hp: 380, half: 30,
                                 buildTime: 22, supply: 0, produces: [], requires: .barracks, range: 210,
                                 damage: 11, cooldown: 0.7, sight: 270, hotkey: "T",
                                 desc: "Static defense. Fires on nearby enemies.")
        case .radar:
            return BuildingStats(name: "Radar Station", short: "Radar", glyph: "RD", cost: 175, hp: 520, half: 34,
                                 buildTime: 30, supply: 0, produces: [], requires: .barracks, range: 0, damage: 0,
                                 cooldown: 0, sight: 900, hotkey: "D",
                                 desc: "Sweeps a wide circle of the map. Unarmed.")
        case .artillery:
            return BuildingStats(name: "Artillery", short: "Artillery", glyph: "AT", cost: 250, hp: 600, half: 40,
                                 buildTime: 40, supply: 0, produces: [], requires: .factory, range: 480, damage: 45,
                                 cooldown: 4.0, sight: 300, hotkey: "L",
                                 desc: "Lobs shells 480 out, further than it sees: spotters find its targets. Blind inside 150.")
        case .shield:
            return BuildingStats(name: "Shield Generator", short: "Shield", glyph: "SG", cost: 225, hp: 500, half: 36,
                                 buildTime: 35, supply: 0, produces: [], requires: .barracks, range: 0, damage: 0,
                                 cooldown: 0, sight: 240, hotkey: "K",
                                 desc: "Shields every building of yours within 320: 300 points soaked before the walls, recharging.")
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

// Bridges come with the map rather than being built from scratch, so their numbers live here rather
// than in BuildingStats: nobody owns one, anybody can shell it down, any Engineer can rebuild it.
let bridgeHP: Double = 900
let bridgeCost = 75
let bridgeRebuildTime: Double = 25

// Repair: one Engineer restores a building's full health in `repairTime` seconds (more Engineers stack), and a
// full bar costs `repairCostRatio` of the building's price, charged as the health goes back on. Engineers also
// repair Siege Tanks, at the same rate and the same share of the tank's price.
// The campaign: hand-authored missions played in order against the computer. `win` is "destroy" (the usual
// rule), "survive" (be standing when `seconds` run out) or "hold" (keep the point at `hold` yours, with no
// enemy unit inside the ring, for `seconds` in a row). Same list as the Linux edition's defs.CAMPAIGN.
struct Mission {
    let id: String
    let title: String
    let map: String
    let opponents: Int
    let difficulty: Int
    let teams: Int
    let win: String
    let seconds: Double
    let hold: (Double, Double, Double)?
    let brief: String
}

let campaign: [Mission] = [
    Mission(id: "first_light", title: "First Light", map: "twin_ridges", opponents: 1, difficulty: 0, teams: 0, win: "destroy", seconds: 0, hold: nil,
            brief: "Mine, build, and take the enemy base. The computer goes easy on you — this once."),
    Mission(id: "hold_the_line", title: "Hold the Line", map: "river_crossing", opponents: 1, difficulty: 2, teams: 0, win: "survive", seconds: 480, hold: nil,
            brief: "Eight minutes. The enemy comes over the bridges in force; be standing when the clock runs out. Cut a bridge if you must."),
    Mission(id: "gold_run", title: "The Gold Run", map: "highland_pass", opponents: 1, difficulty: 1, teams: 0, win: "hold", seconds: 180, hold: (2000, 1400, 260),
            brief: "Hold the gold deposit in the middle pass for three minutes without an enemy inside the ring."),
    Mission(id: "crossfire", title: "Crossfire", map: "four_corners", opponents: 3, difficulty: 1, teams: 2, win: "destroy", seconds: 0, hold: nil,
            brief: "You and a computer ally against two. Use attack points (Z) to bring your ally onto the fight."),
    Mission(id: "long_march", title: "The Long March", map: "long_march", opponents: 11, difficulty: 2, teams: 2, win: "destroy", seconds: 0, hold: nil,
            brief: "Twelve commanders in two lines across a wide river. Hold the middle bridges, take the gold, and roll them up."),
]
func missionNamed(_ id: String?) -> Mission? { id.flatMap { i in campaign.first { $0.id == i } } }

// Every side starts with this much crystal in the bank.
let startCrystal = 2000

// Supply crates: one drops somewhere open every crateInterval seconds (at most crateMax on the field, each
// gone after crateLife), and the first unit to reach one collects its gift for its side: crystal, a squad
// of Rangers, or a Siege Tank. crateKinds is the wire order.
let crateInterval: Double = 75
let crateFirst: Double = 60
let crateMax = 4
let crateLife: Double = 180
let crateRadius: Double = 22
let crateKinds = ["crystal", "squad", "tank"]
let crateSquad = 3
let crateCrystal = [150, 200, 250, 300, 400]

// The Command Center's point-defence gun (the "defense" upgrade): a turret's reach, a little less bite.
let hqGunRange: Double = 240
let hqGunDamage: Double = 14
let hqGunCooldown: Double = 0.6

// Artillery: a fixed gun that reaches beyond its own sight, so it needs something else to see the target. Its
// shells fly slowly in a high arc (visible all the way), land with splash, and it cannot hit anything close.
let artilleryMinRange: Double = 150
let artillerySplash: Double = 55
let artilleryShellSpeed: Double = 380    // world units a second; tank shells fly at 650
let tankShellSpeed: Double = 650

// Shield generators: every friendly building within shieldRadius carries up to shieldMax shield points that
// soak damage before the walls; after shieldDelay seconds without a hit they recharge at shieldRegen a second.
let shieldRadius: Double = 320
let shieldMax: Double = 300
let shieldRegen: Double = 15
let shieldDelay: Double = 4

// Gold: a deposit worth a hundred normal mineral nodes. Drawn gold (crystal variant 3), mined like any other,
// but it does not run out — a spot worth holding for the whole match.
let goldAmount = 150000

let repairTime: Double = 30
let repairCostRatio: Double = 0.35

// Healing: a Medic restores `healRate` hit points a second to one wounded ally on foot (Engineers, Rangers,
// Snipers, other Medics) within `healRange`, and looks for the wounded as far as it can see.
let healRate: Double = 6
let healRange: Double = 60

// Siege mode. A Siege Tank can dig in: it stops moving and takes `siegeTransition` seconds to switch either
// way, and while sieged it fires further and harder but cannot hit anything closer than `siegeMinRange`.
// Mobile, a Sniper (330) outranges it; sieged, it outranges the Sniper — but has to be set up first.
let siegeRange: Double = 340
let siegeMinRange: Double = 90
let siegeDamage: Double = 50
let siegeSplash: Double = 65
let siegeCooldown: Double = 3.2
let siegeTransition: Double = 2.5
let siegeSight: Double = 360          // dug in, a tank sees as far as it shoots

enum SiegeMode: Int { case mobile = 0, sieging, sieged, unsieging }

// MARK: - Building upgrades
//
// Bought on one building at a time, researched by that building over `time` seconds, and permanent for it.
// `cost` is a fraction of the building's own price unless `flat` is set. The order of `UpgradeKind.allCases`
// is the wire order: an installed set travels as a bitmask, an upgrade in progress as its index.

struct UpgradeStats {
    let name: String
    let short: String
    let desc: String
    let cost: Double
    let flat: Bool
    let time: Double
    let hotkey: String
    let appliesTo: [BuildingKind]      // empty means every building
    let button: String                 // the label on the 64-point command-card button; `name` is for tooltips
}

enum UpgradeKind: Int, CaseIterable {
    case hp = 0, armor, prod, supply, guns, defense

    var stats: UpgradeStats {
        switch self {
        case .hp: return UpgradeStats(name: "Reinforce", short: "Reinforced", desc: "Doubles the building's hit points.",
                                      cost: 0.6, flat: false, time: 30, hotkey: "V", appliesTo: [], button: "Reinforce")
        case .armor: return UpgradeStats(name: "Armour plating", short: "Armoured", desc: "The building takes 30% less damage.",
                                         cost: 0.6, flat: false, time: 30, hotkey: "X", appliesTo: [], button: "Armour")
        case .prod: return UpgradeStats(name: "Assembly line", short: "Assembly line", desc: "Trains units twice as fast.",
                                        cost: 0.8, flat: false, time: 40, hotkey: "U", appliesTo: [.hq, .barracks, .factory], button: "Assembly")
        case .supply: return UpgradeStats(name: "Expanded storage", short: "Expanded", desc: "+8 supply from this depot.",
                                          cost: 75, flat: true, time: 20, hotkey: "U", appliesTo: [.depot], button: "Storage")
        case .guns: return UpgradeStats(name: "Twin cannon", short: "Twin cannon", desc: "Damage 11 to 20 and range 210 to 260.",
                                        cost: 0.9, flat: false, time: 35, hotkey: "U", appliesTo: [.turret], button: "Twin gun")
        case .defense: return UpgradeStats(name: "Point defence", short: "Point defence", desc: "The Command Center mounts a gun: damage 14 at range 240.",
                                           cost: 0.5, flat: false, time: 35, hotkey: "J", appliesTo: [.hq], button: "Defence")
        }
    }

    func applies(to b: BuildingKind) -> Bool { stats.appliesTo.isEmpty || stats.appliesTo.contains(b) }
    func cost(for b: BuildingKind) -> Int { stats.flat ? Int(stats.cost) : Int((Double(b.stats.cost) * stats.cost).rounded()) }
    var wireName: String { ["hp", "armor", "prod", "supply", "guns", "defense"][rawValue] }
}

// MARK: - The Armory
//
// Kit is bought once per match with crystal and worn by every unit of that type, present and future. Effects:
// hp/damage/speed/cooldown are fractions of the unit's base value (cooldown is a reduction), range is added in
// world units, work speeds up an Engineer's repairing and rebuilding, carry adds crystal to each mining trip.
// The order of `kits` is the wire order: what a player owns travels as a bitmask.

struct Kit {
    let id: String
    let unit: UnitKind
    let name: String
    let cost: Int
    let desc: String
    let effect: [(String, Double)]
    func bonus(_ key: String) -> Double { effect.first { $0.0 == key }?.1 ?? 0 }
}

let kits: [Kit] = [
    Kit(id: "hardhat", unit: .worker, name: "Hard hat", cost: 100, desc: "+50% hit points. Engineers survive a stray shell.", effect: [("hp", 0.5)]),
    Kit(id: "powertools", unit: .worker, name: "Power tools", cost: 150, desc: "Repairs and rebuilds 30% faster.", effect: [("work", 0.3)]),
    Kit(id: "cargorig", unit: .worker, name: "Cargo rig", cost: 150, desc: "Carries 12 crystal per trip instead of 8.", effect: [("carry", 4)]),
    Kit(id: "flak", unit: .marine, name: "Flak jacket", cost: 200, desc: "+25% hit points for every Ranger.", effect: [("hp", 0.25)]),
    Kit(id: "hollowpoint", unit: .marine, name: "Hollow points", cost: 250, desc: "+20% Ranger damage.", effect: [("damage", 0.2)]),
    Kit(id: "boots", unit: .marine, name: "Sprint boots", cost: 150, desc: "Rangers move 15% faster.", effect: [("speed", 0.15)]),
    Kit(id: "scope", unit: .sniper, name: "Long scope", cost: 300, desc: "+30 range: 360, further than a dug-in tank.", effect: [("range", 30)]),
    Kit(id: "ghillie", unit: .sniper, name: "Ghillie suit", cost: 200, desc: "+25% hit points for every Sniper.", effect: [("hp", 0.25)]),
    Kit(id: "matchammo", unit: .sniper, name: "Match ammo", cost: 250, desc: "Snipers reload 20% faster.", effect: [("cooldown", 0.2)]),
    Kit(id: "reactive", unit: .tank, name: "Reactive armour", cost: 300, desc: "+25% hit points for every Siege Tank.", effect: [("hp", 0.25)]),
    Kit(id: "barrel", unit: .tank, name: "Extended barrel", cost: 300, desc: "+20 range, mobile and dug in.", effect: [("range", 20)]),
    Kit(id: "autoloader", unit: .tank, name: "Autoloader", cost: 350, desc: "Tanks reload 20% faster.", effect: [("cooldown", 0.2)]),
    Kit(id: "trauma", unit: .medic, name: "Trauma kit", cost: 200, desc: "Medics heal 50% faster.", effect: [("heal", 0.5)]),
    Kit(id: "plates", unit: .medic, name: "Ceramic plates", cost: 150, desc: "+30% hit points for every Medic.", effect: [("hp", 0.3)]),
    Kit(id: "litter", unit: .medic, name: "Field litter", cost: 150, desc: "Medics move 15% faster.", effect: [("speed", 0.15)]),
]
let kitIds = kits.map { $0.id }
let carryCap = 8            // crystal an Engineer carries per trip without a Cargo rig

// Attacker reveal: anything that hits you shows itself to your alliance for `revealTime` seconds, even from
// beyond your sight — so a Sniper or a dug-in tank shelling you from the dark can be seen and answered.
let revealTime: Double = 2.5
let revealRadius: Double = 60

// Veterancy: a rank at each kill count, every rank adding `vetBonus` of base damage and hit points.
let vetThresholds = [2, 5, 10]
let vetBonus: Double = 0.10

// Watchtowers: neutral control points at the centre and flanks of every map. Troops of one alliance alone
// inside `towerRadius` for `towerCaptureTime` seconds take one; the owner sees `towerSight` around it.
let towerRadius: Double = 140
let towerCaptureTime: Double = 8
let towerSight: Double = 700
let towerHalf: Double = 26

let armorFactor: Double = 0.7
let turretUpgradedDamage: Double = 20
let turretUpgradedRange: Double = 260
let depotUpgradedSupply = 8

// MARK: - Single-player teams

/// The alliance a slot plays for: its own in a free-for-all (teams 0), otherwise dealt round-robin into
/// `teams` alliances — the same rule as the multiplayer lobby's presets.
func teamOf(slot: Int, teams: Int) -> Int { teams >= 2 ? slot % teams + 1 : slot + 1 }

/// Who plays with whom, for the title screen: "You + Computer 2  vs  Computer 1 + Computer 3".
/// Matches the Python edition's `lineup_text` word for word.
func lineupText(opponents: Int, teams: Int) -> String {
    let names = ["You"] + (1...max(1, opponents)).map { opponents > 1 ? "Computer \($0)" : "Computer" }
    guard teams >= 2 else { return "Free-for-all: everyone for themselves" }
    var sides: [Int: [String]] = [:]
    for (i, n) in names.enumerated() { sides[teamOf(slot: i, teams: teams), default: []].append(n) }
    let ordered = sides.keys.sorted().map { sides[$0]! }
    let full = ordered.map { $0.joined(separator: " + ") }.joined(separator: "  vs  ")
    if full.count <= 80 { return full }
    // Big games: say it in numbers rather than names so the line fits the screen.
    let mine = sides[teamOf(slot: 0, teams: teams)]!
    let others = sides.keys.sorted().filter { $0 != teamOf(slot: 0, teams: teams) }.map { sides[$0]!.count }
    let allies = mine.count - 1
    let sizes = Set(others).count == 1 ? "\(others[0])" : others.map(String.init).joined(separator: "/")
    return "You + \(allies) \(allies == 1 ? "ally" : "allies")  vs  \(others.count) \(others.count == 1 ? "team" : "teams") of \(sizes)"
}

enum ButtonIcon {
    case attack, stop, siege(Bool), upgrade(UpgradeKind), unit(UnitKind), building(BuildingKind)
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
