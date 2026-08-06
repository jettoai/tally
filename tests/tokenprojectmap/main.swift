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
// Pinned, not `>=`: the next attribution change has to fail here and be bumped past 5 deliberately.
check(cacheVersion == 5, "the cache version is 5, the worktree-folding rule (found \(cacheVersion.map(String.init) ?? "nothing"))")

try? manager.removeItem(at: home)

print(failures == 0 ? "\nAll token project map tests passed."
                    : "\n\(failures) token project map test(s) failed.")
exit(failures == 0 ? 0 : 1)
