import Foundation

// THE SESSIONS NOBODY SUPERVISES, made visible to the next launch in the same directory.
//
// THE DEFECT THIS CLOSES. A launch must not resume a conversation another process is writing: two
// writers on one transcript is how about three hours of turns were orphaned here on 2026-07-29, and
// Claude Code does not refuse it for you (#88393). `liveConversations` (SwitchRequest.swift) answers
// that question, and every witness it had was keyed by a SUPERVISOR pid - the presence entry, the
// published session context, the status line's report. A session with no supervisor was therefore
// invisible to the live set in BOTH directions: the next smart launch here would hand its transcript
// to a second writer, and its own start-mode injection could take a supervised session's.
//
// WHICH SESSIONS THOSE ARE IS NOT A LIST OF LAUNCH PATHS, and the first version of this file learned
// that the hard way. It enumerated the four paths inside the CLI that exec `claude` outright (an
// exported `CLAUDE_CONFIG_DIR`, an `--account` pin, `--no-handoff`, a denormalized pin) and declared
// the launcher "the one place all four of them pass through" - a claim about EVERY launch that had
// counted only the launches it could see. `claude` also starts from the PATH shim, a bash script that
// evals `tally launch-dir` and then execs the real binary without entering this program at all
// (IntegrationsShim.swift), and from a user simply typing `claude` on a machine with no shim at all
// (codex review of fc26083). Enumerating launch paths cannot answer a question about every process
// that might be writing a transcript, because that set is not the launcher's to enumerate.
//
// SO THE ANSWER IS ASKED WHERE THE SESSION ANSWERS FOR ITSELF: the status line. Claude Code runs it
// on every render and hands it the conversation and the directory, and the process that ran it is
// the process writing the transcript (`claudeCodeThatRanUs`, TranscriptIdentity.swift). A render
// that finds no supervisor to report to records the session HERE instead, whatever launched it -
// shim, bare binary, or a Tally launch. That is the same shape as the fix that ended the fork-join
// family: stop enumerating the ways a thing can happen and ask the one party that always knows.
//
// THE LAUNCH STILL REGISTERS TOO, and it is not redundant. `execvp` replaces the image, not the
// process - pid and `p_starttime` are identical either side of it (measured 2026-08-25) - so the
// tally process about to become `claude` already knows exactly which process the session will be,
// and can write the record BEFORE the first render, with the conversation it is about to resume
// already in it. It also covers a config home where Tally's status line is not installed, which no
// render can reach. The two write the same file under the same key, so they compose rather than
// compete.
//
// A DIRECTORY OF ITS OWN, NOT THE SUPERVISOR STATE DIRECTORY, and that is deliberate rather than
// tidy. Twenty files read `supervisorStateDir`, every one of them on the premise that a file named
// for a pid in there belongs to a live SUPERVISOR: `liveSupervisorPids` counts them, the sweep
// removes them by suffix (`supervisorStateSuffixes`), the reload registry reports them as sessions
// that will restart. A record for a process that is not a supervisor, filed among those, would be
// read as one by all of them. So these live under `~/.tally/unmanaged-sessions`, where the only
// readers are in this file.
//
// WHAT IDENTIFIES THE SESSION IS A STAMP AND NOT A NUMBER, the rule `ProcessStamp` states: a pid
// names a process only while it is alive, and a record left behind by a session that ended would
// otherwise start naming whatever process next inherits that number. Every reading here compares the
// whole stamp, so a recycled pid reads as no record.
//
// OVER-NAMING IS FREE AND UNDER-NAMING IS THE DEFECT, which is what makes the supervised/unsupervised
// split safe to get slightly wrong. The live set is a UNION of ids; a session recorded on both
// channels contributes the same id twice and the set is unchanged. So the supervised test below is
// there to keep this directory tidy, not to keep it correct, and the one direction that must never
// fail is the one where nobody records the session at all.
//
// WHAT IT STILL CANNOT SEE, said rather than left to be found:
//
//   - A session under a config home with NO Tally status line, started by something that is not this
//     program (the shim, or the binary typed by hand). Nothing renders, nothing execs through the
//     launcher, and the session stays invisible exactly as it was before this file existed.
//   - A session that started FRESH under such a home through the launcher: the record exists from
//     the exec but stays unnamed, because only a render can say which conversation it became.
//   - Two launches racing in one directory: each reads the live set before the other registers, a
//     window this narrows to the width of one exec rather than closing.

