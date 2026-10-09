import Foundation

/// How many LIVE supervisors have their child on `accountID` right now, read from the per-pid
/// account files (`supervisorAccountFile`). A file whose pid is gone is not counted: the sweep that
/// removes it runs when the supervisor dies (PendingNotice.swift) and can lag.
func liveSessionCount(onAccount accountID: String, dir: URL = supervisorStateDir) -> Int {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
    return names.filter { name in
        guard name.hasSuffix(supervisorAccountSuffix) else { return false }
        let pid = String(name.dropLast(supervisorAccountSuffix.count))
        guard let value = pid_t(pid), value > 0 else { return false }
        return supervisorAlive(value) && readSupervisorAccount(pid: pid, dir: dir) == accountID
    }.count
}
