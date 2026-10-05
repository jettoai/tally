import Foundation

// The whole-machine breakdown behind the CPU banner (Tally/Core/CPUAlertBreakdown.swift), driven
// with fixtures. Uses main.swift's `expect`, `L` and `t0`.

func runBreakdownChecks() {

    let bHome = "/Users/a"
    let ws = "/Users/a/workspace"
    let bRoots: Set<String> = ["\(ws)/onemark", "/Users/a/.claude", "\(ws)/geo", "\(ws)/jetto/tally",
                               "\(ws)/web", "\(ws)/baton", "\(ws)/finance", "\(ws)/bigdata"]
    let bCheckouts: Set<String> = ["\(ws)/voice"]
    func bIsCheckout(_ dir: String) -> Bool { bCheckouts.contains(dir) || bRoots.contains(dir) }
    func bName(_ path: String) -> String? { (path as NSString).lastPathComponent }
    func work(_ pid: Int32, _ seconds: Double, cwd: String?, path: String? = nil,
              parent: Int32 = 1) -> CPUAlertProcessWork {
        CPUAlertProcessWork(pid: pid, parent: parent, seconds: seconds, cwd: cwd, executablePath: path)
    }
    func breakdown(_ scan: CPUAlertScan, busy: Double = 100) -> [CPUAlertCulprit] {
        L.breakdown(scan, busy: busy, roots: bRoots, home: bHome, isCheckout: bIsCheckout, displayName: bName)
    }
    func bannerSum(_ b: CPUAlertBanner) -> Int {
        b.named.reduce(0) { $0 + Int($1.percent.rounded()) } + b.otherProjects + b.other
    }
    let claudeBin = "/Users/a/.local/share/claude/versions/2.1.300"
    let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/"
        + "Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    let vm = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
        + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

    // T18 the 21:52 crossing replayed (cpu=100 cores=16, the banner read onemark 25, .claude 7, geo 6
    // and left 62% unsaid): 16 cores over 2 s, the session projects, Tally's own usage probe, two
    // Chrome helpers, a VM, a project's reaped tool children, an MCP server at `/` under geo's claude,
    // a stray interpreter, and what no readable process accounts for.
    do {
        let scan = CPUAlertScan(processes: [
            work(100, 8.0, cwd: "\(ws)/onemark", path: claudeBin),
            work(101, 2.24, cwd: "/Users/a/.claude", path: claudeBin),
            work(102, 1.92, cwd: "\(ws)/geo", path: claudeBin),
            work(103, 1.6, cwd: "\(ws)/jetto/tally/Tally", path: claudeBin),
            work(104, 1.28, cwd: "\(ws)/web", path: "/opt/homebrew/bin/node"),
            work(105, 0.96, cwd: "\(ws)/baton", path: claudeBin),
            work(106, 0.64, cwd: "\(ws)/finance/engine", path: "/usr/bin/python3"),
            work(107, 2.9, cwd: "/Users/a/.tally/probe", path: claudeBin),
            work(108, 0.65, cwd: "/", path: helper),
            work(109, 0.65, cwd: "/", path: helper),
            work(110, 1.0, cwd: "/", path: vm),
            work(111, 4.0, cwd: "\(ws)/bigdata", path: claudeBin),
            work(112, 2.0, cwd: "/", path: "/opt/homebrew/bin/node", parent: 102),
            work(113, 0.3, cwd: "/tmp", path: "/usr/bin/python3"),
            work(1, 0, cwd: "/", path: "/sbin/launchd", parent: 0),
        ], busySeconds: 32)
        let groups = breakdown(scan)
        let banner = L.banner(groups, busy: 100)
        let total = groups.reduce(0) { $0 + $1.percent }
        print("T18 banner: " + banner.named.map { "\($0.name):\(Int($0.percent.rounded()))" }.joined(separator: ",")
              + " otherProjects:\(banner.otherProjects) other:\(banner.other)")
        expect(abs(total - 100) < 0.01, "T18 the groups sum to the title's CPU")
        expect((99...101).contains(bannerSum(banner)), "T18 the banner's names and its two sums add up to 100 +/- 1")
        expect(banner.named.first == groups.first, "T18 the first name is the largest group")
        expect(groups.contains { $0.kind == .system && $0.name == "System" }, "T18 the unaccounted remainder is the system")
        expect(groups.contains { $0.kind == .tally && $0.name == "Tally" }
               && !groups.contains { $0.name == "claude" || $0.name == "2.1.300" },
               "T18 Tally's usage probe is Tally, nothing is called claude")
        expect(groups.first { $0.name == "geo" }.map { abs($0.percent - 12.25) < 0.01 } ?? false,
               "T18 the MCP server at / is charged to geo through its parent")
        expect(groups.filter { $0.name == "Google Chrome" }.count == 1, "T18 Chrome's helpers are one app")
    }

    // T19 the processes account for more than the ticks say (36 s against 30): scaled, never negative
    do {
        let groups = breakdown(CPUAlertScan(processes: [work(1, 20, cwd: "\(ws)/onemark"),
                                                        work(2, 16, cwd: "\(ws)/geo")], busySeconds: 30))
        expect(groups.allSatisfy { $0.percent >= 0 } && abs(groups.reduce(0) { $0 + $1.percent } - 100) < 0.01,
               "T19 scaled to the title's CPU")
        expect(!groups.contains { $0.kind == .system }, "T19 no system remainder when nothing is unaccounted")
        let banner = L.banner(groups, busy: 100)
        expect(banner.other == 0 && bannerSum(banner) == 100, "T19 no negative other")
    }

    // T20 windowWork: own deltas, reaped children net of the departed child's life before the window,
    // births inside the window counted whole, a reused pid treated as new, an unread elder ignored.
    do {
        let first: [Int32: CPUAlertPidReading] = [
            10: CPUAlertPidReading(parent: 1, startedAt: 100, own: 5, children: 1),
            11: CPUAlertPidReading(parent: 10, startedAt: 200, own: 0.8, children: 0.2),
            13: CPUAlertPidReading(parent: 1, startedAt: 100, own: 1, children: 0),
        ]
        let second: [Int32: CPUAlertPidReading] = [
            10: CPUAlertPidReading(parent: 1, startedAt: 100, own: 6, children: 4),
            12: CPUAlertPidReading(parent: 10, startedAt: 2000, own: 0.5, children: 0),
            13: CPUAlertPidReading(parent: 1, startedAt: 5000, own: 0.4, children: 0),
            14: CPUAlertPidReading(parent: 1, startedAt: 500, own: 9, children: 0),
        ]
        let w = L.windowWork(first: first, second: second, windowStart: 1000)
        expect(abs((w[10] ?? 0) - 3.0) < 1e-9, "T20 own delta plus reaped growth less the departed child's prior life")
        expect(w[12] == 0.5, "T20 a pid born inside the window counts whole")
        expect(w[13] == 0.4, "T20 a reused pid is a new process")
        expect(w[14] == nil && w[11] == nil, "T20 an elder unread at the start and a departed pid count nothing")
    }

    // T20b a chain reaped inside the window (A reaps B after B reaped C, C reaped D): the kernel folds
    // every generation's whole life into A, so each departed pid's prior life is settled on its
    // nearest live ancestor, not on a parent that left too.
    do {
        let first: [Int32: CPUAlertPidReading] = [
            100: CPUAlertPidReading(parent: 1, startedAt: 100, own: 1, children: 0),
            101: CPUAlertPidReading(parent: 100, startedAt: 200, own: 0, children: 0),
            102: CPUAlertPidReading(parent: 101, startedAt: 300, own: 80, children: 0),
            103: CPUAlertPidReading(parent: 102, startedAt: 400, own: 10, children: 0),
        ]
        func a(children: Double) -> Double {
            let second: [Int32: CPUAlertPidReading] = [100: CPUAlertPidReading(parent: 1, startedAt: 100, own: 1, children: children)]
            return L.windowWork(first: first, second: second, windowStart: 1000)[100] ?? -1
        }
        expect(abs(a(children: 90)) < 1e-9, "T20b no work inside the window: the reaped chain's prior life is not new")
        expect(abs(a(children: 92.5) - 2.5) < 1e-9, "T20b only the chain's work inside the window counts")
    }

    // T21 owner, rule by rule
    do {
        func own(_ list: [CPUAlertProcessWork], roots: Set<String> = bRoots) -> (CPUAlertKind, String) {
            let byPid = Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0) })
            let r = L.owner(of: list[0].pid, in: byPid, roots: roots, home: bHome,
                            isCheckout: bIsCheckout, displayName: bName)
            return (r.kind, r.name)
        }
        expect(own([work(1, 1, cwd: "/Users/a/.tally/probe", path: claudeBin)]) == (.tally, "Tally"),
               "T21 Tally's probe directory is Tally")
        expect(own([work(1, 1, cwd: "/", path: "/Applications/Tally.app/Contents/MacOS/Tally")]) == (.tally, "Tally"),
               "T21 the Tally bundle is Tally")
        expect(own([work(1, 1, cwd: "\(ws)/baton/live/src")], roots: ["\(ws)/baton", "\(ws)/baton/live"])
               == (.project, "live"), "T21 the longer of two nested roots wins")
        expect(own([work(1, 1, cwd: "\(ws)/voice/src", path: "/opt/homebrew/bin/node")]) == (.project, "voice"),
               "T21 a checkout with no session is a project")
        expect(own([work(2, 1, cwd: "/", path: "/opt/homebrew/bin/node", parent: 3),
                    work(3, 0, cwd: "\(ws)/geo", path: claudeBin)]) == (.project, "geo"),
               "T21 a process at / is charged through its parent")
        expect(own([work(50, 1, cwd: "/", path: "/usr/bin/python3", parent: 51),
                    work(51, 0, cwd: "/", path: "/usr/bin/python3", parent: 50)]) == (.process, "python3"),
               "T21 a parent cycle ends and falls to the path rules")
        expect(own([work(1, 1, cwd: "/", path: vm)]) == (.system, "System"), "T21 /System is the system")
        expect(own([work(1, 1, cwd: "/", path: helper)]) == (.app, "Google Chrome"), "T21 a helper is its outer app")
        expect(own([work(1, 1, cwd: "/tmp", path: "/usr/bin/python3")]) == (.process, "python3"),
               "T21 /usr/bin/python3 outside any project is python3, not the system")
        expect(own([work(1, 1, cwd: nil, path: nil)]) == (.process, "unknown"), "T21 an unreadable process is unknown")
    }

    // T22 the system is the largest share: it leads the banner
    do {
        let groups = breakdown(CPUAlertScan(processes: [work(1, 6, cwd: "\(ws)/onemark")], busySeconds: 32))
        let banner = L.banner(groups, busy: 100)
        expect(banner.named.first?.kind == .system && bannerSum(banner) == 100, "T22 the system leads when it is largest")
    }

    // T23 rounding up three halves runs one over at most, never a negative other
    do {
        let banner = L.banner([CPUAlertCulprit(name: "a", percent: 33.5), CPUAlertCulprit(name: "b", percent: 33.5),
                               CPUAlertCulprit(name: "c", percent: 33.0)], busy: 100)
        expect(banner.other == 0 && bannerSum(banner) == 100, "T23 other clamps at zero, the sum is the title")
        func parts(_ percents: [Double], project: Double, busy: Double) -> CPUAlertBanner {
            L.banner(percents.enumerated().map { CPUAlertCulprit(name: "n\($0.offset)", percent: $0.element) }
                     + [CPUAlertCulprit(name: "p", percent: project, kind: .project)], busy: busy)
        }
        let halves = parts([26.5, 24.5, 24.5], project: 24.5, busy: 100)
        expect(bannerSum(halves) == 100 && halves.other == 0, "T23 four halves and other projects add up to the title")
        let tenths = parts([24.6, 24.6, 24.6], project: 18.6, busy: 92.4)
        expect(bannerSum(tenths) == 92, "T23 four .6 fractions add up to a fractional title")
        let shares = halves.named.map(\.percent)
        expect(shares == shares.sorted(by: >), "T23 the leader stays the largest share after rounding")
        for busy in stride(from: 90.0, through: 100.0, by: 0.1) {
            for a in stride(from: 5.0, through: 40.0, by: 0.7) {
                let b = parts([a, a * 0.8, a * 0.6], project: a * 0.5, busy: busy)
                if bannerSum(b) != Int(busy.rounded()) {
                    expect(false, "T23 sweep: busy \(busy) lead \(a) sums to \(bannerSum(b))")
                }
            }
        }
    }

    // T24 one group: nothing else to print
    do {
        let banner = L.banner([CPUAlertCulprit(name: "a", percent: 100)], busy: 100)
        expect(banner.otherProjects == 0 && banner.other == 0 && banner.named.count == 1, "T24 a single group has no rest")
    }

    // T25 the log line carries the rest
    do {
        let named = [CPUAlertCulprit(name: "onemark", percent: 25), CPUAlertCulprit(name: "System", percent: 15, kind: .system)]
        let line = L.logLine(.alarm(silence: nil), busy: 100, cores: 16, culprits: named, rest: (21, 30), now: t0)
        expect(line.contains(" top=onemark:25,System:15 rest=projects:21,other:30\n"), "T25 rest after top")
        let bare = L.logLine(.alarm(silence: nil), busy: 100, cores: 16, culprits: named, now: t0)
        expect(!bare.contains("rest="), "T25 no rest when both are zero")
        let half = L.logLine(.clear, busy: 40, cores: 16, culprits: [], rest: (0, 5), now: t0)
        expect(half.hasSuffix(" rest=other:5\n"), "T25 a zero part is left out")
    }
}
