import Foundation

// How a `tally switch` reaches ONE running session: the request file it writes, and the two ways a
// session can be identified. The decision a supervisor then makes about that request, and the
// command that writes it, live next door in SessionSwitch.swift; this side is the addressing, split
// out because it is what the CLI, the supervisor and the state-directory sweep all have to agree on
// (the same division ReloadRequest.swift keeps from Reload.swift).
//
// A reload speaks to EVERY session through one file. This speaks to one, so the file is named for
// its reader: the supervisor's pid, which that supervisor stamps into its child's environment
// (`TALLY_SUPERVISOR_PID`, Supervisor.swift) and every process the child spawns inherits - the
// agent's own shell included, which is the main path (Claude asked mid-conversation to move
// accounts runs the command itself). A shell opened separately in the project directory carries no
// such marker, and falls back to the registry of live supervisors and the directory each publishes.

// MARK: - The request file

/// One request file per supervised session, named for the supervisor pid that will read it.
/// A directory rather than a single file because these are addressed: two sessions can each have one
/// pending, and neither may read the other's.
let switchRequestDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/switch")

/// The account id that means "no account": `tally switch --auto`, asking the supervisor to drop the
/// session pin a previous switch left behind (SessionSwitch.swift).
///
/// The flag the user types and the token the file carries are ONE string on purpose: the request
/// file is the only channel between the command and the supervisor, so a second spelling would be a
/// second thing to keep in step for no gain. It cannot collide with a real account: an id is
/// `<provider>:<config-dir name>` (Snapshot.swift), so it always carries a colon and never starts
/// with a dash.
let switchAutoRequest = "--auto"

/// A parsed switch request: when it was made, and the account it names.
struct SwitchRequest: Equatable {
    /// MILLISECONDS since the unix epoch, unlike the reload stamp's seconds. The supervisor acts
    /// only on a stamp strictly newer than the one it has served, and this request is typed by hand
    /// INSIDE the session it moves: "switch to A" and, on seeing the wrong account, "switch to B" a
    /// moment later are one sequence a person really performs, and at second resolution the second
    /// one reads as already served and vanishes silently.
    let epoch: Int
    /// The account id the snapshot lists, not the name that was typed: the CLI resolves the name
    /// against the live fleet at write time (the same rule `tally project set --account` follows),
    /// so a label renamed while the request sat here still moves the session to the right account.
    let accountID: String
    /// The conversation this was typed into, as Claude Code itself reported it, or nil when the
    /// surface that wrote it had no such report (a person's own shell). What it is FOR, and why a
    /// request has to carry it at all, is RequestTranscript.swift.
    ///
    /// A `var` with a default so the memberwise initialiser keeps working unchanged, which is the
    /// same additivity the file format below promises the other way round.
    var transcriptID: String?

    /// This request releases the session pin rather than naming somewhere to go.
    var isUnpin: Bool { accountID == switchAutoRequest }
}

/// Parse the file body: the stamp on line 1, the account id on line 2, the conversation it was typed
/// into on line 3 (empty, or absent altogether, meaning "nothing can say"). Pure, so the format is
/// testable without a home directory. Anything unparseable is nil - no request - rather than a
/// partial one: a truncated write must never read as a switch to an account nobody named.
///
/// LINE 3 IS ADDITIVE IN BOTH DIRECTIONS, which is the whole of its compatibility story: a file
/// written before it existed simply has no third line and parses exactly as it always did, and a
/// supervisor from such a build reads lines 1 and 2 of a new file and ignores what follows. An
/// unusable value (one that could not name a transcript, `isTranscriptSessionID`) reads as ABSENT
/// rather than as a broken request: it says nothing about the account, which is the instruction.
func parseSwitchRequest(_ raw: String) -> SwitchRequest? {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let epoch = lines.first.flatMap({ Int($0) }),
          let accountID = lines.dropFirst().first, !accountID.isEmpty else { return nil }
    let transcript = lines.dropFirst(2).first.flatMap { isTranscriptSessionID($0) ? $0 : nil }
    return SwitchRequest(epoch: epoch, accountID: accountID, transcriptID: transcript)
}

