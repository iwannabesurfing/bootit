import SwiftUI

/// One external drive, shown as a selectable row.
///
/// This is the most consequential choice in the app — the selected drive is
/// about to be erased — so the name, capacity and BSD identifier are all on
/// screen before the user commits, rather than collapsed into a single line
/// of a pop-up menu where only one drive is visible at a time.
struct DriveCard: View {
    let disk: USBDisk
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.name)
                        .font(.headline)
                    Text("\(disk.sizeText)  ·  \(disk.deviceID)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Theme.accent.opacity(0.07) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Theme.accent : Color.secondary.opacity(0.18),
                              lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drive-card-\(disk.deviceID)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(disk.name), \(disk.sizeText), \(disk.deviceID), external drive")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
