#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Testable routing

struct KeyModifiers: OptionSet, Hashable {
    let rawValue: Int
    static let command = KeyModifiers(rawValue: 1 << 0)
    static let option  = KeyModifiers(rawValue: 1 << 1)
    static let control = KeyModifiers(rawValue: 1 << 2)
    static let shift   = KeyModifiers(rawValue: 1 << 3)

    static func from(_ ns: NSEvent.ModifierFlags) -> KeyModifiers {
        let masked = ns.intersection(.deviceIndependentFlagsMask)
        var m: KeyModifiers = []
        if masked.contains(.command) { m.insert(.command) }
        if masked.contains(.option)  { m.insert(.option) }
        if masked.contains(.control) { m.insert(.control) }
        if masked.contains(.shift)   { m.insert(.shift) }
        return m
    }
}

enum MacKeyCode {
    static let upArrow: UInt16 = 126
    static let downArrow: UInt16 = 125
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let returnKey: UInt16 = 36
    static let numpadEnter: UInt16 = 76
    static let escape: UInt16 = 53
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let tab: UInt16 = 48
}

enum MainKeyIntent: Equatable {
    case selectNext
    case selectPrevious
    case selectFirst
    case selectLast
    case selectNextList
    case selectPreviousList
    case moveSelectedDown
    case moveSelectedUp
    case toggleComplete
    case deleteSelected
    case deferSelected
    case openCapture
    case openPalette
    case openSearch
    case toggleInspector
    case toggleShowDone
    case toggleShowDeferred
    case clearFilters
    case gotoList(Int)              // 0 = inbox, 1..N = project index
    case moveSelectedToList(Int)    // same indexing
    case editSelected
    case indentSelected
    case outdentSelected
    case toggleCollapseSelected
    case openProjectEditor
    case undo
    case pass
}

/// Pure key routing for the main window. Holds a small leader-key buffer for
/// vim-style two-character sequences (`dd`, `gg`, `fd`, `fs`, `gi`, `g1`–`g5`,
/// `mi`, `m1`–`m5`).
struct MainKeyRouter {
    var pendingLeader: (key: Character, at: Date)?
    var leaderWindow: TimeInterval = 0.6

    mutating func route(
        chars: String,
        keyCode: UInt16,
        modifiers: KeyModifiers = [],
        now: Date = Date()
    ) -> MainKeyIntent {
        // Skip when any modifier outside shift is held — those are reserved for
        // menu shortcuts (⌘N, ⌘K, etc.) which have their own handlers.
        if !modifiers.subtracting(.shift).isEmpty {
            pendingLeader = nil
            return .pass
        }

        let shifted = modifiers.contains(.shift)

        // Key-code first (arrows, return, delete, escape). All of these clear
        // any pending leader — a sequence must be two characters back-to-back.
        switch keyCode {
        case MacKeyCode.downArrow:
            pendingLeader = nil
            return shifted ? .moveSelectedDown : .selectNext
        case MacKeyCode.upArrow:
            pendingLeader = nil
            return shifted ? .moveSelectedUp : .selectPrevious
        case MacKeyCode.leftArrow:
            pendingLeader = nil; return .selectPreviousList
        case MacKeyCode.rightArrow:
            pendingLeader = nil; return .selectNextList
        case MacKeyCode.returnKey, MacKeyCode.numpadEnter:
            pendingLeader = nil; return .openCapture
        case MacKeyCode.delete, MacKeyCode.forwardDelete:
            pendingLeader = nil; return .deleteSelected
        case MacKeyCode.escape:
            pendingLeader = nil; return .clearFilters
        case MacKeyCode.tab:
            pendingLeader = nil
            return shifted ? .outdentSelected : .indentSelected
        default: break
        }

        // If a leader is pending and still within the window, try to resolve
        // the two-character sequence. Unresolved pairs fall through to the
        // single-key switch (so `dj` clears pending and runs `j`).
        if let pending = pendingLeader, now.timeIntervalSince(pending.at) < leaderWindow {
            pendingLeader = nil
            if let intent = Self.resolveSequence(leader: pending.key, next: chars) {
                return intent
            }
        } else {
            pendingLeader = nil
        }

        switch chars {
        case "j": return .selectNext
        case "k": return .selectPrevious
        case "J": return .moveSelectedDown
        case "K": return .moveSelectedUp
        case "x", " ": return .toggleComplete
        case "o", "O", "a": return .openCapture
        case "s": return .deferSelected
        case "i": return .toggleInspector
        case "e": return .editSelected
        case "z": return .toggleCollapseSelected
        case "u": return .undo
        case "/": return .openSearch
        case ":", "?": return .openPalette
        case "G": return .selectLast

        // Plain digits jump to a list directly (0 = inbox, 1..N = project).
        case "0": return .gotoList(0)
        case "1": return .gotoList(1)
        case "2": return .gotoList(2)
        case "3": return .gotoList(3)
        case "4": return .gotoList(4)
        case "5": return .gotoList(5)

        // Leaders — swallow the key and wait for a follow-up.
        case "g", "d", "f", "m":
            pendingLeader = (Character(chars), now)
            return .pass

        default:
            return .pass
        }
    }

