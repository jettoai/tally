import Foundation

// WHICH PRESSES THE PICK PANEL DOES NOT OWN. Its own file for the reason pickclaimchecks.swift is:
// one decision, with one incident behind it.
//
// THE INCIDENT (Albert, 2026-08-10). The panel's backstop handlers answered every arrow they were
// given, and an arrow is spelled the same way whether somebody means the next column or the next
// desktop. Control-Left and Control-Right are how macOS moves between desktops, so pressing them
// over the panel changed the focused column and the desktop stayed exactly where it was: a key the
// panel does not own, taken because the key it is spelled with is.
//
// The rule is pure, so what a modifier means is asserted here; the wiring that asks it on the way
// in is locked by source, the way the rest of this surface is (a scan proves the call is written,
// not that AppKit delivers the event - that last step is a person pressing the key).
func runPickModifierChecks() {

    // MARK: - 37h. A press wearing a modifier is somebody doing something else

    check("nothing held is this panel's press",
          !pickPressIsElsewhere(command: false, control: false, option: false))
    check("control is the desktop switch this was written for",
          pickPressIsElsewhere(command: false, control: true, option: false))
    check("command is a shortcut somewhere else on the machine",
          pickPressIsElsewhere(command: true, control: false, option: false))
    check("option is the caret walking by word, which belongs to a field and not to us",
          pickPressIsElsewhere(command: false, control: false, option: true))
    check("and any combination of them still is",
          pickPressIsElsewhere(command: true, control: true, option: true)
              && pickPressIsElsewhere(command: false, control: true, option: true))

    // SHIFT IS ABSENT ON PURPOSE, and its absence is a decision rather than an omission: on this
    // surface Shift is a direction (Shift-Tab is the way back through the columns), so a rule that
    // handed every shifted press to the machine would take that key away. It is not a parameter
    // here at all, which is the only way it cannot be added by accident, and the Tab handler below
    // is what reads it instead.
    let view = (try? String(contentsOfFile: "Tally/Views/PickPanelView.swift", encoding: .utf8)) ?? ""
    check("the panel view is readable from this suite", !view.isEmpty)
    check("Shift still means the other direction rather than somebody else's shortcut",
          view.contains("act(press.modifiers.contains(.shift) ? .backtab : .tab)"))

    // MARK: - 37h2. …and the arrows are asked before the panel acts on them

    // ALL FOUR, since Control-Up and Control-Down are Mission Control the way sideways is Spaces,
    // and one arrow left answering would be the same defect with a different key.
    for (key, direction) in [("upArrow", "up"), ("downArrow", "down"),
                             ("leftArrow", "left"), ("rightArrow", "right")] {
        check("the \(direction) arrow goes through the modifier question: \(key)",
              view.contains(".onKeyPress(.\(key), phases: [.down, .repeat]) { press in act(press, as: .\(direction)) }"))
    }
    check("…which declines the press rather than acting on it, so the event carries on",
          view.contains("else { return .ignored }\n        return act(key)"))
    check("…and reads the rule from the pure one rather than spelling the modifiers again",
          view.contains("pickPressIsElsewhere(command: press.modifiers.contains(.command)")
              && view.contains("control: press.modifiers.contains(.control)")
              && view.contains("option: press.modifiers.contains(.option))"))
    // ONE ANSWER FOR ONE PRESS: the typing handler asked the same three modifiers in its own words
    // before this, and two spellings of one rule are two rules the moment either is edited.
    check("the typing handler comes through the same door rather than asking again",
          view.contains("act(press, as: .text(press.characters))")
              && !view.contains("guard !press.modifiers.contains(.command)"))
}
