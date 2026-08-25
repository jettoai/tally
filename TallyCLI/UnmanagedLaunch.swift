import Foundation

// THE SESSIONS NOBODY SUPERVISES, made visible to the next launch in the same directory.
//
// THE DEFECT THIS CLOSES. A launch must not resume a conversation another process is writing: two
// writers on one transcript is how about three hours of turns were orphaned here on 2026-07-29, and
// Claude Code does not refuse it for you (#88393). `liveConversations` (SwitchRequest.swift) answers
// that question, and every witness it had was keyed by a SUPERVISOR pid - the presence entry, the
// published session context, the status line's report. Four launch paths never get a supervisor at
// all and exec `claude` outright (Snapshot.swift `exec`): an exported `CLAUDE_CONFIG_DIR`, an
// `--account` pin, `--no-handoff`, and the denormalized pin whose account is missing from the
// snapshot. Those sessions were therefore invisible to the live set in BOTH directions - the next
// smart launch here would hand their transcript to a second writer, and their own start-mode
// injection (they run through `applyStartMode` like every other launch) could take a supervised
// session's.
//
// THE CHANNEL IS THE SAME SHAPE AS THE SUPERVISED ONE, one directory over. A plain exec KEEPS THE
// PID and the start time - `execvp` replaces the image, not the process (measured 2026-08-25: pid
// and `p_starttime` are identical either side of an execv) - so the tally process that is about to
// become `claude` already knows, exactly, which process the session will be. It writes that down
// with the directory it is launching in, and the status line fills in the conversation id as soon as
// the session has one.
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
// WHAT IT CANNOT SEE, said rather than left to be found. The id arrives from Tally's status line, so
// a config home that has not installed it reports nothing and the record keeps whatever the launch
// itself injected (`--resume <id>`, or the id the user typed) - which is the common case for these
// paths and covers them from the first instant. A session that started FRESH under a home with no
// Tally status line stays unnamed, and the launch after it is exactly as exposed as it was before
// this file existed. Two launches racing in one directory can still both pick the same conversation:
// each reads the live set before the other registers, which is a window this narrows to the width of
// one exec rather than closing.

/// Where the records live. Beside the supervisor state rather than inside it, for the reason the
/// header states: everything in that directory is read as a supervisor.
let unmanagedLaunchDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/unmanaged-sessions")

/// The environment variable naming the process a record was written for.
///
/// ITS OWN NAME RATHER THAN `TALLY_SUPERVISOR_PID`, which eleven readers take as "a supervisor is
/// watching this session" - `liveSessionMarker`, the three hooks, the status line's badges. Handing
/// them a pid that is a Claude Code and not a supervisor would make every one of them answer about a
/// process that never registered.
///
/// Inherited by everything the session starts, like every other variable here, and that is harmless
/// by construction: the reader admits it only when it names the very process that ran it, so a
/// session launched from inside an unmanaged one carries a marker that refuses to describe it.
let unmanagedLaunchMarker = "TALLY_UNSUPERVISED_PID"

