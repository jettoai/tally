import Foundation

// Groups 10 and 11 of the worktree assertions: the teardown decisions that are pure functions - the
// kill selection, the two path guards, and the transcript sweep over every account home the launch
// side seeds - split out of teardownchecks.swift for file size. Runs as one function that group
// calls, and uses the shared harness main.swift owns (`check`, `tempDir`, `rp`).

func runTeardownPureChecks() {
    // MARK: - 10. Teardown: kill decision (pure)

    check("a claude process inside the worktree is killed",
          shouldKill(name: "claude", cwd: "/a/b/wt", worktreePath: "/a/b/wt"))
    check("a process nested under the worktree is killed",
          shouldKill(name: "fswatch", cwd: "/a/b/wt/sub/dir", worktreePath: "/a/b/wt"))
    check("tally is in the allowlist", shouldKill(name: "tally", cwd: "/a/b/wt", worktreePath: "/a/b/wt"))
    check("a shell is never killed even inside the worktree",
          !shouldKill(name: "zsh", cwd: "/a/b/wt", worktreePath: "/a/b/wt"))
    check("an unrelated binary is not killed", !shouldKill(name: "node", cwd: "/a/b/wt", worktreePath: "/a/b/wt"))
    check("a sibling sharing a path prefix is not a false positive",
          !shouldKill(name: "claude", cwd: "/a/b/wtx", worktreePath: "/a/b/wt"))
    check("a process outside the worktree is not killed",
          !shouldKill(name: "claude", cwd: "/other/place", worktreePath: "/a/b/wt"))

    // The selection fed to the killer, over a scan mixing a worktree's own agents with a shell, an
    // unrelated binary and an outsider. This is the shape of the 2026-07-26 failure: git had let go
    // of the registration while five session processes were still alive, and teardown reported
    // "killed 0" because the scan behind this selection stopped short of them.
    let liveScan = [
        ProcInfo(pid: 101, name: "claude", cwd: "/a/b/wt"),
        ProcInfo(pid: 102, name: "tally", cwd: "/a/b/wt"),
        ProcInfo(pid: 103, name: "claude", cwd: "/a/b/wt/sub/dir"),
        ProcInfo(pid: 104, name: "zsh", cwd: "/a/b/wt"),
        ProcInfo(pid: 105, name: "node", cwd: "/a/b/wt"),
        ProcInfo(pid: 106, name: "claude", cwd: "/a/b/wtx"),
    ]
    check("every agent rooted in the worktree is selected, never zero",
          worktreeProcessesToKill(liveScan, worktreePath: "/a/b/wt").map(\.pid) == [101, 102, 103])
    check("an empty scan selects nothing",
          worktreeProcessesToKill([], worktreePath: "/a/b/wt").isEmpty)
    check("the same selection is what the list report counts as live agents",
          worktreeListLines([WorktreeEntry(path: "/a/b/wt", branch: "wt")], processes: liveScan)
            .first?.contains("\t3 agents\t") == true)

    // The guard on deleting a worktree directory ourselves.
    check("a path git no longer registers may be removed",
          worktreeDirRemovalAllowed(path: "/a/b/repo-feat", mainRepo: "/a/b/repo", registered: false))
    check("a still-registered path is left to git",
          !worktreeDirRemovalAllowed(path: "/a/b/repo-feat", mainRepo: "/a/b/repo", registered: true))
    check("the main repo itself is never removed",
          !worktreeDirRemovalAllowed(path: "/a/b/repo", mainRepo: "/a/b/repo", registered: false))
    check("an ancestor of the main repo is never removed",
          !worktreeDirRemovalAllowed(path: "/a/b", mainRepo: "/a/b/repo", registered: false))
    check("the filesystem root is never removed",
          !worktreeDirRemovalAllowed(path: "/", mainRepo: "/a/b/repo", registered: false))
    check("a relative path is refused (nothing to resolve it against)",
          !worktreeDirRemovalAllowed(path: "repo-feat", mainRepo: "/a/b/repo", registered: false))

    // MARK: - 11. Teardown: slug + transcript path guards (pure)

    check("the transcript slug turns / and . into -",
          worktreeTranscriptSlug(forResolvedPath: "/Users/x/repo-feat.1")
            == "-Users-x-repo-feat-1")
    let guardHome = "/Users/x/.claude"
    check("a target under the home's projects dir passes the guard",
          transcriptGuardPasses(target: "\(guardHome)/projects/-Users-x-repo-feat", home: guardHome))
    check("the projects dir itself does not pass (nothing to remove)",
          !transcriptGuardPasses(target: "\(guardHome)/projects/", home: guardHome))
    check("a path outside the projects dir is refused",
          !transcriptGuardPasses(target: "\(guardHome)/somewhere/else", home: guardHome))
    check("a secondary account home guards on its own projects dir",
          transcriptGuardPasses(target: "/Users/x/.claude2/projects/-Users-x-repo-feat",
                                home: "/Users/x/.claude2") &&
          !transcriptGuardPasses(target: "\(guardHome)/projects/-Users-x-repo-feat",
                                 home: "/Users/x/.claude2"))
    check("an empty slug yields a target that is just the prefix and is refused",
          !transcriptGuardPasses(target: "\(guardHome)/projects/", home: guardHome))

    // The removal loop sweeps every account home the launch side seeds, not just the default one.
    let homeA = rp(tempDir())
    let homeB = rp(tempDir())
    let sweepSlug = "-Users-x-repo-feat"
    for base in [homeA, homeB] {
        try? FileManager.default.createDirectory(atPath: "\(base)/projects/\(sweepSlug)",
                                                 withIntermediateDirectories: true)
    }
    check("both account homes hold the transcript dir before the sweep",
          FileManager.default.fileExists(atPath: "\(homeA)/projects/\(sweepSlug)") &&
          FileManager.default.fileExists(atPath: "\(homeB)/projects/\(sweepSlug)"))
    check("the sweep removes the dir in both homes and reports success",
          removeTranscriptDirs(slug: sweepSlug, homes: [homeA, homeB]))
    check("the transcript dir is gone from the default home",
          !FileManager.default.fileExists(atPath: "\(homeA)/projects/\(sweepSlug)"))
    check("the transcript dir is gone from the secondary home",
          !FileManager.default.fileExists(atPath: "\(homeB)/projects/\(sweepSlug)"))
    check("a second sweep finds nothing to remove but does not fail",
          !removeTranscriptDirs(slug: sweepSlug, homes: [homeA, homeB]))
    check("an empty slug removes nothing", !removeTranscriptDirs(slug: "", homes: [homeA, homeB]))
}
