import SwiftUI

/// The window shell: toolbar, step indicator, page heading, the current step's
/// content, and the action bar. Step views render only their own controls — the
/// title, subtitle and chrome live here so no page repeats them.
struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.showsSetupProgress {
                        StepIndicator(stages: model.setupStages, current: model.step)
                    }
                    heading
                    stepBody
                }
                .padding(.horizontal, Theme.pageHorizontalPadding)
                .padding(.vertical, Theme.pageVerticalPadding)
                .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            Divider()
            actionBar
        }
        .animation(.easeInOut(duration: Theme.transitionDuration), value: model.step)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("BootIt")
        .toolbar { toolbarContent }
        .confirmationDialog(eraseTitle,
                            isPresented: $model.isConfirmingErase,
                            titleVisibility: .visible) {
            Button("Erase and Create", role: .destructive) { model.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(eraseMessage)
        }
    }

    // MARK: Heading

    @ViewBuilder private var heading: some View {
        if model.step != .done {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.pageTitle).font(.title2.weight(.semibold))
                if let subtitle = model.pageSubtitle {
                    Text(subtitle).font(.body).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var stepBody: some View {
        switch model.step {
        case .platform: PlatformStepView()
        case .source:   SourceStepView()
        case .options:  OptionsStepView()
        case .usb:      USBStepView()
        case .progress: ProgressStepView()
        case .done:     CompletionStepView()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.step == .usb {
                Button {
                    model.refreshDisks()
                } label: {
                    Label("Refresh Drives", systemImage: "arrow.clockwise")
                }
                .disabled(model.refreshingDisks)
                .help("Rescan for external drives")
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityIdentifier("refresh-disks-button")
            }

            if model.step == .progress {
                Button {
                    model.showsLogDetails.toggle()
                } label: {
                    Label(model.showsLogDetails ? "Hide Details" : "Show Details",
                          systemImage: "text.alignleft")
                }
                .help("Show the technical log")
                .keyboardShortcut("l", modifiers: .command)
            }

            if model.showsSetupProgress && model.step != .platform {
                Button("Start Over") { model.reset() }
                    .help("Discard these choices and begin again")
                    .accessibilityIdentifier("start-over-toolbar-button")
            }
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            if model.step == .done {
                Button("Create Another") { model.reset() }
                    .accessibilityIdentifier("make-another-button")
            } else if model.showsBack {
                Button { model.goBack() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .accessibilityIdentifier("back-button")
            }
            Spacer()
            primaryButton
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// One button per step. It stays visible when disabled so the next action is
    /// always discoverable — it used to vanish until it became valid.
    @ViewBuilder private var primaryButton: some View {
        switch model.step {
        case .progress:
            Button(model.primaryActionTitle, role: .cancel) { model.primaryAction() }
                .disabled(!model.isPrimaryActionEnabled)
                .accessibilityIdentifier("cancel-button")
        case .done:
            Button(model.primaryActionTitle) { NSApp.terminate(nil) }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("quit-button")
        default:
            Button { model.primaryAction() } label: {
                if model.step == .options, model.loadingCatalog {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading…") }
                } else {
                    Text(model.primaryActionTitle)
                }
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.isPrimaryActionEnabled)
            .accessibilityIdentifier(model.step == .usb ? "create-button" : "continue-button")
        }
    }

    // MARK: Destructive confirmation

    private var eraseTitle: String {
        guard let drive = model.selectedDrive else { return "Erase this drive?" }
        return "Erase “\(drive.name)”?"
    }

    private var eraseMessage: String {
        guard let drive = model.selectedDrive else { return "This cannot be undone." }
        let target = model.platform == .macos ? "macOS" : "Windows"
        return "This permanently removes everything on \(drive.deviceID) (\(drive.sizeText)) "
            + "and creates a bootable \(target) installer. This action cannot be undone."
    }
}

#if DEBUG
#Preview("Platform step") {
    RootView().environmentObject(PreviewModel.platform(nil)).frame(width: 760, height: 600)
}

#Preview("Drive step") {
    RootView().environmentObject(PreviewModel.drives(selected: 0, acknowledged: true))
        .frame(width: 760, height: 600)
}

#Preview("Drive step — dark") {
    RootView().environmentObject(PreviewModel.drives(selected: 0, acknowledged: true))
        .frame(width: 760, height: 600).preferredColorScheme(.dark)
}

#Preview("Writing") {
    RootView().environmentObject(PreviewModel.writing(progress: 0.42, phase: .copying))
        .frame(width: 760, height: 600)
}

#Preview("Complete") {
    RootView().environmentObject(PreviewModel.completed()).frame(width: 760, height: 600)
}
#endif
