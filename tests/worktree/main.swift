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

// MARK: - 10-13. Teardown (kill decision, path guards, git cleanup, killer no-op)

// Split into tests/worktree/teardownchecks.swift for file size; top-level statements only run in
// main.swift, so those groups run as one function called from here.
runTeardownChecks()

// MARK: - 14. List: line formatting (pure)

check("a clean worktree with commits and no agents formats all five columns",
      formatWorktreeListLine(branch: "feat/a", age: "2 hours ago", dirty: false,
                             liveAgents: 0, subject: "add the thing")
        == "feat/a\t2 hours ago\t\t-\tadd the thing")
check("a dirty worktree shows the * marker",
      formatWorktreeListLine(branch: "fix/b", age: "1 day ago", dirty: true,
                             liveAgents: 0, subject: "wip").contains("\t*\t"))
check("an empty age renders as 'no commits'",
      formatWorktreeListLine(branch: "new", age: "", dirty: false,
                             liveAgents: 0, subject: "").hasPrefix("new\tno commits\t"))
check("an empty subject leaves the trailing column empty",
      formatWorktreeListLine(branch: "new", age: "now", dirty: false,
                             liveAgents: 0, subject: "").hasSuffix("\t-\t"))
check("a single live agent is singular",
      formatWorktreeListLine(branch: "b", age: "now", dirty: false,
                             liveAgents: 1, subject: "s").contains("\t1 agent\t"))
check("multiple live agents are plural",
      formatWorktreeListLine(branch: "b", age: "now", dirty: false,
                             liveAgents: 3, subject: "s").contains("\t3 agents\t"))
check("a long subject is truncated to the shared 40-char cap",
      formatWorktreeListLine(branch: "b", age: "now", dirty: false, liveAgents: 0,
                             subject: String(repeating: "x", count: 60))
        .hasSuffix("\t" + truncateSubject(String(repeating: "x", count: 60))))

// MARK: - 15. List: repo scan (real git)

let listRepo = tempDir()
sh("git init -q && git config user.email t@t && git config user.name t && " +
   "git commit -q --allow-empty -m init", cwd: listRepo)
FileManager.default.changeCurrentDirectoryPath(listRepo)
check("listing a repo with no worktrees exits 0", runWorktreeList() == 0)

let listWt = resolveWorktree(name: "feat-list")
sh("git commit -q --allow-empty -m 'list subject'", cwd: listWt.path)
let listLines = worktreeListLines(
    [WorktreeEntry(path: listWt.path, branch: "feat-list")], processes: [])
check("one report line per worktree", listLines.count == 1)
check("the report line names the branch and has five tab columns",
      listLines[0].hasPrefix("feat-list\t") && listLines[0].filter { $0 == "\t" }.count == 4)
check("with no processes the agent column is '-'", listLines[0].contains("\t-\t"))
let listWt2 = resolveWorktree(name: "feat-list-2")
let listLines2 = worktreeListLines(
    [WorktreeEntry(path: listWt.path, branch: "feat-list"),
     WorktreeEntry(path: listWt2.path, branch: "feat-list-2")], processes: [])
check("two worktrees produce two report lines", listLines2.count == 2)

exit(failures == 0 ? 0 : 1)
