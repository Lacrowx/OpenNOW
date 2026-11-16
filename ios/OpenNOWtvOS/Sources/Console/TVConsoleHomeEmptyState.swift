import Foundation

/// Why Home has no games to show, so it can say so instead of always claiming to be ready.
enum TVConsoleHomeEmptyState: Equatable {
    case loading, failed(String), ready

    init(isLoading: Bool, catalogError: String?) {
        if isLoading {
            self = .loading
        } else if let catalogError {
            self = .failed(catalogError)
        } else {
            self = .ready
        }
    }

    var title: String {
        switch self {
        case .loading: return "Loading your games"
        case .failed: return "Couldn’t load your games"
        case .ready: return "Your Home is ready"
        }
    }
}
