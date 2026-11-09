import Darwin
import Foundation

/// The syscalls of the tmux priority guard (rules: TmuxPriorityLogic.swift). Read only: nothing
/// here signals, restarts or renices a process.
enum TmuxPriorityReaders {

    /// The highest `pth_priority` over a process's threads, which is what `ps -o pri` prints.
    ///
    /// NOT the task-level base priority (`pti_priority`). It does not see a priority
    /// the scheduler lowered: measured 2026-11-09, a tmux server `ps` showed at 20 read 31 there,
    /// and a guard built on it never fires. Nil when the kernel will not say (the process ended, or
    /// belongs to another user), which the rules read as "say nothing".
    static func maxThreadPriority(of pid: pid_t) -> Int? {
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { return nil }
        // Slack for threads started between the two calls; the kernel fills what fits.
        var ids = [UInt64](repeating: 0, count: Int(task.pti_threadnum) + 16)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &ids,
                                 Int32(ids.count * MemoryLayout<UInt64>.size))
        guard bytes > 0 else { return nil }
        var highest: Int?
        for id in ids.prefix(Int(bytes) / MemoryLayout<UInt64>.size) {
            var thread = proc_threadinfo()
            let size = Int32(MemoryLayout<proc_threadinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTHREADINFO, id, &thread, size) == size else { continue }
            highest = max(highest ?? Int(thread.pth_priority), Int(thread.pth_priority))
        }
        return highest
    }

    /// Every tmux server of `uid` (a process named `tmux` whose parent is launchd: the client
    /// forks the server and leaves), with its priority and whether an agent runs under it.
    /// The descendant walk and the path lookups happen only for a server that is below normal.
    static func scan(uid: uid_t = getuid()) -> [TmuxServerReading] {
        var parents: [pid_t: pid_t] = [:]
        var servers: [pid_t] = []
        for pid in allPids() where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            parents[pid] = pid_t(info.pbi_ppid)
            if info.pbi_ppid == 1, info.pbi_uid == uid, commandName(info) == "tmux" { servers.append(pid) }
        }
        return servers.sorted().map { pid in
            let priority = maxThreadPriority(of: pid)
            guard TmuxPriorityLogic.isLow(priority) else {
                return TmuxServerReading(pid: pid, priority: priority, hasAgent: false)
            }
            let hasAgent = TmuxPriorityLogic.descendants(of: pid, parents: parents).contains {
                executablePath(of: $0).map(TmuxPriorityLogic.isAgentPath) ?? false
            }
            return TmuxServerReading(pid: pid, priority: priority, hasAgent: hasAgent)
        }
    }

    private static func commandName(_ info: proc_bsdinfo) -> String {
        withUnsafeBytes(of: info.pbi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `proc_listallpids` returns a COUNT of pids and not the byte count its argument is given in
    /// (the trap `ProcessTree.liveProcesses` documents); clamped to the buffer because processes
    /// started between the sizing call and the fill can push the count past it.
    private static func allPids() -> [pid_t] {
        let sized = proc_listallpids(nil, 0)
        guard sized > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(sized) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(min(Int(filled), pids.count)))
    }
}
