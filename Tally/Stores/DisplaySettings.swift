import Foundation

/// Whether meters read as amount used or amount remaining. Default remaining (the number a subscriber
/// usually wants: "how much have I got left"). Colour always keys off used%, so severity never flips
/// with this toggle. The persisted value lives in `SettingsStore`.
enum DisplayMode: String, Sendable, CaseIterable {
    case used
    case remaining

    var toggled: DisplayMode { self == .used ? .remaining : .used }
}

/// What the fleet gauge shows and which number the menu-bar strip leads with. `all` (default)
/// renders EVERY pooled weekly-cycle window - the primary-model budget first, the account-wide
/// weekly after it, because a fallback user needs both runways at once; `primary` collapses the
/// strip to just the primary-model pool (flagship-first when no primary is declared, the smart
/// launcher's rule); `weekly` pins the account-wide weekly budget alone. The menu bar always
/// carries one number per window class, so it follows the leading pool. Persisted in
/// `SettingsStore`; resolution lives in `FleetFocus`.
enum GaugeFocus: String, Sendable, CaseIterable {
    case all
    case primary
    case weekly
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

/// How much room each account gets on the panel. `list` (default) collapses each account to a
/// single row, meters inline, so a fleet of several accounts fits the screen. `cards` is the full
/// card: identity, the headline meter prominent, every other window under it, the reset context
/// lines. It is a density, not a different set of facts: every control a card carries is on the
/// row too, shrunk to an icon. Persisted in `SettingsStore`.
enum PanelDensity: String, Sendable, CaseIterable {
    case cards
    case list
}