func switchRequestFile(sessionKey: String, dir: URL = switchRequestDir) -> URL {
    dir.appendingPathComponent(sessionKey)
}

/// This session's pending request, or nil when there is none (or it cannot be read).
func readSwitchRequest(sessionKey: String, dir: URL = switchRequestDir) -> SwitchRequest? {
    guard let raw = try? String(contentsOf: switchRequestFile(sessionKey: sessionKey, dir: dir),
                                encoding: .utf8) else { return nil }
    return parseSwitchRequest(raw)
}

/// Stamp a request for one session. Atomic (Foundation writes temp + rename), so a supervisor
/// polling mid-write reads either the previous request or this one, never half of either.
///
/// The third line is written even when there is nothing to put on it, the way the model request
/// writes its own unnamed effort: one shape on disk is one shape to read back, and a reader old
/// enough to know only the first two lines is unaffected either way.
func writeSwitchRequest(accountID: String, sessionKey: String, transcriptID: String? = nil,
                        now: Date = Date(), dir: URL = switchRequestDir) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let body = "\(Int(now.timeIntervalSince1970 * 1000))\n\(accountID)\n"
        + "\(transcriptRequestLine(transcriptID))\n"
    try body.write(to: switchRequestFile(sessionKey: sessionKey, dir: dir), atomically: true,
                   encoding: .utf8)
}

/// The request is served (or found to be about nothing): unlink it. The served stamp in memory is
/// what makes the decision idempotent; this only keeps the directory from collecting husks.
func clearSwitchRequest(sessionKey: String, dir: URL = switchRequestDir) {
    try? FileManager.default.removeItem(at: switchRequestFile(sessionKey: sessionKey, dir: dir))
}

/// Drop requests addressed to supervisors that are gone: a session can exit with one still pending
/// (it was queued behind a turn that never ended), and the OS reuses pids. Swept by the CLI as it
/// writes, which is the only moment anything here grows.
///
/// Named for the SESSION rather than for the switch, and the directory is a required argument, so
/// every per-session request directory sweeps through this one loop: `tally model` writes into its
/// own (ModelRequest.swift) under the same naming rule, and a second copy of this loop would be a
/// second answer to "is that pid still alive".
///
/// Its own function rather than `sweepDeadSupervisorState` pointed at these directories, though the
/// two loops look alike: that one reads names through `supervisorStatePid`, which accepts the
/// suffixed documents the state directory holds, and NOTHING here is ever suffixed. Sharing it would
/// make these directories' naming contract the other one's, so a document added there could start
/// being deleted from here.
func sweepDeadSessionRequests(dir: URL) {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir,
        includingPropertiesForKeys: nil)) ?? []
    for file in files {
        guard let pid = pid_t(file.lastPathComponent), !supervisorAlive(pid) else { continue }
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: - Which session is asking

/// The suffix under which a supervisor publishes the directory its session runs in, beside its
/// presence entry in `supervisorStateDir` (the track the drift badge and the pending notice share).
///
/// It exists only for the fallback below - a shell opened separately in a project directory, with no
/// session marker in its environment. The supervisor's own cwd cannot change while it runs, so this
/// is written once at startup and never again.
let supervisorCwdSuffix = ".cwd"

func supervisorCwdFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + supervisorCwdSuffix)
}

/// Publish this supervisor's working directory. Best-effort, like everything else on this track:
/// failing to write it costs the fallback, never the session.
func writeSupervisorCwd(_ cwd: String, pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? realpathString(cwd).write(to: supervisorCwdFile(pid: pid, dir: dir), atomically: true,
                                   encoding: .utf8)
}

/// The suffix of the file naming the Claude Code a supervisor is running.
let supervisorChildSuffix = ".child"

func supervisorChildFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + supervisorChildSuffix)
}

