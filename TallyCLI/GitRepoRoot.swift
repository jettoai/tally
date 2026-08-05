import Foundation

// Which repository this directory belongs to, and how to ask git anything at all.
//
// Split out of Worktree.swift / WorktreeTree.swift because the answer stopped being a worktree
// question: a per-project launch profile (`tally project`, ProjectPolicy.swift) is keyed by the MAIN
// repo's working tree, so a parallel line inherits the profile its repo declared instead of needing
// one of its own. Two callers, one resolution - a second implementation of "which repo is this"
// would key the profile differently from the way the worktree overview names the same directory.
//
// Foundation only, so both the launcher and the small test harnesses compile it standalone.

/// Run git and collect its output. Never throws: a git that cannot be run is reported as exit 127
/// with the reason on `err`, because every caller here is already prepared for a non-zero code.
func runGit(_ args: [String], cwd: String? = nil) -> (out: String, err: String, code: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let outPipe = Pipe(), errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
    } catch {
        return ("", "cannot run git: \(error.localizedDescription)", 127)
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let trim = { (data: Data) in
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return (trim(outData), trim(errData), process.terminationStatus)
}

/// Fully-resolved path (POSIX realpath, keeping the /private prefix like projectSlug), or the
/// input unchanged when it can't be resolved.
func realpathString(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(path, &buffer).map { String(cString: $0) } ?? path
}

/// The main worktree of the ORDINARY layout, where the common git dir sits at `<checkout>/.git`:
/// strip that suffix, which is the rule git applies internally. nil when the common dir lives
/// somewhere else (a submodule keeps it at `<super>/.git/modules/<name>`, `--separate-git-dir` puts
/// it anywhere, a bare repo is the dir), because its parent is then not a checkout at all and the
/// answer has to be asked for rather than computed.
func colocatedMainRepoPath(gitCommonDir dir: String) -> String? {
    let suffix = "/.git"
    guard dir.hasSuffix(suffix) else { return nil }
    return String(dir.dropLast(suffix.count))
}

/// Whether `candidate` really is a working tree of the repo whose common git dir is `commonDir`.
/// Every guess below is put through this: a computed path that looks like a checkout but is not one
/// (or belongs to a different repo) is worse than admitting we do not know, because everything
/// downstream treats the answer as a directory to print, to cd into, and to run git in.
private func isWorkingTree(_ candidate: String, ofCommonDir commonDir: String) -> Bool {
    guard !candidate.isEmpty else { return false }
    let probe = runGit(["-C", candidate, "rev-parse", "--path-format=absolute", "--git-common-dir"])
    return probe.code == 0 && realpathString(probe.out) == realpathString(commonDir)
}

/// The main repo's working tree, fully resolved, or nil when git says this is not a repository.
/// `cwd` is the directory to ask from; nil asks from this process's own.
///
/// Four ways to the answer, each verified before it is trusted:
///
///  1. The caller is standing IN the main worktree (its git dir is the common one, true for every
///     plain repo, submodule and separate-git-dir repo entered at its own checkout): git names it
///     outright with `--show-toplevel`. `--show-toplevel` alone is not enough, because from a
///     LINKED worktree it names that worktree rather than the main one.
///  2. The colocated layout, common dir at `<checkout>/.git`: strip the suffix.
///  3. `core.worktree`, which is how a submodule points back at its checkout from a linked worktree
///     of that submodule (relative to the common dir).
///  4. Nothing verified: the common dir, which is the answer `git worktree list` itself prints, and
///     a warning that it is a git dir rather than a checkout.
///
/// Case 4 is reachable and is not an oversight: a repo made with `git init --separate-git-dir`
/// records its working tree NOWHERE (measured 2026-07-27 on git 2.50.1: `core.worktree` unset, no
/// path in the git dir's config, and the `.git` file in the checkout points one way only, into the
/// git dir). Asked from a linked worktree of such a repo, git cannot answer either:
/// `git -C <common dir> rev-parse --show-toplevel` fails with "this operation must be run in a work
/// tree", and `--git-dir=<common dir>` resolves the toplevel from the caller's own cwd. So the
/// information genuinely does not exist, and inventing a path would be the worse failure.
func resolveMainRepo(cwd: String? = nil) -> String? {
    let common = runGit(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: cwd)
    guard common.code == 0, !common.out.isEmpty else { return nil }
    if runGit(["rev-parse", "--path-format=absolute", "--absolute-git-dir"], cwd: cwd).out
        == common.out {
        let top = runGit(["rev-parse", "--path-format=absolute", "--show-toplevel"], cwd: cwd).out
        if !top.isEmpty { return realpathString(top) }   // empty in a bare repo
    }
    if let colocated = colocatedMainRepoPath(gitCommonDir: common.out),
       isWorkingTree(colocated, ofCommonDir: common.out) {
        return realpathString(colocated)
    }
    let recorded = runGit(["config", "--get", "core.worktree"], cwd: cwd).out
    let absolute = recorded.hasPrefix("/") ? recorded : "\(common.out)/\(recorded)"
    if !recorded.isEmpty, isWorkingTree(absolute, ofCommonDir: common.out) {
        return realpathString(absolute)
    }
    warn("this repository records no main working tree; using its git dir \(common.out)")
    return realpathString(common.out)
}
