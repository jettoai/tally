import Foundation

// Assertions for which project row a working directory is credited to (Tally/Core/TokenStats/
// TokenProjectMap.swift), built against a fixture workspace on disk rather than the machine's own,
// so the answers are the same on every machine. The rule under test here is the newest one: a git
// worktree is a parallel line of work on a repository, not a project beside it, so its directories
// and its agents' transcript folders belong to the repository's row.
//
// The layouts where a repository's git directory is NOT the checkout's own `.git` (a submodule, a
// `--separate-git-dir` repository, a bare one) are built by RUNNING git rather than by writing the
// files this suite believes git writes. That distinction is the whole reason this note exists: a
// hand-written fixture once carried a `core.worktree` key in a separate git dir's config, which
// git does not put there, and the test passed over an implementation that could only work if it
// did. A test may spawn git; the app may not, and `checkoutGit` says why.

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok: \(message)")
    } else {
        print("  FAIL: \(message)")
        failures += 1
    }
}

func section(_ title: String) { print("\n\(title)") }

/// Localization stub. `TokenTotals.swift` is compiled in for `TokenProject.otherKey` and calls
/// this for its display names; the app's bundle resolution is not what this suite is about.
func L(_ key: String) -> String { key }

/// Claude Code's own naming for a project's transcript folder, restated here as the oracle the
/// map's flattened spelling is checked against: the absolute path with everything that is not a
/// letter, digit or dash replaced by a dash.
func transcriptFolder(for path: String) -> String {
    String(path.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" ? $0 : "-" })
}

// MARK: Fixture

let manager = FileManager.default
let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("tokenprojectmap-\(getpid())", isDirectory: true)
let workspace = home.appendingPathComponent("workspace", isDirectory: true)
try? manager.removeItem(at: home)

func directory(_ relative: String) -> URL {
    workspace.appendingPathComponent(relative, isDirectory: true)
}

/// A repository: `.git` is a directory.
func repository(_ relative: String) {
    try! manager.createDirectory(at: directory(relative).appendingPathComponent(".git"),
                                 withIntermediateDirectories: true)
}

/// A worktree, or anything else whose `.git` is a file: the contents are written verbatim, so a
/// malformed link can be spelled out exactly as it would be found.
func checkout(_ relative: String, dotGit contents: String) {
    let url = directory(relative)
    try! manager.createDirectory(at: url, withIntermediateDirectories: true)
    try! contents.write(to: url.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
}

func worktree(_ relative: String, of gitDir: String) {
    checkout(relative, dotGit: "gitdir: \(gitDir)\n")
}

/// Run a shell command, returning its exit status. Only the real-git fixtures use it: nothing the
/// map does shells out, and nothing here asserts through git either. The identity `git init` and
/// friends write is the fixture, and reading what they actually wrote is the point.
@discardableResult
func sh(_ command: String) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// A repository with one empty commit, so worktrees can be cut from it.
func gitRepository(at path: String, _ initFlags: String = "") {
    sh("git init -q \(initFlags) '\(path)' && git -C '\(path)' -c user.email=t@t -c user.name=t "
        + "commit -q --allow-empty -m init")
}

/// The `gitdir:` line of a checkout's `.git` FILE, for asserting the fixture is the layout this
/// suite thinks it is. A shape assertion that fails means git changed what it writes, which is a
/// different failure from the map reading it wrongly, and the two must not look alike.
func gitDirLine(of checkout: String) -> String {
    ((try? String(contentsOfFile: checkout + "/.git", encoding: .utf8)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

repository("tally")
worktree("tally-release", of: workspace.path + "/tally/.git/worktrees/aiusage-release")

// A container of checkouts rather than a checkout itself, so its children are the projects.
try! manager.createDirectory(at: directory("taiwanbigdata"), withIntermediateDirectories: true)
repository("taiwanbigdata/geo")
worktree("taiwanbigdata/geo-auth", of: workspace.path + "/taiwanbigdata/geo/.git/worktrees/geo-auth")
// The same repository's worktree, cut at the top level instead of beside it.
worktree("geo-admin", of: workspace.path + "/taiwanbigdata/geo/.git/worktrees/admin")

// A link written relative to the worktree, which git can be configured to do. It only resolves to
// a path the allow-list knows through `realpath`, `..` and all.
repository("specai")
worktree("specai-relative", of: "../specai/.git/worktrees/rel")

// A `.git` file that says nothing this understands, and one naming a repository that is not in
// the workspace at all. Both keep their own row.
checkout("broken", dotGit: "this is not a link\n")
worktree("orphan", of: "/nowhere/repo/.git/worktrees/x")

// The three layouts where the repository's git directory is NOT the checkout's own `.git`, each
// built by running git. This is where reading a path for its `.git` component gave the wrong answer
// or none at all.
let ws = workspace.path

// A submodule, and a parallel line cut from the submodule rather than from the superproject. git
// keeps the submodule's bookkeeping at `<super>/.git/modules/<name>`, so the worktree's gitdir line
// names a path that contains the SUPERPROJECT's `.git`. The submodule is reached through a link in
// the workspace folder, which is how a subproject someone works on directly earns its own row (a
// submodule's own directory sits inside a checkout, and the allow-list does not look inside those).
gitRepository(at: home.path + "/src/sub")
gitRepository(at: ws + "/super")
sh("git -C '\(ws)/super' -c protocol.file.allow=always -c user.email=t@t -c user.name=t "
    + "submodule add -q '\(home.path)/src/sub' sub")
sh("git -C '\(ws)/super/sub' worktree add -q '\(ws)/sub-feature' -b sub-feat")
try! manager.createSymbolicLink(atPath: ws + "/subproject", withDestinationPath: ws + "/super/sub")

// A repository created with `--separate-git-dir`: the checkout's `.git` is a file naming a git
// directory that is not called `.git` and does not sit in the checkout. git records the way back
// nowhere, which is why the map matches on the git directory instead of trying to find one.
// The parent has to exist first: git refuses to place a separate git dir under a missing folder.
try! manager.createDirectory(atPath: home.path + "/gitdirs", withIntermediateDirectories: true)
gitRepository(at: ws + "/separate", "--separate-git-dir='\(home.path)/gitdirs/separate.git'")
sh("git -C '\(ws)/separate' worktree add -q '\(ws)/separate-feature' -b sep-feat")

// A bare repository has no checkout at all, so its worktrees have no row to fold into.
gitRepository(at: home.path + "/src/bare-src")
sh("git clone -q --bare '\(home.path)/src/bare-src' '\(home.path)/gitdirs/bare.git'")
sh("git -C '\(home.path)/gitdirs/bare.git' worktree add -q '\(ws)/bare-feature' -b bare-feat")

// A worktree that has already been torn down: no directory, no `.git` file, only the note teardown
// wrote before removing it. Written through the same API the CLI writes it with, so the writer and
// the reader cannot drift into two spellings of one file.
// Deliberately NOT named `<repo>-<name>` beside its repository, which is where `tally claude -w`
// puts one: that spelling is a dash-prefix of the repository's own flattened path, so an agent's
// transcript folder would fold by the prefix rule whether the note existed or not, and the test
// would pass over a map that had stopped reading it. This one is a parallel line of `taiwanbigdata/
// geo` cut at the top level (the `geo-admin` shape, which is real), where nothing but the note says
// so.
WorktreeOrigins.record(WorktreeOrigin(worktree: ws + "/geo-gone", resolved: nil,
                                      repository: ws + "/taiwanbigdata/geo",
                                      removedAt: "2026-08-06T00:00:00Z"),
                       in: WorktreeOrigins.fileURL(home: home))
// And one whose repository this machine no longer has, which must place nothing.
WorktreeOrigins.record(WorktreeOrigin(worktree: ws + "/elsewhere-gone", resolved: nil,
                                      repository: "/nowhere/repo", removedAt: nil),
                       in: WorktreeOrigins.fileURL(home: home))
// A worktree that is still on disk here, but which a teardown has already recorded the removal of:
// the state the scan sees when `tally worktree remove` is running while it scans. The scan folds it
// off its `.git` file (still there for a moment longer) and would write a live note for it, which
// must not overwrite the record of a line that is closing.
WorktreeOrigins.record(WorktreeOrigin(worktree: ws + "/specai-relative", resolved: nil,
                                      repository: resolved(ws + "/specai"),
                                      removedAt: "2026-08-06T00:00:00Z"),
                       in: WorktreeOrigins.fileURL(home: home))

let map = TokenProjectMap.current(home: home)

// MARK: The fixtures are the layouts git really writes

section("the real-git fixtures have the shapes the map is written against")

// Read back before anything is asserted about attribution. A git that changed what it writes has to
// fail HERE, saying the fixture moved, rather than silently turning the assertions below into a
// test of nothing.
check(gitDirLine(of: ws + "/sub-feature").contains("/super/.git/modules/sub/worktrees/"),
      "a submodule's worktree points into the superproject's modules dir (the old rule's trap)")
check(gitDirLine(of: ws + "/subproject").contains("modules/sub"),
      "and the submodule's own checkout points at that same modules dir")
// Asserted on the ending rather than the whole line: git writes the path it resolved, and a temp
// folder on macOS is reached through a symlink (`/var` -> `/private/var`), so the two spellings of
// the same directory are both correct answers.
let separateGitDirLine = gitDirLine(of: ws + "/separate")
check(separateGitDirLine.hasSuffix("/gitdirs/separate.git") && !separateGitDirLine.contains("/.git"),
      "a --separate-git-dir checkout names a git dir that is not called .git")
let separateConfig = (try? String(contentsOfFile: home.path + "/gitdirs/separate.git/config",
                                  encoding: .utf8)) ?? ""
check(!separateConfig.contains("worktree"),
      "and git writes NO core.worktree there, so nothing can read the checkout back out of it")
check(gitDirLine(of: ws + "/bare-feature").contains("/gitdirs/bare.git/worktrees/"),
      "a bare repository's worktree points into the bare dir, which is nobody's checkout")

// MARK: Worktrees

section("a worktree is folded into the repository it was cut from")

check(map.key(forCWD: ws + "/tally") == ws + "/tally", "the repository is still its own row")
check(map.key(forCWD: ws + "/tally-release") == ws + "/tally",
      "the worktree's own directory is credited to the repository")
check(map.key(forCWD: ws + "/tally-release/Tally/Views") == ws + "/tally",
      "a directory inside the worktree is credited to the repository")
check(map.key(forCWD: ws + "/taiwanbigdata/geo-auth/app") == ws + "/taiwanbigdata/geo",
      "a worktree of a repository under a container folds into that container's child, not the container")
check(map.key(forCWD: ws + "/geo-admin") == ws + "/taiwanbigdata/geo",
      "a top-level worktree finds its repository under a container")
check(map.key(forCWD: ws + "/specai-relative/src") == ws + "/specai",
      "a relative gitdir link resolves to the repository")

section("a worktree of a repository whose git directory is elsewhere")

// The regression this group exists for: read for a `.git` component, the submodule's bookkeeping
// path `<super>/.git/modules/sub/worktrees/wt1` answers "the superproject", so a parallel line of
// work on the submodule was billed to the product it is embedded in. The right answer comes from
// that git directory's own `core.worktree`.
check(map.key(forCWD: ws + "/sub-feature") == ws + "/subproject",
      "a submodule's worktree folds into the submodule's own row")
check(map.key(forCWD: ws + "/sub-feature") != ws + "/super",
      "and never into the superproject it is embedded in")
check(map.key(forCWD: ws + "/sub-feature/app") == ws + "/subproject",
      "a directory inside it folds the same way")
check(map.key(forCWD: ws + "/subproject") == ws + "/subproject",
      "the submodule's own checkout is still its own row, not a worktree of anything")
check(map.key(forCWD: ws + "/separate-feature") == ws + "/separate",
      "a --separate-git-dir repository's worktree folds into the checkout sharing its git dir")
check(map.key(forCWD: ws + "/separate") == ws + "/separate",
      "that repository keeps its own row")
check(map.key(forCWD: ws + "/bare-feature") == ws + "/bare-feature",
      "a bare repository has no checkout to fold into, so its worktree keeps its own row")

section("a worktree that has been torn down keeps its repository's row")

// The half that the filesystem can no longer answer: the directory is gone, so only the note
// teardown wrote before removing it says whose parallel line those sessions were. Without this a
// full rescan (which a cache version bump forces, and this delivery bumped one) would pool the
// repository's own history into Other, which is what keeping the transcripts was meant to prevent.
check(map.key(forCWD: ws + "/geo-gone") == ws + "/taiwanbigdata/geo",
      "a removed worktree's directory is still credited to the repository")
check(map.key(forCWD: ws + "/geo-gone/app") == ws + "/taiwanbigdata/geo",
      "so is a directory inside it")
check(map.key(forCWD: agentDirectory(serving: ws + "/geo-gone")) == ws + "/taiwanbigdata/geo",
      "and an agent's transcript folder, which is the spelling that actually outlives the worktree")
check(map.key(forCWD: ws + "/elsewhere-gone") == TokenProject.otherKey,
      "a note naming a repository this machine no longer has places nothing")

section("an unreadable link leaves the directory a project of its own")

check(map.key(forCWD: ws + "/broken") == ws + "/broken",
      "a `.git` file with no gitdir line falls back to a plain checkout")
check(map.key(forCWD: ws + "/broken/src") == ws + "/broken",
      "and still claims what sits inside it")
check(map.key(forCWD: ws + "/orphan") == ws + "/orphan",
      "a worktree whose repository is outside the workspace keeps its own row")

// MARK: Transcript folders

section("an agent's transcript folder folds with its worktree")

/// Where an agent serving `cwd` runs: inside the transcript tree of the project it serves.
func agentDirectory(serving cwd: String) -> String {
    home.path + "/.claude/projects/" + transcriptFolder(for: cwd) + "/subagents/s1"
}

check(map.key(forCWD: agentDirectory(serving: ws + "/tally-release")) == ws + "/tally",
      "an agent working in the worktree is credited to the repository")
check(map.key(forCWD: agentDirectory(serving: ws + "/tally-release/Tally")) == ws + "/tally",
      "so is one working below it")
check(map.key(forCWD: agentDirectory(serving: ws + "/taiwanbigdata/geo-auth")) == ws + "/taiwanbigdata/geo",
      "the container case folds in the flattened spelling too")
check(map.key(forCWD: agentDirectory(serving: ws + "/tally")) == ws + "/tally",
      "an agent working in the repository itself is unaffected")
check(map.key(forCWD: agentDirectory(serving: ws + "/broken")) == ws + "/broken",
      "an unfolded checkout still answers for its own agents")
check(map.key(forCWD: home.path + "/.claude/hooks") == home.path + "/.claude",
      "work on the harness itself is still the config home's own row")

// MARK: Pooling

section("everything else still pools")

check(map.key(forCWD: nil) == TokenProject.otherKey, "a session with no directory pools")
check(map.key(forCWD: "/private/tmp/build") == TokenProject.otherKey,
      "a directory outside the home pools")
check(map.key(forCWD: ws + "/tally-release/scratchpad/x") == TokenProject.otherKey,
      "a scratch directory pools even inside a folded worktree")

// MARK: The scan writes down what it folded

section("a live worktree's origin is written down while it is still live")

/// A file's contents and modification time together, which is what "this was not rewritten" has to
/// mean: a scan that rewrote the ledger with the records it already held would leave the bytes
/// identical and move the timestamp, so comparing either one alone would pass over it.
func fileStamp(_ url: URL) -> String {
    let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate]
    return "\((modified as? Date)?.timeIntervalSince1970 ?? 0)\n\(contents)"
}

/// The map records a repository by its resolved path, and every path in this fixture is reached
/// through the symlink macOS puts in front of the temp folder (`/var` -> `/private/var`).
func resolved(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(path, &buffer).map { String(cString: $0) } ?? path
}

let ledger = WorktreeOrigins.fileURL(home: home)
let recorded = WorktreeOrigins.load(from: ledger)

// Building the map above folded `geo-admin` into `taiwanbigdata/geo` off its `.git` file. That
// file is the only thing that says so, and a worktree removed by hand (a bare `git worktree
// remove`, or `rm -rf` on the directory) takes it away without ever running the teardown that
// would have written the note. So the fold writes it: the note is on file while the worktree is
// still open, whichever way it later ends.
let liveNote = recorded.first { $0.paths.contains(ws + "/geo-admin") }
check(liveNote?.repository == resolved(ws + "/taiwanbigdata/geo"),
      "the scan recorded the live worktree's repository, resolved")
check(liveNote?.removedAt == nil, "and recorded it as still open (no removal time)")
check(recorded.contains { $0.paths.contains(ws + "/tally-release") },
      "every folded worktree gets one, not just the first")
check(!recorded.contains { $0.paths.contains(ws + "/bare-feature") },
      "a worktree with no checkout to fold into records nothing")
check(recorded.filter { $0.worktree == ws + "/geo-gone" }.count == 1,
      "and an existing note for a worktree that is already gone is left alone")
// The race with a teardown running over the same file: the scan sees a worktree that is still on
// disk and a record saying it has been removed. The record wins - it knows the line is closed, the
// scan only knows the directory has not gone yet, and both agree on the repository.
check(recorded.first { $0.worktree == ws + "/specai-relative" }?.removedAt == "2026-08-06T00:00:00Z",
      "the scan does not overwrite a teardown's record of a worktree it can still see")

// The scan runs on a background queue every time the Tokens tab is looked at, and its answer for
// the same tree is the same every time, so the second pass must not touch the file at all.
let stamp = fileStamp(ledger)
usleep(20_000)   // so an identical rewrite is visible in the timestamp rather than a coin flip
_ = TokenProjectMap.current(home: home)
check(fileStamp(ledger) == stamp, "a second scan of an unchanged tree does not rewrite the ledger")

// The point of writing it early, exercised the way it really happens: the directory disappears
// without teardown ever running, and the sessions that ran there keep the repository's row.
try! manager.removeItem(at: directory("geo-admin"))
let afterBareRemoval = TokenProjectMap.current(home: home)
check(afterBareRemoval.key(forCWD: ws + "/geo-admin") == ws + "/taiwanbigdata/geo",
      "a worktree removed WITHOUT teardown still credits its directory to the repository")
check(afterBareRemoval.key(forCWD: agentDirectory(serving: ws + "/geo-admin")) == ws + "/taiwanbigdata/geo",
      "and its agents' transcript folders, which is the spelling that outlives the directory")

// MARK: Cache version

section("the cache version moves with the attribution rule")

// Attribution is baked into the cached entries, so this rule change is only complete if the cache
// version was bumped with it (TokenStatsEngine.Cache.currentVersion); otherwise entries written
// before it keep crediting worktrees to rows of their own and the table mixes both rules. Read
// from the source rather than linked, so this suite stays the map's closure and nothing more.
let engineSource = (try? String(contentsOfFile: "Tally/Core/TokenStats/TokenStatsEngine.swift",
                                encoding: .utf8)) ?? ""
let marker = "static let currentVersion = "
let cacheVersion = engineSource.split(separator: "\n")
    .first(where: { $0.contains(marker) })
    .flatMap { Int($0.trimmingCharacters(in: .whitespaces).dropFirst(marker.count)) }
// Pinned, not `>=`: the next attribution change has to fail here and be bumped past 6 deliberately.
check(cacheVersion == 6, "the cache version is 6, the git-directory reading of the worktree-folding rule (found \(cacheVersion.map(String.init) ?? "nothing"))")

try? manager.removeItem(at: home)

print(failures == 0 ? "\nAll token project map tests passed."
                    : "\n\(failures) token project map test(s) failed.")
exit(failures == 0 ? 0 : 1)
