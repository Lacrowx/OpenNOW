import SwiftUI

/// The console Home (`opennow-qt/qml/screens/HomeScreen.qml`): the user's pinned games as a grid
/// of tiles over the focused game's artwork.
struct TVConsoleHomeView: View {
    let openLibrary: () -> Void

    @EnvironmentObject private var store: OpenNOWStore
    @EnvironmentObject private var input: TVConsoleInput
    @FocusState private var focusedID: String?
    /// The tile focus was last on. It stays the "current" one while focus is in the dock.
    @State private var currentID: String?
    /// `nil` until the user has chosen a size for a tile.
    @State private var explicitWideIDs = UserDefaults.standard.stringArray(forKey: TVConsoleHomeView.wideTilesKey)
    @State private var editingID: String?
    @State private var afterMenu: (() -> Void)?
    @State private var movingID: String?
    @State private var movePreview: [String] = []
    @State private var selectedGameForDetails: CloudGame?
    @State private var pendingLaunchRequest: GameLaunchRequest?

    private static let wideTilesKey = "tvConsoleHomeWideTileIDs"

    /// Everything the grid shows, resolved once per update.
    private struct Model {
        let layout: TVConsoleHomeLayout
        let games: [String: CloudGame]
        let wideIDs: Set<String>
        let runningID: String?

        var shownIDs: [String] { layout.items.compactMap(\.gameID) }
    }

    private var model: Model {
        let running = store.activeSession?.game
            ?? store.primaryRemoteJumpBackSession.flatMap(store.gameForRemoteSession)
        let catalog = store.catalogPresentation
        let pinned = store.settings.favoriteGameIds
        let ids = movingID == nil
            ? TVConsoleHomeContent.gameIDs(pinned: pinned, recent: catalog.recentGames.map(\.id), running: running?.id)
            : movePreview
        var games: [String: CloudGame] = [:]
        for id in ids {
            games[id] = id == running?.id ? running : catalog.favoriteGamesByID[id]
        }
        let resolved = ids.filter { games[$0] != nil }
        var wide = TVConsoleHomeContent.wideIDs(explicit: explicitWideIDs, gameIDs: resolved)
        // A running game that is only on Home because it is running leads the grid as a wide tile.
        if let running, !pinned.contains(running.id) { wide.insert(running.id) }
        return Model(
            layout: TVConsoleHomeLayout(gameIDs: resolved, wideIDs: wide),
            games: games, wideIDs: wide, runningID: running?.id
        )
    }

    var body: some View {
        let model = model
        let current = model.layout.items.first { $0.id == currentID } ?? model.layout.items.first
        let currentGame = current?.gameID.flatMap { model.games[$0] }

        ZStack(alignment: .topLeading) {
            TVConsoleBackground(artwork: currentGame?.heroImageUrl ?? currentGame?.detailsArtworkUrl)

            if movingID == nil {
                header(game: currentGame, isEmpty: model.games.isEmpty)
                    .frame(width: 1584, height: 76, alignment: .topLeading)
                    .offset(x: 168, y: 132)
            } else {
                moveBanner.offset(x: 168, y: 140)
            }

            grid(model, current: current)
                .padding(33)
                .tvConsoleGlass(radius: 42, fill: TVConsoleTheme.shell.opacity(0.52))
                .padding(.top, 224)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .preference(key: TVConsoleHintsKey.self, value: hints(for: current, model: model))
        .onChange(of: focusedID) { _, newValue in
            if let newValue { currentID = newValue }
        }
        .onChange(of: model.games.isEmpty) { _, isEmpty in
            // The catalog arrives after the first frame, when "Add a game" was the only tile focus
            // could take. Hand it to the first game instead of leaving it there.
            guard !isEmpty, let first = model.layout.items.first?.id else { return }
            if focusedID == TVConsoleHomeLayout.Item.addID { focusedID = first }
            if currentID == nil || currentID == TVConsoleHomeLayout.Item.addID { currentID = first }
        }
        .onReceive(input.presses) { press in
            if press == .x, let id = focusedID { openMenu(for: id, model: model) }
        }
        .onExitCommand(perform: movingID == nil ? nil : cancelMove)
        .fullScreenCover(item: Binding(
            get: { editingID.flatMap { model.games[$0] } },
            set: { if $0 == nil { editingID = nil } }
        ), onDismiss: {
            afterMenu?()
            afterMenu = nil
        }) { game in
            TVConsoleHomeTileMenu(
                game: game,
                position: (model.shownIDs.firstIndex(of: game.id) ?? 0) + 1,
                isWide: model.wideIDs.contains(game.id),
                canRemove: game.id != model.runningID,
                onMove: { closeMenu { beginMove(game.id, model: model) } },
                onSize: { setWide($0, for: game.id, model: model) },
                onDetails: { closeMenu { selectedGameForDetails = game } },
                onRemove: { closeMenu { remove(game.id, model: model) } }
            )
        }
        .presentGameDetailsSheet(selectedGame: $selectedGameForDetails, store: store) { game, option in
            pendingLaunchRequest = GameLaunchRequest(game: game, launchOption: option)
        }
        .printedWasteLaunchSheet(pendingLaunchRequest: $pendingLaunchRequest)
    }

    // MARK: Header

    private func header(game: CloudGame?, isEmpty: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Text(game.map(eyebrow) ?? (isEmpty ? "HOME" : "ADD A GAME"))
                    .font(TVConsoleTheme.mono(14))
                    .tracking(1.68)
                    .foregroundStyle(TVConsoleTheme.textMuted)
                Text(game?.title ?? (isEmpty ? "Your Home is ready" : "Pin a game from Library"))
                    .font(TVConsoleTheme.display(46))
                    .tracking(-0.92)
                    .foregroundStyle(TVConsoleTheme.label)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let owned = game?.ownedStorefronts.first {
                HStack(spacing: 8) {
                    Circle().fill(TVConsoleTheme.mint).frame(width: 9, height: 9)
                    Text("Owned on \(gameStoreDisplayName(owned))")
                        .font(TVConsoleTheme.display(17, weight: 800))
                        .foregroundStyle(TVConsoleTheme.mint)
                }
                .padding(.bottom, 9)
            }
        }
        .accessibilityHidden(true)
    }

