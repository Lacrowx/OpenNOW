import SwiftUI
import UIKit

/// What can hold focus on a catalog page (Library, Store).
enum TVConsoleCatalogFocus: Hashable {
    case search, filter
    case game(String)

    var gameID: String? {
        if case let .game(id) = self { return id }
        return nil
    }
}

// MARK: - Store marks

/// `ConsoleStoreMark.qml`: the store's logo on a disc of its colour.
struct TVConsoleStoreMark: View {
    let store: String
    var size: CGFloat = 30

    var body: some View {
        let key = TVConsoleTheme.storeKey(store)
        Circle()
            .fill(TVConsoleTheme.storeColor(key))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .overlay {
                if let key, TVConsoleTheme.storeIconKeys.contains(key) {
                    Image("Console/store-\(key)").resizable().scaledToFit()
                        .frame(width: (size * 0.56).rounded(), height: (size * 0.56).rounded())
                } else {
                    Text(gameStoreDisplayName(store).prefix(1).uppercased())
                        .font(TVConsoleTheme.display((size * 0.42).rounded()))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// `ConsoleStoreChip.qml`: a store's mark and name in a pill.
struct TVConsoleStoreChip: View {
    let store: String
    var markSize: CGFloat = 30
    var inset: CGFloat = 5

    var body: some View {
        HStack(spacing: 10) {
            TVConsoleStoreMark(store: store, size: markSize)
            Text(gameStoreDisplayName(store))
                .font(TVConsoleTheme.display(16, weight: 800))
                .foregroundStyle(TVConsoleTheme.label)
        }
        .padding(.leading, inset)
        .padding(.trailing, 16)
        .frame(height: markSize + inset * 2)
        .background(Capsule().fill(TVConsoleTheme.face.opacity(0.07)))
        .overlay(Capsule().strokeBorder(TVConsoleTheme.seam, lineWidth: 1))
    }
}

extension CloudGame {
    /// The stores a game can be launched from, one per store the console shell knows a mark for.
    var consoleStores: [String] {
        var seen = Set<String>()
        return gameResolvedStores(game: self).filter { store in
            seen.insert(TVConsoleTheme.storeKey(store) ?? normalizeGameStore(store)).inserted
        }
    }
}

// MARK: - Poster

/// `PosterTile.qml`: a portrait cover with optional store marks and a star when pinned to Home.
struct TVConsolePoster: View {
    static let size = CGSize(width: 156, height: 234)

    let game: CloudGame
    /// Marks drawn along the bottom edge; empty to leave the cover clean.
    var stores: [String] = []
    let pinned: Bool
    let highlighted: Bool
    let parked: Bool

    private var artwork: URL? {
        (game.catalogArtworkUrl ?? game.imageUrl).flatMap(URL.init(string:))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TVConsoleTheme.storeColor(stores.first.flatMap(TVConsoleTheme.storeKey))
            if let artwork {
                CachedRemoteImage(url: artwork, targetPixelSize: Int(Self.size.height) * 2) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                } failure: {
                    Color.clear
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .clipped()
            }
            if artwork == nil || !stores.isEmpty {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.6), .init(color: .black.opacity(0.82), location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            VStack(alignment: .leading, spacing: 8) {
                if artwork == nil {
                    Text(game.title)
                        .font(TVConsoleTheme.display(15))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(.horizontal, 4)
                }
                if !stores.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(stores.prefix(4), id: \.self) { TVConsoleStoreMark(store: $0, size: 24) }
                    }
                    .padding(4)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                }
            }
            .padding(8)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(alignment: .topTrailing) {
            if pinned {
                Image(systemName: "star.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(TVConsoleTheme.faceText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(TVConsoleTheme.yellow))
                    .padding(10)
                    .accessibilityLabel("Pinned to Home")
            }
        }
        .overlay(TVConsoleFocusFrame(focused: highlighted, parked: parked, radius: 22))
        .scaleEffect(highlighted && !parked ? 1.04 : 1)
        .animation(.easeOut(duration: 0.09), value: highlighted && !parked)
    }
}

/// The scrolling cover grid of a catalog page.
struct TVConsolePosterGrid: View {
    let games: [CloudGame]
    let columns: Int
    /// Pitch of the grid; the cover sits in the cell's top-left corner.
    let cell: CGSize
    /// Room around the grid for the focused cover's frame, which draws outside its cell.
    let inset: CGPoint
    var showsStores = false
    let pinnedIDs: Set<String>
    let currentID: String?
    let focus: FocusState<TVConsoleCatalogFocus?>.Binding
    let onOpen: (CloudGame) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(cell.width), spacing: 0, alignment: .topLeading), count: columns),
                alignment: .leading, spacing: 0
            ) {
                ForEach(games) { game in
                    let focused = focus.wrappedValue == .game(game.id)
                    let isCurrent = currentID == game.id
                    Button {
                        onOpen(game)
                    } label: {
                        TVConsolePoster(
                            game: game,
                            stores: showsStores ? game.consoleStores : [],
                            pinned: pinnedIDs.contains(game.id),
                            highlighted: focused || isCurrent,
                            parked: isCurrent && !focused
                        )
                    }
                    .buttonStyle(TVConsolePlainButtonStyle())
                    .focused(focus, equals: .game(game.id))
                    .frame(width: cell.width, height: cell.height, alignment: .topLeading)
                    .zIndex(focused ? 20 : 0)
                    .accessibilityLabel(game.title)
                }
            }
            .padding(.leading, inset.x)
            .padding(.top, inset.y)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The container clips; inside it a focused cover may overlap its neighbours' cells.
        .scrollClipDisabled()
        .focusSection()
        // Focus coming from the dock or the search row returns to the cover it left.
        .defaultFocus(focus, currentID.map { .game($0) }, priority: .userInitiated)
    }
}

