import Foundation

/// Which alternative usage-tab layout this launch previews, from the volatile
/// `-TallyUsageLayout ledger|tray` argument (the argument domain, same as `-TallyCardStyle`).
///
/// DEBUG BUILDS ONLY. A release build answers nil whatever the arguments say, so the default layout
/// is not something a launch flag can reach: the previews exist to be photographed and judged, and
/// the panel every user runs stays exactly the one it was. This file is the only place the flag is
/// spelled (the launch-flag completeness check scans for the literal).
///
/// Resolved once: a launch argument cannot change while the app runs, and the panel asks on every
/// layout pass.
enum UsageLayout: String {
    /// One row per account, three horizontal bars lined up in columns, one number: the tightest.
    case ledger
    /// One tile per account, three vertical micro bars, a number only when it is tight.
    case tray

    /// The pure reading of the flag's value: case-insensitive, and anything unknown is nil rather
    /// than a guess (a typo must land on the default layout, not on a layout nobody asked for).
    static func parse(_ raw: String?) -> UsageLayout? {
        raw.flatMap { UsageLayout(rawValue: $0.lowercased()) }
    }

    #if DEBUG
    static let active: UsageLayout? = parse(UserDefaults.standard.string(forKey: "TallyUsageLayout"))
    #else
    static let active: UsageLayout? = nil
    #endif
}
