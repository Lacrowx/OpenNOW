import SwiftUI

/// `ConsoleSheetFrame.qml`: a panel on the right edge over a dimmed screen, with a heading.
/// Present it with `fullScreenCover`; Back closes it.
struct TVConsoleSheetPanel<Content: View>: View {
    let eyebrow: String
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .trailing) {
            TVConsoleTheme.scrim
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(eyebrow)
                        .font(TVConsoleTheme.mono(14, bold: true))
                        .tracking(1.4)
                        .foregroundStyle(TVConsoleTheme.textMuted)
                    Text(title)
                        .font(TVConsoleTheme.display(40))
                        .foregroundStyle(TVConsoleTheme.label)
                    Text(description)
                        .font(TVConsoleTheme.display(18, weight: 600))
                        .foregroundStyle(TVConsoleTheme.textMuted)
                }
                .lineLimit(1)
                content
            }
            .padding(.leading, 65)
            .padding(.trailing, 72)
            .padding(.top, 72)
            .padding(.bottom, 56)
            .frame(width: 760)
            .frame(maxHeight: .infinity, alignment: .top)
            .background {
                let shape = UnevenRoundedRectangle(topLeadingRadius: 40, bottomLeadingRadius: 40)
                shape.fill(TVConsoleTheme.sheet).overlay(shape.strokeBorder(TVConsoleTheme.seam, lineWidth: 1))
            }
        }
        .ignoresSafeArea()
        .presentationBackground(.clear)
    }
}

/// Background of a row in a sheet list: lit with the focus frame when focused, faint when it is
/// the open section of a two-pane sheet.
struct TVConsoleSheetRow: ViewModifier {
    let focused: Bool
    var marked = false
    var radius: CGFloat = 20

    @Environment(\.openNowAccent) private var accent

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius)
                .fill(TVConsoleTheme.face.opacity(focused ? 0.12 : marked ? 0.08 : 0)))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: radius).strokeBorder(TVConsoleTheme.face, lineWidth: 3)
                    RoundedRectangle(cornerRadius: radius + 5).strokeBorder(accent.color.opacity(0.4), lineWidth: 5).padding(-5)
                }
            }
    }
}

/// The label of an option row: a check when it is the one in effect, then the text.
struct TVConsoleSheetOptionLabel<Label: View>: View {
    let label: Label
    var detail = ""
    let current: Bool
    let focused: Bool

    init(detail: String = "", current: Bool, focused: Bool, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.detail = detail
        self.current = current
        self.focused = focused
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(TVConsoleTheme.mint)
                .opacity(current ? 1 : 0)
                .frame(width: 24)
                .padding(.leading, 23)
                .padding(.trailing, 14)
            VStack(alignment: .leading, spacing: 3) {
                label
                    .font(TVConsoleTheme.display(20, weight: current || focused ? 900 : 700))
                    .foregroundStyle(TVConsoleTheme.label)
                if !detail.isEmpty {
                    Text(detail)
                        .font(TVConsoleTheme.display(15, weight: 600))
                        .foregroundStyle(TVConsoleTheme.textMuted)
                }
            }
            Spacer(minLength: 12)
        }
        .lineLimit(1)
    }
}

extension TVConsoleSheetOptionLabel where Label == Text {
    init(label: String, detail: String = "", current: Bool, focused: Bool) {
        self.init(detail: detail, current: current, focused: focused) { Text(label) }
    }
}

/// One row of a console choice sheet.
struct TVConsoleChoice: Identifiable {
    let id: String
    let label: String
    var detail = ""
    /// Marks the option in effect with a check.
    var isCurrent = false
    let action: () -> Void
}

/// `ConsoleChoiceSheet.qml`: a sheet panel with a single list of choices.
struct TVConsoleChoiceSheet: View {
    let eyebrow: String
    let title: String
    let description: String
    let choices: [TVConsoleChoice]

    @FocusState private var focusedID: String?

    var body: some View {
        TVConsoleSheetPanel(eyebrow: eyebrow, title: title, description: description) {
            // A list such as the sign-in providers can be longer than the screen.
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(choices) { choice in
                        let focused = focusedID == choice.id
                        Button(action: choice.action) {
                            TVConsoleSheetOptionLabel(label: choice.label, detail: choice.detail,
                                                      current: choice.isCurrent, focused: focused)
                                .padding(.vertical, 12)
                                .frame(minHeight: 56)
                                .modifier(TVConsoleSheetRow(focused: focused))
                        }
                        .buttonStyle(TVConsolePlainButtonStyle())
                        .focused($focusedID, equals: choice.id)
                    }
                }
                // Room for the focus ring, which the scroll view would otherwise clip.
                .padding(6)
            }
            .padding(.top, 22)
        }
        .defaultFocus($focusedID, choices.first?.id)
    }
}

/// A choice sheet over a `Picker`'s own options: views tagged with the value they select. The
/// option labels are views, so they cannot become `TVConsoleChoice` strings.
struct TVConsoleSelectionSheet<Value: Hashable, Options: View>: View {
    let eyebrow: String
    let title: String
    let description: String
    @Binding var selection: Value
    @ViewBuilder let options: Options

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Value?

    var body: some View {
        TVConsoleSheetPanel(eyebrow: eyebrow, title: title, description: description) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(subviews: options) { option in
                        if let value = option.containerValues.tag(for: Value.self) {
                            let isFocused = focused == value
                            Button {
                                selection = value
                                dismiss()
                            } label: {
                                TVConsoleSheetOptionLabel(current: value == selection, focused: isFocused) { option }
                                    .padding(.vertical, 12)
                                    .frame(minHeight: 56)
                                    .modifier(TVConsoleSheetRow(focused: isFocused))
                            }
                            .buttonStyle(TVConsolePlainButtonStyle())
                            .focused($focused, equals: value)
                        }
                    }
                }
                // Room for the focus ring, which the scroll view would otherwise clip.
                .padding(6)
            }
            .padding(.top, 22)
        }
        .defaultFocus($focused, selection)
    }
}

/// `HomeTileMenu.qml`: what can be done with a Home tile.
struct TVConsoleHomeTileMenu: View {
    let game: CloudGame
    /// 1-based position among the Home tiles.
    let position: Int
    let isWide: Bool
    let canRemove: Bool
    let onMove: () -> Void
    let onSize: (_ wide: Bool) -> Void
    let onDetails: () -> Void
    let onRemove: () -> Void

    var body: some View {
        TVConsoleChoiceSheet(
            eyebrow: "HOME",
            title: "Edit Home tile",
            description: "\(game.title) · Home position \(position)",
            choices: choices
        )
    }

    private var choices: [TVConsoleChoice] {
        var choices = [
            TVConsoleChoice(id: "move", label: "Move tile", detail: "Pick it up, then use the D-pad to place it",
                            action: onMove),
            TVConsoleChoice(id: "square", label: "Square tile", detail: isWide ? "" : "Current size",
                            isCurrent: !isWide, action: { onSize(false) }),
            TVConsoleChoice(id: "wide", label: "Wide tile", detail: isWide ? "Current size" : "",
                            isCurrent: isWide, action: { onSize(true) }),
            TVConsoleChoice(id: "details", label: "Game details", action: onDetails),
        ]
        if canRemove {
            choices.append(TVConsoleChoice(id: "remove", label: "Remove from Home",
                                           detail: "Still available in Library", action: onRemove))
        }
        return choices
    }
}
