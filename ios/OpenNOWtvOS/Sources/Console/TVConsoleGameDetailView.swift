import SwiftUI

/// The console game details (`opennow-qt/qml/screens/GameDetailScreen.qml`): the game's artwork
/// across the right of the screen, its title and the stores it can be played on at the left, and
/// the actions under them. It takes the place of `GameLaunchDetailsSheet` on tvOS and launches
/// through the same callback.
struct TVConsoleGameDetailView: View {
    let game: CloudGame
    let onLaunch: (GameLaunchOption?) -> Void

    @EnvironmentObject private var store: OpenNOWStore
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case chip(String), allStores, play, pin, more
    }

    private enum Panel: String, Identifiable {
        case stores, more, about
        var id: String { rawValue }
    }

    @FocusState private var focus: Field?
    /// The store the user picked here; until then the saved default or the first one launches.
    @State private var pickedID: String?
    @State private var panel: Panel?

    private var options: [GameLaunchOption] { store.launchOptions(for: game) }
    private var savedDefault: GameLaunchOption? { store.defaultLaunchOption(for: game) }
    private var selected: GameLaunchOption? {
        options.first { $0.id == pickedID } ?? savedDefault ?? options.first
    }
    private var importedGame: CloudGame? {
        store.importedGames.first { catalogStableGameKey($0) == catalogStableGameKey(game) }
    }

    /// Why the game cannot be started, if it cannot.
    private var notice: String? {
        if let restriction = store.launchRestrictionMessage(for: game) { return restriction }
        if !OpenNOWPlatform.supportsEmbeddedStreamer { return OpenNOWPlatform.streamingUnavailableReason }
        return options.isEmpty ? "This game doesn’t expose launch targets yet." : nil
    }

    var body: some View {
        let options = options
        let selected = selected
        let pinned = store.isFavorite(game)
        let pinLabel = pinned ? "Remove from Home" : "Pin to Home"
        let moreChoices = moreChoices(options: options, selected: selected)

        ZStack(alignment: .topLeading) {
            backdrop
            VStack(alignment: .leading, spacing: 0) {
                // The chips start at y 476 unless the copy runs longer.
                heroCopy(options: options).frame(minHeight: 221, alignment: .top)
                VStack(alignment: .leading, spacing: 13) {
                    if !options.isEmpty {
                        Text("PLAY ON")
                            .font(TVConsoleTheme.mono(14))
                            .tracking(1.68)
                            .foregroundStyle(TVConsoleTheme.textMuted)
                        chips(options: options, selected: selected)
                    }
                    if let notice {
                        Text(notice)
                            .font(TVConsoleTheme.display(17, weight: 600))
                            .foregroundStyle(TVConsoleTheme.yellow)
                            .lineLimit(3)
                            .frame(maxWidth: 900, alignment: .leading)
                    }
                    HStack(spacing: 14) {
                        TVConsoleActionButton(title: "Play", glyph: .select, primary: true, pill: true) {
                            onLaunch(selected)
                            dismiss()
                        }
                        .disabled(notice != nil)
                        .focused($focus, equals: .play)
                        TVConsoleActionButton(title: pinLabel, glyph: .x, pill: true) {
                            store.toggleFavorite(game)
                        }
                        .focused($focus, equals: .pin)
                        if !moreChoices.isEmpty {
                            TVConsoleActionButton(title: "More", pill: true, isOpen: panel == .more) {
                                panel = .more
                            }
                            .focused($focus, equals: .more)
                        }
                    }
                    .padding(.top, 34)
                    .focusSection()
                }
                .padding(.top, 56)
            }
            .padding(.leading, 120)
            .padding(.top, 199)

            requestsCard
                .frame(width: 472)
                .padding(.leading, 1352)
                .padding(.top, 470)

            HStack {
                TVConsoleHintRow(hints: [.init(button: .back, label: "Back")])
                Spacer()
                TVConsoleHintRow(hints: [.init(button: .x, label: pinLabel), .init(button: .select, label: "Play")])
            }
            .padding(.horizontal, 64)
            // A cover is offered the title-safe width; the hints sit at the canvas edges.
            .frame(width: 1920)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 81)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .presentationBackground(TVConsoleTheme.shell)
        .defaultFocus($focus, notice == nil ? .play : .pin)
        .onPlayPauseCommand { store.toggleFavorite(game) }
        .fullScreenCover(item: $panel) { panel in
            switch panel {
            case .stores:
                TVConsoleChoiceSheet(
                    eyebrow: "PLAY ON", title: "Choose a store", description: game.title,
                    choices: options.map { option in
                        TVConsoleChoice(id: option.id, label: gameStoreDisplayName(option.storefront),
                                        detail: ownership(of: option), isCurrent: option.id == selected?.id) {
                            pickedID = option.id
                            self.panel = nil
                        }
                    }
                )
            case .more:
                TVConsoleChoiceSheet(eyebrow: "GAME", title: "More", description: game.title, choices: moreChoices)
            case .about:
                TVConsoleGameAboutSheet(game: game, description: fullDescription, facts: aboutFacts(options: options))
            }
        }
    }

    // MARK: Backdrop

    private var backdrop: some View {
        TVConsoleTheme.shell
            .overlay(alignment: .trailing) {
                // The artwork covers the right two thirds and fades into the shell on its left.
                Color.clear
                    .overlay {
                        if let url = (game.heroImageUrl ?? game.detailsArtworkUrl).flatMap(URL.init(string:)) {
                            CachedRemoteImage(url: url, targetPixelSize: 1920) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.clear
                            } failure: {
                                Color.clear
                            }
                        }
                    }
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: TVConsoleTheme.shell, location: 0),
                                .init(color: TVConsoleTheme.shell.opacity(0.55), location: 0.32),
                                .init(color: .clear, location: 0.6),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    }
                    .frame(width: 1267)
                    .clipped()
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, TVConsoleTheme.shell.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 280)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    // MARK: Copy

    private func heroCopy(options: [GameLaunchOption]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let eyebrow = (game.consoleMakers
                + gameMetadataDisplayLabels([game.genre] + (game.tags ?? [])).prefix(2))
                .filter { !$0.isEmpty && $0 != "Cloud Game" }
                .joined(separator: " · ")
            if !eyebrow.isEmpty {
                Text(eyebrow.uppercased())
                    .font(TVConsoleTheme.mono(15))
                    .tracking(1.8)
                    .foregroundStyle(TVConsoleTheme.textMuted)
                    .lineLimit(1)
            }
            Text(game.title)
                .font(TVConsoleTheme.display(88))
                .tracking(-2.64)
                .foregroundStyle(TVConsoleTheme.label)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            if let description = fullDescription {
                Text(description)
                    .font(TVConsoleTheme.display(20, weight: 600))
                    .lineSpacing(2)
                    .foregroundStyle(TVConsoleTheme.textMuted)
                    .lineLimit(2)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.top, 2)
            }
            let facts = facts(options: options)
            if !facts.isEmpty {
                Text(facts.uppercased())
                    .font(TVConsoleTheme.mono(14))
                    .tracking(1.2)
                    .foregroundStyle(TVConsoleTheme.textMuted)
                    .lineLimit(1)
                    .padding(.top, 14)
            }
            let playtime = store.consolePlaytime(of: game)
            if !game.capabilityBadges.isEmpty || playtime != nil {
                HStack(spacing: 18) {
                    if !game.capabilityBadges.isEmpty {
                        TVConsoleFeatureChips(labels: game.capabilityBadges)
                    }
                    if let playtime {
                        Text("You played \(playtime) on this Apple TV")
                            .font(TVConsoleTheme.display(17, weight: 800))
                            .foregroundStyle(TVConsoleTheme.label)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 14)
            }
        }
        .frame(width: 860, alignment: .leading)
    }

    private var fullDescription: String? {
        [game.longDescription, game.summary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Every fact the details know, for the "About this game" panel.
    private func aboutFacts(options: [GameLaunchOption]) -> [(label: String, value: String)] {
        let controls = gameMetadataDisplayLabels(Array(Set(options.flatMap { $0.supportedControls ?? [] })).sorted())
        let rows: [(String, String?)] = [
            ("Publisher", game.publisher),
            ("Developer", game.developer),
            ("Release", game.releaseDate),
            ("Genre", gameMetadataDisplayLabels([game.genre] + (game.tags ?? [])).filter { $0 != "Cloud Game" }
                .joined(separator: ", ")),
            ("Play type", game.playType.map(gameMetadataDisplayLabel)),
            ("Age rating", GFNContentRatingParser.ageBadge(from: game.contentRatings)),
            ("Controls", controls.joined(separator: ", ")),
            ("Features", gameMetadataDisplayLabels(game.featureLabels ?? []).joined(separator: ", ")),
            ("Membership", game.membershipTierLabel.map(gameMetadataDisplayLabel)),
            ("Last played", game.lastPlayedAt?.formatted(date: .abbreviated, time: .omitted)),
            ("On this Apple TV", store.consolePlaytime(of: game)),
        ]
        return rows.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
    }

    /// The shared facts line, plus when the game was last played.
    private func facts(options: [GameLaunchOption]) -> String {
        [TVConsoleGameFacts.factsLine(game, options: options), TVConsoleGameFacts.lastPlayed(game.lastPlayedAt) ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // MARK: Stores

    private func ownership(of option: GameLaunchOption) -> String {
        TVConsolePlayOnChips.ownershipLabel(isOwned: option.isOwned, libraryStatus: option.libraryStatus)
    }

    private func chips(options: [GameLaunchOption], selected: GameLaunchOption?) -> some View {
        let shown = TVConsolePlayOnChips.shown(
            optionCount: options.count, selected: selected.flatMap { selected in options.firstIndex { $0.id == selected.id } }
        )
        return HStack(spacing: 12) {
            ForEach(shown, id: \.self) { index in
                let option = options[index]
                let isSelected = option.id == selected?.id
                Button {
                    pickedID = option.id
                } label: {
                    HStack(spacing: 14) {
                        TVConsoleStoreMark(store: option.storefront, size: 42)
                        VStack(alignment: .leading, spacing: -1) {
                            Text(gameStoreDisplayName(option.storefront))
                                .font(TVConsoleTheme.display(19))
                                .foregroundStyle(TVConsoleTheme.label)
                            Text(ownership(of: option))
                                .font(TVConsoleTheme.display(15, weight: 700))
                                .foregroundStyle(option.isOwned ? TVConsoleTheme.mint : TVConsoleTheme.textMuted)
                        }
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 19, weight: .black))
                                .foregroundStyle(TVConsoleTheme.mint)
                        }
                    }
                    .lineLimit(1)
                    .padding(.leading, 14)
                    .padding(.trailing, 24)
                    .frame(height: 72)
                    .background(RoundedRectangle(cornerRadius: 24)
                        .fill(isSelected ? TVConsoleTheme.face.opacity(0.16) : TVConsoleTheme.shell.opacity(0.7)))
                    .overlay(TVConsoleFocusFrame(focused: focus == .chip(option.id), radius: 24))
                }
                .buttonStyle(TVConsolePlainButtonStyle())
                .focused($focus, equals: .chip(option.id))
                .accessibilityLabel("\(gameStoreDisplayName(option.storefront)), \(ownership(of: option))")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            if !TVConsolePlayOnChips.isInline(optionCount: options.count) {
                Button {
                    panel = .stores
                } label: {
                    Text("All \(options.count) stores ›")
                        .font(TVConsoleTheme.display(19))
                        .foregroundStyle(TVConsoleTheme.label)
                        .padding(.horizontal, 24)
                        .frame(height: 72)
                        .background(RoundedRectangle(cornerRadius: 24).fill(TVConsoleTheme.shell.opacity(0.7)))
                        .overlay(TVConsoleFocusFrame(
                            focused: focus == .allStores || panel == .stores, parked: panel == .stores, radius: 24
                        ))
                }
                .buttonStyle(TVConsolePlainButtonStyle())
                .focused($focus, equals: .allStores)
            }
        }
        .focusSection()
    }

    // MARK: More

    private func moreChoices(options: [GameLaunchOption], selected: GameLaunchOption?) -> [TVConsoleChoice] {
        var choices = [TVConsoleChoice(
            id: "about", label: "About this game", detail: "Full description and every detail",
            action: { panel = .about }
        )]
        if options.count > 1, let selected {
            let name = gameStoreDisplayName(selected.storefront)
            let isDefault = selected.id == savedDefault?.id
            choices.append(TVConsoleChoice(
                id: "default",
                label: isDefault ? "Stop always using \(name)" : "Always use \(name)",
                detail: isDefault ? "The first store is used again" : "Starts this game on \(name) without asking",
                action: {
                    store.setDefaultGameVariant(game: game, option: isDefault ? nil : selected)
                    panel = nil
                }
            ))
        }
        if let importedGame {
            choices.append(TVConsoleChoice(
                id: "remove", label: "Remove from added games",
                detail: "Does not change ownership or end a session",
                action: {
                    panel = nil
                    store.removeImportedGame(importedGame)
                    dismiss()
                }
            ))
        }
        return choices
    }

    // MARK: Launch requests

    /// What the next launch will ask the rig for (`requestsCard` in the Qt screen).
    private var requestsCard: some View {
        let settings = store.settings
        let profile = StreamSettingsResolver.profile(
            for: settings, membershipTier: store.subscription?.membershipTier ?? store.user?.membershipTier
        )
        let picture = (profile.height >= 2160 ? "4K" : "\(profile.height)p") + " · \(profile.fps) FPS"
        let codec = settings.preferredCodec.uppercased() + (settings.hdrEnabled ? " · HDR" : "")
        return VStack(alignment: .leading, spacing: 16) {
            Text("NEXT LAUNCH REQUESTS")
                .font(TVConsoleTheme.mono(13))
                .tracking(1.56)
                .foregroundStyle(TVConsoleTheme.textMuted)
            VStack(spacing: 10) {
                requestRow("Picture", picture)
                requestRow("Codec", codec)
                requestRow("Region", store.consoleRegionName ?? "Automatic region", dot: true)
            }
            Text("The rig decides the final stream. Change these in Settings.")
                .font(TVConsoleTheme.display(15, weight: 600))
                .foregroundStyle(TVConsoleTheme.textMuted)
        }
        .padding(29)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvConsoleGlass(radius: 32, strong: true)
        .accessibilityElement(children: .combine)
    }

    private func requestRow(_ label: String, _ value: String, dot: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(TVConsoleTheme.display(19, weight: 700))
                .foregroundStyle(TVConsoleTheme.textMuted)
            Spacer(minLength: 12)
            if dot { Circle().fill(TVConsoleTheme.mint).frame(width: 9, height: 9) }
            Text(value)
                .font(TVConsoleTheme.display(19, weight: 800))
                .foregroundStyle(TVConsoleTheme.label)
        }
        .lineLimit(1)
    }
}

