import SwiftUI

/// The two sizes the panel uses, holding AppKit's own segmented metrics: 16 / 20pt tall on 9 / 11pt
/// type, with the side padding read back off the native control's measured widths (a `.mini` pair of
/// tabs is 92pt wide, a `.small` row of four ranges 198pt). They are copied rather than derived so a
/// surface that swaps the native control for this one keeps the exact geometry it laid out around -
/// the header's fit test in particular decides whether the clock still fits from this control's width.
enum NeutralSegmentedSize {
    case mini, small

    var height: CGFloat { self == .mini ? 16 : 20 }
    var font: Font { .system(size: self == .mini ? 9 : 11) }
    var sidePadding: CGFloat { self == .mini ? 7.5 : 9 }
    var radius: CGFloat { self == .mini ? 5 : 6 }
}

/// A segmented control that stays grey whatever the window is doing. AppKit's own draws its selection
/// in the accent colour while the window is key and in neutral grey when it is not, which on a panel
/// that is watched all day means the loudest thing on screen is a tab that is merely still selected.
/// This one commits to the quiet half of that pair: the same neutral fills the system reserves for an
/// inactive window, in every window state, so the accent stays spent on the things that earn it (the
/// pin, the smart pick, the meters).
///
/// It is a row of buttons rather than a restyled `Picker`: the native control's selection colour comes
/// from its key-window state, not from `.tint`, so there is nothing to override. The fills are the
/// system's inactive greys sampled off it (the track lifts the surface a shade, the chip about three
/// times as far), which is why they are opacities on `Color.primary` rather than fixed colours - one
/// pair reads correctly in both appearances and over the pinned panel's glass, where a fixed colour
/// would not.
struct NeutralSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let size: NeutralSegmentedSize
    let label: (Value) -> String

    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { segment($0) }
        }
        .background(shape(radius: size.radius).fill(Color.primary.opacity(0.07)))
    }

    private func segment(_ option: Value) -> some View {
        let isSelected = selection == option
        let text = label(option)
        return Button {
            selection = option
        } label: {
            // Every label drawn hidden underneath the real one, so each segment reserves the width of
            // the widest and the columns come out even - the same reservation AppKit's control makes,
            // and the reason "7D" does not sit in a slot half the width of "Today".
            ZStack {
                ForEach(options, id: \.self) { Text(label($0)).hidden() }
                Text(text)
            }
            .font(size.font)
            .lineLimit(1)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, size.sidePadding)
            .frame(height: size.height)
            // Inset by a point so the chip reads as sitting IN the track rather than replacing a
            // slice of it, which is what the native control draws.
            .background(shape(radius: size.radius - 1)
                .fill(fillColor(option, selected: isSelected))
                .padding(1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? option : (hovered == option ? nil : hovered) }
        .accessibilityLabel(text)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Selection draws the chip, hover only hints at one - the same two-tier fill the layout tiles use,
    /// so the panel's two hand-rolled pickers answer a pointer the same way.
    private func fillColor(_ option: Value, selected: Bool) -> Color {
        if selected { return Color.primary.opacity(0.16) }
        return hovered == option ? Color.primary.opacity(0.07) : .clear
    }

    private func shape(radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
