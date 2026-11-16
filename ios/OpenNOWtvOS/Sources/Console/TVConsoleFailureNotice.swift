import SwiftUI

/// What the shell tells the user when a failure was reported and no screen already shows it.
/// Pure: the store hands in the failure and the state around it, and gets back the notice or nil.
struct TVConsoleFailureNotice: Equatable, Identifiable {
    enum Button: Equatable {
        /// Signs the current account out, which brings up the sign-in screen.
        case signInAgain
        case dismiss
    }

    let kind: OpenNOWFailure.Kind
    let title: String
    let message: String
    let buttons: [Button]

    var id: String { "\(kind.rawValue)|\(message)" }

    func title(for button: Button) -> String {
        switch button {
        case .signInAgain: return "Sign in again"
        case .dismiss: return buttons.contains(.signInAgain) ? "Not now" : "OK"
        }
    }

    /// `queueScreenVisible` and `rejoinScreenVisible` are the screens that already print the
    /// session error; `isSignedIn` is false once the user has already left the account.
    static func make(failure: OpenNOWFailure, queueScreenVisible: Bool, rejoinScreenVisible: Bool,
                     isSignedIn: Bool) -> TVConsoleFailureNotice? {
        guard !queueScreenVisible, !rejoinScreenVisible else { return nil }
        if failure.kind == .authExpired {
            guard isSignedIn else { return nil }
            return TVConsoleFailureNotice(
                kind: .authExpired,
                title: "Your sign-in has expired",
                message: "Sign in again to keep playing.",
                buttons: [.signInAgain, .dismiss]
            )
        }
        guard !failure.message.isEmpty else { return nil }
        return TVConsoleFailureNotice(kind: failure.kind, title: title(for: failure.kind),
                                      message: failure.message, buttons: [.dismiss])
    }

    private static func title(for kind: OpenNOWFailure.Kind) -> String {
        switch kind {
        case .offline: return "No connection"
        case .timeout: return "No answer"
        case .authExpired: return "Your sign-in has expired"
        case .notEntitled: return "Not in your plan"
        case .sessionLimit: return "A session is already running"
        case .capacity: return "No rigs available"
        case .maintenance: return "Under maintenance"
        case .transportLost: return "Connection lost"
        case .rejected, .unknown: return "Something went wrong"
        }
    }
}

/// The notice over the shell: a centred card with its buttons. Back dismisses it.
struct TVConsoleFailureNoticeView: View {
    let notice: TVConsoleFailureNotice

    @EnvironmentObject private var store: OpenNOWStore

    private enum Field: Hashable { case signIn, dismiss }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(spacing: 14) {
            Text(notice.title)
                .font(TVConsoleTheme.display(40))
                .foregroundStyle(TVConsoleTheme.label)
            Text(notice.message)
                .font(TVConsoleTheme.display(22, weight: 600))
                .foregroundStyle(TVConsoleTheme.textMuted)
                .multilineTextAlignment(.center)
            HStack(spacing: 20) {
                ForEach(notice.buttons, id: \.self) { button in
                    TVConsoleActionButton(title: notice.title(for: button), primary: button == notice.buttons.first) {
                        switch button {
                        case .signInAgain: store.signInAgainFromFailureNotice()
                        case .dismiss: store.dismissFailureNotice()
                        }
                    }
                    .focused($focus, equals: button == .signInAgain ? .signIn : .dismiss)
                }
            }
            .padding(.top, 26)
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focus, notice.buttons.first == .signInAgain ? .signIn : .dismiss)
        .presentationBackground(TVConsoleTheme.shell)
    }
}

/// Presents the store's failure notice over the shell.
struct TVConsoleFailurePrompt: ViewModifier {
    @EnvironmentObject private var store: OpenNOWStore

    func body(content: Content) -> some View {
        content.fullScreenCover(item: Binding(
            get: { store.failureNotice },
            set: { if $0 == nil { store.dismissFailureNotice() } }
        )) { notice in
            TVConsoleFailureNoticeView(notice: notice)
                .environmentObject(store)
        }
    }
}
