import Foundation
import SwiftUI
import Combine

/// Owns the user's sync transport choice. Three modes:
///   - `.localOnly`     — doc lives only in Application Support.
///   - `.folder(URL)`   — mirrored via a user-picked folder (Dropbox,
///                        iCloud Drive, Syncthing, …).
///   - `.server(cfg)`   — mirrored via an HTTP relay; bytes are pushed
///                        to `<baseURL>/doc/<mainDocId>`.
///
/// Mode switches preserve the in-memory Automerge doc: the persistence
/// layer re-points its file URL and merges if appropriate. Callers never
/// rebuild the TaskStore on mode change.
@MainActor
final class SyncSettings: ObservableObject {
    static let shared = SyncSettings()

    @Published private(set) var mode: SyncMode = .localOnly
    @Published private(set) var lastMergedAt: Date?
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncError: String?
    @Published private(set) var serverHealth: ServerHealth = .unknown

    /// Whether the main doc is encrypted on its way to the relay.
    ///
    /// Shared projects were always sealed under their own per-project key;
    /// this is about everything else, which used to travel — and sit on
    /// the relay — as plaintext Automerge bytes.
    @Published private(set) var relayEncryption: RelayEncryption = .off

    /// Argon2 salt lifted from a relay envelope we couldn't open. This is
    /// the bootstrap path for a device that has the passphrase but has
    /// never seen the doc: the salt normally lives *inside* the main doc,
    /// which is exactly what we can't read yet. Feed it to
    /// `MasterKey.derive(passphrase:salt:)`.
    @Published private(set) var relayEnvelopeSalt: Data?

    private var masterKeyObserver: AnyCancellable?

    enum RelayEncryption: Equatable {
        /// No passphrase on this device, and the relay isn't encrypted
        /// either — bytes go up in the clear, as they always did.
        case off
        /// Sealed under the passphrase-derived master key.
        case on
        /// The relay holds ciphertext but this device can't open it.
        /// Pushes are suppressed rather than downgrading the relay copy.
        case locked
    }

    /// One-shot user-facing message for share-link arrivals that can't
    /// be handled silently (e.g. link opened before any sync transport
    /// is configured — the encrypted shared file has no way to reach
    /// us). Root view presents an alert when non-nil; setting back to
    /// nil dismisses.
    @Published var shareLinkAlert: String?

    /// Shared-project coordinator. Rooted in the *local* folder that
    /// holds shared-project files: the sync folder in `.folder` mode,
    /// Application Support in `.localOnly` / `.server` modes. When
    /// the server is active, Persistence additionally pushes/pulls
    /// each shared-project envelope to the relay on top of the local
    /// file.
    @Published private(set) var sharedProjectManager: SharedProjectManager?

    /// Swappable for tests.
    var keyStore: KeyStore = KeychainKeyStore()

    enum ServerHealth: Equatable {
        case unknown
        case ok
        case failing(String)
    }

    private let bookmarkKey = "todarchy.sync.folderBookmark"
    private let lastMergedKey = "todarchy.sync.lastMergedAt"
    private let serverConfigKey = "todarchy.sync.serverConfig"
    private let modeKey = "todarchy.sync.mode"

    init() {
        // Keep Persistence's copy of the relay key in step with the master
        // key. Persistence seals on its own serial queue and can't hop to
        // the MainActor to ask, so it holds a mirrored copy instead.
        masterKeyObserver = MasterKey.shared.$currentKey
            .sink { [weak self] _ in
                // Deferred: `currentSalt` is assigned right after
                // `currentKey`, so reading it inside the sink would race
                // the pair apart.
                DispatchQueue.main.async { self?.refreshRelayKey() }
            }
        if let ts = UserDefaults.standard.object(forKey: lastMergedKey) as? Date {
            self.lastMergedAt = ts
        }
        // Restore mode without side-effects — actual file/persistence wiring
        // happens later in `applyStartupConfiguration` once the TaskStore
        // and persistence singletons are ready.
        if let stored = UserDefaults.standard.string(forKey: modeKey) {
            switch stored {
            case "server":
                if let cfg = loadServerConfig() {
                    self.mode = .server(cfg)
                }
            case "folder":
                if let url = resolveSavedFolderBookmark() {
                    self.mode = .folder(url)
                }
            default: break
            }
        } else if let url = resolveSavedFolderBookmark() {
            // Backward-compat: older builds only knew about folder mode;
            // an existing bookmark implies `.folder`.
            self.mode = .folder(url)
        }
    }

