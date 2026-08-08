import Foundation

// WHICH CONVERSATION THIS SESSION IS IN, said by the one process that cannot be wrong about it.
//
// THE GUESS THIS REPLACES. A supervisor that resumed a known id binds `<id>.jsonl` outright; one
// that did not takes the most recently written transcript in the project directory, and `bindFile`
// says what that costs: it "would otherwise pick the wrong file when the directory holds a second
// session (a sibling tab, an unrelated older conversation)". Three separate defects have now been
// found downstream of that guess, and each fix was a patch on a premise rather than the premise: the
// monotonic gate dated a request from a stranger's file, the join key was latched from it, and the
// file-evidence check asked about a conversation that was not ours. All three exist because nothing
// ever TOLD the supervisor where the conversation was.
//
// THE CHANNEL. Claude Code hands its status-line command a JSON object on stdin every time it
// renders, and that object carries `session_id` and `transcript_path` (measured against 2.1.226).
// Tally's status line IS that command (Statusline.swift), so the answer arrives on its own, from the
// process doing the writing, without the user having to type anything. It is strictly better than
// the id a `tally account` request carries: same authority, no command required, and it lands within
// a render of a `/clear` rather than whenever somebody next asks for something.
//
// TWO HARD CONSTRAINTS SHAPE EVERYTHING HERE.
//
//   1. THE STATUS LINE MUST NOT NOTICE THIS. It is drawn on every interaction and it is the one
//      surface a user sees constantly, so nothing on this path may throw, block, print, or wait: the
//      whole write side is `try?` over small files, it never touches the terminal, and it returns
//      before doing any work at all in the case that is true almost every time (nothing changed).
//   2. WRITES MUST BE RARE. A render can happen several times a second. The value only changes when
//      the conversation does, so the file is read first and written only when it would say something
//      different, which in a steady session means one write at start-up and one per `/clear`.
//
// ADDRESSING IS NOT REINVENTED. Which session a status line belongs to is the same question the
// prompt hooks and the MCP picker answer, and it has one answer (`SessionMarkerTrust.corroborated`,
// SwitchRequest.swift): the marker in the environment counts only where the directory the prompt
// came from is actually running that supervisor, narrowed by process ancestry and by the
// conversation id. A status line is in the strongest position of all three - it is a direct child of
// Claude Code, so `getppid()` IS the process whose conversation it is reporting, and that pid is
// exactly what each supervisor publishes about its own child (`readSupervisorChild`).

/// The suffix under which a session's own report of its transcript lives, beside the supervisor's
/// presence entry and the other per-session documents (SwitchRequest.swift keeps that family).
/// Registered in `supervisorStateSuffixes` so a dead supervisor's copy is swept with the rest.
let transcriptIdentitySuffix = ".transcript"

func transcriptIdentityFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + transcriptIdentitySuffix)
}

/// What one status-line render reported: the conversation it drew for, and the Claude Code that drew
/// it.
///
/// THE PID IS NOT DECORATION, and it is what makes a stale file harmless. A supervisor outlives its
/// children: it relaunches one to move accounts, to change model, to take an update. A report left
/// by the child before last names a conversation that child was in, and a relaunch that starts a
/// FRESH conversation (nothing to resume) would otherwise bind the watcher to a transcript nobody is
/// writing any more. The reader therefore accepts a report only from the child it is running right
/// now, which also disposes of the other stale case for free: a recycled supervisor pid inheriting a
/// dead supervisor's file, whose child pid cannot be ours.
struct TranscriptIdentity: Equatable {
    /// Claude Code's own id for the conversation, which is also the stem of the transcript it is
    /// writing (measured 2026-08-07, and the same equality `transcriptSessionID` rests on).
    let id: String
    /// The Claude Code process that reported it: the status line's own parent.
    let claudeCodePID: pid_t
}

/// Parse the file body: the id on line 1, the reporting pid on line 2. Pure, so the format is
/// testable without a home directory, and anything unparseable is NO report rather than a partial
/// one - the reader's fallback is the behaviour this build has always had, which is safe by
/// construction.
func parseTranscriptIdentity(_ raw: String) -> TranscriptIdentity? {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let id = lines.first, isTranscriptSessionID(id),
          let pid = lines.dropFirst().first.flatMap({ pid_t($0) }), pid > 0 else { return nil }
    return TranscriptIdentity(id: id, claudeCodePID: pid)
}

func readTranscriptIdentity(pid: String, dir: URL = supervisorStateDir) -> TranscriptIdentity? {
    guard let raw = try? String(contentsOf: transcriptIdentityFile(pid: pid, dir: dir),
                                encoding: .utf8) else { return nil }
    return parseTranscriptIdentity(raw)
}

/// Publish one. Atomic, so a supervisor polling mid-write reads the previous report or this one,
/// never half of either, and best-effort like everything else on this track: failing to write it
/// costs the certainty, never the status line.
func writeTranscriptIdentity(_ identity: TranscriptIdentity, pid: String,
                             dir: URL = supervisorStateDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? "\(identity.id)\n\(identity.claudeCodePID)\n"
        .write(to: transcriptIdentityFile(pid: pid, dir: dir), atomically: true, encoding: .utf8)
}

// MARK: - The status line's side

