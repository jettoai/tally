import Foundation

/// Wires the clearance lane's occupancy reader (`clearanceSessionCounter`) for every launch,
/// prediction and supervisor this process runs. Called once at entry (main.swift). A count that
/// could not be read is FULL, so an unreadable state directory never fills a clearance account.
func wireClearanceSessionCounter() {
    clearanceSessionCounter = { liveSessionCount(onAccount: $0) ?? clearanceMaxSessions }
}

/// How many LIVE supervisors have their child on `accountID` right now, read from the per-pid
/// account files (`supervisorAccountFile`). A file whose pid is gone is not counted: the sweep that
/// removes it runs when the supervisor dies (PendingNotice.swift) and can lag.
///
/// nil is "unknown", and every caller reads it as full: the directory exists but cannot be listed,
/// or a LIVE supervisor's file cannot be read (unreadable, empty, mid-write). Reading those as 0 is
/// what used to let a clearance account take sessions it already had. A directory that does not
/// exist yet is a real 0: no supervisor has ever written one.
func liveSessionCount(onAccount accountID: String, dir: URL = supervisorStateDir) -> Int? {
    let names: [String]
    do {
        names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return 0
    } catch {
        return nil
    }
    var count = 0
    for name in names where name.hasSuffix(supervisorAccountSuffix) {
        let pid = String(name.dropLast(supervisorAccountSuffix.count))
        guard let value = pid_t(pid), value > 0, supervisorAlive(value) else { continue }
        guard let account = readSupervisorAccount(pid: pid, dir: dir) else { return nil }
        if account == accountID { count += 1 }
    }
    return count
}
