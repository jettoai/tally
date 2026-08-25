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
// THE RECORD NAMES ITS OWN FORMAT, because the layout of it has already changed once and neither
// side of that change could tell: reading a record across the swap is silent corruption rather than
// a parse failure, and one of its two directions ends with a live session missing from the live set
// - the Critical this file exists to prevent, arriving through the reader. The tag on line 1 makes
// both directions refuse the record instead (`unmanagedLaunchFormat` has the whole of it).
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

/// The tag on line 1 of every record, and the whole of what a reader accepts.
///
/// THE LAYOUT HAS ALREADY CHANGED ONCE UNDER READERS THAT COULD NOT TELL. The conversation and the
/// directory swapped places (the path moved last, for the reason `formatUnmanagedLaunch` states),
/// and both directions of that change are silent corruption rather than a parse failure: a new
/// reader on an old record takes `/Users/a/project` as the conversation - it fails
/// `isTranscriptSessionID`, so the session reads as UNNAMED and vanishes from the live set, which is
/// the very Critical this file exists to prevent - and an old reader on a new record takes the
/// conversation as the directory. Neither is detectable from the fields themselves, because a
/// directory is opaque by definition and every shape is a legal one.
///
/// So line 1 is a name rather than data. A reader from before this tag existed wants an `Int64`
/// there, does not get one, and refuses the whole record; a reader after it wants exactly this
/// string, and refuses everything else - an older layout, a newer one, a half-written file. Both
/// directions therefore READ no record at all, which is the behaviour every build before this
/// channel existed had.
///
/// REFUSING TO READ A RECORD IS NOT A LICENCE TO DELETE IT, and the sweep rather than the parse is
/// where that distinction is kept: the builds either side of a layout change run on one machine at
/// the same time, so a record this one cannot read may be a live session's, and deleting it turns
/// this safe read into the Critical the file exists to prevent (`sweepUnmanagedLaunches` has the
/// whole of it, from the codex review of e1bde51).
///
/// NAMED RATHER THAN "v2", because this is the first VERSIONED format and the second LAYOUT: a
/// numeral on line 1 would be off by one against the layouts for anybody counting later. Nothing
/// migrates an older record - fc26083 and ea8816e never shipped, so the unversioned layouts exist
/// only on the machines that built them, and migration code would be a permanent cost paid to a
/// window that closes on its own.
let unmanagedLaunchFormat = "tally-unmanaged-1"

