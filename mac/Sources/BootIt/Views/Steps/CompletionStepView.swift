import SwiftUI

/// Stage 6 — the finished drive, and what to do with it.
struct CompletionStepView: View {
    @EnvironmentObject var model: AppModel
    private var isMac: Bool { model.platform == .macos }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
                .padding(.top, 4)

            Text(model.pageTitle)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            if let drive = model.selectedDrive {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(drive.name) (\(drive.deviceID))").font(.headline)
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: 420)
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Color.secondary.opacity(0.18)))
                .accessibilityElement(children: .combine)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Next steps").font(.headline)
                // The drive is still mounted on *this* Mac at this point, so
                // "plug it into the target Mac" was skipping the step that
                // protects the thing we just spent fifteen minutes writing.
                if !model.driveEjected {
                    Bullet("Eject the drive before unplugging it")
                }
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

            if model.driveEjected {
                Label("Safe to unplug", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ejected-confirmation")
            }
            if let ejectError = model.ejectError {
                // A banner, not a footnote. This is an action the user pressed
                // and which did not happen; as grey secondary text under a green
                // tick it read as a hint about the list above it, and the drive
                // stayed mounted while the screen still said "ready".
                StatusBanner(.warning, message: ejectError)
                    .accessibilityIdentifier("eject-error")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var summary: String {
        var parts: [String] = []
        if isMac {
            if let installer = model.selectedMacInstaller { parts.append(installer.displayName) }
        } else {
            parts.append(model.osChoice.title)
            if model.editionIndex < model.editions.count {
                parts.append(model.editions[model.editionIndex].name)
            }
        }
        if let drive = model.selectedDrive { parts.append(drive.sizeText) }
        return parts.joined(separator: "  ·  ")
    }
}

#if DEBUG
#Preview("Windows complete") {
    CompletionStepView().environmentObject(PreviewModel.completed()).padding().frame(width: 560)
}

#Preview("macOS complete") {
    CompletionStepView().environmentObject(PreviewModel.completed(platform: .macos))
        .padding().frame(width: 560)
}

#Preview("Windows complete — dark") {
    CompletionStepView().environmentObject(PreviewModel.completed())
        .padding().frame(width: 560).preferredColorScheme(.dark)
}
#endif
