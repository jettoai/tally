import SwiftUI

/// The panel's column count as a row of layout tiles rather than a list of numbers: every tile draws
/// the shape it produces (one bar per column, at the width that column would get), so the choice is
/// read as a picture of the result instead of a figure to translate. Auto draws the same bars with
/// uneven heights - the panel decides that one, so its tile deliberately commits to no count.
///
/// Shared by the Settings pane and the panel's view options, which means the two surfaces cannot
/// drift into offering the same setting in two different vocabularies.
struct LayoutColumnPicker: View {
    /// `SettingsStore.panelColumns` / `listColumns`: 0 = auto, 1...`maxColumns` an explicit width.
    @Binding var selection: Int
    /// The highest count on offer. Cards go to four; the compact list stops at three, because a row
    /// is nearly twice a card's width and a fourth column of them needs a panel wider than the
    /// screen it would be read on (Albert's call, 2026-08-04).
    var maxColumns: Int = 4
    /// Whether a number here is the MOST columns the page will use rather than the number it will
    /// lay out. False for the account pages, whose count decides the panel's own width and is
    /// therefore always kept exactly. True for the session board, which lives in the width those
    /// pages decided: a panel one comfortable row wide seats one session column whatever the picker
    /// says, and a tile that promised two would be the control lying about the page again (Albert,
    /// 2026-08-15). Said in the words the tile is described in, so the promise is the one the board
    /// can keep in every width.
    var atMost: Bool = false
    /// The Settings pane's size (B-2526 G19): 48-wide tiles, 12pt numbers, and the selection drawn as
    /// the thumbnail cards draw theirs, a 2pt ring standing off the tile. The panel's view options
    /// are a 268-wide popover and keep the compact tile.
    var roomy: Bool = false

    @State private var hovered: Int?

    private static let auto = 0
    private var options: [Int] { [Self.auto] + Array(1 ... maxColumns) }
    private var glyphWidth: CGFloat { roomy ? 30 : 26 }
    private var glyphHeight: CGFloat { roomy ? 16 : 14 }
    private static let tileRadius: CGFloat = 6

    var body: some View {
        HStack(spacing: roomy ? 10 : 6) {
            ForEach(options, id: \.self) { option in
                tile(option)
            }
        }
    }

    private func tile(_ option: Int) -> some View {
        let isSelected = selection == option
        let description = Self.description(option, atMost: atMost)
        return Button {
            selection = option
        } label: {
            VStack(spacing: 4) {
                glyph(option, active: isSelected)
                Text(option == Self.auto ? L("Auto") : "\(option)")
                    .font(roomy ? .system(size: 12, weight: isSelected ? .semibold : .regular).monospacedDigit()
                                : .caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(isSelected ? (roomy ? Color.primary : Color.accentColor) : Color.secondary)
            .frame(width: roomy ? 48 : 42)
            .padding(.vertical, roomy ? 8 : 6)
            .background(shape.fill(fillColor(option, selected: isSelected)))
            // Selected reads on the border as well as the fill: over the panel's glass a tinted
            // fill alone is easy to lose, and the border survives whatever shows through.
            .overlay(shape.strokeBorder(isSelected && !roomy ? Color.accentColor.opacity(0.55) : .clear,
                                        lineWidth: 1))
            .overlay {
                if roomy, isSelected {
                    RoundedRectangle(cornerRadius: Self.tileRadius + 5, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-5)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? option : (hovered == option ? nil : hovered) }
        .tallyTooltip(description)
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
                           ? glyphHeight * 0.62 : glyphHeight)
            }
        }
        .frame(width: glyphWidth, height: glyphHeight, alignment: .top)
    }

    /// What a tile is called, for the callout under the pointer and for VoiceOver alike: one
    /// sentence, so the two channels cannot describe the same tile differently.
    private static func description(_ option: Int, atMost: Bool) -> String {
        switch option {
        case auto: return L("Columns chosen automatically")
        case 1: return atMost ? L("Up to one column") : L("One column")
        default:
            return atMost ? String(localized: "Up to \(option) columns", bundle: AppLocale.bundle)
                          : String(localized: "\(option) columns", bundle: AppLocale.bundle)
        }
    }
}
