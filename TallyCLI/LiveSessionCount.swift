import Foundation

/// Wires the clearance lane's occupancy reader (`clearanceSessionCounter`) for every launch,
/// prediction and supervisor this process runs. Called once at entry (main.swift). A count that
/// could not be read is FULL, so an unreadable state directory never fills a clearance account.
func wireClearanceSessionCounter() {
    // Re-read per ask: a supervisor outlives many refreshes, and only thin accounts are asked (#4).
    clearanceSessionCounter = { id in
        sessionsOnLogin(id, in: loadSnapshot().0?.accounts ?? []) { liveSessionCount(onAccount: $0) }
    }
}

/// How many LIVE supervisors have their child on `accountID` right now (`liveSessionCounts`, the
/// reader the panel's badge shares). nil is "unknown", which every caller reads as full.
func liveSessionCount(onAccount accountID: String, dir: URL = supervisorStateDir) -> Int? {
    liveSessionCounts(dir: dir).map { $0[accountID] ?? 0 }
}
