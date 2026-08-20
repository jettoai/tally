import Foundation

// DECIDING WHAT A SESSION IS DOING, which only the supervisor can do.
//
// The record and its file are in SessionState.swift, which both targets compile. Everything here
// is the supervisor's alone: the transcript it is tailing, the open tool call, the subagent walk
// and the terminal atime are facts nothing outside this process can read, and the app is
// deliberately given a reading rather than the ingredients (the drift badge and the pending notice
// are published on exactly these terms).

/// How long a conversation must be quiet before its session is called idle rather than working.
///
/// PARAMETERISED AWAY FROM THE 600s TEARDOWN BAR ON PURPOSE. `WorktreeActivity` asks a question
/// about safety ("may this checkout be torn down"), where being early destroys work, so it waits
/// ten minutes. This asks a question about a glance ("is this one moving"), where being late is the
/// whole failure: a board that takes ten minutes to notice a finished turn is a board nobody looks
/// at. Nothing about the teardown's bar moves because of this one.
///
/// 30 seconds because the gates behind `isQuiet` already absorb the silences that are not idleness
/// (an unanswered tool call holds for up to 600s, a working subagent for 600s), so what this bar
/// measures is a conversation with nothing outstanding at all.
let sessionStateQuietSeconds: TimeInterval = 30

/// The state, from the three things the supervisor knows about this tick. Pure, so the whole
/// machine is assertable without a transcript on disk.
///
/// A HARD WAIT LEADS, including over an unbound transcript. `unknown` means "running, and nothing
/// can be said about it"; an unanswered permission request is something said about it, from a
/// channel that does not depend on a transcript existing at all. A session whose first act is a
/// permission request is exactly that case, and reporting it as unknown would hide the one state
/// the board exists for.
///
/// A SOFT WAIT ONLY LEADS OVER SILENCE, and that is the 2026-08-15 correction. `idle_prompt` says
/// the floor is free; a session that has dispatched a fan-out and is waiting on it satisfies that
/// sentence for the whole of the fan-out, because the main transcript stops the moment the
/// subagents start. This tick already KNOWS the difference - `quiet` is decided from the file, the
/// open tool call and the subagent walk together - and the old rule threw that away by taking any
/// wait as final. So the soft one is now allowed to upgrade only the reading it is compatible with:
/// a conversation with nothing outstanding at all, which is exactly what would otherwise be `idle`.
/// Measured on this machine that day: two of six live sessions stood red for minutes while their
/// subagents wrote.
///
/// Not over `unknown`, deliberately: with no transcript bound, "quiet" is true in a way that means
/// nothing (`isQuiet` answers true for a file it cannot find, by design), so a soft wait there is a
/// sentence about a conversation nobody can see. Unknown is the honest reading, and a hard wait is
/// the one that still outranks it.
func supervisedSessionState(wait: UserWait?, hasTranscript: Bool, quiet: Bool) -> SupervisedState {
    if wait == .hard { return .blocked }
    guard hasTranscript else { return .unknown }
    if wait == .soft, quiet { return .blocked }
    return quiet ? .idle : .working
}

/// Whether a notice Claude Code left is still unanswered.
///
/// TWO WAYS AN ANSWER SHOWS ITSELF, and both are measured from the instant the hook fired:
///
///   - THE CONVERSATION MOVED. The user answered and Claude Code got on with it, so the transcript
///     is newer than the event. This is the ordinary case and it is exact.
///   - SOMEBODY TYPED IN THAT TERMINAL. The supervisor shares the tty with its child, so a
///     keystroke stamps a device node it can stat (KeyboardIdle.swift carries the measurements).
///     This is what covers an answer that writes nothing: an Escape, a dismissal, a question
///     abandoned.
///
/// THE SECOND ONE ASKS FOR A BURST RATHER THAN A STAMP, which is a deliberate departure from the
/// plainest reading of "was anything typed". A lone stamp is not typing: measured on this machine
/// (KeyboardIdle.swift, 2026-07-28), an idle terminal with nobody at it was stamped four times in
/// three minutes by control chatter alone, and its age never passed 61 seconds. Clearing on that
/// would take every blocked session back to idle within a minute of nobody doing anything, which
/// is precisely the false reading the board cannot afford - a session that needs the user, shown
/// as one that does not. A burst (two stamps inside `keyboardBurstGap`) is a person, and the
/// answers a single keypress gives are covered by the transcript rule above, since Claude Code
/// writes the moment it is unblocked.
func userNoticeStillOpen(_ notice: UserNotice?, transcriptModified: Date?,
                         keyboardBurstAt: Date?) -> Bool {
    guard let notice else { return false }
    if let transcriptModified, transcriptModified > notice.at { return false }
    if let keyboardBurstAt, keyboardBurstAt > notice.at { return false }
    return true
}