/// Publish the pid of the Claude Code this supervisor just spawned.
///
/// A FILE OF ITS OWN, beside the directory this supervisor runs in and for the same reason: it is
/// known at spawn and it is true from that instant, where the context reading next door does not
/// exist until the conversation has had a turn with usage in it (`SessionContextWriter.sync`
/// returns on a nil token count, deliberately - inventing a number nobody measured would be worse
/// than silence). Riding this witness on that document made it arrive LATE, and a bare
/// `/tally-model` typed as the first thing in a fresh session is the single commonest way to reach
/// this feature: the witness has to be there before the first turn, not after it (codex review of
/// 49dcdcd). It also has to be replaced at a relaunch, which is why it is written at the spawn
/// rather than once at start-up.
///
/// Best-effort like everything else on this track: failing to write it costs the fallback witnesses,
/// never the session.
func writeSupervisorChild(_ child: pid_t, pid: String, dir: URL = supervisorStateDir) {
    let file = supervisorChildFile(pid: pid, dir: dir)
    // TAKEN AWAY FIRST, and the order is the guard. A publish that fails at a relaunch (a full
    // disk, a permission that changed under us) used to leave the PREVIOUS child's pid in place,
    // and a stale pid here is worse than no pid at all: it reads as a confident "not this session",
    // which removes the only real candidate and skips the fallbacks with it - so every `/tally-*`
    // in that session fails until it restarts (codex review of bc606c4). Removing first turns that
    // failure into an ABSENT file, which every witness reads as "cannot say" and passes on.
    try? FileManager.default.removeItem(at: file)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? String(child).write(to: file, atomically: true, encoding: .utf8)
}

/// The parent of a live process, straight from the kernel: the one field of `processIdentity`
/// (TranscriptIdentity.swift, which states why this is a `sysctl` and not the `ps` table next door)
/// that this track asks for. nil when the pid is gone or cannot be asked about.
func parentProcessID(_ pid: pid_t) -> pid_t? { processIdentity(pid)?.parent }

/// The Claude Code that supervisor is running, or nil when there is no answer to be had.
///
/// TWO THINGS ARE CHECKED, and neither is the file's contents. A publish that fails leaves the
/// previous child's pid behind (the removal above narrows that, and a directory which has become
/// unwritable defeats both halves of it), so the value on disk cannot be taken as a fact:
///
///   - THE PROCESS MUST BE RUNNING. A relaunch terminates the old child before spawning the new
///     one, so a stale value names a process that has exited - and reading it as a fact is exactly
///     the failure this guard exists to prevent: it makes the one real candidate look "provably not
///     it", removing it and skipping the fallbacks behind it.
///   - AND IT MUST BE THIS SUPERVISOR'S OWN CHILD. Liveness alone is not enough, because pids are
///     reused: the OS can hand a stale pid to something else entirely, and that process is alive.
///     The child is spawned directly by the supervisor (`spawnChild`, posix_spawnp), so its parent
///     IS the supervisor, and a reused pid would have to land under the very same parent to fool
///     this. Nothing sweeps the residue for us - the sweep is keyed on the SUPERVISOR's pid, and a
///     supervisor that is still alive keeps its own stale `.child` file forever (a claim to the
///     contrary stood in this comment until codex read it, 3c0635a) - so this check is the whole
///     defence rather than a narrowing of one.
func readSupervisorChild(pid: String, dir: URL = supervisorStateDir) -> Int? {
    guard let raw = try? String(contentsOf: supervisorChildFile(pid: pid, dir: dir),
                                encoding: .utf8),
          let child = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let running = pid_t(exactly: child), supervisorAlive(running),
          let supervisor = pid_t(pid), parentProcessID(running) == supervisor else { return nil }
    return child
}

func readSupervisorCwd(pid: String, dir: URL = supervisorStateDir) -> String? {
    guard let raw = try? String(contentsOf: supervisorCwdFile(pid: pid, dir: dir), encoding: .utf8)
    else { return nil }
    let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
}

