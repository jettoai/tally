import Foundation

// THE CARD'S OWN EDGE (Tally/Views/SessionCardView.swift, Tally/Views/TallyVisualStyle.swift): the
// one thing a session card says that is found by sweeping a board rather than by reading it.
//
// Read off the source, like every other check in this family that is about a SwiftUI surface: the
// modifier under test is a view modifier on a card this harness has no target to construct. What
// can be pinned from here is the whole of what the rule is - which state gets an edge, that no
// other card in the app asks for one, that the channels the edge was added BESIDE are still there,
// and that the one modifier every card goes through still draws the plain hairline for everybody.

func runSessionCardEdgeChecks() {
    let card = (try? String(contentsOfFile: "Tally/Views/SessionCardView.swift",
                            encoding: .utf8)) ?? ""
    let style = (try? String(contentsOfFile: "Tally/Views/TallyVisualStyle.swift",
                             encoding: .utf8)) ?? ""
    check("the two sources this suite reads are readable from it", !card.isEmpty && !style.isEmpty)
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
          cardCode.contains("private var sessionIsWaiting: Bool { row.state == .blocked }"))
    // THE ONE CALL SITE IN THE WHOLE APP, which is what makes the edge mean one thing. A second
    // accented card anywhere would put the reader back to reading edges to find out what this one
    // is about, which is exactly the cost the edge was spent to avoid. Counted over every surface
    // that draws a card, so a new accent cannot arrive somewhere this list is not looking.
    for (source, expected) in [("Tally/Views/SessionCardView.swift", 1),
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
    check("…and the state word and the reason line are still said in it",
          cardCode.components(separatedBy: ".foregroundStyle(TallyColor.critical)").count - 1 == 2)

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
