import CoreGraphics
import Foundation

// The panel's one-time nudges: when the first hint shows, when the tally-command invite shows, what
// counts as an opening, how a failed install is worded. Pure checks against PanelHints.swift, plus
// source locks for the gates a type check cannot see.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// MARK: what counts as an opening

expect(PanelHints.countsAsOpen(hasAccounts: true, anyReading: true), "an opening with a reading counts")
expect(!PanelHints.countsAsOpen(hasAccounts: true, anyReading: false), "accounts still loading do not count")
expect(!PanelHints.countsAsOpen(hasAccounts: false, anyReading: true), "no accounts do not count")
expect(!PanelHints.countsAsOpen(hasAccounts: false, anyReading: false), "an empty panel does not count")

// MARK: the first hint

expect(PanelHints.showsBubble(seen: false, hasData: true), "the first hint shows on data nobody has explained")
expect(!PanelHints.showsBubble(seen: true, hasData: true), "Got it ends it for good")
expect(!PanelHints.showsBubble(seen: false, hasData: false), "nothing to point at shows no hint")

// MARK: the invite, each entry condition flipped once from an all-true base

func invite(seen: Bool = true, opens: Int = 2, dismissed: Bool = false, absent: Bool = true,
            claude: Bool = true) -> Bool {
    PanelHints.showsInvite(seenAtAppear: seen, opensAtAppear: opens, dismissed: dismissed,
                           commandAbsent: absent, hasClaudeAccount: claude)
}
expect(invite(), "the second opening after the hint was answered invites")
expect(!invite(seen: false), "an unanswered first hint holds the invite back")
expect(!invite(opens: 1), "the first opening never invites")
expect(invite(opens: 9), "later openings still invite")
expect(!invite(dismissed: true), "the cross ends the invite for good")
expect(!invite(absent: false), "a command already on the PATH (link or someone else's file) is not invited")
expect(!invite(claude: false), "the copy is about Claude, so a Codex-only Mac is not invited")
expect(PanelHints.invitePanelOpens == 2, "the invite waits for two openings with data")

// MARK: the two never share a moment

let combos = [true, false].flatMap { seen in [true, false].map { (seen, $0) } }
expect(combos.allSatisfy { seen, hasData in
    // The invite reads `seen` as it was at appear; the bubble reads it live and only while unseen,
    // so for any one `seen` value at most one of them is on.
    !(PanelHints.showsBubble(seen: seen, hasData: hasData)
        && invite(seen: seen, opens: 5, dismissed: false, absent: true, claude: true))
}, "the bubble and the invite are never on together")

// MARK: the preview flags

expect(PanelHints.preview(named: "hint") == .bubble && PanelHints.preview(named: "INVITE") == .invite,
       "the preview flag names the hint or the invite, case-insensitively")
expect(PanelHints.preview(named: nil) == nil && PanelHints.preview(named: "YES") == nil
        && PanelHints.preview(named: "") == nil, "no value, or one that names nothing, holds nothing")
expect(PanelHints.preview(named: "off") == .off && PanelHints.preview(named: "OFF") == .off,
       "the off value holds a panel with neither first-run hint")
expect(TallyCommandScreen.preview(named: "confirm") == .confirm
        && TallyCommandScreen.preview(named: "done") == .done
        && TallyCommandScreen.preview(named: "failed-cancelled") == .failed(.cancelled)
        && TallyCommandScreen.preview(named: "failed") == .failed(.other)
        && TallyCommandScreen.preview(named: "failed-foreign") == .failed(.foreignFile)
        && TallyCommandScreen.preview(named: "failed-unavailable") == .failed(.unavailable),
       "all six window screens can be held")
expect(TallyCommandScreen.preview(named: nil) == nil && TallyCommandScreen.preview(named: "installing") == nil,
       "no value, or the transient screen, holds nothing")

// MARK: the failure wording follows the install's own outcome

let cancelled = "The command line tool was not installed because the administrator password request was cancelled."
func classify(_ message: String?, cancelledMessage: String? = cancelled,
              foreign: Bool = false, unshipped: Bool = false) -> TallyCommandFailure {
    TallyCommandFailure.classify(lastError: message, cancelledMessage: cancelledMessage,
                                 foreignFile: foreign, unshipped: unshipped)
}
expect(classify(cancelled) == .cancelled, "the message the cancelled outcome produces is the cancelled screen")
expect(classify("could not link") == .other, "any other message is the generic failure")
expect(classify(nil) == .other, "no message at all is still a failure, never a silent success")
expect(classify(cancelled, cancelledMessage: nil) == .other, "an outcome that cannot be worded cannot be called a cancel")
expect(classify("could not link", foreign: true) == .foreignFile
        && classify(cancelled, foreign: true) == .foreignFile,
       "a file of somebody else's at the link path is its own failure, whatever the message says")
