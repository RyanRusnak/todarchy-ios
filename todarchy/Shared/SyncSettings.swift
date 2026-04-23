import Foundation
import SwiftUI

/// Owns the user's sync folder choice, persisted via a security-scoped
/// bookmark in `UserDefaults`. Platform-agnostic; the folder picker UI is
/// platform-specific (`.fileImporter` on iOS, `NSOpenPanel` on macOS).
@MainActor
final class SyncSettings: ObservableObject {
    static let shared = SyncSettings()

    @Published private(set) var syncFolderURL: URL?
    @Published private(set) var lastMergedAt: Date?
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncError: String?

    private let bookmarkKey = "todarchy.sync.folderBookmark"
    private let lastMergedKey = "todarchy.sync.lastMergedAt"

    init() {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            let options: URL.BookmarkResolutionOptions = Self.resolutionOptions
            if let url = try? URL(resolvingBookmarkData: data,
                                   options: options,
                                   relativeTo: nil,
                                   bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                self.syncFolderURL = url
            }
        }
        if let ts = UserDefaults.standard.object(forKey: lastMergedKey) as? Date {
            self.lastMergedAt = ts
        }
    }

    /// The canonical tasks.automerge URL for the current setting.
    var currentFileURL: URL {
        if let folder = syncFolderURL {
            return folder.appendingPathComponent("tasks.automerge")
        }
        return TaskStorePersistence.defaultFileURL()
    }

    /// Called by the view after the user picks a folder.
    func setFolder(_ folder: URL, persistence: TaskStorePersistence) {
        let creationOptions: URL.BookmarkCreationOptions = Self.creationOptions
        do {
            let bookmark = try folder.bookmarkData(options: creationOptions,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            _ = folder.startAccessingSecurityScopedResource()
            syncFolderURL = folder
            persistence.scopedFolderURL = folder
            let newFileURL = folder.appendingPathComponent("tasks.automerge")
            try persistence.setFileURL(newFileURL)
        } catch {
            #if DEBUG
            print("todarchy: couldn't set sync folder: \(error)")
            #endif
        }
    }

    /// Clear the chosen sync folder and fall back to Application Support.
    func clearFolder(_ persistence: TaskStorePersistence) {
        if let url = syncFolderURL { url.stopAccessingSecurityScopedResource() }
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        syncFolderURL = nil
        persistence.scopedFolderURL = nil
        try? persistence.setFileURL(TaskStorePersistence.defaultFileURL())
    }

    /// Eagerly re-point the shared `TaskStorePersistence` at the saved sync
    /// folder (if any) so the *first* save after launch writes to the sync
    /// file, not the Application Support fallback. Safe to call repeatedly.
    func applyStartupConfiguration() {
        guard let folder = syncFolderURL else { return }
        TaskStorePersistence.shared.scopedFolderURL = folder
        let fileURL = folder.appendingPathComponent("tasks.automerge")
        // replaceLocalDoc=true: the app has just launched, nothing has
        // been edited locally yet, so the sync folder's bytes are
        // authoritative. This avoids the startup-merge panic where two
        // disjoint doc histories collide in Rust.
        try? TaskStorePersistence.shared.setFileURL(fileURL, replaceLocalDoc: true)
    }

    func markMerged() {
        let now = Date()
        lastMergedAt = now
        UserDefaults.standard.set(now, forKey: lastMergedKey)
    }

    // MARK: - Sync lifecycle

    func beginSync() {
        isSyncing = true
        lastSyncError = nil
    }

    func endSync(result: TaskStorePersistence.SyncResult) {
        isSyncing = false
        if result.success {
            markMerged()
            lastSyncError = nil
        } else {
            lastSyncError = result.message
        }
    }

    // MARK: - Platform-specific bookmark options

    private static var creationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        // iOS bookmarks don't use `.withSecurityScope`; the security scope is
        // implicit when you resolve a bookmark to a UIDocumentPicker-returned
        // URL via `startAccessingSecurityScopedResource`.
        return []
        #endif
    }

    private static var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }
}
