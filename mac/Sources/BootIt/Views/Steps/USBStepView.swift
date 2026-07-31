import SwiftUI

/// Stage 4 — the drive to erase. The only irreversible choice in the app, so
/// identity is on screen (name, capacity, BSD id) before anything is confirmed.
struct USBStepView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                        }
                    }
                }
                .accessibilityIdentifier("drive-list")

                if let drive = model.selectedDrive {
                    EraseWarning(drive: drive, acknowledged: $model.hasAcknowledgedErase)
                }

                if model.platform == .macos {
                    StatusBanner(.information,
                                 message: "Creating a macOS installer needs administrator access — "
                                        + "you'll be asked for your password after you confirm.")
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
