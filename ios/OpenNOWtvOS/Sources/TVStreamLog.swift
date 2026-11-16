import os

/// Console output for the developer: compiled into Debug builds only.
@inline(__always)
func tvStreamDebug(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

enum TVStreamLog {
    private static let logger = Logger(subsystem: "OpenNOWiOS", category: "TVStream")

    /// The raw failure text, kept in the unified log in every build; the screen shows a plain sentence.
    static func failure(_ reason: String) {
        logger.error("stream failed: \(reason, privacy: .public)")
    }
}
