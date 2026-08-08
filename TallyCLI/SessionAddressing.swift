import Foundation

// WHICH SESSION A COMMAND BELONGS TO. One question, one answer, asked by every surface that acts on
// a running conversation: `tally account` and `tally model` typed in a shell, the prompt hooks that
// answer `/tally-account` and `/tally-model` without waking a model, the MCP server behind the
// native picker, and the status line reporting which transcript it just drew for.
//
// Split from SwitchRequest.swift, which keeps the thing it addresses: the request FILE a switch
// writes, the documents a supervisor publishes beside it, and whether that supervisor is new enough
// to read one. The seam is the one that file's own header always drew - "the request file it writes,
// and the two ways a session can be identified" - and it is here because those two halves are read
// by different callers for different reasons, and because together they had outgrown the size a file
// in this repo may be.
//
// THE RULE, in one sentence, because it has now been got wrong in three different places: a session
// marker is inherited by everything a session ever starts, so it is a perfect answer for a process
// that DESCENDS from the conversation and a trap for one that was merely told about a prompt. What
// separates them is corroboration, and what corroboration weighs is below.

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
