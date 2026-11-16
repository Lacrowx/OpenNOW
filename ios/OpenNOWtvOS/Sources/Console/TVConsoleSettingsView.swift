import SwiftUI

struct TVConsoleSettingsSection<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    /// SF Symbol drawn on the coloured square.
    let symbol: String
    let color: Color
    var ink: Color = TVConsoleTheme.faceText
}

/// The console Settings (`opennow-qt/qml/screens/SettingsScreen.qml`): a rail of sections beside a
/// panel with the open section's rows. Focusing a section opens it. The rows are the shared
/// settings pages, drawn as console rows by `Form` (`TVConsoleSettingsForm.swift`); `panel` is
/// the navigation stack that shows them, so sub-pages open inside the panel.
struct TVConsoleSettingsLayout<ID: Hashable, Panel: View>: View {
    let sections: [TVConsoleSettingsSection<ID>]
    @Binding var selection: ID
    /// A sub-page is open in the panel, which pops itself on Back.
    let isPushed: Bool
    @ViewBuilder let panel: Panel

    @FocusState private var railFocus: ID?
    @FocusState private var inRows: Bool

    private static var panelHeight: CGFloat { 792 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVConsoleBackground(artwork: nil, tint: 0x17233B)
            HStack(alignment: .top, spacing: 24) {
                rail
                    .frame(width: 360, height: Self.panelHeight)
                    .tvConsoleGlass(radius: 40)
                    .focusSection()
                    .defaultFocus($railFocus, selection, priority: .userInitiated)
                panel
                    .id(selection)
                    .frame(width: 1344, height: Self.panelHeight)
                    .tvConsoleGlass(radius: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 40))
                    .focusSection()
                    .focused($inRows)
                    // Back from the rows of a section goes to the rail. From the rail the shell
                    // takes it, and from a sub-page the navigation stack pops.
                    .onExitCommand(perform: inRows && !isPushed ? { railFocus = selection } : nil)
            }
            .padding(.leading, 96)
            .padding(.top, 124)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onChange(of: railFocus) { _, focused in
            if let focused { selection = focused }
        }
        .preference(key: TVConsoleHintsKey.self, value: TVConsoleHints(
            left: [.init(button: .back, label: inRows && !isPushed ? "Sections" : "Back")],
            right: [.init(button: .select, label: "Select")],
            // The shell would send Back to the dock instead of the rail.
            handlesBack: inRows && !isPushed
        ))
    }

    private var rail: some View {
        VStack(spacing: 6) {
            ForEach(sections) { section in
                TVConsoleSettingsRailRow(
                    section: section, selected: selection == section.id, focused: railFocus == section.id
                ) { selection = section.id }
                    .focused($railFocus, equals: section.id)
            }
        }
        .padding(23)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A section in the rail: a white pill while it is the open one, a white border while focused.
private struct TVConsoleSettingsRailRow<ID: Hashable>: View {
    let section: TVConsoleSettingsSection<ID>
    let selected: Bool
    let focused: Bool
    let action: () -> Void

    @Environment(\.openNowAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 11)
                    .fill(section.color)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: section.symbol)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(section.ink)
                    }
                Text(section.title)
                    .font(TVConsoleTheme.display(19))
                    .foregroundStyle(selected ? TVConsoleTheme.faceText : TVConsoleTheme.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .frame(height: 58)
            .background(Capsule().fill(selected ? TVConsoleTheme.face : .clear))
            .overlay {
                if focused {
                    if !selected {
                        Capsule().strokeBorder(TVConsoleTheme.face, lineWidth: 3)
                    }
                    Capsule().strokeBorder(accent.color.opacity(0.5), lineWidth: 5).padding(-5)
                }
            }
        }
        .buttonStyle(TVConsolePlainButtonStyle())
    }
}
