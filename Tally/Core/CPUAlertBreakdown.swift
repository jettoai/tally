import Foundation

// WHERE ALL OF A FULL CPU WENT, so the banner's names and its "other" add up to the figure in its
// title. The rollup names projects with sessions; this names everything: projects by working
// directory or by an ancestor's, Tally's own work, the OS, apps by bundle, the rest by executable,
// and what no readable process accounts for (the kernel, other users) as the system.
//
// PURE: the readings come from `CPUAlertReaders.scan`, and the two lookups that live in
// Darwin-heavy files (`ProcessTree.displayName`) are passed in so the harness compiles this alone.

enum CPUAlertKind: String, Equatable, Sendable {
    case project, system, tally, app, process, vm, browser
}

/// What a project's or an executable's work is, for the banner's category word: a process holding
/// a TCP LISTEN socket is a service (a dev server), anything else is a command that ran long.
enum CPUAlertRole: String, Equatable, Sendable {
    case service, command
}

/// One process over the scan window.
struct CPUAlertProcessWork: Equatable, Sendable {
    var pid: Int32
    var parent: Int32
    /// CPU seconds inside the window, own plus reaped (`CPUAlertLogic.windowWork`).
    var seconds: Double
    var cwd: String?
    var executablePath: String?
    /// The executable of the process macOS holds responsible for this one (a virtual machine's is
    /// the app that started it), read only for OS executables that worked; nil when the kernel
    /// does not say (B-2238).
    var responsiblePath: String? = nil
    /// Holds a TCP LISTEN socket; read only for processes that worked outside the OS.
    var listening: Bool = false
}

struct CPUAlertScan: Equatable, Sendable {
    /// Every live process at the window's end, working or not (ancestors are looked up here).
    var processes: [CPUAlertProcessWork]
    /// Busy CPU seconds across all cores over the window, from the host ticks.
    var busySeconds: Double
}

/// What the banner prints: up to five names, then the rest in two sums.
struct CPUAlertBanner: Equatable, Sendable {
    var named: [CPUAlertCulprit]
    var otherProjects: Int
    var other: Int
}

/// One pid at one end of the window, as the readers saw it.
struct CPUAlertPidReading: Equatable, Sendable {
    var parent: Int32
    /// Microseconds since the epoch (`ProcessIdentity.startedAt`).
    var startedAt: Int64
    var own: Double
    var children: Double
}

extension CPUAlertLogic {
    static let tallyBundles = ["/Tally.app/", "/Tally Dev.app/"]
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
    static let maxAncestors = 32
    /// Scratch locations: a checkout made here (a pre-push hook's `git init` in `mktemp -d`) is a
    /// throwaway, so the process is charged to a known project up its parent chain first.
    static let tempPrefixes = ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"]

    /// Seconds each pid worked inside the window. Own time is the difference across the window, or
    /// everything when the pid was born inside it (`windowStart`, microseconds like `startedAt`).
    /// Reaped time is the growth of the pid's children counter less what its children that left
    /// during the window had already burned when it opened: their whole life lands in the counter
    /// at once, and only the part inside the window is new work. A child whose parent left too is
    /// settled on the nearest ancestor still alive, the one whose counter took the whole chain. A pid
    /// read at neither end, or born before the window but unread at its start, counts nothing (the
    /// residual takes it).
    static func windowWork(first: [Int32: CPUAlertPidReading], second: [Int32: CPUAlertPidReading],
                           windowStart: Int64) -> [Int32: Double] {
        var departedByParent: [Int32: Double] = [:]
        func departed(_ pid: Int32) -> Bool {
            guard let before = first[pid] else { return false }
            return second[pid]?.startedAt != before.startedAt
        }
        for (pid, before) in first where departed(pid) {
            // ponytail: assumes each parent reaped its child before leaving; a child orphaned to
            // launchd first is still charged to the live ancestor, so that ancestor reads low.
            var collector = before.parent
            for _ in 0..<maxAncestors where departed(collector) {
                collector = first[collector]?.parent ?? collector
            }
            departedByParent[collector, default: 0] += before.own + before.children
        }
        var out: [Int32: Double] = [:]
        for (pid, after) in second {
            if let before = first[pid], before.startedAt == after.startedAt {
                let own = max(0, after.own - before.own)
                let reaped = max(0, after.children - before.children - (departedByParent[pid] ?? 0))
                out[pid] = own + reaped
            } else if after.startedAt >= windowStart {
                out[pid] = after.own + after.children
            }
        }
        return out
    }

