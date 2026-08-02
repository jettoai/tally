import SwiftUI

/// The panel's column count as a row of layout tiles rather than a list of numbers: every tile draws
/// the shape it produces (one bar per column, at the width that column would get), so the choice is
/// read as a picture of the result instead of a figure to translate. Auto draws the same bars with
/// uneven heights - the panel decides that one, so its tile deliberately commits to no count.
///
/// Shared by the Settings pane and the panel's view options, which means the two surfaces cannot
/// drift into offering the same setting in two different vocabularies.
struct LayoutColumnPicker: View {
    /// `SettingsStore.panelColumns`: 0 = auto, 1...4 = an explicit width.
    @Binding var selection: Int

    @State private var hovered: Int?

    private static let auto = 0
    private static let options = [auto, 1, 2, 3, 4]
    private static let glyphWidth: CGFloat = 26
    private static let glyphHeight: CGFloat = 14
    private static let tileRadius: CGFloat = 6

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.options, id: \.self) { option in
                tile(option)
            }
        }
    }

    private func tile(_ option: Int) -> some View {
        let isSelected = selection == option
        let description = Self.description(option)
        return Button {
            selection = option
        } label: {
            VStack(spacing: 4) {
                glyph(option, active: isSelected)
                Text(option == Self.auto ? L("Auto") : "\(option)")
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 42)
            .padding(.vertical, 6)
            .background(shape.fill(fillColor(option, selected: isSelected)))
            // Selected reads on the border as well as the fill: over the panel's glass a tinted
            // fill alone is easy to lose, and the border survives whatever shows through.
            .overlay(shape.strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : .clear,
                                        lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? option : (hovered == option ? nil : hovered) }
        .help(description)
        .accessibilityLabel(description)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous)
    }

    /// Selection tints, hover only hints. Both stay low-opacity so the row reads as one control in
    /// either appearance instead of five lit buttons.
    private func fillColor(_ option: Int, selected: Bool) -> Color {
        if selected { return Color.accentColor.opacity(0.16) }
        return hovered == option ? Color.primary.opacity(0.07) : .clear
    }

    /// The layout itself, at tile size: one bar per column, sharing the glyph's width the way the
    /// cards share the panel's. Auto shows two bars of different heights - the count is not the
    /// user's to fix, so the drawing does not pretend it is.
    private func glyph(_ option: Int, active: Bool) -> some View {
        let bars = option == Self.auto ? 2 : option
        return HStack(spacing: 2) {
            ForEach(0 ..< bars, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(active ? Color.accentColor : Color.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .frame(height: option == Self.auto && index == 1
                           ? Self.glyphHeight * 0.62 : Self.glyphHeight)
            }
        }
        .frame(width: Self.glyphWidth, height: Self.glyphHeight, alignment: .top)
    }

    private static func description(_ option: Int) -> String {
        switch option {
        case auto: return L("Columns chosen automatically")
        case 1: return L("One column")
        default: return String(localized: "\(option) columns", bundle: AppLocale.bundle)
        }
    }
}
