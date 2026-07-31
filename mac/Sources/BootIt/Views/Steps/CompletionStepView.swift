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

            if let drive = model.selectedDrive {
                Button {
                    model.eject(drive)
                } label: {
                    Label("Eject Drive", systemImage: "eject")
                }
                .accessibilityIdentifier("eject-button")
                if let ejectError = model.ejectError {
                    Text(ejectError).font(.footnote).foregroundStyle(.secondary)
                }
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
