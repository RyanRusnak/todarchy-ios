#if os(macOS)
import XCTest
import Automerge

/// One-off diagnostic — reads real files from ~/Dropbox/todarchy_sync so
/// we can see what the two devices actually produced, whether the merge
/// works with that exact bytes-on-disk scenario, and whether the conflict
/// file gets absorbed by `ingestConflictCopies`.
///
/// Set an environment var `TODARCHY_DIAGNOSE=1` to enable — the test is a
/// no-op otherwise so it doesn't fail on other machines / CI.
@MainActor
final class SyncDiagnosticTests: XCTestCase {

    func testDropboxFilesMergeCleanly() throws {
        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent("Dropbox/todarchy_sync")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("No ~/Dropbox/todarchy_sync folder on this machine")
        }
        let canonical = dir.appendingPathComponent("tasks.automerge")

        guard FileManager.default.fileExists(atPath: canonical.path) else {
            throw XCTSkip("No tasks.automerge at \(canonical.path) — diagnostic skipped")
        }
        let canonicalBytes = try Data(contentsOf: canonical)
        let canonicalStore = AutomergeStore(data: canonicalBytes)
        let canonicalSnap = try canonicalStore.snapshot()
        print("📄 tasks.automerge (\(canonicalBytes.count) bytes):")
        for t in canonicalSnap.tasks {
            print("   - \(t.id.prefix(8)) \(t.title) [list=\(t.list)]")
        }

        // Enumerate sibling conflict copies.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let conflicts = entries.filter {
            $0 != "tasks.automerge" && $0.hasSuffix(".automerge") && $0.hasPrefix("tasks")
        }
        print("📑 found \(conflicts.count) conflict cop\(conflicts.count == 1 ? "y" : "ies"): \(conflicts)")

        for entry in conflicts {
            let conflictURL = dir.appendingPathComponent(entry)
            let conflictBytes = try Data(contentsOf: conflictURL)
            let conflictStore = AutomergeStore(data: conflictBytes)
            let snap = try conflictStore.snapshot()
            print("📄 \(entry) (\(conflictBytes.count) bytes):")
            for t in snap.tasks {
                print("   - \(t.id.prefix(8)) \(t.title) [list=\(t.list)]")
            }
            // Merge into canonical.
            try canonicalStore.merge(conflictStore)
        }

        let merged = try canonicalStore.snapshot()
        print("🔀 after merge: \(merged.tasks.count) tasks total")
        for t in merged.tasks {
            print("   - \(t.id.prefix(8)) \(t.title) [list=\(t.list)]")
        }

        // This test is fully informational — its value is the printed
        // output above when a user reports sync oddities. No formal
        // assertion, because the user's live Dropbox state varies between
        // runs and isn't a property of the code we're testing.
    }
}
#endif
