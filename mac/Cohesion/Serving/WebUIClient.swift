import Foundation
import Observation

/// Loads the web UI from a daemon and holds the session showing it.
/// `CohesionWebUI` drives it from a route; an app keeps one for each window.
@Observable
final class WebUIClient {
    /// Where the web UI stands.
    enum State {
        case loading
        /// There is no pairing, or the server no longer trusts it.
        case unpaired
        case ready(WebUISession)
        case failed(String)
    }

    /// How many times, a second apart, to try reaching a cohesiond that may
    /// only just have started, or a server elsewhere before the network is
    /// up. At login, cohesiond settles its agents before it opens its socket.
    private static let attempts = 30

    private(set) var state = State.loading
    /// Bumped by `retry()`, which loads again.
    private(set) var generation = 0

    init() {}

    /// Loads again after a failure.
    func retry() {
        generation += 1
    }

    /// Drops the session, as when its window closes.
    func stop() {
        state = .loading
    }

    /// Loads the UI for `route`, unless it is already showing for it, trying
    /// again while the daemon can't be reached. Runs until it settles or is
    /// cancelled.
    func load(_ route: DaemonRoute?) async {
        guard let route else {
            state = .unpaired
            return
        }
        if case .ready(let session) = state, session.route == route { return }
        state = .loading
        var attempt = 1
        while !Task.isCancelled {
            do {
                let assets = try await WebAssets.load(from: route)
                guard !Task.isCancelled else { return }
                state = .ready(WebUISession(route: route, assets: assets))
                return
            } catch ConnectionError.unpaired {
                state = .unpaired
                return
            } catch let error as WebUIError {
                state = .failed(error.localizedDescription)
                return
            } catch {
                guard attempt < Self.attempts else {
                    state = .failed(error.localizedDescription)
                    return
                }
                attempt += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
