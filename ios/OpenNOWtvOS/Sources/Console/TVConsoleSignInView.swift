import SwiftUI

/// `SignInScreen.qml`: the signed-out screen. `LoginView` owns the sign-in task and the QR
/// image and hands them in; this view only draws them and reports what was pressed.
struct TVConsoleSignInView: View {
    let prompt: DeviceLoginPrompt?
    let qrCode: UIImage?
    let onSignIn: () -> Void
    let onQRCode: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var store: OpenNOWStore
    // The top bar reads the controller from the environment; the shell that normally owns it is
    // not on screen before sign-in.
    @StateObject private var input = TVConsoleInput()
    @FocusState private var focus: TVConsoleSignIn.Button?
    @State private var showingProviders = false
    @Environment(\.openNowAccent) private var accent

    private var provider: LoginProvider? {
        store.providers.first { $0.idpId == store.settings.selectedProviderIdpId }
    }

    private var state: TVConsoleSignIn {
        TVConsoleSignIn(providerCode: provider?.code, providerName: provider?.displayName ?? "NVIDIA",
                        hasCode: prompt != nil, isAuthenticating: store.isAuthenticating,
                        error: store.authError, phase: store.authenticationPhase)
    }

    var body: some View {
        ZStack {
            TVConsoleBackground(artwork: nil, tint: 0x1B2A42)
            controls
                .frame(width: 820, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 120)
            // A provider without QR sign-in has nothing to scan.
            if prompt != nil || state.buttons.contains(.qrCode) {
                qrPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 160)
            }
            VStack {
                TVConsoleTopBar(title: "Welcome to OpenNOW")
                Spacer(minLength: 0)
            }
        }
        .environmentObject(input)
        .ignoresSafeArea()
        .defaultFocus($focus, state.buttons.first)
        // A code appearing or a failed attempt ending changes which buttons exist or work, and
        // focus on one that went away or was disabled is lost.
        .onChange(of: state.buttons) { _, buttons in focus = buttons.first }
        .onChange(of: store.isAuthenticating) { _, _ in focus = state.buttons.first }
        .onExitCommand(perform: prompt == nil ? nil : onCancel)
        .onAppear { input.start() }
        .onDisappear { input.stop() }
        .fullScreenCover(isPresented: $showingProviders) {
            TVConsoleChoiceSheet(
                eyebrow: "SIGN IN", title: "Provider",
                description: "Choose the GeForce NOW service that holds your account.",
                choices: store.providers.map { provider in
                    TVConsoleChoice(id: provider.idpId, label: provider.displayName,
                                    isCurrent: provider.idpId == store.settings.selectedProviderIdpId) {
                        store.selectProvider(provider)
                        showingProviders = false
                    }
                }
            )
            .task { await store.refreshProviders() }
        }
    }

    // MARK: Left column

    private var controls: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("SIGN IN")
                .font(TVConsoleTheme.mono(15, bold: true))
                .tracking(2.4)
                .foregroundStyle(accent.color)
            Text("Bring your games to the big screen.")
                .font(TVConsoleTheme.display(64))
                .tracking(-1.4)
                .foregroundStyle(TVConsoleTheme.label)
            Text("OpenNOW connects to your GeForce NOW account without storing your NVIDIA password. Sign in from your phone, then come straight back to the controller.")
                .font(TVConsoleTheme.display(21, weight: 600))
                .lineSpacing(8)
                .foregroundStyle(TVConsoleTheme.label.opacity(0.76))
            VStack(spacing: 14) {
                ForEach(Array(state.buttons.enumerated()), id: \.element) { index, button in
                    TVConsoleActionButton(title: state.title(for: button), glyph: glyph(for: button),
                                          primary: index == 0 && button != .cancel, isOpen: button == .provider && showingProviders,
                                          fillsWidth: true) {
                        press(button)
                    }
                    .disabled(!state.isEnabled(button))
                    .focused($focus, equals: button)
                }
            }
            .frame(width: 640)
            .padding(.top, 8)
            .focusSection()
            status
        }
    }

    private func glyph(for button: TVConsoleSignIn.Button) -> TVConsoleButton? {
        button == .cancel ? .back : nil
    }

    private func press(_ button: TVConsoleSignIn.Button) {
        switch button {
        case .qrCode: onQRCode()
        case .signIn: onSignIn()
        case .provider: showingProviders = true
        case .cancel: onCancel()
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(state.statusIsError ? TVConsoleTheme.coral : TVConsoleTheme.mint)
                    .frame(width: 10, height: 10)
                Text(state.statusText)
                    .font(TVConsoleTheme.display(17, weight: 600))
                    .foregroundStyle(state.statusIsError ? TVConsoleTheme.coral : TVConsoleTheme.textMuted)
                    .lineLimit(2)
            }
            // Tells the user what to do during the browser sign-in.
            ForEach(Array(store.tvAuthLogs.suffix(4).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(TVConsoleTheme.mono(14))
                    .foregroundStyle(TVConsoleTheme.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(width: 640, alignment: .leading)
    }

    // MARK: QR panel

    private var qrPanel: some View {
        VStack(spacing: 20) {
            qrTile
            if let prompt {
                Text(prompt.userCode)
                    .font(TVConsoleTheme.mono(34, bold: true))
                    .tracking(4)
                    .foregroundStyle(TVConsoleTheme.label)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Expires in \(TVConsoleSignIn.countdown(until: prompt.expiresAt, now: context.date)) · \(TVConsoleSignIn.hostText(for: prompt.verificationURL))")
                }
                .frame(width: 400)
            } else {
                Text("Scan with your phone")
                    .font(TVConsoleTheme.display(22))
                    .foregroundStyle(TVConsoleTheme.label)
                Text("A real QR code appears after sign-in starts")
                    .frame(width: 400)
            }
        }
        .font(TVConsoleTheme.display(16, weight: 600))
        .foregroundStyle(TVConsoleTheme.textMuted)
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(width: 480)
        .tvConsoleGlass(radius: 40, strong: true)
    }

    private var qrTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28).fill(Color.white)
            if prompt != nil, let qrCode {
                // Whole points per module keep the squares crisp; 320 is the Qt grid's width.
                let modules = max(qrCode.size.width, 1)
                Image(uiImage: qrCode)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: (320 / modules).rounded(.down) * modules,
                           height: (320 / modules).rounded(.down) * modules)
                    .accessibilityLabel("QR code for NVIDIA sign-in")
            } else {
                VStack(spacing: 10) {
                    Text("◎")
                        .font(.system(size: 88, weight: .black))
                    Text("Ready when you are")
                        .font(TVConsoleTheme.display(19, weight: 700))
                }
                .foregroundStyle(TVConsoleTheme.faceText)
            }
        }
        .frame(width: 360, height: 360)
    }
}
