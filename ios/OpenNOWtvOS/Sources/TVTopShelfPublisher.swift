import SwiftUI
import TVServices

extension TVTopShelfSnapshot {
    /// The running game first, then the recently played ones; empty while signed out.
    @MainActor
    static func current(in store: OpenNOWStore) -> TVTopShelfSnapshot {
        guard store.user != nil else { return .empty }
        let running = store.activeSession?.game
            ?? store.primaryRemoteJumpBackSession.flatMap(store.gameForRemoteSession)
        let recent = store.catalogPresentation.recentGames
            .filter { $0.id != running?.id }
            .prefix(recentLimit)
            .compactMap { game in link("launch", game.id).map { item(game, link: $0) } }
        return TVTopShelfSnapshot(playing: running.flatMap { game in link("resume").map { item(game, link: $0) } },
                                  recent: Array(recent))
    }

    /// The app's own deep links (`OpenNOWStore.handleIncomingURL`): `opennow://launch/<game id>`
    /// starts a game and `opennow://resume` returns to the running session.
    private static func link(_ action: String, _ id: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "opennow"
        components.host = action
        if let id { components.path = "/" + id }
        return components.url
    }

    /// The artwork of a wide Home tile, which is 16:9 like a Top Shelf item.
    private static func item(_ game: CloudGame, link: URL) -> Item {
        Item(id: game.id, title: game.title,
             imageURL: (game.heroImageUrl ?? game.tvBannerUrl ?? game.catalogArtworkUrl).flatMap(URL.init(string:)),
             link: link)
    }
}

/// Keeps the Top Shelf in step with the store. Drawn behind the app's root view, so only this
/// view is re-evaluated when the store changes.
struct TVTopShelfPublisher: View {
    @ObservedObject var store: OpenNOWStore

    var body: some View {
        Color.clear
            .onChange(of: TVTopShelfSnapshot.current(in: store), initial: true) { _, snapshot in
                if snapshot.save() { TVTopShelfContentProvider.topShelfContentDidChange() }
            }
    }
}
