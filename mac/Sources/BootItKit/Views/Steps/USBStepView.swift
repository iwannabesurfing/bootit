import AppKit
import SwiftUI

/// Stage 4 — the drive to erase. The only irreversible choice in the app, so
/// identity is on screen (name, capacity, BSD id) before anything is confirmed.
struct USBStepView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Above the drive list, because both of these say "do not press
            // Start yet" and arriving underneath the erase confirmation is too
            // late to be that. Neither is reachable on the Windows path: it
            // never goes near the privileged helper.
            if model.preflight.appWasReplaced {
                AppReplacedWarning()
            }
            if let report = model.preflight.usbAccessReport {
                USBAccessWarning(report: report)
            }
            if model.preflight.warnsAboutAdministrator(platform: model.platform) {
                StatusBanner(.warning,
                             title: "This account can't approve BootIt's helper",
                             message: "Writing a macOS installer needs a background helper, and "
                                    + "macOS only accepts that approval from an administrator "
                                    + "account. Someone who administers this Mac will have to "
                                    + "approve it in System Settings → General → Login Items & "
                                    + "Extensions. A Windows drive needs none of this.")
            }

            if model.disks.isEmpty {
                StatusBanner(.warning,
                             message: "No external drives found. Insert a USB drive "
                                    + "(8 GB+ for Windows, 16 GB+ for macOS) and choose Refresh.")
            } else {
                Text("Available drives").font(.headline)
                VStack(spacing: 8) {
                    ForEach(Array(model.disks.enumerated()), id: \.element.id) { index, disk in
                        DriveCard(disk: disk, selected: model.diskIndex == index) {
                            model.diskIndex = index
                            model.hasAcknowledgedErase = false
                            // Asked here rather than at Start, which is the
                            // whole point: the answer has to arrive while the
                            // user is still deciding, not once they have
                            // committed to erasing this drive.
                            model.checkUSBAccess()
                        }
                    }
                }
                .accessibilityIdentifier("drive-list")

                if let drive = model.selectedDrive {
                    EraseWarning(drive: drive, acknowledged: $model.hasAcknowledgedErase)
                }

                // Suppressed when the administrator warning above is showing:
                // that one already explains the approval, and this one's "macOS
                // asks *you*" would contradict it on the same screen.
                if model.platform == .macos,
                   !model.preflight.warnsAboutAdministrator(platform: model.platform) {
                    StatusBanner(.information,
                                 title: "macOS will ask you to approve BootIt once",
                                 message: "Apple's createinstallmedia has to run with system privileges. "
                                        + "The first time, macOS asks an administrator to allow BootIt "
                                        + "to run a background helper — the prompt names BootIt. After "
                                        + "that it won't ask again, and your password is never seen by "
                                        + "this app.")
                }
            }

            // The download route configures this on the options step. A local ISO
            // never visits that step, so the option appears here instead — it must
            // stay reachable however the user got their image.
            if model.showsBypassOptionOnDriveStep {
                Divider().padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Relax Windows 11 hardware and online-account requirements",
                           isOn: $model.bypassWin11)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("bypass-win11-toggle")
                    Text("Adds setup configuration for unsupported hardware (TPM, Secure Boot, RAM) and "
                       + "offline setup. Writes an autounattend.xml to the USB — your ISO is not modified.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
            }

            Text("Your internal drive is never listed.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Shown when the bundle this process launched from has been replaced on disk.
///
/// The button is Quit rather than a relaunch. Relaunching means asking the new
/// bundle to open while this process is still tearing down, and two BootIts
/// racing for the same daemon is a worse bug than the one being fixed — for a
/// recovery the user can perform in two seconds.
struct AppReplacedWarning: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusBanner(.warning,
                         title: "BootIt was updated while it was open",
                         message: "This window is still running the previous version, and the two "
                                + "disagree about how to talk to the background helper. Quit BootIt "
                                + "and open it again before writing a drive.")
            Button("Quit BootIt") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
                .padding(.leading, 34)
                .accessibilityIdentifier("quit-after-update")
        }
    }
}

/// Shown when the helper has been asked whether it can write, and said no.
///
/// The settings button appears only when the daemon classified its own refusal
/// as a TCC denial. Every other refusal — a read-only volume, a full disk, an
/// I/O error — is still a blocked write, but Full Disk Access does nothing about
/// it, and offering that button anyway is how a user ends up changing an
/// unrelated setting and still failing.
struct USBAccessWarning: View {
    let report: AccessDiagnostics.Report

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusBanner(.warning,
                         title: "This drive can't be written yet",
                         message: report.summary)
            if report.helperNeedsFullDiskAccess {
                Button("Open Full Disk Access Settings…") {
                    if let url = HelperError.fullDiskAccessSettingsURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
                .padding(.leading, 34)
                .accessibilityIdentifier("open-full-disk-access")
            }
        }
    }
}

/// Names the drive rather than asking for a generic acknowledgement — the
/// question that matters is "is this the right one?", not "do you know what
/// erase means?". The warning icon is paired with text, never colour alone.
struct EraseWarning: View {
    let drive: USBDisk
    @Binding var acknowledged: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(drive.name) will be permanently erased.").font(.headline)
                    Text("All files and partitions on this \(drive.sizeText) drive (\(drive.deviceID)) "
                       + "will be removed.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Toggle("I have checked that this is the correct drive.", isOn: $acknowledged)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("confirm-erase-toggle")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.smallRadius).fill(Color.orange.opacity(0.10)))
    }
}

#if DEBUG
#Preview("No drives") {
    USBStepView().environmentObject(PreviewModel.drives([])).padding().frame(width: 560)
}

#Preview("Drives, none selected") {
    USBStepView().environmentObject(PreviewModel.drives()).padding().frame(width: 560)
}

#Preview("Selected, not acknowledged") {
    USBStepView().environmentObject(PreviewModel.drives(selected: 0)).padding().frame(width: 560)
}

#Preview("Selected and acknowledged") {
    USBStepView().environmentObject(PreviewModel.drives(selected: 0, acknowledged: true))
        .padding().frame(width: 560)
}

#Preview("Local ISO — bypass offered here") {
    USBStepView().environmentObject(PreviewModel.drives(selected: 0, source: .local))
        .padding().frame(width: 560)
}

#Preview("Updated while open") {
    USBStepView().environmentObject(PreviewModel.preflightWarning(replaced: true))
        .padding().frame(width: 560)
}

/// Also the one case where the "macOS will ask you to approve BootIt once"
/// note is suppressed, so the screen never says "macOS asks you" beside
/// "an administrator has to".
#Preview("Standard account — can't approve the helper") {
    USBStepView().environmentObject(PreviewModel.preflightWarning(admin: false))
        .padding().frame(width: 560)
}

#Preview("Blocked — Full Disk Access") {
    USBStepView().environmentObject(
        PreviewModel.preflightWarning(access: PreviewModel.blockedByFullDiskAccess))
        .padding().frame(width: 560)
}

#Preview("Blocked — but not by Full Disk Access") {
    USBStepView().environmentObject(
        PreviewModel.preflightWarning(access: PreviewModel.blockedByAReadOnlyVolume))
        .padding().frame(width: 560)
}

#Preview("Selected — dark") {
    USBStepView().environmentObject(PreviewModel.drives(selected: 0, acknowledged: true))
        .padding().frame(width: 560).preferredColorScheme(.dark)
}
#endif
