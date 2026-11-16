import SwiftUI
import UIKit

/// The console shell (`AppChrome.qml` around a screen): top bar, the current page, button hints
/// and the dock. It replaces the tab bar on tvOS.
struct TVConsoleShell<Page: View>: View {
    @Binding var route: TVConsoleRoute
    @ViewBuilder let page: (TVConsoleRoute) -> Page

    @EnvironmentObject private var store: OpenNOWStore
    /// Owned by the root view, so the queue screen and the covers above the shell share it.
    @EnvironmentObject private var input: TVConsoleInput
    @StateObject private var state = TVConsoleShellState()
    @FocusState private var dockFocus: TVConsoleRoute?
    @State private var hints = TVConsoleHints()

    var body: some View {
        ZStack {
            TVConsoleTheme.shell.ignoresSafeArea()
            // Pages draw edge to edge on the Qt canvas and mark their own focus sections: one
            // around the whole page would cover the dock and keep focus from moving down to it.
            page(route)
            chrome
        }
        .environmentObject(state)
        .onPreferenceChange(TVConsoleHintsKey.self) { hints = $0 }
        .onReceive(input.presses, perform: handle)
        .onExitCommand(perform: exitAction)
        .onAppear { input.start() }
        .onDisappear { input.stop() }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            TVConsoleTopBar(title: route.title)
            Spacer(minLength: 0)
            ZStack {
                HStack {
                    TVConsoleHintRow(hints: hints.left)
                    Spacer()
                    TVConsoleHintRow(hints: hints.right)
                }
                .padding(.horizontal, 64)
                TVConsoleDock(route: $route, focus: $dockFocus)
                    .disabled(hints.locksDock)
            }
            .frame(height: 72)
            // Full width, so Down reaches the dock from any column of the page above.
            .frame(maxWidth: .infinity)
            .focusSection()
            .padding(.bottom, 60)
        }
        .ignoresSafeArea()
    }

    /// Back on a page moves focus to the dock, the way it reaches the tab bar in a tab view.
    /// Home and the dock have nothing behind them, so there the system takes Back and leaves the app.
    private var exitAction: (() -> Void)? {
        guard route != .home, dockFocus == nil, !hints.handlesBack else { return nil }
        return {
            // A pushed page normally pops before this runs. Popping here covers the case where
            // this handler is asked first, so Back never skips a level.
            if !TVConsoleWindow.popNavigation() { dockFocus = route }
        }
    }

    private func handle(_ press: TVConsoleInput.Press) {
        guard !store.queueOverlayVisible, !hints.locksDock else { return }
        switch press {
        case .previousPage: step(by: -1)
        case .nextPage: step(by: 1)
        case .y:
            // Home's "Search" looks through every game, which is the Store's search.
            guard route == .home else { break }
            state.focusSearchOnArrival = true
            route = .store
        case .x, .options: break
        }
    }

    private func step(by offset: Int) {
        let routes = TVConsoleRoute.allCases
        guard let index = routes.firstIndex(of: route), routes.indices.contains(index + offset) else { return }
        route = routes[index + offset]
    }
}

/// Requests one page leaves for the next one the shell shows.
@MainActor
final class TVConsoleShellState: ObservableObject {
    /// The Store should open with focus on its search field. The Store clears it.
    var focusSearchOnArrival = false
}

/// UIKit state the shell cannot read through SwiftUI.
@MainActor
enum TVConsoleWindow {
    private static var root: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
    }

    /// A sheet, alert, cover or the keyboard is over the shell.
    static var isModalPresented: Bool { root?.presentedViewController != nil }

    /// Pops the innermost navigation stack that has a pushed page. `false` when none has.
    static func popNavigation() -> Bool {
        guard let root, let stack = pushedStack(in: root) else { return false }
        stack.popViewController(animated: true)
        return true
    }

    private static func pushedStack(in controller: UIViewController) -> UINavigationController? {
        for child in controller.children.reversed() {
            if let found = pushedStack(in: child) { return found }
        }
        if let stack = controller as? UINavigationController, stack.viewControllers.count > 1 { return stack }
        return nil
    }
}
