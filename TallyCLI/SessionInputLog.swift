import Foundation

// WHAT WAS TYPED INTO A SESSION, AND WHEN: the one file that answers that question afterwards.
//
// Split from SessionInput.swift, which keeps the decision and the terminal write. The seam is the
// one every line here is on the far side of: nothing in this file decides anything, and everything
// in it is a sentence somebody reads back weeks later. It moved because the file it came from had
// outgrown the size a file in this repo may be.

/// The audit trail: one line per served request, so the answer to "what typed into my session, and
/// when" is never a matter of belief.
let sessionInputLog = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/logs/input.log")

/// One line per served request. Pure, so the shape can be asserted without a home directory - the
/// whole point of these fields is that somebody reads them back weeks later.
///
/// The TEXT GOES LAST, the rule `handoffLogLine` states about its own cwd: it is the one field that
/// can contain a space, so everything before it stays at a fixed offset for an eye or a `grep`. It
/// is truncated to 40 characters and stripped of anything that is not printable, because a control
/// byte written verbatim into a log is a log that reformats somebody's terminal when they `cat` it -
/// and because this file must show WHAT was typed without becoming a transcript of it.
///
/// THERE IS NO `submit` FIELD. There was, and it read `yes` on every line ever written once typing
/// and sending became one act: a column that cannot vary answers nothing anybody greps this file
/// for, and it costs the eye a stop on every line.
func sessionInputLogLine(pid: String, outcome: String, text: String,
                         now: Date = Date()) -> String {
    let visible = String(text.unicodeScalars.map { scalar -> Character in
        scalar.properties.isDefaultIgnorableCodePoint || scalar.value < 0x20 || scalar.value == 0x7F
            ? "·" : Character(scalar)
    }.prefix(40))
    return "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=\(outcome) "
        + "bytes=\(text.utf8.count) text=\(visible)\n"
}

/// The mode this log is kept at: readable by its owner and by nobody else.
///
/// DELIBERATELY UNLIKE ITS NEIGHBOURS, and this is the note for whoever comes to make it consistent.
/// Everything else under `~/.tally` is 0644 (`handoff.log`, the history, the state directory), and
/// that is right for what those files hold: accounts, quota windows, which session moved where -
/// events ABOUT the work. This one holds the work itself. Every line carries the first 40 characters
/// of text that was typed into a live conversation, which is content rather than telemetry, and the
/// default mode hands it to every other uid on the machine.
///
/// THE CONTENT STAYS AND THE MODE MOVES, which is the trade this feature is built on. An audit line
/// stripped of what was typed answers "somebody typed something" and nothing a person consulting
/// this log ever asks; the cost of keeping it is one chmod.
let sessionInputLogMode = 0o600

/// The line a lost answer leaves (grep `input=receipt-lost`): the request was SERVED, the text is
/// on the terminal (or the refusal was decided), and the file the caller is polling for could not be
/// written. So that caller waits out its timeout, is told nobody answered, and may reasonably send
/// the same line again - which is the one way this feature types a line into a conversation twice.
///
/// ITS OWN LINE BESIDE THE SERVED ONE rather than a field inside it, the shape
/// `sessionInputDirectoryModeLine` uses. The served line's business is what was typed, and it is
/// what a person greps when asking that; a failure carried as an extra column on it would be
/// invisible to every one of those greps, and the question this answers ("was I told?") is asked
/// separately from them.
func sessionInputReceiptLostLine(pid: String, outcome: String, epoch: Int, failure: String,
                                 now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=receipt-lost "
        + "served=\(outcome) epoch=\(epoch) failed=\(failure)\n"
}

/// The line a `/clear` that ended running subagents leaves (grep `input=agents-killed`): the line
/// was typed, and the session's context went with the work it had dispatched.
///
/// ITS OWN LINE BESIDE THE SERVED ONE, the shape above and for the same two reasons. The served
/// line's business is what was typed, and its fields are at a fixed offset for an eye and a `grep`,
/// which an occasional extra column in the middle of them would end. And the question this answers
/// ("where did my agents go") is asked separately from that one - by somebody who was not there:
/// the caller of a `/clear` is the session being cleared, and it has left with `queued` long before
/// its line lands, so the receipt naming the same count reaches nobody. This file is the reader.
func sessionInputAgentsKilledLine(pid: String, count: Int, now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=agents-killed count=\(count)\n"
}

// MARK: - What became of the draft under the line

/// The line a stashed composer leaves (grep `input=draft-stashed`): before the payload went in, this
/// many rounds of the two kill keys moved whatever was in that composer into its kill buffer
/// (SessionInputDraft.swift).
///
/// A COUNT OF PRESSES AND NOT OF THE DRAFT, because there is no honest number for the draft: the
/// supervisor cannot see the composer, which is the whole premise of the stash. What this file must
/// never do is grow a column that could only be filled by reading somebody's half-written prompt.
func sessionInputDraftStashedLine(pid: String, rounds: Int, now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=draft-stashed "
        + "rounds=\(rounds)\n"
}

