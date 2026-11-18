import SwiftUI

/// Pages of the console shell, in dock order (`NavPill.qml`). The Qt client's Friends and
/// Computer mode have no tvOS equivalent; Sessions takes their place.
enum TVConsoleRoute: String, CaseIterable, Identifiable, Hashable {
    case home, library, store, sessions, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .store: return "Store"
        case .sessions: return "Sessions"
        case .settings: return "Settings"
        }
    }

    /// Centre title of the top bar.
    var title: String { self == .home ? "My games" : label }

    var icon: String { "Console/nav-\(rawValue)" }
}

/// What a page asks of the shell's lower chrome: the button hints beside the dock, and whether
/// the dock is out of reach (while a tile is being moved, focus must stay on it).
struct TVConsoleHints: Equatable {
    var left: [TVConsoleHint] = []
    var right: [TVConsoleHint] = []
    var locksDock = false
    /// The page takes Back itself, so the shell must not send focus to the dock.
    var handlesBack = false
}

struct TVConsoleHintsKey: PreferenceKey {
    static let defaultValue = TVConsoleHints()

    static func reduce(value: inout TVConsoleHints, nextValue: () -> TVConsoleHints) {
        let next = nextValue()
        if next != defaultValue { value = next }
    }
}

extension OpenNOWStore {
    /// The region the user picked or the running session's zone; `nil` while GeForce NOW chooses.
    var consoleRegionName: String? {
        if let picked = availableRegions.first(where: { $0.url == settings.preferredRegion }) {
            return picked.name
        }
        guard let zone = activeSession?.zone, !zone.isEmpty else { return nil }
        return zone
    }
}

// MARK: - Top bar

/// `AppChrome.qml`, upper half: profile pill, page title, status pill.
struct TVConsoleTopBar: View {
    let title: String

    @EnvironmentObject private var store: OpenNOWStore
    @EnvironmentObject private var input: TVConsoleInput

    var body: some View {
        HStack(spacing: 40) {
            profilePill
            Text(title)
                .font(TVConsoleTheme.display(22))
                .tracking(0.22)
                .foregroundStyle(TVConsoleTheme.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            statusPill
        }
        .frame(height: 60)
        .padding(.horizontal, 64)
        .padding(.top, 36)
    }

    private var displayName: String { store.user?.displayName ?? "Guest" }

    private var membershipTier: String {
        (store.subscription?.membershipTier ?? store.user?.membershipTier ?? "").uppercased()
    }

    private var profilePill: some View {
        HStack(spacing: 12) {
            Text(displayName.prefix(1).uppercased())
                .font(TVConsoleTheme.display(18))
                .foregroundStyle(TVConsoleTheme.faceText)
                .frame(width: 42, height: 42)
                .background(Circle().fill(TVConsoleTheme.violet))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 2))
            Text(displayName)
                .font(TVConsoleTheme.display(19, weight: 800))
                .foregroundStyle(TVConsoleTheme.label)
                .lineLimit(1)
            if !membershipTier.isEmpty {
                Text(membershipTier)
                    .font(TVConsoleTheme.mono(13))
                    .tracking(1.04)
                    .foregroundStyle(TVConsoleTheme.violet)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(TVConsoleTheme.violet.opacity(0.18)))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 22)
        .frame(height: 60)
        .tvConsoleGlass(radius: 30, strong: true)
        .accessibilityElement(children: .combine)
    }

    private var statusPill: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.consoleRegionName == nil ? TVConsoleTheme.textMuted : TVConsoleTheme.mint)
                    .frame(width: 9, height: 9)
                Text(store.consoleRegionName ?? "Automatic region")
            }
            if let playtime = TVConsoleGameFacts.playtimeLeft(store.subscription) {
                seam
                Text(playtime.text)
                    .foregroundStyle(playtime.isLow ? TVConsoleTheme.coral : TVConsoleTheme.label)
                    .accessibilityLabel("Playtime this month: \(playtime.text)")
            }
            seam
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened))
            }
            if let battery = input.batteryPercent {
                seam
                HStack(spacing: 8) {
                    batteryIcon(percent: battery)
                    Text("\(battery)%")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Controller battery \(battery)%")
            }
        }
        .font(TVConsoleTheme.mono(15))
        .foregroundStyle(TVConsoleTheme.label)
        .lineLimit(1)
        .padding(.horizontal, 25)
        .frame(height: 60)
        .tvConsoleGlass(radius: 30, strong: true)
    }

    private var seam: some View {
        Rectangle().fill(TVConsoleTheme.seam).frame(width: 1, height: 22)
    }

    private func batteryIcon(percent: Int) -> some View {
        HStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(TVConsoleTheme.label, lineWidth: 2)
                .frame(width: 21, height: 14)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(percent <= 15 ? TVConsoleTheme.coral : TVConsoleTheme.mint)
                        .frame(width: max(2, 15 * CGFloat(min(percent, 100)) / 100), height: 8)
                        .padding(.leading, 3)
                }
            RoundedRectangle(cornerRadius: 1).fill(TVConsoleTheme.label).frame(width: 2, height: 6)
        }
    }
}

