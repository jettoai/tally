import Foundation

/// Whether meters read as amount used or amount remaining. Default remaining (the number a subscriber
/// usually wants: "how much have I got left"). Colour always keys off used%, so severity never flips
/// with this toggle. The persisted value lives in `SettingsStore`.
enum DisplayMode: String, Sendable, CaseIterable {
    case used
    case remaining

    var toggled: DisplayMode { self == .used ? .remaining : .used }
}

/// Whether reset instants read as a countdown ("resets in 2d 4h") or an exact time ("resets at
/// 7/18, 21:36"). Global, toggled by clicking any reset label (OpenUsage's pattern — the exact time
/// is one click away, no settings entry needed). Persisted in `SettingsStore`.
enum ResetDisplay: String, Sendable {
    case relative
    case absolute

    var toggled: ResetDisplay { self == .relative ? .absolute : .relative }
}
