import Foundation
import SwiftUI

/// A published release of the Apple TV port on GitHub (tags `tvos-v<version>`).
struct TVRelease: Equatable, Codable {
    let version: String
    let name: String
    let url: URL

    static let repository = "Lacrowx/OpenNOW"
    static let tagPrefix = "tvos-v"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    /// What updates an installed copy, as the fork's README gives it.
    static let updateCommand = "cd OpenNOW-AppleTV && git pull && sh ios/OpenNOWtvOS/BuildScripts/install.sh"

    /// The newest full release in a GitHub `releases` listing; drafts, pre-releases and tags of
    /// other products (the desktop app's `v*` tags) are skipped.
    static func newest(inListing data: Data) -> TVRelease? {
        struct Entry: Decodable {
            let tag_name: String
            let name: String?
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        return entries
            .filter { !$0.draft && !$0.prerelease && $0.tag_name.hasPrefix(tagPrefix) }
            .map { entry in
                let version = String(entry.tag_name.dropFirst(tagPrefix.count))
                let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                return TVRelease(version: version, name: name?.isEmpty == false ? name! : "OpenNOW \(version)",
                                 url: entry.html_url)
            }
            .max { isVersion($1.version, newerThan: $0.version) }
    }

    /// Compares dotted versions numerically ("1.1.200" is newer than "1.1.191"); a missing part
    /// counts as 0 and a part that is not a number as 0.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] { version.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Asks GitHub, at most twice a day, whether a newer release of the Apple TV port is out. The
/// request carries no account or device data. Settings → About shows the result and can turn
/// the check off.
@MainActor
final class TVReleaseChecker: ObservableObject {
    static let shared = TVReleaseChecker()

    enum Status: Equatable {
        case idle, checking, checked, failed
    }

    /// The newer release, while there is one.
    @Published private(set) var available: TVRelease?
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date?
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Keys.enabled)
            if !enabled { available = nil; status = .idle }
        }
    }

    let installedVersion: String
    private let defaults: UserDefaults
    private static let interval: TimeInterval = 12 * 3600

    private enum Keys {
        static let enabled = "tvReleaseCheckEnabled"
        static let lastChecked = "tvReleaseCheckLastChecked"
        static let newest = "tvReleaseCheckNewest"
    }

    init(defaults: UserDefaults = .standard,
         installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.defaults = defaults
        self.installedVersion = installedVersion
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
        // The last answer counts until the next check, so the badge shows without a request.
        if enabled, let data = defaults.data(forKey: Keys.newest),
           let newest = try? JSONDecoder().decode(TVRelease.self, from: data) {
            apply(newest)
        }
    }

    /// Checks when the last check is older than the interval.
    func checkIfDue(now: Date = Date()) async {
        guard enabled, status != .checking else { return }
        if let lastChecked, now.timeIntervalSince(lastChecked) < Self.interval { return }
        await check(now: now)
    }

    func check(now: Date = Date()) async {
        guard enabled, status != .checking else { return }
        status = .checking
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(TVRelease.repository)/releases?per_page=20")!,
            timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenNOW-tvOS", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { status = .failed; return }
            let newest = TVRelease.newest(inListing: data)
            lastChecked = now
            defaults.set(now, forKey: Keys.lastChecked)
            defaults.set(newest.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.newest)
            apply(newest)
        } catch {
            status = .failed
        }
    }

    private func apply(_ newest: TVRelease?) {
        if let newest, TVRelease.isVersion(newest.version, newerThan: installedVersion) {
            available = newest
        } else {
            available = nil
        }
        status = .checked
    }

    #if DEBUG
    /// `--opennow-update-preview`: a newer release, without asking GitHub.
    func installPreview() {
        available = TVRelease(version: "1.2.0", name: "OpenNOW for Apple TV 1.2.0", url: TVRelease.releasesPage)
        status = .checked
        lastChecked = Date()
    }
    #endif
}
