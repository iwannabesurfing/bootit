import SwiftUI

/// The meaning a banner carries. Each case supplies its own symbol *and* an
/// accessibility prefix, so the difference between a note and an error is never
/// communicated by colour alone.
enum StatusBannerStyle {
    case information
    case warning
    case error
    case success

    var symbol: String {
        switch self {
        case .information: return "info.circle.fill"
        case .warning:     return "exclamationmark.triangle.fill"
        case .error:       return "xmark.octagon.fill"
        case .success:     return "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .information: return .accentColor
        case .warning:     return .orange
        case .error:       return .red
        case .success:     return .green
        }
    }

    /// Spoken before the message so VoiceOver conveys severity explicitly.
    var spokenPrefix: String {
        switch self {
        case .information: return ""
        case .warning:     return "Warning: "
        case .error:       return "Error: "
        case .success:     return "Success: "
        }
    }
}

/// A short status message with a semantic style. Replaces the old NoteBox,
/// whose caller had to hand-pick a tint and symbol for every use — which meant
/// an error and a hint could look identical if someone passed the wrong colour.
struct StatusBanner: View {
    let style: StatusBannerStyle
    var title: String?
    let message: String

    init(_ style: StatusBannerStyle, title: String? = nil, message: String) {
        self.style = style
        self.title = title
        self.message = message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title).font(.callout.weight(.semibold))
                }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(title == nil ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.smallRadius).fill(style.tint.opacity(0.10)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.spokenPrefix + [title, message].compactMap { $0 }.joined(separator: ". "))
    }
}
