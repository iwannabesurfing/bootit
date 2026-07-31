import SwiftUI

/// A determinate progress ring.
///
/// Hand-drawn on purpose: SwiftUI's `.circular` ProgressView style renders an
/// indeterminate spinner on macOS, not a ring, so there is no stock control for
/// this. The linear bar is the more conventional macOS choice — this exists
/// because the progress screen is otherwise a single thin line in a large empty
/// window, and a focal element earns its place there.
struct ProgressRing: View {
    let value: Double            // 0…1
    var lineWidth: CGFloat = 12
    var diameter: CGFloat = 150

    private var clamped: Double { min(max(value, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)

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
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overall progress")
        .accessibilityValue("\(Int(clamped * 100)) percent")
    }
}

#if DEBUG
#Preview("Ring") {
    HStack(spacing: 20) {
        ProgressRing(value: 0.0)
        ProgressRing(value: 0.42)
        ProgressRing(value: 1.0)
    }
    .padding()
}
#endif
