import SwiftUI

/// The console Library (`opennow-qt/qml/screens/LibraryScreen.qml`): the user's games as a cover
/// grid beside a panel describing the focused one. Filtering and sorting are the shared iOS
/// library's (`LibraryPresentationModel`); only the layout is the console's.
struct TVConsoleLibraryView: View {
    @EnvironmentObject private var store: OpenNOWStore
    @EnvironmentObject private var input: TVConsoleInput
    @StateObject private var presentation = LibraryPresentationModel()
    @FocusState private var focus: TVConsoleCatalogFocus?
    @State private var currentID: String?
    @State private var query = ""
    @State private var filter = TVConsoleCatalogFilter()
    @State private var showingFilter = false
    @State private var detailsGame: CloudGame?

    private static let showLabels = ["All library games", "Pinned to Home"]

    private var criteria: LibraryScreenCriteria {
        var criteria = LibraryScreenCriteria()
        criteria.query = query
        criteria.storefront = filter.storefront
        criteria.genre = filter.genre
        criteria.favoritesOnly = filter.show == 1
        criteria.order = LibraryOrder.allCases[min(filter.sort, LibraryOrder.allCases.count - 1)]
        return criteria
    }

    private var sections: [TVConsoleFilterSection] {
        filter.sections(
            sortLabels: LibraryOrder.allCases.map(\.title), stores: presentation.stores,
            genres: presentation.genres, showLabels: Self.showLabels, storeLabel: gameStoreDisplayName
        )
    }

