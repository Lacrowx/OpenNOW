import SwiftUI

/// The screen for rejoining a game that is still running. A relaunch that finds one asks here
/// whether to rejoin or end it. While a rejoin is under way, from here or from anywhere else, it
/// shows that instead of the choices, and the streamer replaces it. Back leaves the session
/// running; it stays on Home as the running game.
struct TVConsoleRejoinView: View {
    let session: ActiveSession

    @EnvironmentObject private var store: OpenNOWStore
    @Environment(\.openNowAccent) private var accent

    private enum Field { case rejoin, end, later }
    @FocusState private var focus: Field?

    var body: some View {
        // Rejoining claims the session first, which takes a few seconds.
        let rejoining = store.isLaunchingSession
        let title = session.game.title
        TVConsoleLaunchStageView(
            game: session.game,
            status: rejoining ? "Reconnecting" : "Still running", tone: accent.color,
            eyebrow: "Your game is still running",
            headline: rejoining ? "Jumping back into \(title)" : "Jump back into \(title)?",
            detail: rejoining ? "Reconnecting to the running session. This takes a few seconds."
                : store.sessionError ?? "The session is still running on the server."
        ) {
            EmptyView()
        } actions: {
            if rejoining {
                HStack(spacing: 16) {
                    ProgressView()
                    Text("Reconnecting…")
                        .font(TVConsoleTheme.display(20, weight: 800))
                        .foregroundStyle(TVConsoleTheme.label)
                }
                .frame(height: 84)
            } else {
                TVConsoleActionButton(title: "Jump back in", detail: "Resume the running session", primary: true) {
                    store.jumpBackToSession()
                }
                .focused($focus, equals: .rejoin)
                TVConsoleActionButton(title: "End session", detail: "Closes the game. Unsaved progress may be lost.",
                                      danger: true) {
                    Task { await store.endSession() }
                }
                .focused($focus, equals: .end)
                TVConsoleActionButton(title: "Not now") {
                    store.dismissRejoinScreen()
                }
                .focused($focus, equals: .later)
            }
        }
        .defaultFocus($focus, .rejoin)
        .presentationBackground(TVConsoleTheme.shell)
    }
}

/// Presents `TVConsoleRejoinView` over the shell while the store has a session for it.
struct TVConsoleRejoinPrompt: ViewModifier {
    @EnvironmentObject private var store: OpenNOWStore

    func body(content: Content) -> some View {
        content.fullScreenCover(item: Binding(
            get: { store.sessionOnRejoinScreen },
            set: { if $0 == nil { store.dismissRejoinScreen() } }
        )) { session in
            TVConsoleRejoinView(session: session)
                .environmentObject(store)
        }
    }
}
