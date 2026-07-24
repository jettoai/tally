import Foundation

// Assertion harness for the CLI's worktree logic (TallyCLI/Worktree.swift), compiled against the
// real source. Pure functions are checked directly; the create/link/hook groups use real git and
// a temp filesystem. Mirrors the five scenario groups in
// docs/specs/changes/worktree-launch/design.md.

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

@discardableResult
func sh(_ command: String, cwd: String? = nil) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

func tempDir() -> String {
    let dir = NSTemporaryDirectory() + "wt-test-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func rp(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(path, &buffer).map { String(cString: $0) } ?? path
}

// MARK: - 1. Flag extraction

var a1 = ["-w", "feat", "--model", "opus"]
let r1 = extractWorktreeFlag(&a1)
check("-w feat extracted, name kept, rest intact",
      r1.found && r1.name == "feat" && a1 == ["--model", "opus"])

var a2 = ["--worktree", "feat", "-p"]
let r2 = extractWorktreeFlag(&a2)
check("--worktree feat extracted", r2.found && r2.name == "feat" && a2 == ["-p"])

var a3 = ["-w", "--continue"]
let r3 = extractWorktreeFlag(&a3)
check("bare -w before a flag leaves the flag", r3.found && r3.name == nil && a3 == ["--continue"])

var a4 = ["-w"]
let r4 = extractWorktreeFlag(&a4)
check("bare -w at end", r4.found && r4.name == nil && a4.isEmpty)

var a5 = ["--model", "opus"]
let r5 = extractWorktreeFlag(&a5)
check("no worktree flag leaves args untouched",
      !r5.found && r5.name == nil && a5 == ["--model", "opus"])

// Stripping a hand-typed continue/resume for a worktree with no conversation yet.
var s1 = ["--resume", "abc123", "--model", "opus"]
check("strip --resume with its session-id value",
      stripContinueResume(&s1) && s1 == ["--model", "opus"])
var s2 = ["-c"]
check("strip -c", stripContinueResume(&s2) && s2.isEmpty)
var s3 = ["-r", "-p"]
check("strip -r but keep a following flag as its value is absent",
      stripContinueResume(&s3) && s3 == ["-p"])
var s4 = ["--model", "opus"]
check("nothing to strip returns false, args untouched",
      !stripContinueResume(&s4) && s4 == ["--model", "opus"])

// MARK: - 2. Porcelain parse + path derivation

let porcelain = """
worktree /Users/x/repo
HEAD abc
branch refs/heads/main

worktree /Users/x/repo-feat
HEAD def
branch refs/heads/feat/x

worktree /Users/x/repo-detached
HEAD 123
detached
"""
let entries = parseWorktreePorcelain(porcelain)
check("three entries parsed", entries.count == 3)
check("main entry path + branch", entries[0].path == "/Users/x/repo" && entries[0].branch == "main")
check("branch with slash kept verbatim", entries[1].branch == "feat/x")
check("detached entry has nil branch", entries[2].branch == nil)
check("path derivation is a sibling", worktreePath(mainRepo: "/Users/x/repo", name: "feat") == "/Users/x/repo-feat")
check("slash sanitized in the directory suffix",
      worktreePath(mainRepo: "/Users/x/repo", name: "feat/x") == "/Users/x/repo-feat-x")
check("sanitize replaces every slash", sanitizeWorktreeName("feat/x/y") == "feat-x-y")
check("the main checkout entry is refused (not resolved as a worktree)",
      isMainCheckout(WorktreeEntry(path: "/Users/x/repo", branch: "main"), mainRepo: "/Users/x/repo"))
check("a real worktree entry is not the main checkout",
      !isMainCheckout(WorktreeEntry(path: "/Users/x/repo-feat", branch: "feat"), mainRepo: "/Users/x/repo"))

// MARK: - 3. Resolve/create (real git)

let repo = tempDir()
sh("git init -q && git config user.email t@t && git config user.name t && " +
   "git commit -q --allow-empty -m init", cwd: repo)
FileManager.default.changeCurrentDirectoryPath(repo)   // resolveWorktree reads process cwd

