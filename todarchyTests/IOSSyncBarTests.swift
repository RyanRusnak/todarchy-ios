import XCTest
import SwiftUI

/// The sync-bar view's label logic is state-dependent on SyncSettings.
/// We don't render a SwiftUI view tree in unit tests; we test the
/// `SyncSettings` state combinations that drive it and the auxiliary
/// "relative time" helper via the public API surface.
@MainActor
final class IOSSyncBarTests: XCTestCase {

    func testLocalOnlyWhenNoSyncFolder() {
        let s = SyncSettings.shared
        // Without external configuration, shared's syncFolderURL may or
        // may not be nil depending on the test environment. Force the
        // local-only path by using clearFolder.
        s.clearFolder(TaskStorePersistence.shared)
        XCTAssertNil(s.syncFolderURL)
        XCTAssertFalse(s.isSyncing)
    }

    func testBeginSyncShowsSyncingState() {
        let s = SyncSettings.shared
        s.beginSync()
        XCTAssertTrue(s.isSyncing)
        s.endSync(result: .init(success: true, taskCount: 0, message: nil))
        XCTAssertFalse(s.isSyncing)
    }

    func testEndSyncFailureExposesErrorForBar() {
        let s = SyncSettings.shared
        s.endSync(result: .init(success: false, taskCount: nil, message: "couldn't read"))
        XCTAssertEqual(s.lastSyncError, "couldn't read")
    }

    func testEndSyncSuccessClearsErrorForBar() {
        let s = SyncSettings.shared
        s.endSync(result: .init(success: false, taskCount: nil, message: "prior failure"))
        XCTAssertNotNil(s.lastSyncError)
        s.endSync(result: .init(success: true, taskCount: 5, message: nil))
        XCTAssertNil(s.lastSyncError)
        XCTAssertNotNil(s.lastMergedAt)
    }
}
