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

/// The block AppKit spells its function keys in: `NSUpArrowFunctionKey` is 0xF700 and the whole
/// family runs to 0xF8FF. Unicode leaves that range to private use, which is exactly why it has to
/// be named here: there is nothing in a general test of a character that rules it out.
let pickFunctionKeyScalars: ClosedRange<UInt32> = 0xF700...0xF8FF

/// WHETHER A PRESS IS SOMETHING A PERSON WOULD SEE IN THE FIELD. The one gate in front of every
/// path that puts characters into a query, so a key that is not typing cannot become typing by
/// arriving through a path that did not think to ask.
///
/// TWO KINDS ARE TURNED AWAY, and the second is the defect this was extracted for:
///
///   1. CONTROL CHARACTERS, which carry no ink: one in the query narrows the list to nothing with
///      nothing on screen to say why.
///   2. THE FUNCTION-KEY BLOCK. An arrow key reaching a TEXT handler still carries a character,
///      and a printable-looking one, because AppKit spells the arrows and the function row as
///      scalars in the private use area. Albert pressed the arrows eight times on the live panel
///      (2026-08-10) and got eight empty boxes in the models filter with "No matches" underneath:
///      the presses had fallen past the panel's own arrow handlers and been typed. The other half
///      of that fix is that they no longer fall through at all (`pickKeyAction`, sideways), and
///      both halves stay: one keeps the key on its own path, this one keeps every other key that
///      carries no ink out of the query whatever path it arrives by.
func pickIsTypable(_ characters: String) -> Bool {
    guard !characters.isEmpty else { return false }
    return characters.unicodeScalars.allSatisfy {
        !CharacterSet.controlCharacters.contains($0) && !pickFunctionKeyScalars.contains($0.value)
    }
}

/// WHETHER A PRESS BELONGS TO THE MACHINE RATHER THAN TO THIS PANEL. Command, control and option
/// are the three that mean somebody is doing something else with it (copying, switching desktops,
/// walking by word), so a press wearing one is handed back untouched instead of acted on.
///
/// THE DEFECT IT CLOSES (Albert, 2026-08-10): the panel's own arrow handlers answered every arrow
/// they were given, modifiers and all, so Control-Left and Control-Right, which is how macOS moves
/// between desktops, changed the panel's column and never reached the system. A key the panel does
/// not own is not the panel's to take just because the key it is spelled with is.
///
/// SHIFT IS NOT ONE OF THEM: on this surface it is a direction rather than a different intent
/// (Shift-Tab is the way back), and it spells no system shortcut this panel could swallow.
///
/// Asked of the arrows and of typing, and deliberately not of Tab, Enter or Escape: Command-Tab
/// never reaches an app at all, and the other combinations there mean nothing macOS would rather
/// have. The honest limit, since a source scan cannot show it: declining a press is the whole of
/// what the panel can do about it, and where it goes next is AppKit's to decide.
func pickPressIsElsewhere(command: Bool, control: Bool, option: Bool) -> Bool {
    command || control || option
}

/// WHETHER A CIRCLE THAT HAS JUST MOVED IS ONE THE LIST SHOULD SCROLL TO. The keyboard's, always;
/// the pointer's, never.
///
/// THE DEFECT (Albert, 2026-08-10): every change of circle re-centred the column, and a row that was
/// CLICKED is by definition already on screen - so the whole list slid under the pointer that had
/// just landed on it, which reads as the panel jumping. An arrow key is the opposite case and the
/// reason this exists at all: it can walk the circle onto a row that is not drawn yet, and nothing
/// else would bring it into view.
///
/// A DESTINATION RATHER THAN A FLAG, which is what makes the request safe to leave standing. The
/// keyboard writes where it is sending the circle, and a keypress that lands on the row already
/// circled changes nothing - so no observer runs, and the request is still there when the POINTER
/// next moves the circle. It cannot fire then: a stale request equals the index being moved away
/// from, which is the one index the new one cannot be. Consumed on every move regardless, so it is
/// stale for at most one of them.
func pickScrollFollowsKeyboard(asked: Int?, landedOn now: Int) -> Bool { asked == now }

/// Which column the focus lands on when it is stepped sideways. Clamped rather than wrapped, like
/// the walk down a column: a held arrow key must come to rest somewhere rather than cycle.
func pickColumnFocus(_ palette: PickPalette, from kind: PickKind, step: Int) -> PickKind {
    guard let index = palette.columns.firstIndex(where: { $0.kind == kind }) else { return kind }
    let landed = min(max(index + step, 0), palette.columns.count - 1)
    return palette.columns[landed].kind
}

// MARK: - The keyboard

/// One keypress, in the vocabulary this surface has. Named here rather than taken from SwiftUI so
/// the rule below can be asserted without a view (the same split the panel's own focus rules are
/// under, `pickShouldRetryActivation`).
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
/// SIDEWAYS IS THE OTHER COLUMN, which is what pays for the columns: left and right mean the one
/// thing a two-column surface needs a spare key for, and they mean it whether or not something has
/// been typed. The cost is stated rather than discovered, and it is paid in the query: no caret step
/// means a query is typed and backspaced rather than edited in the middle, which is what a filter
/// over a dozen model names is answered with anyway (the case below carries the rest).
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
    // SIDEWAYS IS ALWAYS THE OTHER COLUMN, whatever is typed (Albert, 2026-08-10), and that is a
    // correction of the reading this shipped with. The first one asked the query: an empty field
    // has no caret to walk, so the arrows changed columns, and a field with something in it got
    // them handed back to walk the caret with. It cost two things, and the second is a defect:
    //
    //   1. THE KEY CHANGED MEANING UNDER THE PERSON. Type three letters to narrow the fleet, press
    //      right for the models, and the caret moves one character instead. Wanting the next column
    //      does not stop when somebody has typed, and on this surface it is the commoner want.
    //   2. HANDING A KEY BACK SPLIT THE PATHS. The field walks a caret with it, but the panel's own
    //      backstop has no field to hand anything to: an unclaimed key there falls through to the
    //      next handler, which is TYPING (PickPanelView). That is how eight presses of an arrow key
    //      became eight boxes in the filter, and `pickIsTypable` is the other half of the fix.
    //
    // What it costs is stated rather than discovered: nothing walks into the middle of a query on
    // this surface, so a query is typed and backspaced rather than edited, which is what a filter
    // over a dozen model names and a handful of account names is answered with. Every other motion
    // is untouched and still the field's: word steps, Home, End, and the whole of a selection.
    case .left: return .moveColumn(-1)
    case .right: return .moveColumn(1)
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
        // Only what a person can see, and it is asked HERE because here is where every path that
        // types meets (`pickIsTypable` says what is turned away and what it cost to learn).
        guard pickIsTypable(characters) else { return .ignore }
        return .edit(query + characters)
    }
}
