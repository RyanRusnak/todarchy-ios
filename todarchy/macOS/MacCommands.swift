#if os(macOS)
import SwiftUI

extension Notification.Name {
    static let todarchyOpenPalette = Notification.Name("todarchy.openPalette")
    static let todarchyOpenCapture = Notification.Name("todarchy.openCapture")
    static let todarchyOpenSearch = Notification.Name("todarchy.openSearch")
    static let todarchyToggleInspector = Notification.Name("todarchy.toggleInspector")
    static let todarchyDeleteSelected = Notification.Name("todarchy.deleteSelected")
    static let todarchyUndo = Notification.Name("todarchy.undo")
    static let todarchyOpenDeferPicker = Notification.Name("todarchy.openDeferPicker")
    static let todarchyOpenSendTo = Notification.Name("todarchy.openSendTo")
    static let todarchyOpenProjectEditor = Notification.Name("todarchy.openProjectEditor")
    static let todarchySyncNow = Notification.Name("todarchy.syncNow")
    static let todarchyOpenVoiceCapture = Notification.Name("todarchy.openVoiceCapture")
}

struct TodarchyCommands: Commands {
    /// Resolved from the focused scene via `.focusedSceneObject(store)` in
    /// `MacRootView`. Lets menu items act on the active window's store
    /// directly instead of broadcasting a notification every view observes.
    @FocusedObject private var store: TaskStore?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") {
                NotificationCenter.default.post(name: .todarchyOpenCapture, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Task by Voice") {
                NotificationCenter.default.post(name: .todarchyOpenVoiceCapture, object: nil)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                NotificationCenter.default.post(name: .todarchyUndo, object: nil)
            }
            .keyboardShortcut("z", modifiers: .command)
        }

        CommandMenu("Task") {
            Button("Toggle Complete") {
                _ = store?.toggleSelectedDone()
            }
            .keyboardShortcut("x", modifiers: [])

            Button("Defer…") {
                NotificationCenter.default.post(name: .todarchyOpenDeferPicker, object: nil)
            }
            .keyboardShortcut("d", modifiers: .command)

            Divider()

            Button("Delete") {
                NotificationCenter.default.post(name: .todarchyDeleteSelected, object: nil)
            }
            .keyboardShortcut(.delete)
        }

        CommandMenu("Go") {
            Button("Command Palette") {
                NotificationCenter.default.post(name: .todarchyOpenPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("Search") {
                NotificationCenter.default.post(name: .todarchyOpenSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button("Sync Now") {
                NotificationCenter.default.post(name: .todarchySyncNow, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") {
                NotificationCenter.default.post(name: .todarchyToggleInspector, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
#endif
