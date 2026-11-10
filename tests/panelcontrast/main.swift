import AppKit
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

// ---------------------------------------------------------------------------------------------
// THE SKIN (B-4169, Opus draft): every element of the re-skinned panel on every desktop the glass
// can sit over, at every gradient stop, with and without each colour halo at its peak. The glass is
// laid at 0.93 (dark) / 0.91 (light) over a FLAT desktop colour; a blurred pattern only lands between
// the two extremes (pure white and pure black are both in the list), so the flat worst case bounds it.
// Words need 4.5:1, marks and decoration 3:1.
// ---------------------------------------------------------------------------------------------
typealias Background = (PanelPalette.Appearance, UInt32, Int, Int?) -> PanelPalette.RGB

let onPanel: Background = { PanelPalette.skinPanel($0, wallpaper: $1, stop: $2, halo: $3) }
let onCard: Background = { PanelPalette.skinCard($0, wallpaper: $1, stop: $2, halo: $3) }
let onFooter: Background = { PanelPalette.skinFooter($0, wallpaper: $1, stop: $2, halo: $3) }
func laid(_ base: @escaping Background, _ tone: @escaping (PanelPalette.Skin) -> PanelPalette.Tone) -> Background {
    { mode, wall, stop, halo in PanelPalette.over(tone(mode.skin), base(mode, wall, stop, halo)) }
}

struct Element {
    /// The draft's own group name where it has one (its reading is printed beside ours).
    let name: String
    let ink: (PanelPalette.Appearance) -> UInt32
    let backgrounds: [Background]
    let minimum: Double
}

let words = 4.5, marks = 3.0
let hotCard = laid(onCard) { $0.hotRow }
let underBar = laid(onCard) { $0.track }
func pillOnCard(_ pill: @escaping (PanelPalette.Skin) -> PanelPalette.Pill) -> Background {
    { mode, wall, stop, halo in
        PanelPalette.over(pill(mode.skin).fill, onCard(mode, wall, stop, halo))
    }
}
func pillOnPanel(_ pill: @escaping (PanelPalette.Skin) -> PanelPalette.Pill) -> Background {
    { mode, wall, stop, halo in
        PanelPalette.over(pill(mode.skin).fill, onPanel(mode, wall, stop, halo))
    }
}
let chipOnPanel = laid(onPanel) { $0.chip }
let chipOnFooter = laid(onFooter) { $0.chip }
let thumb = laid(laid(onPanel) { $0.seg }) { $0.segOn }

func gradientEnds(_ name: String, _ get: @escaping (PanelPalette.Skin) -> PanelPalette.Gradient) -> [Element] {
    [Element(name: name, ink: { get($0.skin).from }, backgrounds: [onCard, underBar], minimum: marks),
     Element(name: name, ink: { get($0.skin).to }, backgrounds: [onCard, underBar], minimum: marks)]
}

