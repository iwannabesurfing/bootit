import SwiftUI

/// Stage 1 — which operating system the finished USB will install.
struct PlatformStepView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                card(.windows)
                card(.macos)
            }

            StatusBanner(.information,
                         message: "BootIt downloads official installers from Microsoft and Apple, "
                                + "or uses an installer you already have.")
        }
    }

    /// A taller tile than `ChoiceCard`, because this is the one choice with only
    /// two options and no supporting detail to read — it can afford the space.
    private func card(_ platform: AppModel.Platform) -> some View {
        let selected = model.platform == platform
        return Button { model.platform = platform } label: {
            VStack(spacing: 10) {
                Image(systemName: platform.symbol)
                    .font(.system(size: 38))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .accessibilityHidden(true)
                Text(platform.title).font(.title3.weight(.semibold))
                Text(platform.cardDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 158)
            .padding(.horizontal, 10)
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.accent)
                        .padding(10)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.cardFill(selected: selected)))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.cardBorder(selected: selected),
                              lineWidth: selected ? Theme.selectedBorderWidth : Theme.borderWidth))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: Theme.selectionDuration), value: selected)
        .accessibilityIdentifier("platform-card-\(platform.rawValue)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(platform.title). \(platform.cardDescription)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

extension AppModel.Platform {
    /// Longer than `subtitle`, which has to fit the compact platform summary.
    var cardDescription: String {
        self == .windows ? "Create a Windows 10 or 11 installer"
                         : "Create an installer for a compatible Mac"
    }
}

#if DEBUG
#Preview("Nothing selected") {
    PlatformStepView().environmentObject(PreviewModel.platform(nil)).padding().frame(width: 560)
}

#Preview("Windows selected") {
    PlatformStepView().environmentObject(PreviewModel.platform(.windows)).padding().frame(width: 560)
}

#Preview("macOS selected — dark") {
    PlatformStepView().environmentObject(PreviewModel.platform(.macos))
        .padding().frame(width: 560).preferredColorScheme(.dark)
}
#endif
