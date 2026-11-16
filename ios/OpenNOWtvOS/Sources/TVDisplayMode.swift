import UIKit

/// Owns the TV's display mode while OpenNOW is in the foreground: the mode fixed in Settings, or in
/// Automatic the best mode for the stream that is playing. The system's own mode is handed back
/// whenever neither applies and when the app leaves the foreground.
///
/// This Apple TV lists 120 Hz modes below 4K (2560x1440, 1920x1080), but tvOS has no public way to
/// select them: `AVDisplayManager` criteria asking for 120 Hz left the display at 60 Hz when tested.
/// QuartzCore's private `CADisplay` does switch, so this is for sideloaded builds only, and every
/// private call is checked at runtime first.
@MainActor
enum TVDisplayMode {
    /// A resolution and refresh rate the TV offers. The colour-format and dynamic-range variants of
    /// one are a single choice, and so are fractional rates (59.94 Hz counts as 60).
    struct Choice: Hashable {
        let width: Int
        let height: Int
        let refreshRate: Int

        var label: String { "\(width) × \(height) · \(refreshRate) Hz" }
    }

    private struct Video {
        let fps: Int
        let width: Int
        let hdr: Bool
    }

    /// The mode fixed in Settings; nil is Automatic.
    private(set) static var selection: Choice?
    private static var video: Video?
    private static var foreground = true
    /// The system's own mode while the display is held in another one.
    private static var original: NSObject?
    private static var applied: NSObject?
    private static let defaults = UserDefaults.standard
    private static let selectionKey = "tvDisplayModeSelection"
    /// Identifies `original` across launches: tvOS keeps the held mode if the app dies in it.
    private static let pendingRestoreKey = "tvHighRefreshDisplayModeOriginal"
    private static let setCurrentMode = NSSelectorFromString("setCurrentMode:")
    /// Slower modes are of no use to a game stream and are not offered.
    private static let minimumRefreshRate = 60

    /// The modes the connected TV offers, largest and fastest first.
    static var choices: [Choice] {
        guard let modes = tvOut()?.value(forKey: "availableModes") as? [NSObject] else { return [] }
        return Set(modes.compactMap(choice)).sorted {
            ($0.width * $0.height, $0.refreshRate) > ($1.width * $1.height, $1.refreshRate)
        }
    }

