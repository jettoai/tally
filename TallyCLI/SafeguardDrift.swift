import Foundation

// Safeguard-fallback restore: a session the API fell onto a fallback model comes back at the depth
// the user declared, at the next idle moment.
//
// The Fable safeguards move a running session onto a fallback model mid-conversation and leave it
// there; DriftMonitor.swift observes that episode and this file acts on it.
//
// WHAT THE TRANSCRIPTS ACTUALLY SHOW, because it decides what this may and may not do. Measured
// across every safeguard event on this machine (50 of them, 2026-07-27):
//
//  - The MODEL switch is real and it is permanent: every event lands on the fallback model and the
//    conversation stays there until the user runs `/model` by hand. That is the API's own decision,
//    and steering back would re-enter the stretch that tripped the safeguard and be switched away
//    again, so this NEVER tries to return to it.
//  - The EFFORT is NOT taken away by the switch. In 44 of the 50 events the effort field is
//    unchanged across the flag, and in the other 6 it goes UP (high -> xhigh) rather than down. So
//    there is no API-side downgrade here to undo, and any comment claiming otherwise is wrong.
//
// What the switch does leave behind is a session running a model it was not launched for, at
// whatever depth its LAUNCH flags carry - a depth chosen for the model it is no longer on. That is
// the gap this closes: keep the model the safeguard chose, and run it at the depth declared for that
// model rather than the one declared for the model it left.
//
// WHERE THE DECLARATION COMES FROM, because there are two candidates and only one is right. The
// launch policy's `fallbackModel` / `fallbackEffort` pair (Settings, `~/.tally/state.json`) is the
// user's own answer to "what should this run when it cannot run the primary", and the pairing is
// deliberate rather than incidental: the flagship at a lower depth to make its quota last, the
// fallback at a higher one because its quota is not the scarce thing. Claude Code's own
// `settings.json` -> `effortLevel` is NOT the source, however tempting: the launcher already
// overrides it with `--effort` on every launch, so reading it here would import the very mismatch
// this feature exists to settle, and would silently apply one model's depth to another.
//
// The quota-driven fallback profile in Supervisor.swift reads the same pair, which is the point:
// whether the primary became unavailable because a window ran dry or because a safeguard stepped in,
// the session lands on the pairing the user declared for exactly that situation. The two paths are
// disjoint (that block is gated on the drift being inactive, this one requires it), so the same
// pairing is reached from both directions and neither can fight the other. What differs is only when
// a restart is worth spending: a dry window is the supervisor's own doing and the relaunch IS the
// mechanism, while a safeguard switch already happened to a running conversation, so a second restart
// on top of it fires only when it would change something anyone could observe.
//
// It is a plain same-account relaunch through the usual resume path, so the conversation continues;
// and it settles a preference rather than repairing an outage, so it waits for the full "left alone"
// bar instead of interrupting the work that triggered it.
//
// The declaration is the whole trigger, and it has two independent halves: a depth
// (`fallbackEffort`) and extra launch flags (`fallbackArgs`). Either one on its own is something
// worth applying, both together is the full profile, and neither means the feature does not fire at
// all rather than restarting a session to hand it what it already has. A session already on that
// profile is left alone for the same reason. This is the same either-half test the quota fallback
// profile applies, so a user who configured one Settings row gets it honoured on both paths.
//
// WHAT "ALREADY THERE" MEANS IS THE RUNNING STATE, NOT THE LAUNCH FLAGS (2026-07-29). A restore
// settles a difference between what the session is actually running and the pairing the declaration
// asks for, so the question at the last gate is whether a relaunch would change anything observable.
// Both halves of that state are read where they can be read: the model from the transcript (the gate
// above has already established the session is on the one the safeguard landed it on), and the depth
// from the `--effort` the child is running under. A declared depth already in place on the landed
// model is the whole declared pairing already in place, and nothing restarts.
//
// This used to be decided by comparing LAUNCH FLAGS instead, the session's `--model fable` against
// the declared `opus`, and that is exactly where the restarts that changed nothing came from: a
// session the safeguard had moved to opus, already running the declared depth, still read as "not
// there yet" because its launch line named a model it no longer served, so it was interrupted to
// become what it already was. Dropping the restore entirely whenever the declaration NAMED the landed
// model (a fix that stood for one day) removed those restarts by also removing the ones that would
// have changed the running depth, which is the feature itself. Extra launch flags are the one half
// with no readable running state, so a declaration of those alone still falls back to the launch-flag
// comparison: once a relaunch has aligned the launch line, that is the only evidence the flags were
// delivered.

