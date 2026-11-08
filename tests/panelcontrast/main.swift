import Foundation

// The Detailed panel's text levels on the worst desktop (B-4169 correction batch). The glass panel
// shows the desktop through it, so every level is checked on a dark, a middle and a pale one after
// the panel tint and the card fill are laid over it. Main and secondary words need 4.5:1, the
// tertiary level (words nobody has to read) 3:1.

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

let appearances: [(String, PanelPalette.Appearance)] = [("dark", PanelPalette.dark), ("light", PanelPalette.light)]

print("every level on every desktop")
for (name, mode) in appearances {
    for wall in PanelPalette.wallpapers {
        let l = PanelPalette.levels(mode, wallpaper: wall.hex)
        let tag = "\(name) panel over a \(wall.name) desktop"
        check(l.main >= PanelPalette.minimumMain, "\(tag): main text \(String(format: "%.2f", l.main)) >= 4.5")
        check(l.secondary >= PanelPalette.minimumSecondary,
              "\(tag): secondary text \(String(format: "%.2f", l.secondary)) >= 4.5")
        check(l.tertiary >= PanelPalette.minimumTertiary,
              "\(tag): tertiary text \(String(format: "%.2f", l.tertiary)) >= 3")
    }
}

// THE TEST CAN GO RED: the design draft's own colours (tertiary #6e6e76 / #a2a2a9, glass 0.72 / 0.74)
// are the case this was written against, and they must fail on the worst desktop. If this stopped
// failing, the checks above would be asking nothing.
print("the draft's original colours are caught")
let draftDark = PanelPalette.Appearance(text: 0xF4F4F6, text2: 0xA6A6AE, text3: 0x6E6E76, panelSolid: 0x1E1E22,
                                        glassAlpha: 0.72, cardFill: 0xFFFFFF, cardAlpha: 0.055)
let draftLight = PanelPalette.Appearance(text: 0x1B1B1E, text2: 0x68686F, text3: 0xA2A2A9, panelSolid: 0xF4F4F6,
                                         glassAlpha: 0.74, cardFill: 0xFFFFFF, cardAlpha: 0.72)
let worstDraftDark = PanelPalette.levels(draftDark, wallpaper: 0xE8E8E8)
let worstDraftLight = PanelPalette.levels(draftLight, wallpaper: 0x202020)
check(worstDraftDark.tertiary < PanelPalette.minimumTertiary, "draft tertiary on a pale desktop under the dark panel fails")
check(worstDraftDark.secondary < PanelPalette.minimumSecondary, "draft secondary on a pale desktop under the dark panel fails")
check(worstDraftLight.tertiary < PanelPalette.minimumTertiary, "draft tertiary on a dark desktop under the light panel fails")

// Words somebody has to read never sit on the tertiary token: the reset countdown, the account count,
// the column titles, the ring's caption. Only decoration (the grip, the credit, the version) may.
print("must-read words do not use the tertiary level")
for file in ["Tally/Views/ResetCaption.swift", "Tally/Views/PopoverDetailedLayout.swift",
             "Tally/Views/ProviderCardHeader.swift", "Tally/Views/PoolRingView.swift",
             "Tally/Views/AdvisorCard.swift", "Tally/Views/AccountListRowView.swift",
             "Tally/Views/AccountListRowView+Meters.swift"] {
    let source = read(file)
    check(!source.isEmpty && !source.contains("PanelStyle.text3") && !source.contains(".tertiary"),
          "\(file) draws no word in the tertiary level")
}
let header = read("Tally/Views/PopoverHeaderView.swift")
check(!header.isEmpty && header.contains(".foregroundStyle(PanelStyle.text2)") && !header.contains("foregroundStyle(.tertiary).monospacedDigit"),
      "the refresh countdown is secondary")

// THE NUMBERS THE DELIVERY TEXT QUOTES, one per line as "name=value", every one read from the constant or
// the arithmetic the views are laid out by (never typed here), so a sentence in a hand-off can be checked
// against this output line for line.
print("measures (read from PanelMetrics, PanelGeometry and PanelPalette)")
let columns = 3
let measures: [(String, String)] = [
    ("pool ring diameter (pt)", "\(PanelMetrics.ringSize)"),
    ("account row height (pt)", "\(PanelMetrics.rowHeight)"),
    ("panel width (pt)", "\(PanelGeometry.detailedPanelWidth)"),
    ("gap between cards (pt)", "\(PanelMetrics.cardGap)"),
    ("body side padding (pt)", "\(PanelMetrics.bodyPadH)"),
    ("row side padding (pt)", "\(PanelMetrics.rowPadH)"),
    ("meter cell width, \(columns) windows (pt)", "\(PanelMetrics.meterCellWidth(columns: columns))"),
    ("meter block width, \(columns) windows (pt)", "\(PanelMetrics.meterBlockWidth(columns: columns))"),
    ("account name column width, \(columns) windows (pt)", "\(PanelMetrics.identityColumnWidth(columns: columns))"),
    ("glass tint opacity, dark", "\(PanelPalette.dark.glassAlpha)"),
    ("glass tint opacity, light", "\(PanelPalette.light.glassAlpha)"),
    ("desktop showing through, dark (share)", String(format: "%.2f", 1 - PanelPalette.dark.glassAlpha)),
    ("desktop showing through, light (share)", String(format: "%.2f", 1 - PanelPalette.light.glassAlpha)),
]
for (name, value) in measures { print("  \(name)=\(value)") }
check(PanelMetrics.identityColumnWidth(columns: columns) > 0, "the name column is not empty at \(columns) windows")

if failures > 0 { print("\(failures) assertion(s) failed"); exit(1) }
print("ALL PASS")
