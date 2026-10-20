import SwiftUI

/// What the footer is showing, and whose it is.
///
/// The bars follow the tab you are looking at, not the account new sessions
/// would start on. Those are different things the moment you switch account
/// with work still running, and showing the wrong one is how a session that
/// has hit its limit sits under a bar reading 1%.
struct UsageReadout: Equatable {
    var session: UsageWindow?
    var week: UsageWindow?
    /// The account these numbers belong to, spelled out for the footer.
    var account: String
    var problem: String?
    var isBusy: Bool
    /// When these numbers were read. A window that stays open for days can be
    /// looking at an hour-old figure, and there is no way to tell from a bar.
    var updated: Date?
}

/// The 5-hour and weekly limits, always on screen in the sidebar footer —
/// and, in the same shape, the Cursor plan's two pools above them.
struct UsageBars: View {
    let readout: UsageReadout
    /// False when the footer's account chip already names this account.
    var showsAccount = true
    /// Which plan these are, once the footer holds more than one.
    var title: String? = nil
    var labels = (first: "5h", second: "Week")
    /// What the bars measure, for the tooltip, where the Claude wording about
    /// accounts and tabs would not be true.
    var about: String? = nil
    let refresh: () -> Void

    private static let barWidth: CGFloat = 90

    var body: some View {
        HStack(spacing: 6) {
            // Both windows count down; the raw text is only a fallback for a
            // reset the panel phrased in some way we could not turn into a date.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 5) {
                    if let title {
                        Text(title.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    row(labels.first, readout.session, at: context.date)
                    row(labels.second, readout.week, at: context.date)
                    // Named when these are NOT the account chip's numbers (a tab
                    // running as someone else), or when the reading is old
                    // enough that its age matters. Same account twice in one
                    // footer said nothing.
                    let staleText = isStale
                        ? age.lowercased()
                            .replacingOccurrences(of: "read ", with: "")
                            .replacingOccurrences(of: ".", with: "")
                        : nil
                    let parts = [showsAccount ? readout.account : nil, staleText].compactMap { $0 }
                    if !parts.isEmpty {
                        Text(parts.joined(separator: " · "))
                            .font(.system(size: 9))
                            .foregroundStyle(isStale ? Color.pending.opacity(0.85) : Color.secondary.opacity(0.7))
                            .lineLimit(1)
                            .padding(.leading, 39)
                    }
                }
            }
            Button {
                refresh()
            } label: {
                // A failed read is worth an icon of its own: silently showing
                // "—" forever is how a broken account looks like a quiet one.
                //
                // The two symbols are deliberately separate views. Swapping the
                // name on one shared Image keeps the view — and its in-flight
                // spin — alive across the swap, so the triangle inherits the
                // turn and ends up sitting there tilted.
                Group {
                    if showsProblem {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                    } else {
                        SpinningRefreshIcon(isSpinning: readout.isBusy)
                    }
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .clickable()
            .disabled(readout.isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .help(helpText)
    }

    /// An account with nothing to report is not a fault, so it does not get a
    /// warning triangle — only something that actually went wrong does.
    /// Ten minutes is longer than any of the readers wait, so past that
    /// something has stopped and the number on screen is history.
    private var isStale: Bool {
        guard let updated = readout.updated else { return false }
        return Date().timeIntervalSince(updated) > 600
    }

    private var showsProblem: Bool {
        readout.problem != nil && !readout.isBusy
    }

    private var helpText: String {
        if let problem = readout.problem { return "\(problem)\n\nClick to try again." }
        if let about { return "\(about)\n\(age)  Click ↻ to read them now." }
        return """
            The limits of \(readout.account) — the account this tab is running as, \
            which is not always the account new sessions start on.
            \(age)  Click ↻ to read them now.
            """
    }

    private var age: String {
        guard let updated = readout.updated else { return "Not read yet." }
        let seconds = Int(Date().timeIntervalSince(updated))
        if seconds < 90 { return "Read just now." }
        if seconds < 3_600 { return "Read \(seconds / 60) min ago." }
        return "Read \(seconds / 3_600) hr ago."
    }

    @ViewBuilder
    private func row(_ label: String, _ window: UsageWindow?, at now: Date) -> some View {
        // A blank row reads as "nothing to report"; the truth is "we could not
        // find out", and the two deserve different words.
        let trailing = window?.countdown(from: now)
            ?? window?.resets
            ?? (showsProblem ? "unavailable" : nil)
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)

            // Fixed width on purpose: a GeometryReader here reads the size of
            // the very inset it sits in, which makes the sidebar re-layout
            // while it is already laying out.
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: Self.barWidth)
                if let window {
                    Capsule()
                        .fill(Self.color(for: window.level))
                        .frame(width: Self.barWidth * CGFloat(window.percent) / 100)
                }
            }
            .frame(width: Self.barWidth, height: 7)

            if let window {
                Text("\(window.percent)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Self.color(for: window.level))
                    .frame(width: 36, alignment: .trailing)
            } else if readout.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 36, alignment: .trailing)
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
            }

            Text(trailing ?? "")
                .font(.system(size: 11))
                .foregroundStyle(window == nil && showsProblem ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private static func color(for level: Int) -> Color {
        switch level {
        case 2: return .red
        case 1: return .orange
        default: return .green
        }
    }
}

/// The refresh glyph, turned by the clock rather than by an implicit animation.
///
/// The obvious `.rotationEffect(isProbing ? 360 : 0)` plus `repeatForever` gets
/// two things wrong, and both are visible on an 11pt icon:
///
/// - The store publishes while it is reading, so the body is rebuilt mid-turn
///   and the repeating animation is re-seeded from wherever the icon happens to
///   be. The turn stutters and looks like it keeps changing speed.
/// - `arrow.clockwise` does not turn around the middle of its layout box. Its
///   arc is centred at y ≈ 0.559 of that box — measured off the rendered glyph
///   at four point sizes, stable to ±0.003 — so spinning around `.center` walks
///   the icon around a small circle instead of turning it on the spot.
///
/// Driving the angle off the wall clock fixes the first: there is no animation
/// state to restart, so a rebuild lands on exactly the angle the time says it
/// should. The measured anchor fixes the second.
private struct SpinningRefreshIcon: View {
    var isSpinning: Bool

    /// One turn. A second reads as a flicker at this size; this reads as a turn.
    private static let period: Double = 1.3
    /// Where the arc's circle actually sits inside the glyph's layout box.
    private static let axis = UnitPoint(x: 0.5, y: 0.559)

    /// Where the icon rests once it has stopped, and how it gets there.
    @State private var restAngle: Double = 0

    var body: some View {
        Group {
            if isSpinning {
                TimelineView(.animation) { context in
                    icon(angle: Self.angle(at: context.date))
                }
            } else {
                icon(angle: restAngle)
            }
        }
        .onChange(of: isSpinning) { _, spinning in
            guard !spinning else { return }
            // Coast to upright from wherever the turn was, rather than snapping
            // there: a read that finishes fast is otherwise a visible jolt.
            restAngle = Self.angle(at: .now)
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.3)) { restAngle = 360 }
            }
        }
    }

    private func icon(angle: Double) -> some View {
        Image(systemName: "arrow.clockwise")
            .foregroundStyle(Color.secondary)
            .rotationEffect(.degrees(angle), anchor: Self.axis)
    }

    /// The angle straight from the clock: nothing to fall out of step with, and
    /// nothing to restart when the view is rebuilt.
    private static func angle(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        return phase * 360
    }
}