/// The identity half of a published state: everything a board row needs to NAME a session, as
/// opposed to what it is doing. Grouped so the writer takes one argument rather than six, and so a
/// caller cannot fill the project while forgetting the account.
struct SessionIdentity: Equatable {
    var accountID: String?
    var directory: String?
    var project: String?
    var worktree: String?
    var model: String?
    var childPid: Int?
}

/// Keeps the state file in step with the session, writing only when something in it actually
/// changed.
///
/// The supervisor polls every 2 seconds and most ticks change nothing, so an unconditional write
/// would be a file replace every 2s per session for the whole life of the machine. Holding the last
/// value in memory also preserves `since`: as long as the state WORD reads the same, it is the same
/// stretch of working or waiting, and it keeps its start time.
///
/// THE IN-MEMORY COPY IS SEEDED FROM THE FILE, for the reason `PendingNoticeWriter` spells out at
/// length: a self-update replaces this process with `execv`, keeping the pid, so the new image
/// starts with nothing held while a record written by the image it replaced is still on disk. Left
/// unseeded, the first tick would either rewrite an identical record (losing `since`) or, worse,
/// hold a state it never decided.
struct SessionStateWriter {
    private var current: SessionStateRecord?

    /// `pid` is optional only so a test can build a writer with nothing to reconcile; the
    /// supervisor always passes its own, because the file it may have to take over is named for it.
    init(pid: String? = nil, dir: URL = supervisorStateDir) {
        current = pid.flatMap { readSessionState(pid: $0, dir: dir) }
    }

    /// Idempotent: the same state and the same identity in, nothing happens.
    ///
    /// `noticeType` and `quiet` are the tick's own diagnosis rather than part of the decision
    /// (SessionState.swift says what they are for). They join the delta below like every other
    /// field, so a session sitting blocked while its subagents start and stop writing costs one
    /// write per flip - which is the price of being able to answer "why is this red" at all.
    mutating func sync(_ state: SupervisedState, reason: String?, noticeType: String? = nil,
                       quiet: Bool? = nil, identity: SessionIdentity,
                       pid: String, dir: URL = supervisorStateDir, now: Date = Date()) {
        let word = state.rawValue
        let record = SessionStateRecord(
            state: word,
            // The age of THIS state, not of this tick: preserved while the word holds steady.
            since: current?.state == word ? (current?.since ?? now) : now,
            updatedAt: now, reason: reason, noticeType: noticeType, quiet: quiet,
            accountID: identity.accountID,
            directory: identity.directory, project: identity.project, worktree: identity.worktree,
            model: identity.model, childPid: identity.childPid)
        // WHOLE-VALUE, with `updatedAt` normalised away: that field moves on every tick by
        // construction, so comparing it would make every tick a write. Written this way rather than
        // as a chain of field comparisons so a field added to the record LATER joins this test for
        // free - a chain is a list somebody has to remember to extend, and the symptom of
        // forgetting is a change that is decided and then never published.
        if var unchanged = current {
            unchanged.updatedAt = record.updatedAt
            if unchanged == record { return }
        }
        let moved = current?.state != word
        // NOTHING IS BELIEVED UNTIL IT IS ON DISK. The guard above judges the next write against
        // `current`, so updating it after a publish that failed would suppress every retry for the
        // rest of the session: the state would be decided correctly, every tick, and never
        // published again. Leaving `current` where it was makes the next tick try once more, which
        // is what "best-effort" has to mean for a writer that remembers.
        guard writeSessionState(record, pid: pid, dir: dir) else { return }
        current = record
        // THE KNOCK, and only on a state change. The file is the truth and this is what saves the
        // app from polling a panel nobody has open (SessionState.swift states the rule); a post per
        // model change or per account move would be noise on a machine-wide bus for a reading that
        // is re-read whenever the panel is looked at anyway. After the write, for the same reason:
        // a knock is an invitation to read a file that has to already say the new thing.
        guard moved else { return }
        postSessionStateChanged(pid: pid)
    }
}

