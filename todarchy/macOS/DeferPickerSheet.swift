#if os(macOS)
import SwiftUI
import AppKit

/// Identifiable wrapper so `.sheet(item:)` works with a task id.
struct DeferTarget: Identifiable, Equatable {
    let id: String
}

struct DeferPickerSheet: View {
    @EnvironmentObject var store: TaskStore
    let taskId: String
    let onClose: () -> Void

    @State private var freeform: String = ""
    @State private var parsed: Date?
    @State private var pickDate: Date = Date().addingTimeInterval(24 * 3600)
    @FocusState private var inputFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.border)

            Text("QUICK DEFER")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.fgMute)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 6)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(DeferPickerSheet.presets(now: Date()), id: \.label) { p in
                    preset(p.label, p.date)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)

            Divider().background(Theme.border)

            // Freeform parser input
            Text("TYPE A DURATION")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.fgMute)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 6)

            HStack(spacing: 8) {
                Text(">")
                    .font(Typo.mono(15, weight: .semibold))
                    .foregroundStyle(Theme.purple)
                TextField("tomorrow · +3d · fri · 2026-05-01", text: $freeform)
                    .textFieldStyle(.plain)
                    .font(Typo.mono(13))
                    .foregroundStyle(Theme.fg)
                    .focused($inputFocus)
                    .onChange(of: freeform) { _, v in
                        parsed = DeferParser.parse(v)
                    }
                    .onSubmit { commit(parsed) }
                if let parsed {
                    Text(parsed.formatted(date: .abbreviated, time: .shortened))
                        .font(Typo.mono(11))
                        .foregroundStyle(Theme.success)
                } else if !freeform.isEmpty {
                    Text("?")
                        .font(Typo.mono(11))
                        .foregroundStyle(Theme.danger)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)

            Divider().background(Theme.border).padding(.top, 8)

            // Manual date picker
            Text("OR PICK A DATE")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.fgMute)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 6)

            HStack {
                DatePicker("", selection: $pickDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Spacer()
                Button("set to this") { commit(pickDate) }
                    .buttonStyle(.plain)
                    .font(Typo.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.purple)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.purple.opacity(0.5), lineWidth: 1))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            Spacer(minLength: 0)

            Divider().background(Theme.border)

            // Footer
            HStack(spacing: 10) {
                Button("clear defer") {
                    store.clearDefer(taskId)
                    onClose()
                }
                .buttonStyle(.plain)
                .font(Typo.mono(12))
                .foregroundStyle(Theme.danger)
                .disabled(currentTask?.deferUntil == nil)
                .opacity(currentTask?.deferUntil == nil ? 0.4 : 1)

                Spacer()

                Button("cancel") { onClose() }
                    .buttonStyle(.plain)
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.fgMute)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgElev)
        .onAppear { inputFocus = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("DEFER")
                .font(Typo.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.purple)
            if let t = currentTask {
                Text(t.title)
                    .font(Typo.mono(13))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1)
                if let d = t.deferUntil, d > Date() {
                    Text("(currently \(d.formatted(date: .abbreviated, time: .shortened)))")
                        .font(Typo.mono(10))
                        .foregroundStyle(Theme.fgMute)
                }
            } else {
                Text("selected task").font(Typo.mono(13)).foregroundStyle(Theme.fgMute)
            }
            Spacer()
            Text("esc")
                .font(Typo.mono(10))
                .foregroundStyle(Theme.fgMute)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.borderHi, lineWidth: 1))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var currentTask: TaskItem? {
        store.tasks.first(where: { $0.id == taskId })
    }

    struct Preset {
        let label: String
        let date: Date
    }

    /// Duration-first preset ladder. All dates are computed relative to `now`.
    /// Exposed static for unit testing.
    static func presets(now: Date) -> [Preset] {
        let cal = Calendar.current
        func plus(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

        // Later today: jump to the next round hour at least 3h out, capped at 9pm.
        let laterToday: Date = {
            let threeFromNow = plus(3 * 3600)
            let hour = cal.component(.hour, from: threeFromNow)
            let minute = cal.component(.minute, from: threeFromNow)
            let rounded = minute == 0
                ? threeFromNow
                : cal.date(bySettingHour: hour + 1, minute: 0, second: 0, of: threeFromNow) ?? threeFromNow
            let nineToday = cal.date(bySettingHour: 21, minute: 0, second: 0, of: now) ?? now
            return min(rounded, nineToday)
        }()

        let tomorrow9 = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
            .flatMap { cal.date(bySettingHour: 9, minute: 0, second: 0, of: $0) } ?? plus(86400)

        let thisWeekend: Date = {
            var comps = DateComponents(); comps.weekday = 7; comps.hour = 9
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) ?? plus(86400 * 5)
        }()

        let nextWeek: Date = {
            var comps = DateComponents(); comps.weekday = 2; comps.hour = 9
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) ?? plus(86400 * 7)
        }()

        let twoWeeks = cal.date(byAdding: .day, value: 14, to: now) ?? plus(86400 * 14)
        let oneMonth = cal.date(byAdding: .month, value: 1, to: now) ?? plus(86400 * 30)

        return [
            Preset(label: "+15 min", date: plus(15 * 60)),
            Preset(label: "+1 hour", date: plus(3600)),
            Preset(label: "+3 hours", date: plus(3 * 3600)),
            Preset(label: "Later today", date: laterToday),
            Preset(label: "Tomorrow 9am", date: tomorrow9),
            Preset(label: "This weekend", date: thisWeekend),
            Preset(label: "Next week", date: nextWeek),
            Preset(label: "+2 weeks", date: twoWeeks),
            Preset(label: "+1 month", date: oneMonth),
        ]
    }

    private func preset(_ label: String, _ date: Date) -> some View {
        Button {
            commit(date)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(Typo.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(Typo.mono(10))
                    .foregroundStyle(Theme.fgMute)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.bgSoft)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func commit(_ date: Date?) {
        guard let date else { return }
        store.defer_(taskId, until: date)
        onClose()
    }
}
#endif
