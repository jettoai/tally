import Darwin
import Foundation

// THE MACHINE'S OWN ALARM, GOT IN FRONT OF THE SESSIONS RUNNING ON IT.
//
// WHY THE SUPERVISOR CARRIES THIS AT ALL. The app is what samples the machine (HostHealthLogic.
// swift), and the app has no door into a conversation: it can raise a banner and write a file, and
// neither reaches a session that is thirty minutes into a work package. The supervisor is the one
// process that has that door, so it reads what the app published and says one sentence.
//
// WHAT IT COSTS ON AN ORDINARY TICK: one `stat`. The report is rewritten once a minute and this
// decodes it only when its modification time has moved, so a machine that is fine costs a stat
// every two seconds and a decode every sixty.
//
// ONE SENTENCE PER ALARM, keyed on the instant the alarm was RAISED rather than on the report being
// new: the app rewrites that document every minute for as long as the alarm stands, and a station
// keyed on the document would say the same thing sixty times an hour.
//
// IT SPEAKS THROUGH THE KNOCK'S OWN CHANNEL AND NEVER AROUND IT (QuotaKnock.swift, QuotaKnock
// Notice.swift): filed for this child's hooks where they are registered, typed into the composer
// where they are not, and behind every gate the typed channel applies. It is placed AFTER the quota
// knock in the tick for the reason the resume line is placed after the request station: a tick that
// has already written to this composer has spent its turn, and two lines in one is one prompt with
// two instructions in it. What that costs is one tick of delay, which against a one-minute sample
// is nothing.
//
// AND IT WILL NOT WRITE OVER A SENTENCE NOBODY HAS READ YET. The filed channel is one slot per
// supervisor, so a filed knock still sitting undelivered holds this station off until the session's
// own hook run has taken it. That is not a loss: both sentences are delivered by the same hook run,
// so a session whose hooks have not run would not have received this one either, and the tick after
// the claim files it. The one case this DOES cost is a quota re-arm landing between the two, which
// clears the slot unconditionally (`clearQuotaKnockNotice`) and can take a filed host-health
// sentence with it. Left alone deliberately: the alternative is a second slot and a second claim
// inside somebody else's gate, and what the miss costs is one advisory sentence about a machine
// that is also raising a banner and writing a log.

/// The audit word a typed host-health sentence leaves in the input log (grep `input=host-health`).
let hostHealthKnockOutcome = "host-health"

/// And the word for one that was FILED rather than typed, on the terms `quotaKnockFiledOutcome`
/// states: the two answer different questions afterwards, and only the pair says whether a sentence
/// that was decided ever reached anybody.
let hostHealthKnockFiledOutcome = "host-health-filed"

/// The word when the terminal refused the write.
let hostHealthKnockFailedOutcome = "host-health-failed"

/// And when the file could not be written.
let hostHealthKnockFileFailedOutcome = "host-health-file-failed"

/// When the report was last rewritten, or nothing when it is not there at all.
func hostHealthReportModified(_ file: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
}

/// The report as it stands, fail-open on every failure: a machine whose Tally is closed, a document
/// half-written, a format this build cannot read all answer nothing, and nothing is what every
/// reader here treats as "no news".
func loadHostHealthReport(_ file: URL = hostHealthReportFile) -> HostHealthReport? {
    decodeHostHealthReport(try? Data(contentsOf: file))
}

