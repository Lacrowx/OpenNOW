import SwiftUI

// The settings pages are written as `Form { Section { ... } }` with plain `Toggle`, `Button`,
// `NavigationLink`, `LabeledContent` and `Picker` rows. In the tvOS target `Form` is this console
// list instead (the module's own `Form` shadows SwiftUI's, as `TextEditor` does in TVCompat), so
// those pages take the Qt client's `SettingRow.qml` look without being rewritten.

private struct TVConsoleFormHeadingKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Heading drawn above the rows of a `Form`; `nil` for a form that is not a settings page.
    var tvConsoleFormHeading: String? {
        get { self[TVConsoleFormHeadingKey.self] }
        set { self[TVConsoleFormHeadingKey.self] = newValue }
    }
}

extension View {
    func tvConsoleFormHeading(_ heading: String) -> some View {
        environment(\.tvConsoleFormHeading, heading)
    }
}

struct Form<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.tvConsoleFormHeading) private var heading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let heading {
                Text(heading)
                    .font(TVConsoleTheme.display(32))
                    .tracking(-0.3)
                    .foregroundStyle(TVConsoleTheme.label)
                    .lineLimit(1)
                    .frame(height: 40, alignment: .leading)
                    .padding(.horizontal, 57)
                    .padding(.top, 31)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sections: content) { section in
                        TVConsoleFormSection(section: section)
                    }
                }
                // Room for the focus ring, which reaches 5 pt past a row and would be clipped.
                .padding(.horizontal, 35)
                .padding(.vertical, 10)
            }
            .padding(.top, heading == nil ? 0 : 8)
            // Rows stop short of the panel's rounded bottom edge instead of being cut by it.
            .padding(.bottom, heading == nil ? 0 : 18)
        }
        .buttonStyle(TVConsoleFormButtonStyle())
        .toggleStyle(TVConsoleFormToggleStyle())
        .labeledContentStyle(TVConsoleFormLabeledContentStyle())
    }
}

/// The title of a settings page drawn inline in its section's panel, as the header of an empty
/// `Section` placed before the page's own sections. It sets its own type, so the section header
/// style (small capitals) does not apply.
struct TVConsoleFormPageTitle: View {
    let title: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(TVConsoleTheme.display(26))
                .foregroundStyle(TVConsoleTheme.label)
            Text(summary)
                .font(TVConsoleTheme.display(16, weight: 600))
                .foregroundStyle(TVConsoleTheme.textMuted)
        }
        .textCase(nil)
        .tracking(0)
        .padding(.top, 18)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct TVConsoleFormSection: View {
    let section: SectionConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !section.header.isEmpty {
                section.header
                    .font(TVConsoleTheme.mono(13, bold: true))
                    .tracking(1.3)
                    .textCase(.uppercase)
                    .foregroundStyle(TVConsoleTheme.textMuted)
                    .padding(.horizontal, 25)
                    .padding(.top, 20)
                    .padding(.bottom, 4)
            }
            ForEach(subviews: section.content) { row in
                TVConsoleFormRow(row: row)
            }
            if !section.footer.isEmpty {
                section.footer
                    .font(TVConsoleTheme.display(16, weight: 600))
                    .foregroundStyle(TVConsoleTheme.textMuted)
                    .padding(.horizontal, 25)
                    .padding(.vertical, 8)
            }
        }
    }
}

/// `SettingRow.qml`: a row at least 84 pt tall that lights up while focus is on anything in it.
/// Rows with nothing to focus (information text) draw no chrome.
private struct TVConsoleFormRow: View {
    let row: Subview

    @FocusState private var focused: Bool

    var body: some View {
        row
            .font(TVConsoleTheme.display(21))
            .foregroundStyle(TVConsoleTheme.label)
            .focused($focused)
            .padding(.horizontal, 25)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .modifier(TVConsoleSheetRow(focused: focused, radius: 24))
            .overlay(alignment: .bottom) {
                if !focused {
                    Rectangle().fill(TVConsoleTheme.face.opacity(0.09)).frame(height: 1).padding(.horizontal, 18)
                }
            }
    }
}

/// Buttons and navigation links: the row draws focus, so the button only has to fill it.
struct TVConsoleFormButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(configuration.role == .destructive ? TVConsoleTheme.coral : TVConsoleTheme.label)
            .opacity(configuration.isPressed ? 0.86 : isEnabled ? 1 : 0.45)
    }
}

/// The Qt toggle: a 64x36 capsule, mint when on, with a 28 pt knob.
struct TVConsoleFormToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 24) {
                configuration.label
                Spacer(minLength: 24)
                Capsule()
                    .fill(configuration.isOn ? TVConsoleTheme.mint : TVConsoleTheme.face.opacity(0.18))
                    .frame(width: 64, height: 36)
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(TVConsoleTheme.face)
                            .frame(width: 28, height: 28)
                            .padding(.leading, configuration.isOn ? 32 : 4)
                    }
                    .animation(.easeOut(duration: TVConsoleTheme.focusDuration), value: configuration.isOn)
            }
        }
    }
}

/// Information rows: the title, and the value on the right in muted type.
struct TVConsoleFormLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 24) {
            configuration.label
            Spacer(minLength: 24)
            configuration.content
                .font(TVConsoleTheme.display(18, weight: 800))
                .foregroundStyle(TVConsoleTheme.textMuted)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// `SettingRow.qml` dropdown: the current value on the right; Select opens the choice panel.
/// `Picker` is `TVLabeledPicker` in the settings pages and this is what it draws.
struct TVConsolePickerRow<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    @ViewBuilder let options: Options

    @State private var isChoosing = false

    var body: some View {
        Button {
            isChoosing = true
        } label: {
            HStack(spacing: 24) {
                Text(title)
                Spacer(minLength: 24)
                Group(subviews: options) { choices in
                    if let current = choices.first(where: { $0.containerValues.tag(for: Value.self) == selection }) {
                        current
                            .font(TVConsoleTheme.display(18, weight: 800))
                            .foregroundStyle(TVConsoleTheme.textMuted)
                    }
                }
                .lineLimit(1)
            }
        }
        .fullScreenCover(isPresented: $isChoosing) {
            TVConsoleSelectionSheet(eyebrow: "SETTINGS", title: title, description: "Choose a value",
                                    selection: $selection) { options }
        }
    }
}
