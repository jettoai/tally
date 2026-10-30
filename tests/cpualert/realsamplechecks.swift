import Foundation

// The banner replayed on a real machine sample: the 15 busiest processes read at 11:52 to 11:54 on
// 2026-10-30 (ps for CPU and path, lsof for the working directory), 16 cores, a 2 s window. The
// owner's question was which project is eating what, and of what kind. Uses main.swift's `expect`, `L`.

func runRealSampleChecks() {
    let ws = "/Users/albertliu/workspace"
    let home = "/Users/albertliu"
    let roots: Set<String> = ["\(ws)/jetto/baton", "\(ws)/jetto/baton-live", "\(ws)/taiwanbigdata/finance",
                              "\(ws)/jetto/crm", "\(ws)/social", "\(home)/.claude", "\(ws)/jetto/tally",
                              "\(ws)/taiwanbigdata/geo"]
    let python = "/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/"
        + "Resources/Python.app/Contents/MacOS/Python"
    let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/"
        + "Versions/156.0.8078.74/Helpers/Google Chrome Helper (Aperitif Renderer).app/Contents/MacOS/"
        + "Google Chrome Helper (Aperitif Renderer)"
    let parallels = "/Applications/Parallels Desktop.app/Contents/MacOS/prl_vm_app"
    let appleVM = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
        + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
    // (pid, cpu% of one core, executable, cwd, listening)
    let rows: [(Int32, Double, String, String?, Bool)] = [
        (38090, 111.7, python, "\(ws)/jetto/baton", false),
        (12918, 97.0, "/Applications/Tally.app/Contents/Helpers/swift/tally", "\(ws)/taiwanbigdata/geo", false),
        (54739, 86.5, python, "\(ws)/taiwanbigdata/finance", false),
        (54895, 71.3, "/usr/bin/grep", nil, false),
        (34889, 70.1, "/usr/bin/grep", "\(ws)/jetto/crm", false),
        (52539, 63.5, python, "\(ws)/jetto/baton-live/server", true),
        (32172, 62.6, parallels, "/", false),
        (52159, 55.8, python, "\(ws)/social/brands/taiwanbigdata/posts/2026-10-30-us-datacenter-moratorium", false),
        (172, 52.5, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", nil, false),
        (47798, 42.4, python, "\(home)/.claude", false),
        (1672, 41.8, appleVM, "/", false),
        (24578, 37.4, "/Applications/Jetto.app/Contents/MacOS/Jetto", "/", false),
        (57722, 31.3, "/Applications/Tally.app/Contents/MacOS/Tally", "/", false),
        (33080, 26.8, chromeHelper, "/", false),
        (95535, 22.8, "\(home)/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", "\(ws)/jetto/tally", false),
    ]
    func fixture(browsers: Set<String> = ["Google Chrome"]) -> (scan: CPUAlertScan, groups: [CPUAlertCulprit], banner: CPUAlertBanner) {
        let scan = CPUAlertScan(processes: rows.map {
            CPUAlertProcessWork(pid: $0.0, parent: 1, seconds: $0.1 / 100 * 2, cwd: $0.3, executablePath: $0.2,
                                listening: $0.4)
        }, busySeconds: rows.reduce(0) { $0 + $1.1 } / 100 * 2)
        let groups = L.breakdown(scan, busy: 95, roots: roots, home: home,
                                 isCheckout: { roots.contains($0) }, displayName: { ($0 as NSString).lastPathComponent },
                                 browsers: browsers)
        return (scan, groups, L.banner(groups, busy: 95))
    }

    // R1 the five names, each with its kind, and the whole adds up to the title's 95
    let (_, groups, banner) = fixture()
    print("R1 banner: " + banner.named.map { "\($0.name):\(Int($0.percent)):\($0.category)" }.joined(separator: ",")
          + " otherProjects:\(banner.otherProjects) other:\(banner.other)")
    expect(banner.named.map(\.name) == ["Tally", "baton", "finance", "grep", "crm"],
           "R1 the five largest groups are named, in order")
    expect(banner.named.map(\.category) == ["tally", "command", "command", "command", "command"],
           "R1 each name carries its category")
    expect(banner.named.map(\.percent) == [14, 12, 9, 8, 8], "R1 the named shares are whole percents")
    expect(banner.otherProjects == 20 && banner.other == 24, "R1 the rest is the other projects and the other, whole")
    expect(banner.named.reduce(0) { $0 + Int($1.percent) } + banner.otherProjects + banner.other == 95,
           "R1 five names and two sums add up to the title's 95")

    // R2 every group's kind on the same sample
    func group(_ name: String, _ kind: CPUAlertKind) -> CPUAlertCulprit? { groups.first { $0.name == name && $0.kind == kind } }
    expect(group("baton-live", .project)?.role == .service, "R2 the dev server holding a listen socket is a service")
    expect(group("Parallels Desktop", .vm) != nil && group("Virtual machine", .vm) != nil,
           "R2 both virtual machines are VMs, the unclaimed one by the framework path")
    expect(group("System", .system) != nil && group("Jetto", .app) != nil && group("Google Chrome", .browser) != nil,
           "R2 the OS, an app and the browser each have a kind")
    expect(abs(groups.reduce(0) { $0 + $1.percent } - 95) < 0.01, "R2 the groups sum to the title")

    // R3 no browser list: Chrome falls back to an app
    expect(fixture(browsers: []).groups.contains { $0.name == "Google Chrome" && $0.kind == .app },
           "R3 without the OS's browser list Chrome is an app")

    // R4 the sum holds across the whole range of the title, with five names
    for busy in stride(from: 90.0, through: 100.0, by: 0.1) {
        let scan = fixture().scan
        let b = L.banner(L.breakdown(scan, busy: busy, roots: roots, home: home, isCheckout: { roots.contains($0) },
                                     displayName: { ($0 as NSString).lastPathComponent },
                                     browsers: ["Google Chrome"]), busy: busy)
        let sum = b.named.reduce(0) { $0 + Int($1.percent) } + b.otherProjects + b.other
        if sum != Int(busy.rounded()) { expect(false, "R4 sweep: busy \(busy) sums to \(sum)") }
    }
}
