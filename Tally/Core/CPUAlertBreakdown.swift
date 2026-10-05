import Foundation

// WHERE ALL OF A FULL CPU WENT, so the banner's names and its "other" add up to the figure in its
// title. The rollup names projects with sessions; this names everything: projects by working
// directory or by an ancestor's, Tally's own work, the OS, apps by bundle, the rest by executable,
// and what no readable process accounts for (the kernel, other users) as the system.
//
// PURE: the readings come from `CPUAlertReaders.scan`, and the two lookups that live in
// Darwin-heavy files (`ProcessTree.displayName`) are passed in so the harness compiles this alone.

enum CPUAlertKind: String, Equatable, Sendable {
    case project, system, tally, app, process
}

/// One process over the scan window.
struct CPUAlertProcessWork: Equatable, Sendable {
    var pid: Int32
    var parent: Int32
    /// CPU seconds inside the window, own plus reaped (`CPUAlertLogic.windowWork`).
    var seconds: Double
    var cwd: String?
    var executablePath: String?
}

struct CPUAlertScan: Equatable, Sendable {
    /// Every live process at the window's end, working or not (ancestors are looked up here).
    var processes: [CPUAlertProcessWork]
    /// Busy CPU seconds across all cores over the window, from the host ticks.
    var busySeconds: Double
}

/// What the banner prints: up to three names, then the rest in two sums.
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

    /// Seconds each pid worked inside the window. Own time is the difference across the window, or
    /// everything when the pid was born inside it (`windowStart`, microseconds like `startedAt`).
    /// Reaped time is the growth of the pid's children counter less what its children that left
    /// during the window had already burned when it opened: their whole life lands in the counter
    /// at once, and only the part inside the window is new work. A pid read at neither end, or born
    /// before the window but unread at its start, counts nothing (the residual takes it).
    static func windowWork(first: [Int32: CPUAlertPidReading], second: [Int32: CPUAlertPidReading],
                           windowStart: Int64) -> [Int32: Double] {
        var departedByParent: [Int32: Double] = [:]
        for (pid, before) in first where second[pid]?.startedAt != before.startedAt {
            departedByParent[before.parent, default: 0] += before.own + before.children
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
    /// ancestor; the OS by path; an app by its outermost bundle; else the executable's name.
    static func owner(of pid: Int32, in byPid: [Int32: CPUAlertProcessWork], roots: Set<String>,
                      home: String, isCheckout: (String) -> Bool,
                      displayName: (String) -> String?) -> (kind: CPUAlertKind, name: String) {
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
        if let hit = project(work) { return hit }
        var cursor = work.parent
        var seen: Set<Int32> = [pid]
        for _ in 0..<maxAncestors {
            guard cursor > 1, seen.insert(cursor).inserted, let up = byPid[cursor] else { break }
            if let hit = project(up) { return hit }
            cursor = up.parent
        }
        if systemPrefixes.contains(where: path.hasPrefix) { return (.system, "System") }
        if let range = path.range(of: ".app/") {
            let name = (String(path[..<range.lowerBound]) as NSString).lastPathComponent
            if !name.isEmpty { return (.app, name) }
        }
        return (.process, path.isEmpty ? "unknown" : displayName(path) ?? "unknown")
    }

    /// Every group's share of `busy` (the banner's figure), largest first; the unaccounted
    /// remainder joins the system. Sums to `busy`: the larger of the ticks' busy seconds and the
    /// processes' sum is the denominator, so a window where the two disagree scales, never goes
    /// negative.
    static func breakdown(_ scan: CPUAlertScan, busy: Double, roots: Set<String>, home: String,
                          isCheckout: (String) -> Bool,
                          displayName: (String) -> String?) -> [CPUAlertCulprit] {
        let byPid = Dictionary(scan.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        struct Key: Hashable { var kind: CPUAlertKind; var name: String }
        var seconds: [Key: Double] = [:]
        var accounted = 0.0
        for work in scan.processes where work.seconds > 0 {
            let (kind, name) = owner(of: work.pid, in: byPid, roots: roots, home: home,
                                     isCheckout: isCheckout, displayName: displayName)
            seconds[Key(kind: kind, name: name), default: 0] += work.seconds
            accounted += work.seconds
        }
        let residual = scan.busySeconds - accounted
        if residual > 0 { seconds[Key(kind: .system, name: "System"), default: 0] += residual }
        let denominator = max(scan.busySeconds, accounted)
        guard denominator > 0 else { return [] }
        return ranked(seconds.map {
            CPUAlertCulprit(name: $0.key.name, percent: $0.value / denominator * busy, kind: $0.key.kind)
        })
    }

    /// The three names and what the rest adds up to, in whole percents that sum to `busy` rounded
    /// (an `other` that rounding would push below zero reads zero, so the sum can run one over).
    static func banner(_ groups: [CPUAlertCulprit], busy: Double) -> CPUAlertBanner {
        let all = ranked(groups)
        let named = Array(all.filter { $0.percent >= minimumShare }.prefix(maxNames))
        let otherProjects = Int(all.filter { culprit in
            culprit.kind == .project && !named.contains(culprit)
        }.reduce(0) { $0 + $1.percent }.rounded())
        let shown = named.reduce(0) { $0 + Int($1.percent.rounded()) }
        return CPUAlertBanner(named: named, otherProjects: otherProjects,
                              other: max(0, Int(busy.rounded()) - shown - otherProjects))
    }
}
