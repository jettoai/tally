import Foundation

// Which project settings file replaces Tally's status line in a session's folder
// (ProjectStatusLine.swift, jettoai/tally#12). Scratch folders only, deleted at the end.
func runProjectStatusLineChecks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tally-psl-\(UUID())").resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: root) }
    let ours = ProjectStatusLine.ourCommand
    let home = root.appendingPathComponent("home").path

    func dir(_ path: String, git: Bool = false) throws -> URL {
        let d = root.appendingPathComponent(path)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        if git { try fm.createDirectory(at: d.appendingPathComponent(".git"), withIntermediateDirectories: true) }
        return d
    }
    func write(_ d: URL, _ name: String, _ body: String) throws {
        try fm.createDirectory(at: d.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try body.write(to: d.appendingPathComponent(".claude/\(name)"), atomically: true, encoding: .utf8)
    }
    func status(_ command: String) -> String { #"{"statusLine":{"type":"command","command":"\#(command)"}}"# }
    func found(_ d: URL) -> String? { ProjectStatusLine.overridingFile(cwd: d.path, userHome: home) }

    let repo = try dir("repo", git: true)
    let deep = try dir("repo/a/b")
    check("no settings anywhere is no override", found(deep) == nil)

    try write(deep, "settings.local.json", status("my-line"))
    check("a local file in the cwd overrides", found(deep) == deep.appendingPathComponent(".claude/settings.local.json").path)
    fm.createFile(atPath: deep.appendingPathComponent(".claude/settings.local.json").path, contents: nil)
    check("an empty (unparsable) file carries nothing", found(deep) == nil)
    try write(deep, "settings.local.json", "{not json")
    check("broken JSON is no override and does not throw", found(deep) == nil)
    try write(deep, "settings.local.json", #"{"statusLine":"x"}"#)
    check("a statusLine without a command carries nothing", found(deep) == nil)
    try fm.removeItem(at: deep.appendingPathComponent(".claude"))

    try write(deep, "settings.json", status("my-line"))
    check("a settings.json in the cwd overrides", found(deep) == deep.appendingPathComponent(".claude/settings.json").path)
    try write(deep, "settings.local.json", status("other"))
    check("local ranks above settings.json",
          found(deep) == deep.appendingPathComponent(".claude/settings.local.json").path)
    try write(deep, "settings.local.json", status(ours))
    check("a local file with Tally's own command decides: no override, even over a custom settings.json",
          found(deep) == nil)
    try write(deep, "settings.local.json", status("\(ours) --extra"))
    check("a command that starts with Tally's is Tally's", found(deep) == nil)
    try fm.removeItem(at: deep.appendingPathComponent(".claude"))

    // (a) shared settings.json is read from the session folder only: a parent's is never loaded.
    try write(repo, "settings.json", status("root-line"))
    check("a shared settings.json at the repo root is not read from a subfolder", found(deep) == nil)
    check("…but it is read when the session starts at the root",
          found(repo) == repo.appendingPathComponent(".claude/settings.json").path)
    try fm.removeItem(at: repo.appendingPathComponent(".claude"))

    // (b) the local file lives at the repo root and outranks the cwd's shared file.
    try write(deep, "settings.json", status(ours))
    try write(repo, "settings.local.json", status("root-local"))
    check("a root settings.local.json overrides a Tally settings.json in the subfolder",
          found(deep) == repo.appendingPathComponent(".claude/settings.local.json").path)
    try write(deep, "settings.local.json", status("legacy-local"))
    check("the root's local file outranks a legacy one left in the subfolder",
          found(deep) == repo.appendingPathComponent(".claude/settings.local.json").path)
    try fm.removeItem(at: repo.appendingPathComponent(".claude"))
    check("a legacy local file left in the subfolder is still read",
          found(deep) == deep.appendingPathComponent(".claude/settings.local.json").path)
    try fm.removeItem(at: deep.appendingPathComponent(".claude"))

    try write(root, "settings.json", status("above-root"))
    check("nothing above the git root is looked at", found(deep) == nil)
    try fm.removeItem(at: root.appendingPathComponent(".claude"))

    let plain = try dir("plain/sub")
    try write(root.appendingPathComponent("plain"), "settings.json", status("parent-line"))
    check("without a .git only the cwd is looked at", found(plain) == nil)
    try write(plain, "settings.json", status("own-line"))
    check("…and the cwd itself still counts", found(plain) == plain.appendingPathComponent(".claude/settings.json").path)

    // (c) a worktree: the local file is the main checkout's root one.
    let main = try dir("main", git: true)
    let mainSub = try dir("main/sub")
    try fm.createDirectory(at: main.appendingPathComponent(".git/worktrees/wt"), withIntermediateDirectories: true)
    let worktree = try dir("wt/sub")
    try "gitdir: \(main.path)/.git/worktrees/wt\n".write(
        to: root.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)
    check("a worktree with no settings anywhere is no override", found(worktree) == nil)
    try write(main, "settings.local.json", status("main-local"))
    check("a worktree reads the main checkout's root settings.local.json",
          found(worktree) == main.appendingPathComponent(".claude/settings.local.json").path)
    check("…and so does a subfolder of the main checkout",
          found(mainSub) == main.appendingPathComponent(".claude/settings.local.json").path)
    try write(root.appendingPathComponent("wt"), "settings.json", status("wt-line"))
    check("the worktree's own shared file is read only from the session folder", found(worktree) == main.appendingPathComponent(".claude/settings.local.json").path)
    try fm.removeItem(at: main.appendingPathComponent(".claude"))
    check("a worktree root's shared settings.json is not read from its subfolder", found(worktree) == nil)
    try "gitdir: /elsewhere/modules/x".write(
        to: root.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)
    try write(root.appendingPathComponent("wt"), "settings.local.json", status("sub-local"))
    check("a .git file that is not a worktree (submodule) is its own root",
          found(worktree) == root.appendingPathComponent("wt/.claude/settings.local.json").path)

    let homeDir = try dir("home", git: true)
    try write(homeDir, "settings.json", status("user-layer"))
    check("the user's home is the user layer, not a project",
          found(try dir("home/proj")) == nil && found(homeDir) == nil)
    check("a folder that does not exist is no override",
          ProjectStatusLine.overridingFile(cwd: root.appendingPathComponent("nope/x").path, userHome: home) == nil)
}
