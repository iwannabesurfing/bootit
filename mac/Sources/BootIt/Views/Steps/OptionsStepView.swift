import SwiftUI

/// Stage 3 — what to download. Only reached on the download route; a local
/// source has nothing to configure and goes straight to the drive.
struct OptionsStepView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.platform == .macos { macOptions } else { windowsOptions }

            if model.loadingCatalog {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Contacting servers…")
                }
                .foregroundStyle(.secondary)
            }
            if let error = model.catalogError {
                StatusBanner(.error, message: error)
            }
        }
        .onAppear(perform: loadIfNeeded)
    }

    /// Previews and tests must never reach the live catalogues, so the fetch is
    /// skipped when SwiftUI is rendering a preview.
    private func loadIfNeeded() {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        if model.platform == .macos {
            if model.macInstallers.isEmpty { model.loadMacCatalog() }
        } else if model.languages.isEmpty {
            model.loadWindowsCatalog()
        }
    }

    // MARK: Windows

    private var windowsOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Windows version") {
                Picker("Windows version", selection: $model.osChoice) {
                    ForEach(AppModel.OSChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
                .accessibilityIdentifier("os-choice-picker")
                .onChange(of: model.osChoice) { _ in model.loadWindowsCatalog() }
            }

            if !model.editions.isEmpty {
                LabeledContent("Edition") {
                    picker("Edition", selection: $model.editionIndex, items: model.editions.map(\.name))
                }
            }
            if !model.languages.isEmpty {
                LabeledContent("Language") {
                    picker("Language", selection: $model.languageIndex, items: model.languages.map(\.name))
                }
            }

            if !model.languages.isEmpty {
                StatusBanner(.information, message: "Downloaded directly from Microsoft.")
            }

            advancedOptions
        }
    }

    /// The Windows 11 bypass. It lives here on the download route, but the USB
    /// step carries it too — a local ISO never passes through this view, and the
    /// option has to stay reachable for people bringing their own image.
    private var advancedOptions: some View {
        DisclosureGroup(isExpanded: $model.showsAdvancedWindowsOptions) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Relax Windows 11 hardware and online-account requirements",
                       isOn: $model.bypassWin11)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("bypass-win11-toggle")
                Text("Adds setup configuration for unsupported hardware (TPM, Secure Boot, RAM) and "
                   + "offline setup. Writes an autounattend.xml to the USB — the Windows image itself "
                   + "is not modified.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Advanced Options").font(.headline)
        }
        .disclosureGroupStyle(.automatic)
    }

    private func picker(_ label: String, selection: Binding<Int>, items: [String]) -> some View {
        Picker(label, selection: selection) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, name in Text(name).tag(index) }
        }
        .labelsHidden().frame(maxWidth: 360)
        .accessibilityIdentifier("\(label.lowercased())-picker")
    }

    // MARK: macOS

    private var macOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.macInstallers.isEmpty {
                // A grid rather than a row: the list comes live from Apple, so the
                // number of majors grows on its own and a fixed HStack would squash.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 10)], spacing: 10) {
                    ForEach(model.macOSGroups) { group in groupTile(group) }
                }

                if let installer = model.selectedMacInstaller, let group = model.selectedMacGroup {
                    selectedBuildPanel(installer: installer, group: group)
                    Text("The installer (\(installer.sizeText)) downloads to your Applications folder "
                       + "first, then is written to the USB.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func selectedBuildPanel(installer: MacOSInstaller, group: MacOSGroup) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(installer.displayName).font(.callout.weight(.medium))
                    Text("\(installer.sizeText)  ·  build \(installer.build)  ·  \(installer.etaText)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if group.builds.count > 1 {
                    Button {
                        withAnimation(.easeInOut(duration: Theme.selectionDuration)) {
                            model.showOlderMacBuilds.toggle()
                        }
                    } label: {
                        Label("Older builds",
                              systemImage: model.showOlderMacBuilds ? "chevron.up" : "chevron.down")
                            .font(.footnote)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("older-builds-button")
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
        .background(RoundedRectangle(cornerRadius: Theme.smallRadius)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius)
            .strokeBorder(Color.secondary.opacity(0.15)))
    }

    private func groupTile(_ group: MacOSGroup) -> some View {
        let selected = model.selectedMacGroupTitle == group.id
        return Button {
            model.selectedMacGroupTitle = group.id
            model.selectedMacBuild = group.latest.build
            model.showOlderMacBuilds = false
        } label: {
            VStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Theme.macGradient(group.majorInt))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Image(systemName: "apple.logo")
                            .font(.system(size: 21))
                            .foregroundStyle(.white)
                    )
                VStack(spacing: 1) {
                    Text(group.majorLabel).font(.headline)
                    Text("macOS \(group.versionLabel)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 118)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.cardFill(selected: selected)))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.cardBorder(selected: selected),
                              lineWidth: selected ? Theme.selectedBorderWidth : Theme.borderWidth))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mac-group-\(group.majorLabel)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.title), macOS \(group.versionLabel)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func buildRow(_ build: MacOSInstaller, latest: MacOSInstaller) -> some View {
        let selected = model.selectedMacBuild == build.build
        return Button { model.selectedMacBuild = build.build } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.4))
                Text("\(build.version)  ·  \(build.sizeText)").font(.callout)
                Spacer()
                if build.build == latest.build {
                    Text("latest").font(.footnote.italic()).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 34).contentShape(Rectangle())
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}