/// The entry of the policy's declared fallback list that names the model the safeguard actually
/// landed on, or nil when the list declares none of them.
///
/// A list rather than one name because that is what the field holds: `fallbackModel` is
/// comma-separated (the quota fallback profile splits it the same way), so a user who declared
/// "opus,sonnet" has said what to run for EACH, and handing the raw string to `--model` would ask
/// claude for a model called "opus,sonnet". Matching by model rather than taking the first entry is
/// what keeps the promise at the top of this file: the safeguard chose which model, and the
/// declaration only supplies the NAME the user prefers for it.
///
/// The entry itself rather than a Bool because that name is the whole value: the alias the user
/// writes (`opus`) rather than the transcript's full id (`claude-opus-4-8`), and the restore
/// relaunches under it. The quota fallback profile picks its model the same way (Supervisor.swift).
///
/// nil when nothing matches, and the caller then keeps the model straight from the event: a
/// declaration naming only models the safeguard did not choose is not a reason to move the session
/// to one of them.
func declaredFallbackModel(_ list: String?, landedOn: String) -> String? {
    guard let list else { return nil }
    return list.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .first { !$0.isEmpty && modelsAgree($0, landedOn) }
}

/// Whether two model names denote the same model. The bidirectional-contains rule this repo already
/// applies wherever an alias meets a full id (`opus` vs `claude-opus-4-8`): the launcher injects
/// aliases, the transcript carries full ids, and both have to compare equal.
func modelsAgree(_ one: String?, _ other: String?) -> Bool {
    guard let one = one?.lowercased(), let other = other?.lowercased(),
          !one.isEmpty, !other.isEmpty else { return false }
    return one.contains(other) || other.contains(one)
}

// MARK: - Per-conversation records

/// Restores already performed, one file per conversation (~/.tally/safeguard-restore/<session>),
/// written atomically. The same shape as the rebalance and quarantine records next door, for the
/// same reason: one file per key means concurrent supervisors never corrupt a shared document, and
/// the BODY (which flag was corrected) is what makes a record self-expiring rather than a growing
/// list.
let safeguardRestoreDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/safeguard-restore")

/// How long a record outlives its conversation. Nothing reads a record for a session that has ended,
/// so this only stops the directory growing without bound; a week is far longer than any resumed
/// conversation's gap and short enough that the directory stays a handful of files.
let safeguardRecordTTL: TimeInterval = 7 * 24 * 3600

/// The filename a conversation's record lives under: a filesystem-safe derivative, as in the
/// quarantine and the rebalance records. Both the writer and the reader go through it so a slash in
/// an id can never make them disagree.
func safeguardRecordName(_ session: String) -> String {
    session.replacingOccurrences(of: "/", with: "_")
}

/// The transcript pointer a restore is deduped and logged against: the flag event's own uuid, or its
/// timestamp when a transcript carries none. Either names exactly one line in the file, which is
/// what the audit log needs to be followable without quoting what triggered the safeguard.
func safeguardEventKey(_ flag: SafeguardFlag) -> String {
    flag.uuid ?? ISO8601DateFormatter().string(from: flag.at)
}

/// Whether this conversation has already been restored for THIS flag event. Any other stored key (an
/// earlier episode, or nothing at all) leaves the event unhandled, so a later safeguard switch in the
/// same conversation is corrected on its own merits.
func safeguardRestoreHandled(session: String?, event: String,
                             dir: URL = safeguardRestoreDir) -> Bool {
    guard let session,
          let raw = try? String(contentsOf: dir.appendingPathComponent(safeguardRecordName(session)),
                                encoding: .utf8) else { return false }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines) == event
}

/// The record a planned restore will write IF its relaunch actually happens, carried from the
/// decision to the execution point rather than written where it is decided.
///
/// Planning is not doing. A tick can plan a restore and then stand the relaunch down (the
/// unresolved-fork hold, StandDown.swift), and a record written at decision time would outlive the
/// relaunch it describes: the next tick reads the event as handled and the session is never restored
/// at all. Writing on the execution path instead means the cancel path has nothing to undo - the
/// shape any future way of cancelling a planned relaunch is safe under by construction.
///
/// The dedup it exists for is untouched by the delay: the write lands before the child is
/// terminated, so the supervisor that adopts the conversation next (this one after a self-update
/// exec, or the one behind the relaunch) still reads it. Nothing between the decision and the
/// execution reads the directory, and the tick that planned it is the one that executes it.
struct PendingSafeguardRecord {
    let session: String?
    let event: String
    let dir: URL