    /// Called at launch: loads the saved selection and takes over the display, putting it back first
    /// if the previous run ended while holding a mode.
    static func start() {
        if let saved = defaults.array(forKey: selectionKey) as? [Int], saved.count == 3 {
            selection = Choice(width: saved[0], height: saved[1], refreshRate: saved[2])
        }
        if let saved = defaults.object(forKey: pendingRestoreKey) as? NSNumber, let display = tvOut(),
           let modes = display.value(forKey: "availableModes") as? [NSObject] {
            original = modes.first { representation($0) == saved } ?? display.value(forKey: "preferredMode") as? NSObject
        }
        // The system UI must not inherit the app's mode. Background, not inactive: a system alert
        // over the app would otherwise switch modes twice.
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { enteredBackground() }
        }
        _ = center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { enteringForeground() }
        }
        tvStreamDebug("[TVStream] display choices \(choices.map(\.label)) selection=\(selection?.label ?? "Automatic")")
        update()
    }

    /// Fixes the display to `choice`, or with nil returns to Automatic. An unsaved selection lasts
    /// until the app ends, so a mode the TV cannot show does not come back at the next launch.
    static func select(_ choice: Choice?, save: Bool) {
        selection = choice
        if save { defaults.set(choice.map { [$0.width, $0.height, $0.refreshRate] }, forKey: selectionKey) }
        update()
    }

    /// Reports the video a stream is showing; safe to call again when its format changes. Returns
    /// whether this type holds the display in a mode for it. When it does not, the display is in
    /// the system's own mode and the system's content matching may be used instead.
    @discardableResult
    static func streamVideo(fps: Int, width: Int, hdr: Bool) -> Bool {
        video = Video(fps: fps, width: width, hdr: hdr)
        update()
        return applied != nil
    }

    static func streamEnded() {
        video = nil
        update()
    }

    private static func enteredBackground() {
        foreground = false
        if let original { apply(original) }
        defaults.removeObject(forKey: pendingRestoreKey)
    }

    private static func enteringForeground() {
        // Also sent at launch, when there is nothing to take back.
        guard !foreground else { return }
        foreground = true
        // The system's mode may have changed while the app was away. It is read again unless the
        // display still reports the mode set here, which would mean the hand-back has not registered.
        if let current = tvOut()?.value(forKey: "currentMode") as? NSObject, !same(current, applied) { original = nil }
        applied = nil
        update()
    }

    private static func update() {
        guard foreground, let display = tvOut(), let current = display.value(forKey: "currentMode") as? NSObject,
              let modes = display.value(forKey: "availableModes") as? [NSObject] else { return }
        let system = original ?? current
        guard let mode = wantedMode(among: modes, system: system) else {
            if let original { apply(original) }
            original = nil
            applied = nil
            defaults.removeObject(forKey: pendingRestoreKey)
            return
        }
        original = system
        defaults.set(representation(system), forKey: pendingRestoreKey)
        if !same(applied, mode) {
            applied = mode
            apply(mode)
        }
    }

    /// The mode the display should be held in, or nil to leave it in the system's own.
    private static func wantedMode(among modes: [NSObject], system: NSObject) -> NSObject? {
        let range = video?.hdr == true ? "HDR10" : "SDR"
        if let selection {
            var variants = modes.filter { choice(for: $0) == selection }
            let exact = variants.filter { number($0, "refreshRate") == Double(selection.refreshRate) }
            if !exact.isEmpty { variants = exact }
            // A fixed mode keeps its resolution and rate; only the dynamic range follows the video.
            if let mode = variants.first(where: { dynamicRange($0) == range })
                ?? variants.first(where: { dynamicRange($0) == "SDR" }) ?? variants.first {
                return mode
            }
            // The connected TV does not offer the saved mode: behave as Automatic.
        }
        // Automatic switches only when the system's mode refreshes slower than the stream, to the
        // largest mode at the stream's frame rate and dynamic range that is no wider than the stream.
        guard let video, number(system, "refreshRate") < Double(video.fps) - 0.5 else { return nil }
        let candidates = modes.filter {
            abs(number($0, "refreshRate") - Double(video.fps)) < 0.5 && number($0, "width") <= Double(video.width)
                && dynamicRange($0) == range
        }
        guard let widest = candidates.map({ number($0, "width") }).max() else { return nil }
        return candidates.first { number($0, "width") == widest }
    }

    private static func choice(for mode: NSObject) -> Choice? {
        let width = Int(number(mode, "width")), height = Int(number(mode, "height"))
        let rate = Int(number(mode, "refreshRate").rounded())
        guard width > 0, height > 0, rate >= minimumRefreshRate else { return nil }
        return Choice(width: width, height: height, refreshRate: rate)
    }

    private static func apply(_ mode: NSObject) {
        guard let display = tvOut(), display.responds(to: setCurrentMode) else { return }
        tvStreamDebug("[TVStream] display mode -> \(Int(number(mode, "width")))x\(Int(number(mode, "height"))) "
            + "\(number(mode, "refreshRate")) Hz \(dynamicRange(mode) ?? "?") \(mode)")
        _ = display.perform(setCurrentMode, with: mode)
    }

    private static func tvOut() -> NSObject? {
        let displays = NSSelectorFromString("displays")
        guard let type = NSClassFromString("CADisplay"), (type as AnyObject).responds(to: displays),
              let all = (type as AnyObject).perform(displays)?.takeUnretainedValue() as? [NSObject] else { return nil }
        return all.first { ($0.value(forKey: "name") as? String) == "TVOut" }
    }

    private static func same(_ a: NSObject?, _ b: NSObject?) -> Bool {
        guard let a, let b else { return false }
        if a.isEqual(b) { return true }
        guard let id = representation(a) else { return false }
        return id == representation(b)
    }

    private static func representation(_ mode: NSObject) -> NSNumber? {
        mode.value(forKey: "internalRepresentation") as? NSNumber
    }

    private static func dynamicRange(_ mode: NSObject) -> String? {
        mode.value(forKey: "hdrMode") as? String
    }

    /// -1 for a property this OS does not have: key-value access to a missing key would abort the app.
    private static func number(_ object: NSObject, _ key: String) -> Double {
        guard object.responds(to: NSSelectorFromString(key)) else { return -1 }
        return (object.value(forKey: key) as? NSNumber)?.doubleValue ?? -1
    }
}
