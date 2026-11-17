import Foundation

/// What the Top Shelf shows, written by the app and read by its Top Shelf extension through the
/// shared app group. Compiled into both targets.
struct TVTopShelfSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable {
        let id: String
        let title: String
        let imageURL: URL?
        /// The `opennow://` link the app opens when the item is selected.
        let link: URL
    }

    /// The game of a session that is still running, on this Apple TV or left on the host.
    var playing: Item?
    var recent: [Item]

    static let empty = TVTopShelfSnapshot(playing: nil, recent: [])
    /// The system shows a section's items in one scrolling row; more than this is never reached.
    static let recentLimit = 12

    private static let defaultsKey = "topShelfSnapshot"

    /// The app group both targets share, from the `OpenNOWAppGroup` Info.plist key. Nil when the
    /// build has none, for example an unsigned build.
    static var appGroup: String? {
        (Bundle.main.object(forInfoDictionaryKey: "OpenNOWAppGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static var defaults: UserDefaults? { appGroup.flatMap(UserDefaults.init(suiteName:)) }

    static func load() -> TVTopShelfSnapshot {
        guard let data = defaults?.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(TVTopShelfSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    /// Saves the snapshot; false when it was unchanged or there is nowhere to save it.
    @discardableResult
    func save() -> Bool {
        guard let defaults = Self.defaults, self != Self.load(),
              let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.defaultsKey)
        return true
    }
}
