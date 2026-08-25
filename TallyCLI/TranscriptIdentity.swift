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
// conversation id. A status line is in the strongest position of all three, because the process that
// RAN it is the one whose conversation it is reporting, and that pid is exactly what each supervisor
// publishes about its own child (`readSupervisorChild`). Which process that is takes a short walk up
// the ancestry rather than a `getppid()`, for the reason `claudeCodeThatRanUs` states: it is the
// parent only for the users who never had a status line of their own.

// MARK: - What identifies a process

/// WHICH PROCESS, said in the only way that stays true. A pid names a process for exactly as long as
/// that process is alive, and a supervisor spends its life replacing children: the moment one ends,
/// its number is back in the pool and the OS may hand it straight to the replacement. Every witness
/// on this track that compared pids was therefore comparing a value that CAN come out equal for two
/// different conversations, which is precisely the case the reader has to refuse (codex review of
/// 4b4454a: a status line still mid-render when its Claude Code was terminated can land its atomic
/// rename after the supervisor voided the file, and a recycled pid then makes that dead
/// conversation's report read as the new child's own).
///
/// Start time closes it: a pid is reused, a pid AND the microsecond it started at is not. It is one
/// more field off the struct the parent reading already fetches (`processIdentity`), so the cost is
/// nothing and the check stops being probabilistic.
struct ProcessStamp: Equatable {
    let pid: pid_t
    /// Microseconds since the epoch, as the kernel recorded the fork (`p_starttime`). Stable for the
    /// life of the process: two readings of a live pid give the same number, and a reused pid gives
    /// a different one.
    let startedAt: Int64
}

/// A live process's parent, its short name, and when it started, read from the kernel in one call.
///
/// `sysctl` rather than the `ps` table the backstop reads (PromptHookBackstop.swift): that one wants
/// EVERY process and their arguments, and one call answers the whole question; this one wants three
/// fields about a single pid, on a path that runs per render and per candidate per prompt, and
/// spawning `ps` to learn them would be a subprocess for a struct copy. nil when the pid is gone or
/// cannot be asked about. `parentProcessID` (SwitchRequest.swift) is the parent-only reading of it.
///
/// The name is `p_comm`: the executable's basename as the kernel recorded it, truncated to 16
/// characters - which every shell name fits inside several times over, and a shell name is all this
/// file asks of it.
func processIdentity(_ pid: pid_t) -> (parent: pid_t, name: String, startedAt: Int64)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
    }
    let started = info.kp_proc.p_un.__p_starttime
    return (info.kp_eproc.e_ppid, name,
            Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec))
}

/// Who a live pid actually is. nil when it is nobody, which every caller reads as "cannot say".
func processStamp(_ pid: pid_t) -> ProcessStamp? {
    processIdentity(pid).map { ProcessStamp(pid: pid, startedAt: $0.startedAt) }
}

// MARK: - The report file

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
/// THE STAMP IS NOT DECORATION, and it is what makes a stale file harmless. A supervisor outlives
/// its children: it relaunches one to move accounts, to change model, to take an update. A report
/// left by the child before last names a conversation that child was in, and a relaunch that starts
/// a FRESH conversation (nothing to resume) would otherwise bind the watcher to a transcript nobody
/// is writing any more. The reader therefore accepts a report only from the child it is running
/// right now, which also disposes of the other stale case for free: a recycled supervisor pid
/// inheriting a dead supervisor's file, whose child cannot be ours.
///
/// "THE CHILD IT IS RUNNING" IS A PROCESS, NOT A NUMBER, and that is the whole of the second round's
/// fix. Both halves of the defence that preceded it failed on the same square, which is why neither
/// caught it: the voiding cannot beat a rename already in flight, and a pid check cannot tell the
/// successor from the process whose number it inherited (`ProcessStamp` states the mechanism).
struct TranscriptIdentity: Equatable {
    /// Claude Code's own id for the conversation, which is also the stem of the transcript it is
    /// writing (measured 2026-08-07, and the same equality `transcriptSessionID` rests on).
    let id: String
    /// The Claude Code process that reported it: the one that ran this status line.
    let claudeCode: ProcessStamp
}