    private func eyebrow(for game: CloudGame) -> String {
        [primaryStore(of: game).map(gameStoreDisplayName), game.genre]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            .uppercased()
    }

    private func primaryStore(of game: CloudGame) -> String? {
        game.ownedStorefronts.first ?? gameResolvedStores(game: game).first
    }

    private var moveBanner: some View {
        Text("MOVE TILE  ·  D-PAD MOVE  ·  SELECT PLACE  ·  BACK CANCEL")
            .font(TVConsoleTheme.mono(15, bold: true))
            .tracking(1.4)
            .foregroundStyle(TVConsoleTheme.label)
            .padding(.horizontal, 27)
            .frame(height: 56)
            .tvConsoleGlass(radius: 28, strong: true)
            .overlay(Capsule().strokeBorder(TVConsoleTheme.face, lineWidth: 2))
    }

    // MARK: Grid

    private func grid(_ model: Model, current: TVConsoleHomeLayout.Item?) -> some View {
        TVConsoleTileGrid(centersSingleTile: model.games.isEmpty) {
            ForEach(model.layout.items) { item in
                let game = item.gameID.flatMap { model.games[$0] }
                let focused = focusedID == item.id
                let isCurrent = current?.id == item.id
                Button {
                    activate(item, model: model)
                } label: {
                    TVConsoleGameTile(
                        game: game,
                        wide: item.wide,
                        store: game.flatMap(primaryStore),
                        highlighted: focused || isCurrent,
                        // Focus is in the dock or a menu: the tile keeps a thinner frame.
                        parked: isCurrent && !focused,
                        running: item.gameID != nil && item.gameID == model.runningID
                    )
                }
                .buttonStyle(TVConsolePlainButtonStyle())
                .focused($focusedID, equals: item.id)
                .disabled(movingID != nil && movingID != item.id)
                .opacity(movingID != nil && movingID != item.id ? 0.58 : 1)
                .zIndex(focused ? 10 : 0)
                .layoutValue(key: TVConsoleTilePlace.self, value: CGPoint(x: item.column * 192, y: item.row * 192))
                .accessibilityLabel(game?.title ?? "Add a game")
            }
        }
        .overlay(alignment: .top) {
            if model.games.isEmpty {
                Text("Pin games from Library to build your own layout")
                    .font(TVConsoleTheme.display(18, weight: 700))
                    .foregroundStyle(TVConsoleTheme.textMuted)
                    .padding(.top, 86)
            }
        }
        // Also when focus comes back up from the dock: return to the tile it left, not the nearest one.
        .defaultFocus($focusedID, current?.id, priority: .userInitiated)
        .focusSection()
        .onPlayPauseCommand {
            if let id = focusedID { openMenu(for: id, model: model) }
        }
        .onMoveCommand { direction in
            move(toward: direction, model: model)
        }
    }

