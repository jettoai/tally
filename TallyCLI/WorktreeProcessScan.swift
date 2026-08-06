import Darwin
import Foundation

// Walking the process table for the worktree commands: which live processes exist, where each one
// is working, and what terminal it is attached to. Split out of WorktreeTeardown.swift for file
// size; the decisions taken over this list (`shouldKill`, `worktreeProcessesToKill`) stay there
// with the teardown they serve, and `ProcInfo` is declared there too since it is what those pure
// decisions are written against.
//
// Two callers, one scan: the teardown signals what it finds here, and `tally worktree list` counts
// the same selection in its live agent column, so a report and a refusal can never disagree.

/// Every live process (except this one and its ancestors) whose cwd libproc will report. Only
/// processes we can inspect and signal surface here, which is exactly the set we could kill anyway.
/// How far the pid buffer may be walked comes from `scannedPidCount` (ReloadRequest.swift, same
/// target), which documents why the second `proc_listallpids` return must not be divided by the pid
/// size. Doing so once ended the walk a quarter of the way through the machine, blinding both users
/// of this scan: teardown reported "killed 0" over live agents, and `tally worktree list`
/// undercounted the same processes in its live agent column.
func defaultListProcesses(worktreePath: String) -> [ProcInfo] {
    let excluded = ancestorPids(of: getpid())
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(capacity))
    let returned = proc_listallpids(&pids, Int32(Int(capacity) * MemoryLayout<pid_t>.size))
    var result: [ProcInfo] = []
    for pid in pids.prefix(scannedPidCount(returned, capacity: pids.count)) {
        if pid <= 0 || excluded.contains(pid) { continue }
        guard let cwd = processCwd(pid), !cwd.isEmpty else { continue }
        let info = bsdInfo(pid)
        result.append(ProcInfo(pid: pid, ppid: info.map { pid_t($0.pbi_ppid) } ?? 0,
                               name: processName(pid), cwd: cwd,
                               tty: info.flatMap(controllingTerminal)))
    }
    return result
}

/// A process's controlling terminal as a device path, or nil when it has none or the number does
/// not name a device.
///
/// `e_tdev` is unsigned and carries NODEV (0xFFFFFFFF) for a process with no terminal, which is the
/// common case (every daemon, and this process itself when it runs from a hook rather than a tab).
/// It MUST be tested before the conversion: `dev_t` is signed, so handing NODEV to it traps and
/// takes the whole teardown down with it (seen while measuring this, 2026-07-27).
private func controllingTerminal(_ info: proc_bsdinfo) -> String? {
    guard info.e_tdev != UInt32.max else { return nil }
    guard let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
    let device = String(cString: name)
    return device.isEmpty ? nil : "/dev/\(device)"
}

/// libproc's BSD record for a pid, or nil when it cannot be read (the process is gone, or belongs
/// to another user: `login` running as root answers nothing here, which is why every field derived
/// from this is optional).
private func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info
}

/// The current working directory of a process via proc_pidvnodepathinfo, or nil when it cannot be
/// read (the process is gone, or belongs to another user).
private func processCwd(_ pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) > 0 else { return nil }
    return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
        raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
    }
}

/// A process's short name: the last path component of its executable (proc_pidpath), falling back to
/// the accounting name (proc_name) when the path is unavailable.
private func processName(_ pid: pid_t) -> String {
    // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not imported into Swift; use its literal value.
    var pathBuffer = [CChar](repeating: 0, count: 4 * 1024)
    if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
        let path = pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        if !path.isEmpty { return (path as NSString).lastPathComponent }
    }
    var nameBuffer = [CChar](repeating: 0, count: 256)
    if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
        return nameBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
    return ""
}

/// The set of a process's own pid plus every ancestor, walked via proc_bsdinfo's parent pid. Used to
/// keep the teardown from signalling the session that launched it.
private func ancestorPids(of start: pid_t) -> Set<pid_t> {
    var chain: Set<pid_t> = [start]
    var pid = start
    while let parent = parentPid(pid), parent > 0, !chain.contains(parent) {
        chain.insert(parent)
        pid = parent
    }
    return chain
}

/// A process's parent pid, nil for the same reasons its BSD record can be unreadable.
private func parentPid(_ pid: pid_t) -> pid_t? {
    bsdInfo(pid).map { pid_t($0.pbi_ppid) }
}
