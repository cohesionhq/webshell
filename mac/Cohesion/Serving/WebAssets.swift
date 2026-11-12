import Foundation

/// The web UI's build as cohesiond hands it out (`WebBundle` in
/// `cohesion-core/src/protocol/server_requests.rs`).
nonisolated struct WebBundle: Decodable, Sendable {
    struct File: Decodable, Sendable {
        /// Relative to the build's root, with `/` separators.
        let path: String
        /// The file's bytes as raw deflate; base64 on the wire, which
        /// `Data` decodes by default.
        let data: Data
    }

    let hash: String
    let files: [File]
}

/// Why the web UI couldn't be loaded, apart from the connection.
nonisolated enum WebUIError: LocalizedError {
    /// The daemon was built without `web/build/`.
    case noWebUI
    case malformed

    var errorDescription: String? {
        switch self {
        case .noWebUI: "This server wasn’t built with the web UI."
        case .malformed: "Couldn’t unpack the web UI."
        }
    }
}

/// Every file of one build of the web UI, held in memory, and kept unpacked
/// on disk in a directory named by the bundle's hash so a later launch
/// skips the download while the daemon's hash is unchanged. Only the newest
/// build is kept.
nonisolated struct WebAssets: Sendable {
    let hash: String
    private let files: [String: Data]

    /// The file at `path`, or `index.html` for any path the build doesn't
    /// have, so the UI's client-side routes load on refresh.
    func file(at path: String) -> (path: String, data: Data)? {
        if let data = files[path] { return (path, data) }
        return files["index.html"].map { ("index.html", $0) }
    }

    // MARK: - The cache

    /// `<hash>/manifest.json` lists the files under `<hash>/files/`; a build
    /// counts as cached once its manifest is written, which is last.
    private static var cacheDirectory: URL {
        URL.cachesDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "Cohesion")
            .appending(path: "WebUI")
    }

    /// The build with `hash`, if this app unpacked it before.
    @concurrent
    static func cached(_ hash: String) async -> WebAssets? {
        let directory = cacheDirectory.appending(path: hash)
        guard let manifest = try? Data(contentsOf: directory.appending(path: "manifest.json")),
              let paths = try? JSONDecoder().decode([String].self, from: manifest)
        else { return nil }
        var files: [String: Data] = [:]
        for path in paths {
            guard let data = try? Data(contentsOf: directory.appending(path: "files").appending(path: path)) else {
                return nil
            }
            files[path] = data
        }
        return WebAssets(hash: hash, files: files)
    }

    /// Inflates every file in `bundle` and caches the build in place of any other.
    @concurrent
    static func unpack(_ bundle: WebBundle) async throws(WebUIError) -> WebAssets {
        var files: [String: Data] = [:]
        for file in bundle.files {
            // Despite its name, `.zlib` is raw deflate.
            guard let data = try? (file.data as NSData).decompressed(using: .zlib) as Data else {
                throw .malformed
            }
            files[file.path] = data
        }
        let assets = WebAssets(hash: bundle.hash, files: files)
        // A build that can't be cached still serves.
        try? assets.save()
        return assets
    }

    private func save() throws {
        let manager = FileManager.default
        let root = Self.cacheDirectory
        let directory = root.appending(path: hash)
        try? manager.removeItem(at: root)
        for (path, data) in files {
            let url = directory.appending(path: "files").appending(path: path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try JSONEncoder().encode(Array(files.keys)).write(to: directory.appending(path: "manifest.json"))
    }
}
