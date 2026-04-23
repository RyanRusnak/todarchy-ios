#if os(macOS)
import SwiftUI
import AppKit

/// macOS settings surface. The underlying `SyncSettings` type lives in
/// `Shared/` so iOS shares the persistence/bookmark logic.
struct SyncSettingsView: View {
    @ObservedObject var settings = SyncSettings.shared
    let persistence: TaskStorePersistence

    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SYNC")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.fgMute)

            SyncStatusBlock(settings: settings)

            HStack(spacing: 10) {
                Button(settings.syncFolderURL == nil ? "Pick sync folder…" : "Change folder…") {
                    showPicker = true
                }
                .buttonStyle(.plain)
                .font(Typo.mono(12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.5), lineWidth: 1))

                if settings.syncFolderURL != nil {
                    Button("Stop syncing") {
                        settings.clearFolder(persistence)
                    }
                    .buttonStyle(.plain)
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.danger.opacity(0.5), lineWidth: 1))

                    Button("Refresh") {
                        persistence.refreshFromDisk()
                        settings.markMerged()
                    }
                    .buttonStyle(.plain)
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.fgDim)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                }
            }

            SyncExplanation()

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 280)
        .background(Theme.bg)
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                settings.setFolder(url, persistence: persistence)
            }
        }
    }
}
#endif
