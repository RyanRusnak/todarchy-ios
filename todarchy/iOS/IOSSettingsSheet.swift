#if !os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// iOS/iPadOS settings sheet. Reached via the "Settings" button in the list-
/// switcher footer (iPhone) or from the iPad sidebar.
struct IOSSettingsSheet: View {
    @ObservedObject var settings = SyncSettings.shared
    let persistence: TaskStorePersistence
    let onClose: () -> Void

    @State private var showPicker = false
    @AppStorage("theme.name") private var themeName: String = ThemePalette.tokyoNight.id

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    syncSection
                    diagnosticsSection
                    themeSection
                    aboutSection
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onClose() }
                }
            }
        }
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

    // MARK: - Sections

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("SYNC")
            SyncStatusBlock(settings: settings)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bgElev)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))

            HStack(spacing: 10) {
                Button {
                    showPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                        Text(settings.syncFolderURL == nil
                             ? "Pick sync folder…"
                             : "Change folder…")
                            .font(Typo.mono(13, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)

                if settings.syncFolderURL != nil {
                    Button {
                        settings.clearFolder(persistence)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle")
                            Text("Stop syncing")
                                .font(Typo.mono(13))
                        }
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.danger.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            if settings.syncFolderURL != nil {
                Button {
                    persistence.refreshFromDisk()
                    settings.markMerged()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Refresh from sync folder")
                            .font(Typo.mono(12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.fgDim)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            SyncExplanation()
        }
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("THEME")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(ThemePalette.allPalettes, id: \.id) { palette in
                    themeChip(palette)
                }
            }
        }
    }

    private func themeChip(_ palette: ThemePalette) -> some View {
        let selected = palette.id == themeName
        return Button {
            // Update the static BEFORE flipping @AppStorage. The `.id()`
            // rebuild on the root view fires the moment themeName changes,
            // and we need ThemePalette.current to already hold the new
            // value so the rebuilt tree picks up the new colors — not the
            // stale ones from app launch.
            ThemePalette.current = palette
            themeName = palette.id
        } label: {
            HStack(spacing: 10) {
                swatches(for: palette)
                VStack(alignment: .leading, spacing: 2) {
                    Text(palette.id)
                        .font(Typo.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                    Text(labelFor(palette))
                        .font(Typo.mono(10))
                        .foregroundStyle(Theme.fgMute)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(palette.accent)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.accent.opacity(0.14) : Theme.bgElev)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? palette.accent.opacity(0.6) : Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func swatches(for palette: ThemePalette) -> some View {
        HStack(spacing: 2) {
            ForEach([palette.bg, palette.accent, palette.accent2, palette.success], id: \.self) { c in
                Rectangle().fill(c).frame(width: 6, height: 22)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func labelFor(_ palette: ThemePalette) -> String {
        switch palette.id {
        case "tokyoNight": return "blue / magenta"
        case "catppuccin": return "pastel / cozy"
        case "gruvbox": return "amber / retro"
        case "ubuntu": return "orange / aubergine"
        default: return ""
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("DIAGNOSTICS")
            SyncDiagnosticsView()
                .frame(minHeight: 420)
                .background(Theme.bgElev)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("ABOUT")
            VStack(alignment: .leading, spacing: 4) {
                Text("todarchy")
                    .font(Typo.mono(16, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text("font: JetBrains Mono")
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgMute)
                Text("device id: \(DeviceID.current)")
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgFaint)
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bgElev)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Typo.mono(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.fgMute)
    }
}
#endif
