import Foundation
import CoreGraphics

/// Player preferences, persisted in UserDefaults.
enum Settings {
    private static let d = UserDefaults.standard

    static let speeds: [(name: String, value: CGFloat)] = [("Slow", 0.75), ("Normal", 1.0), ("Fast", 1.35), ("Faster", 1.7)]

    static var speedIndex: Int {
        get { d.object(forKey: "speedIndex") as? Int ?? 1 }
        set { d.set((newValue + speeds.count) % speeds.count, forKey: "speedIndex") }
    }
    static var gameSpeed: CGFloat { speeds[speedIndex].value }
    static var speedName: String { speeds[speedIndex].name }

    static var edgeScroll: Bool {
        get { d.object(forKey: "edgeScroll") as? Bool ?? true }
        set { d.set(newValue, forKey: "edgeScroll") }
    }

    static var sound: Bool {
        get { d.object(forKey: "sound") as? Bool ?? true }
        set { d.set(newValue, forKey: "sound") }
    }

    static var objectives: Bool {
        get { d.object(forKey: "objectives") as? Bool ?? true }
        set { d.set(newValue, forKey: "objectives") }
    }

    static var lastDifficulty: Int {
        get { d.object(forKey: "lastDifficulty") as? Int ?? 1 }
        set { d.set(newValue, forKey: "lastDifficulty") }
    }

    static var mapId: String {
        get { d.string(forKey: "mapId") ?? "twin_ridges" }
        set { d.set(newValue, forKey: "mapId") }
    }

    static var maxOpponents: Int { (SMapGen.info(mapId)?.players ?? 2) - 1 }

    static var opponents: Int {
        get { min(maxOpponents, max(1, d.object(forKey: "opponents") as? Int ?? 1)) }
        set { d.set(newValue, forKey: "opponents") }
    }

    static func cycleMap() {
        let ids = SMapGen.catalog.map { $0.id }
        mapId = ids[((ids.firstIndex(of: mapId) ?? -1) + 1) % ids.count]
    }

    static func cycleOpponents() { opponents = opponents % maxOpponents + 1 }
}