/// The file body: the format tag on line 1, the start time on line 2, the conversation on line 3,
/// the DIRECTORY on the rest.
///
/// THE PATH GOES LAST BECAUSE IT IS THE ONLY OPAQUE FIELD. The other two are constrained - digits,
/// and the charset `isTranscriptSessionID` admits - while a directory name on this platform may
/// contain anything but a NUL, newlines and trailing spaces included. Putting it in the middle of a
/// line-delimited format made the record depend on the path being well behaved, which is a premise
/// about the user's disk that nothing here is entitled to; putting it last makes "everything after
/// the id" its value and the shape stops mattering (codex review of fc26083, which found the
/// trailing-space half of it). That move is also what the tag above is for: it is the change no
/// reader on either side of it could have noticed.
func formatUnmanagedLaunch(_ launch: UnmanagedLaunch) -> String {
    "\(unmanagedLaunchFormat)\n\(launch.claudeCode.startedAt)\n\(launch.id ?? "")\n\(launch.cwd)\n"
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
/// is only ever as trustworthy as the last thing that wrote it - and an empty id line is a session
/// that has not been named yet, which is a record rather than a rejection.
///
/// THE DIRECTORY IS CHECKED FOR THE ONE THING EVERY REAL ONE HAS. It is opaque, so there is nothing
/// to validate about its shape - except that every path written here went through `realpathString`
/// first, which answers with an ABSOLUTE path for anything that resolves. Provenance is not what
/// this guard can speak to: the render channel's directory arrives in the JSON Claude Code hands the
/// status line, and `realpathString` returns its argument unchanged when the resolve fails, so the
/// field can carry a value neither written nor normalised by this program. What the guard rejects is
/// a value that cannot be the resolved directory of any live process - a relative path, the id line
/// of some other layout, a half-written file - which makes the record corrupt rather than a
/// directory, and it is refused. This is the second of the two guards and it is not the tag's
/// understudy: the tag catches a whole record from another layout, this catches a field that arrived
/// from anywhere else.
func parseUnmanagedLaunch(_ raw: String, pid: pid_t) -> UnmanagedLaunch? {
    let body = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count >= 4, lines[0] == unmanagedLaunchFormat,
          let started = Int64(lines[1].trimmingCharacters(in: .whitespaces)), started > 0
    else { return nil }
    let named = String(lines[2]).trimmingCharacters(in: .whitespaces)
    let cwd = lines.dropFirst(3).joined(separator: "\n")
    guard cwd.hasPrefix("/") else { return nil }
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

/// What one file in this directory is, to the two questions asked of it.
///
/// THOSE ARE NOT THE SAME QUESTION, and this type exists because folding them into one answer is how
/// a safe read became a destructive delete. "Who is running here" takes a file this build cannot
/// read as a no, exactly as every build before this channel did; "who has certainly ended" takes the
/// same file as no answer at all, for the reason `sweepUnmanagedLaunches` states. A single
/// `UnmanagedLaunch?` cannot hold both, which is what let the second be read off the first.
enum UnmanagedLaunchState: Equatable {
    /// The pid this file is named for is still the process the record inside it describes.
    case live(UnmanagedLaunch)
    /// Positively confirmed over: no process under that pid, or one whose stamp is not the record's,
    /// which is a pid handed on to somebody else. The only state the sweep removes.
    case ended
    /// The process is running and this build cannot say what its file means: a tag it does not know,
    /// a layout from another build, a half-written file. Neither live nor deletable.
    case unreadable

    var live: UnmanagedLaunch? {
        guard case .live(let launch) = self else { return nil }
        return launch
    }
}

/// Every file in this directory that is one of ours, and what it is.
///
/// One rule read by both the live set and the sweep, rather than the same listing written twice:
/// "which files here are ours" and "which of them are still running" are exactly the questions those
/// two would come to disagree about. A file not named for a pid is not ours and does not appear at
/// all, which is what keeps the sweep off anything else in the directory.
///
/// THE PID IS ASKED ABOUT BEFORE THE FILE IS READ, and not only because it is the cheaper of the
/// two: a dead pid ends the question whatever the body says, while a body that says nothing usable
/// only ends it once the pid is known to be gone.
func unmanagedLaunchEntries(dir: URL = unmanagedLaunchDir,
                            stamp: (pid_t) -> ProcessStamp? = processStamp)
    -> [(file: URL, state: UnmanagedLaunchState)] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir,
        includingPropertiesForKeys: nil)) ?? []
    return files.compactMap { url in
        guard let pid = pid_t(url.lastPathComponent) else { return nil }
        guard let running = stamp(pid) else { return (url, .ended) }
        guard let record = readUnmanagedLaunch(pid: pid, dir: dir) else { return (url, .unreadable) }
        return (url, record.claudeCode == running ? .live(record) : .ended)
    }
}

/// Every unsupervised session running right now.
func liveUnmanagedLaunches(dir: URL = unmanagedLaunchDir,
                           stamp: (pid_t) -> ProcessStamp? = processStamp) -> [UnmanagedLaunch] {
    unmanagedLaunchEntries(dir: dir, stamp: stamp).compactMap { $0.state.live }
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
///
/// ENDED IS A POSITIVE FINDING HERE, NOT THE ABSENCE OF A LIVE ONE, and that distinction is the
/// whole of what this function got wrong. It used to delete every entry the live set could not use,
/// which reads "this build cannot parse it" as "its session is over": under a pid that is running,
/// that file is most likely the live record of a session the build on the other side of a layout
/// change is writing, and this directory is the ONLY witness such a session has under a config home
/// with no Tally status line to write the record again. Deleting it makes the next launch in that
/// directory resume a transcript somebody is holding open, which is precisely the Critical this file
/// exists to prevent - so the tidying job is not allowed to reach a file it cannot read (codex
/// review of e1bde51). The cost of keeping it is one file until that pid dies, when the very next
/// sweep confirms the death and takes it.
func sweepUnmanagedLaunches(dir: URL = unmanagedLaunchDir,
                            stamp: (pid_t) -> ProcessStamp? = processStamp) {
    for entry in unmanagedLaunchEntries(dir: dir, stamp: stamp) where entry.state == .ended {
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
