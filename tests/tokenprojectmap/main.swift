import Foundation

// Assertions for which project row a working directory is credited to (Tally/Core/TokenStats/
// TokenProjectMap.swift), built against a fixture workspace on disk rather than the machine's own,
// so the answers are the same on every machine. The rule under test here is the newest one: a git
// worktree is a parallel line of work on a repository, not a project beside it, so its directories
// and its agents' transcript folders belong to the repository's row.

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

/// A git directory that is not its checkout's own `.git`, as git writes one for a submodule and for
/// `--separate-git-dir`: `core.worktree` names the checkout, absolute or relative to this directory.
/// `worktree` is nil for a bare repository, which has no checkout to name.
func gitDirectory(at path: String, worktree: String?) {
    try! manager.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
    var config = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n"
    if let worktree { config += "\tworktree = \(worktree)\n" }
    try! config.write(to: URL(fileURLWithPath: path + "/config"), atomically: true, encoding: .utf8)
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

// The three layouts where the repository's git directory is NOT the checkout's own `.git`, which
// is where reading the path for a `.git` component gave the wrong answer or none.

// A submodule, and a parallel line cut from the submodule (not from the superproject). git keeps
// the submodule's bookkeeping at `<super>/.git/modules/<name>`, whose `core.worktree` is written
// relative to it, and the submodule's own checkout carries a `.git` file pointing there. The
// submodule is reached through a link in the workspace folder, which is how a subproject someone
// works on directly gets its own row.
repository("super")
checkout("super/sub", dotGit: "gitdir: ../.git/modules/sub\n")
gitDirectory(at: workspace.path + "/super/.git/modules/sub", worktree: "../../../sub")
try! manager.createSymbolicLink(atPath: workspace.path + "/subproject",
                                withDestinationPath: workspace.path + "/super/sub")
worktree("sub-feature", of: workspace.path + "/super/.git/modules/sub/worktrees/wt1")

// A repository created with `--separate-git-dir`: the checkout's `.git` is a file, the git
// directory lives elsewhere, and `core.worktree` there names the checkout absolutely.
checkout("separate", dotGit: "gitdir: \(home.path)/gitdirs/separate.git\n")
gitDirectory(at: home.path + "/gitdirs/separate.git", worktree: workspace.path + "/separate")
worktree("separate-feature", of: home.path + "/gitdirs/separate.git/worktrees/wt")

// A bare repository has no checkout to fold into, so its worktrees keep their own rows.
gitDirectory(at: home.path + "/gitdirs/bare.git", worktree: nil)
worktree("bare-feature", of: home.path + "/gitdirs/bare.git/worktrees/wt")

let map = TokenProjectMap.current(home: home)
let ws = workspace.path

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
      "a --separate-git-dir repository's worktree folds into the checkout core.worktree names")
check(map.key(forCWD: ws + "/separate") == ws + "/separate",
      "that repository keeps its own row")
check(map.key(forCWD: ws + "/bare-feature") == ws + "/bare-feature",
      "a bare repository has no checkout to fold into, so its worktree keeps its own row")

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