/// The live supervisors running in `cwd`, sorted so the answer is stable. Fully resolved on both
/// sides (/tmp -> /private/tmp), which is how the supervisor wrote it.
func supervisorsInDirectory(_ cwd: String, dir: URL = supervisorStateDir) -> [String] {
    let target = realpathString(cwd)
    return liveSupervisorPids(dir: dir)
        .filter { readSupervisorCwd(pid: String($0), dir: dir) == target }
        .map(String.init)
        .sorted()
}

/// Which session a `tally switch` belongs to.
enum SessionLookup: Equatable {
    /// The supervisor pid to address the request to.
    case session(String)
    /// Nothing supervised is running here: an unsupervised launch (`--no-handoff`, an `--account`
    /// pin, a piped run) or a bare `claude`, neither of which anything can move.
    case none
    /// Several sessions share this directory and the command came from outside all of them, so
    /// there is no way to tell which one was meant.
    case ambiguous([String])
}

/// The choice itself, pure. `envPid` is the marker the supervisor stamped into this session's
/// environment, already checked for liveness by the caller; `here` is every live supervisor in this
/// directory. The environment wins whenever it is present, and that is the whole design: it names
/// the session the command was actually run in, while the directory can only ever name candidates.
func sessionLookup(envPid: String?, here: [String]) -> SessionLookup {
    if let envPid { return .session(envPid) }
    if here.count == 1, let only = here.first { return .session(only) }
    return here.isEmpty ? .none : .ambiguous(here)
}

/// How far a surface may trust the session marker it is holding. THE ONE RULE for "which session
/// does this belong to", stated once because it has now been got wrong twice in two different
/// places.
///
/// A marker is exported by a supervisor into the child it spawns, and it is inherited by everything
/// that child ever starts. That makes it a perfect answer for a process that DESCENDS from the
/// session, and a trap for a process that was merely told about a prompt:
///
///   - A person's shell descends from the session they are typing in, so `tally model` typed there
///     is talking about that session even when it is run from a subdirectory the supervisor never
///     published. The marker is the only witness there, and it is a good one.
///   - The MCP server is a long-lived child of Claude Code, and Claude Code inherits its own
///     environment from whatever launched it. Start one session's `claude` from a shell inside
///     another session and the marker travels straight down into a conversation it has nothing to
///     do with (QA, 2026-08-07: a bare `/tally-model` in an unsupervised scratch session pinned
///     opus/xhigh onto pid 23743).
///   - A prompt HOOK is the same story and has been shipping with it: the hook is a child of Claude
///     Code, so a `claude` launched from a supervised shell answers `/tally-model` by describing the
///     OUTER session. Found by QA on the backstop, and true of the plain command hook all along.
///
/// So a marker that reached us second-hand has to be CORROBORATED: the directory the prompt came
/// from must actually be running that supervisor. Corroboration is what keeps the marker useful
/// rather than merely discarding it - with several sessions in one directory it is the only thing
/// that can say WHICH, and a directory-only answer would have to refuse them all.
///
/// The cost is stated rather than hidden: a session whose supervisor never managed to publish its
/// directory (that write is best-effort, `writeSupervisorCwd`) has an uncorroborated marker, and
/// its hooks now refuse with "this session is not supervised" instead of acting. Fail-closed is the
/// right side to land on when the alternative is acting on somebody else's live conversation.
enum SessionMarkerTrust: Equatable {
    /// This process descends from the session, so the marker names it outright.
    case trusted(String?)
    /// The marker arrived from somewhere that may not be this session at all. It counts only after
    /// the witnesses in `PromptOrigin` have had their say.
    case corroborated(PromptOrigin)

    /// The marker itself, whether or not a resolution will end up using it.
    var value: String? {
        switch self {
        case .trusted(let marker): return marker
        case .corroborated(let origin): return origin.marker
        }
    }