    // MARK: - Backward-compatible accessors used throughout the UI

    /// Present for legacy callers that want the folder URL when in folder
    /// mode. `nil` in any other mode.
    var syncFolderURL: URL? {
        if case .folder(let url) = mode { return url }
        return nil
    }

    var serverConfig: ServerConfig? {
        if case .server(let cfg) = mode { return cfg }
        return nil
    }

    /// Canonical tasks.automerge URL for the current mode. Server mode
    /// uses the Application Support fallback — the file exists locally
    /// as an Automerge cache regardless of whether we're relaying to
    /// a server.
    var currentFileURL: URL {
        switch mode {
        case .folder(let url): return url.appendingPathComponent("tasks.automerge")
        case .localOnly, .server: return TaskStorePersistence.defaultFileURL()
        }
    }

    // MARK: - Mutations

    /// Pick a sync folder. Preserves the in-memory Automerge doc by
    /// routing through `setFileURL(replaceLocalDoc: false)`.
    func setFolder(_ folder: URL, persistence: TaskStorePersistence) {
        let creationOptions: URL.BookmarkCreationOptions = Self.creationOptions
        do {
            let bookmark = try folder.bookmarkData(options: creationOptions,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            UserDefaults.standard.set("folder", forKey: modeKey)
            _ = folder.startAccessingSecurityScopedResource()

            mode = .folder(folder)
            persistence.scopedFolderURL = folder
            persistence.serverClient = nil
            persistence.serverMainDocId = nil
            installSharedManager(folder: folder, on: persistence)

            let newFileURL = folder.appendingPathComponent("tasks.automerge")
            try persistence.setFileURL(newFileURL)
        } catch {
            #if DEBUG
            print("todarchy: couldn't set sync folder: \(error)")
            #endif
        }
    }

    /// Switch to HTTP-relay mode. The in-memory doc survives the switch;
    /// on the next flush Persistence pushes its bytes to the server.
    func setServer(_ config: ServerConfig, persistence: TaskStorePersistence) {
        // Drop any folder bookmark scope — we're no longer using it.
        if case .folder(let url) = mode {
            url.stopAccessingSecurityScopedResource()
        }

        saveServerConfig(config)
        UserDefaults.standard.set("server", forKey: modeKey)

        mode = .server(config)
        persistence.scopedFolderURL = nil
        persistence.serverClient = ServerSyncClient(baseURL: config.baseURL)
        persistence.serverMainDocId = config.mainDocId

        // Shared-project envelopes keep a local cache in Application
        // Support so offline operation works; Persistence pushes each
        // envelope to the server on top of that. Root the manager
        // there.
        let cacheFolder = TaskStorePersistence.defaultFileURL().deletingLastPathComponent()
        installSharedManager(folder: cacheFolder, on: persistence)

        do {
            try persistence.setFileURL(TaskStorePersistence.defaultFileURL())
        } catch {
            #if DEBUG
            print("todarchy: couldn't switch to server mode: \(error)")
            #endif
        }
    }

    /// Turn off sync (`.localOnly`). Preserves the in-memory doc.
    func clearSync(_ persistence: TaskStorePersistence) {
        if case .folder(let url) = mode {
            url.stopAccessingSecurityScopedResource()
        }
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: serverConfigKey)
        UserDefaults.standard.set("localOnly", forKey: modeKey)

        mode = .localOnly
        persistence.scopedFolderURL = nil
        persistence.serverClient = nil
        persistence.serverMainDocId = nil
        sharedProjectManager = nil
        persistence.sharedProjectManager = nil
        try? persistence.setFileURL(TaskStorePersistence.defaultFileURL())
    }

