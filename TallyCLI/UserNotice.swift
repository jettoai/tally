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

// MARK: - The clock this event is written on
//
// WHOLE SECONDS ARE NOT ENOUGH HERE, and that is the whole reason this file does not use the
// `.iso8601` strategy its neighbours do.
//
// `at` exists to be compared against a transcript's mtime, which is nanosecond-precise, and the two
// events it separates land in the SAME SECOND as a matter of course: a tool call writes its result
// at T.600 and the permission prompt for the next one fires at T.900. Encoded to whole seconds, `at`
// decodes as T.000, the mtime is greater, and `userNoticeStillOpen` reads a write that happened
// BEFORE the prompt as the answer to it. The first tick after the prompt then clears it, and a
// permission request never reaches the board at all.
//
// So this pair is millisecond-precise and symmetric. Its neighbours are unaffected: nothing compares
// `SessionStateRecord.since` against another clock (it is rendered as an age and preserved by value),
// and `PendingNotice.since` is the same.

/// Built per call rather than held in a global, which is the house pattern here
/// (`recordManifest` does the same) and the only one this target's strict concurrency accepts:
/// `ISO8601DateFormatter` is not `Sendable`, so a global one is a shared mutable box the compiler
/// refuses. It costs an allocation on a path that runs once per hook and once per 2s tick.
private func fractionalNoticeFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}

private func encodeNoticeDate(_ date: Date, _ encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(fractionalNoticeFormatter().string(from: date))
}

/// The fractional form first, then the plain one: a notice on disk across the upgrade that
/// introduced the fractional clock is at most one wait old, but reading it as unparseable would
/// DROP that wait, and dropping a wait is the failure this whole file exists to prevent.
private func decodeNoticeDate(_ decoder: Decoder) throws -> Date {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let date = fractionalNoticeFormatter().date(from: raw)
        ?? ISO8601DateFormatter().date(from: raw)
    else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "not an ISO 8601 instant"))
    }
    return date
}

/// Record the event. Best-effort and atomic, like every other file on this track: a hook that
/// cannot write costs the blocked reading, never the session.
func writeUserNotice(_ notice: UserNotice, pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom(encodeNoticeDate)
    guard let data = try? encoder.encode(notice) else { return }
    try? data.write(to: userNoticeFile(pid: pid, dir: dir), options: .atomic)
}

/// The event still standing against this session, or nil when there is none (or the file is from a
/// format this build does not know, which reads the same way: nothing is waiting).
func readUserNotice(pid: String, dir: URL = supervisorStateDir) -> UserNotice? {
    guard let data = try? Data(contentsOf: userNoticeFile(pid: pid, dir: dir)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom(decodeNoticeDate)
    return try? decoder.decode(UserNotice.self, from: data)
}

/// The wait is over. Unlinked rather than emptied, because absence IS the signal here.
func clearUserNotice(pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.removeItem(at: userNoticeFile(pid: pid, dir: dir))
}

/// Take the answered event away, BUT ONLY IF IT IS STILL THE ONE THAT WAS JUDGED.
///
/// Reading an event, deciding it has been answered and unlinking it are three steps with nothing
/// holding the path still between them, and the hook replaces that file by atomic rename at any
/// moment: a permission prompt landing in that gap would be deleted unread, leaving somebody
/// waiting on a session the board calls idle. Comparing the instant (millisecond-precise, which is
/// what makes two events one second apart distinguishable at all) narrows the window to the
/// microseconds between this read and the unlink.
///
/// IT IS NOT A COMPARE-AND-SWAP AND MUST NOT BE READ AS ONE: the file system offers no
/// rename-if-unchanged, so a write landing inside that last window is still lost. What keeps even
/// that recoverable is the SHAPE of the loss - a delete rather than a wrong answer, so the board
/// reads idle for a session that is waiting, which is the degradation an unregistered hook already
/// gives, and the next prompt republishes.
///
/// A function of its own rather than three lines at the call site because the property being
/// claimed ("only the judged event is removed") is the whole of what makes the narrowing worth
/// anything, and a property nothing can state is a property nothing can hold onto.
func clearAnsweredUserNotice(_ judged: UserNotice, pid: String, dir: URL = supervisorStateDir) {
    guard readUserNotice(pid: pid, dir: dir)?.at == judged.at else { return }
    clearUserNotice(pid: pid, dir: dir)
}