    /// The marker as a resolution ACTUALLY used it, given the session it landed on: nil when the
    /// directory answered instead. What separates "this command is running inside that session" from
    /// "this command found that session by looking", which two callers have to tell apart - the
    /// already-there reading, and the supervisor-version check that may only be made against a
    /// version stamped beside a marker we believed.
    func adopted(_ sessionKey: String) -> String? {
        value == sessionKey ? sessionKey : nil
    }

    /// Which session this is, given every live supervisor in the directory the prompt came from.
    ///
    /// `published` answers "which conversation is that supervisor watching", and is injected so the
    /// whole rule is assertable without a supervisor on the machine. The default reads the track
    /// everything else on this path reads.
    func resolve(here: [String],
                 published: (String) -> String? = {
                     readSessionContext(pid: $0)?.transcriptSessionID
                 },
                 childOf: (String) -> Int? = { readSupervisorChild(pid: $0) })
        -> SessionLookup {
        switch self {
        case .trusted(let marker):
            return sessionLookup(envPid: marker, here: here)
        case .corroborated(let origin):
            /// What a narrowed candidate set comes to, with the marker allowed to choose INSIDE it
            /// and nowhere else. A marker that is not among the candidates is DROPPED rather than
            /// argued with: what remains is the same directory-only answer a shell outside every
            /// session gets, refusals included.
            func decide(_ candidates: [String]) -> SessionLookup {
                sessionLookup(envPid: origin.marker.flatMap {
                    candidates.contains($0) ? $0 : nil
                }, here: candidates)
            }
            // STAGED NARROWING, strongest witness first. Process ancestry cannot go stale under the
            // session and cannot be shared by two of them; the conversation id can do neither of
            // those but still separates supervisors from a build that publishes no child pid; the
            // marker only ever chooses INSIDE what they leave. Each stage passes on what it could
            // not rule out, so a directory holding one new-build and one old-build supervisor is
            // narrowed by whichever witness can actually speak for them.
            let running = sessionsRunning(origin.claudeCodePID, among: here, published: childOf)
            // A POSITIVE reading ends it. The conversation id is the weaker witness of the two and
            // it goes stale (a `/clear` rebinds the transcript while the published document still
            // names the old one), so letting it filter a set the process witness has already named
            // would refuse the very session that just cleared - with the hook blocking the turn
            // that could fix it (codex review of 0708b21).
            guard !running.identified else { return decide(running.candidates) }
            return decide(sessionsWatching(origin.promptSession, among: running.candidates,
                                           published: published).candidates)
        }
    }
}

/// Everything a second-hand caller knows about the session whose prompt it is answering.
///
/// A struct rather than three associated values, because this is the third time the answer to "how
/// do we know which session this is" has needed another field, and each time it grew every
/// signature it passes through. What a caller must not be able to do is supply one witness while
/// silently omitting another, so they travel together.
struct PromptOrigin: Equatable {
    /// The supervisor pid in this process's environment, which may have been inherited from a
    /// session that has nothing to do with this prompt.
    var marker: String?
    /// Claude Code's own id for the conversation, off the hook payload.
    var promptSession: String?
    /// The pid of the Claude Code process this prompt came from: for a hook, its own parent; for
    /// the MCP server, the parent it recorded at start-up.
    var claudeCodePID: pid_t?
}

/// ONE NARROWING RULE, shared by every witness: the candidates a witness can vouch for, or - when
/// it can vouch for none of them - the candidates it could not speak for at all.
///
/// The second half is what keeps a staged narrowing honest, and getting it wrong broke a whole
/// class of machine each time. A witness that answers for SOME candidates has said nothing about
/// the ones it has no reading for, so those survive to the next stage; only the ones it read and
/// disagreed with are provably not it. Dropping the silent ones with them takes every supervisor
/// from an older build down with the new ones in the same directory (codex review of 49dcdcd);
/// keeping the disagreeing ones puts back the nested session this whole mechanism exists to
/// separate.
///
/// An empty result is therefore a REAL refusal: every candidate was read, and every one of them
/// disagreed.
func narrowed<Witness: Equatable>(_ wanted: Witness?, among here: [String],
                                  published: (String) -> Witness?) -> WitnessReading {
    guard let wanted else { return WitnessReading(identified: false, candidates: here) }
    var matches: [String] = []
    var silent: [String] = []
    for candidate in here {
        guard let reading = published(candidate) else { silent.append(candidate); continue }
        if reading == wanted { matches.append(candidate) }
    }
    return matches.isEmpty
        ? WitnessReading(identified: false, candidates: silent)
        : WitnessReading(identified: true, candidates: matches)
}

