import Foundation
import Network
import Security
import UIKit

/// Experimental: turns a TCL Google TV's "Game Master" on for the HDMI input the Apple TV is on
/// while a stream plays, and puts the input's own setting back afterwards.
///
/// Apple TV sends neither ALLM nor VRR, so the TV's Auto setting never fires. The TV is reached
/// over Android wireless debugging, which it announces over Bonjour; its port changes whenever
/// wireless debugging restarts. The app's key has to be approved on the TV once, through the
/// classic debugging port (5555), which a computer opens with `adb tcpip 5555`.
///
/// Game Master is TCL's `ITvDisplayManagerService.setGameModeConfig(source, value, act)`
/// (transaction 159; 160 reads it back). Sources: HDMI 1-4 = 8-11. Values: Off 0, On 1, Auto 2.
/// The settings menu also mirrors the value in `Settings.Global GAME_MODE_HDMI_<n>`, mapped
/// Auto 0, On 1, Off 2; writing both, as the menu does, keeps the menu showing the change.
enum TVGameMaster {
    enum Mode: Int32, CaseIterable {
        case off = 0, on = 1, auto = 2

        var label: String {
            switch self {
            case .off: "Off"
            case .on: "On"
            case .auto: "Auto"
            }
        }

        /// The value the TV's settings menu stores for this mode.
        var menuValue: Int {
            switch self {
            case .auto: 0
            case .on: 1
            case .off: 2
            }
        }
    }

    /// An HDMI input, numbered as on the TV (1-4).
    struct Input: Equatable {
        let number: Int
        /// The TV's input device id, as `tcl_sys_tv_input_current_device_id` reports it (15-18).
        init?(deviceID: Int) {
            guard (15...18).contains(deviceID) else { return nil }
            number = deviceID - 14
        }
        init?(number: Int) {
            guard (1...4).contains(number) else { return nil }
            self.number = number
        }
        /// TCL's picture-quality input source enum.
        var source: Int { number + 7 }
    }

    static let currentInputCommand = "settings get secure tcl_sys_tv_input_current_device_id"

    static func readCommand(_ input: Input) -> String { "service call tcl_tv_display 160 i32 \(input.source)" }

    /// Applies and saves (act 2) the mode, then mirrors it where the menu reads it.
    static func writeCommand(_ input: Input, _ mode: Mode) -> String {
        "service call tcl_tv_display 159 i32 \(input.source) i32 \(mode.rawValue) i32 2"
            + " && settings put global GAME_MODE_HDMI_\(input.number) \(mode.menuValue)"
    }

    /// The int a `service call` returned, from output like
    /// `Result: Parcel(00000000 00000002   '........')`; nil when the call raised an exception.
    static func parcelInt(_ output: String) -> Int32? {
        guard let open = output.range(of: "Parcel(") else { return nil }
        let words = output[open.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard words.count >= 2, words[0] == "00000000", let value = UInt32(words[1], radix: 16) else { return nil }
        return Int32(bitPattern: value)
    }

    // MARK: - Settings

    private static let defaults = UserDefaults.standard
    private static let enabledKey = "tvGameMasterEnabled"
    /// [input number, mode] to put back; survives a crash or a stream closed while suspended.
    private static let pendingRestoreKey = "tvGameMasterPendingRestore"

    static var enabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    // MARK: - Lifecycle

    /// What keeps Game Master on. Switching it makes the TV re-plug HDMI (it turns VRR on), which
    /// loses a display mode switch made at the same moment and froze a starting stream's picture.
    /// So it goes on as the launch begins, during the queue, and stays on across the hand-over to
    /// the stream; it goes back `releaseGrace` after the last hold ends.
    enum Hold { case launch, stream }

    private static var holds: Set<Hold> = []
    private static var pendingRelease: DispatchWorkItem?
    private static let releaseGrace: TimeInterval = 10

    /// At launch: puts back a setting a previous run left changed.
    static func start() {
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                   object: nil, queue: .main) { _ in
            // A suspended app runs no timers: release now rather than at the next launch.
            pendingRelease?.perform()
        }
        guard pendingRestore != nil else { return }
        perform("restore after relaunch") { link in try restore(link) }
    }

    static func hold(_ hold: Hold) {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingRelease?.cancel()
        pendingRelease = nil
        let first = holds.isEmpty
        holds.insert(hold)
        if first { engage() }
    }

