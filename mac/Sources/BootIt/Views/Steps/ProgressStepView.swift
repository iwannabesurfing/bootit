import BootItShared
import SwiftUI

/// Stage 5 — the write itself. A phase checklist carries the narrative; the
/// technical log is collapsed by default and opens on its own when it matters.
struct ProgressStepView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let error = model.runError, model.wasCancelled {
                // Nothing failed, so nothing here should read like it did — no
                // red banner, no diagnostics to send, no "what to try" hint for
                // an outcome the user chose deliberately.
                StatusBanner(.information, title: "Build cancelled", message: error)
                phaseChecklist
                Button("Try Again") { model.start() }
                    .disabled(model.selectedDrive == nil)
                    .accessibilityIdentifier("try-again-button")
            } else if let error = model.runError {
                StatusBanner(.error, title: "The build stopped", message: error)
                if let hint = model.recoveryHint {
                    StatusBanner(.information, title: "What to try", message: hint)
                }
                phaseChecklist
                HStack(spacing: 10) {
                    Button("Copy Diagnostics", action: copyDiagnostics)
                        .accessibilityIdentifier("copy-diagnostics-button")
                    Button("Try Again") { model.start() }
                        .disabled(model.selectedDrive == nil)
                        .accessibilityIdentifier("try-again-button")
                }
            } else {
                runningHeader
            }

            logSection
        }
    }

    /// The ring and the checklist sit side by side: one answers "how far along",
    /// the other "doing what". A bar alone left the window mostly empty.
    private var runningHeader: some View {
        HStack(alignment: .center, spacing: 26) {
            ProgressRing(value: model.ringValue)
            VStack(alignment: .leading, spacing: 12) {
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                livenessLine
                phaseChecklist
            }
            Spacer(minLength: 0)
        }
    }

    /// What the drive is actually doing, in numbers.
    ///
    /// This is the part BootIt never had. Three attempts to fix "the bar doesn't
    /// move" all replaced one guessed percentage with another; none of them
    /// answered the question the user was really asking, which was whether
    /// anything was happening at all. Throughput and bytes answer it directly,
    /// and unlike a percentage they are measured rather than inferred.
    @ViewBuilder private var livenessLine: some View {
        if let copy = model.copyState {
            VStack(alignment: .leading, spacing: 3) {
                if let detail = copy.detail {
                    Label {
                        Text(detail).font(.callout.monospacedDigit())
                    } icon: {
                        Image(systemName: model.livenessSymbol)
                            .foregroundStyle(model.livenessIsWarning ? Color.orange : Theme.accent)
                    }
                    .foregroundStyle(model.livenessIsWarning ? Color.primary : Color.secondary)
                }
                Text("\(durationHuman(copy.elapsed)) elapsed — \(CopyProgressModel.durationRange)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var phaseChecklist: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(model.plannedPhases) { phase in
                let state = model.state(of: phase)
                HStack(spacing: 9) {
                    marker(state)
                    Text(model.title(for: phase))
                        .font(.callout.weight(state == .active || state == .failed ? .semibold : .regular))
                        .foregroundStyle(state == .pending || state == .skipped
                                         ? Color.secondary : Color.primary)
                    if state == .skipped {
                        Text("Skipped — already on this Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.title(for: phase))
                .accessibilityValue(accessibilityValue(for: state))
            }
        }
        .padding(.vertical, 2)
    }

    /// Shape as well as colour: a tick, a filled dot and an empty ring stay
    /// distinguishable without relying on green-versus-grey.
    @ViewBuilder private func marker(_ state: PhaseState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .active:
            Image(systemName: "circle.fill")
                .foregroundStyle(Theme.accent)
                .font(.system(size: 10))
                .frame(width: 16)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle")
                .foregroundStyle(Color.secondary)
                .font(.system(size: 12))
                .frame(width: 16)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(Color.secondary.opacity(0.7))
                .font(.system(size: 12))
                .frame(width: 16)
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(Color.secondary.opacity(0.4))
                .font(.system(size: 12))
                .frame(width: 16)
        }
    }

    private func accessibilityValue(for state: PhaseState) -> String {
        switch state {
        case .done:    return "Completed"
        case .active:  return "In progress"
        case .failed:  return "Failed"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped, the installer was already on this Mac"
        case .pending: return "Not started"
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: Theme.selectionDuration)) {
                    model.showsLogDetails.toggle()
                }
            } label: {
                Label(model.showsLogDetails ? "Hide Details" : "Show Details",
                      systemImage: model.showsLogDetails ? "chevron.down" : "chevron.right")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .keyboardShortcut("l", modifiers: .command)
            .accessibilityIdentifier("toggle-log-button")

            if model.showsLogDetails {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.logText)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(height: 190)
                    .background(RoundedRectangle(cornerRadius: Theme.smallRadius)
                        .fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius)
                        .strokeBorder(Color.secondary.opacity(0.2)))
                    .onChange(of: model.logText) { _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .accessibilityIdentifier("log-panel")
                }
            }
        }
    }

    private func copyDiagnostics() {
        let report = """
        BootIt diagnostics
        Platform: \(model.platform?.title ?? "unknown")
        Source: \(model.source == .download ? "download" : "local file")
        Phase: \(model.currentPhase.map { model.title(for: $0) } ?? "none")
        Error: \(model.runError ?? "none")

        \(model.logText)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}

#if DEBUG
#Preview("Starting") {
    ProgressStepView().environmentObject(PreviewModel.writing(progress: 0.02, phase: .downloading))
        .padding().frame(width: 560)
}

#Preview("Mid-write") {
    ProgressStepView().environmentObject(PreviewModel.writing(progress: 0.42, phase: .copying))
        .padding().frame(width: 560)
}

#Preview("Mid-write, log open") {
    ProgressStepView()
        .environmentObject(PreviewModel.writing(progress: 0.42, phase: .copying, showingLog: true))
        .padding().frame(width: 560)
}

#Preview("macOS copy — writing") {
    ProgressStepView()
        .environmentObject(PreviewModel.copying(.writing(bytesPerSecond: 8_900_000)))
        .padding().frame(width: 560)
}

#Preview("macOS copy — drive gone quiet") {
    ProgressStepView()
        .environmentObject(PreviewModel.copying(.idle(seconds: 190)))
        .padding().frame(width: 560)
}

#Preview("macOS copy — no measurable signal") {
    ProgressStepView()
        .environmentObject(PreviewModel.copying(.unmeasured(reason: .unavailable)))
        .padding().frame(width: 560)
}

#Preview("macOS copy — finishing") {
    ProgressStepView()
        .environmentObject(PreviewModel.copying(.finishing))
        .padding().frame(width: 560)
}

#Preview("Failure") {
    ProgressStepView().environmentObject(PreviewModel.failed()).padding().frame(width: 560)
}

#Preview("Failure — dark") {
    ProgressStepView().environmentObject(PreviewModel.failed())
        .padding().frame(width: 560).preferredColorScheme(.dark)
}
#endif
