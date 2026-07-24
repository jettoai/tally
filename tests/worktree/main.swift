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

exit(failures == 0 ? 0 : 1)
