import Foundation

// Render-path waste the panel and the menu bar used to pay on every redraw (Sentry TALLY-7Z,
// TALLY-82, TALLY-37, TALLY-23). Source text, because these are SwiftUI bodies and AppKit wiring
// this suite does not compile: each check names the shape the fix took, so the per-redraw call
// cannot come back unnoticed.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}
func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

let grid = source("Tally/Views/PopoverCardGrid.swift")
let row = source("Tally/Views/AccountListRowView.swift")
let fleet = source("Tally/Views/FleetStripView.swift")
let controller = source("Tally/MenuBar/StatusItemController.swift")
let button = source("Tally/MenuBar/StatusItemButton.swift")
let advisor = source("Tally/Views/AdvisorStripView.swift")
check("the sources this suite reads are readable",
      ![grid, row, fleet, controller, button, advisor].contains(where: \.isEmpty))

// TALLY-7Z: the list asks the auto pick once per provider and hands each row its answer.
check("7Z the list computes the pick once per provider",
      grid.contains("compactMap { AccountFacts.autoPickID(providerID: $0) }")
          && grid.contains("isAutoPick: autoPicks.contains(usage.id)"))
check("7Z the row uses the answer it is handed", row.contains("isAutoPick ?? facts.isAutoPick"))

// TALLY-82: the fleet callout's blocks are built on hover, not on every body.
check("82 no fleet target builds its blocks eagerly", !fleet.contains("tallyTooltip(blocks: fleetTooltipBlocks"))
check("82 the fleet rows build them lazily",
      fleet.components(separatedBy: "tallyTooltip(lazyBlocks: { fleetTooltipBlocks([summary]) }").count == 2)

// TALLY-23: the advisor row's callout text is built on hover, not on every body.
check("23 the advisor tag builds its callout lazily",
      !advisor.contains(".tallyTooltip(advisorTooltip(")
          && !advisor.contains(".tallyTooltip(blocks: advisorTooltip(")
          && advisor.contains(".tallyTooltip(lazyBlocks: { advisorTooltip(state) })"))

// TALLY-37: the refresh job's tail queues the strip for the next run-loop turn.
check("37 the refresh hook queues the redraw",
      controller.contains("UsageStore.shared.onChange = { [weak self] in self?.updateButtonSoon() }"))
check("37 the queued redraw runs on the next turn, coalesced",
      button.contains("guard !Self.buttonUpdateQueued else { return }")
          && button.contains("DispatchQueue.main.async { [weak self] in"))

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