/// Report the conversation this render was drawn for, if it is worth reporting and there is anybody
/// to report it to. Called from the status line and nowhere else.
///
/// EVERY EXIT IS SILENT. There is no error path, no output, and no throw: this runs inside the one
/// command a user sees on every interaction, and a status line that hesitated or printed a diagnostic
/// would be a worse defect than the guess this exists to remove.
///
/// THE ORDER OF THE GUARDS IS THE COST CONTROL, and it is deliberate rather than incidental:
///
///   1. No marker in the environment means nothing is supervising this session, so there is nobody
///      to tell. That is one environment read and one `kill(pid, 0)`, and it is where an unsupervised
///      `claude` running Tally's status line stops - it never touches the disk at all.
///   2. The file the marker names is read and compared. When it already says exactly this, the work
///      ends here: one small read, no directory scan, no write. That is what almost every render
///      does, because the value only changes when the conversation does.
///   3. Only a render that would say something NEW pays for the corroboration below.
///
/// Step 2 cannot be fooled by an inherited marker, which is the one thing that would make reading a
/// file named for it unsafe: it skips only when the stored report matches OURS in both fields, and
/// the pid field is this render's own Claude Code. Another session's supervisor publishes its own
/// child's pid there, and one process cannot be two supervisors' child.
/// `marker` and `claudeCodePID` are injected for the reason every other file-touching helper here
/// injects its inputs: a test of the addressing must not read the suite's own environment, where
/// `TALLY_SUPERVISOR_PID` names the very real session running it. The defaults are the real ones, so
/// the status line reads exactly as it would without them.
func reportTranscriptIdentity(sessionID: String?, cwd: String?,
                              claudeCodePID: pid_t = getppid(),
                              marker: String? = liveSessionMarker(),
                              dir: URL = supervisorStateDir) {
    guard let sessionID, isTranscriptSessionID(sessionID), let marker else { return }
    let identity = TranscriptIdentity(id: sessionID, claudeCodePID: claudeCodePID)
    guard readTranscriptIdentity(pid: marker, dir: dir) != identity else { return }
    // The same rule every second-hand surface uses, and for the same reason: a marker is inherited
    // by everything a session ever starts, so a `claude` launched from inside another supervised
    // session carries a marker that has nothing to do with it. Process ancestry settles it here
    // outright - a status line's parent IS the Claude Code it draws for, and that is the pid each
    // supervisor publishes about its own child.
    //
    // A SUPERVISOR TOO OLD TO PUBLISH ITS CHILD gets no report, and that is the right way to fail:
    // the fallback witness is the conversation id each supervisor publishes, which goes stale across
    // exactly the event this feature exists to notice (a `/clear` rebinds the transcript while the
    // published document still names the old one), so it would refuse anyway. A build that cannot
    // read the report cannot be harmed by not receiving it.
    let trust = SessionMarkerTrust.corroborated(
        PromptOrigin(marker: marker, promptSession: sessionID, claudeCodePID: claudeCodePID))
    guard case .session(let key) = trust.resolve(
        here: supervisorsInDirectory(cwd ?? FileManager.default.currentDirectoryPath, dir: dir),
        published: { readSessionContext(pid: $0, dir: dir)?.transcriptSessionID },
        childOf: { readSupervisorChild(pid: $0, dir: dir) })
    else { return }
    writeTranscriptIdentity(identity, pid: key, dir: dir)
}

// MARK: - The supervisor's side

/// Bind the watcher to the conversation this session's own child reported, when it has reported one.
/// True when that moved the watcher, which is news only to a test: the caller acts on the watcher.
///
/// TAKEN AS FACT, with none of the weighing a request goes through (`adoptRequestedTranscript`,
/// RequestTranscript.swift), and the difference is the witness rather than a change of standard:
///
///   - A REQUEST is a report about where a PROMPT was typed, routed to this supervisor by a chain of
///     witnesses, and it can arrive long after the moment it describes. So it is dated (only ever
///     forward), weighed against what the file itself says, and refused when another live supervisor
///     claims the same transcript.
///   - THIS is the process this supervisor spawned, saying what it is writing right now, on a
///     channel that only exists while it is running. There is no ordering question (a later render
///     supersedes an earlier one by definition), no identity question (the pid must be the child we
///     are running), and no rival claim to weigh (a process has one parent).
///
/// Which is also why the birth gate is absent: a resumed conversation's transcript predates this
/// child by hours and is still exactly where the conversation is. Dating it would refuse the truth.
///
/// TWO REFUSALS REMAIN, and both are about whether the report is ABOUT this child at all:
///
///   - a report from another Claude Code (a child this supervisor has since replaced, or a stale
///     file under a recycled pid), and
///   - a conversation with no transcript in this session's project directory, where there would be
///     nothing to tail and a relaunch would resume an id with nothing behind it. `bindFile`'s pinned
///     arm refuses on the same ground.
@discardableResult
func adoptReportedTranscript(watcher: inout TranscriptWatcher, sessionKey: String,
                             childPID: pid_t?, dir: URL = supervisorStateDir) -> Bool {
    guard let childPID, let report = readTranscriptIdentity(pid: sessionKey, dir: dir),
          report.claudeCodePID == childPID,
          watcher.file?.deletingPathExtension().lastPathComponent != report.id else { return false }
    let url = watcher.projectDir.appendingPathComponent("\(report.id).jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    watcher.moveTo(url)
    // The hold exists because the watcher could not tell whether a newer file was where the
    // conversation had moved (TranscriptFork.swift). It has just been told, so the question it was
    // holding open is answered. Any OTHER unresolvable candidate in this directory raises it again
    // on the next scan, exactly as before - this only drops the answer that is now stale.
    watcher.hasUnresolvedFork = false
    return true
}