expect(classify("Integrations are managed by the installed release app.", unshipped: true) == .unavailable
        && classify(nil, foreign: true, unshipped: true) == .unavailable,
       "a build that may not install is its own failure")

// MARK: only two failures may hand out the sudo line

expect(TallyCommandFailure.cancelled.allowsManualCommand && TallyCommandFailure.other.allowsManualCommand,
       "a cancel and a generic failure still offer the line to run in Terminal")
expect(!TallyCommandFailure.foreignFile.allowsManualCommand && !TallyCommandFailure.unavailable.allowsManualCommand,
       "a foreign file and an unshipped build never offer it")
expect(TallyCommandFailure.manualCommandAllowed(foreignFile: false, unshipped: false)
        && !TallyCommandFailure.manualCommandAllowed(foreignFile: true, unshipped: false)
        && !TallyCommandFailure.manualCommandAllowed(foreignFile: false, unshipped: true)
        && !TallyCommandFailure.manualCommandAllowed(foreignFile: true, unshipped: true),
       "the copy action's own check refuses on either reason")

// MARK: gates and orderings a type check cannot see

func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
let bubble = source("Tally/Views/PanelHintBubble.swift")
expect(bubble.contains("private let persists = !DemoUsage.isActive && PanelHintMemory.preview == nil"),
       "demo data and a held preview never write the real defaults")
expect(bubble.contains("guard BuildVariant.isDev || DemoUsage.isActive else { return nil }"),
       "the hint preview flag is read only through the Dev-or-demo gate")
if let snapshot = bubble.range(of: "seenAtAppear = memory.seen"),
   let count = bubble.range(of: "countIfReadable()\n        }") {
    expect(snapshot.lowerBound < count.lowerBound,
           "the appearance reads whether the hint was answered before it counts itself")
} else { expect(false, "the appearance reads whether the hint was answered before it counts itself") }
expect(bubble.contains("arrowAtBottom: shown.placement.above) { memory.markSeen() }")
        && bubble.contains("held == .bubble && !memory.seen")
        && bubble.contains("showsBubble(seen: memory.seen"),
       "the Got it button marks the hint seen, and both the held and the normal path read that")
let root = source("Tally/Views/PopoverRootView.swift")
expect(root.contains("PanelHintsSection(store: store"), "the panel hosts the nudges")
let invite = source("Tally/Views/TallyCommandInviteCard.swift")
expect(!bubble.contains("systemBlue") && !invite.contains("systemBlue") && !invite.contains(".borderedProminent"),
       "neither first-run hint is drawn in the system blue")
expect(!bubble.contains("width - 250 - 126"),
       "the bubble's arrow is placed from a measured meter, not from the panel width")
let rowSource = source("Tally/Views/AccountListRowView.swift"), cardSource = source("Tally/Views/AccountCardView.swift")
expect(rowSource.contains("anchorPreference(key: PanelHintTargetKey.self")
        && cardSource.contains("anchorPreference(key: PanelHintTargetKey.self")
        && root.contains("overlayPreferenceValue(PanelHintTargetKey.self"),
       "both densities report their first meter, and the panel places the bubble from it")
// The bubble is drawn over the whole panel body, after the footer, and asks nobody for room (B-3823):
// the scroll view only reports its visible frame into the same key.
if let footerEnd = root.range(of: "                Divider()\n                footer\n            }"),
   let overlay = root.range(of: "overlayPreferenceValue(PanelHintTargetKey.self"),
   let areaAt = root.range(of: "transformAnchorPreference(key: PanelHintTargetKey.self, value: .bounds)"),
   let scrollFrame = root.range(of: ".frame(width: popoverWidth, alignment: .leading)"),
   let section = root.range(of: "PanelHintsSection(store: store") {
    expect(footerEnd.upperBound < overlay.lowerBound,
           "the bubble's overlay is on the whole panel body, after the footer")
    expect(scrollFrame.upperBound < areaAt.lowerBound && areaAt.lowerBound < section.lowerBound,
           "the scroll area reports its visible frame from the scroll view itself")
} else {
    expect(false, "the bubble's overlay is on the whole panel body, after the footer")
    expect(false, "the scroll area reports its visible frame from the scroll view itself")
}
expect(!root.contains("hintRoom") && !bubble.contains("@Binding var room") && !root.contains("minHeight: hint"),
       "the bubble reports no height to the panel")

// MARK: where the bubble sits in the visible area (B-4112)

