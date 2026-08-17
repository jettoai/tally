import Foundation

// HOW A CARD SAYS IT IS WAITING FOR SOMEBODY (Tally/Views/SessionCardView.swift,
// Tally/Views/SessionCardState.swift, Tally/Views/TallyVisualStyle.swift), which is four channels
// and used to be five: the dot's colour, the word, the age ticking beside it, and the card's own
// red edge - the one thing here found by sweeping a board rather than by reading it. The fifth was
// a red line of the hook's own sentence, clipped to the card's width; it became a hover of the word
// (Albert, 2026-08-17), which is the only hover this board answers.
//
// Read off the source, like every other check in this family that is about a SwiftUI surface: the
// modifier under test is a view modifier on a card this harness has no target to construct. What
// can be pinned from here is the whole of what the rule is - which state gets an edge, that no
// other card in the app asks for one, that the channels the edge was added BESIDE are still there,
// and that the one modifier every card goes through still draws the plain hairline for everybody.

func runSessionCardEdgeChecks() {
    // Both halves of the card, read as one: the edge is asked for where the card is assembled and
    // the three channels inside it are drawn one file over (`SessionCardState.swift`).
    let card = ["Tally/Views/SessionCardView.swift", "Tally/Views/SessionCardState.swift"]
        .map { (try? String(contentsOfFile: $0, encoding: .utf8)) ?? "" }
        .joined(separator: "\n")
    let style = (try? String(contentsOfFile: "Tally/Views/TallyVisualStyle.swift",
                             encoding: .utf8)) ?? ""
    check("the sources this suite reads are readable from it", !card.isEmpty && !style.isEmpty)
    // Asked of the CODE rather than of the file: both of these explain in prose why the edge is
    // rationed, and an assertion that cannot tell a comment from a modifier would be green for the
    // sentence and red for nothing (the same treatment the grip checks give this file).
    func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
    let cardCode = code(card), styleCode = code(style)

    // ONE CONDITION WEARS THE EDGE, and it is the state where a PERSON is what the session is
    // waiting for. The board is read by sweeping down it for that card, and every other channel the
    // wait is on lives INSIDE the card, where it has to be found card by card.
    check("the blocked card asks the card modifier for an edge in the state colour",
          cardCode.contains(".tallyCard(accent: sessionIsWaiting ? TallyColor.critical : nil)"))
    check("…on the same question the rest of that card's blocked-only fields are written on",
          cardCode.contains("var sessionIsWaiting: Bool { row.state == .blocked }"))
    // THE ONE CALL SITE IN THE WHOLE APP, which is what makes the edge mean one thing. A second
    // accented card anywhere would put the reader back to reading edges to find out what this one
    // is about, which is exactly the cost the edge was spent to avoid. Counted over every surface
    // that draws a card, so a new accent cannot arrive somewhere this list is not looking.
    for (source, expected) in [("Tally/Views/SessionCardView.swift", 1),
                               ("Tally/Views/SessionCardState.swift", 0),
                               ("Tally/Views/AccountCardView.swift", 0),
                               ("Tally/Views/PopoverCardGrid.swift", 0),
                               ("Tally/Views/CardReorder.swift", 0),
                               ("Tally/Views/TokenStatsView.swift", 0)] {
        let text = (try? String(contentsOfFile: source, encoding: .utf8)) ?? ""
        check("\(source) is readable from this suite", !text.isEmpty)
        check("…and asks for an accented card \(expected) time(s)",
              code(text).components(separatedBy: "tallyCard(accent:").count - 1 == expected)
    }
    // ADDED, NEVER SUBSTITUTED. Colour is not a channel for a reader who cannot separate this red
    // from the greys around it, so the shape and the words the wait was already said in stay
    // exactly as they were: the dot, the state word, and the reason line.
    check("the blocked dot is still filled in the same red",
          cardCode.contains("case .blocked:")
              && cardCode.contains("Circle().fill(TallyColor.critical).frame(width: size,"
                                   + " height: size)"))
    // AND THE RED TEXT IS NOW THE STATE WORD ALONE. It was the word AND the reason line, and this
    // count is what says the line went rather than merely stopped being reachable: a branch left
    // standing behind a condition nobody satisfies is the shape a removal usually leaves behind.
    check("…and the one red sentence left on the card is the state word",
          cardCode.components(separatedBy: ".foregroundStyle(TallyColor.critical)").count - 1 == 1
              && cardCode.contains("Text(L(row.state.rawValue)).font(.caption2)"))
    // THE REASON IS NEVER DRAWN NOW, and it is counted rather than banned outright: the sentence
    // still becomes a `Text` once, inside the accessibility value the listener reads
    // (`SessionWaitSpoken`), so "this file never says Text(reason)" would be asserting the wrong
    // thing after the a11y correction. A second one is a line back on the card.
    check("…the reason becoming a Text exactly once, and not on the card's face",
          cardCode.components(separatedBy: "Text(reason)").count - 1 == 1
              && !cardCode.contains("sessionIsWaiting, let reason"))
    // THE LAST SLOT IS WHAT THE REASON GAVE BACK: every card, waiting or not, now spends it on the
    // figures, and the only thing that still takes it is a card that knows nothing yet.
    check("…and the card's last line is the figures on every card that has any",
          cardCode.contains("if sessionIsLoading {") && cardCode.contains("sessionStats"))

    // THE SENTENCE ITSELF MOVED TO A HOVER OF THE WORD IT QUALIFIES, which is the one place it can
    // be said whole: it is written by a hook and can be any length, and the line it had was a 236pt
    // column with an ellipsis on the end.
    check("the reason is the state word's callout, and only when there is one",
          cardCode.contains("if let reason = sessionReason { word.tallyTooltip(reason) } else"
                            + " { word }"))
    check("…read off the same guarded question as before, so a stale sentence cannot stand",
          cardCode.contains("guard sessionIsWaiting,")
              && cardCode.contains("let reason = row.reason?.trimmingCharacters("))
    // A HOVER IS INVISIBLE TO A SCREEN READER, and the callout's own accessibility hint does NOT
    // cover for it here. What stood in this place asserted that hint on both of the modifier's
    // paths, which is true of the modifier and says nothing about this card: the target it wraps is
    // a `Text` inside a `Button`, and a card is ONE accessibility element - a child's label composes
    // into the button's own, a child's hint composes into nothing. The assertion was measuring a
    // tree the card does not have (codex review of 22e9dcd), which is the same defect as a mutation
    // that survives because the assertion never passed through the mutated layer.
    //
    // SO THE LISTENER'S COPY IS ON THE BUTTON, and that is what is asserted: its VALUE, because the
    // element's one hint is already spent on what a click does and a second hint replaces rather
    // than joins it. Read off the same property the callout uses, so there is one sentence.
    check("the reason is spoken on the card's own element, not on a child of it",
          cardCode.contains(".modifier(SessionWaitSpoken(reason: sessionReason))"))
    check("…as the element's value, the hint being spent on what a click does",
          cardCode.contains("content.accessibilityValue(Text(reason))")
              && cardCode.contains(
                  ".accessibilityHint(Text(L(\"Click to bring its terminal to the front\")))"))
    check("…and only on a card that is waiting and named a reason",
          cardCode.contains("if let reason { content.accessibilityValue(Text(reason)) } else"
                            + " { content }"))
    // ONE SENTENCE, TWO CHANNELS: the pointer's callout and the listener's value take the same
    // property, so a wait cannot be explained to one of them and not the other.
    check("…both channels reading the one property",
          cardCode.components(separatedBy: "sessionReason").count - 1 >= 3)
    // AND THE MODIFIER IS APPLIED TO THE BUTTON RATHER THAN INSIDE ITS LABEL, which is the whole
    // point of the correction: inside, it would be an attribute of a node nothing can land on.
    let labelEnd = cardCode.range(of: "}\n        .buttonStyle(.plain)")
    let spoken = cardCode.range(of: ".modifier(SessionWaitSpoken(reason: sessionReason))")
    check("…applied outside the button's label, where the element actually is",
          (labelEnd.flatMap { end in spoken.map { end.upperBound < $0.lowerBound } }) == true)
    // AND THE BOARD HOSTS A LAYER, so the card's one callout is Tally's own chip rather than the
    // NSToolTip the fallback would otherwise draw over the panel's glass. All three surfaces that
    // draw a session card are this one root (`MainWindowController`, `PinnedPanelController`,
    // `StatusItemController`), so one layer covers them.
    check("every surface that draws a session card hosts the callout layer",
          ((try? String(contentsOfFile: "Tally/Views/PopoverRootView.swift", encoding: .utf8)) ?? "")
              .contains(".tallyTooltipLayer(suppressed: cardLift != nil || sessionLift != nil)"))

    // WHAT THE MODIFIER DOES WITH IT. One edge is drawn rather than a colour laid over a hairline,
    // and the accent survives the glass path, where the plain hairline is deliberately dropped: the
    // system's rim already says where a card is, and no rim says which card is asking for somebody.
    check("a card with no accent still draws the neutral hairline it always did",
          styleCode.contains("shape.strokeBorder(Color.primary.opacity(0.08),"
                             + " lineWidth: TallyMetrics.hairline)"))
    check("…and an accented one draws its accent instead of that, not as well as it",
          styleCode.contains("if accent != nil {\n            accentEdge\n        } else {"))
    check("…thicker than the hairline, because a mark is not a boundary",
          TallyCardEdge.accentWidth > TallyCardEdge.hairline)
    check("…and held back from full strength, because a border is a long mark",
          TallyCardEdge.accentOpacity > 0 && TallyCardEdge.accentOpacity < 1)
    check("the glass surface keeps the accent although it drops the hairline",
          styleCode.contains("content.glassEffect(.regular, in: shape).overlay(accentEdge)"))
    check("…and the default is still no accent, so every other card is untouched",
          styleCode.contains("func tallyCard(accent: Color? = nil) -> some View"))
}

/// The three numbers the card's edges are drawn with, read out of the source because two of them
/// are private to a view modifier this suite has no target to construct.
///
/// READ RATHER THAN COPIED, which is the difference between an assertion about the code and an
/// assertion about a number somebody typed twice: a value edited in the source is the value these
/// checks are then asserting about, and a value that stops being findable reads as `nan`, which
/// fails every comparison below rather than passing one.
enum TallyCardEdge {
    static let accentWidth = number("accentWidth")
    static let accentOpacity = number("accentOpacity")
    static let hairline = number("hairline")

    private static func number(_ name: String) -> Double {
        let source = (try? String(contentsOfFile: "Tally/Views/TallyVisualStyle.swift",
                                  encoding: .utf8)) ?? ""
        guard let mark = ["let \(name): CGFloat = ", "let \(name): Double = "]
            .compactMap({ source.range(of: $0) }).first
        else { return .nan }
        return Double(source[mark.upperBound...].prefix { $0.isNumber || $0 == "." }) ?? .nan
    }
}
