import Foundation

// THE PANEL DRAWS WHAT THE RULES SAY IT DRAWS, and every word on it is translated. Split from
// pickpalettechecks.swift the way pickheightchecks.swift was split from pickerchecks.swift, and for
// the same reason: this is one decision of its own, with its own two incidents behind it.
//
// WHY ANY OF IT IS LOCKED BY SOURCE. The layout needs a screen, and a pure rule nobody calls is the
// defect this feature has been bitten by twice: the first two-column panel came up with the wrong
// column listening, and the first filter field dropped backspace in silence. Neither is reachable
// from an assertion suite, so what CAN be asserted is that the view is wired to the rules that were.
//
// The honest limit, recorded rather than glossed: a source scan proves the call is written, not that
// AppKit delivers the event. That last step is a person pressing the key (the live keyboard run,
// 2026-08-10).
func runPickSurfaceChecks() {
    // MARK: - 37g. The panel draws what this file says it draws

    // The layout itself needs a screen, so the wiring is carried by the source: the same lock the
    // height suite uses, for the same reason (a pure rule nobody calls is the defect this feature
    // has been bitten by before).
    let view = (try? String(contentsOfFile: "Tally/Views/PickPanelView.swift", encoding: .utf8)) ?? ""
    check("the panel view is readable from this suite", !view.isEmpty)
    check("the columns are drawn side by side, in the order the palette put them",
          view.contains("HStack(alignment: .top, spacing: pickColumnGap)")
              && view.contains("ForEach(palette.columns, id: \\.kind)"))
    check("…each at its own width, and the panel at the sum of them",
          view.contains("pickColumnWidth(column.kind, alone: alone)")
              && view.contains(".frame(width: pickPanelWidth(palette))"))
    check("each column lists its own rows and pins its own way out",
          view.contains("ForEach(Array(column.items.enumerated())")
              && view.contains("if let sticky = column.sticky"))
    check("…both scrolling at the height the rule above decides, filter or no filter",
          view.contains("pickPanelListHeight(request, filters: queries, measured: listHeights)")
              && view.contains(".frame(height: listHeight)") && !view.contains(".frame(maxHeight:"))
    check("…measured off an EAGER stack, which is the only kind that measures whole",
          view.contains("VStack(spacing: 0)") && !view.contains("LazyVStack"))
    check("each column is typed into on its own",
          view.contains("queries[column.kind]") && view.contains("filters: queries"))
    // WHICH COLUMN IS LISTENING, said on the name at the head of its own box. The outline that used
    // to say it as well is gone with the heading line: a box that is named, filled and ringed says
    // one thing three times, and it was competing with the circles a press acts on.
    check("…and the column being typed into says so, on its own name",
          view.contains("Text(L(pickColumnHeadingKey(column.kind)))")
              && view.contains("isFocused ? AnyShapeStyle(TallyColor.ai)")
              && !view.contains("stroke(TallyColor.ai"))
    check("…and that name is inside the field's own box rather than on a line above it",
          view.contains("PickSearchField(text: query")
              && !view.contains("frame(height: pickColumnHeadingHeight"))
    // The other half of the frozen height: a filtered stack measures only what survived the query,
    // so believing it would resize the panel from underneath.
    check("…and a measurement taken while a column is filtered is not believed",
          view.contains(#"guard !pickIsFiltering(queries[kind] ?? "") else { return }"#))
    // A DETAIL LINE THAT WRAPS IS A ROW THE ARITHMETIC CANNOT SEE, so the row refuses to wrap: a
    // real fleet at 100% across three windows plus a tag did exactly that on the first live run.
    // The row itself lives one file over now (PickRowView.swift), split out when it gained the
    // circle; what the panel owns is the columns around it.
    let rowView = (try? String(contentsOfFile: "Tally/Views/PickRowView.swift",
                               encoding: .utf8)) ?? ""
    check("the row view is readable from this suite", !rowView.isEmpty)
    check("a row's second line is held to one line, which is what the height family assumes",
          rowView.contains(".lineLimit(1)"))
    // THE LINE THE PANEL ADDS, drawn from the item the arithmetic measured rather than decided again
    // here: a model named with no depth says what it leaves alone (`pickPanelNote`), and the two
    // must be the same answer or the row is a line taller than the sum knows about.
    check("a model with no depth is drawn with the line the column gave it",
          view.contains("note: item.note") && rowView.contains("} else if let note {")
              && rowView.contains("Text(L(note))"))
    // AND THE DEPTH IS A CHIP COLOURED BY HOW DEEP IT IS, from the ramp rather than one accent for
    // every level: `high` and `xhigh` were the same purple, so nothing said which of them spends a
    // paid window faster (Albert, 2026-08-10). One table, so the chip on a row and the same word in
    // the bar under the columns cannot come out different colours.
    check("the depth is drawn as a chip in the tags' own capsule",
          rowView.contains("PickEffortChip(effort: effort, lit: isCircled)")
              && rowView.contains("cornerRadius: TallyMetrics.calloutRadius"))
    check("…tinted by where the depth sits on the ramp, not by a colour written on the row",
          rowView.contains(".foregroundStyle(color)")
              && rowView.contains("switch pickEffortHeat(effort)"))
    check("…and the sentence under the columns colours that word from the same table",
          rowView.contains("Text(verbatim: effort).foregroundStyle(pickEffortColor(effort))")
              && rowView.contains("pickChangeParts(pair.element)"))
    // A MODE IS SET APART BY WEIGHT rather than by a sixth hue, in both places the depth is written:
    // `ultracode` runs AT xhigh, so a colour past the deepest depth would rank it as something it is
    // not (`PickEffortHeat.mode`).
    check("…and the mode the CLI does not document is told apart by weight, in both of them",
          rowView.components(separatedBy: ".fontWeight(pickEffortWeight(effort))").count == 3)
    check("a column its filter emptied says that rather than showing a gap",
          view.contains("column.isEmptyOfMatches") && view.contains(#"L("No matches")"#))
    check("every keypress is decided by the rule this file asserts",
          view.contains("pickKeyAction(key, query: queries[kind] ?? \"\")")
              && view.contains("pickColumnFocus(palette, from: kind, step: step)"))
    // TYPING IS THE HANDLER OF LAST RESORT on this path, so everything the named ones declined
    // arrives there wearing whatever character it carries, and an arrow key carries one. Both halves
    // of what stopped it are locked: the press goes through the same rule as every other key (where
    // `pickIsTypable` turns it away), and the sideways keys no longer decline in the first place.
    check("what the named handlers declined is typed through the same rule, not straight in",
          view.contains(".onKeyPress(phases: [.down, .repeat]) { press in typed(press) }")
              && view.contains("return act(.text(press.characters))")
              && !view.contains("edited(press.characters"))
    // A KEYBOARD WITH NOWHERE TO GO IS THE SAME HOLE: the request says which column the keyboard
    // starts in and the sections say which columns exist, and nothing on the wire makes the first
    // one of the second. Refused here, every key on the panel fell through to the typing handler.
    check("a focus naming no column lands on one that is drawn rather than refusing the key",
          view.contains("guard let column = palette.column(focus) ?? palette.columns.first")
              && view.contains("if kind != focus { focus = kind }"))
    check("the pointer moves the keyboard's column with it, once the panel is really up",
          view.contains("focus = column.kind")
              && view.contains("guard pickHoverMovesFocus(shownAt: shownAt) else { return }"))
    // A CLICK CIRCLES, IT DOES NOT ANSWER (pickcirclechecks carries the grammar and the reason):
    // what leaves the panel is every circle at once, so both axes can move on one press.
    check("a chosen row is circled in its own column",
          view.contains(".onTapGesture { selections[column.kind] = index }"))
    // THE DEV TAG, which is why it is on this panel at all: two instances of it can be on one
    // machine, and a build nobody installed must be tellable from the installed one BEFORE a click
    // moves somebody's conversation. Reused from the popover's header rather than drawn again.
    check("a dev build says so on this panel, in the popover's own badge",
          view.contains("if BuildVariant.isDev") && view.contains("TallyDevTagView()"))
    let popover = (try? String(contentsOfFile: "Tally/Views/PopoverHeaderView.swift",
                               encoding: .utf8)) ?? ""
    check("…which is the one the popover wears, rather than a second capsule",
          popover.contains("TallyDevTagView()")
              && !popover.contains(#"Text(verbatim: "DEV")"#))
    let brand = (try? String(contentsOfFile: "Tally/Views/ProviderIconShape.swift",
                             encoding: .utf8)) ?? ""
    check("…and it is one style in one place",
          brand.contains("struct TallyDevTagView"))
    // MARK: - 37g2. The field is a real one, and the words on it are translated

    // WHY THIS IS LOCKED BY SHAPE: an account nickname is whatever somebody typed into Settings, so
    // a fleet can hold names in scripts that have to be COMPOSED, and raw keypresses cannot compose
    // anything. Only a real field has marked text, a caret, paste and a backspace that works, and
    // the last of those is the defect that started this (`PickSearchField`).
    check("each column's filter is a real text field",
          view.contains("PickSearchField(text: query"))
    let field = (try? String(contentsOfFile: "Tally/Views/PickSearchField.swift",
                             encoding: .utf8)) ?? ""
    check("…wrapping AppKit's own, which is what makes an input method work at all",
          field.contains("NSViewRepresentable") && field.contains("NSTextField"))
    // TAB IS ONE OF THESE, and its absence is the defect Albert hit (2026-08-10): a key this list
    // does not name is a key AppKit's own key-view loop takes, so the first responder moved to the
    // other column's field while the panel went on believing the one it had chosen was focused, and
    // the next keystroke was dragged back to it. Both directions, since Shift-Tab is its own
    // selector rather than a modifier on the first.
    for selector in ["moveUp", "moveDown", "moveLeft", "moveRight", "insertNewline",
                     "cancelOperation", "insertTab", "insertBacktab"] {
        check("…handing the panel the keys it answers with: \(selector)",
              field.contains("#selector(NSResponder.\(selector)(_:))"))
    }
    // …and the panel's backstop path answers it too, for the panel whose field never took the
    // responder at all (the dev preview is raised that way).
    check("…and the same key on the path the field never sees",
          view.contains(".onKeyPress(.tab, phases: [.down, .repeat])")
              && view.contains("act(press.modifiers.contains(.shift) ? .backtab : .tab)"))
    // AND NOTHING ELSE, which is the half that fixes backspace: every editing key reaches the field
    // editor untouched, so deleting, composing and pasting are AppKit's rather than ours.
    check("…and taking none of the editing ones, backspace first among them",
          !field.contains("deleteBackward") && !field.contains("deleteForward")
              && field.contains("default: return false"))
    // THE STATE IT WAS JUST GIVEN IS NOT READ BACK: a query written from a callback is not promised
    // to be visible on the next line, and the panel showed it (clearing a filter left the cursor on
    // the first row rather than walking back to the session's own).
    check("the cursor is placed against the column the edit makes, not the one state still holds",
          view.contains("var filters = queries") && view.contains("filters[kind] = typed"))
    check("the caret is placed in the units an NSRange counts, not in what a person calls one",
          field.contains("pickCaretEnd(field.stringValue)")
              && !field.contains("stringValue.count"))
    // A QUERY THE PANEL WROTE COMES BACK SELECTED unless something puts the caret back: setting a
    // field's value selects the whole of it, so the next keystroke replaces the query instead of
    // adding to it. Albert typed "3" and saw the digit highlighted (live, 2026-08-10).
    check("a value written by the panel leaves a caret behind it, not a selection",
          field.contains("field.stringValue = text")
              && field.contains("NSRange(location: pickCaretEnd(text), length: 0)"))
    check("a click in the other column's field moves the panel's focus with it",
          field.contains("controlTextDidBeginEditing") && view.contains("onFocus: { focus ="))
    // THE FIRST RESPONDER IS THE FACT AND THE STATE FOLLOWS IT, one direction only. The correction
    // that puts the keyboard in the focused column runs on the EDGE - the pass where the panel
    // itself moved the focus - and never on the level, or a field that already holds the responder
    // is argued with on every redraw. That argument is the bug: Tab moved the responder, the state
    // still said the other column, and typing pulled the caret back to it (Albert, 2026-08-10).
    check("the keyboard is taken on the pass the panel moved it",
          field.contains("let claimed = isFocused")
              && field.contains("!context.coordinator.heldFocus")
              && field.contains("guard claimed else { return }")
              && !field.contains("guard isFocused else { return }"))
    // AND ON THE LEVEL WHILE NOBODY IS EDITING, which is the case an edge cannot reach: the panel is
    // focusable itself, so on the pass it comes up its own SwiftUI focus and this claim both want
    // the responder, and when the panel wins there is no second edge coming - the state never moved.
    // Every press then goes to the panel's backstop, which is the surface Albert's arrow keys were
    // typed into (2026-08-10). Safe by construction rather than by care: a field holding the
    // responder makes the test below false, which is exactly the property the edge was added for.
    check("…and again whenever the keyboard is in the panel and in no field at all",
          field.contains("|| pickFieldEditorIsIdle(field.window)"))
    check("…which is asked of the window that has the keyboard, and of what holds it there",
          field.contains("guard let window, window.isKeyWindow else { return false }")
              && field.contains("return !(window.firstResponder is NSText)"))
    // The other half of that rule, and the one that cannot be missed: whatever moved the keyboard
    // here - a click, a path this panel does not name - the character typed puts the panel's own
    // record straight, so the arrow keys and Escape act on the column being typed into.
    // Read as the body between the two delegate methods, since the one after it calls `onFocus`
    // too and a scan of the whole file could not tell which of them this is about.
    let onTyping = (field.components(separatedBy: "func controlTextDidChange").last ?? "")
        .components(separatedBy: "func controlTextDidBeginEditing").first ?? ""
    check("…and whichever field is typed into says so, on every keystroke rather than the first",
          onTyping.contains("onFocus()") && onTyping.contains("onEdit(field.stringValue)"))

    // EVERY WORD THIS SURFACE ADDED IS IN THE CATALOGUE, in all four translations: the app ships
    // five languages, and a string that reaches a person in English on a Japanese machine is a
    // missing translation nobody notices until they see it.
    let catalogue = (try? Data(contentsOf: URL(fileURLWithPath:
        "Tally/Resources/Localizable.xcstrings")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let strings = catalogue?["strings"] as? [String: Any] ?? [:]
    check("the string catalogue is readable from this suite", !strings.isEmpty)
    for word in ["Accounts", "Models", "Type to filter", "esc to clear", "No matches", "Filter",
                 "Account", "Model", pickEffortUnchangedKey] {
        let entry = strings[word] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any] ?? [:]
        check("\(word) is translated into every language Tally ships",
              AppLocaleSupported.allSatisfy { localizations[$0] != nil })
    }
    check("…and the panel asks for them through the app's own language rather than the main bundle",
          view.contains("L(pickColumnHeadingKey(column.kind))")
              && view.contains(#"L("Type to filter")"#)
              && view.contains("L(pickPanelKindName(request.kind))"))
    check("the column names the panel draws are the keys the catalogue is written in",
          pickColumnHeadingKey(.account) == "Accounts" && pickColumnHeadingKey(.model) == "Models")

    // …and the answer written from a choice names the column, which is the field the CLI routes on.
    // Pure, so it is asserted rather than read.
    check("the answer a choice becomes names its own section",
          PickChoice(kind: .account, row: PickRow(value: "claude:.claude2", label: "Claude 2"))
              .answer == PickAnswer(value: "claude:.claude2", effort: nil, kind: .account))
    let controller = (try? String(contentsOfFile: "Tally/MenuBar/PickPanelController.swift",
                                  encoding: .utf8)) ?? ""
    check("…and the panel writes exactly what was submitted",
          controller.contains("finish(with: answer ?? .cancelled)"))
    check("a request with rows in any section is drawn rather than refused",
          controller.contains("!request.everyRow.isEmpty"))
    check("the dev preview shows the whole palette, which is what a person actually sees",
          controller.contains("sections: [accounts, models]")
              && controller.contains("sections: [models, accounts]"))
    // …AND THE WHOLE OF THE MODEL LIST, since this fixture is what the panel is captured through: two
    // depths here while the CLI expands the axis (`pickerExpandedEfforts`) would be a picture of a
    // panel nobody sees, and how long that list runs is exactly what a capture is looked at for.
    check("…expanding the same depths the CLI does",
          controller.contains("for effort in claudeEffortNames()"))
}
