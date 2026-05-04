#if os(macOS)
import SwiftUI
import AppKit

/// macOS settings surface. The underlying `SyncSettings` type lives in
/// `Shared/` so iOS shares the persistence/bookmark logic.
struct SyncSettingsView: View {
    @ObservedObject var settings = SyncSettings.shared
    let persistence: TaskStorePersistence

    @State private var showPicker = false
    @State private var serverURLText: String = "https://todarchy-ryanrusnak.fly.dev"
    @State private var serverIdText: String = ""
    @State private var serverUrlError: String?
    @State private var serverIdError: String?
    @State private var healthCheck: String?

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
