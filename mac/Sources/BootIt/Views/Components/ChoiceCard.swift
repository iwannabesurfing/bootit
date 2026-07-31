import SwiftUI

/// A selectable card for a mutually exclusive choice.
///
/// Selection is signalled by a tinted fill, an accent border and a trailing
/// checkmark — deliberately *not* also a leading radio dot, which the previous
/// version had. Three simultaneous cues for one piece of state read as noise.
struct ChoiceCard<Content: View>: View {
    let selected: Bool
    var symbol: String?
    let action: () -> Void
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 22))
                        .foregroundStyle(selected ? Theme.accent : Color.secondary)
                        .frame(width: 34)
                        .accessibilityHidden(true)
                }
                content
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.35))
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.cardFill(selected: selected)))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(hovering && !selected
                              ? Color.secondary.opacity(0.35)
                              : Theme.cardBorder(selected: selected),
                              lineWidth: selected ? Theme.selectedBorderWidth : Theme.borderWidth))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: Theme.selectionDuration), value: selected)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A bullet line, used for the start-up instructions on the completion screen.
struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 6)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
            Spacer(minLength: 0)
        }
    }
}
