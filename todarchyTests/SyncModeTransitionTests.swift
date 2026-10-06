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

// MARK: - MockURLProtocol helpers

extension MockURLProtocol {
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

/// The main doc used to leave the device as plaintext Automerge bytes —
/// `automerge.save()` went straight to `client.put`, so the relay held
/// readable titles, notes and comments for every non-shared project. Only
/// per-project shared files were ever sealed. These pin the fix: the relay
/// copy is sealed under the passphrase-derived master key, the pre-
/// encryption format still reads, and a device that can't decrypt refuses
/// to push plaintext back over ciphertext.
@MainActor
final class RelayEncryptionTests: XCTestCase {
    var tmpDir: URL!
    let baseURL = URL(string: "https://mock.example.com")!
    let docId = "main_crypto"

    /// A stand-in for the passphrase-derived master key.
    let relay = TaskStorePersistence.RelayKey(
        key: CryptoBox.generateKey(),
        salt: Data(repeating: 0x5A, count: 16)
    )

    override func setUp() async throws {
        MockURLProtocol.reset()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-relaycrypto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        // Sticky no-downgrade flag is process-wide; start every case clean.
        UserDefaults.standard.set(false, forKey: "todarchy.sync.relayEncrypted")
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        UserDefaults.standard.set(false, forKey: "todarchy.sync.relayEncrypted")
        _ = try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makePersistence() -> TaskStorePersistence {
        let p = TaskStorePersistence(fileURL: tmpDir.appendingPathComponent("tasks.automerge"))
        p.serverClient = ServerSyncClient(baseURL: baseURL, session: MockURLProtocol.makeSession())
        p.serverMainDocId = docId
        return p
    }

    /// Bytes a peer would be holding, as raw Automerge.
    private func peerDocBytes(title: String) throws -> Data {
        let peer = AutomergeStore(data: nil)
        try peer.upsertTasks([TaskItem(list: "inbox", title: title, pos: Date())])
        return peer.save()
    }

    private func stubGet(_ response: @escaping () -> MockResponse) {
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "GET") { _ in response() }
    }

    // MARK: - Push

    func testMainDocIsSealedBeforeItReachesTheRelay() async throws {
        let put = expectation(description: "PUT")
        put.assertForOverFulfill = false
        let body = BodyBox()
        stubGet { MockResponse(status: 404, headers: [:], body: Data()) }
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "PUT") { request in
            body.data = request.httpBody ?? MockURLProtocol.streamedBody(from: request)
            put.fulfill()
            return MockResponse(status: 204, headers: ["ETag": "\"v1\""], body: Data())
        }

        let p = makePersistence()
        p.relayKey = relay
        p.saveNow(.init(tasks: [TaskItem(list: "inbox", title: "buy-plutonium", pos: Date())],
                        projects: []))
        await fulfillment(of: [put], timeout: 5)

        let uploaded = try XCTUnwrap(body.data)
        XCTAssertTrue(CryptoBox.isEnvelope(uploaded), "Relay payload must be a sealed envelope.")
        XCTAssertNil(uploaded.range(of: Data("buy-plutonium".utf8)),
                     "Task titles must not be readable in the bytes the relay stores.")
        XCTAssertEqual(CryptoBox.salt(in: uploaded), relay.salt,
                       "The KDF salt rides in the clear header so other devices can re-derive.")

        let opened = try CryptoBox.open(uploaded, with: relay.key)
        let snap = try AutomergeStore(data: opened).snapshot()
        XCTAssertTrue(snap.tasks.contains { $0.title == "buy-plutonium" })
    }

    func testWithoutAPassphraseBytesStillGoUpInTheClear() async throws {
        // No master key and a relay that has never held ciphertext: keep
        // syncing rather than stranding the user. The UI reports this as
        // "relay encryption OFF" so it isn't a quiet fail-open.
        let put = expectation(description: "PUT")
        put.assertForOverFulfill = false
        let body = BodyBox()
        stubGet { MockResponse(status: 404, headers: [:], body: Data()) }
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "PUT") { request in
            body.data = request.httpBody ?? MockURLProtocol.streamedBody(from: request)
            put.fulfill()
            return MockResponse(status: 204, headers: ["ETag": "\"v1\""], body: Data())
        }

        let p = makePersistence()
        p.relayKey = nil
        p.saveNow(.init(tasks: [TaskItem(list: "inbox", title: "plain", pos: Date())],
                        projects: []))
        // The relay's format is unknown until a GET completes, so the
        // write-back after this refresh is the first upload.
        p.refreshFromDisk()
        await fulfillment(of: [put], timeout: 5)

