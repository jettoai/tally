import Foundation

/// Whether meters read as amount used or amount remaining. Default remaining (the number a subscriber
/// usually wants: "how much have I got left"). Colour always keys off used%, so severity never flips
/// with this toggle. The persisted value lives in `SettingsStore`.
enum DisplayMode: String, Sendable, CaseIterable {
    case used
    case remaining

    var toggled: DisplayMode { self == .used ? .remaining : .used }
}

/// Which window the fleet gauge headlines and the menu-bar strip's weekly number shows - the
/// "number Tally leads with" for people who ration a specific budget. `auto` follows the launch
/// policy's primary model (flagship-first when unset, the smart launcher's rule); `flagship`
/// pins the top model window; `weekly` pins the account-wide weekly budget. Persisted in
/// `SettingsStore`; resolution lives in `FleetFocus`.
enum GaugeFocus: String, Sendable, CaseIterable {
    case auto
    case flagship
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
