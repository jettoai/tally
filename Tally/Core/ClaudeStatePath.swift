import Foundation

// Where Claude Code keeps a config dir's non-secret state file, named the way Claude Code names it.
//
// Shared by BOTH targets rather than reimplemented in each (project.yml compiles this file into the
// CLI as well as the app): `tally add` reads it to carry folder trust to a new account, and the
// app's account cards read it for the signed-in plan and email. Two copies of one path rule fail
// silently - the wrong file either does not exist (reads as "nothing trusted yet") or is a stale
// leftover copy that happens to agree today and names the previous account tomorrow.

/// The state file (`.claude.json`) of a config dir, which is not simply "inside the config dir".
///
/// The default home is the exception: `~/.claude` keeps its state one level UP, at `~/.claude.json`,
/// while `~/.claude2` keeps it at `~/.claude2/.claude.json`.
func claudeStateFile(forConfigDir dir: URL) -> URL {
    dir.lastPathComponent == ".claude"
        ? dir.deletingLastPathComponent().appendingPathComponent(".claude.json")
        : dir.appendingPathComponent(".claude.json")
}
