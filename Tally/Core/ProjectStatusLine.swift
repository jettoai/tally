import Foundation

/// Whether a project folder's own Claude Code settings replace Tally's status line.
///
/// Claude Code merges settings user < project (`.claude/settings.json`) < local
/// (`.claude/settings.local.json`), and a `statusLine` set in a project file wins over the one in
/// the user's `settings.json` that Tally installs. Settings → Integrations only reads the user
/// files, so it kept saying "Installed" for a folder whose sessions never call `tally statusline`
/// (jettoai/tally#12).
///
/// One file compiled by both targets (project.yml): the app counts the overridden folders of its
/// running sessions, and `tally status --json` names the file per session. The command Tally
/// registers lives here for the same reason, so that "ours" has a single spelling.
enum ProjectStatusLine {
    /// What `IntegrationsStore` writes into the user's settings.json as the status line command.
    nonisolated static let ourCommand = "/usr/local/bin/tally statusline claude"

    /// The file that makes a session started in `cwd` ignore Tally's status line, or nil.
    ///
    /// Walks from `cwd` up to the repository root (the first folder holding a `.git`, file or
    /// directory, so worktrees stop too; with none, `cwd` alone), checking `settings.local.json`
    /// then `settings.json` in each `.claude/` (the order Claude Code ranks them). The first file
    /// that carries a `statusLine.command` decides: Tally's own command is no override. A missing,
    /// unreadable or unparsable file carries nothing. Read-only, never throws.
    ///
    /// `userHome` is skipped as a project folder: `~/.claude/settings.json` is the USER layer
    /// Tally manages, and a dotfiles repository at `~` would otherwise put it on every walk.
    nonisolated static func overridingFile(cwd: String, userHome: String = NSHomeDirectory()) -> String? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        let home = URL(fileURLWithPath: userHome).standardizedFileURL.path
        let hasGit = hasGitAbove(cwd: dir)
        while true {
            if dir.path != home {
                for name in ["settings.local.json", "settings.json"] {
                    let file = dir.appendingPathComponent(".claude/\(name)")
                    guard let data = try? Data(contentsOf: file),
                          let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let command = (settings["statusLine"] as? [String: Any])?["command"] as? String
                    else { continue }
                    return command.hasPrefix(ourCommand) ? nil : file.path
                }
            }
            let parent = dir.deletingLastPathComponent()
            if !hasGit || fm.fileExists(atPath: dir.appendingPathComponent(".git").path)
                || parent.path == dir.path { return nil }
            dir = parent
        }
    }

    /// Whether some folder from `cwd` upward holds a `.git`; without one the walk is `cwd` alone.
    private nonisolated static func hasGitAbove(cwd: URL) -> Bool {
        var dir = cwd
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return true }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return false }
            dir = parent
        }
    }
}
