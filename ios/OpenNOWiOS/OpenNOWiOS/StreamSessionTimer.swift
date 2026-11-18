import Foundation

// The session clock: the tier's session limit, time played and left, and the warnings as the
// limit nears. Shared by the iOS stream screen and the tvOS stream menu, stats strip and notices.

enum StreamSessionTimerMode: Equatable {
    case countdown
    case stopwatch
}

struct StreamSessionLimit: Equatable {
    let tierLabel: String
    let limitHours: Int
    let mode: StreamSessionTimerMode

    var limitSeconds: Int {
        limitHours * 60 * 60
    }
}

struct StreamSessionTimerSnapshot: Equatable {
    let elapsedSeconds: Int
    let remainingSeconds: Int
    let progress: Double

    var isWarning: Bool {
        remainingSeconds <= 10 * 60
    }
}

let streamSessionWarningThresholdsSeconds = [
    30 * 60,
    10 * 60,
    5 * 60,
    3 * 60,
    60
]

func streamSessionLimit(for membershipTier: String?) -> StreamSessionLimit {
    switch StreamSettingsResolver.plan(for: membershipTier) {
    case .free:
        return StreamSessionLimit(tierLabel: "Free", limitHours: 1, mode: .countdown)
    case .priority:
        return StreamSessionLimit(tierLabel: "Performance", limitHours: 6, mode: .stopwatch)
    case .ultimate:
        return StreamSessionLimit(tierLabel: "Ultimate", limitHours: 8, mode: .stopwatch)
    }
}

func streamSessionTimerSnapshot(
    limit: StreamSessionLimit,
    startedAt: Date,
    now: Date = Date()
) -> StreamSessionTimerSnapshot {
    let elapsedSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
    let remainingSeconds = max(0, limit.limitSeconds - elapsedSeconds)
    let progress = limit.limitSeconds > 0
        ? min(max(Double(elapsedSeconds) / Double(limit.limitSeconds), 0), 1)
        : 0
    return StreamSessionTimerSnapshot(
        elapsedSeconds: elapsedSeconds,
        remainingSeconds: remainingSeconds,
        progress: progress
    )
}

struct StreamSessionWarningTracker: Equatable {
    private(set) var previousRemainingSeconds: Int?
    private(set) var warnedThresholds: Set<Int> = []

    mutating func nextWarning(remainingSeconds: Int) -> Int? {
        defer { previousRemainingSeconds = remainingSeconds }
        guard let previousRemainingSeconds else { return nil }
        guard let crossedThreshold = streamSessionWarningThresholdsSeconds
            .filter({ previousRemainingSeconds > $0 && remainingSeconds <= $0 })
            .min() else {
            return nil
        }
        return warnedThresholds.insert(crossedThreshold).inserted ? crossedThreshold : nil
    }
}

/// The clock as the stream screens show it: time left on a countdown tier ("12:30 left"), time
/// played out of the limit on the others ("42:10 / 6h").
func streamSessionTimerText(snapshot: StreamSessionTimerSnapshot, limit: StreamSessionLimit) -> String {
    switch limit.mode {
    case .countdown:
        return "\(streamSessionClockText(snapshot.remainingSeconds)) left"
    case .stopwatch:
        return "\(streamSessionClockText(snapshot.elapsedSeconds)) / \(limit.limitHours)h"
    }
}

/// "1:02:03" from an hour on, else "02:03".
func streamSessionClockText(_ secondsValue: Int) -> String {
    let hours = secondsValue / 3_600
    let minutes = (secondsValue % 3_600) / 60
    let seconds = secondsValue % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}

/// What a crossed warning threshold announces: "5 minutes left in this session".
func streamSessionWarningText(thresholdSeconds: Int) -> String {
    let minutes = thresholdSeconds / 60
    return "\(minutes == 1 ? "1 minute" : "\(minutes) minutes") left in this session"
}
