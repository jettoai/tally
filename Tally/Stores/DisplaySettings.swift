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

/// Whether reset instants read as a countdown ("resets in 2d 4h") or an exact time ("resets at
/// 7/18, 21:36"). Global, toggled by clicking any reset label (the exact time
/// is one click away, no settings entry needed). Persisted in `SettingsStore`.
enum ResetDisplay: String, Sendable {
    case relative
    case absolute

    var toggled: ResetDisplay { self == .relative ? .absolute : .relative }
}
