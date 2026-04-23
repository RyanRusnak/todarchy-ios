#if !os(macOS)
import SwiftUI
import Combine

/// Transient "deleted X · Undo" banner shown after a swipe-delete. Lives
/// for 4 seconds unless the user taps Undo (which fires the closure and
/// clears immediately). The store handles the actual undo via its
/// snapshot-based history stack — we just trigger it.
@MainActor
final class IOSUndoToast: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let action: () -> Void

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var entry: Entry?
    private var dismissTask: Task<Void, Never>?

    func show(deletedTitle: String, undo: @escaping () -> Void) {
        dismissTask?.cancel()
        let display = deletedTitle.isEmpty ? "task" : deletedTitle
        let entry = Entry(title: display, action: undo)
        self.entry = entry
        // Auto-dismiss after 4s — long enough to react, short enough to
        // not pile up toasts when the user is deleting in a burst.
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.entry?.id == entry.id {
                    self?.entry = nil
                }
            }
        }
    }

    func performUndo() {
        entry?.action()
        entry = nil
        dismissTask?.cancel()
    }

    func dismiss() {
        entry = nil
        dismissTask?.cancel()
    }
}

struct IOSUndoToastView: View {
    @ObservedObject var toast: IOSUndoToast

    var body: some View {
        if let entry = toast.entry {
            HStack(spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.fgDim)
                Text("deleted")
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.fgMute)
                Text("\"\(entry.title)\"")
                    .font(Typo.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button {
                    toast.performUndo()
                } label: {
                    Text("undo")
                        .font(Typo.mono(12, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.bgElev)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(entry.id)   // force transition to re-fire when a new toast replaces an old one
        }
    }
}
#endif
