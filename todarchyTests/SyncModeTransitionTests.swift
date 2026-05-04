import XCTest
import SwiftUI

/// Tests that flipping between sync modes (folder / server / local-only)
/// preserves the in-memory Automerge state — "switching back and forth
/// should not affect the state of the apps" per the product requirement.
@MainActor
final class SyncModeTransitionTests: XCTestCase {

    var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        MockURLProtocol.reset()
    }

    // MARK: - Folder → different folder

    func testSwitchingFolders_preservesInMemoryDoc() throws {
        let folderA = tmpDir.appendingPathComponent("A", isDirectory: true)
        let folderB = tmpDir.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)

        let persistence = TaskStorePersistence(fileURL: folderA.appendingPathComponent("tasks.automerge"))
        let t = TaskItem(list: "inbox", title: "preserved", pos: Date())
        persistence.saveNow(.init(tasks: [t], projects: []))

        // Flip to folder B — setFileURL(replaceLocalDoc: false) merges the
        // target doc in while keeping local state.
        try persistence.setFileURL(folderB.appendingPathComponent("tasks.automerge"))

        let loaded = persistence.load()!
        XCTAssertTrue(loaded.tasks.contains { $0.title == "preserved" },
                       "folder switch must preserve the in-memory doc")
    }

    // MARK: - Folder → server

    func testSwitchFolderToServer_pushesCurrentBytesAndPreservesState() async throws {
        let folder = tmpDir.appendingPathComponent("F", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let persistence = TaskStorePersistence(fileURL: folder.appendingPathComponent("tasks.automerge"))
        let t = TaskItem(list: "inbox", title: "folder-first", pos: Date())
        persistence.saveNow(.init(tasks: [t], projects: []))

        // Configure a mock server client. We don't route via SyncSettings.setServer
        // here because it touches UserDefaults / the shared singleton — we
        // instead wire Persistence directly, which is what setServer does
        // internally.
        let session = MockURLProtocol.makeSession()
        let client = ServerSyncClient(baseURL: URL(string: "https://mock.example.com")!,
                                       session: session)
        persistence.serverClient = client
        persistence.serverMainDocId = "main_test"

        // Expect a PUT when we switch to the server-backed cache file.
        let putExpectation = expectation(description: "PUT to server")
        MockURLProtocol.stub(path: "/doc/main_test", method: "PUT") { request in
            XCTAssertNotNil(request.httpBody ?? MockURLProtocol.streamedBody(from: request))
            XCTAssertNil(request.value(forHTTPHeaderField: "If-Match"),
                         "always-overwrite semantics: no If-Match")
            putExpectation.fulfill()
            return MockResponse(status: 204, headers: ["ETag": "\"v1\""], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/main_test", method: "GET") { _ in
            MockResponse(status: 404, headers: [:], body: Data())
        }

        // Simulate SyncSettings.setServer: re-point Persistence at the
        // local cache file (not the folder), preserving the doc.
        let cacheFile = tmpDir.appendingPathComponent("cache.automerge")
        try persistence.setFileURL(cacheFile)

        await fulfillment(of: [putExpectation], timeout: 5)

        // Local state still holds the task.
        let loaded = persistence.load()!
        XCTAssertTrue(loaded.tasks.contains { $0.title == "folder-first" },
                       "in-memory doc must survive the folder→server switch")
    }

    // MARK: - Server → folder

    func testSwitchServerToFolder_preservesLocalTasks() async throws {
        let cacheFile = tmpDir.appendingPathComponent("cache.automerge")
        let persistence = TaskStorePersistence(fileURL: cacheFile)

        // Start in server-like mode with a task already persisted locally.
        let session = MockURLProtocol.makeSession()
        let client = ServerSyncClient(baseURL: URL(string: "https://mock.example.com")!,
                                       session: session)
        persistence.serverClient = client
        persistence.serverMainDocId = "main_test"

        // Any incidental network calls just 404 or succeed quietly.
        MockURLProtocol.stub(path: "/doc/main_test", method: "GET") { _ in
            MockResponse(status: 404, headers: [:], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/main_test", method: "PUT") { _ in
            MockResponse(status: 204, headers: ["ETag": "\"v1\""], body: Data())
        }

        let t = TaskItem(list: "inbox", title: "server-first", pos: Date())
        persistence.saveNow(.init(tasks: [t], projects: []))

        // Now clear the server configuration and re-point at a folder.
        persistence.serverClient = nil
        persistence.serverMainDocId = nil
        let folder = tmpDir.appendingPathComponent("F", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try persistence.setFileURL(folder.appendingPathComponent("tasks.automerge"))

        let loaded = persistence.load()!
        XCTAssertTrue(loaded.tasks.contains { $0.title == "server-first" },
                       "server→folder switch must keep local tasks")
    }

    // MARK: - Shared-project envelope pushes to server

    func testSharedProjectEnvelopeIsPushedToServer() async throws {
        let cacheFile = tmpDir.appendingPathComponent("cache.automerge")
        let persistence = TaskStorePersistence(fileURL: cacheFile)

        // Provide a manager with an in-memory key store. Root it in
        // tmpDir so envelope files land in a predictable place.
        let manager = SharedProjectManager(folder: tmpDir, keyStore: InMemoryKeyStore())
        persistence.sharedProjectManager = manager

        // Mock server.
        let session = MockURLProtocol.makeSession()
        let client = ServerSyncClient(baseURL: URL(string: "https://mock.example.com")!,
                                       session: session)
        persistence.serverClient = client
        persistence.serverMainDocId = "main_test"

        // Main-doc calls: benign.
        MockURLProtocol.stub(path: "/doc/main_test", method: "GET") { _ in
            MockResponse(status: 404, headers: [:], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/main_test", method: "PUT") { _ in
            MockResponse(status: 204, headers: ["ETag": "\"m1\""], body: Data())
        }

        // Stand up a shared project directly so persistence has something
        // to drive.
        let sharedProject = ProjectItem(id: "p_shared123", name: "planning",
                                         icon: "folder", accent: .blue,
                                         isShared: true)
        let taskInShared = TaskItem(list: sharedProject.id, title: "in-shared", pos: Date())
        _ = try manager.createShared(project: sharedProject, tasks: [taskInShared])

        // Expect a PUT to /doc/<projectId> with the encrypted envelope.
        let sharedPutExpectation = expectation(description: "PUT shared envelope to server")
        MockURLProtocol.stub(path: "/doc/\(sharedProject.id)", method: "PUT") { request in
            let body = request.httpBody ?? MockURLProtocol.streamedBody(from: request) ?? Data()
            XCTAssertGreaterThan(body.count, 16, "envelope body should not be empty")
            // Envelope magic is "TDAR"
            let magic = body.prefix(4)
            XCTAssertEqual(String(data: magic, encoding: .ascii), "TDAR",
                            "body must be a CryptoBox envelope — server sees ciphertext only")
            sharedPutExpectation.fulfill()
            return MockResponse(status: 204, headers: ["ETag": "\"s1\""], body: Data())
        }
        MockURLProtocol.stub(path: "/doc/\(sharedProject.id)", method: "GET") { _ in
            MockResponse(status: 404, headers: [:], body: Data())
        }

        // Drive a save that includes the shared project. That runs the
        // full flushNow pipeline — main doc + shared store + server PUTs.
        persistence.saveNow(.init(
            tasks: [taskInShared],
            projects: [sharedProject]
        ))

        await fulfillment(of: [sharedPutExpectation], timeout: 5)
    }
}

// MARK: - MockURLProtocol helpers for this test file

private extension MockURLProtocol {
    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// URLSession may stream PUT bodies through httpBodyStream instead of
    /// buffering them in httpBody. Read the stream to bytes for test
    /// assertions.
    static func streamedBody(from request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}
