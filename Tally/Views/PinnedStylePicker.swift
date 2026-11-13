import SwiftUI

/// The Display pane's choice of how the pinned panel looks, as three tile cards (card B, one grid
/// column each) rather than a list of words: each tile draws the shape it produces, so a new idea is
/// read as a picture. The selected tile wears the skeleton's 1.5 point accent frame.
struct PinnedStylePicker: View {
    @Binding var selection: PinnedStyle

    var body: some View {
        TileGrid {
            ForEach(PinnedStyle.allCases, id: \.self) { style in
                tile(style)
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

    private func tile(_ style: PinnedStyle) -> some View {
        let selected = selection == style
        return Button { selection = style } label: {
            TileCard(selected: selected) {
                // 14 from the top and 12 from the bottom of the 96 high tile; the picture sits in the
                // 46 high band between them, the name 13 points on the bottom line.
                VStack(spacing: 0) {
                    glyph(style).frame(height: 46).padding(.top, 14)
                    Spacer(minLength: 0)
                    Text(label(style))
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity)
                .frame(height: PageSkeleton.tileHeight)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(style))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func glyph(_ style: PinnedStyle) -> some View {
        let ink = Color.primary.opacity(0.15)
        switch style {
        case .full:
            VStack(spacing: 4) {
                ForEach(0 ..< 2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3).fill(ink).frame(width: 62, height: 12)
                }
            }
        case .row:
            RoundedRectangle(cornerRadius: 3).fill(ink).frame(width: 70, height: 8)
        case .column:
            RoundedRectangle(cornerRadius: 3).fill(ink).frame(width: 8, height: 40)
        }
    }
}