    private func hints(for current: TVConsoleHomeLayout.Item?, model: Model) -> TVConsoleHints {
        if movingID != nil {
            return TVConsoleHints(
                right: [.init(button: .back, label: "Cancel"), .init(button: .select, label: "Place")],
                locksDock: true
            )
        }
        guard let id = current?.gameID else {
            return TVConsoleHints(right: [.init(button: .select, label: "Add a game")])
        }
        return TVConsoleHints(
            left: [.init(button: .y, label: "Search")],
            right: [
                .init(button: .x, label: "Edit tile"),
                .init(button: .select, label: id == model.runningID ? "Jump back in" : "Details"),
            ]
        )
    }

    // MARK: Actions

    private func activate(_ item: TVConsoleHomeLayout.Item, model: Model) {
        if movingID != nil {
            commitMove()
        } else if let id = item.gameID, let game = model.games[id] {
            if id == model.runningID {
                store.jumpBackToSession()
            } else {
                selectedGameForDetails = game
            }
        } else {
            openLibrary()
        }
    }

    private func openMenu(for id: String, model: Model) {
        guard movingID == nil, editingID == nil, model.games[id] != nil else { return }
        editingID = id
    }

    /// Runs `action` once the menu has finished closing; a second presentation started while the
    /// first is still on screen is dropped by the system.
    private func closeMenu(then action: @escaping () -> Void) {
        afterMenu = action
        editingID = nil
    }

    /// Editing a tile that is only shown (recently played, or the running game) makes the shown
    /// list the pinned one, so the edit has something to apply to.
    private func pin(_ id: String, model: Model) {
        if store.settings.favoriteGameIds.isEmpty {
            store.settings.favoriteGameIds = model.shownIDs
        } else if !store.settings.favoriteGameIds.contains(id) {
            store.settings.favoriteGameIds.insert(id, at: 0)
        }
    }

    private func setWide(_ wide: Bool, for id: String, model: Model) {
        pin(id, model: model)
        var ids = model.wideIDs
        if wide { ids.insert(id) } else { ids.remove(id) }
        let sorted = ids.sorted()
        explicitWideIDs = sorted
        UserDefaults.standard.set(sorted, forKey: Self.wideTilesKey)
    }

    private func remove(_ id: String, model: Model) {
        pin(id, model: model)
        store.settings.favoriteGameIds.removeAll { $0 == id }
    }

    private func beginMove(_ id: String, model: Model) {
        pin(id, model: model)
        movePreview = store.settings.favoriteGameIds
        movingID = id
        focusedID = id
    }

    private func move(toward direction: MoveCommandDirection, model: Model) {
        guard let movingID else { return }
        let side: TVConsoleHomeLayout.Direction
        switch direction {
        case .left: side = .left
        case .right: side = .right
        case .up: side = .up
        case .down: side = .down
        @unknown default: return
        }
        guard let target = model.layout.neighbor(of: movingID, toward: side)?.gameID else { return }
        withAnimation(.easeOut(duration: TVConsoleTheme.focusDuration)) {
            movePreview = TVConsoleHomeContent.moving(movingID, onto: target, in: movePreview)
        }
    }

    private func commitMove() {
        store.settings.favoriteGameIds = movePreview
        movingID = nil
    }

    private func cancelMove() {
        withAnimation(.easeOut(duration: TVConsoleTheme.focusDuration)) { movingID = nil }
    }
}

// MARK: - Grid layout

/// Position of a tile's top-left corner inside the grid.
private struct TVConsoleTilePlace: LayoutValueKey {
    static let defaultValue = CGPoint.zero
}

/// Places tiles at the positions `TVConsoleHomeLayout` computed. A layout rather than nested
/// stacks, so a tile keeps its identity (and focus) when it changes row while being moved.
private struct TVConsoleTileGrid: Layout {
    /// The empty Home shows its lone "Add a game" tile in the middle of the grid.
    let centersSingleTile: Bool

    private static let size = CGSize(width: 1520, height: 560)

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let place = centersSingleTile ? CGPoint(x: 672, y: 192) : subview[TVConsoleTilePlace.self]
            subview.place(
                at: CGPoint(x: bounds.minX + place.x, y: bounds.minY + place.y),
                anchor: .topLeading, proposal: .unspecified
            )
        }
    }
}

// MARK: - Tile

/// `GameTile.qml`: artwork, the store mark, and a title that shows on wide or focused tiles.
private struct TVConsoleGameTile: View {
    /// `nil` draws the "Add a game" tile.
    let game: CloudGame?
    let wide: Bool
    let store: String?
    let highlighted: Bool
    let parked: Bool
    let running: Bool

    private var radius: CGFloat { highlighted ? 30 : 26 }
    private var width: CGFloat { wide ? 368 : 176 }

