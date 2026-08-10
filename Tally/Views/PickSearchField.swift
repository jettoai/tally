import AppKit
import SwiftUI

/// One column's filter field: a real `NSTextField`, wrapped.
///
/// WHY APPKIT RATHER THAN A DRAWN FIELD, which is what this replaces. The first version of this
/// surface captured raw keypresses and drew the query itself, to keep the arrow keys and Enter on
/// the panel. Two things killed it, in order:
///
///   1. BACKSPACE DID NOTHING (Albert, on the panel): a key that carries no printable character has
///      to be recognised by name, and the one catch-all handler recognised it by the character it
///      carries, which is not the one `KeyEquivalent.delete` spells.
///   2. AN ACCOUNT CAN BE CALLED ANYTHING (codex review): a nickname is whatever the person typed
///      into Settings, so a fleet can hold names in any script, and a name that has to be COMPOSED
///      cannot be typed as raw keypresses at all. Filtering by what you can read is the whole point
///      of the field, and an input method needs marked text, which only a real field has.
///
/// So the field is native and gets everything native for free: composition, paste, the caret,
/// selection, backspace and delete, and every key repeat. What the PANEL still owns is the small
/// set of keys that answer it, taken in `control(_:textView:doCommandBy:)` before the field editor
/// acts on them, and decided by the same pure rule the rest of the keyboard goes through
/// (`pickKeyAction`).
///
/// THE PANEL'S KEY-WINDOW FAMILY IS UNTOUCHED BY THIS, which is worth stating because that family
/// has cost four rounds (`pickGraceVerdict`): the field is a first responder INSIDE the panel, and
/// `windowDidResignKey` fires when the WINDOW loses key, not when the responder inside it changes.
/// Editing this field, or moving between the two, never looks like the person putting the panel
/// down.
struct PickSearchField: NSViewRepresentable {
    /// What the column is filtered by now. One-way down: the panel owns the query, because clearing
    /// it is one of the things Escape does.
    let text: String
    let placeholder: String
    /// Whether this column is the one the keyboard is in. The first responder follows it, so
    /// stepping across with an arrow key moves the caret to the other field.
    let isFocused: Bool
    /// A key the panel answers with. True means the panel took it; false leaves it to the field,
    /// which is how a caret step stays a caret step (`pickKeyAction` decides which is which).
    let command: (PickKey) -> Bool
    /// What was typed, on every change: composition, paste and backspace all arrive here.
    let onEdit: (String) -> Void
    /// This field started editing, which is how a CLICK moves the panel's focus. Without it the
    /// panel would go on believing the other column is focused and take the responder back.
    let onFocus: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.command = command
        context.coordinator.onEdit = onEdit
        context.coordinator.onFocus = onFocus
        context.coordinator.isFocused = isFocused
        field.placeholderString = placeholder
        // Written only when it really differs, so an update never disturbs a caret or a composition
        // in progress.
        if field.stringValue != text { field.stringValue = text }
        guard isFocused else { return }
        // ASYNC, because the view may not be in a window yet on the first pass, and a responder
        // cannot be made in a window that is not there. Re-checked inside: by the time this runs
        // the focus may have moved on, and taking the responder back then would be this view
        // fighting the person.
        DispatchQueue.main.async {
            guard context.coordinator.isFocused, let window = field.window,
                  window.firstResponder !== field.currentEditor() else { return }
            window.makeFirstResponder(field)
            // The caret lands at the END rather than over a selected query: coming back to a column
            // and typing must add to what is there, not replace it. Counted the way an `NSRange`
            // counts (`pickCaretEnd` says what goes wrong when it is not).
            field.currentEditor()?.selectedRange = NSRange(location: pickCaretEnd(field.stringValue),
                                                           length: 0)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(command: command, onEdit: onEdit, onFocus: onFocus, isFocused: isFocused)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var command: (PickKey) -> Bool
        var onEdit: (String) -> Void
        var onFocus: () -> Void
        var isFocused: Bool

        init(command: @escaping (PickKey) -> Bool, onEdit: @escaping (String) -> Void,
             onFocus: @escaping () -> Void, isFocused: Bool) {
            self.command = command
            self.onEdit = onEdit
            self.onFocus = onFocus
            self.isFocused = isFocused
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onEdit(field.stringValue)
        }

        func controlTextDidBeginEditing(_ notification: Notification) { onFocus() }

        /// The keys the panel answers with, intercepted before the field editor acts on them.
        ///
        /// EVERYTHING ELSE IS THE FIELD'S, deliberately: backspace, forward delete, word motion,
        /// select-all, paste and every input-method command reach it untouched, which is the whole
        /// reason this is a real field. Only these six are ours, and two of them are handed back
        /// when the panel says they are not its business (a caret step in a query that has one).
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            let key: PickKey
            switch selector {
            case #selector(NSResponder.moveUp(_:)): key = .up
            case #selector(NSResponder.moveDown(_:)): key = .down
            case #selector(NSResponder.moveLeft(_:)): key = .left
            case #selector(NSResponder.moveRight(_:)): key = .right
            case #selector(NSResponder.insertNewline(_:)): key = .enter
            case #selector(NSResponder.cancelOperation(_:)): key = .escape
            default: return false
            }
            return command(key)
        }
    }
}
