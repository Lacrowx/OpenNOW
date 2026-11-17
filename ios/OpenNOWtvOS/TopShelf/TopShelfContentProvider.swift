import TVServices

/// The Top Shelf above OpenNOW on the Apple TV Home screen: the game still running, then the
/// recently played games. The app keeps the snapshot current; selecting an item opens its link.
final class TopShelfContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let snapshot = TVTopShelfSnapshot.load()
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        if let playing = snapshot.playing {
            sections.append(Self.section("Playing Now", [playing]))
        }
        if !snapshot.recent.isEmpty {
            sections.append(Self.section("Recently Played", snapshot.recent))
        }
        // Nil keeps the static Top Shelf image, for a signed-out app or one that has not run yet.
        return sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections)
    }

    private static func section(_ title: String, _ items: [TVTopShelfSnapshot.Item])
        -> TVTopShelfItemCollection<TVTopShelfSectionedItem> {
        let collection = TVTopShelfItemCollection(items: items.map(item))
        collection.title = title
        return collection
    }

    private static func item(_ source: TVTopShelfSnapshot.Item) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: source.id)
        item.title = source.title
        item.imageShape = .hdtv
        if let url = source.imageURL { item.setImageURL(url, for: [.screenScale1x, .screenScale2x]) }
        item.displayAction = TVTopShelfAction(url: source.link)
        item.playAction = TVTopShelfAction(url: source.link)
        return item
    }
}
