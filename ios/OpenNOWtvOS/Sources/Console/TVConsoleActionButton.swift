import SwiftUI

/// `ConsoleActionButton.qml`: the shell's push button. The primary one is solid white, a
/// dangerous one is tinted coral, the rest are faint glass.
struct TVConsoleActionButton: View {
    let title: String
    /// A second line under the title, for buttons that need to say what they do.
    var detail = ""
    var glyph: TVConsoleButton?
    var primary = false
    var danger = false
    /// A pill (the game details row) rather than the rounded bar of a button column.
    var pill = false
    /// Keeps the focus ring while a panel opened from this button is up.
    var isOpen = false
    /// Fills the width it is offered, as the Qt button column does, instead of hugging its text.
    var fillsWidth = false
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.openNowAccent) private var accent

    private var height: CGFloat { detail.isEmpty ? 72 : 84 }
    private var radius: CGFloat { pill ? height / 2 : 26 }
    private var ringed: Bool { focused || isOpen }

    private var ink: Color {
        primary ? TVConsoleTheme.faceText : danger ? TVConsoleTheme.coral : TVConsoleTheme.label
    }

    private var fill: Color {
        primary ? TVConsoleTheme.face : danger ? TVConsoleTheme.coral.opacity(0.12) : TVConsoleTheme.face.opacity(0.07)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: primary ? 14 : 12) {
                if let glyph {
                    TVConsoleGlyph(button: glyph, size: primary ? 34 : 30,
                                   color: primary ? TVConsoleTheme.faceText : TVConsoleTheme.face)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(TVConsoleTheme.display(primary ? 24 : 20, weight: primary ? 900 : 800))
                        .foregroundStyle(ink)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(TVConsoleTheme.display(15, weight: 700))
                            .foregroundStyle(primary ? TVConsoleTheme.faceText.opacity(0.64) : TVConsoleTheme.textMuted)
                    }
                }
                .lineLimit(1)
            }
            .padding(.leading, glyph == nil ? 24 : 18)
            .padding(.trailing, primary ? 36 : 28)
            .frame(minWidth: 160, maxWidth: fillsWidth ? .infinity : nil, minHeight: height, maxHeight: height,
                   alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay {
                RoundedRectangle(cornerRadius: radius).strokeBorder(
                    ringed ? TVConsoleTheme.face : danger ? TVConsoleTheme.coral.opacity(0.6)
                        : primary ? Color.clear : TVConsoleTheme.seam,
                    lineWidth: ringed ? 3 : danger ? 1.5 : 1
                )
            }
            .overlay {
                if ringed {
                    // A gap in the shell colour, then the accent halo.
                    RoundedRectangle(cornerRadius: radius + 4).strokeBorder(TVConsoleTheme.shell, lineWidth: 4).padding(-4)
                    RoundedRectangle(cornerRadius: radius + 9).strokeBorder(accent.color.opacity(0.55), lineWidth: 5).padding(-9)
                }
            }
            .opacity(isEnabled ? 1 : 0.42)
        }
        .buttonStyle(TVConsolePlainButtonStyle())
        .focused($focused)
        .animation(.easeOut(duration: TVConsoleTheme.focusDuration), value: ringed)
    }
}
