import Foundation

// WHERE ANOTHER PROCESS CAN REACH A RUNNING CLAUDE CODE.
//
// Claude Code listens on one unix socket per session, in a machine-wide directory, named for the
// pid of the process listening on it: `/tmp/cc-socks/<pid>.sock`. That is the half of cross-session
// messaging which is NOT partitioned by config home. The peer roster a session publishes lives
// under `$CLAUDE_CONFIG_DIR/sessions/`, so two sessions launched on different accounts cannot see
// each other there at all, while their sockets sit side by side in this one directory. Tally
// supervises sessions on every account, which is exactly what makes it able to answer the question
// that roster cannot: which session is running in which project, and where to reach it.
//
// A TRIPWIRE, NOT AN API. This path is Claude Code's own undocumented convention, not something it
// promises anybody, so it is spelled once here: a version that moves or renames the directory
// breaks in one place rather than in every caller. What that break looks like matters as much as
// where it happens, and it is the reason the check below is for a socket that is really there right
// now rather than for a path that can be composed: a reader is handed an address only when one
// exists, so a Claude Code that has stopped using this directory publishes NO address instead of
// publishing one with nothing listening on it. Absent reads as "not reachable this way, use the
// file channel", which is the answer that stays true whatever the next version does (measured
// against the Claude Code running on this machine, 2026-08-11).
let claudeMessagingSocketDir = "/tmp/cc-socks"

/// The socket a Claude Code process is listening on, or nil when there is nothing there.
///
/// THE FILE IS LOOKED AT, AND ITS TYPE IS CHECKED, rather than the path being composed from a pid
/// and published. Whether Claude Code unlinks a socket when its session ends is not something this
/// can assume either way (this machine happened to hold exactly one per live session when it was
/// measured, 2026-08-11, which proves nothing about the moment after one exits), and an address
/// nobody is behind is the one answer worth ruling out. The type check is the other half: a regular
/// file left at that name is not something to dial.
///
/// The remaining ambiguity is a pid the OS has reused, and it is answered by the CALLER rather than
/// here: the only pids handed to this are ones already proved to be a live Claude Code that this
/// supervisor itself spawned (`readSupervisorChild`), so a socket found under that pid belongs to
/// the session being described and not to a stranger.
func claudeMessagingSocket(childPid: Int, dir: String = claudeMessagingSocketDir) -> String? {
    let path = "\(dir)/\(childPid).sock"
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          attributes[.type] as? FileAttributeType == .typeSocket else { return nil }
    return path
}