    var body: some View {
        let games = presentation.items.map(\.game)
        let current = games.first { $0.id == currentID } ?? games.first
        let sections = sections
        let pinned = Set(store.settings.favoriteGameIds)

        ZStack(alignment: .topLeading) {
            TVConsoleBackground(artwork: current?.heroImageUrl ?? current?.detailsArtworkUrl, tint: 0x354016)
            VStack(alignment: .leading, spacing: 0) {
                TVConsoleCatalogBar(
                    query: $query, prompt: "Search your games",
                    filterSummary: TVConsoleCatalogFilter.summary(of: sections),
                    countLabel: countLabel(shown: games.count),
                    filterOpen: showingFilter, focus: $focus
                ) { showingFilter = true }
                    .padding(.top, 126)
                HStack(alignment: .top, spacing: 14) {
                    grid(games, current: current, pinned: pinned)
                        .frame(width: 1242, height: 702)
                        .clipped()
                    detailPanel(current, pinned: current.map { pinned.contains($0.id) } ?? false)
                        .frame(width: 488, height: 680)
                        .padding(.top, 14)
                }
                .padding(.leading, 80)
                .padding(.top, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .defaultFocus($focus, current.map { .game($0.id) }, priority: .userInitiated)
        .preference(key: TVConsoleHintsKey.self,
                    value: .catalog(describing: current, pinned: current.map { pinned.contains($0.id) } ?? false))
        .modifier(TVConsoleCatalogInteraction(games: games, focus: $focus, currentID: $currentID, detailsGame: $detailsGame))
        .fullScreenCover(isPresented: $showingFilter) {
            TVConsoleFilterSheet(
                eyebrow: "LIBRARY", sections: sections,
                onChoose: { kind, index in
                    filter.choose(index, in: kind, stores: presentation.stores, genres: presentation.genres)
                },
                onReset: { filter = TVConsoleCatalogFilter() }
            )
            .environmentObject(input)
        }
        .onAppear(perform: updatePresentation)
        .onChange(of: store.catalogRevision) { updatePresentation() }
        .onChange(of: store.user?.userId) { updatePresentation() }
        .onChange(of: store.settings.favoriteGameIds) { updatePresentation() }
        .onChange(of: criteria) { updatePresentation() }
        .onDisappear { presentation.cancel() }
    }

    private func updatePresentation() {
        presentation.update(
            games: store.visibleLibraryGames, sourceRevision: store.catalogRevision,
            accountID: store.user?.userId, favoriteIDs: store.settings.favoriteGameIds, criteria: criteria
        )
    }

    private func countLabel(shown: Int) -> String {
        let total = presentation.totalCount
        if total == 0 && (presentation.isUpdating || store.isLoadingGames) { return "Gathering your games" }
        let base = total == 1 ? "1 game in your library" : "\(total) games in your library"
        return criteria.isNarrowed ? "\(shown) shown · \(base)" : base
    }

    // MARK: Grid

    @ViewBuilder
    private func grid(_ games: [CloudGame], current: CloudGame?, pinned: Set<String>) -> some View {
        if games.isEmpty {
            notice.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TVConsolePosterGrid(
                games: games, columns: 7, cell: CGSize(width: 172, height: 269), inset: CGPoint(x: 19, y: 18),
                pinnedIDs: pinned, currentID: current?.id, focus: $focus
            ) { detailsGame = $0 }
        }
    }

    @ViewBuilder
    private var notice: some View {
        if presentation.totalCount > 0 {
            TVConsoleCatalogNotice(title: "No games match these filters",
                                   detail: "Change the search or open Filter & sort to reset.")
        } else if presentation.isUpdating || store.isLoadingGames {
            TVConsoleCatalogNotice(title: "Loading your games…")
        } else if let error = store.catalogError {
            TVConsoleCatalogNotice(title: "Couldn’t reach the catalog", detail: error, actionTitle: "Try again") {
                Task { await store.refreshCatalog() }
            }
        } else {
            TVConsoleCatalogNotice(title: "Your library is empty",
                                   detail: "Games you own on your linked stores appear here.")
        }
    }

    // MARK: Detail panel

    private func detailPanel(_ game: CloudGame?, pinned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(game.map { $0.consoleByline.uppercased() } ?? "GEFORCE NOW LIBRARY")
                .font(TVConsoleTheme.mono(14))
                .tracking(1.68)
                .foregroundStyle(TVConsoleTheme.textMuted)
                .lineLimit(1)
            Text(game?.title ?? "Pick a game")
                .font(TVConsoleTheme.display(40))
                .tracking(-0.8)
                .foregroundStyle(TVConsoleTheme.label)
                .lineLimit(2)
                .padding(.top, 2)
            if let game {
                if let owned = game.ownedStorefronts.first {
                    TVConsoleOwnedLabel(store: owned).padding(.top, 16)
                }
                let stores = game.consoleStores
                if !stores.isEmpty {
                    Text("AVAILABLE ON")
                        .font(TVConsoleTheme.mono(13))
                        .tracking(1.56)
                        .foregroundStyle(TVConsoleTheme.textMuted)
                        .padding(.top, 20)
                    TVConsoleFlow(spacing: 8) {
                        ForEach(stores, id: \.self) { TVConsoleStoreChip(store: $0) }
                    }
                    .padding(.top, 9)
                }
                if let description = game.summary ?? game.longDescription, !description.isEmpty {
                    Text(description)
                        .font(TVConsoleTheme.display(18, weight: 600))
                        .lineSpacing(2)
                        .foregroundStyle(TVConsoleTheme.textMuted)
                        .lineLimit(4)
                        .padding(.top, 23)
                }
            }
            Spacer(minLength: 0)
            if game != nil {
                Rectangle().fill(TVConsoleTheme.seam).frame(height: 1).padding(.bottom, 18)
                VStack(alignment: .leading, spacing: 12) {
                    action(.select, "Open details & play")
                    action(.x, pinned ? "Remove from Home" : "Pin to Home")
                }
            }
        }
        .padding(37)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tvConsoleGlass(radius: 40)
        .accessibilityElement(children: .combine)
    }

    private func action(_ button: TVConsoleButton, _ label: String) -> some View {
        HStack(spacing: 12) {
            TVConsoleGlyph(button: button)
            Text(label)
                .font(TVConsoleTheme.display(18, weight: 800))
                .foregroundStyle(TVConsoleTheme.label)
        }
    }
}
