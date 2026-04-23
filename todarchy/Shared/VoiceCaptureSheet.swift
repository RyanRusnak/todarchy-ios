import SwiftUI

/// Modal that drives `VoiceCapture` — live transcript, equalizer bars,
/// cancel/commit. On commit the transcript is routed through
/// `QuickAddParser` so users can say "buy milk @errands !tomorrow" and
/// the chips still work.
struct VoiceCaptureSheet: View {
    @EnvironmentObject var store: TaskStore
    @StateObject private var voice = VoiceCapture()
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            header
            equalizer
            transcriptView
            Spacer(minLength: 4)
            actions
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 320)
        #endif
        .background(Theme.bgElev)
        .task {
            await voice.start()
        }
        .onDisappear { voice.stop() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("SPEAK YOUR TASK")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.fgMute)
            Spacer()
            statusPill
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch voice.state {
        case .idle:
            pill(text: "idle", color: Theme.fgMute)
        case .preparing:
            pill(text: "warming up…", color: Theme.fgMute)
        case .listening:
            pill(text: "listening", color: Theme.success)
        case .error:
            pill(text: "error", color: Theme.danger)
        }
    }

    private func pill(text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
    }

    private var equalizer: some View {
        EqualizerBars(level: voice.level)
            .frame(height: 90)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private var transcriptView: some View {
        if case .error(let message) = voice.state {
            Text(message)
                .font(Typo.mono(12))
                .foregroundStyle(Theme.danger)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
        } else if voice.partial.isEmpty {
            Text("say something like ")
                .font(Typo.mono(13))
                .foregroundStyle(Theme.fgMute)
            + Text("\"buy pasta @errands tomorrow\"")
                .font(Typo.mono(13, weight: .semibold))
                .foregroundStyle(Theme.fgDim)
        } else {
            Text(voice.partial)
                .font(Typo.mono(16, weight: .medium))
                .foregroundStyle(Theme.fg)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.bgSoft)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: cancel) {
                Text("cancel")
                    .font(Typo.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.fgDim)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(action: commit) {
                Text("add task →")
                    .font(Typo.mono(12, weight: .bold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [Theme.accent, Theme.accent2],
                                                 startPoint: .leading, endPoint: .trailing))
                    )
                    .opacity(commitDisabled ? 0.4 : 1.0)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(commitDisabled)
        }
    }

    private var commitDisabled: Bool {
        voice.partial.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    private func cancel() {
        voice.stop()
        onClose()
    }

    private func commit() {
        let raw = voice.finish()
        guard !raw.isEmpty else { return }
        // Voice transcripts are plain prose — "call mom phone today" —
        // while QuickAddParser expects "!today" / "@phone" tokens. Rewrite
        // bare due/context keywords into their tagged form so the same
        // chip semantics apply whether you speak or type.
        store.add(raw: Self.tokenizeVoiceTranscript(raw))
        onClose()
    }

    /// Rewrite trailing due-date and context words into QuickAddParser's
    /// tagged form. Only the END of the utterance is rewritten — which
    /// matches how people naturally speak GTD tasks ("call mom phone
    /// today") — and avoids false positives like "go to home depot"
    /// becoming "go to @home depot".
    ///
    /// Walks backward word-by-word: each recognized trailing word (or
    /// two-word phrase like "this week") becomes a tag, and we keep
    /// going until we hit a word that isn't a recognized keyword. So
    /// multiple keywords stack correctly without a runaway rewrite of
    /// the whole title.
    static func tokenizeVoiceTranscript(_ raw: String) -> String {
        let singleWordDue: [String: String] = [
            "today": "!today",
            "tonight": "!today",
            "tomorrow": "!tomorrow",
        ]
        let twoWordDue: [String: String] = [
            "this weekend": "!week",
            "this week": "!week",
            "next week": "!week",
        ]
        let ctxNames = Set(TaskContext.allCases.map { String($0.rawValue.dropFirst()) })

        // Strip trailing sentence punctuation, tokenize on whitespace.
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        var words = trimmed
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        var tags: [String] = []

        while !words.isEmpty {
            // Two-word phrases first so "this weekend" matches before
            // the single-word fallback has a chance to mis-classify.
            if words.count >= 2 {
                let phrase = "\(words[words.count - 2].lowercased()) \(words.last!.lowercased())"
                if let tag = twoWordDue[phrase] {
                    tags.insert(tag, at: 0)
                    words.removeLast(2)
                    continue
                }
            }
            let last = words.last!.lowercased()
            if let tag = singleWordDue[last] {
                tags.insert(tag, at: 0)
                words.removeLast()
                continue
            }
            if ctxNames.contains(last) {
                tags.insert("@\(last)", at: 0)
                words.removeLast()
                continue
            }
            break
        }

        if tags.isEmpty { return raw }
        return (words + tags).joined(separator: " ")
    }
}

// MARK: - Equalizer visualization

/// Eight bars whose heights lag and oscillate around the current mic
/// level. Creates a pleasant "it's listening" pulse that doesn't require
/// FFT — just a smoothed RMS plus per-bar phase offsets.
private struct EqualizerBars: View {
    let level: Float

    private static let barCount = 9
    // Per-bar phase offsets so bars don't pulse in lock-step.
    private static let phases: [Double] = (0..<barCount).map { Double($0) * 0.35 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<Self.barCount, id: \.self) { i in
                    bar(for: i, t: t)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func bar(for index: Int, t: TimeInterval) -> some View {
        // Base height from the smoothed level, boosted for center bars.
        let centerWeight = 1.0 - abs(Double(index) - Double(Self.barCount - 1) / 2.0) /
            (Double(Self.barCount - 1) / 2.0)
        let base = Double(level) * (0.5 + centerWeight * 0.5)
        // Add a little continuous motion even when silent, so the viz
        // doesn't look frozen while the user gathers thoughts.
        let osc = (sin(t * 3.6 + Self.phases[index]) * 0.5 + 0.5) * 0.06
        let h = max(0.06, min(1.0, base + osc))

        return RoundedRectangle(cornerRadius: 3)
            .fill(
                LinearGradient(
                    colors: [Theme.accent, Theme.accent2],
                    startPoint: .bottom, endPoint: .top
                )
            )
            .frame(width: 10, height: CGFloat(h) * 90)
            .animation(.easeOut(duration: 0.12), value: h)
    }
}
