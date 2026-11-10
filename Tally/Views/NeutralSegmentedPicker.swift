import SwiftUI
import AppKit
import Combine

/// The two sizes the panel uses: the header's tab switch (24pt segments on 12.5pt type) and the
/// footer's and view options' segments (22pt on 12pt), inside a 3pt capsule track. The header's fit
/// test decides whether the clock still fits from this control's measured width, so a size change
/// here is picked up there without a number to keep in step.
enum NeutralSegmentedSize {
    case mini, small

    var height: CGFloat { self == .mini ? 22 : 20 }
    var font: Font { .system(size: self == .mini ? 12 : 11, weight: .semibold) }
    var sidePadding: CGFloat { self == .mini ? 12 : 10 }
    /// The track's inner margin around the segments, and the gap between two segments.
    static let trackInset: CGFloat = 2
    static let segmentGap: CGFloat = 2
    /// The attention dot's diameter (see `badged`), set in the segment's top trailing corner.
    var badgeDot: CGFloat { 6 }
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
    /// Whether a press on a segment may also move the pinned panel (see `DragOrTapArea`). Off by
    /// default and asked for only by the copy that sits in the panel's header, which is the one
    /// standing in the middle of that surface's grab strip; the footer's and the token view's own
    /// copies are surrounded by draggable space already and would gain nothing.
    var dragsWindow = false
    /// Which segments carry an attention dot: something on that page wants somebody, said without
    /// making them open it (the panel's tab switch marks the session board when a session is
    /// blocked). Nothing by default, so the copies that have nothing to report are unchanged.
    ///
    /// Drawn as an OVERLAY on purpose: a badge must never change what this control measures. The
    /// header's fit test decides whether the clock still fits from this row's width, so a dot that
    /// took layout space would move the clock in and out as sessions came and went.
    var badged: (Value) -> Bool = { _ in false }
    let label: (Value) -> String

    @Environment(\.controlActiveState) private var activeState
    @State private var hovered: Value?
    /// Full Keyboard Access as of the last time this surface came to the front. AppKit publishes the
    /// preference as a plain Bool with nothing to observe, so a body that read it inline kept whatever
    /// was true when it last happened to redraw: a user who turns keyboard navigation on in System
    /// Settings would come back to a row that is still out of the tab order until something unrelated
    /// redrew it. Re-read on the way back in, which is the path that preference change has to take.
    @State private var keyboardAccess = false
    /// Whether the app was frontmost as of the last change either way. The pinned panel is why this is
    /// not just `activeState`: a non-activating floating panel reports itself key whatever the rest of
    /// the screen is doing, so on that surface the window-level reading alone never goes quiet.
    @State private var appActive = false
    /// Whether the row still held focus when this surface last went quiet. That is what separates focus
    /// AppKit is handing back from focus SwiftUI has just seeded (see `cameForward`).
    @State private var keptFocusThroughQuiet = false
    @FocusState private var isFocused: Bool

