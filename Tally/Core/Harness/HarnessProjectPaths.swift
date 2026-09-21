import Foundation

enum HarnessProjectPaths {
    static func visible(_ location: HarnessLocation, links: [HarnessLink], includesHooks: Bool) throws -> [String] {
        guard location.scope == "project", let root = location.project else { return [] }
        var paths = [location.targetSkills + "/tally-harness/SKILL.md"]
            + links.map(\.target)
        if includesHooks { paths.append(location.targetRoot + "/hooks.json") }
        if HarnessIO.canonical(location.targetInstructions) != HarnessIO.canonical(location.sourceInstructions) {
            paths.append(location.targetInstructions)
        }
        return try notIgnored(Set(paths).sorted(), root: root)
    }

    /// Migration change paths are already the exact write targets. Hook files may be
    /// canonical shared targets, while skill links must retain their logical paths.
    static func visible(_ location: HarnessLocation, changedPaths: Set<String>) throws -> [String] {
        guard location.scope == "project", let root = location.project else { return [] }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return try notIgnored(changedPaths.sorted().filter { $0 == root || $0.hasPrefix(prefix) },
                              root: root)
    }

    /// The paths this checkout would track, asked one at a time so an unreadable checkout fails the
    /// whole plan rather than silently reporting fewer git-visible writes than there are.
    private static func notIgnored(_ paths: [String], root: String) throws -> [String] {
        var visible: [String] = []
        for path in paths {
            let result = try HarnessProcess.run(executable: "/usr/bin/git",
                arguments: ["check-ignore", "--quiet", "--", path], input: Data(), cwd: root,
                environment: ProcessInfo.processInfo.environment, timeout: 5)
            guard result.failure == nil, [0, 1].contains(result.code) else {
                throw HarnessError("Cannot inspect project git visibility. Use an accessible git checkout and retry the plan.")
            }
            if result.code == 1 { visible.append(path) }
        }
        return visible
    }
}
