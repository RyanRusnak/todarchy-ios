import XCTest
@testable import todarchy

// MARK: - BodyEditorState

final class BodyEditorStateTests: XCTestCase {

    func test_initialState_isIdle_withEmptyDraft() {
        let s = BodyEditorState()
        XCTAssertFalse(s.isEditing)
        XCTAssertEqual(s.draft, "")
    }

    // MARK: Display

    func test_display_emptyCanonical_notEditing_isEmptyPlaceholder() {
        let s = BodyEditorState()
        XCTAssertEqual(s.display(canonical: ""), .emptyPlaceholder)
    }

    func test_display_nonEmptyCanonical_notEditing_isPreview() {
        let s = BodyEditorState()
        XCTAssertEqual(s.display(canonical: "hello"), .preview)
    }

    func test_display_editing_isAlwaysEditing_regardlessOfCanonical() {
        var s = BodyEditorState()
        s.beginEditing(seed: "abc")
        XCTAssertEqual(s.display(canonical: ""), .editing)
        XCTAssertEqual(s.display(canonical: "something"), .editing)
    }

    // MARK: Transitions

    func test_beginEditing_setsEditing_andSeedsDraft() {
        var s = BodyEditorState()
        s.beginEditing(seed: "hello")
        XCTAssertTrue(s.isEditing)
        XCTAssertEqual(s.draft, "hello")
    }

    func test_beginEditing_fromEmptySeed_keepsDraftEmpty() {
        var s = BodyEditorState()
        s.beginEditing(seed: "")
        XCTAssertTrue(s.isEditing)
        XCTAssertEqual(s.draft, "")
    }

    func test_escape_exitsEditing() {
        var s = BodyEditorState()
        s.beginEditing(seed: "hello")
        s.escape()
        XCTAssertFalse(s.isEditing)
    }

    func test_escape_keepsDraftIntact() {
        // The body editor writes drafts through to the canonical
        // store on every keystroke, so escape doesn't need to
        // discard. We assert the draft is *kept* so any future
        // change to that contract trips a test.
        var s = BodyEditorState()
        s.beginEditing(seed: "hello")
        s.draft = "hello world"
        s.escape()
        XCTAssertEqual(s.draft, "hello world")
    }

    // MARK: Sync from canonical

    func test_syncFromCanonical_notEditing_updatesDraft() {
        var s = BodyEditorState()
        s.syncFromCanonical("new content")
        XCTAssertEqual(s.draft, "new content")
    }

    func test_syncFromCanonical_editing_doesNotClobberDraft() {
        var s = BodyEditorState()
        s.beginEditing(seed: "original")
        s.draft = "typed by user"
        s.syncFromCanonical("external update")
        XCTAssertEqual(s.draft, "typed by user")
    }

    func test_syncFromCanonical_notEditing_sameValue_isNoop() {
        var s = BodyEditorState()
        s.draft = "abc"
        s.syncFromCanonical("abc")
        XCTAssertEqual(s.draft, "abc")
    }

    // MARK: Round trip — exercises the bug we're guarding against.

    func test_roundTrip_idleToEditingToIdle_returnsToPreview() {
        var s = BodyEditorState()
        // Initial: empty body → placeholder.
        XCTAssertEqual(s.display(canonical: ""), .emptyPlaceholder)
        // Tap placeholder → editing.
        s.beginEditing(seed: "")
        XCTAssertEqual(s.display(canonical: ""), .editing)
        // Type something.
        s.draft = "wrote a body"
        // Canonical updates as keystrokes flush through.
        XCTAssertEqual(s.display(canonical: "wrote a body"), .editing)
        // Escape exits editing.
        s.escape()
        // Now the canonical has content, so we render preview.
        XCTAssertEqual(s.display(canonical: "wrote a body"), .preview)
    }

    func test_taskSwitch_pattern_escapesAndResyncs() {
        // Mirrors what the view does on `task.id` change.
        var s = BodyEditorState()
        s.beginEditing(seed: "task A body")
        s.draft = "task A body, edited"
        // Simulate task switch.
        s.escape()
        s.syncFromCanonical("task B body")
        XCTAssertFalse(s.isEditing)
        XCTAssertEqual(s.draft, "task B body")
    }
}

// MARK: - CommentComposerState

final class CommentComposerStateTests: XCTestCase {

    func test_initialState_isPlaceholder_withEmptyDraft() {
        let s = CommentComposerState()
        XCTAssertFalse(s.isFocused)
        XCTAssertEqual(s.display, .placeholder)
        XCTAssertEqual(s.draft, "")
    }

    func test_beginEditing_transitionsToEditing() {
        var s = CommentComposerState()
        s.beginEditing()
        XCTAssertTrue(s.isFocused)
        XCTAssertEqual(s.display, .editing)
    }

    func test_escape_returnsToPlaceholder() {
        var s = CommentComposerState()
        s.beginEditing()
        s.escape()
        XCTAssertFalse(s.isFocused)
        XCTAssertEqual(s.display, .placeholder)
    }

    func test_escape_clearsDraft() {
        // Comments use escape-as-cancel semantics — discarding the
        // in-progress comment matches the user expectation of an
        // inline composer.
        var s = CommentComposerState()
        s.beginEditing()
        s.draft = "drafted but cancelling"
        s.escape()
        XCTAssertEqual(s.draft, "")
    }

    // MARK: canPost

    func test_canPost_emptyDraft_false() {
        var s = CommentComposerState()
        s.beginEditing()
        XCTAssertFalse(s.canPost)
    }

    func test_canPost_whitespaceOnlyDraft_false() {
        var s = CommentComposerState()
        s.beginEditing()
        s.draft = "   \n\t  "
        XCTAssertFalse(s.canPost)
    }

    func test_canPost_realText_true() {
        var s = CommentComposerState()
        s.beginEditing()
        s.draft = "hello"
        XCTAssertTrue(s.canPost)
    }

    func test_canPost_textWithSurroundingWhitespace_true() {
        var s = CommentComposerState()
        s.beginEditing()
        s.draft = "  hello  "
        XCTAssertTrue(s.canPost)
    }

    // MARK: didPost

    func test_didPost_clearsDraftAndExitsFocus() {
        var s = CommentComposerState()
        s.beginEditing()
        s.draft = "shipped it"
        s.didPost()
        XCTAssertFalse(s.isFocused)
        XCTAssertEqual(s.draft, "")
        XCTAssertEqual(s.display, .placeholder)
    }

    // MARK: Round trip

    func test_roundTrip_placeholderTapEditPostReturnsToPlaceholder() {
        var s = CommentComposerState()
        XCTAssertEqual(s.display, .placeholder)
        // User taps placeholder.
        s.beginEditing()
        XCTAssertEqual(s.display, .editing)
        // Types comment.
        s.draft = "looks good"
        XCTAssertTrue(s.canPost)
        // Posts.
        s.didPost()
        XCTAssertEqual(s.display, .placeholder)
        XCTAssertFalse(s.canPost)
    }

    func test_roundTrip_placeholderTapEditEscapeDiscards() {
        var s = CommentComposerState()
        s.beginEditing()
        s.draft = "second thoughts"
        s.escape()
        XCTAssertEqual(s.display, .placeholder)
        XCTAssertEqual(s.draft, "")
    }
}