/// One tick's worth of "what is this session doing", written to the board.
///
/// The whole of it lives here rather than in the poll loop for the reason `syncPendingNotice` does:
/// Supervisor.swift is over its size cap, so the loop hands over the state it already holds and
/// everything else (the clearing rules, the decision, whether the file needs touching at all)
/// happens on this side.
///
/// `watcher` is inout because deciding costs a locate and a stat, which is the same scan the tick's
/// other gates run; `keyboardBurstAt` is the tracker's own reading rather than a fresh stat,
/// because a burst only exists across successive polls (KeyboardIdle.swift).
///
/// IT RETURNS WHAT IT DECIDED, for the one consumer that needs the state as of THIS tick rather than
/// as of the file: `applySessionInput` (SessionInput.swift) gates on it, and reading the file back
/// would be reading a record this call may have just declined to rewrite. Discardable because every
/// other caller is here to publish, not to ask.
@discardableResult
func syncSessionState(_ writer: inout SessionStateWriter, pid: String, project: PickProject,
                      accountID: String, childPid: Int?, model: String?,
                      watcher: inout TranscriptWatcher, keyboardBurstAt: Date?,
                      dir: URL = supervisorStateDir, now: Date = Date()) -> SessionTick {
    let quietness = watcher.quietness(sessionStateQuietSeconds)
    let quiet = quietness == .quiet
    // AFTER the locate `quietness` runs, so this is the file the conversation is actually in: a
    // `/clear` or a fork moves it, and the mtime of the file it left says nothing about the answer
    // somebody just gave (TranscriptFork.swift owns that rule).
    let file = watcher.file
    let modified = transcriptModified(file)
    let notice = readUserNotice(pid: pid, dir: dir)
    let waiting = userNoticeStillOpen(notice, transcriptModified: modified,
                                      keyboardBurstAt: keyboardBurstAt)
    // THE OTHER CHANNEL, and the only one that catches the case the hook cannot: Claude Code fires
    // no notification at all for `AskUserQuestion` or a plan awaiting approval (2.1.233, read off
    // the binary 2026-08-15), so the state the board exists for was the one state it could not
    // show. The transcript says it outright - the tool call is open and only a person closes it -
    // and reading a fact rather than inferring one is the same move the fork join was fixed by.
    let question = watcher.openUserQuestion(asOf: modified)
    // An answered event is taken away rather than left to age out: the file's presence IS the
    // blocked signal (UserNotice.swift), so a stale one would be a session reported as waiting for
    // something that has already happened. Only the event this tick actually judged is removed, and
    // why that qualification is load-bearing (and why it is a narrowing rather than a lock) is
    // stated on `clearAnsweredUserNotice`.
    if let notice, !waiting { clearAnsweredUserNotice(notice, pid: pid, dir: dir) }
    // An open question is a HARD wait wherever it stands, and it outranks a soft notice rather than
    // merging with one: a fan-out that has been quiet for 60s and a conversation holding a question
    // open both carry an `idle_prompt`, and only the second is somebody being waited for.
    let wait: UserWait? = question != nil ? .hard
        : (waiting ? userWait(notificationType: notice?.type) : nil)
    let state = supervisedSessionState(wait: wait, hasTranscript: file != nil, quiet: quiet)
    // What to SAY about the wait, and Claude Code's own sentence leads: it names the tool it wants
    // permission for, which nothing on this side knows. The question's sentence is what fills in
    // when there is no notice, or when the one standing said nothing - an empty message is a wait
    // with nothing to say about it, which is nil rather than "".
    let said = waiting ? (notice?.message).flatMap({ $0.isEmpty ? nil : $0 }) : nil
    let spoken = state == .blocked ? said ?? question.flatMap({ userQuestionTools[$0] }) : nil
    writer.sync(state, reason: spoken, noticeType: waiting ? notice?.type : nil, quiet: quiet,
                identity: SessionIdentity(accountID: accountID, directory: project.path,
                                          project: project.name, worktree: project.worktree,
                                          model: model, childPid: childPid),
                pid: pid, dir: dir, now: now)
    return SessionTick(state: state, quiet: quietness, wait: wait)
}

