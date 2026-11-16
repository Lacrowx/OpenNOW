import Foundation

/// One section of the "Filter & sort" panel: a titled list of options with one in effect.
struct TVConsoleFilterSection: Identifiable, Equatable {
    enum Kind: String {
        case sort, store, genre, show
    }

    let kind: Kind
    let title: String
    let options: [String]
    let selection: Int

    var id: Kind { kind }
    /// Label of the option in effect, shown under the section title.
    var value: String { options[selection] }
}

/// What the Library and Store pages are narrowed and ordered by. The two pages give the sort and
/// show indices their own meaning; store and genre are kept by value so they survive the option
/// lists changing while the catalog loads.
struct TVConsoleCatalogFilter: Equatable {
    var sort = 0
    var storefront: String?
    var genre: String?
    var show = 0

    /// Narrowing is in effect (sorting alone does not hide games).
    var isNarrowed: Bool { storefront != nil || genre != nil || show != 0 }

    /// The panel's sections. `stores` are storefront keys, labelled through `storeLabel`.
    func sections(sortLabels: [String], stores: [String], genres: [String], showLabels: [String],
                  storeLabel: (String) -> String) -> [TVConsoleFilterSection] {
        let stores = Self.options(stores, keeping: storefront)
        let genres = Self.options(genres, keeping: genre)
        return [
            TVConsoleFilterSection(kind: .sort, title: "Sort", options: sortLabels,
                                   selection: min(sort, sortLabels.count - 1)),
            TVConsoleFilterSection(kind: .store, title: "Store", options: ["All stores"] + stores.map(storeLabel),
                                   selection: storefront.flatMap(stores.firstIndex).map { $0 + 1 } ?? 0),
            TVConsoleFilterSection(kind: .genre, title: "Genre", options: ["All genres"] + genres,
                                   selection: genre.flatMap(genres.firstIndex).map { $0 + 1 } ?? 0),
            TVConsoleFilterSection(kind: .show, title: "Show", options: showLabels,
                                   selection: min(show, showLabels.count - 1)),
        ]
    }

    /// Applies the option at `index` of a section built by `sections` from the same lists.
    mutating func choose(_ index: Int, in kind: TVConsoleFilterSection.Kind, stores: [String], genres: [String]) {
        switch kind {
        case .sort: sort = index
        case .store: storefront = Self.value(at: index, of: Self.options(stores, keeping: storefront))
        case .genre: genre = Self.value(at: index, of: Self.options(genres, keeping: genre))
        case .show: show = index
        }
    }

    /// The line beside "Filter & sort": the show choice when it narrows, then store, genre, sort.
    static func summary(of sections: [TVConsoleFilterSection]) -> String {
        let order: [TVConsoleFilterSection.Kind] = [.show, .store, .genre, .sort]
        return order.compactMap { kind in sections.first { $0.kind == kind } }
            .filter { $0.kind != .show || $0.selection != 0 }
            .map(\.value)
            .joined(separator: " · ")
    }

    /// A choice in effect stays selectable even when the reloaded catalog no longer lists it.
    private static func options(_ options: [String], keeping selected: String?) -> [String] {
        guard let selected, !options.contains(selected) else { return options }
        return options + [selected]
    }

    /// Index 0 is "All"; the values follow it.
    private static func value(at index: Int, of options: [String]) -> String? {
        options.indices.contains(index - 1) ? options[index - 1] : nil
    }
}
