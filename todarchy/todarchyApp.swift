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
        }
        #endif
    }
}

struct RootView: View {
    var body: some View {
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
