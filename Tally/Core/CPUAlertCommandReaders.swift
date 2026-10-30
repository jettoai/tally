import Darwin
import Foundation

/// WHAT STARTED THE PROCESSES BEHIND A CPU BANNER: their argument vectors and parent chains, read
/// once when a banner goes out and written to `cpu-alert-commands.log` (CPUAlertCommandLog.swift
/// states the file's rules). This is the only reader that touches arguments; CPUAlertReaders.swift
/// stays names-only. Every argument vector goes through `CPUAlertCommandMask` before it leaves this
/// file, and nothing here prints, logs or reports.
enum CPUAlertCommandReaders {

    /// The arguments of `pid`, the environment block of the same sysctl left unread. Nil when the
    /// process is gone or the kernel refuses (an Apple platform binary).
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 0 else { return nil }
        return CPUAlertCommandMask.arguments(procargs: Data(buffer.prefix(size)))
    }

    /// Writes the banner's block. Called off the main actor, inside the announcing branch, beside
    /// the scan it reads.
    static func write(_ scan: CPUAlertScan, event: CPUAlertEvent, busy: Double, cores: Int,
                      roots: Set<String>, home: String, isCheckout: (String) -> Bool,
                      displayName: (String) -> String?, browsers: Set<String>, now: Date) {
        let top = CPUAlertCommandLog.top(scan, busy: busy, roots: roots, home: home, isCheckout: isCheckout,
                                         displayName: displayName, browsers: browsers)
        let parents = Dictionary(scan.processes.map { ($0.pid, $0.parent) }, uniquingKeysWith: { a, _ in a })
        let known = Dictionary(scan.processes.map { ($0.pid, $0.executablePath) }, uniquingKeysWith: { a, _ in a })
        func name(_ pid: Int32) -> String? {
            (known[pid].flatMap { $0 } ?? ProcessTree.executablePath(of: pid)).flatMap(displayName)
        }
        let records = top.enumerated().map { rank, entry -> CPUAlertCommandRecord in
            let pid = entry.work.pid
            let argv = arguments(of: pid).map { CPUAlertCommandLog.argvField($0, home: home) } ?? "<unreadable>"
            var origin: String?
            var cursor = entry.work.parent
            var seen: Set<Int32> = [pid]
            for _ in 0..<CPUAlertLogic.maxAncestors {
                guard cursor > 1, seen.insert(cursor).inserted else { break }
                if let command = arguments(of: cursor).flatMap(CPUAlertCommandMask.shellCommand(in:)) {
                    origin = CPUAlertCommandLog.argvField([command], home: home)
                    break
                }
                guard let up = parents[cursor] else { break }
                cursor = up
            }
            return CPUAlertCommandRecord(
                rank: rank + 1, pid: pid, share: entry.share, group: entry.group, category: entry.category,
                chain: CPUAlertCommandLog.chain(of: pid, parent: { parents[$0] }, name: name),
                origin: origin, argv: argv)
        }
        guard !records.isEmpty else { return }
        CPUAlertCommandLog.append(
            CPUAlertCommandLog.block(event, busy: busy, cores: cores, records: records, now: now),
            to: cpuAlertCommandsFile)
    }
}