    /// The longest root `directory` is inside, matched on path components, empty roots skipped:
    /// the rule `MachineLoadRollup.project(of:roots:)` states, spelled here so the harness needs
    /// no Darwin.
    static func root(of directory: String, roots: Set<String>) -> String? {
        roots.filter { !$0.isEmpty && (directory == $0 || directory.hasPrefix($0 + "/")) }
            .max { $0.count < $1.count }
    }

    /// Who one process's work belongs to, first rule that holds: Tally's own (cwd under `~/.tally`
    /// or running from a Tally bundle); a session root; a checkout; the same three asked of each
    /// ancestor; the first checkout under a scratch location (`tempPrefixes`), which yields to any
    /// of the above up the chain; a virtual machine by path; the OS by path; an app by its outermost
    /// bundle (a browser when `browsers` names it); else the executable's name. A virtual machine is
    /// named for the app whose process macOS holds responsible for it or whose bundle it runs from:
    /// Docker's lives under /System and is Docker's work, whoever's app it is.
    static func owner(of pid: Int32, in byPid: [Int32: CPUAlertProcessWork], roots: Set<String>,
                      home: String, isCheckout: (String) -> Bool,
                      displayName: (String) -> String?,
                      browsers: Set<String> = []) -> (kind: CPUAlertKind, name: String) {
        func project(_ work: CPUAlertProcessWork) -> (kind: CPUAlertKind, name: String)? {
            guard let cwd = work.cwd else { return nil }
            if cwd == home + "/.tally" || cwd.hasPrefix(home + "/.tally/") { return (.tally, "Tally") }
            if let root = root(of: cwd, roots: roots) {
                return (.project, (root as NSString).lastPathComponent)
            }
            let checkout = processName(cwd: cwd, executable: "", home: home, isCheckout: isCheckout)
            return checkout.isEmpty ? nil : (.project, checkout)
        }
        guard let work = byPid[pid] else { return (.process, "unknown") }
        let path = work.executablePath ?? ""
        if tallyBundles.contains(where: path.contains) { return (.tally, "Tally") }
        var scratch: (kind: CPUAlertKind, name: String)?
        func settle(_ work: CPUAlertProcessWork) -> (kind: CPUAlertKind, name: String)? {
            guard let hit = project(work) else { return nil }
            let cwd = work.cwd ?? ""
            let isScratchCheckout = root(of: cwd, roots: roots) == nil
                && tempPrefixes.contains(where: cwd.hasPrefix)
            guard isScratchCheckout else { return hit }
            if scratch == nil { scratch = hit }
            return nil
        }
        if let hit = settle(work) { return hit }
        var cursor = work.parent
        var seen: Set<Int32> = [pid]
        for _ in 0..<maxAncestors {
            guard cursor > 1, seen.insert(cursor).inserted, let up = byPid[cursor] else { break }
            if let hit = settle(up) { return hit }
            cursor = up.parent
        }
        if let scratch { return scratch }
        if isVirtualMachine(path) {
            return (.vm, work.responsiblePath.flatMap(appName) ?? appName(of: path) ?? "Virtual machine")
        }
        if systemPrefixes.contains(where: path.hasPrefix) {
            if let name = work.responsiblePath.flatMap(appName) { return (.app, name) }
            return (.system, "System")
        }
        if let name = appName(of: path) { return (browsers.contains(name) ? .browser : .app, name) }
        return (.process, path.isEmpty ? "unknown" : displayName(path) ?? "unknown")
    }

    /// Apple's hypervisor framework, and the other hypervisors' executables by name. A hypervisor
    /// outside this list reads as an app or a process (a named blind spot).
    static let vmExecutables = ["prl_vm_app", "vmware-vmx", "VBoxHeadless", "VirtualBoxVM"]
    static func isVirtualMachine(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return path.contains("/Virtualization.framework/") || vmExecutables.contains(name)
            || name.hasPrefix("qemu-system-")
    }

