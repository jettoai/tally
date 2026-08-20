import Darwin
import Foundation

// THE ADVISORY KNOCK, FILED RATHER THAN TYPED: one sentence left on disk for the session's own
// Claude Code to pick up through a hook, instead of pushed into its terminal as keystrokes.
//
// WHY A FILE AT ALL. The typed channel (SessionInput.swift) may only write into a composer nobody
// else is using, so it holds for a conversation mid-turn, for somebody at the keyboard, and for a
// child about to be replaced. Those holds are right for keystrokes and they are exactly wrong for
// this feature: the session the knock exists for is the one in the middle of a work package
// (QuotaKnockLogic.swift argues why), which is the one state the typed channel can never reach.
// A file is written while the session is busy, is delivered by the session's own hook run, and
// interleaves with nothing.
//
// ONE SLOT PER SUPERVISOR, on the track every other hook fact on this repo uses
// (`supervisorStateDir`, one file per pid under a suffix of its own). The supervisor writes it, the
// hook consumes it exactly once, and the ways that can go wrong are the two this file is shaped
// around: it must not be read twice (`claimQuotaKnockNotice` renames before it reads) and it must
// not outlive the news it carries (`clearQuotaKnockNotice` is what a re-arm calls).
//
// IT IS KEPT PRIVATE, unlike its neighbours on this track. What sits in here is a sentence that is
// about to be inserted into somebody's conversation, which is the same class of content
// `sessionInputLogMode` and `sessionInputFileMode` argue for at length: content rather than
// telemetry, and the default mode hands it to every other uid on the machine. The technique below
// is the request channel's own (`writeSessionInputPrivately`) rather than a call into it, because
// that function also narrows the directory it writes into and leaves an audit line when it cannot,
// neither of which belongs on a track shared with the drift badge and the session board.
//
// DEPENDENCY-LIGHT ON PURPOSE, the split HookNotify.swift keeps from UserNotice.swift: the suffix
// list in PendingNotice.swift needs the constant below, three test harnesses compile that list, and
// none of them may have to bring a subcommand's whole world along to get it.

/// The suffix separating a filed knock from the presence/drift file of the same pid.
let quotaKnockNoticeSuffix = ".knock"

/// The mode a filed knock is kept at: readable by its owner and by nobody else. Spelled here rather
/// than borrowed from the request channel so this file stays free of it (see the head), and equal to
/// it by assertion instead (tests/supervisor/knockchannelchecks.swift).
let quotaKnockNoticeMode = 0o600

/// One sentence the supervisor has filed for this session's Claude Code to be told.
///
/// ADDITIVE FOR EVER, which is the compatibility rule this whole track is under
/// (RequestTranscript.swift and TranscriptIdentity.swift state it where the plain-text formats make
/// it a matter of column order): an old supervisor and a new CLI coexist for as long as a session
/// runs, so a field may be appended and may never change meaning. Keyed JSON is what makes that
/// cheap here, and every field added later has to be optional for the same reason.
struct QuotaKnockNotice: Codable, Equatable, Sendable {
    /// The whole sentence, exactly as the typed channel would have typed it
    /// (`quotaKnockMessage`), byte budget included. One text for both channels, so what a session is
    /// told never depends on how it was told.
    var message: String
    /// When the supervisor filed it. THE STAMP IS THE FILING'S, NOT THE FILE'S, the rule
    /// `SessionTurnEnd.at` and `UserNotice.at` are both under: copying or touching the file cannot
    /// make the reading behind this sentence look fresher than it was.
    var at: Date
}

/// The file a supervisor's filed knock lives in.
func quotaKnockNoticeFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + quotaKnockNoticeSuffix)
}

/// File the sentence: nil when it is on disk, and the errno when it is not.
///
/// An answer rather than a `try?`, because the caller has already spent this drought's one
/// announcement by the time it gets here (`applyQuotaKnock` states that rule and why it is that way
/// round), so a write that failed is the one thing it has to be able to record.
///
/// PRIVATE AND ATOMIC IN ONE ACT, for the reason `writeSessionInputPrivately` gives in full: a
/// rename carries the mode of the inode it MOVES, so a destination pre-created at 0600 buys nothing,
/// and `FileManager.createFile` applies its attributes after creating under the umask, so the bytes
/// exist at 0644 for a window that no measurement taken afterwards can see. `open(2)` takes the mode
/// as an argument of the creating call, and `O_EXCL` makes a leftover temporary an error rather than
/// a silent overwrite.
@discardableResult
func writeQuotaKnockNotice(_ notice: QuotaKnockNotice, pid: String,
                           dir: URL = supervisorStateDir) -> Int32? {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // Whole seconds are enough here, unlike the two events this track compares against transcript
    // instants: nothing decides anything by how this stamp orders against another clock. It is read
    // by a person asking how old an undelivered sentence is.
    guard let data = try? encoder.encode(notice) else { return EINVAL }
    let temp = dir.appendingPathComponent(".\(pid)\(quotaKnockNoticeSuffix).\(UUID().uuidString)")
    let handle = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(quotaKnockNoticeMode))
    guard handle >= 0 else { return errno }
    var failure: Int32?
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = write(handle, bytes.baseAddress!.advanced(by: offset),
                                bytes.count - offset)
            // A short write is the rest of the loop rather than a failure, and a signal landing
            // mid-write is not even that.
            if written < 0 {
                guard errno == EINTR else { failure = errno; return }
                continue
            }
            offset += written
        }
    }
    // CLOSING IS PART OF WRITING: a filesystem may hold a write error back until the descriptor is
    // closed, so bytes every `write` accepted can still be incomplete until this returns. Closed
    // exactly once whatever it answers, since the descriptor is gone even when close reports an
    // error.
    let closeFailure = close(handle) == 0 ? nil : errno
    if let failure = failure ?? closeFailure {
        try? FileManager.default.removeItem(at: temp)
        return failure
    }
    guard rename(temp.path, quotaKnockNoticeFile(pid: pid, dir: dir).path) == 0 else {
        let code = errno
        try? FileManager.default.removeItem(at: temp)
        return code
    }
    return nil
}

