import Foundation

// WHAT CLAUDE CODE ASKED THE USER FOR, and the only channel in this repo that carries it.
//
// "Waiting on a person" is the one thing the supervisor cannot see for itself. A transcript that
// has stopped moving looks identical whether the session finished its turn or is holding a
// permission dialog open, and every gate this repo has (`isQuiet`, the open tool call, the subagent
// walk, the terminal's atime) answers the first question rather than the second. So the signal
// comes from Claude Code's OWN `Notification` hook, which fires exactly when it wants the user: a
// permission request, and a prompt left unanswered long enough for it to say so.
//
// The hook writes a file per supervisor pid on the same track as everything else here
// (`supervisorStateDir`), and the supervisor's poll reads it back on its next tick. An event
// rather than a level: it is UNLINKED once the wait it describes has ended (SessionStateSync.swift
// decides when), so the file's presence is the whole of the blocked signal.

/// The suffix separating a user-notice event from the presence/drift file of the same pid.
let userNoticeSuffix = ".usernotice"

/// One thing Claude Code has asked for and not yet had.
struct UserNotice: Codable, Equatable, Sendable {
    /// The hook's own sentence ("Claude needs your permission to use Bash"), shown as the reason a
    /// session is waiting. Empty when the hook carried none, which is a wait with nothing to say
    /// about it rather than no wait.
    var message: String
    /// When the hook fired. The clock every clearing rule is measured against: an answer is
    /// anything that happened AFTER this instant, and something that happened before it cannot be
    /// the answer to it.
    var at: Date
    /// The conversation the hook named, when it named one. Written for the same reason the context
    /// reading publishes its transcript id: it is the only witness that binds an event to a
    /// session, where the environment marker is inherited by every descendant.
    var sessionID: String?
}

func userNoticeFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + userNoticeSuffix)
}

/// Record the event. Best-effort and atomic, like every other file on this track: a hook that
/// cannot write costs the blocked reading, never the session.
func writeUserNotice(_ notice: UserNotice, pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(notice) else { return }
    try? data.write(to: userNoticeFile(pid: pid, dir: dir), options: .atomic)
}

/// The event still standing against this session, or nil when there is none (or the file is from a
/// format this build does not know, which reads the same way: nothing is waiting).
func readUserNotice(pid: String, dir: URL = supervisorStateDir) -> UserNotice? {
    guard let data = try? Data(contentsOf: userNoticeFile(pid: pid, dir: dir)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(UserNotice.self, from: data)
}

/// The wait is over. Unlinked rather than emptied, because absence IS the signal here.
func clearUserNotice(pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.removeItem(at: userNoticeFile(pid: pid, dir: dir))
}