/// Parse the file body: the id on line 1, the reporting pid on line 2, its start time on line 3.
/// Pure, so the format is testable without a home directory, and anything unparseable is NO report
/// rather than a partial one - the reader's fallback is the behaviour this build has always had,
/// which is safe by construction.
///
/// THE THIRD LINE IS APPENDED, and the direction of compatibility is worth stating because only one
/// direction is free. A supervisor from before it existed reads lines 1 and 2 and stops, so it is
/// unaffected: every field it knows kept its position (the rule `RequestTranscript.swift` set). This
/// reader going the other way REFUSES a two-line report rather than assuming a start time, because
/// assuming one is exactly the comparison this round removed - and the cost of refusing is a single
/// render, after which the running status line publishes a complete one.
func parseTranscriptIdentity(_ raw: String) -> TranscriptIdentity? {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let id = lines.first, isTranscriptSessionID(id),
          let pid = lines.dropFirst().first.flatMap({ pid_t($0) }), pid > 0,
          let started = lines.dropFirst(2).first.flatMap({ Int64($0) }), started > 0
    else { return nil }
    return TranscriptIdentity(id: id, claudeCode: ProcessStamp(pid: pid, startedAt: started))
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
    try? "\(identity.id)\n\(identity.claudeCode.pid)\n\(identity.claudeCode.startedAt)\n"
        .write(to: transcriptIdentityFile(pid: pid, dir: dir), atomically: true, encoding: .utf8)
}

/// Void this session's report. Called at every spawn, before the child it would describe exists
/// (Supervisor.swift), and best-effort like every other write on this track.
///
/// DEMOTED, AND SAID SO. This arrived as the fix for a report outliving its author and was described
/// as removing "the whole window", which was wrong: an unlink cannot beat a write that has already
/// passed its checks and is landing its rename, so it narrowed the window rather than closing it,
/// and what remained needed the stamp comparison to catch (`TranscriptIdentity`). With that in place
/// the reader refuses a superseded report whether or not this file is still there.
///
/// It stays for what it does buy, which is not correctness: a dead conversation's id stops sitting
/// in the state directory for the life of the session, the void is immediate rather than deferred to
/// whenever something next reads, and it does not depend on a kernel reading succeeding.
func clearTranscriptIdentity(pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.removeItem(at: transcriptIdentityFile(pid: pid, dir: dir))
}

// MARK: - Which process ran this status line

/// The process names a status line can be running UNDERNEATH: a shell that stayed alive to do
/// something with its exit status.
let statusLineWrapperShells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh",
                                            "fish"]

/// How far up the ancestry the search goes before giving up. A process tree cannot loop, so this is
/// not a cycle guard: it is a refusal to walk an unbounded distance on a path that runs on every
/// render.
let statusLineAncestorLimit = 8

