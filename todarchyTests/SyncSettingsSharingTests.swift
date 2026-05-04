import XCTest
@testable import todarchy

/// Phase 4a wiring: SyncSettings owns the shared-project manager and
/// installs it on persistence whenever the sync folder changes.
@MainActor
final class SyncSettingsSharingTests: XCTestCase {

    // We can't safely reuse `SyncSettings.shared` across tests because
    // it touches UserDefaults + bookmark state. Construct fresh
    // SyncSettings-like scaffolding by driving the settings directly.
    func testSetFolderInstallsManagerOnPersistence() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-syncset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { _ = try? FileManager.default.removeItem(at: tmp) }

        // Arrange: fresh SyncSettings + persistence pair, swap in an
        // in-memory key store so we don't touch the real keychain.
        let settings = SyncSettings()
        settings.keyStore = InMemoryKeyStore()

        // Point a persistence at an unrelated path — setFolder will move it.
        let initialFile = tmp.appendingPathComponent("initial.automerge")
        let persistence = TaskStorePersistence(fileURL: initialFile)

        // Act
        let syncFolder = tmp.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        settings.setFolder(syncFolder, persistence: persistence)

        // Assert: manager is installed on both SyncSettings and persistence.
        XCTAssertNotNil(settings.sharedProjectManager, "SyncSettings should own a manager after setFolder")
        XCTAssertNotNil(persistence.sharedProjectManager, "Persistence should have the same manager installed")
        XCTAssertEqual(settings.sharedProjectManager?.folder, syncFolder)
    }

    func testClearFolderDropsManager() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("todarchy-syncclear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { _ = try? FileManager.default.removeItem(at: tmp) }

        let settings = SyncSettings()
        settings.keyStore = InMemoryKeyStore()
        let persistence = TaskStorePersistence(fileURL: tmp.appendingPathComponent("initial.automerge"))
        let syncFolder = tmp.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        settings.setFolder(syncFolder, persistence: persistence)
        XCTAssertNotNil(settings.sharedProjectManager)

        settings.clearFolder(persistence)
        XCTAssertNil(settings.sharedProjectManager)
        XCTAssertNil(persistence.sharedProjectManager)
    }
}