let first = resolveWorktree(name: "feat")
check("first resolve creates the worktree", first.created)
check("worktree lands as a sibling named <repo>-feat", first.path.hasSuffix("-feat"))
check("created worktree directory exists", FileManager.default.fileExists(atPath: first.path))

let second = resolveWorktree(name: "feat")
check("second resolve reuses the same worktree", !second.created && second.path == first.path)

sh("git branch existing", cwd: repo)
let third = resolveWorktree(name: "existing")
check("a pre-existing branch is checked out without error",
      third.created && third.name == "existing" && third.path.hasSuffix("-existing"))

// A worktree (freshly made or added by hand) whose slug has no transcript reports "no
// conversation" - the caller then suppresses continue. A transcript flips it.
let txHome = tempDir()
let txSlug = projectSlug(forCwd: first.path)
check("a worktree with no transcript reports none (suppress continue)",
      !worktreeHasTranscript(slug: txSlug, homes: [txHome]))
try? FileManager.default.createDirectory(atPath: "\(txHome)/projects/\(txSlug)",
                                         withIntermediateDirectories: true)
FileManager.default.createFile(atPath: "\(txHome)/projects/\(txSlug)/sess.jsonl", contents: Data())
check("a .jsonl transcript makes the worktree report a conversation",
      worktreeHasTranscript(slug: txSlug, homes: [txHome]))

// MARK: - 4. Shared memory (fake home)

let mainRepoDir = tempDir()
let wtDir = tempDir()
let wt = WorktreeLaunch(mainRepo: mainRepoDir, path: wtDir, name: "feat", created: true)
let mainSlug = projectSlug(forCwd: mainRepoDir)
let wtSlug = projectSlug(forCwd: wtDir)

