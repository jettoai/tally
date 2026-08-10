import Foundation

// WHAT ONE ROW OF THE PICK PALETTE SAYS ABOUT ITSELF before anybody clicks it: the line the panel
// adds under a model named with no depth, and where a depth sits on the ramp the chip colours it
// by. Split from pickpalettechecks.swift the way that file was split from pickerchecks, and for the
// same reason: this is one decision of its own, with its own two incidents behind it.
//
// BOTH ARE THINGS ALBERT COULD NOT READ OFF THE PANEL (2026-08-10). A row saying "fable" and nothing
// else is the grammar's third state - change the model, leave the depth alone - and it explained
// itself nowhere. And the two depths the list drew were the same accent purple, so nothing said
// which of them spends a paid window faster; the whole axis is drawn now
// (`pickerExpandedEfforts`), which is what makes the ramp load-bearing rather than decorative.
//
// The honest limit, recorded rather than glossed: these are the rules the drawing reads. That the
// drawing really reads them is a source scan (picksurfacechecks), and that a person can tell the
// colours apart is a person looking at it.
func runPickRowChecks() {
    // MARK: - 37h. What a row says about itself before anybody clicks it

    // A MODEL NAMED WITH NO DEPTH IS THE THIRD STATE OF THE GRAMMAR - change what answers, leave the
    // depth alone - and it explained itself nowhere on the panel (Albert, 2026-08-10). The line is
    // the panel's rather than the wire's, because the other surface for these rows is a form with
    // one field per axis and no room for a sentence (`pickPanelNote`).
    let bare = PickRow(value: "opus", label: "opus")
    check("a model with no depth is told to say what it leaves alone",
          pickPanelNote(bare, kind: .model) == pickEffortUnchangedKey)
    check("…and a model that names its depth says it in the chip, so it needs no line",
          pickPanelNote(PickRow(value: "opus", effort: "high", label: "opus · high"),
                        kind: .model) == nil)
    check("…nor does a row that arrived with a second line of its own",
          pickPanelNote(PickRow(value: "c", label: "Claude", detail: "fable 54%"), kind: .model)
              == nil
              && pickPanelNote(PickRow(value: "a", label: pickAutoLabel), kind: .model) == nil)
    // THE OTHER COLUMN NEVER GETS ONE: an account row carries no depth to leave alone, so the same
    // sentence there would be a promise about an axis it does not touch.
    check("an account is never given a line about a depth",
          pickPanelNote(PickRow(value: "c", label: "Claude"), kind: .account) == nil)
    // The line is what makes the row two lines tall, and the column is where the two agree: the item
    // the panel draws and the item the arithmetic sums are the same item.
    let noted = pickColumn(PickSection(kind: .model, rows: [bare, bare])).items
    check("a row given that line is measured as the two-line row it is drawn as",
          noted.first?.note == pickEffortUnchangedKey
              && noted.first?.height == pickDetailRowHeight)
    // AND NEVER ON THE WAY OUT, which is the one model row that does not leave the depth alone: it
    // hands both axes back (`pickAutoLabel`).
    let released = pickColumn(PickSection(kind: .model, rows: [bare, PickRow(value: "auto",
                                                                            label: "auto")]))
    check("the row that hands the axis back is given no such line",
          released.sticky?.note == nil && released.sticky?.height == pickPlainRowHeight)

    // HOW DEEP A DEPTH IS, which is what colours it: `high` and `xhigh` were one accent purple, so
    // the panel said nothing about which of the two spends a paid window faster.
    check("the ordinary depth is the middle of the ramp",
          pickEffortHeat("high") == .standard && pickStandardEffort == "high")
    check("…anything below it is the shallow end",
          pickEffortHeat("low") == .shallow && pickEffortHeat("medium") == .shallow)
    check("…past it is deep, and the last documented level is the deepest of them",
          pickEffortHeat("xhigh") == .deep && pickEffortHeat("max") == .deepest
              && claudeEffortFallbackLevels.last == "max")
    // A MODE IS NOT A RUNG. `ultracode` runs AT xhigh and orchestrates besides
    // (`claudeUndocumentedEffortAliases`), so it is set apart from the depths rather than ranked
    // past the deepest of them - by weight on the chip, at that depth's own colour.
    check("the undocumented mode is a band of its own, not a rung past the deepest",
          pickEffortHeat("ultracode") == .mode && pickEffortHeat("ultracode") != .deepest)
    // TAKEN FROM THE AXIS'S OWN LISTS rather than a table written beside the colours: a level the
    // installed CLI's help gains lands on the right side of `high` without anybody placing it.
    check("the ramp reads the axis's own enumeration, in its order",
          claudeEffortFallbackLevels.firstIndex(of: pickStandardEffort).map { standard in
              claudeEffortFallbackLevels.indices.allSatisfy { index in
                  let expected: PickEffortHeat = index < standard ? .shallow
                      : index == standard ? .standard
                      : index == claudeEffortFallbackLevels.count - 1 ? .deepest : .deep
                  return pickEffortHeat(claudeEffortFallbackLevels[index]) == expected
              }
          } == true)
    check("…and every level the picker draws has a band, so no chip is drawn unranked",
          claudeEffortNames().allSatisfy { pickEffortHeat($0) != .standard || $0 == "high" })
    // A value nobody has heard of is drawn as ordinary rather than as a warning about a depth we
    // cannot rank, and a row with no depth has nothing to colour at all.
    check("an unrecognised depth is drawn as the ordinary one",
          pickEffortHeat("gpt-ish") == .standard && pickEffortHeat(nil) == .standard)
    check("a depth is matched however it was capitalised", pickEffortHeat("XHigh") == .deep)

    // The bar under the columns says the same words as the rows, and now in the same colours: the
    // sentence is JOINED from the pieces it is drawn from, so the two cannot drift apart.
    let change = PickChoice(kind: .model, row: PickRow(value: "opus", effort: "xhigh",
                                                       label: "opus · xhigh"))
    check("the pieces the bar draws are the words the sentence is made of",
          pickChangeParts(change) == ("opus", "xhigh")
              && pickChangeSummary(change) == "opus xhigh"
              && pickPendingSummary([change]) == pickPendingLead + "opus xhigh")
}
