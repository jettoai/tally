import Foundation

/// Whether meters read as amount used or amount remaining. Default remaining (the number a subscriber
/// usually wants: "how much have I got left"). Colour always keys off used%, so severity never flips
/// with this toggle. The persisted value lives in `SettingsStore`.
enum DisplayMode: String, Sendable, CaseIterable {
    case used
    case remaining

    var toggled: DisplayMode { self == .used ? .remaining : .used }
}

/// What one segment of the menu-bar strip counts. `pooled` (default) gives every provider ONE
/// segment summing its accounts - the same pool the panel's fleet gauge draws, so the two surfaces
/// answer with the same figure. `perAccount` gives every visible account its own mark and its own
/// numbers, so N accounts read as N marks.
///
/// Pooled leads because of the question the bar is glanced at to answer: "how much is left". One
/// figure per provider IS that answer, while N marks are the raw material for it and leave the
/// reader adding up (owner ruling, 2026-08-12; the per-account strip also outgrows the bar first).
/// It is a different unit, not different facts: both layouts stack the same two windows (session on
/// top, the focus-resolved weekly below). Persisted in `SettingsStore`; the segments themselves are
/// built in `MenuBarSegments`.
enum MenuBarLayout: String, Sendable, CaseIterable {
    case perAccount
    case pooled
}

/// How much room each account gets on the panel. The panel is always `list` (B-4059): each account
/// collapses to a single row, meters inline, so a fleet of several accounts fits the screen. `cards`
/// is kept only for the card code path still in the tree: the full card, with identity, the
/// headline meter prominent, every other window under it, the reset context lines.
enum PanelDensity: String, Sendable, CaseIterable {
    case cards
    case list
}

/// What the PINNED panel looks like: bare rings (`rings`), rings with their figures (`labeled`, the
/// strip `PinnedCompactView` draws), or the full panel. The two strips also take a direction
/// (`PinnedAxis`); the full panel has none. Only the pinned panel reads it; the popover and the
/// dashboard window are always full. Persisted in `SettingsStore`.
enum PinnedStyle: String, Sendable, CaseIterable {
    case rings
    case labeled
    case full
}

/// Which way a pinned strip runs. Ignored by `PinnedStyle.full`, but kept while it is selected so
/// switching back to a strip returns to the direction the user last chose.
enum PinnedAxis: String, Sendable, CaseIterable {
    case vertical
    case horizontal
}

extension PinnedStyle {
    /// Reads the stored pin choice. `form` and `axis` are the current keys; `legacy` is the single
    /// `pinnedStyle` key older builds wrote ("full", "row", "column"), read only when `form` is absent
    /// so the old choice carries over once and the new keys win from then on. Anything unreadable
    /// falls back to the full panel, vertical.
    static func resolve(form: String?, axis: String?, legacy: String?) -> (PinnedStyle, PinnedAxis) {
        let old: (PinnedStyle, PinnedAxis) = switch legacy {
        case "row": (.labeled, .horizontal)
        case "column": (.labeled, .vertical)
        default: (.full, .vertical)
        }
        let style = form == nil ? old.0 : (form.flatMap(PinnedStyle.init(rawValue:)) ?? .full)
        let direction = axis.flatMap(PinnedAxis.init(rawValue:)) ?? (form == nil ? old.1 : .vertical)
        return (style, direction)
    }
}