    /// Resolve a two-character vim-style sequence. Returns nil for unknown pairs.
    private static func resolveSequence(leader: Character, next: String) -> MainKeyIntent? {
        switch (leader, next) {
        case ("g", "g"): return .selectFirst
        case ("g", "i"): return .gotoList(0)
        case ("g", "n"): return .openProjectEditor
        case ("g", "1"): return .gotoList(1)
        case ("g", "2"): return .gotoList(2)
        case ("g", "3"): return .gotoList(3)
        case ("g", "4"): return .gotoList(4)
        case ("g", "5"): return .gotoList(5)
        case ("d", "d"): return .deleteSelected
        case ("f", "d"): return .toggleShowDone
        case ("f", "s"): return .toggleShowDeferred
        case ("m", "i"): return .moveSelectedToList(0)
        case ("m", "1"): return .moveSelectedToList(1)
        case ("m", "2"): return .moveSelectedToList(2)
        case ("m", "3"): return .moveSelectedToList(3)
        case ("m", "4"): return .moveSelectedToList(4)
        case ("m", "5"): return .moveSelectedToList(5)
        default: return nil
        }
    }
}

enum PaletteKeyIntent: Equatable {
    case moveUp
    case moveDown
    case commit
    case cancel
    case pass
}

/// Pure key routing for the command palette.
enum PaletteKeyRouter {
    static func route(chars: String, keyCode: UInt16, modifiers: KeyModifiers = []) -> PaletteKeyIntent {
        switch keyCode {
        case MacKeyCode.upArrow: return .moveUp
        case MacKeyCode.downArrow: return .moveDown
        case MacKeyCode.returnKey, MacKeyCode.numpadEnter: return .commit
        case MacKeyCode.escape: return .cancel
        default: break
        }
        if modifiers.contains(.control) {
            switch chars {
            case "n": return .moveDown
            case "p": return .moveUp
            default: break
            }
        }
        return .pass
    }
}

// MARK: - Monitor for the main window