/// Centre message of an empty grid, with an optional action.
struct TVConsoleCatalogNotice: View {
    let title: String
    var detail = ""
    var actionTitle: String?
    var action: () -> Void = {}

    @FocusState private var focused: Bool
    @Environment(\.openNowAccent) private var accent

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(TVConsoleTheme.display(30))
                .foregroundStyle(TVConsoleTheme.label)
            if !detail.isEmpty {
                Text(detail)
                    .font(TVConsoleTheme.display(18, weight: 600))
                    .foregroundStyle(TVConsoleTheme.textMuted)
            }
            if let actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(TVConsoleTheme.display(18))
                        .foregroundStyle(TVConsoleTheme.faceText)
                        .padding(.horizontal, 28)
                        .frame(height: 56)
                        .background(Capsule().fill(TVConsoleTheme.face))
                        .overlay {
                            if focused { Capsule().strokeBorder(accent.color, lineWidth: 5).padding(-6) }
                        }
                }
                .buttonStyle(TVConsolePlainButtonStyle())
                .focused($focused)
                .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 800)
    }
}

// MARK: - Search and filter row

/// The row above a catalog grid (`LibraryScreen.qml`): search field, "Filter & sort", game count.
struct TVConsoleCatalogBar: View {
    @Binding var query: String
    let prompt: String
    let filterSummary: String
    let countLabel: String
    let filterOpen: Bool
    let focus: FocusState<TVConsoleCatalogFocus?>.Binding
    let onFilter: () -> Void

    @State private var keyboardPresented = false

    private static let fill = TVConsoleTheme.shell.opacity(0.62)

    var body: some View {
        HStack(spacing: 14) {
            searchField
            filterButton
            Spacer(minLength: 24)
            Text(countLabel.uppercased())
                .font(TVConsoleTheme.mono(15, bold: true))
                .tracking(1.4)
                .foregroundStyle(TVConsoleTheme.textMuted)
                .lineLimit(1)
        }
        .frame(height: 60)
        .padding(.horizontal, 96)
        .focusSection()
    }

