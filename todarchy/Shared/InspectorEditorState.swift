import Foundation

/// State machine driving the inspector's body editor. Owns the
/// transition between rendered markdown preview, empty-state
/// placeholder, and active edit mode.
///
/// Lifted out of `TaskInspectorContent` so the focus/draft logic is
/// unit-testable without spinning up a SwiftUI host. The view binds
/// its `@FocusState` to `isEditing` — this struct doesn't touch
/// SwiftUI focus machinery, only the logical state.
struct BodyEditorState: Equatable {
    enum Display: Equatable {
        case editing
        case emptyPlaceholder
        case preview
    }

    private(set) var isEditing: Bool = false
    var draft: String = ""

    mutating func beginEditing(seed: String) {
        draft = seed
        isEditing = true
    }

    mutating func escape() {
        isEditing = false
    }

    /// Resync the draft from the canonical note (e.g. switching the
    /// selected task or an external sync write). Skipped while
    /// editing so an in-progress edit isn't clobbered.
    mutating func syncFromCanonical(_ note: String) {
        guard !isEditing else { return }
        if draft != note { draft = note }
    }

    func display(canonical: String) -> Display {
        if isEditing { return .editing }
        if canonical.isEmpty { return .emptyPlaceholder }
        return .preview
    }
}

/// State machine for the inspector's comment composer. Default
/// state is `.placeholder` — the `TextField` is gated behind an
/// explicit tap so macOS doesn't auto-promote it to first responder
/// when the inspector appears.
struct CommentComposerState: Equatable {
    enum Display: Equatable {
        case editing
        case placeholder
    }

    private(set) var isFocused: Bool = false
    var draft: String = ""

    mutating func beginEditing() {
        isFocused = true
    }

    /// Escape cancels the in-progress comment entirely.
    mutating func escape() {
        isFocused = false
        draft = ""
    }

    mutating func didPost() {
        draft = ""
        isFocused = false
    }

    var canPost: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var display: Display {
        isFocused ? .editing : .placeholder
    }
}