    /// The outermost app bundle an executable is inside, by name, nil when it is in none.
    static func appName(of path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        let name = (String(path[..<range.lowerBound]) as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Every group's share of `busy` (the banner's figure), largest first; the unaccounted
    /// remainder joins the system. Sums to `busy`: the larger of the ticks' busy seconds and the
    /// processes' sum is the denominator, so a window where the two disagree scales, never goes
    /// negative.
    static func breakdown(_ scan: CPUAlertScan, busy: Double, roots: Set<String>, home: String,
                          isCheckout: (String) -> Bool,
                          displayName: (String) -> String?,
                          browsers: Set<String> = []) -> [CPUAlertCulprit] {
        let byPid = Dictionary(scan.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        // The role splits one project's dev server from its commands into two groups: a partition,
        // so the sum is unchanged.
        struct Key: Hashable { var kind: CPUAlertKind; var name: String; var role: CPUAlertRole? }
        var seconds: [Key: Double] = [:]
        var accounted = 0.0
        for work in scan.processes where work.seconds > 0 {
            let (kind, name) = owner(of: work.pid, in: byPid, roots: roots, home: home,
                                     isCheckout: isCheckout, displayName: displayName, browsers: browsers)
            seconds[Key(kind: kind, name: name, role: role(kind, work)), default: 0] += work.seconds
            accounted += work.seconds
        }
        let residual = scan.busySeconds - accounted
        if residual > 0 { seconds[Key(kind: .system, name: "System", role: nil), default: 0] += residual }
        let denominator = max(scan.busySeconds, accounted)
        guard denominator > 0 else { return [] }
        return ranked(seconds.map {
            CPUAlertCulprit(name: $0.key.name, percent: $0.value / denominator * busy, kind: $0.key.kind,
                            role: $0.key.role)
        })
    }

    /// Only a project's or a bare executable's work is a service or a command; the other kinds
    /// say what they are.
    static func role(_ kind: CPUAlertKind, _ work: CPUAlertProcessWork) -> CPUAlertRole? {
        guard kind == .project || kind == .process else { return nil }
        return work.listening ? .service : .command
    }

    /// The five names and what the rest adds up to, in whole percents that sum to `busy` rounded:
    /// each part takes its floor and the points left go to the largest fractions (largest
    /// remainder), so no set of parts rounds past the title. Named shares come back whole.
    static func banner(_ groups: [CPUAlertCulprit], busy: Double) -> CPUAlertBanner {
        let all = ranked(groups)
        var named = Array(all.filter { $0.percent >= minimumShare }.prefix(maxNames))
        let projects = all.filter { culprit in
            culprit.kind == .project && !named.contains(culprit)
        }.reduce(0) { $0 + $1.percent }
        let exact = named.map(\.percent) + [projects]
        let parts = wholeParts(exact + [max(0, busy - exact.reduce(0, +))], total: Int(busy.rounded()))
        for index in named.indices { named[index].percent = Double(parts[index]) }
        return CPUAlertBanner(named: named, otherProjects: parts[named.count], other: parts[named.count + 1])
    }

    /// Whole numbers, one per share, that add up to `total`: floors first, then a point to each of
    /// the largest fractions (taken back from the smallest when the shares overrun the total).
    static func wholeParts(_ shares: [Double], total: Int) -> [Int] {
        var parts = shares.map { Int($0.rounded(.down)) }
        let fraction = shares.indices.map { shares[$0] - Double(parts[$0]) }
        let byFraction = shares.indices.sorted { fraction[$0] == fraction[$1] ? $0 < $1 : fraction[$0] > fraction[$1] }
        var left = total - parts.reduce(0, +)
        for index in byFraction where left > 0 { parts[index] += 1; left -= 1 }
        for index in byFraction.reversed() where left < 0 && parts[index] > 0 {
            let take = min(parts[index], -left)
            parts[index] -= take
            left += take
        }
        return parts
    }
}
