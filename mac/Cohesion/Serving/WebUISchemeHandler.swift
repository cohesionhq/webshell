import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the web UI at the root of `cohesion://app/`, as `cohesion open`
/// serves it on loopback: each file at `/<path>` with a matching
/// `Content-Type`, `index.html` for any other path, and `GET /client` for
/// a page that presents the session's token.
nonisolated struct WebUISchemeHandler: URLSchemeHandler {
    static let scheme = "cohesion"
    static let origin = URL(string: "\(scheme)://app/")!

    let assets: WebAssets
    let token: String
    let target: String

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        let (response, body) = answer(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(response))
            continuation.yield(.data(body))
            continuation.finish()
        }
    }

    private func answer(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        let url = request.url ?? Self.origin
        let path = String(url.path(percentEncoded: false).drop(while: { $0 == "/" }))
        if path == "client" {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else {
                return respond(url, status: 401, type: "text/plain", body: Data("missing or wrong launch token".utf8))
            }
            let info = ClientInfo(workspace: nil, target: target)
            return respond(url, status: 200, type: "application/json", body: (try? JSONEncoder().encode(info)) ?? Data())
        }
        guard let (path, data) = assets.file(at: path) else {
            return respond(url, status: 404, type: "text/plain", body: Data("the web UI has no index.html".utf8))
        }
        let type = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        // SvelteKit content-hashes everything under `_app/immutable/`.
        let cache = path.hasPrefix("_app/immutable/") ? "public, max-age=31536000, immutable" : "no-cache"
        return respond(url, status: 200, type: type, cache: cache, body: data)
    }

    private func respond(_ url: URL, status: Int, type: String, cache: String = "no-store", body: Data) -> (HTTPURLResponse, Data) {
        let headers = [
            "Content-Type": type,
            "Content-Length": String(body.count),
            "Cache-Control": cache,
        ]
        return (HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, body)
    }
}

/// What `/client` tells the UI about the client it runs behind. The app
/// keeps no workspace of its own, so the UI picks one as it does in a browser.
private nonisolated struct ClientInfo: Encodable {
    let workspace: Int?
    let target: String

    private enum CodingKeys: String, CodingKey {
        case workspace, target
    }

    /// Writes `"workspace": null` rather than leaving it out.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(target, forKey: .target)
    }
}