let elements: [Element] = [
    Element(name: "Violet pill", ink: { $0.skin.violetPill.ink }, backgrounds: [pillOnPanel { $0.violetPill }], minimum: words),
    Element(name: "Tab, selected", ink: { $0.skin.segOnText }, backgrounds: [thumb], minimum: words),
    Element(name: "Tab, not selected", ink: { $0.skin.segText }, backgrounds: [laid(onPanel) { $0.seg }], minimum: words),
    Element(name: "Refresh countdown 56s", ink: { $0.text2 }, backgrounds: [onPanel], minimum: words),
    Element(name: "Ring number", ink: { $0.text }, backgrounds: [onCard], minimum: words),
    Element(name: "Ring label LEFT", ink: { $0.text2 }, backgrounds: [onCard], minimum: words),
    Element(name: "Provider name", ink: { $0.text }, backgrounds: [onCard], minimum: words),
    Element(name: "Account count", ink: { $0.text2 }, backgrounds: [onCard], minimum: words),
    Element(name: "Suggestion pill", ink: { $0.skin.amberPill.ink }, backgrounds: [pillOnCard { $0.amberPill }], minimum: words),
    Element(name: "Card subline", ink: { $0.text2 }, backgrounds: [onCard], minimum: words),
    Element(name: "Runs out warning", ink: { $0.skin.paceWarn }, backgrounds: [onCard], minimum: words),
    Element(name: "Runs out warning (red)", ink: { $0.skin.lowInk }, backgrounds: [onCard], minimum: words),
    Element(name: "Runs out warning (green)", ink: { $0.skin.greenPill.ink }, backgrounds: [onCard], minimum: words),
    Element(name: "Column header", ink: { $0.text2 }, backgrounds: [onCard], minimum: words),
    Element(name: "Account and machine name", ink: { $0.text }, backgrounds: [onCard, hotCard], minimum: words),
    Element(name: "Plan badge MAX 20X", ink: { $0.skin.planClaude.ink }, backgrounds: [pillOnCard { $0.planClaude }], minimum: words),
    Element(name: "Plan badge Codex", ink: { $0.skin.planCodex.ink }, backgrounds: [pillOnCard { $0.planCodex }], minimum: words),
    Element(name: "Usage number, red", ink: { $0.skin.lowInk }, backgrounds: [onCard, hotCard], minimum: words),
    Element(name: "Reset time", ink: { $0.text2 }, backgrounds: [onCard, hotCard], minimum: words),
    Element(name: "Usage number", ink: { $0.text }, backgrounds: [onCard, hotCard], minimum: words),
    Element(name: "Not started", ink: { $0.skin.greenPill.ink }, backgrounds: [onCard, hotCard], minimum: words),
    Element(name: "Plain count", ink: { $0.text }, backgrounds: [onCard], minimum: words),
    Element(name: "Status pill", ink: { $0.skin.greenPill.ink }, backgrounds: [pillOnCard { $0.greenPill }], minimum: words),
    Element(name: "Status pill (amber)", ink: { $0.skin.amberPill.ink }, backgrounds: [pillOnCard { $0.amberPill }], minimum: words),
    Element(name: "Status pill (red)", ink: { $0.skin.redPill.ink }, backgrounds: [pillOnCard { $0.redPill }], minimum: words),
    Element(name: "Status pill (idle)", ink: { $0.skin.idlePill.ink }, backgrounds: [pillOnCard { $0.idlePill }], minimum: words),
    Element(name: "by Jetto", ink: { $0.text3 }, backgrounds: [onFooter], minimum: marks),
    Element(name: "Tab dot (non-text)", ink: { $0.skin.tabDot }, backgrounds: [laid(onPanel) { $0.seg }], minimum: marks),
    Element(name: "Tool icon (non-text)", ink: { $0.skin.chipInk }, backgrounds: [chipOnPanel, chipOnFooter], minimum: marks),
    Element(name: "Provider icon (non-text)", ink: { $0.skin.inkClaude }, backgrounds: [onCard], minimum: marks),
    Element(name: "Provider icon (non-text)", ink: { $0.skin.inkCodex }, backgrounds: [onCard], minimum: marks),
    Element(name: "Chevron (non-text)", ink: { $0.text2 }, backgrounds: [onCard], minimum: marks),
    Element(name: "Account marker icon (non-text)", ink: { $0.skin.inkSpark }, backgrounds: [onCard, hotCard], minimum: marks),
    Element(name: "Account marker icon (non-text)", ink: { $0.skin.inkWarn }, backgrounds: [onCard, hotCard], minimum: marks),
    Element(name: "Tile icon (non-text)", ink: { _ in 0xFFFFFF },
            backgrounds: [{ mode, _, _, _ in PanelPalette.rgb(mode.skin.tile.from) },
                          { mode, _, _, _ in PanelPalette.rgb(mode.skin.tile.to) }], minimum: marks),
] + gradientEnds("Ring arc (non-text)") { $0.claude } + gradientEnds("Ring arc (non-text)") { $0.codex }
  + gradientEnds("Ring arc (non-text)") { $0.violet } + gradientEnds("Ring arc (non-text)") { $0.amber }
  + gradientEnds("Ring arc (non-text)") { $0.red }

/// Every desktop x gradient stop x {no halo, each halo at its peak}.
func worstContrast(_ element: Element, _ mode: PanelPalette.Appearance) -> Double {
    var worst = Double.greatestFiniteMagnitude
    for wall in PanelPalette.wallpapers {
        for stop in 0..<mode.skin.stops.count {
            for halo in [nil, 0, 1, 2] as [Int?] {
                for background in element.backgrounds {
                    let c = PanelPalette.contrast(PanelPalette.rgb(element.ink(mode)),
                                                  background(mode, wall.hex, stop, halo))
                    worst = min(worst, c)
                }
            }
        }
    }
    return worst
}