/// What one tick decided about a session: the word every surface reads, and the reading behind it.
///
/// THE READING TRAVELS WITH THE WORD because one consumer needs what the word deliberately throws
/// away. `working` is one answer to two different situations - this conversation is mid-turn, and
/// this conversation has finished speaking while the agents it dispatched write on - and the board
/// is right to call both of them working, since both are a session with work in flight. The input
/// gate is not: it types a line rather than killing anything, so the second case is one it may
/// serve (SessionQuiet states the whole argument, Albert 2026-08-17). Handing it the state alone
/// left it unable to tell them apart, and a `/clear` asked for by a head with one agent still
/// running waited out its whole life and was refused.
struct SessionTick: Equatable {
    /// What the board shows and what the state file says.
    let state: SupervisedState
    /// What the transcript said on this tick, in the three shapes `SessionQuiet` keeps apart.
    let quiet: SessionQuiet
    /// WHICH KIND OF WAIT is behind a `blocked`, which is the second thing the word throws away and
    /// the second consumer that cannot afford to lose it. `blocked` is one answer to two different
    /// situations - somebody has to answer a dialog, and Claude Code has finished speaking and
    /// nobody has typed for a minute - and the board is right to draw both, because both are a
    /// session with the floor. The movers that RESTART a child are not: only the first is a reason
    /// not to restart, and reading the word alone made the second one a veto too (see
    /// `waitingOnPerson`).
    let wait: UserWait?

    /// Whether a PERSON is being waited for: a permission request, a plan awaiting approval, an
    /// open question. The reading every mover that restarts this child asks, spelled once here.
    ///
    /// WHY NOT `state == .blocked`, which is what the movers asked at first and is a regression
    /// this exists to have fixed (codex review of e52a436). Claude Code fires `idle_prompt` about
    /// sixty seconds after it stops speaking, and `supervisedSessionState` folds that soft wait
    /// into `blocked` for a session that is otherwise quiet - which is precisely the session the
    /// idle rebalance is waiting for. Its own bar is 120 seconds of silence, so on any machine with
    /// the notification hook installed the soft wait was ALWAYS standing by the time the rebalance
    /// became possible, and the gate refused every single time. Worse, it does not lift on its own:
    /// the notice clears on a keystroke or a transcript write, and an idle session produces
    /// neither. The idle rebalance was therefore switched off outright on exactly the machines
    /// this repo's own hooks are installed on.
    ///
    /// `hard` FAILS OPEN, which is what makes this safe to narrow: `userWait` answers `hard` for a
    /// type it has never heard of and for a notice carrying no type at all, so the only readings
    /// that reach `false` here are the ones explicitly listed as soft (`softWaitNotificationTypes`,
    /// one entry). A new permission-shaped notification from a future Claude Code is a hard wait
    /// without anybody teaching this anything.
    var waitingOnPerson: Bool { wait == .hard }
}

/// When a transcript was last written, or nil when there is none (or it cannot be stat'd).
///
/// A FRESH URL on purpose, the same guard `isBoundFileQuiet` carries: `resourceValues` are cached
/// per URL instance, and a cached mtime would report a conversation that has moved on as frozen at
/// the moment it was first asked about.
func transcriptModified(_ file: URL?) -> Date? {
    guard let file else { return nil }
    return (try? URL(fileURLWithPath: file.path)
        .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}