// MARK: - Hints

/// `ControllerGlyph.qml` rows as `AppChrome.qml` lays them out beside the dock.
struct TVConsoleHintRow: View {
    let hints: [TVConsoleHint]

    @EnvironmentObject private var input: TVConsoleInput

    var body: some View {
        HStack(spacing: 22) {
            // A hint for a button the device lacks (Y on the Siri Remote) is left out whole.
            ForEach(hints.filter { input.symbols[$0.button] != nil }) { hint in
                HStack(spacing: 10) {
                    TVConsoleGlyph(button: hint.button)
                    Text(hint.label)
                        .font(TVConsoleTheme.display(17, weight: 800))
                        .foregroundStyle(TVConsoleTheme.label)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Dock

/// `NavPill.qml`: the page switcher. The current page is a white pill with its name; the others
/// are icons. Shoulder-button glyphs frame it when a controller is connected.
struct TVConsoleDock: View {
    @Binding var route: TVConsoleRoute
    let focus: FocusState<TVConsoleRoute?>.Binding

    @Environment(\.openNowAccent) private var accent
    @ObservedObject private var releases = TVReleaseChecker.shared

    var body: some View {
        HStack(spacing: 4) {
            TVConsoleGlyph(button: .previousPage).padding(.trailing, 8)
            ForEach(TVConsoleRoute.allCases) { item in
                Button {
                    route = item
                } label: {
                    label(for: item)
                }
                .buttonStyle(TVConsolePlainButtonStyle())
                .focused(focus, equals: item)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(route == item ? .isSelected : [])
            }
            TVConsoleGlyph(button: .nextPage).padding(.leading, 8)
        }
        .padding(.horizontal, 15)
        .frame(height: 72)
        .tvConsoleGlass(radius: 36, strong: true)
        // Focus arriving from the page lands on the page it came from.
        .defaultFocus(focus, route, priority: .userInitiated)
    }

    private func label(for item: TVConsoleRoute) -> some View {
        let current = route == item
        let ink = current ? TVConsoleTheme.faceText : TVConsoleTheme.label
        return HStack(spacing: 10) {
            Image(item.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .frame(width: 30, height: 30)
                .overlay(alignment: .topTrailing) {
                    // A newer release is out: Settings → About says how to update.
                    if item == .settings, releases.available != nil {
                        Circle().fill(TVConsoleTheme.mint)
                            .overlay(Circle().strokeBorder(TVConsoleTheme.shell, lineWidth: 2))
                            .frame(width: 12, height: 12)
                            .offset(x: 4, y: -3)
                    }
                }
            if current {
                Text(item.label).font(TVConsoleTheme.display(17))
            }
        }
        .foregroundStyle(ink)
        .padding(.leading, current ? 14 : 0)
        .padding(.trailing, current ? 20 : 0)
        .frame(minWidth: 64)
        .frame(height: 52)
        .background(Capsule().fill(current ? TVConsoleTheme.face : .clear))
        .overlay {
            if focus.wrappedValue == item {
                Capsule().strokeBorder(accent.color, lineWidth: 3)
            }
        }
        .animation(.easeOut(duration: TVConsoleTheme.focusDuration), value: current)
    }
}
