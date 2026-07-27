import Foundation

// Groups 16-18 of the worktree assertions (main repo derivation, "you are here" resolution, and the
// tree overview's rendering), covering TallyCLI/WorktreeTree.swift. Split out of main.swift for
// file size like teardownchecks.swift: they run as one function main.swift calls, which owns the
// shared harness (`check`, `sh`, `tempDir`, `rp`).

func runTreeChecks() {
    // MARK: - 16. Main repo derivation and current location (pure)

    check("the main repo is the parent of the common git dir",
          mainRepoPath(fromGitCommonDir: "/Users/x/repo/.git") == "/Users/x/repo")
    check("a nested common git dir still resolves to its parent",
          mainRepoPath(fromGitCommonDir: "/Users/x/deep/repo/.git") == "/Users/x/deep/repo")

    let treePaths = ["/a/repo", "/a/repo-feat", "/a/repo-feat2"]
    check("standing in the main repo marks the main repo",
          worktreeTreeCurrentIndex(cwd: "/a/repo", paths: treePaths) == 0)
    check("standing in a worktree marks that worktree",
          worktreeTreeCurrentIndex(cwd: "/a/repo-feat", paths: treePaths) == 1)
    check("standing in a worktree's subdirectory marks that worktree",
          worktreeTreeCurrentIndex(cwd: "/a/repo-feat/deep/dir", paths: treePaths) == 1)
    check("a sibling sharing a path prefix is not mistaken for the worktree",
          worktreeTreeCurrentIndex(cwd: "/a/repo-featx", paths: treePaths) == nil)
    check("a directory outside every checkout marks nothing",
          worktreeTreeCurrentIndex(cwd: "/elsewhere/entirely", paths: treePaths) == nil)
    check("a worktree nested inside the main repo wins over its parent",
          worktreeTreeCurrentIndex(cwd: "/a/repo/inner/sub", paths: ["/a/repo", "/a/repo/inner"]) == 1)
    check("an empty candidate path never matches",
          worktreeTreeCurrentIndex(cwd: "/a/repo", paths: [""]) == nil)

    // MARK: - 17. Tree rendering (pure)

    check("the home prefix collapses to ~",
          abbreviateHomePath("/Users/x/workspace/repo", home: "/Users/x") == "~/workspace/repo")
    check("home itself renders as ~", abbreviateHomePath("/Users/x", home: "/Users/x") == "~")
    check("a path outside home keeps its absolute form",
          abbreviateHomePath("/opt/repo", home: "/Users/x") == "/opt/repo")
    check("a sibling of home sharing its prefix is not collapsed",
          abbreviateHomePath("/Users/xy/repo", home: "/Users/x") == "/Users/xy/repo")

    check("columns pad to the widest cell and all-empty columns are dropped",
          alignedColumns([["a", "", "long"], ["bb", "", "x"]]) == ["a   long", "bb  x"])
    check("no line ends in trailing padding",
          alignedColumns([["a", "bbb"], ["a", "b"]]) == ["a  bbb", "a  b"])

    let sampleRows = [
        WorktreeTreeRow(branch: "release-sync", age: "2 hours ago", dirty: false, liveAgents: 1,
                        path: "/Users/x/workspace/repo-release"),
        WorktreeTreeRow(branch: "feat/ui", age: "3 days ago", dirty: true, liveAgents: 0,
                        path: "/Users/x/workspace/repo-feat-ui"),
    ]
    func sample(_ current: Int?) -> [String] {
        worktreeTreeLines(mainRepo: "/Users/x/workspace/repo", mainBranch: "main", rows: sampleRows,
                          currentIndex: current, home: "/Users/x")
    }

    let inMain = sample(0)
    check("the first line is the main repo with the branch it has checked out",
          inMain[0] == "* ~/workspace/repo  [main]  (you are here)")
    check("one further line per worktree", inMain.count == 3)
    check("a worktree line carries branch, age, live agents and path",
          inMain[1].contains("release-sync") && inMain[1].contains("2 hours ago")
            && inMain[1].contains("1 agent") && inMain[1].contains("~/workspace/repo-release"))
    check("the last worktree closes the tree with the corner connector",
          inMain[1].contains("|--") && inMain[2].contains("`--"))
    check("standing in the main repo marks only its own line",
          inMain[0].hasPrefix("* ") && inMain[1].hasPrefix("  ") && inMain[2].hasPrefix("  ")
            && inMain.filter { $0.contains("(you are here)") }.count == 1)

    let inSecond = sample(2)
    check("standing in a worktree marks that worktree's line, not the main repo",
          inSecond[2].hasPrefix("* ") && inSecond[2].hasSuffix("(you are here)")
            && !inSecond[0].contains("(you are here)"))
    check("the marked line is the only one marked wherever the caller stands",
          inSecond.filter { $0.contains("(you are here)") }.count == 1
            && inSecond[1].hasPrefix("  "))

    let nowhere = sample(nil)
    check("outside every checkout nothing is marked",
          nowhere.allSatisfy { $0.hasPrefix("  ") && !$0.contains("(you are here)") })
    check("only the dirty worktree carries the dirty marker",
          !nowhere[1].contains("*") && nowhere[2].contains("*"))

    check("a repo with no worktrees still prints its own line",
          worktreeTreeLines(mainRepo: "/Users/x/workspace/repo", mainBranch: "main", rows: [],
                            currentIndex: 0, home: "/Users/x")
            == ["* ~/workspace/repo  [main]  (you are here)"])
    check("a detached main checkout says so instead of naming a branch",
          worktreeTreeLines(mainRepo: "/r", mainBranch: nil, rows: [], currentIndex: nil,
                            home: "/Users/x") == ["  /r  [detached]"])

    let busy = [WorktreeTreeRow(branch: "b", age: "", dirty: false, liveAgents: 3, path: "/p")]
    check("multiple live agents are plural and a branch with no commits says so",
          worktreeTreeLines(mainRepo: "/r", mainBranch: "main", rows: busy, currentIndex: nil,
                            home: "/h")[1] == "  `--  b  no commits  3 agents  /p")
    let quiet = [WorktreeTreeRow(branch: "b", age: "now", dirty: false, liveAgents: 0, path: "/p")]
    check("a clean tree with no agents leaves no gap where those columns would be",
          worktreeTreeLines(mainRepo: "/r", mainBranch: "main", rows: quiet, currentIndex: nil,
                            home: "/h")[1] == "  `--  b  now  /p")

    // MARK: - 18. Tree and root against real git

    let treeRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: treeRepo)
    FileManager.default.changeCurrentDirectoryPath(treeRepo)
    var rootExit: Int32 = -1
    let rootOut = capturingStdout { rootExit = runWorktreeRoot() }
    check("root exits 0 inside a repo", rootExit == 0)
    check("root prints the repo path and nothing else",
          rootOut == rp(treeRepo) + "\n" && resolveMainRepo() == rp(treeRepo))
    var emptyExit: Int32 = -1
    let emptyOut = capturingStdout { emptyExit = runWorktreeTree() }
    check("tree exits 0 in a repo with no worktrees", emptyExit == 0)
    check("tree prints only the main repo line when there is nothing else",
          emptyOut.split(separator: "\n").count == 1 && emptyOut.contains("[main]"))

    let treeWt = resolveWorktree(name: "feat-tree")
    FileManager.default.changeCurrentDirectoryPath(treeWt.path)
    check("a caller inside a worktree still resolves the main repo, not the worktree",
          resolveMainRepo() == rp(treeRepo))
    check("the worktree is the entry marked when the caller stands in it",
          worktreeTreeCurrentIndex(cwd: rp(treeWt.path),
                                   paths: [rp(treeRepo), rp(treeWt.path)]) == 1)
    check("the main repo is the entry marked from the main checkout",
          worktreeTreeCurrentIndex(cwd: rp(treeRepo),
                                   paths: [rp(treeRepo), rp(treeWt.path)]) == 0)
    FileManager.default.changeCurrentDirectoryPath(treeRepo)

    // A repo that is not a repo at all: both read commands refuse rather than printing a path.
    let notARepo = tempDir()
    FileManager.default.changeCurrentDirectoryPath(notARepo)
    check("root outside a git repository exits 1", runWorktreeRoot() == 1)
    check("tree outside a git repository exits 1", runWorktreeTree() == 1)
    check("nothing resolves outside a git repository", resolveMainRepo() == nil)

    // A DETACHED worktree: the tree must draw it (and mark it when the caller stands in it), while
    // list still leaves it out. Filtering it out of the tree once produced an overview with no
    // "you are here" anywhere on it, which is the one thing the command exists to answer.
    let detachedRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: detachedRepo)
    let detachedPath = tempDir() + "/dwt"
    sh("git worktree add -q --detach '\(detachedPath)' HEAD", cwd: detachedRepo)
    FileManager.default.changeCurrentDirectoryPath(detachedRepo)
    check("git really made a detached worktree (no branch in the porcelain)",
          parseWorktreePorcelain(runGit(["worktree", "list", "--porcelain"], cwd: detachedRepo).out)
            .contains { rp($0.path) == rp(detachedPath) && $0.branch == nil })

    let fromMain = capturingStdout { _ = runWorktreeTree() }.split(separator: "\n").map(String.init)
    check("the tree draws the detached worktree", fromMain.count == 2)
    check("the detached worktree is labelled [detached] with its path",
          fromMain[1].contains("[detached]") && fromMain[1].contains(rp(detachedPath)))
    check("standing in the main repo still marks the main repo",
          fromMain[0].hasPrefix("* ") && fromMain[1].hasPrefix("  "))
    let listOut = capturingStdout { _ = runWorktreeList() }
    check("list leaves the detached worktree out, its contract unchanged", listOut.isEmpty)

    FileManager.default.changeCurrentDirectoryPath(detachedPath)
    let fromDetached = capturingStdout { _ = runWorktreeTree() }
        .split(separator: "\n").map(String.init)
    check("standing in a detached worktree marks that line",
          fromDetached[1].hasPrefix("* ") && fromDetached[1].hasSuffix("(you are here)"))
    check("the main repo line is not the one marked",
          !fromDetached[0].contains("(you are here)"))
    FileManager.default.changeCurrentDirectoryPath(treeRepo)
}

/// Run `body` with stdout redirected to a temp file and hand back what it printed. The tree, root
/// and list commands answer on stdout, so this is what lets the assertions read the real command
/// instead of a reimplementation of its filtering (and keeps their output out of the test log).
func capturingStdout(_ body: () -> Void) -> String {
    let path = NSTemporaryDirectory() + "wt-stdout-" + UUID().uuidString
    fflush(stdout)
    let saved = dup(1)
    let target = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    dup2(target, 1)
    close(target)
    body()
    fflush(stdout)
    dup2(saved, 1)
    close(saved)
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(atPath: path)
    return text
}
