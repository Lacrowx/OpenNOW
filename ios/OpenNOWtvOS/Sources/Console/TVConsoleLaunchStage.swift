import Foundation

/// Where a launch stands, as the queue screen words it (`opennow-qt/qml/screens/InsertingScreen.qml`
/// and `components/LaunchStage.qml`). Pure rules, kept apart from the views so they can be tested.
struct TVConsoleLaunchStage: Equatable {
    /// The four steps of the rail, in order.
    enum Step: Int, CaseIterable {
        case requested = 1, waitingForRig, settingUp, connecting
    }

    let step: Step
    /// Position to show in the ring; `nil` when GeForce NOW reports none.
    let queuePosition: Int?
    let queuePaused: Bool

    /// - Parameters:
    ///   - sessionStatus: `ActiveSession.status`, or `nil` before the session exists.
    ///   - isPastQueue: `QueueSessionPhase.isPastQueue` for that session.
    init(sessionStatus: Int?, isPastQueue: Bool, queuePosition: Int?, queuePaused: Bool) {
        guard let sessionStatus else {
            self.init(step: .requested, queuePosition: nil, queuePaused: false)
            return
        }
        if isPastQueue {
            // Past the queue, status 1 is still seat setup; 2 and 3 have a rig ready to stream.
            self.init(step: sessionStatus == 1 ? .settingUp : .connecting, queuePosition: nil, queuePaused: false)
        } else {
            self.init(step: .waitingForRig, queuePosition: queuePosition.flatMap { $0 > 0 ? $0 : nil },
                      queuePaused: queuePaused)
        }
    }

    private init(step: Step, queuePosition: Int?, queuePaused: Bool) {
        self.step = step
        self.queuePosition = queuePosition
        self.queuePaused = queuePaused
    }

    /// The chip in the top-right corner.
    var status: String {
        switch step {
        case .requested: return "Starting"
        case .waitingForRig: return queuePaused ? "Queue paused" : "In queue"
        case .settingUp: return "Setting up"
        case .connecting: return "Connecting"
        }
    }

    var headline: String {
        switch step {
        case .requested: return "Requesting a rig"
        case .waitingForRig:
            if queuePaused { return "Your place is on hold" }
            return queuePosition == nil ? "Waiting for an available rig" : "You’re in line"
        case .settingUp: return "Setting up your rig"
        case .connecting: return "Connecting the stream"
        }
    }

    var detail: String {
        switch step {
        case .requested: return "Asking GeForce NOW for a rig."
        case .waitingForRig:
            return queuePaused
                ? "The queue is paused until the advertisement has played."
                : "Your session starts by itself, so you can put the controller down."
        case .settingUp: return "GeForce NOW is preparing the rig for your game."
        case .connecting: return "The rig is ready. Opening the stream."
        }
    }

    /// Label of a rail row: a step already passed reads as done.
    func label(for row: Step) -> String {
        switch row {
        case .requested: return "Session requested"
        case .waitingForRig: return step.rawValue > row.rawValue ? "Got a rig" : "Waiting for a rig"
        case .settingUp: return step.rawValue > row.rawValue ? "Rig is set up" : "Setting up the rig"
        case .connecting: return "Connecting the stream"
        }
    }
}

/// The "Play on" chips of the game details (`GameDetailScreen.qml`): every store while they fit
/// in a row, otherwise only the chosen one beside an "All N stores" chip.
enum TVConsolePlayOnChips {
    static let inlineLimit = 4

    static func isInline(optionCount: Int) -> Bool { optionCount <= inlineLimit }

    /// Indices of the options drawn as chips.
    static func shown(optionCount: Int, selected: Int?) -> [Int] {
        if isInline(optionCount: optionCount) { return Array(0..<optionCount) }
        return selected.map { [$0] } ?? []
    }

    /// What a chip says about ownership. A store that reports nothing is not claimed either way.
    static func ownershipLabel(isOwned: Bool, libraryStatus: String?) -> String {
        if isOwned { return "Owned" }
        return libraryStatus?.uppercased() == "NOT_OWNED" ? "Not owned" : "Ownership unconfirmed"
    }
}