/// The Claude Code that ran this status line, which is NOT always its parent.
///
/// A USER WHO ALREADY HAD A STATUS LINE PUTS A SHELL IN BETWEEN. Tally never clobbers one: it
/// registers `tally statusline --wrap <b64> 2>/dev/null || printf %s <b64> | base64 -D | /bin/sh`,
/// so the original keeps running inside ours and survives even Tally's own disappearance
/// (`upsertStatusLine`, IntegrationsStore.swift). A command with a `||` in it is one the shell has
/// to stay around to finish, so it forks Tally and waits; a plain command it can hand over outright,
/// and it execs instead. Measured 2026-08-08 on macOS 14: the plain form's parent is Claude Code,
/// the wrapped form's parent is `/bin/sh`. So `getppid()` answers correctly for everyone who never
/// customised anything and is silently wrong for exactly the people who did - no error and no
/// fallback, just the mtime guess for ever, which is the one failure this whole file exists to end.
///
/// THE SEARCH CROSSES SHELLS AND NOTHING ELSE, and that is the safety rather than a convenience. A
/// `claude` started from a shell inside another supervised session has the OUTER Claude Code further
/// up this very chain, and refusing that one is what the corroboration below is for. Stopping at the
/// first ancestor that is not a shell stops at the process that actually ran us; a search that
/// climbed until something matched a supervisor's published child would walk straight past an
/// unsupervised inner session and publish its conversation onto the outer one.
///
/// nil is a refusal to guess, and the caller publishes nothing: an ancestry that is shells all the
/// way up, or one that cannot be read, is not evidence of anything.
///
/// TWO OBSERVATIONS, AND THEY HAVE TO AGREE. Within one walk the stamp comes off the SAME reading
/// that ruled the process out as a shell, so those two fields cannot describe different moments -
/// but the walk as a whole is still a sequence of separate readings, and the FIRST of them is
/// `getppid()`. Between it and the `sysctl` that follows, this process can be descheduled long
/// enough for its Claude Code to exit and the pid to be handed to the child replacing it: the stamp
/// assembled from those two readings is then the old pid with the NEW process's start time, which is
/// a perfectly valid stamp for a conversation this render knows nothing about (codex review of
/// 87dc17c). Splicing two observations into one identity is the same defect this file has now hit
/// three times in three different disguises, so the fix is the general one rather than a guard on
/// that particular pair: do it twice and refuse unless both answers are the same process.
///
/// Re-reading `getppid()` is what makes the second pass an independent observation rather than a
/// repeat. A dead parent cannot still be our parent: the kernel reparents us the instant it exits
/// (launchd, pid 1), so the very reading the splice depends on is the reading that gives it away.
///
/// The cost of being wrong the other way is stated rather than hidden: a chain that genuinely
/// changes BETWEEN the two passes refuses a correct answer. That costs one render. The status line
/// is still running, and the next one publishes.
func claudeCodeThatRanUs(from: () -> pid_t = getppid, limit: Int = statusLineAncestorLimit,
                         process: (pid_t) -> (parent: pid_t, name: String, startedAt: Int64)?
                             = processIdentity) -> ProcessStamp? {
    guard let first = nonShellAncestor(of: from(), limit: limit, process: process),
          let second = nonShellAncestor(of: from(), limit: limit, process: process),
          first == second else { return nil }
    return first
}