    /// Select opens the tvOS keyboard, which also takes dictation and typing from an iPhone.
    private var searchField: some View {
        Button {
            keyboardPresented = true
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 30).fill(Self.fill)
                TVConsoleGlyph(button: .options).padding(.leading, 15)
                Image("Console/icon-search").resizable().scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(TVConsoleTheme.label)
                    .padding(.leading, 76)
                Text(query.isEmpty ? prompt : query)
                    .font(TVConsoleTheme.display(18, weight: 700))
                    .foregroundStyle(query.isEmpty ? TVConsoleTheme.textMuted : TVConsoleTheme.label)
                    .lineLimit(1)
                    .padding(.leading, 110)
                    .padding(.trailing, 24)
            }
            .frame(width: 440, height: 60)
            .overlay(TVConsoleFocusFrame(focused: focus.wrappedValue == .search, radius: 30))
        }
        .buttonStyle(TVConsolePlainButtonStyle())
        .focused(focus, equals: .search)
        .background(TVConsoleKeyboard(text: $query, prompt: prompt, isPresented: $keyboardPresented))
        .accessibilityLabel(query.isEmpty ? prompt : "Search: \(query)")
    }

    private var filterButton: some View {
        Button(action: onFilter) {
            HStack(spacing: 12) {
                Image("Console/icon-sliders").resizable().scaledToFit().frame(width: 22, height: 22)
                Text("Filter & sort").font(TVConsoleTheme.display(18))
                Rectangle().fill(TVConsoleTheme.seam).frame(width: 1, height: 24)
                Text(filterSummary)
                    .font(TVConsoleTheme.display(17, weight: 700))
                    .foregroundStyle(TVConsoleTheme.textMuted)
                    .frame(maxWidth: 360, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(TVConsoleTheme.label)
            .lineLimit(1)
            .padding(.leading, 15)
            .padding(.trailing, 25)
            .frame(height: 60)
            .background(RoundedRectangle(cornerRadius: 30).fill(Self.fill))
            .overlay(TVConsoleFocusFrame(
                focused: focus.wrappedValue == .filter || filterOpen, parked: filterOpen, radius: 30
            ))
        }
        .buttonStyle(TVConsolePlainButtonStyle())
        .focused(focus, equals: .filter)
        .accessibilityLabel("Filter and sort: \(filterSummary)")
    }
}

// MARK: - Filter panel

/// `ConsoleFilterSheet.qml`: sections on the left, the focused section's options on the right.
/// Choices apply at once, so the grid behind the panel updates as the user goes.
struct TVConsoleFilterSheet: View {
    let eyebrow: String
    let sections: [TVConsoleFilterSection]
    let onChoose: (TVConsoleFilterSection.Kind, Int) -> Void
    let onReset: () -> Void

    private enum Field: Hashable {
        case section(TVConsoleFilterSection.Kind)
        case option(Int)
        case reset
    }

    @FocusState private var field: Field?
    /// The Qt panel opens on Store, the filter reached for most.
    @State private var active = TVConsoleFilterSection.Kind.store

    private var activeSection: TVConsoleFilterSection? { sections.first { $0.kind == active } }

    var body: some View {
        TVConsoleSheetPanel(eyebrow: eyebrow, title: "Filter & sort",
                            description: "The grid updates behind the panel as you choose.") {
            HStack(alignment: .top, spacing: 0) {
                sectionList.frame(width: 220)
                Rectangle().fill(TVConsoleTheme.seam).frame(width: 1).padding(.horizontal, 17)
                optionList
            }
            .padding(.top, 27)
            .frame(maxHeight: .infinity, alignment: .top)

            Rectangle().fill(TVConsoleTheme.seam).frame(height: 1)
            TVConsoleHintRow(hints: [
                .init(button: .select, label: "Choose"),
                .init(button: .back, label: "Done"),
                .init(button: .x, label: "Reset all"),
            ])
            .padding(.top, 21)
        }
        .onChange(of: field) { _, newValue in
            if case let .section(kind) = newValue { active = kind }
        }
        .onPlayPauseCommand(perform: onReset)
    }

    private var sectionList: some View {
        VStack(spacing: 6) {
            ForEach(sections) { section in
                Button {
                    field = .option(section.selection)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.title)
                            .font(TVConsoleTheme.display(19, weight: section.kind == active ? 900 : 700))
                            .foregroundStyle(TVConsoleTheme.label)
                        Text(section.value)
                            .font(TVConsoleTheme.display(15, weight: 600))
                            .foregroundStyle(TVConsoleTheme.textMuted)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 73, alignment: .leading)
                    .modifier(TVConsoleSheetRow(focused: field == .section(section.kind), marked: section.kind == active))
                }
                .buttonStyle(TVConsolePlainButtonStyle())
                .focused($field, equals: .section(section.kind))
            }
            Button(action: onReset) {
                Text("Reset all")
                    .font(TVConsoleTheme.display(17, weight: 800))
                    .foregroundStyle(TVConsoleTheme.textMuted)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .modifier(TVConsoleSheetRow(focused: field == .reset))
            }
            .buttonStyle(TVConsolePlainButtonStyle())
            .focused($field, equals: .reset)
            .padding(.top, 6)
        }
        .focusSection()
        // Coming back from the options, return to their section, not to the row level with them.
        .defaultFocus($field, .section(active), priority: .userInitiated)
    }

    private var optionList: some View {
        ScrollView {
            VStack(spacing: 6) {
                if let section = activeSection {
                    ForEach(Array(section.options.enumerated()), id: \.offset) { index, label in
                        let current = index == section.selection
                        Button {
                            onChoose(section.kind, index)
                        } label: {
                            HStack(spacing: 0) {
                                TVConsoleSheetOptionLabel(label: label, current: current, focused: field == .option(index))
                                if current {
                                    Text("CURRENT")
                                        .font(TVConsoleTheme.mono(13, bold: true))
                                        .tracking(1.3)
                                        .foregroundStyle(TVConsoleTheme.mint)
                                        .padding(.trailing, 20)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .modifier(TVConsoleSheetRow(focused: field == .option(index)))
                        }
                        .buttonStyle(TVConsolePlainButtonStyle())
                        .focused($field, equals: .option(index))
                    }
                }
            }
            .padding(6)
        }
        .scrollClipDisabled()
        .focusSection()
        .defaultFocus($field, .option(activeSection?.selection ?? 0), priority: .userInitiated)
    }
}

/// The tvOS full-screen keyboard for one line of text, opened from a control of the shell's own.
///
/// A SwiftUI `TextField` draws a platter on tvOS that cannot be removed, so the search pill is a
/// button and this invisible UIKit field only owns the keyboard. It is never focused itself, and
/// it hands the text over when the keyboard closes: one search per entry rather than per key.
private struct TVConsoleKeyboard: UIViewRepresentable {
    @Binding var text: String
    let prompt: String
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.alpha = 0
        field.autocorrectionType = .no
        field.returnKeyType = .search
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.placeholder = prompt
        guard isPresented, !field.isFirstResponder else { return }
        field.text = text
        // Presenting during a view update is refused; wait for the update to finish.
        DispatchQueue.main.async { field.becomeFirstResponder() }
    }

    final class Field: UITextField {
        override var canBecomeFocused: Bool { false }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TVConsoleKeyboard

        init(_ parent: TVConsoleKeyboard) { self.parent = parent }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.text = textField.text ?? ""
            parent.isPresented = false
        }
    }
}