/// Where the records live. Beside the supervisor state rather than inside it, for the reason the
/// header states: everything in that directory is read as a supervisor.
let unmanagedLaunchDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/unmanaged-sessions")

/// One unsupervised session: which process it is, where it was launched, and the conversation it is
/// in once anything can say.
struct UnmanagedLaunch: Equatable {
    /// The Claude Code writing the transcript: the process the launcher `execvp`'d into, or the one
    /// a status-line render found itself running under. Those are the same process by construction,
    /// which is why the two writers can share one key.
    let claudeCode: ProcessStamp
    /// The directory the launch ran in, fully resolved (/tmp -> /private/tmp) the same way the
    /// supervisor's own cwd entry is, so the two answer the same question about one path.
    let cwd: String
    /// The conversation, or nil when nothing has said yet: a launch that started fresh under a config
    /// home with no Tally status line.
    let id: String?
}

func unmanagedLaunchFile(pid: pid_t, dir: URL = unmanagedLaunchDir) -> URL {
    dir.appendingPathComponent(String(pid))
}

/// The file body: the start time on line 1, the conversation on line 2, the DIRECTORY on the rest.
///
/// THE PATH GOES LAST BECAUSE IT IS THE ONLY OPAQUE FIELD. The other two are constrained - digits,
/// and the charset `isTranscriptSessionID` admits - while a directory name on this platform may
/// contain anything but a NUL, newlines and trailing spaces included. Putting it in the middle of a
/// line-delimited format made the record depend on the path being well behaved, which is a premise
/// about the user's disk that nothing here is entitled to; putting it last makes "everything after
/// line two" its value and the shape stops mattering (codex review of fc26083, which found the
/// trailing-space half of it).
func formatUnmanagedLaunch(_ launch: UnmanagedLaunch) -> String {
    "\(launch.claudeCode.startedAt)\n\(launch.id ?? "")\n\(launch.cwd)\n"
}

/// Parse one, or nil when the file says nothing usable. Anything unparseable is NO record rather than
/// a partial one: the caller's fallback is the behaviour every build before this had.
///
/// THE PATH IS TAKEN VERBATIM and the other two fields are trimmed, which is the correction: this
/// used to trim every line, so a directory whose name ends in a space round-tripped as a DIFFERENT
/// directory and the session in it stayed invisible to the live set - the exact failure the record
/// exists to prevent, arriving through the reader. A path is bytes; only the fields with a charset
/// may be normalised.
///
/// The id is validated on the way out as well as on the way in, because a file in a state directory
/// is only ever as trustworthy as the last thing that wrote it - and an empty second line is a
/// session that has not been named yet, which is a record rather than a rejection.
func parseUnmanagedLaunch(_ raw: String, pid: pid_t) -> UnmanagedLaunch? {
    let body = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count >= 3,
          let started = Int64(lines[0].trimmingCharacters(in: .whitespaces)), started > 0
    else { return nil }
    let named = String(lines[1]).trimmingCharacters(in: .whitespaces)
    let cwd = lines.dropFirst(2).joined(separator: "\n")
    guard !cwd.isEmpty else { return nil }
    return UnmanagedLaunch(claudeCode: ProcessStamp(pid: pid, startedAt: started), cwd: cwd,
                           id: isTranscriptSessionID(named) ? named : nil)
}

func readUnmanagedLaunch(pid: pid_t, dir: URL = unmanagedLaunchDir) -> UnmanagedLaunch? {
    guard let raw = try? String(contentsOf: unmanagedLaunchFile(pid: pid, dir: dir),
                                encoding: .utf8) else { return nil }
    return parseUnmanagedLaunch(raw, pid: pid)
}

/// Publish one. Atomic, so a launch reading mid-write gets the previous record or this one and never
/// half of either, and best-effort like every other file on this track: failing to write it costs the
/// next launch its knowledge of this session, never the session.
func writeUnmanagedLaunch(_ launch: UnmanagedLaunch, dir: URL = unmanagedLaunchDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? formatUnmanagedLaunch(launch)
        .write(to: unmanagedLaunchFile(pid: launch.claudeCode.pid, dir: dir), atomically: true,
               encoding: .utf8)
}