    static func release(_ hold: Hold) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard holds.remove(hold) != nil, holds.isEmpty else { return }
        let work = DispatchWorkItem {
            pendingRelease = nil
            guard holds.isEmpty else { return }
            disengage()
        }
        pendingRelease = work
        if UIApplication.shared.applicationState == .background {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + releaseGrace, execute: work)
        }
    }

    private static func engage() {
        guard enabled, TVGameMasterKey.stored() != nil else { return }
        perform("switch on") { link in
            // A restore still pending (the TV was off at the end of the last stream) comes first.
            if pendingRestore != nil { try restore(link) }
            let input = try currentInput(link)
            let mode = try read(input, link)
            guard mode != .on else {
                TVStreamLog.note("Game Master already On for HDMI \(input.number)")
                return
            }
            setPendingRestore(input, mode)
            try write(input, .on, link)
            TVStreamLog.note("Game Master On for HDMI \(input.number) (was \(mode.label))")
        }
    }

    private static func disengage() {
        guard pendingRestore != nil else { return }
        perform("switch back") { link in try restore(link) }
    }

    private static func restore(_ link: TVGameMasterLink) throws {
        guard let (input, mode) = pendingRestore else { return }
        try write(input, mode, link)
        defaults.removeObject(forKey: pendingRestoreKey)
        TVStreamLog.note("Game Master back to \(mode.label) for HDMI \(input.number)")
    }

    private static var pendingRestore: (Input, Mode)? {
        guard let saved = defaults.array(forKey: pendingRestoreKey) as? [Int], saved.count == 2,
              let input = Input(number: saved[0]), let mode = Mode(rawValue: Int32(saved[1])) else { return nil }
        return (input, mode)
    }

    private static func setPendingRestore(_ input: Input, _ mode: Mode) {
        defaults.set([input.number, Int(mode.rawValue)], forKey: pendingRestoreKey)
    }

    /// Runs TV work in order on the link's queue, under a background task so a stream closed from
    /// the Home screen can still put the setting back. Failures are logged; the stream never waits.
    private static func perform(_ what: String, _ work: @escaping @Sendable (TVGameMasterLink) throws -> Void) {
        let application = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = application.beginBackgroundTask(withName: "OpenNOW Game Master") {
            application.endBackgroundTask(task)
            task = .invalid
        }
        TVGameMasterLink.shared.queue.async {
            do {
                try work(TVGameMasterLink.shared)
            } catch {
                TVStreamLog.note("Game Master \(what) failed: \(error)")
                tvStreamDebug("[TVStream] Game Master \(what) failed: \(error)")
            }
            DispatchQueue.main.async {
                if task != .invalid { application.endBackgroundTask(task) }
            }
        }
    }

    // MARK: - TV commands

    enum Failure: Error, CustomStringConvertible {
        case notOnHDMI(String)
        case unexpectedOutput(String)

        var description: String {
            switch self {
            case .notOnHDMI(let id): "the TV is not showing an HDMI input (device \(id))"
            case .unexpectedOutput(let output): "unexpected TV output: \(output)"
            }
        }
    }

    static func currentInput(_ link: TVGameMasterLink) throws -> Input {
        let output = try link.run(currentInputCommand).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let input = Int(output).flatMap(Input.init(deviceID:)) else { throw Failure.notOnHDMI(output) }
        return input
    }

    static func read(_ input: Input, _ link: TVGameMasterLink) throws -> Mode {
        let output = try link.run(readCommand(input))
        guard let mode = parcelInt(output).flatMap(Mode.init(rawValue:)) else { throw Failure.unexpectedOutput(output) }
        return mode
    }

    private static func write(_ input: Input, _ mode: Mode, _ link: TVGameMasterLink) throws {
        let output = try link.run(writeCommand(input, mode))
        guard parcelInt(output) == 1 else { throw Failure.unexpectedOutput(output) }
    }
}

/// Finds the TV and keeps one connection open between uses. All work runs on `queue`.
///
/// The TV's Bonjour announcement is not dependable (it stopped after adbd restarted for port
/// 5555), so the last address and wireless-debugging port that worked are remembered and tried
/// first; the search follows, then the classic port 5555 at the remembered address.
final class TVGameMasterLink: @unchecked Sendable {
    static let shared = TVGameMasterLink()
    static let serviceType = "_adb-tls-connect._tcp"
    static let classicPort: UInt16 = 5555

    let queue = DispatchQueue(label: "OpenNOW.GameMaster")
    private var connection: TVAdbConnection?

    private static let defaults = UserDefaults.standard
    private static let hostKey = "tvGameMasterHost"
    private static let portKey = "tvGameMasterPort"

    /// The TV's IPv4 address, found by the search or typed in Settings.
    static var host: String? {
        get { defaults.string(forKey: hostKey) }
        set {
            defaults.set(newValue, forKey: hostKey)
            defaults.removeObject(forKey: portKey)
        }
    }

    private static var tlsPort: UInt16? {
        get { (defaults.object(forKey: portKey) as? Int).flatMap(UInt16.init(exactly:)) }
        set { defaults.set(newValue.map { Int($0) }, forKey: portKey) }
    }

