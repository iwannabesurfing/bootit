import SwiftUI

/// Stage 5 — the write itself. A phase checklist carries the narrative; the
/// technical log is collapsed by default and opens on its own when it matters.
struct ProgressStepView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = model.runError {
                StatusBanner(.error, title: "The build stopped", message: error)
            } else {
                progressHeader
            }

            phaseChecklist

            logSection

            if model.runError != nil {
                HStack(spacing: 10) {
                    Button("Copy Diagnostics", action: copyDiagnostics)
                        .accessibilityIdentifier("copy-diagnostics-button")
                    Button("Start Over") { model.reset() }
                        .accessibilityIdentifier("start-over-button")
                }
            }
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: model.progress)
                .tint(Theme.accent)
                .accessibilityLabel("Overall progress")
                .accessibilityValue("\(Int(model.progress * 100)) percent")
            HStack {
                Text(model.statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(model.progress * 100))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var phaseChecklist: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(model.plannedPhases) { phase in
                let state = model.state(of: phase)
                HStack(spacing: 9) {
                    marker(state)
                    Text(model.title(for: phase))
                        .font(.callout.weight(state == .active ? .semibold : .regular))
                        .foregroundStyle(state == .pending ? Color.secondary : Color.primary)
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
