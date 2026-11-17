import Foundation
import GameController

/// Decides when a stream nobody is playing gets the "Still playing?" countdown, and when that
/// countdown has run out. Times are `systemUptime` seconds.
struct TVStreamIdleGuard: Equatable {
    enum Phase: Equatable {
        case active
        /// The countdown is showing, with this many whole seconds left.
        case warning(secondsLeft: Int)
        case expired
    }

    static let warningDuration: TimeInterval = 60

    /// Input-free time before the countdown starts.
    let idleTimeout: TimeInterval
    private(set) var lastActivity: TimeInterval

    init(idleMinutes: Int, now: TimeInterval) {
        idleTimeout = TimeInterval(max(1, idleMinutes) * 60)
        lastActivity = now
    }

    mutating func noteActivity(at now: TimeInterval) { lastActivity = max(lastActivity, now) }

    func phase(at now: TimeInterval) -> Phase {
        let idle = now - lastActivity
        guard idle >= idleTimeout else { return .active }
        let left = idleTimeout + Self.warningDuration - idle
        return left > 0 ? .warning(secondsLeft: Int(left.rounded(.up))) : .expired
    }
}

/// What a person is doing with the input devices, reduced so that only a deliberate change reads
/// as different: buttons and triggers pressed, sticks in coarse steps past a dead zone (a pad
/// lying on a table must not keep a stream awake), and the last keyboard and mouse events.
/// Motion sensors are left out on purpose, as they never rest.
struct TVInputActivitySignature: Equatable {
    private var pads: [[Int]] = []
    private var keyboardEvent: TimeInterval = 0
    private var mouseEvents: [TimeInterval] = []

    static let stickDeadZone: Float = 0.3

    @MainActor
    static func current() -> TVInputActivitySignature {
        var signature = TVInputActivitySignature()
        signature.pads = GCController.controllers().compactMap(\.extendedGamepad).map(pad)
        signature.keyboardEvent = GCKeyboard.coalesced?.keyboardInput?.lastEventTimestamp ?? 0
        signature.mouseEvents = GCMouse.mice().compactMap { $0.mouseInput?.lastEventTimestamp }
        return signature
    }

    static func stickStep(_ value: Float) -> Int {
        abs(value) < stickDeadZone ? 0 : Int((value * 4).rounded())
    }

    private static func pad(_ gamepad: GCExtendedGamepad) -> [Int] {
        let buttons: [GCControllerButtonInput?] = [
            gamepad.buttonA, gamepad.buttonB, gamepad.buttonX, gamepad.buttonY,
            gamepad.leftShoulder, gamepad.rightShoulder, gamepad.leftTrigger, gamepad.rightTrigger,
            gamepad.buttonMenu, gamepad.buttonOptions, gamepad.buttonHome,
            gamepad.leftThumbstickButton, gamepad.rightThumbstickButton,
            gamepad.dpad.up, gamepad.dpad.down, gamepad.dpad.left, gamepad.dpad.right,
        ]
        let pressed = buttons.enumerated().reduce(0) { $0 | (($1.element?.isPressed ?? false) ? 1 << $1.offset : 0) }
        return [pressed] + [gamepad.leftThumbstick, gamepad.rightThumbstick]
            .flatMap { [stickStep($0.xAxis.value), stickStep($0.yAxis.value)] }
    }
}