/// Lowest reading per group of the draft (its own Chrome-composited worst pixel over 12 combinations),
/// copied from Opus draft readings.js. Printed beside ours, never asserted equal: the draft measures a
/// rendered pixel, this measures a flat colour.
let draftReadings: [String: [String: Double]] = [
    "dark": [
    "Account and machine name": 7.19,
    "Account count": 5.73,
    "Account marker icon (non-text)": 4.51,
    "Bar fill (non-text)": 3.07,
    "Card subline": 5.22,
    "Chevron (non-text)": 6.51,
    "Column header": 5.28,
    "Plain count": 9.72,
    "Logo Tally": 5.06,
    "Not started": 6.63,
    "Violet pill": 4.94,
    "Plan badge MAX 20X": 4.53,
    "Tile icon (non-text)": 3.87,
    "Status pill": 5.48,
    "Provider icon (non-text)": 3.27,
    "Provider name": 7.57,
    "Refresh countdown 56s": 7.48,
    "Reset time": 5.67,
    "Ring arc (non-text)": 3.36,
    "Ring label LEFT": 4.89,
    "Ring number": 6.86,
    "Runs out warning": 5.22,
    "Suggestion pill": 4.82,
    "Tab dot (non-text)": 5.54,
    "Tab, not selected": 8.01,
    "Tab, selected": 7.53,
    "Tool icon (non-text)": 6.33,
    "Usage number": 8.1,
    "Usage number, red": 4.78,
    "by Jetto": 6.23
    ],
    "light": [
    "Account and machine name": 13.73,
    "Account count": 6.4,
    "Account marker icon (non-text)": 4.94,
    "Bar fill (non-text)": 3.2,
    "Card subline": 6.31,
    "Chevron (non-text)": 6.5,
    "Column header": 6.36,
    "Plain count": 14.9,
    "Logo Tally": 3.47,
    "Not started": 6.52,
    "Violet pill": 4.83,
    "Plan badge MAX 20X": 4.7,
    "Tile icon (non-text)": 5.02,
    "Status pill": 5.51,
    "Provider icon (non-text)": 3.05,
    "Provider name": 14.7,
    "Refresh countdown 56s": 5.9,
    "Reset time": 5.91,
    "Ring arc (non-text)": 3.46,
    "Ring label LEFT": 6.31,
    "Ring number": 13.44,
    "Runs out warning": 5.74,
    "Suggestion pill": 5.84,
    "Tab dot (non-text)": 3.83,
    "Tab, not selected": 5.01,
    "Tab, selected": 17.35,
    "Tool icon (non-text)": 10.13,
    "Usage number": 13.77,
    "Usage number, red": 5.15,
    "by Jetto": 5.99
    ],
]

// Two named elements that sit on the same group (the status pill, a provider icon) are read as
// the lowest of them.
func skinReport(_ modes: [(String, PanelPalette.Appearance)], draft: Bool) -> Int {
    var failed = 0
    for (name, mode) in modes {
        var byGroup: [String: (value: Double, minimum: Double)] = [:]
        for element in elements {
            let value = worstContrast(element, mode)
            if let seen = byGroup[element.name] { byGroup[element.name] = (min(seen.value, value), element.minimum) }
            else { byGroup[element.name] = (value, element.minimum) }
        }
        for group in byGroup.keys.sorted() {
            let entry = byGroup[group]!
            let passes = entry.value >= entry.minimum
            if !passes { failed += 1 }
            if draft {
                let reading = draftReadings[name]?[group].map { String(format: "%.2f", $0) } ?? "-"
                check(passes, "\(name) skin, \(group): swift=\(String(format: "%.2f", entry.value)) needs \(entry.minimum), draft=\(reading)")
            }
        }
    }
    return failed
}

print("the skin: every element x every desktop x every stop x every halo")
let skinModes: [(String, PanelPalette.Appearance)] = [("dark", PanelPalette.dark), ("light", PanelPalette.light)]
_ = skinReport(skinModes, draft: true)

// THE SKIN'S TEST CAN GO RED too. The draft's colours under a glass of 0.40 / 0.36 (the opacity the
// first round shipped with, B-4169 round one) must fail somewhere, or the battery above asks nothing.
print("a thin glass is caught")
var thinDark = PanelPalette.dark
thinDark.skin.alpha = 0.40
var thinLight = PanelPalette.light
thinLight.skin.alpha = 0.36
check(skinReport([("dark", thinDark), ("light", thinLight)], draft: false) > 0,
      "the draft's colours at glass 0.40 / 0.36 fail at least one group")

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
// The Detailed card head's fold arrow is a bare image: it must sit in a hit area of its own, wired
// like the ring and the name (B-3823, it was dead until every caller wrapped it).
print("the card head's fold arrow is clickable")
let cardHead = read("Tally/Views/ProviderCardHeader.swift")
let afterChevron = cardHead.range(of: "foldChevron(").map { String(cardHead[$0.upperBound...].prefix(400)) } ?? ""
check(afterChevron.contains(".windowDragOrTap(toggle)") && afterChevron.contains(".onTapGesture(perform: toggle)"),
      "ProviderCardHeader wires the fold arrow to the same toggle as the name and the ring")
