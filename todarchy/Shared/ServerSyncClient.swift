import Foundation

/// HTTP client for the todarchy relay server (see `TODARCHY_SERVER_PROMPT.md`).
///
/// ## Semantics
/// - **PUT is unconditional.** The product choice is "local-first — always
///   overwrite the server", so we never send `If-Match` and never 412.
///   Before pushing, callers should pull + merge via Automerge to integrate
///   concurrent peer changes; after pushing, the latest local-merged state
///   wins.
/// - **GET uses conditional caching.** After a successful fetch we remember
///   the strong ETag and send it on the next GET as `If-None-Match`. On
///   `304` we return `nil` — caller keeps its current bytes.
/// - **404 maps to nil** on GET/HEAD. A missing doc is "no remote yet",
///   not an error.
///
/// The server handles `application/octet-stream` ciphertext exclusively;
/// it never parses or decrypts the bytes.
final class ServerSyncClient: @unchecked Sendable {
    let baseURL: URL
    private let session: URLSession

    /// Last observed strong ETag per doc id. Updated on successful GETs and
    /// PUTs. Used to populate `If-None-Match` on subsequent GETs. Access is
    /// serialized by `etagQueue` because URLSession completion handlers fire
    /// on the session's delegate queue.
    private var etagCache: [String: String] = [:]
    private let etagQueue = DispatchQueue(label: "todarchy.serverSyncClient.etag")

    enum ClientError: Error, LocalizedError, Equatable {
        case invalidResponse
        case http(status: Int, code: String?, message: String?)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Server returned a response we couldn't interpret."
            case .http(let status, let code, let message):
                if let code, let message { return "Server error \(status): \(code) — \(message)" }
                if let message          { return "Server error \(status): \(message)" }
                return "Server error \(status)"
            case .transport(let m):
                return "Network error: \(m)"
            }
        }
    }

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30          // GET read budget
            cfg.timeoutIntervalForResource = 300        // PUT upload budget (5 min)
            cfg.waitsForConnectivity = false
            cfg.httpAdditionalHeaders = ["User-Agent": "todarchy/0.1 (Swift client)"]
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Expose the ETag cache for tests & diagnostics. Thread-safe.
    func cachedETag(for docId: String) -> String? {
        etagQueue.sync { etagCache[docId] }
    }

    func setCachedETag(_ etag: String?, for docId: String) {
        etagQueue.sync {
            if let etag { etagCache[docId] = etag } else { etagCache.removeValue(forKey: docId) }
        }
    }

    // MARK: - Endpoints

    /// Liveness probe. Returns `true` on any 2xx, `false` otherwise.
    /// Never throws — a dead server is a UI-visible state, not an error.
    func healthz() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("healthz"))
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// GET /doc/:id. Returns `(bytes, etag)` on 200, `nil` on 304 or 404.
    /// Throws `ClientError.http` on any other non-2xx / non-304 / non-404.
    func get(_ docId: String) async throws -> (Data, etag: String)? {
        var req = URLRequest(url: docURL(docId))
        req.httpMethod = "GET"
        if let cached = cachedETag(for: docId) {
            req.setValue(cached, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            let etag = (http.value(forHTTPHeaderField: "ETag") ?? "").trimmingCharacters(in: .whitespaces)
            if !etag.isEmpty { setCachedETag(etag, for: docId) }
            return (data, etag)
        case 304:
            return nil
        case 404:
            setCachedETag(nil, for: docId)
            return nil
        default:
            throw makeHTTPError(status: http.statusCode, body: data)
        }
    }

    /// PUT /doc/:id with unconditional semantics (no `If-Match`).
    /// Returns the server's new ETag.
    @discardableResult
    func put(_ docId: String, _ bytes: Data) async throws -> String {
        var req = URLRequest(url: docURL(docId))
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = bytes

        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        switch http.statusCode {
        case 204, 200, 201:
            let etag = (http.value(forHTTPHeaderField: "ETag") ?? "").trimmingCharacters(in: .whitespaces)
            if !etag.isEmpty { setCachedETag(etag, for: docId) }
            return etag
        default:
            throw makeHTTPError(status: http.statusCode, body: data)
        }
    }

    /// DELETE /doc/:id. Idempotent per the spec.
    func delete(_ docId: String) async throws {
        var req = URLRequest(url: docURL(docId))
        req.httpMethod = "DELETE"
        let (data, response) = try await perform(req)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        switch http.statusCode {
        case 204, 200, 404:
            setCachedETag(nil, for: docId)
        default:
            throw makeHTTPError(status: http.statusCode, body: data)
        }
    }

    // MARK: - Internals

    private func docURL(_ docId: String) -> URL {
        // Avoid `appendingPathComponent` for the id itself — some ids may
        // include characters that URL escaping can alter. The server's
        // regex is `[A-Za-z0-9_\-]{1,64}` so standard pathComponent is
        // safe in practice, but we stay defensive for future additions.
        baseURL.appendingPathComponent("doc").appendingPathComponent(docId)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
    }

    /// Build an HTTP error from the JSON body shape the server documents:
    /// `{"error":"<code>","message":"<detail>"}`. Tolerant to a missing or
    /// non-JSON body — the caller still gets a useful status code.
    private func makeHTTPError(status: Int, body: Data) -> ClientError {
        struct Envelope: Decodable {
            let error: String?
            let message: String?
        }
        guard !body.isEmpty,
              let env = try? JSONDecoder().decode(Envelope.self, from: body) else {
            return .http(status: status, code: nil, message: nil)
        }
        return .http(status: status, code: env.error, message: env.message)
    }
}
