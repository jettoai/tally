import Foundation

// Groups 10-13 of the worktree assertions (kill decision, path guards, git cleanup end to end),
// split out of main.swift for file size. They run as one function main.swift calls, which also
// owns the shared harness (`check`, `sh`, `tempDir`, `rp`).

func runTeardownChecks() {
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

    // MARK: - 12. Teardown: git cleanup end to end (real git, no killing)

    // A merged worktree tears all the way down: worktree gone, branch gone, exit 0.
    let mergedRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: mergedRepo)
    FileManager.default.changeCurrentDirectoryPath(mergedRepo)
    let mergedWt = resolveWorktree(name: "feat")   // reuse the launch resolver to create it
    sh("git commit -q --allow-empty -m work", cwd: mergedWt.path)
    sh("git merge -q feat", cwd: mergedRepo)        // fast-forward main to feat so feat is an ancestor
    let mergedCode = performWorktreeRemove(name: "feat", force: false, keepTranscripts: true,
                                           listProcesses: { _ in [] })
    check("a merged worktree removes cleanly (exit 0)", mergedCode == 0)
    check("the merged worktree directory is gone", !FileManager.default.fileExists(atPath: mergedWt.path))
    check("the merged branch is deleted",
          sh("git show-ref --verify --quiet refs/heads/feat", cwd: mergedRepo) != 0)

    // An unmerged worktree is refused without --force, then removed with it.
    let unmergedRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: unmergedRepo)
    FileManager.default.changeCurrentDirectoryPath(unmergedRepo)
    let unmergedWt = resolveWorktree(name: "feat2")
    sh("git commit -q --allow-empty -m unmerged", cwd: unmergedWt.path)   // ahead of main, not merged
    let refusedCode = performWorktreeRemove(name: "feat2", force: false, keepTranscripts: true,
                                            listProcesses: { _ in [] })
    check("an unmerged worktree is refused without --force (exit 1)", refusedCode == 1)
    check("the refused worktree is left in place", FileManager.default.fileExists(atPath: unmergedWt.path))
    let forcedCode = performWorktreeRemove(name: "feat2", force: true, keepTranscripts: true,
                                           listProcesses: { _ in [] })
    check("--force removes the unmerged worktree (exit 0)", forcedCode == 0)
    check("the forced worktree directory is gone", !FileManager.default.fileExists(atPath: unmergedWt.path))
    check("--force deletes the unmerged branch (branch -D)",
          sh("git show-ref --verify --quiet refs/heads/feat2", cwd: unmergedRepo) != 0)

    // A caller sitting inside the target worktree is refused before anything is torn down (git alone
    // would not refuse: the git subprocess runs from mainRepo, so only this guard protects the caller).
    let insideRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: insideRepo)
    FileManager.default.changeCurrentDirectoryPath(insideRepo)
    let insideWt = resolveWorktree(name: "feat3")
    sh("git commit -q --allow-empty -m work", cwd: insideWt.path)
    sh("git merge -q feat3", cwd: insideRepo)       // merged, so only the cwd guard can refuse
    FileManager.default.changeCurrentDirectoryPath(insideWt.path)
    let insideCode = performWorktreeRemove(name: "feat3", force: false, keepTranscripts: true,
                                           listProcesses: { _ in [] })
    check("removal from inside the target worktree is refused (exit 1)", insideCode == 1)
    check("the worktree the caller sits in is left in place",
          FileManager.default.fileExists(atPath: insideWt.path))
    FileManager.default.changeCurrentDirectoryPath(insideRepo)

    // A tag carrying the branch's name must not shadow the branch in the merged check (gitrevisions
    // resolves tags before heads): the unmerged branch stays refused even when the tag is merged.
    let shadowRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: shadowRepo)
    FileManager.default.changeCurrentDirectoryPath(shadowRepo)
    let shadowWt = resolveWorktree(name: "feat4")
    sh("git commit -q --allow-empty -m unmerged", cwd: shadowWt.path)
    sh("git tag feat4 HEAD", cwd: shadowRepo)       // tag at main HEAD, which IS an ancestor
    let shadowCode = performWorktreeRemove(name: "feat4", force: false, keepTranscripts: true,
                                           listProcesses: { _ in [] })
    check("a merged same-name tag does not waive the merged gate (exit 1)", shadowCode == 1)
    check("the tag-shadowed worktree is left in place",
          FileManager.default.fileExists(atPath: shadowWt.path))

    // A half-removed worktree: the registration survives but its checkout no longer validates (the
    // .git file is gone, which git reports as "prunable"), so `git worktree remove` refuses while the
    // directory stays on disk. Teardown prunes, sees git has let go of the path, and deletes the
    // directory itself rather than reporting success over a directory nobody owns.
    let staleRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: staleRepo)
    FileManager.default.changeCurrentDirectoryPath(staleRepo)
    let staleWt = resolveWorktree(name: "feat5")
    sh("git commit -q --allow-empty -m work", cwd: staleWt.path)
    sh("git merge -q feat5", cwd: staleRepo)
    sh("rm -f .git", cwd: staleWt.path)             // registration kept, checkout no longer validates
    check("the half-removed worktree directory is on disk before teardown",
          FileManager.default.fileExists(atPath: staleWt.path))
    let staleCode = performWorktreeRemove(name: "feat5", force: false, keepTranscripts: true,
                                          listProcesses: { _ in [] })
    check("a half-removed worktree still tears down (exit 0)", staleCode == 0)
    check("teardown deletes the directory git left behind",
          !FileManager.default.fileExists(atPath: staleWt.path))
    check("the stale registration is pruned",
          !runGit(["worktree", "list", "--porcelain"], cwd: staleRepo).out.contains(staleWt.path))
    check("the branch of a half-removed worktree is deleted",
          sh("git show-ref --verify --quiet refs/heads/feat5", cwd: staleRepo) != 0)
    check("the main repo is untouched by the directory removal",
          FileManager.default.fileExists(atPath: "\(staleRepo)/.git"))

    // MARK: - 13. Teardown: killWorktreeProcesses with no targets is a no-op

    check("killing an empty target list touches nothing and returns zero",
          killWorktreeProcesses([]) == 0)
}
