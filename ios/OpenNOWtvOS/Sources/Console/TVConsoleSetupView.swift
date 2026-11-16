import SwiftUI

/// First-run setup. The Qt client has no console version, so it takes the sign-in screen's layout:
/// the step and its buttons on the left, the step's choices in a glass panel on the right.
/// `IntroSetupView` owns the steps, texts and logic and hands them in; `content` is drawn as
/// console rows by `Form`.
struct TVConsoleSetupView<Content: View>: View {
    /// Zero-based.
    let step: Int
    let stepCount: Int
    let title: String
    let subtitle: String
    let primaryTitle: String
    let onPrimary: () -> Void
    let onBack: (() -> Void)?
    let onSkip: (() -> Void)?
    @ViewBuilder let content: Content

    private enum Button { case primary, back, skip }

    // The top bar reads the controller from the environment; the shell that normally owns it is
    // not on screen during setup.
    @StateObject private var input = TVConsoleInput()
    @FocusState private var focus: Button?
    @Environment(\.openNowAccent) private var accent

    var body: some View {
        ZStack {
            TVConsoleBackground(artwork: nil, tint: 0x1B2A42)
            controls
                .frame(width: 700, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 120)
            panel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 160)
            VStack {
                TVConsoleTopBar(title: "Welcome to OpenNOW")
                Spacer(minLength: 0)
            }
        }
        .environmentObject(input)
        .ignoresSafeArea()
        .defaultFocus($focus, .primary)
        // Back appears on step 2 and Skip goes on the last, and focus on a button that went away
        // is lost; the primary button is on every step.
        .onChange(of: step) { _, _ in focus = .primary }
        // Back on the first step is left to the system.
        .onExitCommand(perform: onBack)
        .onAppear { input.start() }
        .onDisappear { input.stop() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("STEP \(step + 1) OF \(stepCount)")
                .font(TVConsoleTheme.mono(15, bold: true))
                .tracking(2.4)
                .foregroundStyle(accent.color)
            HStack(spacing: 8) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? accent.color : TVConsoleTheme.face.opacity(0.18))
                        .frame(height: 4)
                }
            }
            .frame(width: 640)
            Text(title)
                .font(TVConsoleTheme.display(64))
                .tracking(-1.4)
                .foregroundStyle(TVConsoleTheme.label)
            Text(subtitle)
                .font(TVConsoleTheme.display(21, weight: 600))
                .lineSpacing(8)
                .foregroundStyle(TVConsoleTheme.label.opacity(0.76))
            VStack(spacing: 14) {
                TVConsoleActionButton(title: primaryTitle, primary: true, fillsWidth: true, action: onPrimary)
                    .focused($focus, equals: .primary)
                if let onBack {
                    TVConsoleActionButton(title: "Back", glyph: .back, fillsWidth: true, action: onBack)
                        .focused($focus, equals: .back)
                }
                if let onSkip {
                    TVConsoleActionButton(title: "Skip setup", fillsWidth: true, action: onSkip)
                        .focused($focus, equals: .skip)
                }
            }
            .frame(width: 640)
            .padding(.top, 8)
            .focusSection()
        }
    }

    private var panel: some View {
        Form { content }
            // The form scrolls, which makes it as tall as it is offered; its own height is what a
            // short step needs. Every step's rows fit the cap.
            .fixedSize(horizontal: false, vertical: true)
            // Rows stop short of the panel's rounded edges.
            .padding(.vertical, 18)
            .frame(width: 920)
            .tvConsoleGlass(radius: 40, strong: true)
            .clipShape(RoundedRectangle(cornerRadius: 40))
            .focusSection()
    }
}
