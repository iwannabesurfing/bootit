import SwiftUI

/// Colour and metric tokens. Everything semantic comes from the system so both
/// appearances work without a hand-maintained light/dark palette — the accent
/// is the only fixed colour in the app.
enum Theme {

    // MARK: Colour

    /// BootIt coral (#FF6B35). Used for selection, the primary action and
    /// progress — never for warnings, errors or body text, which take their
    /// meaning from the system's semantic colours instead.
    static let accent = Color(red: 1.0, green: 0.420, blue: 0.208)

    // MARK: Metrics

    /// The form stops widening past this, so a maximised window doesn't stretch
    /// a four-field layout across the screen.
    static let contentMaxWidth: CGFloat = 620
    static let pageHorizontalPadding: CGFloat = 30
    static let pageVerticalPadding: CGFloat = 26

    static let cardRadius: CGFloat = 12
    static let smallRadius: CGFloat = 8

    static let selectedFillOpacity: Double = 0.07
    static let selectedBorderWidth: CGFloat = 1.5
    static let borderWidth: CGFloat = 1

    /// Matches the system's own step transitions; also the ceiling for anything
    /// animated here, so nothing feels springy or decorative.
    static let transitionDuration: Double = 0.18
    static let selectionDuration: Double = 0.14

    static func cardFill(selected: Bool) -> Color {
        selected ? accent.opacity(selectedFillOpacity) : Color(nsColor: .controlBackgroundColor)
    }

    static func cardBorder(selected: Bool) -> Color {
        selected ? accent : Color.secondary.opacity(0.18)
    }

    // MARK: macOS version artwork

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
