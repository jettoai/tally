import Foundation

// THE KEYBOARD THE PICK PALETTE ANSWERS WITH, split out of PickPalette.swift when that file reached
// the length where two decisions were sharing one: the palette is what the panel IS (columns, what
// each has circled, what a submit comes to), and this is what a keypress DOES to it.
//
// NAMED KEYS AND ONE TOTAL FUNCTION, which is the whole shape of it. The keys are named here rather
// than taken from SwiftUI or from AppKit's selectors so that the rule below is pure: what Enter,
// Escape, an arrow and a Tab mean on this surface can be asserted without a screen, which is the
// only half of the keyboard an assertion suite can reach. The other half is the two paths that turn
// a real keypress into one of these (PickSearchField's `doCommandBy` for the field that has the
// responder, PickPanelView's `onKeyPress` for the panel that has none), and those are locked by
// source scans and by a person pressing the key.

/// WHERE THE CARET GOES when a column takes the keyboard back: the end of what is already typed, so
/// coming back to a column adds to the query rather than replacing it.
///
/// UTF-16, BECAUSE THAT IS WHAT AN `NSRange` COUNTS. `String.count` counts what a person calls
/// characters, and the two disagree the moment a query holds an emoji or a composed syllable: an
/// offset measured in graphemes lands short of the end, and the next keystroke is inserted into the
/// middle of the query instead of after it (codex review, 2026-08-10). Nothing about the panel's
/// vocabulary rules those out - an account is called whatever somebody typed into Settings.
func pickCaretEnd(_ text: String) -> Int { text.utf16.count }

/// Which column the focus lands on when it is stepped sideways. Clamped rather than wrapped, like
/// the walk down a column: a held arrow key must come to rest somewhere rather than cycle.
func pickColumnFocus(_ palette: PickPalette, from kind: PickKind, step: Int) -> PickKind {
    guard let index = palette.columns.firstIndex(where: { $0.kind == kind }) else { return kind }
    let landed = min(max(index + step, 0), palette.columns.count - 1)
    return palette.columns[landed].kind
}

// MARK: - The keyboard

/// One keypress, in the vocabulary this surface has. Named here rather than taken from SwiftUI so
/// the rule below can be asserted without a view (the same split the dismissal judgement is under,
/// `pickDismissalIsFromPerson`).
enum PickKey: Equatable, Sendable {
    case up
    case down
    case left
    case right
    /// The key every other surface on the machine changes field with, and the same key back
    /// (`insertTab:` and `insertBacktab:`, which is what Shift-Tab arrives as).
    case tab
    case backtab
    case enter
    case escape
    case delete
    case text(String)
}

/// What a keypress does to the panel.
enum PickKeyAction: Equatable, Sendable {
    /// Up or down the column the keyboard is in.
    case move(Int)
    /// Across to the next column.
    case moveColumn(Int)
    /// Submit everything both columns have circled (`pickSubmission`), which is nothing on a panel
    /// where neither circle has moved off what is already the case.
    case commit
    case cancel
    /// The FOCUSED column's query, after this keypress. Covers typing, backspace and the clearing
    /// half of Escape.
    case edit(String)
    case ignore
}

/// THE WHOLE KEYBOARD, as one total function.
///
/// SIDEWAYS IS FREE HERE, which is what pays for the columns: this field has no caret to walk, so
/// left and right can mean the only other thing a two-column surface needs them to mean. The cost is
/// stated rather than discovered: no caret means no editing in the middle of a query, only typing
/// and backspace, which is what a filter of a dozen model names is answered with anyway.
///
/// ENTER IS THE SUBMIT, WHEREVER THE CURSOR IS, because the circles are what it sends and they are
/// on the screen: the row it takes is not "the one under the cursor" any more, it is everything both
/// columns have circled. On a panel where nothing has been circled off the current state it sends
/// nothing, which is a cancellation and says so ("nothing was changed").
///
/// ESCAPE HAS TWO ANSWERS and the order is the point: a filter that is showing three rows out of
/// thirty is a state a person wants OUT of more often than they want the panel gone, and losing the
/// whole panel to a stray Escape means retyping the command. So the first Escape clears what was
/// typed IN THE COLUMN THE KEYBOARD IS IN, and the second one closes.
///
/// A MODIFIER MEANS SOMEBODY IS DOING SOMETHING ELSE (copying, switching windows), so those presses
/// are handed back untouched rather than typed into the filter; the caller decides what carries a
/// modifier, because that is the one part that is SwiftUI's to say.
func pickKeyAction(_ key: PickKey, query: String) -> PickKeyAction {
    switch key {
    case .up: return .move(-1)
    case .down: return .move(1)
    // SIDEWAYS MEANS TWO THINGS, and the query decides which: with something typed there is a
    // caret in the field and left and right walk it, which is what anybody who has just typed
    // expects; with the field empty there is no caret to walk, so they are free to mean the only
    // other thing a two-column surface needs (`.ignore` hands the key back to the field).
    case .left: return query.isEmpty ? .moveColumn(-1) : .ignore
    case .right: return query.isEmpty ? .moveColumn(1) : .ignore
    // TAB CHANGES COLUMN WHATEVER IS TYPED, which is the one place it differs from the arrows: Tab
    // means "the next field" everywhere on the machine and never means a caret step, so there is no
    // second reading for a query to choose between. It is clamped like the arrows rather than
    // wrapped, and the panel ANSWERS it either way - a Tab handed back would leave the key-view
    // loop to move the responder while the panel went on believing the other column was focused,
    // which is exactly the defect this case exists for (Albert, live, 2026-08-10: Tab across, type,
    // and the caret was pulled back to the column left behind).
    case .tab: return .moveColumn(1)
    case .backtab: return .moveColumn(-1)
    case .enter: return .commit
    case .escape: return query.isEmpty ? .cancel : .edit("")
    case .delete: return query.isEmpty ? .ignore : .edit(String(query.dropLast()))
    case .text(let characters):
        // Only what a person can see: a control character reaching the query would filter the list
        // down to nothing with no way to tell why.
        guard !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return .ignore }
        return .edit(query + characters)
    }
}
