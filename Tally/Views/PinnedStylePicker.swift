import SwiftUI

/// The Display pane's choice of how the pinned panel looks, as three thumbnail cards rather than a
/// list of words: each card draws the shape it produces, so a new idea is read as a picture and the
/// labels can wrap to two lines in any language without stretching a segmented control.
struct PinnedStylePicker: View {
    @Binding var selection: PinnedStyle

    /// Jetto Voice's thumbnail card (B-2526 G19): 132 by 84, 20 apart, the selection a 2pt ring
    /// standing 3pt off the card. The ring needs 5pt of room all round, so each card carries it as
    /// padding and the stack's own gap is 20 minus the two paddings.
    private static let cardSize = CGSize(width: 132, height: 84)
    private static let ringRoom: CGFloat = 5

    var body: some View {
        HStack(alignment: .top, spacing: 20 - 2 * Self.ringRoom) {
            ForEach(PinnedStyle.allCases, id: \.self) { style in
                card(style)
            }
        }
    }

    private func label(_ style: PinnedStyle) -> String {
        switch style {
        case .full: L("Full")
        case .row: L("Compact row")
        case .column: L("Compact column")
        }
    }

    private func card(_ style: PinnedStyle) -> some View {
        let selected = selection == style
        return Button { selection = style } label: {
            VStack(spacing: 8) {
                ZStack { glyph(style) }
                    .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .overlay(RoundedRectangle(cornerRadius: 8 + Self.ringRoom, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
                        .padding(-Self.ringRoom))
                Text(label(style))
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: Self.cardSize.width)
            }
            .padding(Self.ringRoom)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(style))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func glyph(_ style: PinnedStyle) -> some View {
        let ink = Color.primary.opacity(0.25)
        switch style {
        case .full:
            VStack(spacing: 7) {
                ForEach(0 ..< 2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3).fill(ink).frame(width: 86, height: 19)
                }
            }
        case .row:
            RoundedRectangle(cornerRadius: 3).fill(ink).frame(width: 95, height: 12)
        case .column:
            RoundedRectangle(cornerRadius: 3).fill(ink).frame(width: 12, height: 57)
        }
    }
}
