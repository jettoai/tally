import Foundation

// Assertion harness for the panel's provider sections and the fold they can be in
// (Tally/Core/PanelSections.swift), compiled against the real source. Two things are pinned: a
// folded section keeps its heading (that heading is how it is unfolded again), and the fold's two
// entry points - the chevron on the gauge row up in the fleet strip, the section heading down in
// the cards - read and write ONE state.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

struct Account { let id: String; let providerID: String }

// A fleet in the user's own card order: five Claude accounts, three Codex. Both are pooled (2+
// accounts each), so both have a gauge on screen and both may be folded behind it.
let fleet = (1 ... 5).map { Account(id: "claude:\($0)", providerID: "claude") }
    + (1 ... 3).map { Account(id: "codex:\($0)", providerID: "codex") }
let pooled: Set<String> = ["claude", "codex"]

func sections(collapsed: Set<String>) -> [PanelSections.Section<Account>] {
    PanelSections.sections(fleet, providerID: \.providerID, pooled: pooled, collapsed: collapsed)
}

/// Asked by provider rather than by index, and answering nil when the section is not there at all -
/// which is precisely the regression these assertions exist for (a folded section used to be
/// filtered out of the list). Subscripting would trap on it instead of failing by name.
func section(_ providerID: String, collapsed: Set<String>) -> PanelSections.Section<Account>? {
    sections(collapsed: collapsed).first { $0.providerID == providerID }
}

// MARK: - nothing folded

let open = sections(collapsed: [])
check("a section per provider, in first-appearance order",
      open.map(\.providerID) == ["claude", "codex"])
check("each keeps the user's own order inside it",
      section("claude", collapsed: [])?.items.map(\.id) == fleet.prefix(5).map(\.id))
check("and none of them is folded", open.allSatisfy { !$0.isFolded })
check("two providers means the sections carry headings",
      PanelSections.showsHeadings(sectionCount: open.count))

// MARK: - one folded (the screenshot's state: the Codex group collapsed)

let oneFolded = sections(collapsed: ["codex"])
check("a folded section is STILL a section - its heading stays where it was",
      oneFolded.map(\.providerID) == ["claude", "codex"])
check("the folded one is marked folded and the other is not",
      section("codex", collapsed: ["codex"])?.isFolded == true
          && section("claude", collapsed: ["codex"])?.isFolded == false)
check("the folded section still knows how many cards are behind it (the heading's count)",
      section("codex", collapsed: ["codex"])?.items.count == 3)
check("folding one provider does not take the OTHER provider's heading away",
      PanelSections.showsHeadings(sectionCount: oneFolded.count))

// MARK: - everything folded ("gauges only")

let allFolded = sections(collapsed: pooled)
check("gauges-only folds every section without dropping any of them",
      allFolded.count == 2 && allFolded.allSatisfy(\.isFolded))
check("…so the headings are still drawn, which is the whole way back",
      PanelSections.showsHeadings(sectionCount: allFolded.count))

// MARK: - a fold only counts where a gauge summarizes it

check("a collapse recorded for a provider with no pooled gauge folds nothing",
      !PanelSections.isFolded("claude", pooled: [], collapsed: ["claude"]))
check("…and neither does a gauge with no collapse recorded",
      !PanelSections.isFolded("claude", pooled: pooled, collapsed: []))
let unpooled = PanelSections.sections(fleet, providerID: \.providerID,
                                      pooled: ["codex"], collapsed: pooled)
check("so a fleet whose gauge is off keeps every card on screen",
      unpooled.filter(\.isFolded).map(\.providerID) == ["codex"])

// A single provider is given no heading at all, so a fold there leaves nothing behind: the gauge
// chevron is the way back, and it is the only control there ever was.
let lone = PanelSections.sections((1 ... 4).map { Account(id: "claude:\($0)",
                                                          providerID: "claude") },
                                  providerID: \.providerID, pooled: ["claude"],
                                  collapsed: ["claude"])
check("a lone provider's section is folded and headless",
      lone.count == 1 && lone.first?.isFolded == true
          && !PanelSections.showsHeadings(sectionCount: lone.count))

// MARK: - the two entry points move one state

// The chevron's own reading, wherever it is drawn: pointing right means folded.
func chevronPointsRight(_ providerID: String, collapsed: Set<String>) -> Bool {
    collapsed.contains(providerID)
}

var collapsed: Set<String> = []
// 1. A click on the SECTION HEADING down in the cards.
collapsed = PanelSections.toggling("codex", in: collapsed)
check("a click on the section heading folds that section",
      section("codex", collapsed: collapsed)?.isFolded == true)
check("…and the fleet strip's chevron turns in the same instant",
      chevronPointsRight("codex", collapsed: collapsed))
// 2. A click on the FLEET STRIP's chevron, on the state the first click left.
collapsed = PanelSections.toggling("codex", in: collapsed)
check("a click on the gauge chevron unfolds the section the heading folded",
      section("codex", collapsed: collapsed)?.isFolded == false)
check("…and the heading's own chevron turns back with it",
      !chevronPointsRight("codex", collapsed: collapsed))
check("neither entry point disturbs the other provider",
      section("claude", collapsed: collapsed)?.isFolded == false
          && !chevronPointsRight("claude", collapsed: collapsed))
// 3. Two providers folded from either end, in any order, land in one state.
let viaHeadings = PanelSections.toggling("codex", in: PanelSections.toggling("claude", in: []))
let viaChevrons = PanelSections.toggling("claude", in: PanelSections.toggling("codex", in: []))
check("folding both from either entry point, in either order, is the same state",
      viaHeadings == viaChevrons && viaHeadings == pooled)

print(failures == 0 ? "\nAll panel section assertions passed."
                    : "\n\(failures) assertion(s) failed.")
exit(failures == 0 ? 0 : 1)