    private var artwork: URL? {
        guard let game else { return nil }
        let raw = wide ? (game.heroImageUrl ?? game.tvBannerUrl ?? game.catalogArtworkUrl)
            : (game.catalogArtworkUrl ?? game.imageUrl ?? game.heroImageUrl)
        return raw.flatMap(URL.init(string:))
    }

    var body: some View {
        Group {
            if let game {
                gameFace(game)
            } else {
                addFace
            }
        }
        .frame(width: width, height: 176)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay {
            if game != nil || highlighted {
                TVConsoleFocusFrame(focused: highlighted, parked: parked, radius: radius)
            }
        }
        .scaleEffect(highlighted && !parked ? 1.04 : 1)
        .animation(.easeOut(duration: 0.09), value: highlighted && !parked)
    }

    private func gameFace(_ game: CloudGame) -> some View {
        let storeKey = store.flatMap(TVConsoleTheme.storeKey)
        let labelVisible = wide || highlighted || artwork == nil
        return ZStack(alignment: .bottomLeading) {
            TVConsoleTheme.storeColor(storeKey)
            if let artwork {
                CachedRemoteImage(url: artwork, targetPixelSize: Int(width) * 2) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                } failure: {
                    Color.clear
                }
                .frame(width: width, height: 176)
                .clipped()
            }
            if labelVisible {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.4), .init(color: .black.opacity(0.82), location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 0) {
                    if wide, let store {
                        Text(gameStoreDisplayName(store).uppercased())
                            .font(TVConsoleTheme.mono(12))
                            .tracking(1.2)
                            .foregroundStyle(Color.white.opacity(0.64))
                    }
                    Text(game.title)
                        .font(TVConsoleTheme.display(wide ? 20 : 17))
                        .foregroundStyle(.white)
                }
                .lineLimit(1)
                .padding(.horizontal, 19)
                .padding(.bottom, 15)
                .padding(.trailing, wide && running ? 150 : 0)
            }
        }
        .overlay(alignment: .topLeading) {
            if let store {
                TVConsoleStoreMark(store: store)
                    .padding(highlighted ? 13 : 11)
            }
        }
        .overlay(alignment: wide ? .bottomTrailing : .topTrailing) {
            if running { jumpBackBadge.padding(wide ? 14 : 11) }
        }
    }

    /// The README-era "Jump back in!" pill; a square tile has room for the play mark only.
    private var jumpBackBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.fill").font(.system(size: 12, weight: .black))
            if wide {
                Text("Jump back in!").font(TVConsoleTheme.display(14))
            }
        }
        .foregroundStyle(TVConsoleTheme.faceText)
        .padding(.horizontal, wide ? 12 : 0)
        .frame(minWidth: 30, minHeight: 30)
        .background(Capsule().fill(TVConsoleTheme.face))
    }

    private var addFace: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(TVConsoleTheme.face.opacity(highlighted ? 0.08 : 0.02))
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(
                    highlighted ? TVConsoleTheme.face : TVConsoleTheme.label.opacity(0.38),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 6])
                )
                .opacity(highlighted ? 0 : 1)
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .frame(width: 30, height: 30)
                Text("Add a game").font(TVConsoleTheme.display(15, weight: 800))
            }
            .foregroundStyle(TVConsoleTheme.label)
        }
    }
}

// MARK: - Background

/// `ScreenBackground.qml`: the focused game's artwork, dimmed and washed towards the shell colour
/// so the tiles and chrome stay readable.
struct TVConsoleBackground: View {
    let artwork: String?
    /// A faint wash that tells the pages apart (`tint` in the Qt screens).
    var tint: UInt32 = 0x15253A

    @Environment(\.openNowAccent) private var accent

    var body: some View {
        let url = artwork.flatMap(URL.init(string:))
        // Overlays, so the aspect-filled artwork (wider than the screen) never sizes the page.
        TVConsoleTheme.shell
            .overlay {
                if let url {
                    CachedRemoteImage(url: url, targetPixelSize: 1280, priority: .utility) { image in
                        image.resizable().scaledToFill().opacity(0.58)
                    } placeholder: {
                        Color.clear
                    } failure: {
                        Color.clear
                    }
                    .id(url)
                    .transition(.opacity)
                }
            }
            .clipped()
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: TVConsoleTheme.shell, location: 0),
                        .init(color: TVConsoleTheme.shell.opacity(0.60), location: 0.48),
                        .init(color: TVConsoleTheme.shell.opacity(0.88), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                Color(hex: tint).opacity(0.12)
                LinearGradient(colors: [accent.color.opacity(0.07), .clear],
                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4))
            }
            .animation(.easeOut(duration: TVConsoleTheme.enterDuration), value: url)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
