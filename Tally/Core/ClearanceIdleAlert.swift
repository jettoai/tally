import Foundation

/// An account whose weekly leftovers are about to vanish at a reset with nothing using them
/// (B-1395). Which accounts HAVE such leftovers is the clearance rule's question
/// (`clearanceLeftover`, TallyCLI/AccountComfort.swift); this only adds "soon" and "idle".
struct ClearanceIdleCandidate: Equatable {
    let accountID: String
    let label: String
    let remaining: Double
    let resetsAt: Date
}

enum ClearanceIdleAlert {
    /// How close the reset must be. Two hours is one long working session: early enough to start
    /// one and spend a few percent, late enough that a day-long horizon does not nag.
    static let horizon: TimeInterval = 2 * 3600

    /// Accounts to announce now. `live` nil means the session count could not be read, which
    /// announces nothing. `announced` is each account's last announced cycle key
    /// (`DryPoolLogic.resetKey`), compared with the same minute-jitter tolerance the pool alert uses.
    static func due(_ candidates: [ClearanceIdleCandidate], live: [String: Int]?,
                    announced: [String: String], now: Date) -> [ClearanceIdleCandidate] {
        guard let live else { return [] }
        return candidates.filter { c in
            let left = c.resetsAt.timeIntervalSince(now)
            return left > 0 && left <= horizon && (live[c.accountID] ?? 0) == 0
                && !DryPoolLogic.namesSameCycle(announced[c.accountID], DryPoolLogic.resetKey(c.resetsAt))
        }
    }
}