extension CloudGame {
    /// Publisher, and the developer too when it is a different studio.
    var consoleMakers: [String] {
        let publisher = publisher?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let developer = developer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if publisher.isEmpty { return developer.isEmpty ? [] : [developer] }
        return developer.isEmpty || developer.caseInsensitiveCompare(publisher) == .orderedSame
            ? [publisher] : [publisher, developer]
    }
}

/// "About this game": the full description and every fact, in a right-edge panel. Each block can
/// take focus, so a description longer than the panel scrolls with the remote.
private struct TVConsoleGameAboutSheet: View {
    let game: CloudGame
    let description: String?
    let facts: [(label: String, value: String)]

    @FocusState private var focused: Int?

    private var paragraphs: [String] {
        (description ?? "No description available.")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        TVConsoleSheetPanel(eyebrow: "GAME", title: "About this game", description: game.title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        Text(paragraph)
                            .font(TVConsoleTheme.display(19, weight: 600))
                            .lineSpacing(3)
                            .foregroundStyle(TVConsoleTheme.label)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .modifier(TVConsoleSheetRow(focused: focused == index))
                            .focusable()
                            .focused($focused, equals: index)
                    }
                    VStack(spacing: 10) {
                        ForEach(facts, id: \.label) { fact in
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(fact.label)
                                    .font(TVConsoleTheme.display(17, weight: 700))
                                    .foregroundStyle(TVConsoleTheme.textMuted)
                                    .frame(width: 170, alignment: .leading)
                                Text(fact.value)
                                    .font(TVConsoleTheme.display(17, weight: 800))
                                    .foregroundStyle(TVConsoleTheme.label)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(14)
                    .modifier(TVConsoleSheetRow(focused: focused == -1))
                    .focusable()
                    .focused($focused, equals: -1)
                    .padding(.top, 10)
                }
                .padding(6)
            }
            .padding(.top, 22)
        }
        .defaultFocus($focused, 0)
    }
}
