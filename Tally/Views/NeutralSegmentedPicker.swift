import SwiftUI
import AppKit

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
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { segment($0) }
        }
        .background(shape(radius: size.radius).fill(Color.primary.opacity(0.07)))
        // Held at its ideal width, the one thing the native control did for free. Free to compress,
        // it hands a squeezed width to the header's width probe, and the fit test then reads "the
        // clock still fits" off a number the clock itself caused - the labels truncate to "..." and
        // stay there, because nothing about that state asks the row to give the clock up instead.
        .fixedSize()
        // One tab stop for the row and arrows between the segments, which is the keyboard contract
        // the native control came with: the segments themselves are taken out of the focus chain, so
        // a row of tabs is one stop rather than one per label.
        //
        // Gated on Full Keyboard Access because that is AppKit's own rule for a segmented control
        // (`acceptsFirstResponder` answers the same flag), and the gate is load-bearing rather than
        // decorative: a view that is always focusable is one more thing in every window's tab order
        // and one more thing eating the arrow keys, on a surface whose users mostly never reach for
        // the keyboard at all.
        .focusable(NSApplication.shared.isFullKeyboardAccessEnabled)
        .focused($isFocused)
        // Arrow keys, read as keys rather than as move commands: `onMoveCommand` never fired for this
        // control in any of its three hosts (verified on screen, both with and without the flags a
        // real arrow event carries), and a keyboard affordance that only exists in the source is
        // worse than none.
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .focusEffectDisabled()
        .overlay(shape(radius: size.radius + 1)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .padding(-2)
            .opacity(isFocused ? 1 : 0))
        // Nothing should start focused - the same rule the Settings window enforces with
        // `makeFirstResponder(nil)`. SwiftUI hands initial focus to the first focusable view when a
        // window becomes key, so merely clicking the panel lit a blue ring around the tab switch: a
        // ring is feedback for keyboard navigation, and a mouse user who never pressed Tab has not
        // asked for any.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isFocused = false
        }
    }

    /// Left and right walk the row and stop at its ends. No wrap-around: the native control does not
    /// wrap either, and a selection that jumps from one end to the other is a change nobody asked for
    /// on the way past the edge. An arrow at the end is still handled, so it stays inside the control
    /// instead of falling through to whatever is behind it.
    private func step(_ delta: Int) -> KeyPress.Result {
        guard let index = options.firstIndex(of: selection) else { return .ignored }
        let next = index + delta
        if options.indices.contains(next) { selection = options[next] }
        return .handled
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
        .focusable(false)
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
