import Darwin
import Foundation

/// WHAT THE CPU WATCH ASKS THE MACHINE (CPUAlertLogic.swift holds the rules).
///
/// THE ORDINARY SAMPLE IS ONE SYSCALL: `host_statistics(HOST_CPU_LOAD_INFO)`, cumulative ticks
/// across every core, which walks nothing. The process table is walked only by `busiest` (the load
/// alarm) and `scan` (a CPU banner going out).
enum CPUAlertReaders {

    static func ticks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
            / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks is a C tuple indexed by CPU_STATE_USER / SYSTEM / IDLE / NICE.
        let t = info.cpu_ticks
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    /// The whole machine over one window, for the breakdown (`CPUAlertLogic.breakdown`). Read only
    /// when a banner is going out. The process table is listed at both ends so a pid born inside
    /// the window is seen, and the host ticks bracket the same window so the busy figure and the
    /// processes are one measurement. Nil when the ticks cannot say.
    ///
    /// NAMES, NEVER ARGUMENTS: working directories and executable paths, the rule
    /// `HostHealthProcess` states. The path is read only for pids that worked.
    static func scan(seconds: Double = 2) async -> CPUAlertScan? {
        let firstList = ProcessTree.liveProcesses()
        guard let ticksA = ticks() else { return nil }
        let a = ProcessTree.resourceSample(of: firstList.map(\.pid))
        let windowStart = Int64(a.at.timeIntervalSince1970 * 1_000_000)
        try? await Task.sleep(for: .seconds(seconds))
        let secondList = ProcessTree.liveProcesses()
        guard let ticksB = ticks(),
              let busyShare = CPUAlertLogic.busyPercent(from: ticksA, to: ticksB) else { return nil }
        let b = ProcessTree.resourceSample(of: secondList.map(\.pid))
        let elapsed = b.at.timeIntervalSince(a.at)
        guard elapsed > 0 else { return nil }
        func readings(_ list: [ProcessIdentity], _ s: ProcessResourceSample) -> [Int32: CPUAlertPidReading] {
            var out: [Int32: CPUAlertPidReading] = [:]
            for p in list {
                guard let own = s.times[p.pid] else { continue }
                out[p.pid] = CPUAlertPidReading(parent: p.parent, startedAt: p.startedAt, own: own,
                                                children: s.childTimes[p.pid] ?? 0)
            }
            return out
        }
        let work = CPUAlertLogic.windowWork(first: readings(firstList, a), second: readings(secondList, b),
                                            windowStart: windowStart)
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let processes = secondList.map { p -> CPUAlertProcessWork in
            let seconds = work[p.pid] ?? 0
            return CPUAlertProcessWork(pid: p.pid, parent: p.parent, seconds: seconds,
                                       cwd: MachineLoadRollup.workingDirectory(of: p.pid),
                                       executablePath: seconds > 0 ? ProcessTree.executablePath(of: p.pid) : nil)
        }
        return CPUAlertScan(processes: processes, busySeconds: busyShare / 100 * elapsed * cores)
    }

    /// Every readable process's own CPU over a two-second window, in share of ONE core (Activity
    /// Monitor's unit), busiest first, ties on the pid.
    static func busiest() async -> [(pid: pid_t, percent: Double)] {
        let pids = ProcessTree.liveProcesses().map(\.pid)
        let first = ProcessTree.resourceSample(of: pids)
        try? await Task.sleep(for: .seconds(2))
        let second = ProcessTree.resourceSample(of: pids)
        let elapsed = second.at.timeIntervalSince(first.at)
        guard elapsed > 0 else { return [] }
        return second.times.compactMap { pid, now -> (pid: pid_t, percent: Double)? in
            guard let before = first.times[pid], now >= before else { return nil }
            return (pid, (now - before) / elapsed * 100)
        }
        .sorted { $0.percent == $1.percent ? $0.pid < $1.pid : $0.percent > $1.percent }
    }
}
