import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                stepBody
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .animation(.easeInOut(duration: 0.18), value: model.step)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(eraseTitle,
                            isPresented: $model.isConfirmingErase,
                            titleVisibility: .visible) {
            Button("Erase and Create", role: .destructive) { model.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(eraseMessage)
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

    @ViewBuilder private var stepBody: some View {
        switch model.step {
        case .platform: PlatformStep()
        case .source:   SourceStep()
        case .options:  OptionsStep()
        case .usb:      USBStep()
        case .progress: ProgressStep()
        case .done:     DoneStep()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if model.step == .done {
                Button("Make Another") { model.reset() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("make-another-button")
            } else if model.showsBack {
                Button { model.goBack() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityIdentifier("back-button")
            }
            Spacer()
            primaryButton
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    /// One button for every step. It stays visible when disabled so the next
    /// action is always discoverable — previously it vanished until valid.
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
}

// MARK: - Platform choice

private struct PlatformStep: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 16)
            Text("What are you creating?").font(.title2.bold())
            HStack(spacing: 16) {
                card(.windows)
                card(.macos)
            }
            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity)
    }

    private func card(_ p: AppModel.Platform) -> some View {
        let selected = model.platform == p
        return Button { model.platform = p } label: {
            VStack(spacing: 10) {
                Image(systemName: p.symbol)
                    .font(.system(size: 40))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                Text(p.title).font(.title3.bold())
                Text(p.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(selected ? Theme.accent.opacity(0.07) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Theme.accent : Color.secondary.opacity(0.2),
                              lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("platform-card-\(p.rawValue)")
    }
}

// MARK: - Source

private struct SourceStep: View {
    @EnvironmentObject var model: AppModel
    private var isMac: Bool { model.platform == .macos }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose your source").font(.title2.bold())

            SelectableCard(selected: model.source == .download) { model.source = .download } content: {
                VStack(alignment: .leading, spacing: 3) {
                    Label(isMac ? "Download from Apple" : "Download from Microsoft",
                          systemImage: "icloud.and.arrow.down").font(.headline)
                    Text(isMac
                         ? "Fetches a macOS installer straight from Apple (a large ~12–18 GB download)."
                         : "Fetches the latest Windows 10 or 11 ISO from Microsoft. Choose edition and language next (~6 GB).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("source-download")

            SelectableCard(selected: model.source == .local) { model.source = .local } content: {
                VStack(alignment: .leading, spacing: 3) {
                    Label(isMac ? "Use an installed macOS installer" : "Use an existing ISO file",
                          systemImage: "folder").font(.headline)
                    Text(isMac
                         ? "Use an “Install macOS …” app already on this Mac. Goes straight to writing the USB."
                         : "Use a Windows .iso you've already downloaded. Goes straight to writing the USB.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("source-local")

            if model.source == .local { localPicker }

            if let err = model.catalogError {
                NoteBox(systemImage: "xmark.octagon.fill", text: err, tint: .red)
            }
        }
    }

    @ViewBuilder private var localPicker: some View {
        if isMac {
            if model.macInstalledApps.isEmpty {
                NoteBox(systemImage: "questionmark.folder",
                        text: "No “Install macOS …” app found in /Applications. "
                            + "Download one above, get it from the App Store, or browse to it.",
                        tint: .secondary)
                HStack { Spacer(); Button("Browse…", action: browseMacApp).accessibilityIdentifier("browse-button") }
            } else {
                Picker("Installer", selection: Binding(
                    get: { model.macAppPath },
                    set: { model.macAppPath = $0 }
                )) {
                    ForEach(model.macInstalledApps, id: \.path) { url in
                        Text(url.deletingPathExtension().lastPathComponent).tag(url.path)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("installer-picker")
                HStack { Spacer(); Button("Browse…", action: browseMacApp).accessibilityIdentifier("browse-button") }
            }
        } else {
            HStack {
                TextField("Path to .iso", text: $model.localISOPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("iso-path-field")
                Button("Browse…", action: browseISO).accessibilityIdentifier("browse-button")
            }
        }
    }

    private func browseISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
        panel.allowsOtherFileTypes = true
        panel.directoryURL = downloads
        if panel.runModal() == .OK, let url = panel.url {
            model.localISOPath = url.path; model.catalogError = nil
        }
    }

    private func browseMacApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.macAppPath = url.path; model.catalogError = nil
        }
    }

    private var downloads: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
}

// MARK: - Options (download details)

private struct OptionsStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.platform == .macos { macOptions } else { windowsOptions }

            if model.loadingCatalog {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Contacting servers…") }
                    .foregroundStyle(.secondary)
            }
            if let err = model.catalogError {
                NoteBox(systemImage: "xmark.octagon.fill", text: err, tint: .red)
            }
        }
        .onAppear {
            if model.platform == .macos {
                if model.macInstallers.isEmpty { model.loadMacCatalog() }
            } else if model.languages.isEmpty {
                model.loadWindowsCatalog()
            }
        }
    }

    private var windowsOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Windows version & language").font(.title2.bold())

            Picker("Operating system", selection: $model.osChoice) {
                ForEach(AppModel.OSChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            .accessibilityIdentifier("os-choice-picker")
            .onChange(of: model.osChoice) { _ in model.loadWindowsCatalog() }

            if !model.editions.isEmpty {
                labeledPicker("Edition", selection: $model.editionIndex, items: model.editions.map(\.name))
            }
            if !model.languages.isEmpty {
                labeledPicker("Language", selection: $model.languageIndex, items: model.languages.map(\.name))
            }
        }
    }

    private var macOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a macOS version").font(.title2.bold())

            if !model.macInstallers.isEmpty {
                // Major-version tiles (derived live — new releases appear here automatically).
                HStack(spacing: 8) {
                    ForEach(model.macOSGroups) { group in groupTile(group) }
                }

                if let inst = model.selectedMacInstaller, let group = model.selectedMacGroup {
                    VStack(spacing: 0) {
                        HStack {
                            Text("\(inst.displayName)  ·  \(inst.sizeText)  ·  \(inst.etaText)")
                                .font(.callout)
                            Spacer()
                            if group.builds.count > 1 {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) { model.showOlderMacBuilds.toggle() }
                                } label: {
                                    Label("Older builds",
                                          systemImage: model.showOlderMacBuilds ? "chevron.up" : "chevron.down")
                                        .font(.footnote)
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)

                        if model.showOlderMacBuilds {
                            Divider()
                            VStack(spacing: 0) {
                                ForEach(group.builds) { build in buildRow(build, latest: group.latest) }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.15)))

                    Text("The installer (\(inst.sizeText)) downloads to your Applications folder first, then is written to the USB.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func groupTile(_ group: MacOSGroup) -> some View {
        let selected = model.selectedMacGroupTitle == group.id
        return Button {
            model.selectedMacGroupTitle = group.id
            model.selectedMacBuild = group.latest.build
            model.showOlderMacBuilds = false
        } label: {
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Theme.macGradient(group.majorInt))
                    .frame(width: 54, height: 54)
                    .overlay(
                        Image(systemName: "apple.logo")
                            .font(.system(size: 23))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                VStack(spacing: 1) {
                    Text(group.majorLabel).font(.headline)
                        .foregroundStyle(selected ? Theme.accent : Color.primary)
                    Text("macOS \(group.versionLabel)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 122)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(selected ? Theme.accent.opacity(0.07) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Theme.accent : Color.secondary.opacity(0.18),
                              lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mac-group-\(group.majorLabel)")
    }

    private func buildRow(_ build: MacOSInstaller, latest: MacOSInstaller) -> some View {
        let selected = model.selectedMacBuild == build.build
        return Button { model.selectedMacBuild = build.build } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.5))
                Text("\(build.version)  ·  \(build.sizeText)").font(.callout)
                Spacer()
                if build.build == latest.build {
                    Text("latest").font(.footnote.italic()).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 36).contentShape(Rectangle())
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
    }

    private func labeledPicker(_ label: String, selection: Binding<Int>, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.headline)
            Picker(label, selection: selection) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
            }
            .labelsHidden().frame(maxWidth: 420)
            .accessibilityIdentifier("\(label.lowercased())-picker")
        }
    }
}

// MARK: - USB select

private struct USBStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Select a USB drive").font(.title2.bold())
                Spacer()
                Button { model.refreshDisks() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.refreshingDisks)
                    .accessibilityIdentifier("refresh-disks-button")
            }

            if model.disks.isEmpty {
                NoteBox(systemImage: "externaldrive.badge.questionmark",
                        text: "No external drives found. Insert a USB drive (8 GB+ for Windows, 16 GB+ for macOS) and click Refresh.",
                        tint: .secondary)
            } else {
                Text("Available drives").font(.headline)
                VStack(spacing: 8) {
                    ForEach(Array(model.disks.enumerated()), id: \.element.id) { index, disk in
                        DriveCard(disk: disk, selected: model.diskIndex == index) {
                            model.diskIndex = index
                            model.hasAcknowledgedErase = false
                        }
                    }
                }
                .accessibilityIdentifier("drive-list")

                if let drive = model.selectedDrive {
                    EraseWarning(drive: drive, acknowledged: $model.hasAcknowledgedErase)
                }

                if model.platform == .macos {
                    NoteBox(systemImage: "lock.fill",
                            text: "Creating a macOS installer needs administrator access — "
                                + "you'll be asked for your password after you click Create.",
                            tint: .secondary)
                }
            }

            if model.platform == .windows {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Bypass Windows 11 checks (TPM, Secure Boot, RAM)", isOn: $model.bypassWin11)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("bypass-win11-toggle")
                    Text("Also shows the “I don’t have internet” option during setup, so you can finish "
                        + "without a Microsoft account. Adds an autounattend.xml — leaves the rest of Setup interactive.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
                .padding(.top, 2)
            }

            Text("Only external drives are listed — your internal drive is never shown.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Names the drive rather than asking for a generic acknowledgement — the
/// question that matters is "is this the right one?", not "do you know what
/// erase means?". The warning icon is paired with text, never colour alone.
private struct EraseWarning: View {
    let drive: USBDisk
    @Binding var acknowledged: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(drive.name) will be permanently erased.").font(.headline)
                    Text("All files and partitions on this \(drive.sizeText) drive (\(drive.deviceID)) will be removed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Toggle("I have checked that this is the correct drive.", isOn: $acknowledged)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("confirm-erase-toggle")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Warning: \(drive.name), \(drive.sizeText), \(drive.deviceID) will be permanently erased")
    }
}

// MARK: - Progress

private struct ProgressStep: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.runError == nil ? "Writing bootable drive…" : "Something went wrong")
                .font(.title2.bold())
                .foregroundStyle(model.runError == nil ? Color.primary : Color.red)

            ProgressView(value: model.progress).tint(Theme.accent)
            Text(model.statusText).font(.callout).foregroundStyle(.secondary)

            if let err = model.runError {
                NoteBox(systemImage: "xmark.octagon.fill", text: err, tint: .red)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.logText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(minHeight: 200)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
                .onChange(of: model.logText) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            if model.runError != nil {
                Button("Back to start") { model.reset() }
            }
        }
    }
}

// MARK: - Done

private struct DoneStep: View {
    @EnvironmentObject var model: AppModel
    private var isMac: Bool { model.platform == .macos }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52)).foregroundStyle(.green)
            Text("Your bootable \(isMac ? "macOS" : "Windows") USB is ready")
                .font(.title2.bold()).multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                if isMac {
                    Bullet("Plug the USB into the target Mac")
                    Bullet("Hold the power button (Apple silicon) or ⌥ Option (Intel) at startup")
                    Bullet("Choose the installer volume and follow macOS Setup")
                } else {
                    Bullet("Insert the USB into the target PC")
                    Bullet("Press F12, F2, DEL or ESC at startup to open the boot menu")
                    Bullet("Select the USB drive and follow Windows Setup")
                }
            }
            .frame(maxWidth: 420, alignment: .leading)

            Text("You can safely eject the USB drive from this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
    }
}
