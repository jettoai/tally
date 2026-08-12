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

/// What one segment of the menu-bar strip counts. `perAccount` (default) gives every visible
/// account its own mark and its own numbers, so N accounts read as N marks. `pooled` gives every
/// provider ONE segment summing its accounts - the same pool the panel's fleet gauge draws, so the
/// two surfaces answer with the same figure - for a fleet whose per-account strip has grown wider
/// than the bar has room for. It is a different unit, not different facts: both layouts stack the
/// same two windows (session on top, the focus-resolved weekly below). Persisted in
/// `SettingsStore`; the segments themselves are built in `MenuBarSegments`.
enum MenuBarLayout: String, Sendable, CaseIterable {
    case perAccount
    case pooled
}

/// How much room each account gets on the panel. `cards` (default) is the full card: identity,
/// the headline meter prominent, every other window under it, the reset context lines. `list`
/// collapses the same account to a single row, meters inline, for a fleet whose card grid has
/// grown taller than the screen. It is a density, not a different set of facts: every control a
/// card carries is on the row too, shrunk to an icon. Persisted in `SettingsStore`.
enum PanelDensity: String, Sendable, CaseIterable {
    case cards
    case list
}

/// Whether reset instants read as a countdown ("resets in 2d 4h") or an exact time ("resets at
/// 7/18, 21:36"). Global, toggled by clicking any reset label (the exact time
/// is one click away, no settings entry needed). Persisted in `SettingsStore`.
enum ResetDisplay: String, Sendable {
    case relative
    case absolute

    var toggled: ResetDisplay { self == .relative ? .absolute : .relative }
}