/// Every file in this directory that is one of ours, with the record it holds when the process it
/// names is STILL that process - nil for a session that has ended, a pid handed on to somebody else,
/// or a body that says nothing usable.
///
/// One rule read by both the live set and the sweep, rather than the same listing written twice:
/// "which files here are ours" and "which of them are still running" are exactly the questions those
/// two would come to disagree about. A file not named for a pid is not ours and does not appear at
/// all, which is what keeps the sweep off anything else in the directory.
func unmanagedLaunchEntries(dir: URL = unmanagedLaunchDir,
                            stamp: (pid_t) -> ProcessStamp? = processStamp)
    -> [(file: URL, live: UnmanagedLaunch?)] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir,
        includingPropertiesForKeys: nil)) ?? []
    return files.compactMap { url in
        guard let pid = pid_t(url.lastPathComponent) else { return nil }
        let record = readUnmanagedLaunch(pid: pid, dir: dir)
        return (url, record.flatMap { stamp(pid) == $0.claudeCode ? $0 : nil })
    }
}

/// Every unsupervised session running right now.
func liveUnmanagedLaunches(dir: URL = unmanagedLaunchDir,
                           stamp: (pid_t) -> ProcessStamp? = processStamp) -> [UnmanagedLaunch] {
    unmanagedLaunchEntries(dir: dir, stamp: stamp).compactMap(\.live)
}

/// The conversations unsupervised sessions are writing in `cwd` right now - the half of the live set
/// no supervisor can report (`liveConversations`, SwitchRequest.swift).
func unmanagedConversations(in cwd: String, dir: URL = unmanagedLaunchDir,
                            stamp: (pid_t) -> ProcessStamp? = processStamp) -> Set<String> {
    let target = realpathString(cwd)
    return Set(liveUnmanagedLaunches(dir: dir, stamp: stamp)
        .filter { $0.cwd == target }
        .compactMap(\.id))
}

/// Drop the records of sessions that have ended.
///
/// Swept when a record is CREATED rather than by a timer, on both of the paths that create one (a
/// launch through this program, and the first render of a session nothing was supervising). That is
/// once per session, and it is enough: this directory only grows when a session is added to it, so
/// the one moment it can be stale is a moment something is already here to tidy it. Nothing depends
/// on the sweep for correctness - every reading refuses a record whose stamp does not match - so this
/// is about the directory not accumulating a file per session for the life of the machine.
func sweepUnmanagedLaunches(dir: URL = unmanagedLaunchDir,
                            stamp: (pid_t) -> ProcessStamp? = processStamp) {
    for entry in unmanagedLaunchEntries(dir: dir, stamp: stamp) where entry.live == nil {
        try? FileManager.default.removeItem(at: entry.file)
    }
}

/// The conversation an argument vector will pick up, when it names one.
///
/// Read from the OPTIONS only (`flagValue`), and refused when the next word is another flag: bare
/// `--resume` with nothing after it opens Claude Code's own picker, and the word behind it is then
/// somebody else's flag rather than an id. `isTranscriptSessionID` alone would not catch that - a
/// flag is letters and dashes.
func resumedConversationID(_ args: [String]) -> String? {
    let value = flagValue(args, "--resume") ?? flagValue(args, "-r")
    guard let value, !value.hasPrefix("-"), isTranscriptSessionID(value) else { return nil }
    return value
}

/// Announce a launch this program is about to exec into `claude`, in front of the exec.
///
/// NOT THE ONLY WAY A SESSION GETS RECORDED, and the header says why: the shim and a hand-typed
/// `claude` never reach this program. What this buys over the render below is the window BEFORE the
/// first render - the record exists from the exec, with the conversation this launch is about to
/// resume already in it - and a config home where Tally's status line is not installed, where no
/// render will ever run. Claude only: this whole question is about which transcript in a claude
/// project directory a launch may take, and codex keeps nothing of the sort.
///
/// `pid` and `cwd` are injectable so the rule is assertable without an exec.
func registerUnmanagedLaunch(providerID: String, args: [String],
                             cwd: String = FileManager.default.currentDirectoryPath,
                             pid: pid_t = getpid(),
                             dir: URL = unmanagedLaunchDir,
                             stamp: (pid_t) -> ProcessStamp? = processStamp) {
    guard providerID == "claude", let mine = stamp(pid) else { return }
    sweepUnmanagedLaunches(dir: dir, stamp: stamp)
    writeUnmanagedLaunch(UnmanagedLaunch(claudeCode: mine, cwd: realpathString(cwd),
                                         id: resumedConversationID(args)), dir: dir)
}