    enum Failure: Error, CustomStringConvertible {
        case noKey
        case notFound
        case portClosed

        var description: String {
            switch self {
            case .noKey: "no key has been set up"
            case .notFound: "the TV was not found"
            case .portClosed: "port 5555 is closed"
            }
        }
    }

    /// Runs a command over the open connection, reconnecting (and finding the TV again, since its
    /// port may have changed) once when that fails.
    func run(_ command: String) throws -> String {
        dispatchPrecondition(condition: .onQueue(queue))
        if let connection, let output = try? connection.run(command) { return output }
        connection = nil
        let connection = try connect()
        self.connection = connection
        return try connection.run(command)
    }

    /// Makes sure the TV accepts the app's key, asking for approval through port 5555 when it does
    /// not. `waiting` is called before the TV shows its prompt.
    func approve(waiting: @escaping @Sendable () -> Void) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        connection = nil
        do {
            connection = try connect()
            return
        } catch TVAdbConnection.Failure.notApproved {}
        guard let host = Self.host, let key = TVGameMasterKey.stored() else { throw Failure.noKey }
        waiting()
        do {
            connection = try TVAdbConnection.open(host: host, port: Self.classicPort, key: key,
                                                  authorization: .requestApproval(wait: 60))
        } catch TVAdbConnection.Failure.unreachable {
            throw Failure.portClosed
        }
    }

    private static func log(_ message: String) {
        TVStreamLog.note("Game Master: \(message)")
        tvStreamDebug("[TVStream] Game Master: \(message)")
    }

    /// Tries the remembered wireless-debugging port, then a search, then port 5555. Throws
    /// `notApproved` when a TV answered but does not know the key.
    private func connect() throws -> TVAdbConnection {
        guard let key = TVGameMasterKey.stored() else { throw Failure.noKey }
        var refused: Error?
        func attempt(_ host: String, _ port: UInt16) -> TVAdbConnection? {
            do {
                let connection = try TVAdbConnection.open(host: host, port: port, key: key, authorization: .knownKeyOnly)
                Self.log("connected to \(host):\(port)")
                return connection
            } catch {
                Self.log("\(host):\(port) failed: \(error)")
                if case TVAdbConnection.Failure.notApproved = error { refused = error }
                return nil
            }
        }
        if let host = Self.host, let port = Self.tlsPort, let connection = attempt(host, port) { return connection }
        if let (host, port) = discover() {
            Self.host = host
            Self.tlsPort = port
            if let connection = attempt(host, port) { return connection }
        }
        if let host = Self.host, let connection = attempt(host, Self.classicPort) { return connection }
        throw refused ?? Failure.notFound
    }

    /// The first wireless-debugging service on the network, as its host name and port.
    private func discover(timeout: TimeInterval = 4) -> (String, UInt16)? {
        let deadline = Date().addingTimeInterval(timeout)
        guard let service = browse(timeout: timeout) else {
            Self.log("no wireless debugging service found")
            return nil
        }
        let result = TVBonjourResolver.resolve(name: service.name, type: service.type, domain: service.domain,
                                               timeout: max(1, deadline.timeIntervalSinceNow))
        Self.log("\(service.name) resolved to \(result.map { "\($0.0):\($0.1)" } ?? "nothing")")
        return result
    }

    private struct Service {
        let name: String
        let type: String
        let domain: String
    }

    private func browse(timeout: TimeInterval) -> Service? {
        let found = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var service: Service?
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { state in
            if case .failed = state { Self.log("browser \(state)") }
            if case .waiting = state { Self.log("browser \(state)") }
        }
        browser.browseResultsChangedHandler = { results, _ in
            lock.lock(); defer { lock.unlock() }
            guard service == nil else { return }
            for result in results {
                guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
                service = Service(name: name, type: type, domain: domain)
                found.signal()
                return
            }
        }
        browser.start(queue: .global())
        _ = found.wait(timeout: .now() + timeout)
        browser.cancel()
        lock.lock(); defer { lock.unlock() }
        return service
    }
}

/// The app's adb key, kept in the keychain on this Apple TV only.
enum TVGameMasterKey {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "OpenNOW.TVGameMaster",
        kSecAttrAccount as String: "adbkey",
    ]

    static func stored() -> TVAdbKey? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? TVAdbKey(der: data)
    }

    /// The stored key, or a new one stored now.
    static func ensure() throws -> TVAdbKey {
        if let key = stored() { return key }
        let key = try TVAdbKey()
        var item = query
        item[kSecValueData as String] = try key.derRepresentation()
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return key
    }

    static func remove() { SecItemDelete(query as CFDictionary) }
}