/// One poll tick's host-health knock: nil on almost every tick, and otherwise the line that was
/// TYPED (nil for a filed one, the rule `applyQuotaKnock` states about its own return).
///
/// THE ORDER OF THE GATES IS WHAT KEEPS THIS FREE, and it is the quota knock's order for the same
/// reasons: what costs nothing comes first (a line already typed this tick, a planned relaunch),
/// then the `stat`, then whether there is anything to say at all, then which channel this session
/// has, and only then the input gate, which the filed channel does not ask.
///
/// `filing` is whether THIS CHILD's Claude Code can be handed the sentence rather than have it
/// typed. The reading is taken when that child is launched and handed in, never taken here
/// (`quotaKnockFilingAvailable` argues why the moment is the whole of it).
///
/// Every collaborator is injected with the real one as its default, so the whole table is
/// assertable with no supervisor, no report on disk and no terminal.
@discardableResult
func applyHostHealthKnock(_ state: inout HostHealthKnockState, pid: String, typedAlready: Bool,
                          session: SupervisedState, quiet: SessionQuiet, turnEnded: () -> Bool,
                          keyboardIdle: Bool, relaunchPlanned: Bool, draftSuspected: Bool,
                          waitingOnPerson: Bool,
                          filing: () -> Bool = { false },
                          file: URL = hostHealthReportFile,
                          modified: (URL) -> Date? = { hostHealthReportModified($0) },
                          read: (URL) -> HostHealthReport? = { loadHostHealthReport($0) },
                          undelivered: (String, URL) -> Bool = {
                              readQuotaKnockNotice(pid: $0, dir: $1) != nil
                          },
                          now: Date = Date(), log: URL = sessionInputLog,
                          dir: URL = supervisorStateDir,
                          inject: (String, SessionInputDraftGuard) -> SessionInputInjection = {
                              injectSessionInput($0, draft: $1)
                          }) -> String? {
    guard !typedAlready, !relaunchPlanned else { return nil }
    // The whole of the decision, next door and pure: what the cache does with this tick's stamp,
    // and whether an alarm is owed a sentence at all (HostHealthKnockLogic.swift).
    guard let alarm = HostHealthKnockLogic.observe(&state, stamp: modified(file), now: now,
                                                   read: { read(file) })
    else { return nil }
    // CUT BY BYTES, WHICH IS WHAT THE CHANNEL BOUNDS, and repaired on the way (the sentence itself
    // states both): `prefix` counts characters, and the names in here come off the process table.
    let line = hostHealthKnockSentence(alarm, bytes: sessionInputMaxBytes)
    // WHICH CHANNEL, asked before the composer gate rather than after it, because the answer
    // decides whether that gate applies at all: it keeps keystrokes out of a composer somebody
    // else is using, and a filed sentence is not keystrokes (QuotaKnockNotice.swift).
    if filing() {
        // The slot is shared with the quota knock, so a sentence nobody has read yet is not written
        // over. The head of this file states what that costs and what it buys.
        guard !undelivered(pid, dir) else { return nil }
        // Spent BEFORE the write, the rule `applyQuotaKnock` and `applySessionInput` both state: a
        // state directory that refuses one write refuses the next one two seconds later, and a
        // failure that repeats every tick is the one way this says the same thing twice.
        state.announced = alarm.at
        let failure = writeQuotaKnockNotice(QuotaKnockNotice(message: line, at: now),
                                            pid: pid, dir: dir)
        appendSessionInputLine(
            failure.map { quotaKnockFailureLine(pid: pid, code: $0,
                                                outcome: hostHealthKnockFileFailedOutcome,
                                                now: now) }
                ?? sessionInputLogLine(pid: pid, outcome: hostHealthKnockFiledOutcome, text: line,
                                       now: now),
            to: log)
        // Nothing was typed, so the caller's record of when it last wrote to this composer must not
        // move (SessionInputDraft.swift states what reads it).
        return nil
    }
    guard sessionInputHold(state: session, quiet: quiet, turnEnded: turnEnded(),
                           keyboardIdle: keyboardIdle, relaunchPlanned: relaunchPlanned) == nil
    else { return nil }
    state.announced = alarm.at
    // The same protection a requested line gets, decided from the same reading: a sentence nobody
    // asked for is the last thing that should cost somebody their draft.
    let draft = sessionInputDraftGuard(dialog: waitingOnPerson, suspected: draftSuspected)
    let written = inject(line, draft)
    switch written {
    case .done:
        appendSessionInputLine(sessionInputLogLine(pid: pid, outcome: hostHealthKnockOutcome,
                                                  text: line, now: now), to: log)
    case .failed(let code):
        appendSessionInputLine(quotaKnockFailureLine(pid: pid, code: code,
                                                     outcome: hostHealthKnockFailedOutcome,
                                                     now: now), to: log)
    }
    appendSessionInputDraftLines(pid: pid, draft: draft, now: now, to: log)
    return written.sent ? line : nil
}