/// What one witness had to say about a candidate set.
///
/// THE TWO ANSWERS ARE NOT THE SAME KIND OF ANSWER, and collapsing them is how a staged narrowing
/// goes wrong in both directions at once. `identified` is a POSITIVE reading - these candidates are
/// the ones this witness names - and it is dispositive: a later, weaker witness must not be allowed
/// to take it back, which is exactly what happened to a session that had just run `/clear` (its
/// process matched, and the stale conversation id then removed it again). Without it, the survivors
/// are only "the ones this witness could not disprove", which is a narrowing the next stage is free
/// to refine.
struct WitnessReading: Equatable {
    let identified: Bool
    let candidates: [String]
}

/// The supervisors in `here` whose own child is the Claude Code that sent this prompt.
///
/// Matched against the caller's DIRECT parent and nothing further up, which is the whole of its
/// safety. The backstop next door tolerates a grandparent because its mistake costs one model turn
/// (PromptHookBackstop.swift); the same tolerance here would cost a write into another
/// conversation, because a `claude` started from inside another session has that session's Claude
/// Code two levels up. Measured 2026-08-07: a hook's parent IS the Claude Code that ran it, and an
/// MCP server's parent is the Claude Code that started it. If that ever stops being true, no
/// candidate matches, and what survives is whatever this witness could not read - which is the
/// older builds, exactly as it should be.
func sessionsRunning(_ claudeCodePID: pid_t?, among here: [String],
                     published: (String) -> Int?) -> WitnessReading {
    narrowed(claudeCodePID.map(Int.init), among: here, published: published)
}

/// The supervisors in `here` that could be watching the conversation a prompt came from.
///
/// Three answers, and the third is the one that keeps this safe to ship:
///
///   - A candidate publishing EXACTLY that conversation is it, and nothing else can be: the answer
///     is that one alone, which is also what disambiguates several sessions in one directory.
///   - A candidate publishing a DIFFERENT conversation is provably not it, and is dropped. This is
///     the nested case: the outer session publishes its own transcript id, the inner session's
///     prompt carries another, and the outer stops being a candidate at all.
///   - A candidate publishing NOTHING is kept. A supervisor from a build before this field existed
///     has no witness, and treating silence as a denial would take `/tally-model` away from every
///     session running an older supervisor until it restarted. Silence means "cannot say", here as
///     everywhere else on this track.
///
/// Pure over an injected reader, so all three are asserted without a supervisor on the machine.
/// EVERY exact match, not the first one. Two supervisors starting in one directory at once can bind
/// the same transcript by the mtime heuristic (`bindFile`, TranscriptWatcher.swift) and so publish
/// the same id; returning the first would hand the marker no chance to say which is which, and the
/// caller would write into whichever happened to sort earlier (codex review of 0708b21). Several
/// matches go back as several, and the marker disambiguates them exactly as it does any other
/// ambiguous directory - and refuses when it cannot.
func sessionsWatching(_ promptSession: String?, among here: [String],
                      published: (String) -> String?) -> WitnessReading {
    narrowed(promptSession.flatMap { $0.isEmpty ? nil : $0 }, among: here, published: published)
}

