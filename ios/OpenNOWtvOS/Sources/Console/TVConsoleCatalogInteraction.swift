import SwiftUI

/// What the Library and Store pages do with the focused game, so both behave the same: Select
/// opens its details (and launches from there), Y or Play/Pause pins it to Home or takes it off,
/// and the controller's Options button jumps to the search field.
struct TVConsoleCatalogInteraction: ViewModifier {
    let games: [CloudGame]
    let focus: FocusState<TVConsoleCatalogFocus?>.Binding
    /// The game focus was last on; it stays the described one while focus is elsewhere.
    @Binding var currentID: String?
    @Binding var detailsGame: CloudGame?

    @EnvironmentObject private var store: OpenNOWStore
    @EnvironmentObject private var input: TVConsoleInput
    @State private var pendingLaunchRequest: GameLaunchRequest?

    func body(content: Content) -> some View {
        content
            .onChange(of: focus.wrappedValue) { _, newValue in
                if let id = newValue?.gameID { currentID = id }
            }
            .onChange(of: games.isEmpty) { _, isEmpty in
                // The games arrive after the first frame, when the search field was the only
                // thing focus could take. Hand it to the first cover instead of leaving it there.
                guard !isEmpty, focus.wrappedValue == .search, let first = games.first else { return }
                focus.wrappedValue = .game(first.id)
            }
            .onReceive(input.presses) { press in
                switch press {
                case .y: togglePin()
                case .options: focus.wrappedValue = .search
                // X arrives as Play/Pause below; handling it here too would pin and unpin at once.
                case .x, .previousPage, .nextPage: break
                }
            }
            .onPlayPauseCommand(perform: togglePin)
            .presentGameDetailsSheet(selectedGame: $detailsGame, store: store) { game, option in
                pendingLaunchRequest = GameLaunchRequest(game: game, launchOption: option)
            }
            .printedWasteLaunchSheet(pendingLaunchRequest: $pendingLaunchRequest)
    }

    private func togglePin() {
        guard let id = focus.wrappedValue?.gameID, let game = games.first(where: { $0.id == id }) else { return }
        store.toggleFavorite(game)
    }
}

extension TVConsoleHints {
    /// Hints of a catalog page for the game being described.
    static func catalog(describing game: CloudGame?, pinned: Bool) -> TVConsoleHints {
        TVConsoleHints(
            left: [.init(button: .options, label: "Search")],
            right: game == nil ? [] : [
                .init(button: .x, label: pinned ? "Remove from Home" : "Pin to Home"),
                .init(button: .select, label: "Details"),
            ]
        )
    }
}

extension CloudGame {
    /// "Publisher · Genre", leaving out what the catalog does not give.
    var consoleByline: String {
        [publisher ?? developer ?? "", genre == "Cloud Game" ? "" : genre]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// "● In your Steam library", the ownership line of the catalog pages.
struct TVConsoleOwnedLabel: View {
    let store: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(TVConsoleTheme.mint).frame(width: 9, height: 9)
            Text("In your \(gameStoreDisplayName(store)) library")
                .font(TVConsoleTheme.display(17, weight: 800))
                .foregroundStyle(TVConsoleTheme.mint)
        }
        .lineLimit(1)
    }
}

/// Lays its subviews out in rows, wrapping to the next row when one is full.
struct TVConsoleFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, width: proposal.width ?? .infinity)
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(of: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(of subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.indices + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