/// Everything one status-line render publishes about the conversation it drew for: to the supervisor
/// watching this session, or - when there is none - into the session's own record.
///
/// ONE FUNCTION RATHER THAN TWO CALLS AT THE STATUS LINE, so the rule "the second channel runs only
/// where the first found nobody" is a thing that can be asserted with injected inputs rather than a
/// shape somebody has to keep re-reading in `runStatusline`, which is a `Never`-returning entry point
/// no suite can call. The walk up the process tree is done once by the caller and handed to both, for
/// the reason `claudeCodeThatRanUs` states about its cost.
func publishConversationIdentity(sessionID: String?, cwd: String?,
                                 claudeCode: ProcessStamp? = claudeCodeThatRanUs(),
                                 marker: String? = liveSessionMarker(),
                                 dir: URL = supervisorStateDir,
                                 unmanagedDir: URL = unmanagedLaunchDir) {
    guard !reportTranscriptIdentity(sessionID: sessionID, cwd: cwd, claudeCode: claudeCode,
                                    marker: marker, dir: dir)
    else { return }
    adoptUnmanagedConversation(sessionID: sessionID, cwd: cwd, claudeCode: claudeCode,
                               dir: unmanagedDir)
}

/// Record the session this render was drawn for, when nothing is supervising it. Called from the
/// status line beside `reportTranscriptIdentity`, which is the supervised half of the same job and
/// whose answer decides whether this one runs at all.
///
/// ADDRESSED BY ANCESTRY, NOT BY A MARKER. An earlier version keyed this on an environment variable
/// the launcher exported, which meant it could only ever describe the sessions the launcher started
/// - the same enumeration the header rejects. The process that ran this status line IS the process
/// writing the transcript, and that is true however the session was started, so it is the key.
/// A marker would also have been inherited by every session started from inside this one; a pid read
/// off our own ancestry cannot be.
///
/// EVERY EXIT IS SILENT, and the guards are ordered by cost: a render that would say exactly what the
/// record already says stops after one small read, which is what almost every render does. Only a
/// render with news pays for a write.
///
/// A RECORD FOR THIS PID THAT NAMES A DIFFERENT PROCESS IS DEAD, not somebody else's: this pid is
/// ours right now, so a record under it with another start time was left by a session that has ended.
/// It is overwritten rather than protected. That is also the moment this channel sweeps - a new
/// record means a new session, which is once per session rather than once per render, and it is what
/// keeps the directory from growing by a file for every session on a machine that never launches
/// through this program.
///
/// THE RECORD'S OWN DIRECTORY IS KEPT when there is one. The launch directory is what the transcript
/// is filed under and what a launch asks the live set about (`projectSlug`); a session that has since
/// moved is still writing the same file in the same project directory. Only a record being created
/// takes the directory this render reports.
func adoptUnmanagedConversation(sessionID: String?, cwd: String?,
                                claudeCode: ProcessStamp? = claudeCodeThatRanUs(),
                                dir: URL = unmanagedLaunchDir,
                                stamp: (pid_t) -> ProcessStamp? = processStamp) {
    guard let sessionID, isTranscriptSessionID(sessionID), let claudeCode else { return }
    let known = readUnmanagedLaunch(pid: claudeCode.pid, dir: dir)
        .flatMap { $0.claudeCode == claudeCode ? $0 : nil }
    guard known?.id != sessionID else { return }
    if known == nil { sweepUnmanagedLaunches(dir: dir, stamp: stamp) }
    let here = known?.cwd
        ?? realpathString(cwd ?? FileManager.default.currentDirectoryPath)
    writeUnmanagedLaunch(UnmanagedLaunch(claudeCode: claudeCode, cwd: here, id: sessionID), dir: dir)
}
