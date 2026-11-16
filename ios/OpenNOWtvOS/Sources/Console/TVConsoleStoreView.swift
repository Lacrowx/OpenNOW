import SwiftUI

/// The console Store (`opennow-qt/qml/screens/StoreScreen.qml`): every GeForce NOW game as a
/// cover grid over a strip describing the focused one. Unlike the Qt Store it has the Library's
/// search and filter row, because it is the only place to find a game that is not owned yet.
/// Search and filtering are the shared catalog's (`CatalogPresentation.gridGames`).
struct TVConsoleStoreView: View {
    @EnvironmentObject private var store: OpenNOWStore
    @EnvironmentObject private var input: TVConsoleInput
    @EnvironmentObject private var shell: TVConsoleShellState
    @FocusState private var focus: TVConsoleCatalogFocus?
    @State private var currentID: String?
    @State private var filter = TVConsoleCatalogFilter()
    @State private var showingFilter = false
    @State private var detailsGame: CloudGame?

    private static let sortLabels = ["Popular", "Title", "Recently played"]
    private static let showLabels = ["All games", "New this week"]

    private var sections: [TVConsoleFilterSection] {
        let catalog = store.catalogPresentation
        return filter.sections(
            sortLabels: Self.sortLabels, stores: catalog.storeFilters, genres: catalog.genreFilters,
            showLabels: Self.showLabels, storeLabel: gameStoreDisplayName
        )
    }

    private var isSearching: Bool {
        !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var games: [CloudGame] {
        let catalog = store.catalogPresentation
        let games = catalog.gridGames(
            query: store.searchText, remoteResults: store.remoteSearchResults,
            stores: Set([filter.storefront].compactMap { $0 }), genres: Set([filter.genre].compactMap { $0 }),
            sort: CatalogGameSort.allCases[min(filter.sort, CatalogGameSort.allCases.count - 1)]
        )
        guard filter.show == 1 else { return games }
        // This week's additions, as the iOS Store's "New games added" banner picks them.
        let weekly = Set(newlyAddedStoreHeroGames(games: catalog.catalogGames, limit: .max).map(catalogStableGameKey))
        return games.filter { weekly.contains(catalogStableGameKey($0)) }
    }

    var body: some View {
        let games = games
        let current = games.first { $0.id == currentID } ?? games.first
        let sections = sections
        let pinned = Set(store.settings.favoriteGameIds)

        ZStack(alignment: .topLeading) {
            TVConsoleBackground(artwork: current?.heroImageUrl ?? current?.detailsArtworkUrl, tint: 0x18230F)
            VStack(alignment: .leading, spacing: 0) {
                TVConsoleCatalogBar(
                    query: $store.searchText, prompt: "Search GeForce NOW games",
                    filterSummary: TVConsoleCatalogFilter.summary(of: sections),
                    countLabel: countLabel(shown: games.count),
                    filterOpen: showingFilter, focus: $focus
                ) { showingFilter = true }
                    .padding(.top, 126)
                grid(games, current: current, pinned: pinned)
                    .frame(width: 1760, height: 620)
                    .clipped()
                    .padding(.leading, 80)
                    .padding(.top, 6)
                if let current {
                    strip(current)
                        .frame(width: 1728, height: 96)
                        .padding(.leading, 96)
                        .padding(.top, 8)
                }
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
                eyebrow: "STORE", sections: sections,
                onChoose: { kind, index in
                    let catalog = store.catalogPresentation
                    filter.choose(index, in: kind, stores: catalog.storeFilters, genres: catalog.genreFilters)
                },
                onReset: { filter = TVConsoleCatalogFilter() }
            )
            .environmentObject(input)
        }
        .task {
            // Home's "Search" hint lands here with the search field ready for Select.
            guard shell.focusSearchOnArrival else { return }
            shell.focusSearchOnArrival = false
            focus = .search
        }
    }

    private func countLabel(shown: Int) -> String {
        if store.isSearchingCatalog { return "Searching…" }
        let total = store.catalogPresentation.catalogGames.count
        if total == 0 && store.isLoadingGames { return "Loading the catalog" }
        let base = total == 1 ? "1 game" : "\(total) games"
        return filter.isNarrowed || isSearching ? "\(shown) shown · \(base)" : base
    }

    @ViewBuilder
    private func grid(_ games: [CloudGame], current: CloudGame?, pinned: Set<String>) -> some View {
        if games.isEmpty {
            notice.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TVConsolePosterGrid(
                games: games, columns: 10, cell: CGSize(width: 174, height: 256), inset: CGPoint(x: 20, y: 16),
                showsStores: true, pinnedIDs: pinned, currentID: current?.id, focus: $focus
            ) { detailsGame = $0 }
        }
    }

    @ViewBuilder
    private var notice: some View {
        if store.isSearchingCatalog {
            TVConsoleCatalogNotice(title: "Searching…")
        } else if !store.catalogPresentation.catalogGames.isEmpty {
            TVConsoleCatalogNotice(title: "No games match these filters",
                                   detail: "Change the search or open Filter & sort to reset.")
        } else if store.isLoadingGames {
            TVConsoleCatalogNotice(title: "Loading the live catalog…")
        } else {
            TVConsoleCatalogNotice(title: "Catalog unavailable", detail: store.catalogError ?? "",
                                   actionTitle: "Try again") {
                Task { await store.refreshCatalog() }
            }
        }
    }

    /// The strip under the grid: the focused game's name, who made it, where it can be played.
    private func strip(_ game: CloudGame) -> some View {
        let stores = game.consoleStores
        return HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: -1) {
                Text(game.title)
                    .font(TVConsoleTheme.display(26))
                    .foregroundStyle(TVConsoleTheme.label)
                if !game.consoleByline.isEmpty {
                    Text(game.consoleByline)
                        .font(TVConsoleTheme.display(16, weight: 700))
                        .foregroundStyle(TVConsoleTheme.textMuted)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !stores.isEmpty {
                Text("AVAILABLE ON")
                    .font(TVConsoleTheme.mono(13, bold: true))
                    .tracking(1.56)
                    .foregroundStyle(TVConsoleTheme.textMuted)
                HStack(spacing: 8) {
                    ForEach(stores.prefix(4), id: \.self) { TVConsoleStoreChip(store: $0, markSize: 32, inset: 6) }
                }
            }
            if let owned = game.ownedStorefronts.first {
                Rectangle().fill(TVConsoleTheme.seam).frame(width: 1, height: 44)
                TVConsoleOwnedLabel(store: owned)
            }
        }
        .padding(.horizontal, 29)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tvConsoleGlass(radius: 32, strong: true)
        .accessibilityElement(children: .combine)
    }
}
