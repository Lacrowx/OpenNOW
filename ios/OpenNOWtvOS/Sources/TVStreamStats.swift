import Foundation

/// Per-second figures for one stream, derived from the transport's running totals. One instance
/// feeds the stats HUD, the stream menu and the session report, so the three never disagree.
struct TVStreamStats {
    struct Reading: Equatable {
        var decodedFPS: Int?
        var receivedFPS: Int?
        var bitrateKbps: Int?
        var packetsLostDelta: Int?
        var packetsReceivedDelta: Int?
        /// Share of all packets since the stream started that never arrived.
        var lossPercent: Double
        var pingMs: Int?
        var decodeMs: Double?
        var jitterMs: Double
        var resolution: String?
    }

    private var previous: (at: TimeInterval, sample: NativeStreamNVSTSample)?

    /// Rates need two samples, so they are nil for the first one, and for one whose totals went
    /// backwards (the receiver was rebuilt).
    mutating func read(_ sample: NativeStreamNVSTSample, at now: TimeInterval) -> Reading {
        defer { previous = (now, sample) }
        let elapsed = previous.map { now - $0.at } ?? 0
        func delta(_ total: KeyPath<NativeStreamNVSTSample, UInt64>) -> Double? {
            guard let previous, elapsed > 0, sample[keyPath: total] >= previous.sample[keyPath: total] else { return nil }
            return Double(sample[keyPath: total] - previous.sample[keyPath: total])
        }
        func rate(_ total: KeyPath<NativeStreamNVSTSample, UInt64>, scale: Double = 1) -> Int? {
            delta(total).map { Int(($0 * scale / elapsed).rounded()) }
        }
        return Reading(
            decodedFPS: rate(\.decoded),
            receivedFPS: rate(\.received),
            bitrateKbps: rate(\.bytes, scale: 8.0 / 1000),
            packetsLostDelta: delta(\.lost).map { Int($0) },
            packetsReceivedDelta: delta(\.packets).map { Int($0) },
            lossPercent: Double(sample.lost) * 100 / Double(max(1, sample.lost + sample.packets)),
            pingMs: sample.pingMilliseconds.map { Int($0.rounded()) },
            decodeMs: sample.decodeMilliseconds >= 0 ? sample.decodeMilliseconds : nil,
            jitterMs: sample.jitterMilliseconds,
            resolution: sample.resolution)
    }
}

extension TVStreamStats.Reading {
    /// The figures chosen in Settings, in the order the HUD shows them. A figure with no value yet
    /// is left out, and so are the metrics a TV cannot measure (see `tvEnabledCount`).
    func hudItems(metrics: StreamStatsMetrics, codec: String, gpu: String?, server: String?) -> [String] {
        let items: [(enabled: Bool, text: String?)] = [
            (metrics.fps, decodedFPS.map { "\($0) fps" }),
            (metrics.ping, pingMs.map { "\($0) ms" }),
            (metrics.latency, decodeMs.map { String(format: "decode %.1f ms", $0) }),
            (metrics.bitrate, bitrateText),
            (metrics.packetLoss, String(format: "loss %.1f%%", lossPercent)),
            (metrics.resolution, resolution),
            (metrics.codec, codec),
            (metrics.gpu, gpu),
            (metrics.location, server),
        ]
        return items.compactMap { $0.enabled ? $0.text : nil }
    }

    var bitrateText: String? {
        bitrateKbps.map { String(format: "%.1f Mbps", Double($0) / 1000) }
    }
}

extension StreamStatsMetrics {
    /// The TV's strip: every figure that changes during a stream. Codec, GPU and server stay the
    /// same for the whole session and are in the stream menu, so they start off.
    static var tvDefault: StreamStatsMetrics {
        var metrics = StreamStatsMetrics()
        metrics.fps = true
        metrics.ping = true
        metrics.latency = true
        metrics.bitrate = true
        metrics.packetLoss = true
        metrics.resolution = true
        metrics.battery = false
        metrics.connection = false
        return metrics
    }

    /// How many of the enabled metrics a TV can show. Battery, network type, the display's own
    /// refresh rate and the renderer status belong to the iOS stream screen.
    var tvEnabledCount: Int {
        [fps, ping, latency, bitrate, packetLoss, resolution, codec, gpu, location].filter { $0 }.count
    }
}

extension ProcessInfo.ThermalState {
    /// The Apple TV's own temperature, as the stream menu words it.
    var tvLabel: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Too hot"
        @unknown default: "Unknown"
        }
    }

    /// Shown over the game only from "serious", where tvOS starts slowing the device down and
    /// frames can drop; below that it says nothing worth the space.
    var tvHUDText: String? {
        switch self {
        case .nominal, .fair: nil
        default: "Apple TV \(tvLabel.lowercased())"
        }
    }
}