/// Owns a local key-down monitor and applies main-window intents to the store.
@MainActor
final class MacMainKeyMonitor: ObservableObject {
    weak var store: TaskStore?
    var paletteShowing = false
    var captureShowing = false
    var searchShowing = false
    private var router = MainKeyRouter()
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }

    /// Decide whether to consume an incoming event.
    func handle(_ event: NSEvent) -> Bool {
        if paletteShowing || captureShowing || searchShowing { return false }
        if store?.editingTaskId != nil { return false }
        if MacFocusInspector.firstResponderIsEditable() { return false }
        let chars = event.charactersIgnoringModifiers ?? ""
        let mods = KeyModifiers.from(event.modifierFlags)
        let intent = router.route(chars: chars, keyCode: event.keyCode, modifiers: mods)
        return apply(intent)
    }

    /// Apply a routed intent. Exposed for unit testing.
    @discardableResult
    func apply(_ intent: MainKeyIntent) -> Bool {
        switch intent {
        case .selectNext: store?.selectNext(); return true
        case .selectPrevious: store?.selectPrevious(); return true
        case .selectFirst: store?.selectFirst(); return true
        case .selectLast: store?.selectLast(); return true
        case .toggleComplete:
            // Posted instead of mutating the store directly so the
            // selected `TaskRow` runs its own animated `handleToggle`
            // (fill + pulse + strikethrough), matching the click path.
            NotificationCenter.default.post(name: .todarchyToggleDone, object: nil)
            return true
        case .deleteSelected: store?.deleteSelected(); return true
        case .deferSelected:
            // Route s to the picker sheet instead of applying the 24h default.
            // A future `S` / capital-S binding could snap to 24h if we want it back.
            NotificationCenter.default.post(name: .todarchyOpenDeferPicker, object: nil)
            return true
        case .openCapture:
            NotificationCenter.default.post(name: .todarchyOpenCapture, object: nil)
            return true
        case .openPalette:
            NotificationCenter.default.post(name: .todarchyOpenPalette, object: nil)
            return true
        case .openSearch:
            NotificationCenter.default.post(name: .todarchyOpenSearch, object: nil)
            return true
        case .toggleInspector:
            NotificationCenter.default.post(name: .todarchyToggleInspector, object: nil)
            return true
        case .moveSelectedDown: store?.moveSelectedDown(); return true
        case .moveSelectedUp: store?.moveSelectedUp(); return true
        case .selectNextList: store?.selectNextList(); return true
        case .selectPreviousList: store?.selectPreviousList(); return true
        case .toggleShowDone: store?.showDone.toggle(); return true
        case .toggleShowDeferred: store?.showDeferred.toggle(); return true
        case .clearFilters:
            guard let store else { return false }
            if store.clearContextFilter() { return true }
            // No filter was active — still consume the key so it doesn't
            // leak into random views below.
            return false
        case .gotoList(let i): store?.gotoList(at: i); return true
        case .moveSelectedToList(let i): store?.moveSelectedToList(at: i); return true
        case .editSelected:
            guard let store, let sid = store.selectedTaskId else { return false }
            store.editingTaskId = sid
            return true
        case .indentSelected: return store?.indentSelected() ?? false
        case .outdentSelected: return store?.outdentSelected() ?? false
        case .toggleCollapseSelected: return store?.toggleCollapseSelected() ?? false
        case .openProjectEditor:
            NotificationCenter.default.post(name: .todarchyOpenProjectEditor, object: nil)
            return true
        case .undo: store?.undo(); return true
        case .pass: return false
        }
    }
}

// MARK: - Palette monitor

/// Local key monitor for the command palette. Intercepts navigation keys
/// before the palette's text field can see them.
@MainActor
final class MacPaletteKeyMonitor: ObservableObject {
    weak var model: CommandPaletteModel?
    var onClose: (() -> Void)?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    func handle(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers ?? ""
        let mods = KeyModifiers.from(event.modifierFlags)
        let intent = PaletteKeyRouter.route(chars: chars, keyCode: event.keyCode, modifiers: mods)
        return apply(intent)
    }

    @discardableResult
    func apply(_ intent: PaletteKeyIntent) -> Bool {
        switch intent {
        case .moveUp: model?.moveUp(); return true
        case .moveDown: model?.moveDown(); return true
        case .commit:
            guard let model else { return false }
            if model.execute() { onClose?(); return true }
            return false
        case .cancel:
            onClose?(); return true
        case .pass:
            return false
        }
    }
}

// MARK: - First-responder inspection

enum MacFocusInspector {
    /// True when the active window's first responder is an editable text control.
    static func firstResponderIsEditable() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        let fr = window.firstResponder
        if let tv = fr as? NSTextView { return tv.isEditable }
        if fr is NSText { return true }
        return false
    }
}
#endif
