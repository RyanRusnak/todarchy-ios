import SwiftUI
import MarkdownUI

/// Read-only markdown renderer used by the task detail / inspector
/// body section.
///
/// Renders block-level markdown (headings, lists, code blocks, tables)
/// via `MarkdownUI` — proper layout, not just inline styling. Themed
/// to match the app's mono + dark aesthetic.
///
/// Used for both the iOS detail sheet's body preview and the macOS /
/// iPad inspector's body preview. Editing still goes through the
/// `TextEditor` path elsewhere in those views; this view is
/// strictly the rendered preview state.
struct MarkdownText: View {
    let raw: String

    var body: some View {
        Markdown(raw)
            .markdownTheme(.todarchy)
            .textSelection(.enabled)
    }
}

private extension Theme {
    static let codeBg = Color.black.opacity(0.30)
}

extension MarkdownUI.Theme {
    /// Custom MarkdownUI theme tuned to the existing Typo + Theme
    /// palette. Headings stay mono-weighted to fit the app's vibe;
    /// body text uses the same `Typo.mono(13)` the inspector text
    /// blocks use; links pop in the accent color.
    static let todarchy = MarkdownUI.Theme()
        .text {
            FontFamily(.custom("JetBrainsMono-Regular"))
            FontSize(13)
            ForegroundColor(Theme.fgDim)
        }
        .strong {
            FontWeight(.semibold)
            ForegroundColor(Theme.fg)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .link {
            ForegroundColor(Theme.accent)
        }
        .code {
            FontFamilyVariant(.monospaced)
            ForegroundColor(Theme.accent2)
            BackgroundColor(Theme.codeBg)
        }
        .heading1 { config in
            config.label
                .markdownTextStyle {
                    FontFamily(.custom("JetBrainsMono-Bold"))
                    FontSize(18)
                    ForegroundColor(Theme.fg)
                }
                .markdownMargin(top: 14, bottom: 6)
        }
        .heading2 { config in
            config.label
                .markdownTextStyle {
                    FontFamily(.custom("JetBrainsMono-Bold"))
                    FontSize(15)
                    ForegroundColor(Theme.fg)
                }
                .markdownMargin(top: 12, bottom: 4)
        }
        .heading3 { config in
            config.label
                .markdownTextStyle {
                    FontFamily(.custom("JetBrainsMono-SemiBold"))
                    FontSize(13)
                    ForegroundColor(Theme.fg)
                }
                .markdownMargin(top: 10, bottom: 4)
        }
        .paragraph { config in
            config.label
                .markdownMargin(top: 0, bottom: 8)
        }
        .listItem { config in
            config.label
                .markdownMargin(top: 2, bottom: 2)
        }
        .codeBlock { config in
            ScrollView(.horizontal) {
                config.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(12)
                        ForegroundColor(Theme.fgDim)
                    }
                    .padding(10)
            }
            .background(Theme.codeBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .markdownMargin(top: 6, bottom: 8)
        }
        .blockquote { config in
            config.label
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.accent.opacity(0.4)).frame(width: 2)
                }
                .markdownMargin(top: 4, bottom: 8)
        }
}