    /// This surface going quiet, and coming back: the window losing or taking key, and the app losing
    /// or taking the front. Both matter because neither covers every host - a dashboard window resigns
    /// key when the app deactivates, the pinned panel does not.
    private var wentQuiet: some Publisher<Notification, Never> {
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))
    }

    private var cameForward: some Publisher<Notification, Never> {
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    }

    var body: some View {
        HStack(spacing: NeutralSegmentedSize.segmentGap) {
            ForEach(options, id: \.self) { segment($0) }
        }
        .padding(NeutralSegmentedSize.trackInset)
        .background {
            Capsule().fill(PanelStyle.seg)
            Capsule().strokeBorder(PanelStyle.segEdge, lineWidth: 1)
        }
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
        .focusable(keyboardAccess)
        .focused($isFocused)
        // Arrow keys, read as keys rather than as move commands: `onMoveCommand` never fired for this
        // control in any of its three hosts (verified on screen, both with and without the flags a
        // real arrow event carries), and a keyboard affordance that only exists in the source is
        // worse than none.
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .focusEffectDisabled()
        // The ring belongs to a surface the keyboard can currently reach: the key window of the app in
        // front. Focus survives that surface going quiet, the decoration does not, which is what every
        // system control does. The focus itself is deliberately left alone, so a keyboard user comes
        // back to where they were. Without the gate the pinned panel - a window that sits on screen all
        // day - keeps a lit ring pointing at a control no keystroke can reach.
        .overlay(Capsule()
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .padding(-2)
            .opacity(isFocused && appActive && activeState == .key ? 1 : 0))
        .onAppear {
            keyboardAccess = NSApplication.shared.isFullKeyboardAccessEnabled
            appActive = NSApplication.shared.isActive
        }
        .onReceive(wentQuiet) { _ in
            keptFocusThroughQuiet = isFocused
            appActive = NSApplication.shared.isActive
        }
        // Nothing should start focused - the same rule the Settings window enforces with
        // `makeFirstResponder(nil)`. SwiftUI hands initial focus to the first focusable view when a
        // window becomes key, so merely clicking the panel lit a blue ring around the tab switch: a
        // ring is feedback for keyboard navigation, and a mouse user who never pressed Tab has not
        // asked for any.
        //
        // Focus the user tabbed to and left behind is the exception, and the reason this cannot be an
        // unconditional clear: AppKit restores the first responder when a surface comes back, and
        // wiping it would send a keyboard user back to the top of the tab order every time they came
        // back from another app. Only focus that was NOT already there when this surface went quiet is
        // SwiftUI's own seeding, and only that gets cleared.
        .onReceive(cameForward) { _ in
            keyboardAccess = NSApplication.shared.isFullKeyboardAccessEnabled
            appActive = NSApplication.shared.isActive
            if !keptFocusThroughQuiet { isFocused = false }
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
            .foregroundStyle(isSelected ? PanelStyle.segOnText : PanelStyle.segText)
            .padding(.horizontal, size.sidePadding)
            .frame(height: size.height)
            // The thumb is a capsule sitting IN the track (the track's own inset is the margin). In
            // the dark appearance a light runs along its top edge; in the light one it lifts off the
            // track on a soft shadow.
            .background {
                Capsule()
                    .fill(fillColor(option, selected: isSelected))
                    .shadow(color: isSelected ? PanelStyle.cardShadow : .clear, radius: 1.5, y: 1)
                if isSelected {
                    Capsule().strokeBorder(PanelStyle.segOnTop, lineWidth: 1)
                        .mask(alignment: .top) {
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: size.height / 2)
                        }
                }
            }
            // Inside the segment's own corner rather than over its edge: the header is a short row
            // and a dot hanging off the thumb would be clipped by the surface above.
            .overlay(alignment: .topTrailing) {
                if badged(option) {
                    Circle()
                        .fill(PanelStyle.tabDot)
                        .frame(width: size.badgeDot, height: size.badgeDot)
                        .padding(.top, 4)
                        .padding(.trailing, 5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // On the pinned panel a press that travels moves the window instead of switching the tab,
        // which is what stops the centred switch from being a hole in the header's grab strip. The
        // tap half is this same button's action, so the two readings of a press can never disagree
        // about what a click does.
        .windowDragOrTap(enabled: dragsWindow) { selection = option }
        .focusable(false)
        .onHover { hovered = $0 ? option : (hovered == option ? nil : hovered) }
        .accessibilityLabel(text)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Selection draws the chip, hover only hints at one - the same two-tier fill the layout tiles use,
    /// so the panel's two hand-rolled pickers answer a pointer the same way.
    private func fillColor(_ option: Value, selected: Bool) -> Color {
        if selected { return PanelStyle.segOn }
        return hovered == option ? Color.primary.opacity(0.07) : .clear
    }
}
