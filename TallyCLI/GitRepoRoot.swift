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

/// `path` as a directory to start a subprocess in, or nil when it names none: the empty string, a
/// path that is not there, and a path that is there but is a file all answer nil.
///
/// EVERY `Process` in this binary that sets a working directory goes through this, and the guard
/// has to sit BEFORE the assignment rather than around `run()`. `Process` rejects a
/// `currentDirectoryURL` that is not a file URL by raising an ObjC exception, which no Swift
/// `catch` can see, so the process aborts: SIGABRT, exit 134, and a crash report written per call.
/// The empty string is exactly how that URL gets built, because `getcwd` has nothing to return once
/// the directory this process was started in has been deleted (a finished sandbox, a torn-down
/// worktree), and `FileManager.currentDirectoryPath` passes that emptiness straight on.
///
/// Measured 2026-09-05: a shell sitting in a deleted directory made `tally launch-dir` abort on
/// every bare `claude` or `codex`, 74 crash reports in one afternoon, each one dragging ReportCrash
/// and coresymbolicationd in behind it. The PATH shim's `|| true` hid the failure while the machine
/// paid for it.
func workingDirectoryURL(_ path: String) -> URL? {
    var isDirectory: ObjCBool = false
    guard !path.isEmpty,
          FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          isDirectory.boolValue else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
}

/// Whether `/usr/bin/git` is a real git rather than Apple's stub. On a Mac without Xcode or the
/// Command Line Tools that path is a shim which, when run, asks the person to install developer
/// tools in a system dialog; Tally starts git on every launch, so a fresh Mac would see that
/// dialog from a command that never needed git. `xcode-select -p` never shows it: it answers with
/// the developer directory, or fails when there is none. Only a positive answer is remembered (a
/// supervisor can outlive the install), so a machine without the tools pays one cheap probe per call.
func developerGitIsInstalled() -> Bool {
    if developerGitFound { return true }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let directory = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, !directory.isEmpty,
          FileManager.default.isExecutableFile(atPath: directory + "/usr/bin/git") else { return false }
    developerGitFound = true
    return true
}

// Only ever flips false to true, so a race between threads is harmless (both read the same answer).
nonisolated(unsafe) private var developerGitFound = false

