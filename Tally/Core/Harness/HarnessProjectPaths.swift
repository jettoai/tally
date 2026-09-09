import Foundation

enum HarnessProjectPaths {
    static func visible(_ location: HarnessLocation, links: [HarnessLink]) throws -> [String] {
        guard location.scope == "project", let root = location.project else { return [] }
        var paths = [location.targetRoot + "/hooks.json", location.targetSkills + "/tally-harness/SKILL.md"]
            + links.map(\.target)
        if HarnessIO.canonical(location.targetInstructions) != HarnessIO.canonical(location.sourceInstructions) {
            paths.append(location.targetInstructions)
        }
        var visible: [String] = []
        for path in Set(paths).sorted() {
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
