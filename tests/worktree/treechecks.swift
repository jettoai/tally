import Foundation

// Groups 16-18 of the worktree assertions (main repo derivation, "you are here" resolution, and the
// tree overview's rendering), covering TallyCLI/WorktreeTree.swift. Split out of main.swift for
// file size like teardownchecks.swift: they run as one function main.swift calls, which owns the
// shared harness (`check`, `sh`, `tempDir`, `rp`).

func runTreeChecks() {
    // MARK: - 16. Main repo derivation and current location (pure)

    check("the colocated layout strips the /.git suffix",
          colocatedMainRepoPath(gitCommonDir: "/Users/x/repo/.git") == "/Users/x/repo")
    check("a submodule's git dir is not colocated, so no path is computed from it",
          colocatedMainRepoPath(gitCommonDir: "/Users/x/super/.git/modules/sub") == nil)
    check("a bare repo's dir is not colocated either",
          colocatedMainRepoPath(gitCommonDir: "/Users/x/repo.git") == nil)

    let mainFirst = """
    worktree /Users/x/repo
    HEAD abc
    branch refs/heads/main

    worktree /Users/x/repo-feat
    HEAD def
    branch refs/heads/feat
    """
    check("the first porcelain block is the main worktree and is dropped",
          linkedWorktrees(parseWorktreePorcelain(mainFirst)).map(\.path) == ["/Users/x/repo-feat"])
    check("a listing with only a main worktree has no linked ones",
          linkedWorktrees(parseWorktreePorcelain("worktree /Users/x/repo\nHEAD abc\n")).isEmpty)
    check("the main block is dropped even when git reports it as a git dir (submodule shape)",
          linkedWorktrees(parseWorktreePorcelain("""
          worktree /Users/x/super/.git/modules/sub
          HEAD abc
          branch refs/heads/main

          worktree /Users/x/subwt
          HEAD def
          branch refs/heads/wt
          """)).map(\.path) == ["/Users/x/subwt"])

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

    // Padding must only ever append spaces. Measuring in UTF-16 units and truncating to that
    // measure once cut an emoji in half (a lone surrogate, which renders as U+FFFD) and left every
    // CJK cell a column short.
    let emojiRows = alignedColumns([["\u{1F680}ship", "x"], ["plain", "y"]])
    check("an emoji cell survives the layout intact",
          emojiRows[0].contains("\u{1F680}ship") && !emojiRows.joined().contains("\u{FFFD}"))
    check("a wider ASCII neighbour still gets its own cell padded",
          emojiRows[1].hasPrefix("plain  "))
    check("a lone emoji cell is never split into a broken scalar",
          alignedColumns([["\u{1F680}"], ["a"]])[0] == "\u{1F680}")
    // An emoji branch name and an ASCII one line their next column up, which only works because
    // the emoji is measured as the two columns a terminal draws it in.
    let emojiAligned = alignedColumns([["\u{1F680}ship", "x"], ["plain-name", "y"]])
    check("an emoji row and an ASCII row put their second column in the same place",
          displayColumns(String(emojiAligned[0].prefix(while: { $0 != "x" })))
            == displayColumns(String(emojiAligned[1].prefix(while: { $0 != "y" }))))
    // The same for the multi-scalar spellings: a decomposed accent and a joined emoji are one
    // drawn character each, so the column after them lands in the same place as for plain text.
    let clusterAligned = alignedColumns([["caf\u{0065}\u{0301}", "x"],
                                         ["\u{1F469}\u{200D}\u{1F4BB}ops", "y"],
                                         ["abcdefg", "z"]])
    check("a decomposed accent does not push its row out of line",
          displayColumns(String(clusterAligned[0].prefix(while: { $0 != "x" })))
            == displayColumns(String(clusterAligned[2].prefix(while: { $0 != "z" }))))
    check("nor does a ZWJ emoji sequence",
          displayColumns(String(clusterAligned[1].prefix(while: { $0 != "y" })))
            == displayColumns(String(clusterAligned[2].prefix(while: { $0 != "z" }))))
    let cjkRows = alignedColumns([["\u{4E2D}\u{6587}", "x"], ["abc", "y"]])
    check("a CJK cell is measured in terminal columns, so the column stays square",
          displayColumns(String(cjkRows[0].prefix(while: { $0 != "x" })))
            == displayColumns(String(cjkRows[1].prefix(while: { $0 != "y" }))))
    check("a CJK cell keeps every character it started with",
          cjkRows[0].hasPrefix("\u{4E2D}\u{6587}") && !cjkRows.joined().contains("\u{FFFD}"))
    check("a cell wider than its column is never cut short",
          alignedColumns([["\u{4E2D}\u{6587}\u{5B57}"], ["ab"]])[0] == "\u{4E2D}\u{6587}\u{5B57}")

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

    // A SUBMODULE, whose common git dir lives at <super>/.git/modules/<name>: deriving the repo
    // from that dir's parent answered <super>/.git/modules, so `root` printed a path that is not a
    // checkout and `tree` drew a phantom main line for it.
    let superRepo = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: superRepo)
    let subOrigin = tempDir()
    sh("git init -q && git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: subOrigin)
    sh("git -c protocol.file.allow=always submodule add -q '\(subOrigin)' sub", cwd: superRepo)
    let subPath = "\(superRepo)/sub"
    check("the submodule really has its git dir outside its checkout",
          !FileManager.default.fileExists(atPath: "\(subPath)/.git/HEAD"))
    FileManager.default.changeCurrentDirectoryPath(subPath)
    check("inside a submodule, the resolved repo is the submodule's own checkout",
          resolveMainRepo() == rp(subPath))
    let subTree = capturingStdout { _ = runWorktreeTree() }.split(separator: "\n").map(String.init)
    check("a submodule's tree is its own single line, with no phantom parent",
          subTree.count == 1 && subTree[0].contains(rp(subPath)))
    check("the submodule's line is marked, since the caller is standing in it",
          subTree[0].hasPrefix("* ") && !subTree[0].contains("modules"))

    // The launch side resolves the same way: `tally claude -w` inside a submodule must land its
    // worktree beside the submodule's checkout, not beside <super>/.git/modules.
    let subLaunch = resolveWorktree(name: "feat-sub")
    check("a worktree created from inside a submodule is a sibling of its checkout",
          subLaunch.mainRepo == rp(subPath)
              && rp(subLaunch.path) == rp("\(superRepo)/sub-feat-sub"))
    check("and it is a real registered worktree of that submodule",
          parseWorktreePorcelain(runGit(["worktree", "list", "--porcelain"], cwd: subPath).out)
            .contains { rp($0.path) == rp(subLaunch.path) })
    check("re-entering the same name reuses it rather than creating a second",
          rp(resolveWorktree(name: "feat-sub").path) == rp(subLaunch.path))

    // The same shape from the other direction: --separate-git-dir puts the git dir anywhere.
    let separateWork = tempDir() + "/work"
    let separateGitDir = tempDir() + "/elsewhere.git"
    sh("git init -q --separate-git-dir '\(separateGitDir)' '\(separateWork)'")
    sh("git config user.email t@t && git config user.name t && " +
       "git commit -q --allow-empty -m init", cwd: separateWork)
    FileManager.default.changeCurrentDirectoryPath(separateWork)
    check("a --separate-git-dir repo resolves to its working tree, not next to its git dir",
          resolveMainRepo() == rp(separateWork))
    let separateTree = capturingStdout { _ = runWorktreeTree() }
        .split(separator: "\n").map(String.init)
    check("its tree is one line for the working tree itself",
          separateTree.count == 1 && separateTree[0].contains(rp(separateWork)))

    // From a LINKED worktree of that same repo, git has nothing to answer with: `--separate-git-dir`
    // records the working tree nowhere (no core.worktree, no path in the git dir's config, and the
    // checkout's `.git` file points one way only). What must NOT happen is inventing a checkout.
    let separateWt = tempDir() + "/wt"
    sh("git worktree add -q '\(separateWt)' -b feat-separate", cwd: separateWork)
    FileManager.default.changeCurrentDirectoryPath(separateWt)
    check("git itself records no working tree for this layout",
          runGit(["config", "--get", "core.worktree"]).out.isEmpty)
    check("so the resolved path is the git dir git itself reports, not a fabricated checkout",
          resolveMainRepo() == rp(separateGitDir))
    let separateWtTree = capturingStdout { _ = runWorktreeTree() }
        .split(separator: "\n").map(String.init)
    check("the linked worktree is still drawn and still marked",
          separateWtTree.count == 2 && separateWtTree[1].contains("feat-separate")
              && separateWtTree[1].hasPrefix("* "))
    check("and the main line is the git dir, which is what git worktree list says too",
          separateWtTree[0].contains(rp(separateGitDir))
              && parseWorktreePorcelain(runGit(["worktree", "list", "--porcelain"]).out)
                  .first.map { rp($0.path) } == rp(separateGitDir))

    // A colocated repo entered from ITS linked worktree must still resolve to the real checkout:
    // the verification added for the layouts above must not cost the ordinary case its answer.
    FileManager.default.changeCurrentDirectoryPath(treeWt.path)
    check("a plain repo still resolves to its checkout from inside a linked worktree",
          resolveMainRepo() == rp(treeRepo))

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
