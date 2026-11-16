import Foundation

/// Which games Home shows, following the Qt client (`opennow-qt/qml/screens/HomeScreen.qml`).
/// Pure rules, kept apart from the views so they can be tested.
enum TVConsoleHomeContent {
    /// One wide tile and thirteen square ones fill two rows, leaving the third for "Add a game".
    static let prefillLimit = 15

    /// Pinned games, or the most recently played ones while nothing is pinned, so Home is never
    /// an empty grid. A game with a running session leads the list when it is not in it already.
    static func gameIDs(pinned: [String], recent: [String], running: String? = nil) -> [String] {
        let base = pinned.isEmpty ? Array(recent.prefix(prefillLimit)) : pinned
        guard let running, !base.contains(running) else { return base }
        return [running] + base
    }

    /// Until the user has chosen a size for any tile, the first tile is the wide one.
    static func wideIDs(explicit: [String]?, gameIDs: [String]) -> Set<String> {
        if let explicit { return Set(explicit) }
        return Set(gameIDs.prefix(1))
    }

    /// `id` takes the place `target` had; everything between shifts by one.
    static func moving(_ id: String, onto target: String, in ids: [String]) -> [String] {
        guard let source = ids.firstIndex(of: id), let destination = ids.firstIndex(of: target) else { return ids }
        var updated = ids
        updated.remove(at: source)
        updated.insert(id, at: destination)
        return updated
    }
}

/// Tile packing of the Home grid: 8 columns by 3 rows, a wide tile spans two columns, and an
/// "Add a game" tile follows the last game while there is room. Games that do not fit are left out.
struct TVConsoleHomeLayout: Equatable {
    enum Direction { case left, right, up, down }

    struct Item: Identifiable, Equatable {
        static let addID = "tv-console-home-add"

        /// `nil` for the "Add a game" tile.
        let gameID: String?
        let wide: Bool
        let row: Int
        let column: Int

        var id: String { gameID ?? Self.addID }
    }

    static let columns = 8
    static let rows = 3

    let items: [Item]

    init(gameIDs: [String], wideIDs: Set<String>) {
        var items: [Item] = []
        var row = 0
        var column = 0
        for id in gameIDs {
            let wide = wideIDs.contains(id)
            let span = wide ? 2 : 1
            if column + span > Self.columns {
                row += 1
                column = 0
            }
            if row >= Self.rows { break }
            items.append(Item(gameID: id, wide: wide, row: row, column: column))
            column += span
        }
        if column >= Self.columns {
            row += 1
            column = 0
        }
        if row < Self.rows {
            items.append(Item(gameID: nil, wide: false, row: row, column: column))
        }
        self.items = items
    }

    /// The tile a move in `direction` lands on: the nearest one in the same row for left and
    /// right, and the nearest column of the nearest row for up and down.
    func neighbor(of id: String, toward direction: Direction) -> Item? {
        guard let origin = items.first(where: { $0.id == id }) else { return nil }
        let candidates = items.filter { candidate in
            switch direction {
            case .left: return candidate.row == origin.row && candidate.column < origin.column
            case .right: return candidate.row == origin.row && candidate.column > origin.column
            case .up: return candidate.row < origin.row
            case .down: return candidate.row > origin.row
            }
        }
        return candidates.min { score($0, from: origin) < score($1, from: origin) }
    }

    private func score(_ candidate: Item, from origin: Item) -> Int {
        abs(candidate.row - origin.row) * 100 + abs(candidate.column - origin.column)
    }
}