    /// Called once the relaunch is certain, immediately before the child is terminated.
    ///
    /// `session` is the conversation the decision was made about. A fork adopted by the execution
    /// point's own scan moves the conversation to a new id after this, so the record then names the
    /// file the flag was seen in rather than the one it continues in; the cost of that miss is the
    /// documented one below, one extra restart, and never a stuck session.
    func commit() {
        recordSafeguardRestore(session: session, event: event, dir: dir)
    }
}

/// Record that this conversation has been restored for `event`, so no later supervisor - this one
/// after a self-update exec, or the one that adopts the conversation next - corrects it twice.
/// Best-effort: a record that cannot be written costs at worst one extra restart, never a stuck
/// session.
func recordSafeguardRestore(session: String?, event: String, dir: URL = safeguardRestoreDir) {
    guard let session else { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? event.write(to: dir.appendingPathComponent(safeguardRecordName(session)),
                     atomically: true, encoding: .utf8)
    pruneSafeguardRecords(dir: dir)
}

/// Drop records whose conversation has been gone for longer than the TTL. Opportunistic, on the
/// write path only (a restore is a rare event), the same way the quarantine expires its own files as
/// it reads them.
func pruneSafeguardRecords(dir: URL = safeguardRestoreDir, now: Date = Date()) {
    let files = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for file in files {
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate, now.timeIntervalSince(modified) > safeguardRecordTTL
        else { continue }
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: - The decision

/// The profile a restore relaunches on: the model the safeguard landed the session on, plus the
/// depth and the extra flags the user declared for it. The same three pieces the quota fallback
/// profile applies, because it is the same declaration being honoured.
///
/// `effort` is optional because the two halves are declared independently: someone who only sets
/// extra flags for their fallback has still declared something worth applying, and forcing a depth
/// they never chose would be inventing one.
struct SafeguardRestore: Equatable {
    let model: String
    let effort: String?
    let extraArgs: [String]
}

/// The extra launch flags declared for a fallback, split the way the quota fallback profile splits
/// them (whitespace-separated; `split` drops the empty runs, so repeated spaces collapse). Empty
/// when nothing is declared.
func declaredFallbackArgs(_ raw: String?) -> [String] {
    raw?.split(separator: " ").map(String.init) ?? []
}

/// What a restore would put this session back on, or nil when there is nothing to restore. Pure, so
/// every gate below is testable without a child, a transcript, or a filesystem. Timing is
/// deliberately NOT one of them: the caller needs the difference between "nothing to do" and "queued
/// until this session is left alone", because only the second one is worth a status-line badge.
///
/// The gates, in the order they bite:
///  - something is declared for the fallback, a depth or extra flags. Nothing declared, nothing to
///    apply, so the session is never restarted merely to hand it what it already has. The same
///    either-half test the quota fallback profile applies.
///  - `alreadyHandled`: this flag event has been corrected once already.
///  - the session is still ON the model the safeguard landed it on. If it is not, the user ran
///    `/model` themselves and a relaunch would overwrite a deliberate choice with an older one. Not
///    recorded as handled: the user is free to come back, and a restore is still right if they do.
///  - the relaunch would change something observable. The session is on the landed model by the
///    gate above, so a declared depth already running is the whole declared pairing already in
///    place and nothing is restarted. The launch flags are deliberately NOT consulted here: a
///    session still carrying the `--model` it was started with while serving the fallback is
///    precisely the shape that used to produce restarts changing nothing. With no depth declared
///    (extra flags only) there is no running state to read, exactly as on the quota path, so the
///    launch flags do stand in for it: a launch line already naming the model is the only evidence
///    a relaunch has delivered those flags.
func safeguardRestoreTarget(flag: SafeguardFlag, actualModel: String?, fallbackModel: String?,
                            fallbackEffort: String?, fallbackArgs: String?, currentModel: String?,
                            currentEffort: String?, alreadyHandled: Bool) -> SafeguardRestore? {
    let effort = fallbackEffort.flatMap { $0.isEmpty ? nil : $0 }
    let extraArgs = declaredFallbackArgs(fallbackArgs)
    guard effort != nil || !extraArgs.isEmpty, !alreadyHandled,
          modelsAgree(actualModel, flag.to) else { return nil }
    // The model is the safeguard's choice either way; the declaration only supplies the name the
    // user writes it under, when they have named it at all.
    let model = declaredFallbackModel(fallbackModel, landedOn: flag.to) ?? flag.to
    if let effort {
        // The running state, both halves of it: the model is the landed one by the guard above, so
        // the declared depth already in place leaves nothing a relaunch could change.
        if currentEffort?.lowercased() == effort.lowercased() { return nil }
    } else if modelsAgree(currentModel, model) {
        // Flags only, and flags cannot be read back off a running child: a launch line already
        // naming the model is the only sign a relaunch has handed them over.
        return nil
    }
    return SafeguardRestore(model: model, effort: effort, extraArgs: extraArgs)
}

/// What this tick owes the QUEUED-restore state: the announcement, the audit line, and the status
/// line's "restoring at idle" all hang off it, and so does taking that back.
///
/// Pure and exhaustive on purpose, in the shape `ReloadDecision` and `CapAction` already use here,
/// because the arm that was missing is the expensive one to notice: a restore can be queued and then
/// lose its target while it waits (the user runs `/model` to a third model, or clears the
/// declaration), and without `.cancel` the badge said "restoring at idle" for the rest of the
/// session while no idle tick would ever restart anything. Announced state has to be retractable by
/// the same code path that announced it.
enum SafeguardPending: Equatable {
    case announce   // a target appeared and nothing has been said yet
    case hold       // already announced, still waiting for the session to be left alone
    case cancel     // announced, but the target has since gone away
    case idle       // nothing to say
}

func safeguardPendingTransition(hasTarget: Bool, queued: Bool) -> SafeguardPending {
    switch (hasTarget, queued) {
    case (true, false): return .announce
    case (true, true): return .hold
    case (false, true): return .cancel
    case (false, false): return .idle
    }
}

// MARK: - Audit log

/// The detection line for a queued restore (grep `safeguard-restore=`). Deliberately carries NO
/// excerpt of what triggered the safeguard: those prompts are the sensitive stretch by definition
/// (auth and token work is what trips it here), and the log is a plain file. What makes the episode
/// followable instead is a pointer - the transcript path and the flag event's own uuid - so anyone
/// who needs the content reads it from the transcript, under the transcript's own protection.
///
/// Pure and separate from the append below so that guarantee is testable: the assertion that has to
/// hold forever is about what this string does NOT contain.
/// The extra flags are COUNTED, never quoted: `fallbackArgs` is free text the user configured, and
/// `--append-system-prompt "..."` lives there in practice, so copying it into a plain log would
/// duplicate content this line exists to avoid duplicating. The count still answers the question the
/// log is read for - did the profile land in full.
func safeguardRestoreLine(sessionID: String?, flag: SafeguardFlag, restore: SafeguardRestore,
                          transcript: URL?, now: Date = Date()) -> String {
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    var line = "\(ISO8601DateFormatter().string(from: now)) session=\(sid) " +
        "safeguard-restore=queued \(flag.from)->\(flag.to) model=\(restore.model)"
    if let effort = restore.effort { line += " effort=\(effort)" }
    if !restore.extraArgs.isEmpty { line += " extra-args=\(restore.extraArgs.count)" }
    line += " event=\(safeguardEventKey(flag))"
    if let transcript { line += " transcript=\(transcript.path)" }
    return line
}

/// Append that line to the shared handoff log, where the relaunch it leads to is recorded too
/// (`reason=safeguard`).
/// The line a WITHDRAWN restore leaves (grep `safeguard-restore=cancelled`): the queued restart no
/// longer applies, which nothing else records. Pure, and carrying no more than the announcement's
/// own fields, so the pair reads as one episode in the log.
func safeguardRestoreCancelledLine(sessionID: String?, event: String, now: Date = Date()) -> String {
    let sid = sessionID.map { String($0.prefix(8)) } ?? "unknown"
    return "\(ISO8601DateFormatter().string(from: now)) session=\(sid) "
        + "safeguard-restore=cancelled event=\(event)\n"
}

func logSafeguardRestore(log: URL = handoffLog,
                         sessionID: String?, flag: SafeguardFlag, restore: SafeguardRestore,
                         transcript: URL?, now: Date = Date()) {
    appendHandoffLine(safeguardRestoreLine(sessionID: sessionID, flag: flag, restore: restore,
                                           transcript: transcript, now: now) + "\n", to: log)
}

// MARK: - Poll-loop wiring

/// One poll tick's restore handling, applied to the supervisor's state: decide whether this session
/// owes itself a restore, say so once (terminal, audit log, status-line badge), and plan the
/// relaunch when the session is finally left alone.
///
/// Runs only when no other reason has already planned a relaunch this tick. Every one of those is
/// either more urgent (a cap, a pin) or a deliberate preference change (a follow adoption), and each
/// restarts the child on args of its own - so the right thing is to let it, and correct the depth on
/// a later tick if the drift is still there afterwards.
///
/// The idle bar is the full "left alone" one (transcript, subagents, open tool call, keyboard), the
/// same bar the rebalance and the follow adoption wait for. This settles a preference, not an
/// outage: the session still answers, just not on the declared profile, so it may never cost a
/// keystroke.
///
/// A queued restore is retracted rather than left standing when its target goes away mid-wait, which
/// is why the announcement runs through `SafeguardPending` rather than a bare "say it once" flag.
/// `keyboardIdle` is the keyboard half of the quiet bar, injected the way the reload gate takes it:
/// the supervisor holds one `KeyboardActivity` per child and every non-urgent gate asks that same
/// tracker, because a lone atime cannot tell typing from terminal chatter (KeyboardIdle.swift).
///
/// `record` comes back holding what to write if the relaunch happens, and is written by the caller
/// at the execution point rather than here (`PendingSafeguardRecord`): a restore that is planned and
/// then stood down must leave no trace saying it was performed.
func applySafeguardRestore(plan: inout RelaunchPlan?, drift: inout DriftMonitor,
                           record: inout PendingSafeguardRecord?,
                           watcher: inout TranscriptWatcher, account: Snapshot.Account,
                           policy: LaunchPolicy, launchArgs: [String], fuseAllows: Bool,
                           pid: String, keyboardIdle: (TimeInterval) -> Bool,
                           dir: URL = safeguardRestoreDir,
                           stateDir: URL = supervisorStateDir,
                           log: URL = handoffLog) {
    guard plan == nil, drift.isActive, let flag = watcher.lastFlag else { return }
    let session = watcher.file?.deletingPathExtension().lastPathComponent
    let event = safeguardEventKey(flag)
    // The policy the caller already read this tick, not a fresh load: the loop reads it once per
    // poll and this must answer against the same picture every other block on this tick used.
    let restore = safeguardRestoreTarget(
        flag: flag, actualModel: watcher.lastModel,
        fallbackModel: policy.fallbackModel, fallbackEffort: policy.fallbackEffort,
        fallbackArgs: policy.fallbackArgs,
        currentModel: flagValue(launchArgs, "--model"),
        currentEffort: flagValue(launchArgs, "--effort"),
        alreadyHandled: safeguardRestoreHandled(session: session, event: event, dir: dir))

    let pending = safeguardPendingTransition(hasTarget: restore != nil,
                                             queued: drift.restoreQueued)
    if pending == .announce, let restore {
        // Before the wait rather than after it: a session in use can sit here for a long time, and
        // the whole point of the badge is that the wait is visible while it is happening.
        // NOT SAID ON THE TERMINAL, and the comment above is why it used to be: this announces a
        // restart that has NOT happened yet, so the child is drawing while the line is written and
        // it lands in the middle of the TUI (the rule in PendingNotice.swift, broken again here).
        // Nothing is lost by dropping it - the status line already renders exactly this wait, the
        // drift badge carrying its "restoring" tail from the state written two lines down
        // (Statusline.swift), and the log keeps the full profile.
        logSafeguardRestore(log: log, sessionID: session, flag: flag, restore: restore,
                            transcript: watcher.file)
        writeDriftState(flag, pid: pid, restorePending: true, dir: stateDir)
        drift.markRestoreQueued()
    } else if pending == .cancel {
        // The drift itself stands (the session is still on the fallback model, so the badge keeps
        // saying so); only the promise of a restart is withdrawn, which the badge shows by losing
        // its "restoring" tail. To the LOG rather than the terminal for the same reason as the
        // announcement above: no relaunch follows this line, so the child is drawing over it.
        appendHandoffLine(safeguardRestoreCancelledLine(sessionID: session, event: event), to: log)
        writeDriftState(flag, pid: pid, restorePending: false, dir: stateDir)
        drift.clearRestoreQueued()
    }

    guard let restore, fuseAllows, watcher.isQuiet(followIdleSeconds),
          keyboardIdle(followIdleSeconds) else { return }
    record = PendingSafeguardRecord(session: session, event: event, dir: dir)
    plan = RelaunchPlan(target: account, reason: "safeguard", countsFuse: true,
                        model: restore.model, effort: restore.effort,
                        extraArgs: restore.extraArgs)
}
