import SwiftUI

/// Cross-platform sheet for setting or entering the sync passphrase.
///
/// Two modes:
///   - `.createNew` (no salt on the doc yet) — generate or type a
///     fresh passphrase, with a confirm field to catch typos. A
///     "Generate strong passphrase" button populates the field with
///     six random words from `PassphraseGenerator`.
///   - `.enterExisting` (salt already on the doc, set by another of
///     the user's devices) — single passphrase field, no confirm,
///     since we'll validate against the existing sealed cipher and
///     surface a clear error on wrong passphrase.
///
/// The view doesn't talk to `ShareKeysSync` directly — the caller
/// supplies `onSubmit` to wire up whatever flow makes sense in its
/// context (settings vs. share-required prompt vs. migration).
struct PassphraseSetupView: View {
    enum Mode: Equatable {
        case createNew
        case enterExisting
        /// Change an existing passphrase. UI mirrors `.createNew`
        /// but uses warning copy because rotation forces every other
        /// device to re-enter the new passphrase.
        case rotate
    }

    let mode: Mode
    /// Caller-supplied async work. Receives the entered passphrase.
    /// Throwing surfaces as a user-visible error string.
    let onSubmit: (String) async throws -> Void
    let onCancel: () -> Void

    @State private var passphrase: String = ""
    @State private var confirm: String = ""
    @State private var showPassphrase: Bool = false
    @State private var errorText: String?
    @State private var isSubmitting: Bool = false
    @FocusState private var passphraseFocused: Bool

    /// Minimum acceptable passphrase length. Argon2 protects against
    /// brute force, but only up to the entropy of the secret — short
    /// passphrases collapse quickly. 12 chars + Argon2 ≈ 50–60 bits
    /// effective, which is the floor we accept for typed passphrases.
    /// The "Generate strong" button produces ~24-char passphrases for
    /// users who don't want to think about it.
    static let minimumLength: Int = 12

    /// `.createNew` and `.rotate` both ask for a new passphrase with
    /// confirmation. `.enterExisting` is the only single-field mode.
    private var needsConfirmField: Bool {
        mode != .enterExisting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            passphraseField
            if needsConfirmField {
                confirmField
            }
            if let err = errorText {
                Text(err)
                    .font(Typo.mono(11))
                    .foregroundStyle(Theme.danger)
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.fgDim)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    .disabled(isSubmitting)

                Button(submitLabel, action: submit)
                    .buttonStyle(.plain)
                    .font(Typo.mono(12, weight: .semibold))
                    .foregroundStyle(isValid && !isSubmitting ? Theme.accent : Theme.fgMute)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke((isValid && !isSubmitting ? Theme.accent : Theme.border).opacity(0.5),
                                    lineWidth: 1)
                    )
                    .disabled(!isValid || isSubmitting)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
        .background(Theme.bg)
        .onAppear { passphraseFocused = true }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleText)
                .font(Typo.mono(14, weight: .semibold))
                .foregroundStyle(Theme.fg)
            Text(subtitleText)
                .font(Typo.mono(11))
                .foregroundStyle(Theme.fgMute)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleText: String {
        switch mode {
        case .createNew:     return "Set sync passphrase"
        case .enterExisting: return "Enter sync passphrase"
        case .rotate:        return "Change sync passphrase"
        }
    }

    private var subtitleText: String {
        switch mode {
        case .createNew:
            return """
            Used on each of your devices to unlock shared lists. \
            Choose something you'll remember — there's no recovery if \
            you forget it. Minimum \(Self.minimumLength) characters.
            """
        case .enterExisting:
            return """
            Enter the passphrase you set on your other device. The \
            same one unlocks shared lists everywhere.
            """
        case .rotate:
            return """
            Your other devices will need this new passphrase before \
            they can read shared lists again. There's still no recovery \
            if you forget it. Minimum \(Self.minimumLength) characters.
            """
        }
    }

    // MARK: - Passphrase field

    @ViewBuilder
    private var passphraseField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("passphrase")
                .font(Typo.mono(10))
                .foregroundStyle(Theme.fgMute)
            HStack(spacing: 8) {
                Group {
                    if showPassphrase {
                        TextField("12+ characters", text: $passphrase)
                    } else {
                        SecureField("12+ characters", text: $passphrase)
                    }
                }
                .textFieldStyle(.plain)
                .font(Typo.mono(13))
                .focused($passphraseFocused)
                .padding(8)
                .background(Theme.bgSoft)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

                Button(action: { showPassphrase.toggle() }) {
                    Image(systemName: showPassphrase ? "eye.slash" : "eye")
                        .foregroundStyle(Theme.fgDim)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showPassphrase ? "Hide passphrase" : "Show passphrase")
            }
            if needsConfirmField {
                Button("Generate strong passphrase") {
                    let generated = PassphraseGenerator.random()
                    passphrase = generated
                    confirm = generated
                    showPassphrase = true
                }
                .buttonStyle(.plain)
                .font(Typo.mono(11))
                .foregroundStyle(Theme.accent)
            }
            HStack(spacing: 8) {
                Text("\(passphrase.count) chars")
                    .font(Typo.mono(10))
                    .foregroundStyle(passphrase.count >= Self.minimumLength ? Theme.fgMute : Theme.danger)
                if passphrase.count > 0 && passphrase.count < Self.minimumLength {
                    Text("(\(Self.minimumLength - passphrase.count) to go)")
                        .font(Typo.mono(10))
                        .foregroundStyle(Theme.fgFaint)
                }
            }
        }
    }

    @ViewBuilder
    private var confirmField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("confirm")
                .font(Typo.mono(10))
                .foregroundStyle(Theme.fgMute)
            Group {
                if showPassphrase {
                    TextField("re-enter passphrase", text: $confirm)
                } else {
                    SecureField("re-enter passphrase", text: $confirm)
                }
            }
            .textFieldStyle(.plain)
            .font(Typo.mono(13))
            .padding(8)
            .background(Theme.bgSoft)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(confirmMismatch ? Theme.danger.opacity(0.6) : Theme.border, lineWidth: 1)
            )
            if confirmMismatch {
                Text("Passphrases don't match.")
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    private var confirmMismatch: Bool {
        needsConfirmField && !confirm.isEmpty && confirm != passphrase
    }

    private var isValid: Bool {
        guard passphrase.count >= Self.minimumLength else { return false }
        if needsConfirmField { return passphrase == confirm }
        return true
    }

    private var submitLabel: String {
        if isSubmitting { return "Working…" }
        switch mode {
        case .createNew:     return "Set passphrase"
        case .enterExisting: return "Unlock"
        case .rotate:        return "Change passphrase"
        }
    }

    // MARK: - Submit

    private func submit() {
        guard isValid, !isSubmitting else { return }
        errorText = nil
        isSubmitting = true
        Task {
            do {
                try await onSubmit(passphrase)
                // Caller dismisses; nothing left to do here. If the
                // sheet is still on screen for some reason, settle
                // back into editable state so the user can retry.
                isSubmitting = false
            } catch {
                errorText = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
