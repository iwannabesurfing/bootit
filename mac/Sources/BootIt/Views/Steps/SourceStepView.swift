import SwiftUI
import UniformTypeIdentifiers

/// Stage 2 — download from the vendor, or use an installer already on this Mac.
struct SourceStepView: View {
    @EnvironmentObject var model: AppModel
    private var isMac: Bool { model.platform == .macos }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChoiceCard(selected: model.source == .download, symbol: "icloud.and.arrow.down") {
                model.source = .download
            } content: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(isMac ? "Download from Apple" : "Download from Microsoft").font(.headline)
                        Text("Recommended")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.15)))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(isMac
                         ? "Straight from Apple's servers — a large download, roughly 12–18 GB."
                         : "Straight from Microsoft's servers, around 6 GB. You'll choose edition and language next.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("source-download")

            ChoiceCard(selected: model.source == .local, symbol: "folder") {
                model.source = .local
            } content: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isMac ? "Use an installed macOS installer" : "Use an existing ISO file").font(.headline)
                    Text(isMac
                         ? "An “Install macOS …” app already on this Mac. Goes straight to the drive."
                         : "A Windows .iso you've already downloaded. Goes straight to the drive.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("source-local")

            if model.source == .local { localPicker }

            if model.source == .download {
                // Deliberately precise: the download is untouched, but BootIt does
                // change what lands on the USB (it splits install.wim, and can add
                // an autounattend.xml). Claiming "never alters installer files"
                // would be a nicer sentence and a false one.
                StatusBanner(.information,
                             message: isMac
                             ? "Downloaded directly from Apple, not repackaged."
                             : "Downloaded directly from Microsoft, not repackaged.")
            }

            if let error = model.catalog.error {
                StatusBanner(.error, message: error)
            }
        }
    }

    @ViewBuilder private var localPicker: some View {
        if isMac {
            macInstallerPicker
        } else {
            HStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.system(size: 20)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.localISOPath.isEmpty
                         ? "No file chosen"
                         : (model.localISOPath as NSString).lastPathComponent)
                        .font(.callout.weight(.medium))
                    if !model.localISOPath.isEmpty {
                        Text(model.localISOPath)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 8)
                Button(model.localISOPath.isEmpty ? "Choose…" : "Replace…", action: browseISO)
                    .accessibilityIdentifier("browse-button")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.smallRadius)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .accessibilityIdentifier("iso-file-row")
        }
    }

    @ViewBuilder private var macInstallerPicker: some View {
        if model.catalog.macInstalledApps.isEmpty {
            StatusBanner(.warning,
                         message: "No “Install macOS …” app found in /Applications. "
                                + "Download one above, get it from the App Store, or browse to it.")
            HStack { Spacer(); Button("Browse…", action: browseMacApp).accessibilityIdentifier("browse-button") }
        } else {
            VStack(spacing: 8) {
                ForEach(model.catalog.macInstalledApps, id: \.path) { url in
                    let name = url.deletingPathExtension().lastPathComponent
                    ChoiceCard(selected: model.catalog.macAppPath == url.path, symbol: "app.badge") {
                        model.catalog.macAppPath = url.path
                    } content: {
                        Text(name).font(.callout.weight(.medium))
                    }
                    .accessibilityIdentifier("installer-\(name)")
                }
            }
            .accessibilityIdentifier("installer-list")
            HStack { Spacer(); Button("Browse…", action: browseMacApp).accessibilityIdentifier("browse-button") }
        }
    }

    private func browseISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
        panel.allowsOtherFileTypes = true
        panel.directoryURL = downloads
        if panel.runModal() == .OK, let url = panel.url {
            model.localISOPath = url.path; model.catalog.error = nil
        }
    }

    private func browseMacApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.catalog.macAppPath = url.path; model.catalog.error = nil
        }
    }

    private var downloads: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
}
