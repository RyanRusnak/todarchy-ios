import SwiftUI

/// Read-only markdown renderer used by the task detail / inspector
/// body section.
///
/// Uses SwiftUI's built-in `AttributedString(markdown:)` with
/// `.inlineOnlyPreservingWhitespace` — handles **bold**, *italic*,
/// `code`, [links], and preserves raw newlines so multi-line "trip
/// plan" style content stays legible.
///
/// Block-level markdown (headings, lists, tables) isn't rendered as
/// such; it shows as plain text with the source markers visible. If
/// that becomes a sticking point in practice we can swap in
/// `MarkdownUI` or similar — for now the native approach has zero
/// dependencies and zero failure modes.
struct MarkdownText: View {
    let raw: String

    var body: some View {
        Text(parsed)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var parsed: AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: raw, options: opts))
            ?? AttributedString(raw)
    }
}