/// One pass of the search above: the nearest ancestor that is not a shell. Entry point is
/// `claudeCodeThatRanUs`, which is this run twice, because one pass is an observation and an
/// identity needs two that agree.
func nonShellAncestor(of start: pid_t, limit: Int,
                      process: (pid_t) -> (parent: pid_t, name: String, startedAt: Int64)?)
    -> ProcessStamp? {
    var pid = start
    for _ in 0..<limit {
        // pid 1 is launchd, the top of every chain: reaching it means no Claude Code was found.
        guard pid > 1, let hop = process(pid) else { return nil }
        guard statusLineWrapperShells.contains(hop.name)
        else { return ProcessStamp(pid: pid, startedAt: hop.startedAt) }
        pid = hop.parent
    }
    return nil
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
///      to tell. That is one environment read, one `kill(pid, 0)` and the handful of kernel reads
///      that name the caller (two passes of a short walk, `claudeCodeThatRanUs`), and it is where an
///      unsupervised `claude` running Tally's status line stops - it never touches the disk at all.
///   2. The file the marker names is read and compared. When it already says exactly this, the work
///      ends here: one small read, no directory scan, no write. That is what almost every render
///      does, because the value only changes when the conversation does.
///   3. Only a render that would say something NEW pays for the corroboration below.
///
/// Step 2 cannot be fooled by an inherited marker, which is the one thing that would make reading a
/// file named for it unsafe: it skips only when the stored report matches OURS in every field, and
/// the process field is this render's own Claude Code. Another session's supervisor publishes its
/// own child there, and one process cannot be two supervisors' child.
/// `marker` and `claudeCode` are injected for the reason every other file-touching helper here
/// injects its inputs: a test of the addressing must not read the suite's own environment, where
/// `TALLY_SUPERVISOR_PID` names the very real session running it. The defaults are the real ones, so
/// the status line reads exactly as it would without them.
///
/// RETURNS WHETHER A SUPERVISOR OWNS THIS SESSION, which is the one question the status line's other
/// channel has to ask before it acts (UnmanagedLaunch.swift): a session with no supervisor to report
/// to records itself instead, and asking that question a second way here would be a second copy of an
/// addressing rule that already has exactly one. True means this report reached a supervisor, or
/// found it had already said this; false means there is nobody to tell - no live marker, or a marker
/// inherited from the session this one was started from, which the corroboration below refuses.
@discardableResult
func reportTranscriptIdentity(sessionID: String?, cwd: String?,
                              claudeCode: ProcessStamp? = claudeCodeThatRanUs(),
                              marker: String? = liveSessionMarker(),
                              dir: URL = supervisorStateDir) -> Bool {
    guard let sessionID, isTranscriptSessionID(sessionID), let marker, let claudeCode
    else { return false }
    let identity = TranscriptIdentity(id: sessionID, claudeCode: claudeCode)
    guard readTranscriptIdentity(pid: marker, dir: dir) != identity else { return true }
    // The same rule every second-hand surface uses, and for the same reason: a marker is inherited
    // by everything a session ever starts, so a `claude` launched from inside another supervised
    // session carries a marker that has nothing to do with it. Process ancestry settles it here
    // outright - the Claude Code that ran this status line is the one it draws for, and that is the
    // pid each supervisor publishes about its own child.
    //
    // A SUPERVISOR TOO OLD TO PUBLISH ITS CHILD gets no report, and that is the right way to fail:
    // the fallback witness is the conversation id each supervisor publishes, which goes stale across
    // exactly the event this feature exists to notice (a `/clear` rebinds the transcript while the
    // published document still names the old one), so it would refuse anyway. A build that cannot
    // read the report cannot be harmed by not receiving it.
    let trust = SessionMarkerTrust.corroborated(
        PromptOrigin(marker: marker, promptSession: sessionID, claudeCodePID: claudeCode.pid))
    guard case .session(let key) = trust.resolve(
        here: supervisorsInDirectory(cwd ?? FileManager.default.currentDirectoryPath, dir: dir),
        published: { readSessionContext(pid: $0, dir: dir)?.transcriptSessionID },
        childOf: { readSupervisorChild(pid: $0, dir: dir) })
    else { return false }
    writeTranscriptIdentity(identity, pid: key, dir: dir)
    return true
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
///     supersedes an earlier one by definition), no identity question (the process must be the child
///     we are running), and no rival claim to weigh (a process has one parent).
///
/// Which is also why the birth gate is absent: a resumed conversation's transcript predates this
/// child by hours and is still exactly where the conversation is. Dating it would refuse the truth.
///
/// TWO REFUSALS REMAIN, and both are about whether the report is ABOUT this child at all:
///
///   - a report from another Claude Code: a child this supervisor has since replaced, a stale file
///     under a recycled supervisor pid, or a render of the ended conversation that landed after the
///     spawn onto a REUSED child pid - which is why `child` is a stamp and not a number, and
///   - a conversation with no transcript in this session's project directory, where there would be
///     nothing to tail and a relaunch would resume an id with nothing behind it. `bindFile`'s pinned
///     arm refuses on the same ground.
///
/// `child` is passed in rather than read here so the whole rule is assertable without a live process
/// on the machine; the supervisor reads its own with `processStamp`.
@discardableResult
func adoptReportedTranscript(watcher: inout TranscriptWatcher, sessionKey: String,
                             child: ProcessStamp?, dir: URL = supervisorStateDir) -> Bool {
    guard let child, let report = readTranscriptIdentity(pid: sessionKey, dir: dir),
          report.claudeCode == child,
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
