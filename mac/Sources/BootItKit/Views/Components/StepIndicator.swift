import SwiftUI

/// The `Platform › Source › Options › USB Drive` strip above the step content.
///
/// Stages are supplied by the model rather than hard-coded, because the route
/// itself varies: bringing your own installer skips the options step, and
/// showing a stage the user will never reach is worse than showing none.
struct StepIndicator: View {
    let stages: [AppModel.Step]
    let current: AppModel.Step

    private var currentIndex: Int {
        stages.firstIndex(of: current) ?? 0
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
                stageLabel(stage, index: index)
                if index < stages.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 1)
                        .frame(maxWidth: 28)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(currentIndex + 1) of \(stages.count): \(current.stageTitle)")
    }

    @ViewBuilder
    private func stageLabel(_ stage: AppModel.Step, index: Int) -> some View {
        let state = state(for: index)
        HStack(spacing: 6) {
            marker(state, number: index + 1)
            Text(stage.stageTitle)
                .font(.callout.weight(state == .current ? .semibold : .regular))
                .foregroundStyle(state == .upcoming ? Color.secondary : Color.primary)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func marker(_ state: StageState, number: Int) -> some View {
        switch state {
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
        case .current:
            ZStack {
                Circle().fill(Theme.accent).frame(width: 17, height: 17)
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .upcoming:
            ZStack {
                Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1).frame(width: 17, height: 17)
                Text("\(number)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private enum StageState { case complete, current, upcoming }

    private func state(for index: Int) -> StageState {
        if index < currentIndex { return .complete }
        return index == currentIndex ? .current : .upcoming
    }
}

#if DEBUG
#Preview("Download route — on Options") {
    StepIndicator(stages: [.platform, .source, .options, .usb], current: .options)
        .padding()
        .frame(width: 520)
}

#Preview("Local route — three stages") {
    StepIndicator(stages: [.platform, .source, .usb], current: .source)
        .padding()
        .frame(width: 520)
}
#endif