    /// Legacy alias — kept for the small number of call sites that still
    /// speak the old vocabulary. Prefer `clearSync`.
    func clearFolder(_ persistence: TaskStorePersistence) {
        clearSync(persistence)
    }

    /// Eagerly re-apply whatever mode was in effect on the last run so
    /// the *first* save after launch goes to the right destination.
    /// Safe to call more than once.
    func applyStartupConfiguration() {
        switch mode {
        case .folder(let folder):
            TaskStorePersistence.shared.scopedFolderURL = folder
            TaskStorePersistence.shared.serverClient = nil
            TaskStorePersistence.shared.serverMainDocId = nil
            installSharedManager(folder: folder, on: TaskStorePersistence.shared)
            let fileURL = folder.appendingPathComponent("tasks.automerge")
            // replaceLocalDoc: adopt the sync folder's bytes verbatim.
            try? TaskStorePersistence.shared.setFileURL(fileURL, replaceLocalDoc: true)

        case .server(let cfg):
            TaskStorePersistence.shared.scopedFolderURL = nil
            TaskStorePersistence.shared.serverClient = ServerSyncClient(baseURL: cfg.baseURL)
            TaskStorePersistence.shared.serverMainDocId = cfg.mainDocId
            let cacheFolder = TaskStorePersistence.defaultFileURL().deletingLastPathComponent()
            installSharedManager(folder: cacheFolder, on: TaskStorePersistence.shared)
            // Stay on the Application Support cache file. Server pull
            // happens on the first refresh cycle / save, not here.
            // setFileURL is not called in this path (the URL hasn't changed),
            // so we must start the poll timer explicitly — setFileURL is the
            // only other place that starts it.
            TaskStorePersistence.shared.startServerPollTimer()

        case .localOnly:
            sharedProjectManager = nil
            TaskStorePersistence.shared.sharedProjectManager = nil
            TaskStorePersistence.shared.serverClient = nil
            TaskStorePersistence.shared.serverMainDocId = nil
        }
    }

    private func installSharedManager(folder: URL, on persistence: TaskStorePersistence) {
        let manager = SharedProjectManager(folder: folder, keyStore: keyStore)
        sharedProjectManager = manager
        persistence.sharedProjectManager = manager
    }

    func markMerged() {
        let now = Date()
        lastMergedAt = now
        UserDefaults.standard.set(now, forKey: lastMergedKey)
    }

    func markServerHealth(_ health: ServerHealth) {
        serverHealth = health
    }

    /// Push the current master key down to `Persistence` so relay payloads
    /// can be sealed from the persistence queue, and republish the
    /// user-visible encryption state.
    func refreshRelayKey(persistence: TaskStorePersistence = .shared) {
        if let key = MasterKey.shared.currentKey, let salt = MasterKey.shared.currentSalt {
            persistence.relayKey = .init(key: key, salt: salt)
            relayEncryption = .on
            relayEnvelopeSalt = nil
        } else {
            persistence.relayKey = nil
            // `.locked` is the interesting case — the relay is holding
            // ciphertext we can't read — and Persistence tells us that by
            // handing over an envelope salt.
            relayEncryption = relayEnvelopeSalt == nil ? .off : .locked
        }
    }

    /// Called by `Persistence` when a relay envelope couldn't be opened.
    func noteRelayEnvelopeSalt(_ salt: Data) {
        relayEnvelopeSalt = salt
        if MasterKey.shared.currentKey == nil {
            relayEncryption = .locked
        }
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

    // MARK: - Persistence helpers

    private func resolveSavedFolderBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        let options: URL.BookmarkResolutionOptions = Self.resolutionOptions
        guard let url = try? URL(resolvingBookmarkData: data,
                                  options: options,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    private func loadServerConfig() -> ServerConfig? {
        guard let data = UserDefaults.standard.data(forKey: serverConfigKey) else { return nil }
        return try? JSONDecoder().decode(ServerConfig.self, from: data)
    }

    private func saveServerConfig(_ config: ServerConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: serverConfigKey)
        }
    }

    // MARK: - Platform-specific bookmark options

    private static var creationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
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
