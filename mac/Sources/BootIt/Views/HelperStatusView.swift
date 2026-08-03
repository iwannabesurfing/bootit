import ServiceManagement
import SwiftUI

/// A plain window describing the state of the privileged helper, with the two
/// actions a user could reasonably want: install it, or get rid of it.
///
/// A background daemon running as root should never be something the user can
/// only discover in System Settings. It is also the only way to trigger the
/// approval prompt *before* committing to erasing a drive — the write path
/// checks the helper first and fails safe, but finding out here is kinder.
struct HelperStatusView: View {

    @State private var statusText  = "Checking…"
    @State private var detail      = ""
    @State private var isHealthy   = false
    @State private var busy        = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Privileged Helper")
                .font(.title2).bold()

            Text("Apple's createinstallmedia has to run with system privileges. "
               + "BootIt installs a small background helper to do that, and nothing else.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: isHealthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isHealthy ? Color.green : Color.orange)
                Text(statusText).bold()
            }

            if !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            // Approval alone is not enough: the helper also needs Full Disk
            // Access to write to a USB drive, and unlike the approval prompt
            // macOS never asks for it — a daemon has no session to ask in.
            Button("Open Full Disk Access Settings…") {
                if let url = HelperError.fullDiskAccessSettingsURL { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.link)

            Spacer(minLength: 0)

            HStack {
                Button("Install or Repair") { install() }
                    .disabled(busy)
                Button("Remove Helper") { remove() }
                    .disabled(busy)
                Spacer()
                Button("Test USB Access") { diagnose() }
                    .disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 480, height: 340)
        .onAppear(perform: refresh)
    }

    // MARK: - Actions
    //
    // All helper calls block, so they run off the main queue and hop back to
    // publish. Doing this on the main thread would hang the window for as long
    // as launchd takes to start a cold daemon.

    private func refresh() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let described = Self.describe(PrivilegedHelper.shared.status)
            DispatchQueue.main.async {
                statusText = described.title
                detail = described.detail
                isHealthy = described.healthy
                busy = false
            }
        }
    }

    private func install() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String
            var healthy = false
            do {
                try PrivilegedHelper.shared.ensureReady()
                message = "Installed and responding."
                healthy = true
            } catch {
                message = error.localizedDescription
            }
            let described = Self.describe(PrivilegedHelper.shared.status)
            DispatchQueue.main.async {
                statusText = described.title
                detail = message
                isHealthy = healthy
                busy = false
            }
        }
    }

    /// Reports which of the two processes is actually being refused, so the
    /// next step is a fact rather than a guess.
    private func diagnose() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let report = AccessDiagnostics.run()
            let title: String
            switch report.outcome {
            case .ok:
                title = "USB access OK"
            case .blocked:
                title = "USB access blocked"
            case .inconclusive:
                // Not "blocked": nothing was established either way, and saying
                // otherwise sends the user to fix a setting that may be fine.
                title = "Couldn't test USB access"
            }
            DispatchQueue.main.async {
                statusText = title
                detail = report.summary
                isHealthy = report.outcome == .ok
                busy = false
            }
        }
    }

    private func remove() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            var message = "Removed. BootIt will ask to reinstall it next time it writes macOS."
            do {
                try PrivilegedHelper.shared.uninstall()
            } catch {
                message = error.localizedDescription
            }
            let described = Self.describe(PrivilegedHelper.shared.status)
            DispatchQueue.main.async {
                statusText = described.title
                detail = message
                isHealthy = false
                busy = false
            }
        }
    }

    /// How one `SMAppService.Status` should read to a person.
    struct Description: Equatable {
        let title: String
        let detail: String
        let healthy: Bool
    }

    /// Kept static and pure so the wording is testable without a daemon.
    static func describe(_ status: SMAppService.Status) -> Description {
        switch status {
        case .enabled:
            return Description(title: "Installed",
                               detail: "The helper is registered and allowed to run.",
                               healthy: true)
        case .requiresApproval:
            return Description(title: "Waiting for your approval",
                               detail: "Open System Settings → General → Login Items & Extensions "
                                     + "and enable BootIt under “Allow in the Background”.",
                               healthy: false)
        case .notRegistered:
            return Description(title: "Not installed",
                               detail: "BootIt will install it the first time it writes a macOS drive.",
                               healthy: false)
        case .notFound:
            return Description(title: "Not found",
                               detail: "This copy of BootIt is missing its helper, or is not signed. "
                                     + "Re-download it from the releases page.",
                               healthy: false)
        @unknown default:
            return Description(title: "Unknown", detail: "", healthy: false)
        }
    }
}