/// The session a command typed HERE belongs to, asked of the live world: the supervisor pid to
/// address, and whether the command was run from inside that session. nil when nothing supervised is
/// running here, and nil when several are and the command came from outside all of them - the two
/// cases in which nothing may claim to describe "this session".
///
/// It exists so the two halves of ONE command cannot answer that question differently. The half that
/// writes the request has always gone through `sessionLookup` and therefore through the directory
/// fallback; the halves that DRAW the fleet first (the arrow-key menu, the hook's listing) read only
/// the environment marker, which a shell opened separately in the project directory does not carry.
/// So a bare `tally switch` in a second terminal marked no row as "this session" and could
/// recommend the very account that session was already running - while the request it went on to
/// write moved that session for real (found in review of 0.38.1's zero-turn work).
///
/// A refusal still belongs to the caller: `attemptSwitch` keeps its own `switch` because `.none` and
/// `.ambiguous` need sentences of their own there. What is shared is the RULE, not the wording.
///
/// `dir` and `marker` are injected for the reason every other file-touching helper here injects
/// them: a test of the fallback must not read the machine's own `~/.tally` or its own shell's
/// variables. The defaults are the real ones, so every caller reads unchanged.
///
/// `marker` IS THE MARKER TO TRUST, and nil means THERE IS NONE rather than "go and read the
/// environment". The difference is the whole of a live defect (QA, 2026-08-07): the MCP server
/// behind the native pickers inherits its environment from whatever launched Claude Code, which on
/// a machine where one session's shell started another's is a DIFFERENT session's supervisor pid -
/// and a marker outranks the directory unconditionally, so the picker pinned a model onto somebody
/// else's live conversation. Every surface a person types into passes `liveSessionMarker()` and
/// reads exactly as before; the MCP path passes nil and is resolved by directory alone.
func currentSessionLookup(cwd: String = FileManager.default.currentDirectoryPath,
                          dir: URL = supervisorStateDir,
                          marker: SessionMarkerTrust = .trusted(liveSessionMarker()))
    -> (key: String, isThisSession: Bool)? {
    guard case .session(let key) = marker.resolve(
        here: supervisorsInDirectory(cwd, dir: dir),
        published: { readSessionContext(pid: $0, dir: dir)?.transcriptSessionID },
        childOf: { readSupervisorChild(pid: $0, dir: dir) })
    else { return nil }
    // Only a marker the resolution ACTUALLY used describes this process; one that was dropped for
    // want of corroboration says nothing about where this command is running.
    return (key, marker.value == key)
}

/// The account a supervised session is running on RIGHT NOW, or nil when nothing can say.
///
/// The supervisor publishes it beside its presence entry, rewritten by every handoff
/// (SessionContext.swift), which makes it the only answer that describes the session being asked
/// about rather than the shell doing the asking. It appears once that session has had a turn with a
/// usage reading in it, so a conversation that has not said anything yet has none.
///
/// TWO WITNESSES, and the answer is only given when they do not contradict each other.
///
/// From ANOTHER shell in the project directory there is only one: that shell's own config home
/// describes whatever launched IT, so the published reading is all there is. Its staleness window is
/// stated rather than hidden - from a handoff until the supervisor publishes again, it can name the
/// account the session just left - and the supervisor narrows it by republishing at the relaunch
/// itself (`SessionContextWriter.accountChanged`).
///
/// From INSIDE the session (`isThisSession`) there are two, and each is fresh in a way the other is
/// not. The environment IS that session's, exported when the supervisor spawned the child this shell
/// descends from... unless this shell is OLDER than the last handoff. A long-lived background
/// process started before the move still carries the pre-handoff `CLAUDE_CONFIG_DIR` and still sees
/// a live `TALLY_SUPERVISOR_PID` (the pid does not change when the child does), so on its own the
/// environment would answer "already on A" for a session that has since moved to B - dropping a
/// deliberate "switch back to A" as a no-op. The published file is fresh in the opposite direction:
/// written on a poll tick and at every relaunch, it follows the moves and lags the seconds after
/// one.
///
/// So they are required to AGREE. Agreement means both describe the same account, and either being
/// silent (nothing published yet; a home that matches no account) leaves the other to answer alone.
/// A disagreement is exactly the case where neither can be trusted, and it answers nil.
///
/// nil is not "not there": the caller reads it as "do not decide here", writes the request anyway,
/// and the supervisor settles it against the account the session is really on at that moment (its
/// `alreadyThere` branch consumes the request and restarts nothing).
func sessionAccountID(sessionKey: String, isThisSession: Bool, provider: Provider,
                      accounts: [Snapshot.Account],
                      dir: URL = supervisorStateDir,
                      environment: [String: String] = ProcessInfo.processInfo.environment)
    -> String? {
    let published = readSessionContext(pid: sessionKey, dir: dir)?.accountID
    guard isThisSession else { return published }
    let home = environment[provider.envKey] ?? defaultHome(provider)
    let fromEnvironment = accounts.first { $0.provider == provider.id && $0.launchHome == home }?.id
    guard let fromEnvironment else { return published }
    guard let published else { return fromEnvironment }
    return fromEnvironment == published ? fromEnvironment : nil
}

