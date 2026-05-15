#if !os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// iOS/iPadOS settings sheet. Reached via the "Settings" button in the list-
/// switcher footer (iPhone) or from the iPad sidebar.
struct IOSSettingsSheet: View {
    @ObservedObject var settings = SyncSettings.shared
    @ObservedObject var masterKey = MasterKey.shared
    let persistence: TaskStorePersistence
    let onClose: () -> Void

    @State private var showPicker = false
    @State private var serverURLText: String = "https://todarchy-ryanrusnak.fly.dev"
    @State private var serverIdText: String = ""
    @State private var serverUrlError: String?
    @State private var serverIdError: String?
    @State private var healthCheck: String?
    /// Staged picker selection — separate from `settings.mode` so
    /// tapping "Server" reveals the config form before Connect fires.
    @State private var stagedKind: SyncMode.Kind = .localOnly
    @State private var showPassphraseSheet = false
    @State private var passphraseSheetMode: PassphraseSetupView.Mode = .createNew
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
        .onAppear {
            stagedKind = settings.mode.kind
            hydrateServerFields()
        }
        .onChange(of: settings.mode) { _, newMode in
            stagedKind = newMode.kind
        }
        .sheet(isPresented: $showPassphraseSheet) {
            PassphraseSetupView(
                mode: passphraseSheetMode,
                onSubmit: { passphrase in
                    switch passphraseSheetMode {
                    case .rotate:
                        try await persistence.rotatePassphrase(passphrase)
                    case .createNew, .enterExisting:
                        try await persistence.setupPassphrase(passphrase)
                    }
                    showPassphraseSheet = false
                },
                onCancel: { showPassphraseSheet = false }
            )
        }
    }

    // MARK: - Sections

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("SYNC")

            Picker("Sync via", selection: $stagedKind) {
                Text("Off").tag(SyncMode.Kind.localOnly)
                Text("Folder").tag(SyncMode.Kind.folder)
                Text("Server").tag(SyncMode.Kind.server)
            }
            .pickerStyle(.segmented)
            .onChange(of: stagedKind) { _, newKind in
                applyMode(kind: newKind)
            }

            SyncStatusBlock(settings: settings)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bgElev)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))

            switch stagedKind {
            case .folder: folderControls
            case .server: serverControls
            case .localOnly: EmptyView()
            }

            passphraseSection
            SyncExplanation()
        }
    }

    // MARK: - Passphrase

    @ViewBuilder
    private var passphraseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("PASSPHRASE")
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: passphraseStatusIcon)
                        .font(.system(size: 14))
                        .foregroundStyle(passphraseStatusTint)
                    Text(passphraseStatusText)
                        .font(Typo.mono(13))
                        .foregroundStyle(Theme.fg)
                    Spacer()
                    Button(passphraseButtonLabel) {
                        passphraseSheetMode = nextPassphraseMode
                        showPassphraseSheet = true
                    }
                    .font(Typo.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
                    )
                }
                Text(passphraseHelperText)
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bgElev)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
        }
    }

    private var passphraseStatusIcon: String {
        if masterKey.currentKey != nil { return "checkmark.circle.fill" }
        return persistence.hasShareKeysSalt ? "lock.fill" : "circle"
    }

    private var passphraseStatusTint: Color {
        if masterKey.currentKey != nil { return Theme.accent }
        return persistence.hasShareKeysSalt ? Theme.danger : Theme.fgMute
    }

    private var passphraseStatusText: String {
        if masterKey.currentKey != nil { return "Passphrase set" }
        return persistence.hasShareKeysSalt
            ? "Locked — passphrase required"
            : "No passphrase yet"
    }

    private var passphraseButtonLabel: String {
        if masterKey.currentKey != nil { return "Change…" }
        return persistence.hasShareKeysSalt ? "Unlock…" : "Set…"
    }

    private var passphraseHelperText: String {
        if masterKey.currentKey != nil {
            return "Shared lists you make or accept will propagate to your other devices automatically."
        }
        if persistence.hasShareKeysSalt {
            return "Another of your devices already set a passphrase. Enter it on this device to access shared lists."
        }
        return "Setting a passphrase lets shared lists sync across your own devices without re-opening share links on each."
    }

    /// `.rotate` when unlocked (Change), `.enterExisting` when locked
    /// but a peer device already set a passphrase, `.createNew`
    /// otherwise (first-time on this account).
    private var nextPassphraseMode: PassphraseSetupView.Mode {
        if masterKey.currentKey != nil { return .rotate }
        if persistence.hasShareKeysSalt { return .enterExisting }
        return .createNew
    }

    @ViewBuilder
    private var folderControls: some View {
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
                    persistence.refreshFromDisk()
                    settings.markMerged()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Refresh").font(Typo.mono(12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.fgDim)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var serverControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("server URL")
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgMute)
                TextField("https://…fly.dev", text: $serverURLText)
                    .textFieldStyle(.plain)
                    .font(Typo.mono(12))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .padding(10)
                    .background(Theme.bgSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                if let err = serverUrlError {
                    Text(err).font(Typo.mono(10)).foregroundStyle(Theme.danger)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("sync id (paste on other devices)")
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgMute)
                TextField("main_…", text: $serverIdText)
                    .textFieldStyle(.plain)
                    .font(Typo.mono(12))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .background(Theme.bgSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                HStack(spacing: 8) {
                    Button("Generate new id") {
                        serverIdText = ServerConfig.generateMainDocId()
                        serverIdError = nil
                    }
                    .buttonStyle(.plain)
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.4), lineWidth: 1))

                    Button("Copy") {
                        UIPasteboard.general.string = serverIdText
                    }
                    .buttonStyle(.plain)
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.fgDim)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    .disabled(serverIdText.isEmpty)
                }
                if let err = serverIdError {
                    Text(err).font(Typo.mono(10)).foregroundStyle(Theme.danger)
                }
            }

            HStack(spacing: 8) {
                Button(settings.mode.kind == .server ? "Apply" : "Connect") {
                    applyServerConfig()
                }
                .buttonStyle(.plain)
                .font(Typo.mono(12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.5), lineWidth: 1))

                Button("Test") { runHealthCheck() }
                .buttonStyle(.plain)
                .font(Typo.mono(12))
                .foregroundStyle(Theme.fgDim)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

                if settings.mode.kind == .server {
                    Button("Refresh") {
                        persistence.refreshFromDisk()
                        settings.markMerged()
                    }
                    .buttonStyle(.plain)
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.fgDim)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                }
            }

            if let msg = healthCheck {
                Text(msg)
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgDim)
            }
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

    // MARK: - Helpers

    private func applyMode(kind: SyncMode.Kind) {
        switch kind {
        case .localOnly:
            settings.clearSync(persistence)
        case .folder:
            if settings.syncFolderURL == nil { showPicker = true }
        case .server:
            break
        }
    }

    private func hydrateServerFields() {
        if case .server(let cfg) = settings.mode {
            serverURLText = cfg.baseURL.absoluteString
            serverIdText = cfg.mainDocId
        } else if serverIdText.isEmpty {
            serverIdText = ServerConfig.generateMainDocId()
        }
    }

    private func applyServerConfig() {
        serverUrlError = nil
        serverIdError = nil
        let urlString = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else {
            serverUrlError = "Enter a URL like https://todarchy-yourname.fly.dev"
            return
        }
        let id = serverIdText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ServerConfig.isValidDocId(id) else {
            serverIdError = "Id must be 1–64 chars, letters/digits/_/-"
            return
        }
        settings.setServer(ServerConfig(baseURL: url, mainDocId: id),
                           persistence: persistence)
        healthCheck = nil
    }

    private func runHealthCheck() {
        healthCheck = "checking…"
        let urlString = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString) else {
            healthCheck = "invalid URL"
            return
        }
        Task {
            let client = ServerSyncClient(baseURL: url)
            let ok = await client.healthz()
            await MainActor.run {
                healthCheck = ok ? "reachable ✓" : "unreachable"
            }
        }
    }
}
#endif