let home = rp(tempDir())
ensureSharedMemory(wt, homes: [home])
let link = "\(home)/projects/\(wtSlug)/memory"
check("memory symlink points at the main repo's memory (relative)",
      (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == "../\(mainSlug)/memory")
check("link target directory was created",
      FileManager.default.fileExists(atPath: "\(home)/projects/\(mainSlug)/memory"))

ensureSharedMemory(wt, homes: [home])   // idempotent
check("second run leaves the symlink unchanged",
      (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == "../\(mainSlug)/memory")

let home2 = rp(tempDir())
let realMemory = "\(home2)/projects/\(wtSlug)/memory"
try? FileManager.default.createDirectory(atPath: realMemory, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: "\(realMemory)/note.md", contents: Data("x".utf8))
ensureSharedMemory(wt, homes: [home2])
check("a pre-existing real memory dir is not clobbered",
      FileManager.default.fileExists(atPath: "\(realMemory)/note.md"))
check("existing memory stays a real dir, not a link",
      (try? FileManager.default.destinationOfSymbolicLink(atPath: realMemory)) == nil)

// MARK: - 5. Setup hook

let hookRepo = tempDir()
try? FileManager.default.createDirectory(atPath: "\(hookRepo)/.tally", withIntermediateDirectories: true)
let hookWt = tempDir()
let hookScript = "#!/bin/bash\n" +
    "echo \"$TALLY_MAIN_REPO|$TALLY_WORKTREE_NAME|$TALLY_WORKTREE_PATH|$TALLY_WORKTREE_CREATED\" " +
    "> \"$TALLY_WORKTREE_PATH/marker.txt\"\n"
try? hookScript.write(toFile: "\(hookRepo)/.tally/worktree-setup.sh", atomically: true, encoding: .utf8)
runSetupHook(WorktreeLaunch(mainRepo: hookRepo, path: hookWt, name: "feat/x", created: true))
let marker = (try? String(contentsOfFile: "\(hookWt)/marker.txt", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines)
check("setup hook ran with cwd = worktree and the four env keys",
      marker == "\(hookRepo)|feat/x|\(hookWt)|1")

let failRepo = tempDir()
try? FileManager.default.createDirectory(atPath: "\(failRepo)/.tally", withIntermediateDirectories: true)
try? "#!/bin/bash\nexit 1\n".write(toFile: "\(failRepo)/.tally/worktree-setup.sh",
                                   atomically: true, encoding: .utf8)
runSetupHook(WorktreeLaunch(mainRepo: failRepo, path: tempDir(), name: "z", created: false))
check("a failing setup hook warns without crashing", true)

runSetupHook(WorktreeLaunch(mainRepo: tempDir(), path: tempDir(), name: "z", created: false))
check("an absent setup hook is a no-op", true)

// MARK: - 6. Menu rendering (pure)

let menuRows = [
    MenuRow(branch: "feat/a", age: "2 hours ago", dirty: false, subject: "add the thing"),
    MenuRow(branch: "fix/b", age: "", dirty: true,
            subject: String(repeating: "x", count: 60)),
]
let rendered = renderRows(menuRows, highlighted: 0)
check("render emits one line per row plus the new-worktree line", rendered.count == 3)
check("the highlighted row wears the cursor marker", rendered[0].contains("\u{25B8}"))
check("a non-highlighted row has no cursor marker", !rendered[1].contains("\u{25B8}"))
check("a dirty row shows the yellow dot", rendered[1].contains("\u{25CF}"))
check("a clean row shows no dot", !rendered[0].contains("\u{25CF}"))
check("an empty age renders as 'no commits'", rendered[1].contains("no commits"))
check("the trailing line is the new-worktree option", rendered[2].contains("n) new worktree"))
check("highlighting the new-worktree line moves the cursor there",
      renderRows(menuRows, highlighted: 2)[2].contains("\u{25B8}") &&
      !renderRows(menuRows, highlighted: 2)[0].contains("\u{25B8}"))

check("a short subject is left intact", truncateSubject("short") == "short")
let clipped = truncateSubject(String(repeating: "a", count: 60))
check("a long subject clips to 40 chars ending in an ellipsis",
      clipped.count == 40 && clipped.hasSuffix("\u{2026}"))
check("a subject exactly at the limit is not clipped",
      truncateSubject(String(repeating: "b", count: 40)).count == 40 &&
      !truncateSubject(String(repeating: "b", count: 40)).hasSuffix("\u{2026}"))

// MARK: - 7. Key decoding (pure)

check("ESC [ A decodes to up", decodeKey([0x1B, 0x5B, 0x41]) == .up)
check("ESC [ B decodes to down", decodeKey([0x1B, 0x5B, 0x42]) == .down)
check("a lone ESC is a cancel, distinct from the arrow sequence", decodeKey([0x1B]) == .cancel)
check("an unknown CSI final byte is other", decodeKey([0x1B, 0x5B, 0x43]) == .other)
check("CR is enter", decodeKey([0x0D]) == .enter)
check("LF is enter", decodeKey([0x0A]) == .enter)
check("n opens a new worktree", decodeKey([0x6E]) == .newKey)
check("N opens a new worktree", decodeKey([0x4E]) == .newKey)
check("q cancels", decodeKey([0x71]) == .cancel)
check("j moves down", decodeKey([0x6A]) == .down)
check("k moves up", decodeKey([0x6B]) == .up)
check("a digit decodes to its number", decodeKey([0x35]) == .digit(5))
check("zero decodes as digit zero (caller treats it as out of range)",
      decodeKey([0x30]) == .digit(0))
check("an unrelated letter is other", decodeKey([0x7A]) == .other)
check("an empty sequence is other", decodeKey([]) == .other)
check("a modified arrow (ESC [ 1 ; 2 A) is other as one sequence, never a digit",
      decodeKey([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x41]) == .other)
check("an SS3 arrow (ESC O A) is other, not a leak of its final byte",
      decodeKey([0x1B, 0x4F, 0x41]) == .other)

// MARK: - 8. Menu state transitions (pure combo layer)

// Two existing rows (rowCount = 2); highlights 0,1 are rows, 2 is the new-worktree line.
check("down moves the highlight forward", applyKey(.down, highlighted: 0, rowCount: 2).highlighted == 1)
check("down wraps past the new-worktree line back to the top",
      applyKey(.down, highlighted: 2, rowCount: 2).highlighted == 0)
check("up wraps from the top to the new-worktree line",
      applyKey(.up, highlighted: 0, rowCount: 2).highlighted == 2)
check("a move commits no selection", applyKey(.down, highlighted: 0, rowCount: 2).selection == nil)
check("enter on a row selects that existing worktree",
      applyKey(.enter, highlighted: 1, rowCount: 2).selection == .existing(1))
check("enter on the new-worktree line selects new",
      applyKey(.enter, highlighted: 2, rowCount: 2).selection == .newWorktree)
check("a digit maps to a 1-based existing row",
      applyKey(.digit(2), highlighted: 0, rowCount: 2).selection == .existing(1))
check("an out-of-range digit is ignored, highlight unchanged",
      applyKey(.digit(5), highlighted: 0, rowCount: 2).selection == nil &&
      applyKey(.digit(5), highlighted: 0, rowCount: 2).highlighted == 0)
check("digit zero is out of range and ignored",
      applyKey(.digit(0), highlighted: 0, rowCount: 2).selection == nil)
check("the new key always selects new regardless of highlight",
      applyKey(.newKey, highlighted: 0, rowCount: 2).selection == .newWorktree)
check("cancel selects cancelled", applyKey(.cancel, highlighted: 1, rowCount: 2).selection == .cancelled)
check("an other key is a no-op",
      applyKey(.other, highlighted: 1, rowCount: 2).selection == nil &&
      applyKey(.other, highlighted: 1, rowCount: 2).highlighted == 1)

// A full keystroke sequence: down, down (wrap to new line), then Enter -> new worktree.
var hl = 0
for key in [Key.down, .down, .enter] {
    let step = applyKey(key, highlighted: hl, rowCount: 2)
    hl = step.highlighted
    if let sel = step.selection {
        check("down,down,enter over 2 rows lands on new worktree", sel == .newWorktree)
    }
}

// MARK: - 9. Width-aware line clipping (pure)

check("an ASCII line within the budget is returned unchanged",
      clipToDisplayWidth("hello", columns: 20) == "hello")

// A clipped line always ends with the ellipsis followed by an ANSI reset (color cannot bleed).
let ellipsisReset = "\u{2026}\u{1B}[0m"
let longAscii = clipToDisplayWidth(String(repeating: "a", count: 40), columns: 21)
check("an over-width ASCII line clips to exactly the column budget",
      displayColumns(longAscii) == 21)
check("a clipped ASCII line ends in an ellipsis then a reset", longAscii.hasSuffix(ellipsisReset))

// A wide (CJK) scalar counts as two columns: a run of them clips to the same display width as the
// ASCII case but keeps only half as many visible characters.
let longCJK = clipToDisplayWidth(String(repeating: "\u{4E2D}", count: 40), columns: 21)
check("a CJK line clips to within the column budget", displayColumns(longCJK) <= 21)
check("wide chars count as two: the CJK clip keeps half the visible character count",
      longAscii.filter { $0 == "a" }.count == 20 &&
      longCJK.filter { $0 == "\u{4E2D}" }.count == 10)
check("a clipped CJK line ends in an ellipsis then a reset", longCJK.hasSuffix(ellipsisReset))

// ANSI codes cost zero display width and are not split; a clipped colored line ends with a reset so
// its color cannot bleed onto the next physical line.
let purple = "\u{1B}[38;5;135m"
let reset = "\u{1B}[0m"
let coloredLine = purple + String(repeating: "a", count: 40) + reset
let coloredClip = clipToDisplayWidth(coloredLine, columns: 21)
check("ANSI codes are not counted toward display width",
      displayColumns(coloredClip) == displayColumns(longAscii))
check("a clipped colored line ends with the reset sequence", coloredClip.hasSuffix(reset))
check("the color code survives the clip intact", coloredClip.contains(purple))

// An escape sequence straddling the clip point is copied whole, never split: a naive
// character-count clipper would have cut the yellow code in half here.
let yellow = "\u{1B}[33m"
let straddling = String(repeating: "a", count: 19) + yellow + "bcdef"
let straddleClip = clipToDisplayWidth(straddling, columns: 21)
check("an escape sequence at the clip boundary is kept intact", straddleClip.contains(yellow))
check("the straddling-escape clip still respects the budget", displayColumns(straddleClip) <= 21)

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

// MARK: - 13. Teardown: killWorktreeProcesses with no targets is a no-op

check("killing an empty target list touches nothing and returns zero",
      killWorktreeProcesses([]) == 0)

exit(failures == 0 ? 0 : 1)
