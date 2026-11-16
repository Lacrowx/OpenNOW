import Foundation

/// A fixed feel for one DualSense trigger during a stream. The host only knows the pad as a
/// DualShock 4, so the game cannot shape the triggers; this is the player's own choice instead,
/// the same on every pull.
enum TVTriggerFeel: String, Codable, CaseIterable {
    case off, softResistance, firmResistance, weapon

    var title: String {
        switch self {
        case .off: "Off"
        case .softResistance: "Soft Resistance"
        case .firmResistance: "Firm Resistance"
        case .weapon: "Weapon Trigger"
        }
    }

    /// Resistance starts a little way into the pull so the trigger still rests freely; the weapon
    /// feel is the one the settings test page plays.
    var effect: NvstHidPassthrough.DualSense.TriggerEffect {
        switch self {
        case .off: .off
        case .softResistance: .feedback(strengths: [0, 0] + [Float](repeating: 0.375, count: 8))
        case .firmResistance: .feedback(strengths: [0, 0] + [Float](repeating: 0.75, count: 8))
        case .weapon: .weapon(start: 2.0 / 9, end: 5.0 / 9, strength: 1)
        }
    }

    /// The feel `steps` places on in the list, wrapping at both ends.
    func stepped(by steps: Int) -> TVTriggerFeel {
        let all = Self.allCases
        let index = (all.firstIndex(of: self)! + steps) % all.count
        return all[index < 0 ? index + all.count : index]
    }
}

/// The feel of both triggers.
struct TVTriggerFeels: Codable, Equatable {
    var left = TVTriggerFeel.off
    var right = TVTriggerFeel.off
}

/// Remembers each game's trigger feels between sessions, by game id.
struct TVTriggerFeelStore {
    static let key = "OpenNOW.tvOS.triggerFeelsByGame"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func feels(forGame id: String) -> TVTriggerFeels {
        all[id] ?? TVTriggerFeels()
    }

    /// Free triggers are what a game has without an entry, so choosing them removes it.
    func set(_ feels: TVTriggerFeels, forGame id: String) {
        var all = all
        all[id] = feels == TVTriggerFeels() ? nil : feels
        if all.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private var all: [String: TVTriggerFeels] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: TVTriggerFeels].self, from: data)) ?? [:]
    }
}
