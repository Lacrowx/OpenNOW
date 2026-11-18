import Foundation
import Combine

struct StreamSessionBattery: Codable, Equatable {
    private(set) var startPercent: Int?
    private(set) var currentPercent: Int?
    private(set) var includedCharging = false
    private(set) var charging = false

    mutating func record(percent: Int?, charging: Bool) {
        self.charging = charging
        includedCharging = includedCharging || charging
        guard let percent, (0...100).contains(percent) else { return }
        if startPercent == nil { startPercent = percent }
        currentPercent = percent
    }

    var change: Int? {
        guard let startPercent, let currentPercent else { return nil }
        return currentPercent - startPercent
    }

    var changeText: String {
        guard let change else { return "Unavailable" }
        if includedCharging || change > 0 { return "\(change > 0 ? "+" : "")\(change)% net" }
        return "\(max(0, -change))% used"
    }

    var summary: String {
        guard let currentPercent else { return "Unavailable" }
        return "\(currentPercent)% · \(changeText)\(charging ? " · Charging" : "")"
    }
}

struct StreamSessionRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let gameTitle: String
    let startedAt: Date
    var updatedAt: Date
    var endedAt: Date?
    var interrupted = false
    var battery = StreamSessionBattery()
    let resolution: String
    let targetFPS: Int
    let codec: String
    let hdr: Bool
    let transport: String

    init(gameTitle: String, resolution: String, targetFPS: Int, codec: String,
         hdr: Bool, transport: String, at date: Date = Date()) {
        id = UUID()
        self.gameTitle = gameTitle
        startedAt = date
        updatedAt = date
        self.resolution = resolution
        self.targetFPS = targetFPS
        self.codec = codec
        self.hdr = hdr
        self.transport = transport
    }

    var duration: TimeInterval { max(0, (endedAt ?? updatedAt).timeIntervalSince(startedAt)) }
    var durationText: String {
        let seconds = Int(duration)
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds / 60) % 60)m" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
    var status: String { endedAt == nil ? "Active" : interrupted ? "Interrupted" : "Ended" }

    /// Time played of the game called `title`, over `records`. Records keep only the title, so
    /// games are told apart by title, ignoring case and surrounding spaces.
    static func playedDuration(of title: String, in records: [StreamSessionRecord]) -> TimeInterval {
        let key = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return 0 }
        return records
            .filter { $0.gameTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key }
            .reduce(0) { $0 + $1.duration }
    }
}

/// Local history contains display metadata only, with bounded storage and periodic checkpoints.
@MainActor
final class StreamSessionHistoryStore: ObservableObject {
    @Published private(set) var records: [StreamSessionRecord]
    private let defaults: UserDefaults
    private let key = "OpenNOW.iOS.streamSessionHistory.v1"
    private var lastPersistedAt = Date.distantPast
    static let maximumRecords = 100
    #if DEBUG
    /// Set by `installDebugSamples()`: the sample records must never reach `defaults`.
    fileprivate var holdsSamples = false
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode([StreamSessionRecord].self, from: $0)
        } ?? []
        // A killed process cannot report an end time. Use its last saved checkpoint explicitly.
        for index in records.indices where records[index].endedAt == nil {
            records[index].endedAt = records[index].updatedAt
            records[index].interrupted = true
        }
        records = Array(records.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maximumRecords))
        persist()
    }

    func update(_ record: StreamSessionRecord, force: Bool = false) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
            records = Array(records.prefix(Self.maximumRecords))
        }
        if force || record.updatedAt.timeIntervalSince(lastPersistedAt) >= 30 { persist() }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where records.indices.contains(index) { records.remove(at: index) }
        persist()
    }

    private func persist() {
        #if DEBUG
        guard !holdsSamples else { return }
        #endif
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
        lastPersistedAt = Date()
    }
}

#if DEBUG
extension StreamSessionHistoryStore {
    /// Sample history for screenshots (`--opennow-shell-preview`); in memory only.
    func installDebugSamples() {
        func record(_ title: String, ago: TimeInterval, minutes: Double, resolution: String = "3840x2160",
                    fps: Int = 60, codec: String = "H.265", hdr: Bool = true) -> StreamSessionRecord {
            var record = StreamSessionRecord(
                gameTitle: title, resolution: resolution, targetFPS: fps, codec: codec,
                hdr: hdr, transport: "UDP", at: Date().addingTimeInterval(-ago))
            record.updatedAt = record.startedAt.addingTimeInterval(minutes * 60)
            return record
        }
        var finished = record("Cyberpunk 2077", ago: 86_400 * 2, minutes: 95)
        finished.endedAt = finished.updatedAt
        var interrupted = record("Baldur's Gate 3", ago: 86_400, minutes: 41, resolution: "2560x1440", hdr: false)
        interrupted.endedAt = interrupted.updatedAt
        interrupted.interrupted = true
        var shortRun = record("Fortnite", ago: 86_400 * 4, minutes: 12, resolution: "1920x1080", fps: 120,
                              codec: "H.264", hdr: false)
        shortRun.endedAt = shortRun.updatedAt
        var nightDrive = record("Night Drive", ago: 86_400 * 2 + 7_200, minutes: 132)
        nightDrive.endedAt = nightDrive.updatedAt
        var aimlabs = record("Aimlabs", ago: 86_400 * 3, minutes: 48, fps: 120)
        aimlabs.endedAt = aimlabs.updatedAt
        holdsSamples = true
        records = [record("Forza Horizon 5", ago: 25 * 60, minutes: 25), interrupted, finished, nightDrive,
                   aimlabs, shortRun]
    }
}
#endif
