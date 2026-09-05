import Foundation

// The directory that is no longer there. It is an ordinary state for a shell rather than a broken
// machine: the sandbox it was working in finished, the worktree it stood in was removed, and the
// shell is still sitting in the path where that used to be. `getcwd` then has nothing to return,
// `FileManager.currentDirectoryPath` hands the emptiness on, and `URL(fileURLWithPath: "")` is not
// a file URL - which `Process` answers with an ObjC exception that no Swift `catch` can see. So the
// binary aborts (SIGABRT, exit 134, one crash report per call) where it meant to ask git a question.
//
// Two things are asserted here, and the first one is asserted by RUNNING: without the guard in
// `runGit` (GitRepoRoot.swift) the calls below take the whole harness down with them, so a
// regression is a suite that dies rather than a suite that reports a failure. The second is the
// shim's contract: `tally launch-dir` from such a directory prints nothing and returns, because the
// PATH shim evals what it prints and a bare `claude` must start whether or not Tally can steer it.
//
// Lives outside main.swift because it CHANGES the harness's own working directory to reproduce the
// state, and has to put it back.

/// Whatever `body` writes to stdout. `runLaunchDir` prints, and printing nothing at all is exactly
/// the contract being asserted, so it has to be read from the descriptor rather than from a value.
private func capturingStdout(_ body: () -> Void) -> String {
    let path = tmp.appendingPathComponent("stdout-\(UUID().uuidString)").path
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let sink = FileHandle(forWritingAtPath: path) else { return "capture failed" }
    fflush(stdout)
    let saved = dup(1)
    dup2(sink.fileDescriptor, 1)
    body()
    fflush(stdout)
    dup2(saved, 1)
    close(saved)
    try? sink.close()
    return (try? String(contentsOfFile: path, encoding: .utf8)) ?? "capture failed"
}

func runDeletedCwdChecks() {
    let doomed = tmp.appendingPathComponent("deleted-cwd")
    let present = tmp.appendingPathComponent("present")
    try? FileManager.default.createDirectory(at: doomed, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
    let plainFile = present.appendingPathComponent("a-file")
    FileManager.default.createFile(atPath: plainFile.path, contents: Data())

    check("a directory that is there is a directory to run a subprocess in",
          workingDirectoryURL(present.path)?.isFileURL == true)
    check("a path that is not there is not", workingDirectoryURL(present.path + "/nope") == nil)
    check("neither is a file", workingDirectoryURL(plainFile.path) == nil)
    // The empty string is the whole of the bug, so it is asserted on its own: it is what getcwd
    // leaves behind, and it is the value that builds the non-file URL Process aborts on.
    check("and neither is the empty string a deleted directory leaves behind",
          workingDirectoryURL("") == nil)

    let restore = FileManager.default.currentDirectoryPath
    guard FileManager.default.changeCurrentDirectoryPath(doomed.path) else {
        check("the harness can stand in the directory it is about to delete", false)
        return
    }
    defer { _ = FileManager.default.changeCurrentDirectoryPath(restore) }
    try? FileManager.default.removeItem(at: doomed)

    let gone = FileManager.default.currentDirectoryPath
    check("standing in a deleted directory leaves getcwd with nothing to hand on",
          workingDirectoryURL(gone) == nil)
    let asked = runGit(["rev-parse", "--show-toplevel"], cwd: gone)
    check("git asked from there reports the directory instead of aborting the process",
          asked.code == 127 && asked.err.contains("no such directory"))
    check("so does git asked from the deleted path by name",
          runGit(["rev-parse", "--show-toplevel"], cwd: doomed.path).code == 127)
    check("the repo resolution answers nothing rather than crashing",
          resolveMainRepo(cwd: gone) == nil && resolveMainRepo(cwd: doomed.path) == nil)
    check("and the project key falls back to the directory it was given",
          projectPolicyKey(cwd: doomed.path) == doomed.path)
    check("a profile read from a directory that is gone is simply empty",
          projectPolicy("codex", cwd: doomed.path).isEmpty)
    // The shim's own call, printing nothing: `eval "$(tally launch-dir codex 2>/dev/null)"` has to
    // leave the environment alone and let the bare CLI run.
    check("`launch-dir` prints nothing from a directory that is gone",
          capturingStdout { runLaunchDir("codex") }.isEmpty)
}
