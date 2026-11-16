import SwiftUI

/// The Display pane's choice of how the pinned panel looks: three tile cards (card B, one grid
/// column each) that each draw the shape they produce, then a direction row for the two strips. The
/// selected tile wears the skeleton's 1.5 point accent frame. The direction row stays visible but
/// greys out on the full panel, which has none, and keeps its value so switching back to a strip
/// returns to the direction the user last chose.
struct PinnedStylePicker: View {
    @Binding var style: PinnedStyle
    @Binding var axis: PinnedAxis

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TileGrid {
                ForEach(PinnedStyle.allCases, id: \.self) { tile($0) }
            }
            directionRow
        }
    }

    private func label(_ style: PinnedStyle) -> String {
        switch style {
        case .rings: L("Rings only")
        case .labeled: L("Labeled strip")
        case .full: L("Full panel")
        }
    }

    private var directionRow: some View {
        let inactive = style == .full
        return HStack(spacing: 12) {
            Text(L("Direction")).font(.system(size: 13))
            NeutralSegmentedPicker(selection: $axis, options: PinnedAxis.allCases, size: .small) {
                $0 == .vertical ? L("Vertical") : L("Horizontal")
            }
            .disabled(inactive)
            .opacity(inactive ? 0.45 : 1)
            .accessibilityLabel(L("Direction"))
            Text(inactive ? L("The full panel has no direction.") : L("Applies to both strips."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func tile(_ option: PinnedStyle) -> some View {
        let selected = style == option
        return Button { style = option } label: {
            TileCard(selected: selected) {
                // 14 from the top and 12 from the bottom of the 96 high tile; the picture sits in the
                // 46 high band between them, the name 13 points on the bottom line.
                VStack(spacing: 0) {
                    glyph(option).frame(height: 46).padding(.top, 14)
                    Spacer(minLength: 0)
                    Text(label(option))
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
        .accessibilityLabel(label(option))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The strips turn with the direction row, so the picture shows what the choice will look like.
    @ViewBuilder
    private func glyph(_ option: PinnedStyle) -> some View {
        let vertical = axis == .vertical
        switch option {
        case .rings:
            board(vertical: vertical) {
                ForEach(0 ..< 4, id: \.self) { _ in ring }
            }
        case .labeled:
            // A vertical strip shows one account per line; a horizontal one fits three side by side.
            board(vertical: vertical) {
                ForEach(0 ..< (vertical ? 4 : 3), id: \.self) { _ in
                    HStack(spacing: 2) {
                        ring
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.35)).frame(width: 10, height: 3)
                    }
                }
            }
        case .full:
            VStack(spacing: 4) {
                ForEach(0 ..< 2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.15)).frame(width: 62, height: 12)
                }
            }
        }
    }

    private var ring: some View {
        Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.5).frame(width: 8, height: 8)
    }

    /// The strip's plate: 4 point padding, a 3 point gap, the thin side 14 for rings alone.
    @ViewBuilder
    private func board(vertical: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        let plate = RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
        if vertical {
            VStack(spacing: 3) { content() }.padding(3).background(plate)
        } else {
            HStack(spacing: 3) { content() }.padding(3).background(plate)
        }
    }
}
