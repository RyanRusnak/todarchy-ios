import SwiftUI

struct CtxChip: View {
    let ctx: TaskContext
    var highlighted: Bool = false

    var body: some View {
        let color = ctx.color
        Text(ctx.rawValue)
            .font(Typo.mono(11.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, highlighted ? 5 : 2)
            .padding(.vertical, highlighted ? 1 : 0)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(highlighted ? color.opacity(0.18) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(highlighted ? color.opacity(0.55) : .clear, lineWidth: 1)
            )
    }
}

struct DueChip: View {
    let due: DueBucket

    var body: some View {
        let color = due.color
        Text("!\(due.label)")
            .font(Typo.mono(10.5, weight: .semibold))
            .tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color.opacity(0.35), lineWidth: 1)
            )
    }
}

struct DeferChip: View {
    let date: Date
    var body: some View {
        HStack(spacing: 4) {
            Text("◐").font(Typo.mono(11))
            Text(TimeAgo.deferUntil(date))
                .font(Typo.mono(11))
        }
        .foregroundStyle(Theme.purple)
    }
}

struct ListDot: View {
    let color: Color
    var glow: Bool = false
    var size: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glow ? color.opacity(0.8) : .clear, radius: glow ? 5 : 0)
    }
}

struct Checkbox: View {
    let done: Bool
    var size: CGFloat = 22
    var deferred: Bool = false

    var body: some View {
        // Build the shape from properties that all animate continuously
        // (fill colour, stroke, checkmark scale) so the done <-> not-done
        // transition gets a smooth spring rather than a crossfade between
        // two different view identities.
        ZStack {
            RoundedRectangle(cornerRadius: size / 2)
                .fill(done ? Theme.success
                      : (deferred ? Theme.purple.opacity(0.08) : Color.clear))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: size / 2)
                        .stroke(done ? Color.clear : Theme.borderHi, lineWidth: 1.5)
                )

            Image(systemName: "checkmark")
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(Theme.bg)
                .scaleEffect(done ? 1.0 : 0.0)
                .opacity(done ? 1.0 : 0.0)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: done)
    }
}

/// A small keyboard-hint "pill" rendered like a kbd element.
struct KBD: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Typo.mono(11))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.bgSoft)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.borderHi, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.borderHi, lineWidth: 2)
                    .padding(.top, 14)
                    .mask(Rectangle().padding(.top, 13))
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