let header = read("Tally/Views/PopoverHeaderView.swift")
check(!header.isEmpty && header.contains(".foregroundStyle(PanelStyle.text2)") && !header.contains("foregroundStyle(.tertiary).monospacedDigit"),
      "the refresh countdown is secondary")

// THE NUMBERS THE DELIVERY TEXT QUOTES, one per line as "name=value", every one read from the constant or
// the arithmetic the views are laid out by (never typed here), so a sentence in a hand-off can be checked
// against this output line for line.
// THE PLAN PILL, THE LAUNCH SLOT AND A NAME'S FLOOR FIT ONE IDENTITY COLUMN (B-4334): the widest pill
// text, "MAX 20X" (the plan's old name) or "ULTRA" (its new one) in the badge's type (8.5pt heavy,
// 0.06em tracking, 5pt either side; the source lock below ties these to PanelSkin), the launch slot,
// the 5pt gap before the pill, the 4pt one before the slot and 40pt of name must fit the three-window identity column, so the pin circle,
// the pill and the name never need the room of one another. Four windows squeeze the column and the
// pill is given up instead (the row's second `ViewThatFits` candidate); that is asserted to be the
// case, so this stays a test of the choice and not of a number.
print("the identity column holds a name, the pill and the launch slot")
let skinSource = read("Tally/Views/PanelSkin.swift")
check(skinSource.contains("case .badge: return (8.5, 700, 0.06 * 8.5, 5, 1.5)"), "the pill's type and padding are the ones measured here")
func pillWidth(_ text: String) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 8.5, weight: NSFont.Weight(rawValue: 0.47))
    let measured = (text as NSString).size(withAttributes: [.font: font, .kern: 0.06 * 8.5]).width
    return ceil(measured) + 2 * 5
}
let widestPill = max(pillWidth("MAX 20X"), pillWidth("ULTRA"))
let neededWithPill = PanelMetrics.nameFloor + 5 + widestPill + 4 + PanelMetrics.launchSlotWidth
print("  widest pill=\(widestPill) needed=\(neededWithPill) three windows=\(PanelMetrics.identityColumnWidth(columns: 3)) four windows=\(PanelMetrics.identityColumnWidth(columns: 4))")
check(neededWithPill <= PanelMetrics.identityColumnWidth(columns: 3), "name floor, pill and launch slot fit the three-window identity column")
check(neededWithPill > PanelMetrics.identityColumnWidth(columns: 4), "four windows leave no room for the pill, so the row drops it rather than overflow")
check(PanelMetrics.identityColumnWidth(columns: 2) >= neededWithPill, "two windows fit the pill, the slot and a name as well")

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
    ("panel corner radius, pinned panel (pt)", "\(PanelMetrics.panelRadius)"),
    ("card corner radius (pt)", "\(PanelMetrics.cardRadius)"),
    ("card side padding (pt)", "\(PanelMetrics.cardPadH)"),
    ("table row inset (pt)", "\(PanelMetrics.rowInsetH)"),
    ("pool ring stroke (pt)", "\(PanelMetrics.ringStroke)"),
    ("skin glass opacity, dark", "\(PanelPalette.dark.skin.alpha)"),
    ("skin glass opacity, light", "\(PanelPalette.light.skin.alpha)"),
    ("halo peak opacity, dark (claude, codex, violet)", PanelPalette.dark.skin.halos.map { "\($0.alpha)" }.joined(separator: " ")),
    ("halo peak opacity, light (claude, codex, violet)", PanelPalette.light.skin.halos.map { "\($0.alpha)" }.joined(separator: " ")),
]
for (name, value) in measures { print("  \(name)=\(value)") }
check(PanelMetrics.identityColumnWidth(columns: columns) > 0, "the name column is not empty at \(columns) windows")

if failures > 0 { print("\(failures) assertion(s) failed"); exit(1) }
print("ALL PASS")