/// The session marker in this process's environment, or nil when there is none (or its supervisor
/// has died, which a marker inherited by something long-lived could outlive).
func liveSessionMarker(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    guard let value = env["TALLY_SUPERVISOR_PID"], let pid = pid_t(value),
          supervisorAlive(pid) else { return nil }
    return value
}

/// Whether the supervisor watching this session will act on a request at all, judged from the build
/// it stamped into the environment against the installed one - the same two values the status line's
/// supervision note compares (SupervisorRuntime.swift).
///
/// It exists because the failure it prevents is SILENT. A supervisor from a build without a given
/// feature registers, stamps its pid, and polls nothing for it: the request would be written, read
/// by nobody, and the session would sit as it was while the command reported success.
///
/// Named for the REQUEST rather than for the switch, because the question is about the supervisor
/// and not about the axis: `tally model` writes into a directory of its own and asks exactly this
/// before it does (ModelCommand.swift). A second copy would be a second answer to "is that
/// supervisor new enough".
enum RequestHonourability: Equatable {
    /// The supervisor is the current build and reads these requests.
    case honoured
    /// A different build, which replaces itself at the next idle moment (since 0.26.0) and reads the
    /// request when it comes back. Worth saying, because that wait is the whole delay.
    case afterSelfUpdate
    /// No version stamp at all: a supervisor too old to self-update, so nothing will ever read it.
    case tooOld
}

/// Read off the status line's own supervision note rather than comparing the two versions again
/// (SupervisorRuntime.swift): what "outdated" means is one rule, and a second copy of it here would
/// be free to drift into telling the user something the badge on their status line denies. Asked
/// only where a live session marker was found, so `steered` and `supervised` are true by
/// construction. `.ok` covers the case with no installed version to compare against (a standalone or
/// dev build of this CLI), which assumes it works rather than asserting a problem it cannot see.
func requestHonourability(supervisorVersion: String?, installedVersion: String?)
    -> RequestHonourability {
    switch supervisionStatus(steered: true, supervised: true, supervisorVersion: supervisorVersion,
                             installedVersion: installedVersion) {
    case .unknown: return .tooOld
    case .outdated: return .afterSelfUpdate
    case .ok, .notSteered, .notSupervised: return .honoured
    }
}

/// The same question asked of the live world, which is what every command that writes a request has
/// to ask before it writes one (`attemptSwitch`, `attemptModel`).
///
/// `marker` is the session marker the caller already read for the lookup. It is asked ONLY when the
/// session named ITSELF: the environment carries that session's supervisor build, and a session
/// found through the directory fallback carries nothing to compare, so there is no version there to
/// judge and the request is written on the assumption that it will be read.
func liveRequestHonourability(marker: String?) -> RequestHonourability {
    guard marker != nil else { return .honoured }
    return requestHonourability(
        supervisorVersion: ProcessInfo.processInfo.environment["TALLY_SUPERVISOR_VERSION"],
        installedVersion: supervisorBuildVersion())
}
