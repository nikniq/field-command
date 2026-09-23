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

    /// Health bars on everything friendly, not only the hurt and the selected.
    static var barsAlways: Bool {
        get { d.object(forKey: "barsAlways") as? Bool ?? false }
        set { d.set(newValue, forKey: "barsAlways") }
    }

    static var objectives: Bool {
        get { d.object(forKey: "objectives") as? Bool ?? true }
        set { d.set(newValue, forKey: "objectives") }
    }

    /// Campaign missions completed, by id.
    static var campaignDone: [String] {
        get { d.stringArray(forKey: "campaignDone") ?? [] }
        set { d.set(newValue, forKey: "campaignDone") }
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
        clampTeams()
    }

    static func cycleOpponents() {
        opponents = opponents % maxOpponents + 1
        clampTeams()
    }

    // Teams for a single-player game. Players are dealt round-robin into `teams` alliances — the same rule
    // as the multiplayer lobby's presets — so with three opponents, "2 teams" is you and Computer 2 against
    // Computers 1 and 3. 0 means free-for-all.

    static var teams: Int {
        get { d.object(forKey: "teams") as? Int ?? 0 }
        set { d.set(newValue, forKey: "teams") }
    }

    /// 0 (free-for-all) plus every team count that is not just free-for-all by another name.
    static var teamOptions: [Int] {
        let players = 1 + opponents
        return [0] + [2, 3, 4].filter { $0 < players }
    }

    static var teamCount: Int { teamOptions.contains(teams) ? teams : 0 }

    static func cycleTeams() {
        let opts = teamOptions
        teams = opts[((opts.firstIndex(of: teamCount) ?? 0) + 1) % opts.count]
    }

    private static func clampTeams() { if !teamOptions.contains(teams) { teams = 0 } }
}
