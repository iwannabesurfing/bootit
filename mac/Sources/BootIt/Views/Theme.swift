import SwiftUI

enum Theme {
    /// Coral accent shared with the original tool (#FF6B35).
    static let accent = Color(red: 1.0, green: 0.420, blue: 0.208)

    /// An original, macOS-app-icon-style gradient for a major macOS version.
    /// Known versions get hand-tuned palettes evoking their wallpapers; any
    /// other (e.g. a future release) gets a deterministic colour by number, so
    /// the picker stays self-updating without bundling Apple's artwork.
    static func macGradient(_ major: Int) -> LinearGradient {
        let colors: [Color]
        switch major {
        case 26: colors = [Color(red: 0.23, green: 0.62, blue: 0.90), Color(red: 0.09, green: 0.33, blue: 0.69)] // Tahoe – blue
        case 15: colors = [Color(red: 0.58, green: 0.39, blue: 0.88), Color(red: 0.35, green: 0.19, blue: 0.66)] // Sequoia – violet
        case 14: colors = [Color(red: 0.97, green: 0.48, blue: 0.52), Color(red: 0.82, green: 0.23, blue: 0.43)] // Sonoma – pink/red
        case 13: colors = [Color(red: 0.98, green: 0.65, blue: 0.33), Color(red: 0.90, green: 0.38, blue: 0.23)] // Ventura – amber
        case 12: colors = [Color(red: 0.36, green: 0.78, blue: 0.74), Color(red: 0.16, green: 0.52, blue: 0.55)] // Monterey – teal
        default:
            let palette: [[Color]] = [
                [Color(red: 0.23, green: 0.62, blue: 0.90), Color(red: 0.09, green: 0.33, blue: 0.69)],
                [Color(red: 0.58, green: 0.39, blue: 0.88), Color(red: 0.35, green: 0.19, blue: 0.66)],
                [Color(red: 0.30, green: 0.75, blue: 0.56), Color(red: 0.13, green: 0.51, blue: 0.41)],
                [Color(red: 0.97, green: 0.48, blue: 0.52), Color(red: 0.82, green: 0.23, blue: 0.43)]
            ]
            colors = palette[abs(major) % palette.count]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A bordered, selectable card (used for the ISO-source choice).
struct SelectableCard<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .font(.title3)
                content
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Theme.accent.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Theme.accent : Color.secondary.opacity(0.25),
                                  lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// A highlighted note / warning box.
struct NoteBox: View {
    let systemImage: String
    let text: String
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.10)))
    }
}

/// A bullet line.
struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 6)
                .foregroundStyle(.secondary)
            Text(text)
            Spacer(minLength: 0)
        }
    }
}
