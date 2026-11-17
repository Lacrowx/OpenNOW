import Foundation

/// One row of the in-stream menu.
enum TVStreamMenuItem: String {
    case resume = "Resume"
    case showStats = "Show Stats"
    case hideStats = "Hide Stats"
    case leftTriggerFeel = "L2 Feel"
    case rightTriggerFeel = "R2 Feel"
    case leave = "Leave Stream"
    case endSession = "End Session"
    case keepPlaying = "Keep Playing"
    case confirmEndSession = "End Session Now"
    case retry = "Try Again"
    case close = "Close"

    /// Ending the session closes the game on the host.
    var isDestructive: Bool { self == .endSession || self == .confirmEndSession }

    var symbol: String {
        switch self {
        case .resume, .keepPlaying: "play.fill"
        case .showStats: "chart.bar.xaxis"
        case .hideStats: "chart.bar.xaxis"
        case .leftTriggerFeel: "l2.rectangle.roundedtop.fill"
        case .rightTriggerFeel: "r2.rectangle.roundedtop.fill"
        case .leave: "rectangle.portrait.and.arrow.right"
        case .endSession, .confirmEndSession: "power"
        case .retry: "arrow.clockwise"
        case .close: "xmark"
        }
    }

    /// The line under the row's title.
    func detail(failed: Bool) -> String {
        switch self {
        case .resume: "Back to the game"
        case .showStats: "Show the stream figures over the game"
        case .hideStats: "Hide the stream figures over the game"
        case .leftTriggerFeel, .rightTriggerFeel: "Left or Right to change · kept for this game"
        case .leave: "The game keeps running. Rejoin it from Home."
        case .endSession: "Close the game on the server"
        case .keepPlaying: failed ? "Leave the game running on the server" : "Back to the game"
        case .confirmEndSession: "Unsaved progress may be lost"
        case .retry: "Connect to the session again"
        case .close: "Back to OpenNOW"
        }
    }

    var isTriggerFeel: Bool { self == .leftTriggerFeel || self == .rightTriggerFeel }
}

/// The in-stream menu as state: which rows it offers, which one is lit, and what a command asks
/// the stream to do. It does nothing itself; `TVStreamCoordinator` carries out the actions.
///
/// The menu is drawn and navigated this way, not by the tvOS focus engine: controller input stays
/// away from UIKit for the whole stream, so Back can never leave the app.
struct TVStreamMenu: Equatable {
    /// What the rows depend on outside the menu.
    struct Context: Equatable {
        var failed = false
        var canRetry = false
        var statsVisible = false
        /// Only a DualSense has triggers to shape.
        var dualSense = false
    }

    /// What a command asks of the stream.
    enum Action: Equatable {
        /// Close the menu and return to the game.
        case resume
        case setStatsVisible(Bool)
        case stepTriggerFeel(TVStreamMenuItem, by: Int)
        /// Leave the stream with the game still running on the server.
        case leave
        case retry
        /// Close the game on the server.
        case endSession
    }

    /// Open over a running stream. A failed stream shows its rows without it.
    private(set) var visible = false
    /// The menu is asking whether to end the session, which closes the game on the host.
    private(set) var confirmingEnd = false
    private(set) var selection = 0

    func items(in context: Context) -> [TVStreamMenuItem] {
        if confirmingEnd { return [.keepPlaying, .confirmEndSession] }
        if context.failed { return (context.canRetry ? [.retry] : []) + [.close, .endSession] }
        guard visible else { return [] }
        return [.resume, context.statsVisible ? .hideStats : .showStats]
            + (context.dualSense ? [.leftTriggerFeel, .rightTriggerFeel] : [])
            + [.leave, .endSession]
    }

    /// Opens or closes the menu at its first row; also leaves the question.
    mutating func setVisible(_ visible: Bool) {
        self = TVStreamMenu()
        self.visible = visible
    }

    /// Navigation from a game controller or the Siri Remote. Returns what the stream should do,
    /// or nil when the command only moved within the menu.
    mutating func handle(_ command: NativeStreamControllerHUDCommand, in context: Context) -> Action? {
        let items = items(in: context)
        guard !items.isEmpty else { return nil }
        let lit = items[min(selection, items.count - 1)]
        switch command {
        case .up: selection = max(0, selection - 1)
        case .down: selection = min(items.count - 1, selection + 1)
        case .back:
            guard !confirmingEnd else {
                setConfirmingEnd(false, in: context)
                return nil
            }
            // Nothing is left to resume behind a failure, so Back closes it.
            return context.failed ? .leave : .resume
        case .activate:
            switch lit {
            case .resume: return .resume
            case .endSession: setConfirmingEnd(true, in: context)
            case .keepPlaying: setConfirmingEnd(false, in: context)
            case .confirmEndSession: return .endSession
            case .showStats: return .setStatsVisible(true)
            case .hideStats: return .setStatsVisible(false)
            case .leftTriggerFeel, .rightTriggerFeel: return .stepTriggerFeel(lit, by: 1)
            case .leave, .close: return .leave
            case .retry: return .retry
            }
        case .left: return lit.isTriggerFeel ? .stepTriggerFeel(lit, by: -1) : nil
        case .right: return lit.isTriggerFeel ? .stepTriggerFeel(lit, by: 1) : nil
        }
        return nil
    }

    /// Opens the question with "Keep Playing" lit; leaving it lights "End Session" again.
    private mutating func setConfirmingEnd(_ confirming: Bool, in context: Context) {
        confirmingEnd = confirming
        selection = confirming ? 0 : items(in: context).count - 1
    }
}
