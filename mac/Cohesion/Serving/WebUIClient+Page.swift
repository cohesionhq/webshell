import WebKit

extension WebUIClient {
    /// The page's title, for its window, or the app's name until it has one.
    var title: String {
        guard let title = page?.title, !title.isEmpty else { return "Cohesion" }
        return title
    }

    /// The page showing, once loaded.
    var page: WebPage? {
        guard case .ready(let session) = state else { return nil }
        return session.page
    }
}

extension WebPage {
    /// Whether the page's history has an entry before the one showing.
    var canGoBack: Bool { !backForwardList.backList.isEmpty }

    /// Whether the page's history has an entry after the one showing.
    var canGoForward: Bool { !backForwardList.forwardList.isEmpty }

    /// Goes back one entry in the page's history, as the browser's Back does.
    func goBack() {
        go(to: backForwardList.backList.last)
    }

    /// Goes forward one entry in the page's history.
    func goForward() {
        go(to: backForwardList.forwardList.first)
    }

    private func go(to item: BackForwardList.Item?) {
        guard let item else { return }
        Task {
            do {
                for try await _ in load(item) {}
            } catch {
                // WebKit shows its own error page.
            }
        }
    }
}
