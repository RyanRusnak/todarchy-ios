#if os(macOS)
import SwiftUI
import AppKit

/// macOS settings surface. The underlying `SyncSettings` type lives in
/// `Shared/` so iOS shares the persistence/bookmark logic.
struct SyncSettingsView: View {
    @ObservedObject var settings = SyncSettings.shared
    @ObservedObject var masterKey = MasterKey.shared
    let persistence: TaskStorePersistence

    @State private var showPicker = false
    @State private var serverURLText: String = "https://todarchy-ryanrusnak.fly.dev"
    @State private var serverIdText: String = ""
    @State private var serverUrlError: String?
    @State private var serverIdError: String?
    @State private var healthCheck: String?
    @State private var showPassphraseSheet = false
    @State private var passphraseSheetMode: PassphraseSetupView.Mode = .createNew

    /// The segment the user is viewing. Separate from `settings.mode` so
    /// tapping "Server" reveals the config form before Connect actually
    /// commits the mode change.
    @State private var stagedKind: SyncMode.Kind = .localOnly

    private let defaultServerURL = "https://todarchy-ryanrusnak.fly.dev"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SYNC")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.fgMute)

            modePicker
            SyncStatusBlock(settings: settings)
            modeControls
            passphraseSection
            SyncExplanation()
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 420)
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
        .onAppear {
            stagedKind = settings.mode.kind
            hydrateServerFields()
        }
        .onChange(of: settings.mode) { _, newMode in
            // Outside mutations (e.g. applyStartupConfiguration) should
            // drag the picker along.
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

    // MARK: - Passphrase section

    @ViewBuilder
    private var passphraseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PASSPHRASE")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.fgMute)
                .padding(.top, 4)
            HStack(spacing: 10) {
                Image(systemName: passphraseStatusIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(passphraseStatusTint)
                Text(passphraseStatusText)
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.fg)
                Spacer()
                Button(passphraseButtonLabel) {
                    passphraseSheetMode = nextPassphraseMode
                    showPassphraseSheet = true
                }
                .buttonStyle(.plain)
                .font(Typo.mono(12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.5), lineWidth: 1))
            }
            Text(passphraseHelperText)
                .font(Typo.mono(10))
                .foregroundStyle(Theme.fgFaint)
                .fixedSize(horizontal: false, vertical: true)
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
        return persistence.hasShareKeysSalt ? "Unlock…" : "Set passphrase…"
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

    /// Pick the right `PassphraseSetupView.Mode` for the button:
    ///   - unlocked              → `.rotate` (change)
    ///   - salt present + locked → `.enterExisting` (unlock)
    ///   - everything else       → `.createNew` (first-time setup)
    private var nextPassphraseMode: PassphraseSetupView.Mode {
        if masterKey.currentKey != nil { return .rotate }
        if persistence.hasShareKeysSalt { return .enterExisting }
        return .createNew
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("Sync via", selection: $stagedKind) {
            Text("Off").tag(SyncMode.Kind.localOnly)
            Text("Folder").tag(SyncMode.Kind.folder)
            Text("Server").tag(SyncMode.Kind.server)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: stagedKind) { _, newKind in
            applyMode(kind: newKind)
        }
    }

    private func applyMode(kind: SyncMode.Kind) {
        switch kind {
        case .localOnly:
            // Turn sync off immediately.
            settings.clearSync(persistence)
        case .folder:
            // Folder mode: prompt for a folder if we don't have one.
            if settings.syncFolderURL == nil { showPicker = true }
        case .server:
            // Reveal the server form. Don't commit until Connect.
            break
        }
    }

    // MARK: - Mode-specific controls

    @ViewBuilder
    private var modeControls: some View {
        switch stagedKind {
        case .folder:
            folderControls
        case .server:
            serverControls
        case .localOnly:
            EmptyView()
        }
    }

    private var folderControls: some View {
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

    private var serverControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("server URL")
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgMute)
                TextField("https://todarchy-…fly.dev", text: $serverURLText)
                    .textFieldStyle(.plain)
                    .font(Typo.mono(12))
                    .padding(8)
                    .background(Theme.bgSoft)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                if let err = serverUrlError {
                    Text(err).font(Typo.mono(10)).foregroundStyle(Theme.danger)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("sync id (paste on other devices to sync)")
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgMute)
                HStack(spacing: 6) {
                    TextField("main_…", text: $serverIdText)
                        .textFieldStyle(.plain)
                        .font(Typo.mono(12))
                        .padding(8)
                        .background(Theme.bgSoft)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

                    Button("Generate") {
                        serverIdText = ServerConfig.generateMainDocId()
                        serverIdError = nil
                    }
                    .buttonStyle(.plain)
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.4), lineWidth: 1))

                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(serverIdText, forType: .string)
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
                .padding(.horizontal, 12).padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.5), lineWidth: 1))

                Button("Test connection") { runHealthCheck() }
                .buttonStyle(.plain)
                .font(Typo.mono(12))
                .foregroundStyle(Theme.fgDim)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

                if settings.mode.kind == .server {
                    Button("Refresh") {
                        persistence.refreshFromDisk()
                        settings.markMerged()
                    }
                    .buttonStyle(.plain)
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.fgDim)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                }
            }

            if let msg = healthCheck {
                Text(msg)
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgDim)
            }
        }
    }

    // MARK: - Helpers

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