/// The sentence filed for this session, WITHOUT consuming it: what a supervisor asks to see whether
/// something it filed is still undelivered, and nil when there is nothing there (or the file is from
/// a format this build does not know, which reads the same way: nothing filed).
///
/// Deliberately separate from the claim below. A reader that consumed what it looked at could not be
/// used to observe, and observing is the whole of what makes "written but never delivered" a state
/// anybody can see: an idle session has no next turn, so its hook may never run at all.
func readQuotaKnockNotice(pid: String, dir: URL = supervisorStateDir) -> QuotaKnockNotice? {
    decodeQuotaKnockNotice(try? Data(contentsOf: quotaKnockNoticeFile(pid: pid, dir: dir)))
}

/// TAKE the sentence: exactly one caller can ever get a given notice, and it is gone afterwards.
///
/// THE RENAME IS THE CLAIM, and it has to be, because the readers race. Claude Code fires the hooks
/// this is delivered through several times a turn and runs them concurrently with each other, so
/// "read the file, then unlink it" would hand the same sentence to two hook runs and put it into the
/// conversation twice. `rename(2)` is atomic and answers ENOENT to everybody but the winner, which
/// is what makes the loser's answer here nil rather than a duplicate.
///
/// A private name, so a loser cannot claim the winner's copy either, and the read happens after the
/// file is out of the way: from that point the bytes belong to this process alone.
func claimQuotaKnockNotice(pid: String, dir: URL = supervisorStateDir) -> QuotaKnockNotice? {
    let claim = dir.appendingPathComponent(
        ".\(pid)\(quotaKnockNoticeSuffix).claim.\(UUID().uuidString)")
    guard rename(quotaKnockNoticeFile(pid: pid, dir: dir).path, claim.path) == 0 else { return nil }
    let notice = decodeQuotaKnockNotice(try? Data(contentsOf: claim))
    try? FileManager.default.removeItem(at: claim)
    return notice
}

/// The one decoder both readers use, so a format this build cannot read means the same thing to
/// each of them.
private func decodeQuotaKnockNotice(_ data: Data?) -> QuotaKnockNotice? {
    guard let data else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(QuotaKnockNotice.self, from: data)
}

/// The filed sentence is no longer the news it was: take it back before anybody is told.
///
/// What a re-arm calls (`applyQuotaKnock`). A drought that has ended is not a thing to announce when
/// the session finally submits a prompt an hour later, and the file is the only part of this feature
/// that survives the reading that made it: the arm itself is memory a supervisor holds
/// (QuotaKnockState), while this sits on disk until something reads it.
func clearQuotaKnockNotice(pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.removeItem(at: quotaKnockNoticeFile(pid: pid, dir: dir))
}

/// And the same act at start-up: whatever is under this pid was filed by somebody else, so it goes.
///
/// THE ARM IS MEMORY AND THE FILE IS DISK, and a self-update is where those two part company. The
/// four ways a filed sentence can outlive the reading that made it are: the same image re-arming (the
/// re-arm above takes it back), the supervisor dying (the suffix is registered, so the dead-pid sweep
/// takes it), the session being handed to another account (a different `accountID` re-arms, so the
/// re-arm above takes it), and THIS ONE - `execv` replaces the image and KEEPS THE PID, so the sweep
/// does not see a dead session and the new `QuotaKnockState` starts with `fired = false`, which means
/// the re-arm transition can never fire. Left alone, a sentence about a drought that has since ended
/// sits there until the session's next prompt or tool call, and is then delivered as though it were
/// news.
///
/// The pending-notice track has had exactly this seam since it shipped, and answers it the same way:
/// its writer is seeded from the file so the first tick can take down a badge the replaced image
/// raised (`PendingNoticeWriter.init` argues it at length, with the two badges that survived their
/// own conditions for a whole session). This one has nothing to seed FROM - a knock is news rather
/// than a live wait, and the new image has announced nothing - so the honest reconciliation is to
/// discard, unconditionally.
///
/// UNCONDITIONAL RATHER THAN ON THE `resumed` PATH, and the two cases both want it: after a
/// self-update the file belongs to the image this one replaced, and on a normal launch the pid is
/// fresh and anything under it belongs to a session that is gone. What it costs on every launch is
/// one `unlink` that almost always answers ENOENT.
///
/// WHAT IT COSTS WHEN THE DROUGHT IS REAL: nothing lasting. The arm is empty too, so the next
/// reading (at most `quotaKnockInterval` away) finds the account still under the line and files the
/// sentence again, built from numbers that are current rather than from the ones the old image read.
func discardCarriedQuotaKnockNotice(pid: String, dir: URL = supervisorStateDir) {
    clearQuotaKnockNotice(pid: pid, dir: dir)
}
