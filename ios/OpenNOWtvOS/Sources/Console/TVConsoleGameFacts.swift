import SwiftUI

/// Facts the console pages show beside a game's title: when it was last played, how long it was
/// played on this Apple TV, the tier it needs, and the account's playtime left. Pure text rules,
/// shared by Home, game details, Library, Store and the top bar.
enum TVConsoleGameFacts {
    /// "Played today", "Played yesterday", "Played 3 days ago", else "Played 3 Oct 2026".
    static func lastPlayed(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        switch days {
        case ..<1: return "Played today"
        case 1: return "Played yesterday"
        case 2..<7: return "Played \(days) days ago"
        default: return "Played \(date.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    /// "12 h 40 m", "2 h", "48 min"; `nil` under a minute.
    static func playtime(_ seconds: TimeInterval) -> String? {
        let minutes = Int(seconds / 60)
        guard minutes > 0 else { return nil }
        let hours = minutes / 60
        if hours == 0 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) m"
    }

    /// "Needs Ultimate" for a game with a membership tier requirement.
    static func tierRequirement(_ label: String?) -> String? {
        guard let label else { return nil }
        let tier = gameMetadataDisplayLabel(label)
        return tier.isEmpty ? nil : "Needs \(tier)"
    }

    /// Release, play type, age rating, controls and the tier it needs: "2026 · Single-player · 12+".
    static func factsLine(_ game: CloudGame, options: [GameLaunchOption]) -> String {
        let controls = gameMetadataDisplayLabels(Array(Set(options.flatMap { $0.supportedControls ?? [] })).sorted())
        return [
            game.releaseDate ?? "",
            game.playType.map(gameMetadataDisplayLabel) ?? "",
            GFNContentRatingParser.ageBadge(from: game.contentRatings) ?? "",
            controls.joined(separator: ", "),
            tierRequirement(game.membershipTierLabel) ?? "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    /// The account's monthly playtime left: "12.5 h left", "40 h left", "35 min left". `nil` while
    /// the subscription is unknown, for unlimited accounts, and when it carries no allowance.
    static func playtimeLeft(_ subscription: SubscriptionSnapshot?) -> (text: String, isLow: Bool)? {
        guard let subscription, !subscription.isUnlimited, subscription.totalHours > 0 else { return nil }
        let hours = max(0, subscription.remainingHours)
        let text: String
        if hours < 1 {
            text = "\(Int((hours * 60).rounded())) min left"
        } else {
            let rounded = (hours * 10).rounded() / 10
            text = rounded == rounded.rounded()
                ? "\(Int(rounded)) h left"
                : "\(rounded.formatted(.number.precision(.fractionLength(1)))) h left"
        }
        return (text, hours <= 2)
    }
}

extension OpenNOWStore {
    /// Time played of `game` on this Apple TV, from the local session history.
    func consolePlaytime(of game: CloudGame) -> String? {
        TVConsoleGameFacts.playtime(StreamSessionRecord.playedDuration(of: game.title, in: sessionHistory.records))
    }
}

/// A game's feature badges (RTX, HDR, Reflex) as small chips.
struct TVConsoleFeatureChips: View {
    let labels: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels, id: \.self) { label in
                Text(label.uppercased())
                    .font(TVConsoleTheme.mono(12, bold: true))
                    .tracking(0.8)
                    .foregroundStyle(TVConsoleTheme.label)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(TVConsoleTheme.face.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(TVConsoleTheme.seam, lineWidth: 1))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(labels.joined(separator: ", "))
    }
}
