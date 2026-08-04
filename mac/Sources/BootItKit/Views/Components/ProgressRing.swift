import SwiftUI

/// A progress ring that shows a percentage when there is one to show, and turns
/// into an activity indicator when there is not.
///
/// Hand-drawn on purpose: SwiftUI's `.circular` ProgressView style renders an
/// indeterminate spinner on macOS, not a ring, so there is no stock control for
/// this. The linear bar is the more conventional macOS choice — this exists
/// because the progress screen is otherwise a single thin line in a large empty
/// window, and a focal element earns its place there.
///
/// `value: nil` is the honest state during `createinstallmedia`'s silent
/// stretch: the payload lands on the drive over 30-odd minutes with no
/// trustworthy denominator to divide it by, and a number invented for that
/// stretch has now been wrong three separate times.
struct ProgressRing: View {
    /// 0…1, or nil when no defensible percentage exists.
    let value: Double?
    var lineWidth: CGFloat = 12
    var diameter: CGFloat = 150
    /// Stilled for previews and tests — an always-running animation makes a
    /// snapshot non-deterministic.
    var animates = true

    init(value: Double?, lineWidth: CGFloat = 12, diameter: CGFloat = 150, animates: Bool = true) {
        self.value = value
        self.lineWidth = lineWidth
        self.diameter = diameter
        self.animates = animates
    }

    @State private var spin = false

    private var clamped: Double? { value.map { min(max($0, 0), 1) } }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)

            if let clamped {
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(Theme.accent,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // Tracks real progress rather than easing decoratively; a build
                    // that has genuinely stalled should look stalled.
                    .animation(.linear(duration: 0.2), value: clamped)

                Text("\(Int(clamped * 100))%")
                    .font(.system(size: 30, weight: .semibold).monospacedDigit())
            } else {
                // A moving arc, not a frozen number. The whole complaint this
                // replaces was a bar that did not move for 33 minutes, and the
                // fix for "I can't tell if it's alive" is motion plus the
                // liveness figures beside it — not a different guess.
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(Theme.accent,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        guard animates else { return }
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                            spin = true
                        }
                    }

                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overall progress")
        .accessibilityValue(accessibilityValue)
    }

    /// VoiceOver gets the same claim the screen makes. Reading "0 percent"
    /// during an indeterminate phase would be a fabricated number in the one
    /// place a user cannot check it against a moving arc.
    private var accessibilityValue: String {
        guard let clamped else { return "In progress, no percentage available" }
        return "\(Int(clamped * 100)) percent"
    }
}

#if DEBUG
#Preview("Ring") {
    HStack(spacing: 20) {
        ProgressRing(value: 0.0)
        ProgressRing(value: 0.42)
        ProgressRing(value: 1.0)
        ProgressRing(value: nil)
    }
    .padding()
}
#endif
