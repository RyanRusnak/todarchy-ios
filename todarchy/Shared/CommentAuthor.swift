import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Where comment authorship comes from. v1 stores the display name in
/// `UserDefaults` (per-device, not synced), defaulting to a best-guess
/// from the device name. The user can change it in Settings.
///
/// Synced cross-device identity is intentionally deferred: storing it
/// in the main doc would require a small migration and an "edit
/// display name" sheet on every device, and the v1 use case (two-
/// person family + Claude) is fine with per-device defaults that you
/// can tweak if they bother you.
///
/// Claude (via the future MCP server) reads its author name from an
/// env var and calls `addComment(author:)` directly, bypassing this.
enum CommentAuthor {
    private static let defaultsKey = "todarchy.comment.displayName"

    /// The display name stamped on new comments. Reads from
    /// UserDefaults; falls back to a sensible device-derived default.
    static var current: String {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey),
           !stored.trimmingCharacters(in: .whitespaces).isEmpty {
            return stored
        }
        return platformDefault
    }

    static func setCurrent(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: defaultsKey)
        }
    }

    private static var platformDefault: String {
        #if os(iOS)
        // `UIDevice.current.name` returns the user's chosen device
        // name on iOS 16+ ("Ryan's iPhone"). Reasonable default.
        return UIDevice.current.name
        #elseif os(macOS)
        // ProcessInfo.hostName drops the `.local` suffix on most
        // setups and works without an entitlement.
        let host = ProcessInfo.processInfo.hostName
        if let trimmed = host.components(separatedBy: ".").first, !trimmed.isEmpty {
            return trimmed
        }
        return "Me"
        #else
        return "Me"
        #endif
    }
}