let viewport = CGSize(width: 400, height: 300)
func place(_ minY: CGFloat, height: CGFloat = 8, bubble: CGFloat = 140) -> PanelHints.BubblePlacement? {
    PanelHints.bubblePlacement(meter: CGRect(x: 20, y: minY, width: 34, height: height),
                               bubbleHeight: bubble, viewport: viewport, margin: 12)
}
expect(place(40) == PanelHints.BubblePlacement(y: 50, above: false), "room below puts the bubble under the meter")
expect(place(160) == PanelHints.BubblePlacement(y: 160 - 2 - 140, above: true),
       "a meter too low for the bubble flips it above, not past the bottom edge")
expect(place(100, bubble: 280) == PanelHints.BubblePlacement(y: 12, above: false),
       "a bubble that fits on neither side is clamped inside the visible area")
expect(place(-50) == nil && place(300) == nil && place(400) == nil, "a meter scrolled out of view gets no bubble")
expect(place(-4) == PanelHints.BubblePlacement(y: 6, above: false), "a meter half scrolled off still gets one, below it")
expect(place(286) == PanelHints.BubblePlacement(y: 286 - 2 - 140, above: true),
       "a meter at the very bottom of the view flips above it")
expect(place(40, bubble: 400) == PanelHints.BubblePlacement(y: 12, above: false),
       "a bubble taller than the visible area starts at the margin")

// MARK: past the scroll area, over the rest of the panel (B-3823)

func panel(_ minY: CGFloat, bubble: CGFloat = 140, area: CGFloat = 120,
           headroom: CGFloat = 0, overhang: CGFloat = 0) -> PanelHints.BubblePlacement? {
    PanelHints.bubblePlacement(meter: CGRect(x: 20, y: minY, width: 34, height: 8), bubbleHeight: bubble,
                               viewport: CGSize(width: 400, height: area), margin: 12,
                               headroom: headroom, overhang: overhang)
}
expect(panel(40, overhang: 90) == PanelHints.BubblePlacement(y: 50, above: false),
       "a short area with a footer under it keeps the bubble below the meter, not clamped")
expect(panel(40) == PanelHints.BubblePlacement(y: 12, above: false),
       "without that room the same meter is clamped, so the room is what moved it")
expect(panel(40, overhang: 82) == PanelHints.BubblePlacement(y: 50, above: false),
       "a bubble that exactly reaches the panel's bottom margin still goes below")
expect(panel(40, headroom: 120, overhang: 30) == PanelHints.BubblePlacement(y: -102, above: true),
       "no room below even over the footer flips the bubble above, over the header")
expect(panel(40, headroom: 20, overhang: 30) == PanelHints.BubblePlacement(y: -2, above: false),
       "a bubble that fits neither side is clamped inside the whole panel, button and all")
expect(panel(40, area: 100, headroom: 10, overhang: 10) == PanelHints.BubblePlacement(y: 2, above: false),
       "a panel shorter than the bubble starts it at the panel's top margin")
expect(panel(-50, headroom: 120, overhang: 90) == nil && panel(120, headroom: 120, overhang: 90) == nil,
       "a meter outside the scroll area gets no bubble, however much panel is around it")

if let scrollEnd = root.range(of: "accountPoolTitle"),
   let section = root.range(of: "PanelHintsSection(store: store") {
    let after = root[section.upperBound...]
    expect(scrollEnd.upperBound < section.lowerBound
            && after.prefix(200).contains(".fixedSize(horizontal: false, vertical: true)")
            && !root.contains("PanelHintsSection(store: store, width:"),
           "the invite is held under the scroll view at its own height, so a capped panel cannot scroll it away")
} else { expect(false, "the invite is held under the scroll view at its own height, so a capped panel cannot scroll it away") }
let controller = source("Tally/MenuBar/TallyCommandWindowController.swift")
expect(controller.contains("BuildVariant.isDev || DemoUsage.isActive")
        && controller.components(separatedBy: "flagsHonoured").count >= 3,
       "the command window's preview flag is read only through the Dev-or-demo gate")
let store = source("Tally/Stores/TallyCommandStore.swift")
expect(store.contains("IntegrationsStore.cliInstallMessage(.cancelled"),
       "the cancelled screen is decided against the install's own cancelled message")
expect(store.contains("guard preview == nil"), "a held preview touches no clipboard and no Terminal")
if let manual = store.range(of: "func copyManualInstallAndOpenTerminal()"),
   let guardAt = store.range(of: "guard TallyCommandFailure.manualCommandAllowed(foreignFile: IntegrationsStore.detectCLIToolPresence() == .foreignFile,\n                                                       unshipped: BuildVariant.isUnshipped)"),
   let copyAt = store.range(of: "Self.copy(IntegrationsStore.manualInstallCommand") {
    expect(manual.lowerBound < guardAt.lowerBound && guardAt.lowerBound < copyAt.lowerBound,
           "the manual line re-asks the disk and the build before it reaches the clipboard")
} else { expect(false, "the manual line re-asks the disk and the build before it reaches the clipboard") }

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
