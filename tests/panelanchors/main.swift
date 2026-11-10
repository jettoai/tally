import Foundation

// The Detailed panel's interaction wiring, counted against main at ee65eda1 (B-4169). The panel is
// re-skinned (colours, sizes, glass, card surface) and none of that may add, drop or move a hit
// area, a gesture, a tooltip or an animation. Each wiring token below is counted per file; the count
// must equal the one recorded from ee65eda1. A skin change that leaves these numbers alone cannot
// have touched the wiring; a number that has to move means an interaction changed, and the change
// belongs in the commit message, not in a quiet edit of this table.
//
// Counts are of the token as plain text (comments included), so a re-skin that rewrites a comment
// near a token is fine as long as the token text itself stays.

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

func occurrences(of token: String, in text: String) -> Int {
    text.components(separatedBy: token).count - 1
}

let tokens = [
    ".windowDragOrTap(",
    ".windowDragSurface()",
    ".onTapGesture(",
    ".onHover",
    ".contextMenu",
    ".tallyTooltip",
    ".help(",
    ".contentShape(",
    ".highPriorityGesture(",
    "DragGesture(",
    ".animation(",
    "withAnimation(",
    ".transition(",
    ".popover(",
    "Button(",
    "Button {",
    ".accessibilityLabel(",
    ".accessibilityAddTraits(",
    ".allowsHitTesting(false)",
    "TimelineView(",
    "DragOrTapArea",
    "PointerIntent"
]

// file -> (token, count) for every token the file contains at ee65eda1; a token not listed is 0.
let baseline: [(String, [(String, Int)])] = [
    ("Tally/Views/ProviderCardHeader.swift", [(".windowDragOrTap(", 4), (".onTapGesture(", 5), (".tallyTooltip", 2), (".contentShape(", 5), (".accessibilityLabel(", 1), (".accessibilityAddTraits(", 1), ("TimelineView(", 1)]),
    ("Tally/Views/AdvisorStripView.swift", [(".tallyTooltip", 1), (".accessibilityLabel(", 1)]),
    ("Tally/Views/FleetStripView.swift", [(".tallyTooltip", 4), ("TimelineView(", 1)]),
    ("Tally/Views/PopoverLaunchViews.swift", [(".tallyTooltip", 1), (".contentShape(", 1), ("Button {", 1)]),
    ("Tally/Views/PopoverDetailedLayout.swift", [(".contentShape(", 1)]),
    ("Tally/Views/PopoverRootView.swift", [(".tallyTooltip", 1), (".highPriorityGesture(", 1), (".animation(", 2), (".transition(", 3)]),
    ("Tally/Views/PopoverCardGrid.swift", [(".contentShape(", 1), ("DragGesture(", 1), ("withAnimation(", 1)]),
    ("Tally/Views/AccountListRowView.swift", [(".onHover", 1), (".contextMenu", 1), (".tallyTooltip", 7), (".contentShape(", 3), ("Button(", 2), ("Button {", 2), (".accessibilityLabel(", 5), (".allowsHitTesting(false)", 1)]),
    ("Tally/Views/AccountListRowView+Meters.swift", [(".tallyTooltip", 1), (".accessibilityLabel(", 1)]),
    ("Tally/Views/AccountListRowView+Controls.swift", [(".tallyTooltip", 3), ("Button {", 1), (".accessibilityLabel(", 3)]),
    ("Tally/Views/AccountListRowView+Tails.swift", [(".tallyTooltip", 2), ("Button(", 1)]),
    ("Tally/Views/ResetCaption.swift", [(".tallyTooltip", 1), ("TimelineView(", 2)]),
    ("Tally/Views/PopoverHeaderView.swift", [(".windowDragSurface()", 4), (".tallyTooltip", 2), (".contentShape(", 1), ("Button {", 2), (".accessibilityLabel(", 1), ("TimelineView(", 1)]),
    ("Tally/Views/NeutralSegmentedPicker.swift", [(".windowDragOrTap(", 1), (".onHover", 1), (".contentShape(", 1), ("Button {", 1), (".accessibilityLabel(", 1), (".accessibilityAddTraits(", 1), ("DragOrTapArea", 1)]),
    ("Tally/Views/PanelGrip.swift", [(".windowDragSurface()", 1), (".contentShape(", 1)]),
    ("Tally/Views/PopoverFooterView.swift", [(".tallyTooltip", 10), (".contentShape(", 6), (".popover(", 2), ("Button {", 6), (".allowsHitTesting(false)", 1)]),
    ("Tally/Views/PinnedCompactView.swift", [(".windowDragSurface()", 2), (".onHover", 1), (".help(", 1), (".allowsHitTesting(false)", 1), ("TimelineView(", 1)]),
    ("Tally/Views/PoolRingView.swift", [(".accessibilityLabel(", 1)]),
    ("Tally/Views/PanelStyle.swift", []),
    ("Tally/Views/AdvisorCard.swift", []),
    ("Tally/MenuBar/PinnedPanelController.swift", [("DragOrTapArea", 5), ("PointerIntent", 2)]),
    ("Tally/MenuBar/StatusItemController.swift", [("Button(", 3)]),
    ("Tally/MenuBar/MainWindowController.swift", [])
]

// Files the skin adds. They draw only; no gesture, no tooltip, no animation, no hit area of their
// own (the one allowed token is `.allowsHitTesting(false)`, which switches a layer's hits OFF).
let skinFiles = ["Tally/Views/PanelSkin.swift"]

print("wiring counts per file against ee65eda1")
for (path, rows) in baseline {
    let source = read(path)
    check(!source.isEmpty, "\(path) is readable")
    var drift: [String] = []
    for token in tokens {
        let want = rows.first(where: { $0.0 == token })?.1 ?? 0
        let got = occurrences(of: token, in: source)
        if got != want { drift.append("\(token) want \(want) got \(got)") }
    }
    check(drift.isEmpty, "\(path): \(drift.isEmpty ? "\(tokens.count) tokens unchanged" : drift.joined(separator: "; "))")
}

print("files the skin adds carry no wiring")
for path in skinFiles {
    let source = read(path)
    var found: [String] = []
    for token in tokens where token != ".allowsHitTesting(false)" {
        let n = occurrences(of: token, in: source)
        if n > 0 { found.append("\(token) x\(n)") }
    }
    check(found.isEmpty, "\(path): \(found.isEmpty ? "no gesture, tooltip, animation or hit area" : found.joined(separator: "; "))")
}

if failures > 0 { print("\(failures) assertion(s) failed"); exit(1) }
print("ALL PASS")
