import Darwin
import Foundation

/// WHAT THE CPU WATCH ASKS THE MACHINE (CPUAlertLogic.swift holds the rules).
///
/// THE ORDINARY SAMPLE IS ONE SYSCALL: `host_statistics(HOST_CPU_LOAD_INFO)`, cumulative ticks
/// across every core, which walks nothing. The process table is walked only by `unattributed`, and
/// only at the instant a banner is about to go out and the rollup cannot explain the load.
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

    /// The busiest processes whose working directory is in none of `roots`, as shares of the whole
    /// machine, over a two-second window. Own CPU only (not `childTimes`), so a parent is not
    /// charged for children it reaped.
    ///
    /// NAMES, NEVER ARGUMENTS: the executable's display name, the rule `HostHealthProcess` states.
    /// A process whose program cannot be read is named "unknown" rather than guessed at.
    static func unattributed(roots: Set<String>, cores: Int, limit: Int = 2) async -> [CPUAlertCulprit] {
        guard cores > 0 else { return [] }
        let pids = ProcessTree.liveProcesses().map(\.pid)
        let first = ProcessTree.resourceSample(of: pids)
        try? await Task.sleep(for: .seconds(2))
        let second = ProcessTree.resourceSample(of: pids)
        let elapsed = second.at.timeIntervalSince(first.at)
        guard elapsed > 0 else { return [] }
        let ranked = second.times.compactMap { pid, now -> (pid_t, Double)? in
            guard let before = first.times[pid], now >= before else { return nil }
            return (pid, (now - before) / elapsed * 100 / Double(cores))
        }
        .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        var out: [CPUAlertCulprit] = []
        for (pid, share) in ranked.prefix(5) {
            if let dir = MachineLoadRollup.workingDirectory(of: pid),
               MachineLoadRollup.project(of: dir, roots: roots) != nil { continue }
            let name = ProcessTree.executablePath(of: pid)
                .flatMap { ProcessTree.displayName(forPath: $0) } ?? "unknown"
            out.append(CPUAlertCulprit(name: name, percent: share))
            if out.count == limit { break }
        }
        return out
    }
}