        let uploaded = try XCTUnwrap(body.data)
        XCTAssertFalse(CryptoBox.isEnvelope(uploaded))
        XCTAssertTrue(AutomergeStore.isDocument(uploaded))
    }

    // MARK: - Pull

    func testSealedBytesFromTheRelayAreOpenedAndMerged() async throws {
        let sealed = try CryptoBox.seal(try peerDocBytes(title: "from-peer"),
                                        with: relay.key, salt: relay.salt)
        stubGet { MockResponse(status: 200, headers: ["ETag": "\"v1\""], body: sealed) }
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "PUT") { _ in
            MockResponse(status: 204, headers: ["ETag": "\"v2\""], body: Data())
        }

        let p = makePersistence()
        p.relayKey = relay
        try await expectMerge(p, title: "from-peer")
    }

    func testLegacyPlaintextFromTheRelayStillMerges() async throws {
        // Upgrade path: the relay is still holding what an older build put
        // there. Merge it, then the write-back re-uploads it sealed.
        stubGet { [self] in
            MockResponse(status: 200, headers: ["ETag": "\"v1\""],
                         body: (try? peerDocBytes(title: "legacy-peer")) ?? Data())
        }
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "PUT") { _ in
            MockResponse(status: 204, headers: ["ETag": "\"v2\""], body: Data())
        }

        let p = makePersistence()
        p.relayKey = relay
        try await expectMerge(p, title: "legacy-peer")
    }

    func testLockedDeviceRefusesToPushPlaintextOverCiphertext() async throws {
        // A device without the passphrase must not "helpfully" overwrite
        // the relay's ciphertext with its own readable bytes — that would
        // silently strip encryption for every other device on the doc.
        let sealed = try CryptoBox.seal(try peerDocBytes(title: "unreadable"),
                                        with: CryptoBox.generateKey(),
                                        salt: Data(repeating: 9, count: 16))
        let get = expectation(description: "GET")
        get.assertForOverFulfill = false
        stubGet { get.fulfill(); return MockResponse(status: 200, headers: ["ETag": "\"v1\""], body: sealed) }

        let noPut = expectation(description: "no PUT while locked")
        noPut.isInverted = true
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "PUT") { _ in
            noPut.fulfill()
            return MockResponse(status: 204, headers: ["ETag": "\"v2\""], body: Data())
        }

        let p = makePersistence()
        p.relayKey = nil        // locked: no passphrase on this device
        // Save first: this is the dangerous ordering — a local mutation
        // racing ahead of the device's first read of the relay.
        p.saveNow(.init(tasks: [TaskItem(list: "inbox", title: "local-secret", pos: Date())],
                        projects: []))
        p.refreshFromDisk()

        await fulfillment(of: [get], timeout: 5)
        await fulfillment(of: [noPut], timeout: 2)
        XCTAssertTrue(p.relayIsEncrypted, "Seeing ciphertext arms the no-downgrade rule.")
        XCTAssertTrue(p.load()?.tasks.contains { $0.title == "local-secret" } ?? false,
                      "Local state must survive being unable to read the relay.")
    }

    func testUnreadableRelayBytesAreNotMerged() async throws {
        // AutomergeStore(data:) substitutes the empty seed for junk bytes,
        // so merging without checking quietly folds that seed into the
        // live doc. Refuse instead.
        stubGet { MockResponse(status: 200, headers: ["ETag": "\"v1\""],
                               body: Data(repeating: 0x7F, count: 512)) }
        MockURLProtocol.stub(path: "/doc/\(docId)", method: "PUT") { _ in
            MockResponse(status: 204, headers: ["ETag": "\"v2\""], body: Data())
        }

        let p = makePersistence()
        p.relayKey = relay
        p.saveNow(.init(tasks: [TaskItem(list: "inbox", title: "mine", pos: Date())], projects: []))
        let before = p.load()?.tasks.count ?? 0

        let settled = expectation(description: "refresh settled")
        settled.assertForOverFulfill = false
        p.onExternalChange = { settled.fulfill() }
        p.refreshFromDisk()
        await fulfillment(of: [settled], timeout: 5)

        XCTAssertEqual(p.load()?.tasks.count, before,
                       "Junk from the relay must not change the local doc.")
        XCTAssertTrue(p.load()?.tasks.contains { $0.title == "mine" } ?? false)
    }

    // MARK: - Helpers

    private func expectMerge(_ p: TaskStorePersistence, title: String) async throws {
        let merged = expectation(description: "merged \(title)")
        merged.assertForOverFulfill = false
        p.onExternalChange = { [weak p] in
            if p?.load()?.tasks.contains(where: { $0.title == title }) == true { merged.fulfill() }
        }
        p.refreshFromDisk()
        await fulfillment(of: [merged], timeout: 10)
    }
}

/// Captures a request body from the mock protocol's thread.
private final class BodyBox: @unchecked Sendable {
    var data: Data?
}