/// Run git and collect its output. Never throws: a git that cannot be run is reported as exit 127
/// with the reason on `err`, because every caller here is already prepared for a non-zero code.
/// A `cwd` that is no longer a directory is one of those cases rather than a crash, for the reason
/// `workingDirectoryURL` gives; nil `cwd` inherits this process's own, and git reports a deleted one
/// itself ("unable to read current working directory") as an ordinary non-zero exit. So is a Mac
/// with no developer tools (`developerGitIsInstalled`): git is not started at all there.
/// `gitIsInstalled` is injectable so a test can stand in for a machine without the tools.
func runGit(_ args: [String], cwd: String? = nil,
            gitIsInstalled: () -> Bool = developerGitIsInstalled) -> (out: String, err: String, code: Int32) {
    guard gitIsInstalled() else {
        return ("", "cannot run git: the developer tools are not installed", 127)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    if let cwd {
        guard let directory = workingDirectoryURL(cwd) else {
            return ("", "cannot run git: no such directory `\(cwd)`", 127)
        }
        process.currentDirectoryURL = directory
    }
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
    guard let probe = gitDirectoryFacts(cwd: candidate) else { return false }
    return realpathString(probe.commonDir) == realpathString(commonDir)
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
    // One git call for all three facts, remembered per directory (gitDirectoryFacts, below).
    guard let facts = gitDirectoryFacts(cwd: cwd) else { return nil }
    let common = facts.commonDir
    if facts.gitDir == common, let top = facts.toplevel { return realpathString(top) }   // nil in a bare repo
    if let colocated = colocatedMainRepoPath(gitCommonDir: common),
       isWorkingTree(colocated, ofCommonDir: common) {
        return realpathString(colocated)
    }
    let recorded = runGit(["config", "--get", "core.worktree"], cwd: cwd).out
    let absolute = recorded.hasPrefix("/") ? recorded : "\(common)/\(recorded)"
    if !recorded.isEmpty, isWorkingTree(absolute, ofCommonDir: common) {
        return realpathString(absolute)
    }
    warn("this repository records no main working tree; using its git dir \(common)")
    return realpathString(common)
}

// MARK: - One answer per directory

// THE DOOR EVERY "WHICH REPOSITORY IS THIS DIRECTORY" QUESTION GOES THROUGH.
//
// Measured 2026-11-03: `tally status` with 34 live sessions (33 distinct directories) spawned 133
// `git rev-parse` processes, and the pollers that call it (Baton, fleet-watch, the relay hook) do
// that every few seconds. The same few facts were being asked four times per directory
// (`--git-common-dir`, `--absolute-git-dir`, `--show-toplevel` twice, once for the project key and
// once for the checkout), and a parallel line probed its main repo again for every sibling line.
// One `rev-parse` with three flags answers all three questions, the answer is remembered for
// `gitFactsLifetime` seconds under the directory's realpath, and callers that ask the same
// directory at the same moment (`sessionDirectoryIdentities` fans out with `concurrentPerform`)
// share one git process instead of racing to start N of them.
//
// A caller that spawns `git rev-parse` itself for a directory identity is bypassing this; the
// source-text lock in tests/gitfacts/main.swift (G6) says so for the files that used to.

/// What one `git rev-parse` says about a directory.
struct GitDirectoryFacts: Sendable, Equatable {
    /// `--git-common-dir`, absolute, as git printed it.
    let commonDir: String
    /// `--absolute-git-dir`.
    let gitDir: String
    /// `--show-toplevel`, nil in a bare repo, inside the git dir, or when git could not say.
    let toplevel: String?
}

/// How long one answer is reused, in seconds. Long enough that a poller calling `tally status` every
/// couple of seconds hits the disk layer, short enough that a `git init` or a moved repo is seen on
/// the next look. A repository changing LAYOUT inside this window (same path, different kind of
/// repo) is the one thing it cannot see; nothing in this tool does that.
let gitFactsLifetime: TimeInterval = 5

/// The only place the `rev-parse` argument vector is spelled.
private func revParseArgs(_ flags: [String]) -> [String] {
    ["rev-parse", "--path-format=absolute"] + flags
}

/// Ask git, with no memory. Three flags in one process when git can answer them all (rc 0 and
/// exactly three lines); a directory that is not a repository fails with nothing on stdout. Anything
/// in between (a bare repo or the inside of a git dir fails at `--show-toplevel` after printing the
/// first two, a path with a newline in it breaks the line count) is asked flag by flag, which is
/// what this code did before, so those shapes get the same answers as ever.
private func computeGitFacts(cwd: String?, run: GitFactsCache.Runner) -> GitDirectoryFacts? {
    let all = run(revParseArgs(["--git-common-dir", "--absolute-git-dir", "--show-toplevel"]), cwd)
    let lines = all.out.components(separatedBy: "\n")
    if all.code == 0, lines.count == 3, !lines.contains(where: \.isEmpty) {
        return GitDirectoryFacts(commonDir: lines[0], gitDir: lines[1], toplevel: lines[2])
    }
    if all.code != 0, all.out.isEmpty { return nil }
    let common = run(revParseArgs(["--git-common-dir"]), cwd)
    guard common.code == 0, !common.out.isEmpty else { return nil }
    let gitDir = run(revParseArgs(["--absolute-git-dir"]), cwd).out
    let top = run(revParseArgs(["--show-toplevel"]), cwd)
    return GitDirectoryFacts(commonDir: common.out, gitDir: gitDir,
                             toplevel: top.code == 0 && !top.out.isEmpty ? top.out : nil)
}

/// Short-lived memory of `computeGitFacts`, keyed by realpath, safe to ask from many threads.
///
/// Two locks, never held together in the other order: `lock` guards the dictionary and is dropped as
/// soon as the key's `Entry` is in hand, and each Entry's own lock is held while git runs. So N
/// threads asking one directory queue on that one Entry and exactly one of them runs git, while
/// different directories never wait on each other.
final class GitFactsCache: @unchecked Sendable {
    typealias Runner = ([String], String?) -> (out: String, err: String, code: Int32)

    private final class Entry {
        let lock = NSLock()
        var asked: TimeInterval?          // `clock` reading when git was asked
        var wall: TimeInterval = 0        // wall clock then, the only clock two processes share
        var value: GitDirectoryFacts?     // nil is a real answer: not a repository
    }

    private static func defaultRunner(_ args: [String], _ cwd: String?) -> (out: String, err: String, code: Int32) {
        runGit(args, cwd: cwd)
    }
    private static func defaultClock() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var runner: Runner = GitFactsCache.defaultRunner
    private var clockFn: () -> TimeInterval = GitFactsCache.defaultClock
    private var disk: URL?
    private var diskRead = false
    private var freshKeys: Set<String> = []   // positive answers computed by THIS process

    /// Seams for the tests; production code leaves them alone. `clock` must be monotonic.
    var run: Runner {
        get { lock.lock(); defer { lock.unlock() }; return runner }
        set { lock.lock(); runner = newValue; lock.unlock() }
    }
    var clock: () -> TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return clockFn }
        set { lock.lock(); clockFn = newValue; lock.unlock() }
    }
    /// Where answers are shared with the next process. nil (the default) keeps everything in this
    /// process, which is what every test harness that compiles this file wants: only
    /// TallyCLI/main.swift turns it on.
    var diskFile: URL? {
        get { lock.lock(); defer { lock.unlock() }; return disk }
        set { lock.lock(); disk = newValue; lock.unlock() }
    }

    /// Forget everything this process knows and put the seams back. `diskFile` stays, so a test can
    /// play "a new process" against the same file.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]; freshKeys = []; diskRead = false
        runner = GitFactsCache.defaultRunner; clockFn = GitFactsCache.defaultClock
    }

    private func entry(forKey key: String) -> Entry {
        lock.lock(); defer { lock.unlock() }
        loadDiskIfNeeded()
        if let known = entries[key] { return known }
        let made = Entry()
        entries[key] = made
        return made
    }

    func facts(forKey key: String) -> GitDirectoryFacts? {
        let slot = entry(forKey: key)
        let run = self.run, clock = self.clock
        slot.lock.lock()
        let now = clock()
        if let asked = slot.asked, now - asked >= 0, now - asked < gitFactsLifetime {
            let answer = slot.value
            slot.lock.unlock()
            return answer
        }
        let value = computeGitFacts(cwd: key, run: run)
        slot.value = value; slot.asked = now; slot.wall = Date().timeIntervalSince1970
        slot.lock.unlock()
        if value != nil { lock.lock(); freshKeys.insert(key); lock.unlock() }
        return value
    }

    // MARK: Disk layer (shared between processes)

    private struct DiskEntry: Codable {
        let at: TimeInterval       // wall clock when git answered
        let common: String
        let gitDir: String
        let top: String?
    }
    private struct DiskFile: Codable {
        let v: Int
        let entries: [String: DiskEntry]
    }

    private func isDirectory(_ path: String) -> Bool { workingDirectoryURL(path) != nil }

    /// What `file` holds that is still inside the lifetime. A file that is missing, unreadable or
    /// of another version is an empty answer, never an error.
    private func readDisk(_ file: URL) -> [String: DiskEntry] {
        guard let data = try? Data(contentsOf: file),
              let parsed = try? JSONDecoder().decode(DiskFile.self, from: data),
              parsed.v == 1 else { return [:] }
        let now = Date().timeIntervalSince1970
        return parsed.entries.filter { now - $0.value.at >= 0 && now - $0.value.at < gitFactsLifetime }
    }

    /// Caller holds `lock`. Once per process, on the first question: the other process's answers
    /// become entries aged by how long ago they were given. An answer is only trusted while the
    /// directories it names are still there, which catches a repo that was moved or removed.
    private func loadDiskIfNeeded() {
        guard !diskRead, let file = disk else { return }
        diskRead = true
        let wallNow = Date().timeIntervalSince1970, uptime = clockFn()
        for (key, item) in readDisk(file) {
            guard isDirectory(item.common), isDirectory(item.gitDir),
                  item.top.map(isDirectory) ?? true, entries[key] == nil else { continue }
            let made = Entry()
            made.asked = uptime - (wallNow - item.at); made.wall = item.at
            made.value = GitDirectoryFacts(commonDir: item.common, gitDir: item.gitDir, toplevel: item.top)
            entries[key] = made
        }
    }

    /// Write this process's positive answers where the next process will find them. Positive only: a
    /// "not a repository" that outlived a `git init` would be wrong for the next five seconds in
    /// every other process. Re-reads and merges, newest answer per directory wins, expired ones are
    /// dropped, and a failed write costs the next process one git call and nothing else.
    func flush() {
        lock.lock()
        guard let file = disk else { lock.unlock(); return }
        let mine = freshKeys.compactMap { key in entries[key].map { (key, $0) } }
        lock.unlock()
        guard !mine.isEmpty else { return }
        var merged = readDisk(file)
        let now = Date().timeIntervalSince1970
        for (key, entry) in mine {
            entry.lock.lock(); let value = entry.value, wall = entry.wall; entry.lock.unlock()
            guard let value, now - wall >= 0, now - wall < gitFactsLifetime else { continue }
            if let old = merged[key], old.at >= wall { continue }
            merged[key] = DiskEntry(at: wall, common: value.commonDir, gitDir: value.gitDir,
                                    top: value.toplevel)
        }
        guard let data = try? JSONEncoder().encode(DiskFile(v: 1, entries: merged)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

let gitFactsCache = GitFactsCache()

/// What git says about `cwd`, or nil when it is not inside a repository. `cwd` nil asks from this
/// process's own directory, which has no stable name to key on and is not remembered; neither is a
/// path that names no directory (empty, deleted, a file), so those keep failing the way `runGit`
/// reports them rather than being answered from memory.
func gitDirectoryFacts(cwd: String?) -> GitDirectoryFacts? {
    guard let cwd else { return computeGitFacts(cwd: nil, run: gitFactsCache.run) }
    let key = realpathString(cwd)
    guard workingDirectoryURL(key) != nil else {
        return computeGitFacts(cwd: cwd, run: gitFactsCache.run)
    }
    return gitFactsCache.facts(forKey: key)
}

/// The checkout `cwd` stands in, realpath'd; nil outside a work tree. For a session on a parallel
/// line this is the line, where `resolveMainRepo` is the repository it belongs to.
func gitCheckout(cwd: String) -> String? {
    gitDirectoryFacts(cwd: cwd)?.toplevel.map(realpathString)
}
