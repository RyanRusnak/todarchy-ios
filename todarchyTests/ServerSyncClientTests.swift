import XCTest

/// Unit tests for `ServerSyncClient` using a mock URLProtocol that
/// intercepts every request made through the injected URLSession. No
/// network traffic leaves the test process.
final class ServerSyncClientTests: XCTestCase {

    var session: URLSession!
    let baseURL = URL(string: "https://mock.example.com")!

    override func setUp() async throws {
        MockURLProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: cfg)
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        session = nil
    }

    // MARK: - PUT is always unconditional

    func testPutSendsNoIfMatch_alwaysOverwrites() async throws {
        MockURLProtocol.stub(path: "/doc/test123", method: "PUT") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "If-Match"),
                         "PUT must NEVER send If-Match — app is local-first, always overwrites")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                           "application/octet-stream")
            return MockResponse(status: 204, headers: ["ETag": "\"abc123\""], body: Data())
        }

        let client = ServerSyncClient(baseURL: baseURL, session: session)
        // Prime the etag cache to prove PUT ignores it.
        client.setCachedETag("\"stale-etag\"", for: "test123")

        let etag = try await client.put("test123", Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(etag, "\"abc123\"")
    }

    func testPutSecondTimeStillHasNoIfMatch() async throws {
        var seenIfMatch: [String?] = []
        MockURLProtocol.stub(path: "/doc/test123", method: "PUT") { request in
            seenIfMatch.append(request.value(forHTTPHeaderField: "If-Match"))
            return MockResponse(status: 204, headers: ["ETag": "\"\(seenIfMatch.count)\""], body: Data())
        }
        let client = ServerSyncClient(baseURL: baseURL, session: session)
        _ = try await client.put("test123", Data([0x01]))
        _ = try await client.put("test123", Data([0x02]))
        XCTAssertEqual(seenIfMatch, [nil, nil])
    }

    // MARK: - GET conditional fetch

    func testGetCachesEtagAndSendsItOnNextFetch() async throws {
        // First response: 200 + ETag.
        MockURLProtocol.stub(path: "/doc/test123", method: "GET") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            return MockResponse(status: 200,
                                 headers: ["ETag": "\"v1\""],
                                 body: Data([0xAA]))
        }
        let client = ServerSyncClient(baseURL: baseURL, session: session)
        let first = try await client.get("test123")
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.etag, "\"v1\"")
        XCTAssertEqual(client.cachedETag(for: "test123"), "\"v1\"")

        // Second response: 304 when the cached etag matches.
        MockURLProtocol.stub(path: "/doc/test123", method: "GET") { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
            return MockResponse(status: 304, headers: [:], body: Data())
        }
        let second = try await client.get("test123")
        XCTAssertNil(second, "304 must be reported as nil (no change)")
    }

    func testGet404ReturnsNil_treatsMissingAsNoRemote() async throws {
        MockURLProtocol.stub(path: "/doc/absent", method: "GET") { _ in
            MockResponse(status: 404, headers: [:],
                         body: Data("""
                         {"error":"not_found","message":"missing"}
                         """.utf8))
        }
        let client = ServerSyncClient(baseURL: baseURL, session: session)
        let result = try await client.get("absent")
        XCTAssertNil(result)
    }

    // MARK: - Error propagation

    func testPut413SurfacesHttpError() async {
        MockURLProtocol.stub(path: "/doc/big", method: "PUT") { _ in
            MockResponse(status: 413, headers: [:],
                         body: Data("""
                         {"error":"doc_too_large","message":"body > 5 MiB"}
                         """.utf8))
        }
        let client = ServerSyncClient(baseURL: baseURL, session: session)
        do {
            _ = try await client.put("big", Data([0x01]))
            XCTFail("expected ClientError on 413")
        } catch let ServerSyncClient.ClientError.http(status, code, message) {
            XCTAssertEqual(status, 413)
            XCTAssertEqual(code, "doc_too_large")
            XCTAssertNotNil(message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Healthz

    func testHealthzOk() async {
        MockURLProtocol.stub(path: "/healthz", method: "GET") { _ in
            MockResponse(status: 200, headers: [:], body: Data("ok".utf8))
        }
        let client = ServerSyncClient(baseURL: baseURL, session: session)
        let ok = await client.healthz()
        XCTAssertTrue(ok)
    }

    func testHealthzFailingStatus() async {
        MockURLProtocol.stub(path: "/healthz", method: "GET") { _ in
            MockResponse(status: 500, headers: [:], body: Data())
        }
        let client = ServerSyncClient(baseURL: baseURL, session: session)
        let ok = await client.healthz()
        XCTAssertFalse(ok)
    }

    // MARK: - DELETE idempotent

    func testDeleteTreatsMissingAsSuccess() async throws {
        MockURLProtocol.stub(path: "/doc/gone", method: "DELETE") { _ in
            MockResponse(status: 404, headers: [:], body: Data())
        }
        let client = ServerSyncClient(baseURL: baseURL, session: session)
        client.setCachedETag("\"stale\"", for: "gone")
        try await client.delete("gone")
        XCTAssertNil(client.cachedETag(for: "gone"), "DELETE should clear the etag cache")
    }
}

// MARK: - MockURLProtocol

/// Tiny URLProtocol stub. Register via `URLSessionConfiguration.protocolClasses`.
/// Stubs are keyed by `(path, method)` — most recent `stub()` call wins.
struct MockResponse {
    let status: Int
    let headers: [String: String]
    let body: Data
}

typealias MockHandler = (URLRequest) -> MockResponse

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var handlers: [String: MockHandler] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlers.removeAll()
    }

    static func stub(path: String, method: String, handler: @escaping MockHandler) {
        lock.lock(); defer { lock.unlock() }
        handlers["\(method) \(path)"] = handler
    }

    static func handler(for request: URLRequest) -> MockHandler? {
        lock.lock(); defer { lock.unlock() }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        return handlers["\(method) \(path)"]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler(for: request),
              let url = request.url else {
            let err = NSError(domain: "MockURLProtocol", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "no stub for \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"])
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        let response = handler(request)
        let http = HTTPURLResponse(url: url,
                                    statusCode: response.status,
                                    httpVersion: "HTTP/1.1",
                                    headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty {
            client?.urlProtocol(self, didLoad: response.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