/// The line a restored composer leaves (grep `input=draft-restored`): the draft went back in behind
/// the Return, so the person who left it there finds it where they left it.
func sessionInputDraftRestoredLine(pid: String, now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=draft-restored\n"
}

/// The line a stash nobody put back leaves (grep `input=draft-restore-dropped`), and the one of
/// these three that a person actually goes looking for: their composer is empty and they want to
/// know where it went. The answer is always the same and the reason says which road got there - the
/// text is in that composer's kill buffer, and Claude Code's own hint (`Ctrl+Y to paste deleted
/// text`) is on screen saying how to get it back.
///
/// THE REASONS ARE A CLOSED SET, named as constants next door so the writer and the reader cannot
/// drift: `sessionInputDraftDropReason*`.
func sessionInputDraftDroppedLine(pid: String, reason: String, now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=draft-restore-dropped "
        + "reason=\(reason)\n"
}

/// What one injection did about the draft under it, in the one to two lines it leaves.
///
/// ONE WRITER FOR BOTH STATIONS, and that is the reason it is a function rather than a switch at the
/// two call sites: `tally session send` and the advisory knock type through the same door under the
/// same guard, so a reader searching this file for their draft must not have to know which of them
/// was typing. Nothing is written where the stash never ran (a blocked session's composer is behind
/// its dialog, so nothing was touched and there is nothing to explain) or where nothing was typed at
/// all (a clear answered by moving the session).
func appendSessionInputDraftLines(pid: String, draft: SessionInputDraftGuard,
                                  written: SessionInputInjection, now: Date = Date(),
                                  to log: URL) {
    guard draft.stash else { return }
    appendSessionInputLine(sessionInputDraftStashedLine(pid: pid, rounds: sessionInputStashRounds,
                                                        now: now), to: log)
    switch (draft.restore, written) {
    case (true, .done):
        appendSessionInputLine(sessionInputDraftRestoredLine(pid: pid, now: now), to: log)
    // THE DECISION IS REPORTED BEFORE THE ACCIDENT, on a line that could name either: a restore this
    // build chose not to attempt is the ordinary case and the honest reason for it, while a write
    // that failed is only the reason when there was something to attempt.
    case (false, _):
        appendSessionInputLine(
            sessionInputDraftDroppedLine(pid: pid, reason: sessionInputDraftDropReasonNoTyping,
                                         now: now), to: log)
    // BOTH FAILURES LAND HERE, and they are one fact for this reader: the draft is in the kill
    // buffer and nothing put it back. Which side of the Return the write stopped on is the served
    // line's business (`SessionInputInjection`), not this one's.
    case (true, .failed), (true, .restoreFailed):
        appendSessionInputLine(
            sessionInputDraftDroppedLine(pid: pid, reason: sessionInputDraftDropReasonWriteFailed,
                                         now: now), to: log)
    }
}

/// No burst of keystrokes since the last prompt and since this supervisor's own last line, so
/// nothing said there was a draft to put back. The ordinary case, and the deliberately conservative
/// one (`sessionInputDraftSuspected` states the asymmetry it is conservative about).
let sessionInputDraftDropReasonNoTyping = "no-typing-evidence"

/// The terminal refused a write part-way through, so the stash may have happened and the restore
/// certainly did not. Rare, and the only one of the two that means something is wrong.
let sessionInputDraftDropReasonWriteFailed = "write-failed"

/// The line a directory that could not be narrowed leaves (grep `input=directory-mode`): the
/// requests in it are readable by every account on this machine, and the write went ahead anyway
/// (`makeSessionInputDirectory` states why). Its own line rather than a served-request one, because
/// nothing was typed and no session is named.
func sessionInputDirectoryModeLine(dir: URL, failure: Error, now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) input=directory-mode "
        + "wanted=\(String(sessionInputDirMode, radix: 8)) failed=\(failure.localizedDescription) "
        + "dir=\(dir.path)\n"
}

/// Append one audit line, keeping the log at `sessionInputLogMode`.
///
/// IT CONVERGES AN EXISTING FILE rather than only setting the mode at creation, because the file
/// that matters most is the one that already exists: a machine that ran an earlier build has a 0644
/// log on it, and a permission applied only at `O_CREAT` would leave every one of those open for
/// good. Checked before it is set so the ordinary append costs a `stat` rather than a `chmod`.
///
/// Created HERE rather than left to the appender below, which opens `O_CREAT` at 0644: a mode is
/// only applied by `open` when the call actually creates the file, so making it first is what
/// decides the mode at all.
func appendSessionInputLine(_ line: String, to log: URL) {
    let manager = FileManager.default
    try? manager.createDirectory(at: log.deletingLastPathComponent(),
                                 withIntermediateDirectories: true)
    if !manager.fileExists(atPath: log.path) {
        manager.createFile(atPath: log.path, contents: nil,
                           attributes: [.posixPermissions: sessionInputLogMode])
    } else if (try? manager.attributesOfItem(atPath: log.path))?[.posixPermissions] as? Int
        != sessionInputLogMode {
        try? manager.setAttributes([.posixPermissions: sessionInputLogMode],
                                   ofItemAtPath: log.path)
    }
    appendHandoffLine(line, to: log)
}
