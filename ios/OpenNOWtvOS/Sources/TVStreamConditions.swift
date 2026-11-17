import AVFoundation
import GameController
import Network

/// Where the stream's sound goes, and how late it gets there.
struct TVAudioRoute: Equatable {
    enum Kind { case hdmi, bluetooth, airPlay, other }

    let name: String
    let kind: Kind
    /// The route's own delay plus one I/O buffer, as the system reports it.
    let latencyMs: Int

    /// Wireless sound this late is out of step with the picture and with the player's input.
    static let noticeableLatencyMs = 60

    static func current() -> TVAudioRoute? {
        let session = AVAudioSession.sharedInstance()
        guard let output = session.currentRoute.outputs.first else { return nil }
        let kind: Kind
        switch output.portType {
        case .HDMI: kind = .hdmi
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: kind = .bluetooth
        case .airPlay: kind = .airPlay
        default: kind = .other
        }
        return TVAudioRoute(name: output.portName, kind: kind,
                            latencyMs: Int(((session.outputLatency + session.ioBufferDuration) * 1000).rounded()))
    }

    var label: String { kind == .hdmi ? "HDMI" : name }

    /// The stream menu's figure: the output and its delay.
    var figure: String { "\(label) · \(latencyMs) ms" }

    /// Said once when the stream starts on, or moves to, a slow wireless output.
    var notice: String? {
        guard kind == .bluetooth || kind == .airPlay, latencyMs >= Self.noticeableLatencyMs else { return nil }
        return "\(name) plays the sound about \(latencyMs) ms late. Sound through the TV is in step with the picture."
    }
}

/// Follows whether the Apple TV is on Wi-Fi or Ethernet. Updates arrive on the main actor.
final class TVNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()

    func start(onChange: @escaping @MainActor (SessionNetworkKind) -> Void) {
        monitor.pathUpdateHandler = { path in
            let kind = SessionNetworkKind(path: path)
            Task { @MainActor in onChange(kind) }
        }
        monitor.start(queue: DispatchQueue(label: "OpenNOW.TVNetworkMonitor"))
    }

    func stop() { monitor.cancel() }
}

extension SessionNetworkKind {
    init(path: NWPath) {
        guard path.status == .satisfied else { self = .unknown; return }
        if path.usesInterfaceType(.wiredEthernet) { self = .wired }
        else if path.usesInterfaceType(.wifi) { self = .wifi }
        else if path.usesInterfaceType(.cellular) { self = .cellular }
        else { self = .unknown }
    }
}

/// Watches a Wi-Fi stream for sustained trouble, so the advice to use Ethernet comes once and
/// only when it would help.
struct TVWiFiTroubleDetector {
    static let lossPercent = 2.0
    static let jitterMs = 15.0
    /// Consecutive bad readings (about a second each) before it counts as trouble.
    static let sustainedReadings = 5

    private var badReadings = 0
    private(set) var reported = false

    /// True once, the first time the trouble has lasted long enough on Wi-Fi.
    mutating func shouldReport(network: SessionNetworkKind, lossPercent: Double?, jitterMs: Double?) -> Bool {
        guard !reported, network == .wifi else { badReadings = 0; return false }
        let bad = (lossPercent ?? 0) >= Self.lossPercent || (jitterMs ?? 0) >= Self.jitterMs
        badReadings = bad ? badReadings + 1 : 0
        guard badReadings >= Self.sustainedReadings else { return false }
        reported = true
        return true
    }
}

/// A controller's battery as the stream menu and the low-battery notice read it.
struct TVControllerBattery: Equatable {
    /// One-based, as the pad's player lights show it; nil before the stream gives it a slot.
    let player: Int?
    let percent: Int?
    let charging: Bool

    /// Warned at these levels, once each, while discharging.
    static let warningPercents = [15, 5]

    @MainActor
    static func all() -> [TVControllerBattery] {
        GCController.controllers().filter { $0.extendedGamepad != nil }.map { controller in
            let index = controller.playerIndex.rawValue
            let battery = controller.battery
            let charging = battery.map { $0.batteryState == .charging || $0.batteryState == .full } ?? false
            // A level of exactly 0 with an unknown state is a pad that does not report one.
            let unknown = battery == nil || (battery?.batteryState == .unknown && battery?.batteryLevel == 0)
            return TVControllerBattery(player: index >= 0 ? index + 1 : nil,
                                       percent: unknown ? nil : battery.map { Int(($0.batteryLevel * 100).rounded()) },
                                       charging: charging)
        }
    }

    var label: String {
        let who = player.map { "P\($0)" } ?? "Pad"
        if charging { return "\(who) charging" }
        return percent.map { "\(who) \($0)%" } ?? who
    }

    /// The lowest warning level this reading has reached, if any.
    var warningLevel: Int? {
        guard !charging, let percent else { return nil }
        return Self.warningPercents.filter { percent <= $0 }.min()
    }
}
