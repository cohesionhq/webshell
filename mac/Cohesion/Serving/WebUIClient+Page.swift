import WebKit

extension WebUIClient {
    /// The page's title, for its window, or the app's name until it has one.
    var title: String {
        guard let title = page?.title, !title.isEmpty else { return "Cohesion" }
        return title
    }

    /// The page showing, once loaded.
    private var page: WebPage? {
        guard case .ready(let session) = state else { return nil }
        return session.page
    }
}