/// One unsupervised session: which process it is, where it was launched, and the conversation it is
/// in once anything can say.
struct UnmanagedLaunch: Equatable {
    /// The process that `execvp`'d into `claude`, which IS the Claude Code writing the transcript.
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

/// The file body: the start time on line 1, the directory on line 2, the conversation on line 3.
/// Pure, so the format is testable without a home directory - the same split `TranscriptIdentity`
/// keeps, and for the same reason.
func formatUnmanagedLaunch(_ launch: UnmanagedLaunch) -> String {
    "\(launch.claudeCode.startedAt)\n\(launch.cwd)\n\(launch.id ?? "")\n"
}

/// Parse one, or nil when the file says nothing usable. Anything unparseable is NO record rather than
/// a partial one: the caller's fallback is the behaviour every build before this had.
///
/// The id is validated on the way out as well as on the way in, because a file in a state directory
/// is only ever as trustworthy as the last thing that wrote it - and an absent third line is a
/// session that has not been named yet, which is a record rather than a rejection.
func parseUnmanagedLaunch(_ raw: String, pid: pid_t) -> UnmanagedLaunch? {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let started = lines.first.flatMap({ Int64($0) }), started > 0,
          let cwd = lines.dropFirst().first, !cwd.isEmpty else { return nil }
    let named = lines.dropFirst(2).first.flatMap { isTranscriptSessionID($0) ? $0 : nil }
    return UnmanagedLaunch(claudeCode: ProcessStamp(pid: pid, startedAt: started), cwd: cwd,
                           id: named)
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
/// Swept at the launch that writes one rather than by a timer: this directory only grows when a
/// launch adds to it, so the one moment it can be stale is the one moment something is here to tidy
/// it. Nothing depends on the sweep for correctness - every reading already refuses a record whose
/// stamp does not match - so this is about the directory not accumulating a file per session for the
/// life of the machine.
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

/// Announce this launch, in front of the exec that turns this process into `claude`.
///
/// Called from `launchProvider` (MCPAuthSync.swift), which is the one place every unsupervised launch
/// passes through - the supervised path never reaches it - so a new launch site cannot forget to
/// register. Claude only: this whole question is about which transcript in a claude project directory
/// a launch may take, and codex keeps nothing of the sort.
///
/// The id is taken from the args this launch will actually run with, so the record is complete from
/// the first instant for the case that matters most: a launch Tally itself just pointed at a
/// conversation. `pid` and `cwd` are injectable so the rule is assertable without an exec.
func registerUnmanagedLaunch(providerID: String, args: [String],
                             cwd: String = FileManager.default.currentDirectoryPath,
                             pid: pid_t = getpid(),
                             dir: URL = unmanagedLaunchDir,
                             stamp: (pid_t) -> ProcessStamp? = processStamp) {
    guard providerID == "claude", let mine = stamp(pid) else { return }
    sweepUnmanagedLaunches(dir: dir, stamp: stamp)
    writeUnmanagedLaunch(UnmanagedLaunch(claudeCode: mine, cwd: realpathString(cwd),
                                         id: resumedConversationID(args)), dir: dir)
    setenv(unmanagedLaunchMarker, String(pid), 1)
}

/// Name the conversation this render was drawn for, when this session is an unsupervised launch
/// Tally made. Called from the status line beside `reportTranscriptIdentity`, which is the supervised
/// half of the same job.
///
/// EVERY EXIT IS SILENT, and the guards are ordered by cost exactly as that one's are: no marker
/// means this is not one of ours and nothing touches the disk; a marker that does not name the very
/// process that ran this status line is an INHERITED one, describing the session this one was started
/// from; and a render that would say what the record already says stops before writing. In a steady
/// session that leaves one small read per render and one write per `/clear`.
///
/// THE RECORD'S OWN DIRECTORY IS KEPT rather than the one the status line reports. The launch
/// directory is what the transcript is filed under and what a launch asks the live set about
/// (`projectSlug`); a session that has since moved is still writing the same file in the same project
/// directory.
func reportUnmanagedConversation(sessionID: String?,
                                 claudeCode: ProcessStamp? = claudeCodeThatRanUs(),
                                 marker: String? = ProcessInfo.processInfo
                                     .environment[unmanagedLaunchMarker],
                                 dir: URL = unmanagedLaunchDir) {
    guard let sessionID, isTranscriptSessionID(sessionID), let claudeCode, let marker,
          let pid = pid_t(marker), pid == claudeCode.pid,
          let record = readUnmanagedLaunch(pid: pid, dir: dir),
          record.claudeCode == claudeCode, record.id != sessionID else { return }
    writeUnmanagedLaunch(UnmanagedLaunch(claudeCode: claudeCode, cwd: record.cwd, id: sessionID),
                         dir: dir)
}
