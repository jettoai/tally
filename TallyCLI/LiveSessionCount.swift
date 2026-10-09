import Foundation

/// How many LIVE supervisors have their child on `accountID` right now, read from the per-pid
/// account files (`supervisorAccountFile`). A file whose pid is gone is not counted: the sweep that
/// removes it runs when the supervisor dies (PendingNotice.swift) and can lag.
func liveSessionCount(onAccount accountID: String, dir: URL = supervisorStateDir) -> Int {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
    return names.filter { $0.hasSuffix(supervisorAccountSuffix) }.reduce(0) { count, name in
        let pid = String(name.dropLast(supervisorAccountSuffix.count))
        guard let value = pid_t(pid), value > 0, supervisorAlive(value),
              readSupervisorAccount(pid: pid, dir: dir) == accountID else { return count }
        return count + 1
    }
}
