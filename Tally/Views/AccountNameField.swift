import AppKit
import SwiftUI

/// The Settings account row's name, renamed in place (B-1033): a click on the name turns it into a
/// field, Enter or a click anywhere else saves, Esc puts the name back as it was - the way a Finder
/// item is renamed. Saving nothing (or the default name) removes the nickname. The row's menu offers
/// the same field rather than a second one.
///
/// "A click anywhere else" is a mouse-down monitor rather than focus loss: clicking empty window
/// background or a switch does not take focus from a text field on macOS, so a field that waited for
/// focus to move would stay open under a click that was meant to close it.
struct AccountNameField: View {
    let defaultLabel: String
    /// What the row shows when it is not being edited (nickname applied).
    let displayed: String
    @Binding var override: String?
    @Binding var isEditing: Bool

    @State private var text = ""
    @State private var cancelled = false
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing {
            TextField("", text: $text, prompt: Text(defaultLabel))
                // A visible field of a fixed width: plain and flexible, it read as a greyed-out name
                // and pushed the row's badge across to the far side (capture, 2026-10-09).
                .textFieldStyle(.roundedBorder)
                .font(.subheadline.weight(.semibold))
                .frame(width: 180)
                // The bordered field stands 8pt taller than the name it replaces; giving that back
                // in layout keeps the row (and every row below it) from moving when rename opens.
                .padding(.vertical, -4)
                .focused($focused)
                .onSubmit { isEditing = false }
                .onExitCommand { cancelled = true; isEditing = false }
                .onAppear {
                    text = override ?? ""
                    cancelled = false
                    // A beat later: opened from the row's menu, the menu is still closing and
                    // takes the focus back with it.
                    DispatchQueue.main.async { focused = true }
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                        if !Self.isInFieldEditor(event) { isEditing = false }
                        return event  // the click still reaches whatever it landed on
                    }
                }
                // Every way out ends here, so saving is written once: Enter, a click elsewhere, the
                // row leaving the list. Only Esc skips it.
                .onDisappear {
                    if let monitor { NSEvent.removeMonitor(monitor) }
                    monitor = nil
                    if !cancelled { override = AccountIdentity.nickname(typed: text, defaultLabel: defaultLabel) }
                }
        } else {
            Text(displayed)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { isEditing = true }
                // The full name, since this is the part of the row that truncates first.
                .tallyTooltip(displayed + "\n" + L("Rename…"))
        }
    }

    /// Whether a click landed in the text being edited, which only moves the caret.
    private static func isInFieldEditor(_ event: NSEvent) -> Bool {
        guard let window = event.window, let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor, let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil)
                                        ?? event.locationInWindow)
        else { return false }
        if hit === editor || hit.isDescendant(of: editor) { return true }
        return (editor.delegate as? NSView).map { hit === $0 || hit.isDescendant(of: $0) } ?? false
    }
}
