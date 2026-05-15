import SwiftUI

@main
struct TodarchyApp: App {
    @StateObject private var store = TaskStore()
    @AppStorage("theme.name") private var themeName: String = ThemePalette.tokyoNight.id
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FontRegistrar.register()
        let saved = UserDefaults.standard.string(forKey: "theme.name") ?? ThemePalette.tokyoNight.id
        ThemePalette.current = ThemePalette.named(saved)
        // Resolve any previously-saved sync folder bookmark and point the
        // shared persistence at it BEFORE TaskStore's first save runs.
        // Without this, the first save after every launch goes to
        // Application Support instead of the user's Dropbox/iCloud folder.
        SyncSettings.shared.applyStartupConfiguration()
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .id(themeName)
                .onChange(of: themeName) { _, name in
                    ThemePalette.current = ThemePalette.named(name)
                }
                .onChange(of: scenePhase) { _, phase in
                    // Switching back to the app pulls the latest
                    // bytes — same pattern iOS uses. The 10 s timer
                    // covers passive viewing; this catches "I was on
                    // another app and just came back" instantly.
                    if phase == .active {
                        TaskStorePersistence.shared.refreshFromDisk()
                    }
                }
                .onOpenURL { url in handleIncomingURL(url) }
                .task {
                    DeferNotifier.shared.attach(store: store)
                    DeferNotifier.shared.start()

                    GlobalHotkey.shared.onFire = {
                        NSApp.activate(ignoringOtherApps: true)
                        NotificationCenter.default.post(
                            name: .todarchyOpenCapture, object: nil
                        )
                    }
                    GlobalHotkey.shared.register()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1280, height: 820)
        .commands {
            TodarchyCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra {
            MenuBarExtraView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .id(themeName)
        } label: {
            MenuBarBadge()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .id(themeName)
                .onChange(of: themeName) { _, name in
                    // Keep the static palette in sync with @AppStorage so
                    // theme swaps take effect on iOS without an app kill.
                    ThemePalette.current = ThemePalette.named(name)
                }
                .onChange(of: scenePhase) { _, phase in
                    // iOS's DispatchSource file watcher doesn't fire for
                    // file-provider-driven changes (Dropbox, iCloud, etc.).
                    // Pull fresh bytes + merge every time we foreground.
                    if phase == .active {
                        TaskStorePersistence.shared.refreshFromDisk()
                    }
                }
                .onOpenURL { url in handleIncomingURL(url) }
        }
        #endif
    }

    /// Dispatch incoming `todarchy://…` URLs to the right handler. Right
    /// now the only scheme path is `share/`, but we branch on it so new
    /// URL types (e.g. a future `project/`) plug in cleanly.
    @MainActor
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == ShareLink.scheme else { return }
        if url.host == "share" {
            acceptShareLink(url)
        }
    }

    @MainActor
    private func acceptShareLink(_ url: URL) {
        guard let manager = SyncSettings.shared.sharedProjectManager else {
            // The link carries the decryption key, but the encrypted
            // .tdshared file is delivered through the sync transport.
            // Without a transport configured, there's no path to the
            // bytes — surface that explicitly so testers don't think
            // the link is broken.
            SyncSettings.shared.shareLinkAlert =
                "Shared lists need Sync set up first. Open Settings → Sync to connect to a sync server, then re-open the link."
            return
        }
        do {
            let project = try store.acceptShareLink(url, manager: manager)
            // Jump to the newly-joined project so the user sees their
            // collaborator's tasks immediately.
            store.activeSelection = .list(project.id)
            store.activeContextFilter = nil
        } catch {
            #if DEBUG
            print("todarchy: couldn't accept share link: \(error.localizedDescription)")
            #endif
        }
    }
}

struct RootView: View {
    @ObservedObject private var syncSettings = SyncSettings.shared

    var body: some View {
        platformRoot
            .alert(
                "Sync Required",
                isPresented: Binding(
                    get: { syncSettings.shareLinkAlert != nil },
                    set: { if !$0 { syncSettings.shareLinkAlert = nil } }
                ),
                presenting: syncSettings.shareLinkAlert
            ) { _ in
                Button("OK", role: .cancel) { syncSettings.shareLinkAlert = nil }
            } message: { text in
                Text(text)
            }
    }

    @ViewBuilder
    private var platformRoot: some View {
        #if os(macOS)
        MacRootView()
        #else
        AdaptiveRootView()
        #endif
    }
}

#if !os(macOS)
struct AdaptiveRootView: View {
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        if hSize == .regular {
            IPadRootView()
        } else {
            IOSRootView()
        }
    }
}
#endif
