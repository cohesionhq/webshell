import Foundation

extension WebAssets {
    /// The build the daemon at `route` serves: the cached copy when the hash
    /// in its `hello` matches one, else fetched with `webBundle` over the
    /// same session.
    static func load(from route: DaemonRoute) async throws -> WebAssets {
        let connection = try route.connect()
        defer { connection.close() }
        var frames = connection.frames.makeAsyncIterator()
        guard let first = try await frames.next() else { throw ConnectionError.disconnected("Cohesion closed the session.") }
        let hello = try JSONDecoder().decode(HelloFrame.self, from: Data(first.utf8))
        guard let hash = hello.webBundleHash else { throw WebUIError.noWebUI }
        if let cached = await cached(hash) { return cached }

        try await connection.send(#"{"id":\#(BundleReply.id),"type":"webBundle"}"#)
        while let text = try await frames.next() {
            let data = Data(text.utf8)
            let header = try JSONDecoder().decode(FrameHeader.self, from: data)
            guard header.type == "reply", header.id == BundleReply.id else { continue }
            let reply = try JSONDecoder().decode(BundleReply.self, from: data)
            if let error = reply.error { throw ConnectionError.refused(error.message) }
            guard let ok = reply.ok else { throw WebUIError.malformed }
            return try await unpack(ok.data)
        }
        throw ConnectionError.disconnected("Cohesion closed the session.")
    }
}

/// The parts of a session's first frame (`Hello`) the loader reads.
private nonisolated struct HelloFrame: Decodable {
    /// `nil` when the daemon was built without the UI.
    let webBundleHash: String?

    private enum CodingKeys: String, CodingKey {
        case webBundleHash = "web_bundle_hash"
    }
}

/// What kind of frame one is, and which request a reply answers.
private nonisolated struct FrameHeader: Decodable {
    let type: String
    let id: Int?
}

/// The reply to `webBundle`.
private nonisolated struct BundleReply: Decodable {
    static let id = 1

    struct Ok: Decodable {
        let data: WebBundle
    }

    struct Refusal: Decodable {
        let message: String
    }

    let ok: Ok?
    let error: Refusal?
}
