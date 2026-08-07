import Foundation

// How a `tally model` reaches ONE running session, and what that session then remembers about it.
// The decision a poll tick makes is next door in SessionModel.swift, the command that writes a
// request is in ModelCommand.swift; this side is the format and the state, split out for the same
// reason SwitchRequest.swift is split from SessionSwitch.swift - it is what the CLI, the supervisor
// and the tests all have to agree on.
//
// ADDRESSING IS NOT DUPLICATED. Which session a command belongs to (`liveSessionMarker`,
// `sessionLookup`, `supervisorsInDirectory`), whether that session's supervisor is new enough to
// read anything (`requestHonourability`), and the sweep of requests addressed to dead pids
// (`sweepDeadSessionRequests`) are all in SwitchRequest.swift and are all asked here unchanged. They
// are about the SESSION, not about the axis, and a second copy of the rules would be a second set of
// answers to "which conversation is this" - the one question both commands must never differ on.
// What is new here is only what a request SAYS.

// MARK: - The request file

/// One request file per supervised session, named for the supervisor pid that will read it. A
/// directory of its own beside the switch requests, rather than a second field in those: the two
/// commands are independent (a session can be moving accounts and changing model in the same
/// minute), and one file would make either one silently overwrite the other's pending instruction.
let modelRequestDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/model")

/// The model name that means "no model": `tally model --auto`, asking the supervisor to drop the
/// pair a previous `tally model` pinned and go back to this project's profile and the fleet default.
///
/// The same spelling `switchAutoRequest` uses on the account axis, and for the same reason stated
/// there: the flag the user types and the token the file carries are ONE string, so there is no
/// second mapping to keep in step. It cannot collide with a real model either - `isLaunchAxisValue`
/// refuses anything starting with a dash, which is what the parser below requires of a real one.
let modelAutoRequest = "--auto"

/// A parsed model request: when it was made, and the pair it asks for. (`SessionModelPin`, the pair
/// itself, lives in RelaunchPlan.swift: it is consumed by the relaunch rewrite, which is compiled by
/// suites that have no business knowing how a request file is parsed.)
struct ModelRequest: Equatable {
    /// MILLISECONDS since the unix epoch, like the switch stamp and unlike the reload one. The
    /// supervisor acts only on a stamp strictly newer than the one it has served, and these are
    /// typed by hand INSIDE the session they change: "opus xhigh" and, on second thoughts, "opus
    /// high" a moment later is one sequence a person really performs, and at second resolution the
    /// second one reads as already served and vanishes silently.
    let epoch: Int
    /// The model to pin, or `modelAutoRequest` to release. Passed through as written: model names
    /// are open (`us.anthropic.claude-opus-4:1`), so there is nothing to resolve them against.
    let model: String
    /// The effort to pin alongside it, or nil to leave the effort axis where it is. Two axes with
    /// one request because they are one instruction ("run this conversation like THIS"), and
    /// because a relaunch carries both or neither anyway.
    let effort: String?

    /// This request releases the pin rather than naming something to run.
    var isRelease: Bool { model == modelAutoRequest }

    /// What the session is pinned to once this request is served. Empty for a release, which is what
    /// "follow the project profile and the fleet default again" is stored as.
    var pin: SessionModelPin {
        isRelease ? SessionModelPin() : SessionModelPin(model: model, effort: effort)
    }
}

/// Parse the file body: the stamp on line 1, the model on line 2, the effort on line 3 (an empty
/// line meaning "leave the effort alone"). Pure, so the format is testable without a home directory.
///
/// Anything unparseable is nil - no request - rather than a partial one, the rule the switch request
/// follows for a truncated write. It goes further on one point: both axes are CHECKED here as well
/// as at the command that wrote them (`isLaunchAxisValue`, and the closed enumeration for effort),
/// because this file is the one thing between a shell and a launch. A bad effort is not a cosmetic
/// problem: `claude --effort nonsense` exits immediately, so a request naming one would kill the
/// child and respawn it into the same failure on every tick. Reading it as no request at all leaves
/// the session exactly where it was.
func parseModelRequest(_ raw: String) -> ModelRequest? {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let epoch = lines.first.flatMap({ Int($0) }),
          let model = lines.dropFirst().first, !model.isEmpty,
          model == modelAutoRequest || isLaunchAxisValue(model) else { return nil }
    var effort: String?
    if let line = lines.dropFirst(2).first, !line.isEmpty {
        guard isLaunchAxisValue(line), isClaudeEffortName(line) else { return nil }
        effort = line
    }
    // A release carrying an effort is a contradiction, not a half-instruction: `--auto` hands both
    // axes back at once, so the only honest reading of the pair is to refuse it.
    guard model != modelAutoRequest || effort == nil else { return nil }
    return ModelRequest(epoch: epoch, model: model, effort: effort)
}

func modelRequestFile(sessionKey: String, dir: URL = modelRequestDir) -> URL {
    dir.appendingPathComponent(sessionKey)
}

/// This session's pending request, or nil when there is none (or it cannot be read).
func readModelRequest(sessionKey: String, dir: URL = modelRequestDir) -> ModelRequest? {
    guard let raw = try? String(contentsOf: modelRequestFile(sessionKey: sessionKey, dir: dir),
                                encoding: .utf8) else { return nil }
    return parseModelRequest(raw)
}

/// Stamp a request for one session. Atomic (Foundation writes temp + rename), so a supervisor
/// polling mid-write reads either the previous request or this one, never half of either.
func writeModelRequest(model: String, effort: String?, sessionKey: String, now: Date = Date(),
                       dir: URL = modelRequestDir) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "\(Int(now.timeIntervalSince1970 * 1000))\n\(model)\n\(effort ?? "")\n"
        .write(to: modelRequestFile(sessionKey: sessionKey, dir: dir), atomically: true,
               encoding: .utf8)
}

/// The request is served: unlink it. The served stamp in memory is what makes the decision
/// idempotent; this only keeps the directory from collecting husks.
func clearModelRequest(sessionKey: String, dir: URL = modelRequestDir) {
    try? FileManager.default.removeItem(at: modelRequestFile(sessionKey: sessionKey, dir: dir))
}

// MARK: - What the session carries between ticks

/// What the supervisor remembers about the model and effort its user asked this session to run.
/// Held across relaunches, like the recovery fuse, the quarantine and the account pin.
///
/// STICKY FOR THE SESSION, and that is the whole point of the command: `--model` on the launch line
/// is decided once and can only be changed by ending the conversation, while the fleet default is
/// followed by every session at once. This is the missing third scope - "run THIS conversation on
/// that pair, and keep doing it" - and it outranks the project profile and the fleet default for as
/// long as the session lasts, exactly as a `tally switch` pin outranks them on the account axis.
struct SessionModelState {
    /// This session's address: the supervisor's own pid, the key the request file is named for.
    let sessionKey: String
    /// The newest request stamp this supervisor has served.
    var servedEpoch: Int
    /// The pair this session is pinned to, empty when it follows the layers below (where every
    /// session starts, and where `tally model --auto` puts it back).
    var pin: SessionModelPin
    /// The `/model` event this session has already acted on (SessionModel.swift).
    ///
    /// Without it the adoption is not a decision but a STANDING RULE: `lastModelCommandAt` lives as
    /// long as the child, so every later disagreement between the serving model and the pin still
    /// satisfied "a /model happened, and the observation is newer than it" - including a genuine
    /// quota fallback, which was then adopted as though the user had asked for it. The degradation
    /// rescue would never fire again for the rest of that child (caught in review of c914b41).
    ///
    /// The same shape `servedEpoch` above has, and for the same reason: an instruction is served
    /// once, and the next one has to be NEWER. Not carried across the self-update exec, unlike the
    /// pin: that exec starts a new child, and the new watcher's `since` already filters out every
    /// `/model` from before it.
    var servedModelCommandAt: Date?
    /// Why a request is being held rather than served, for the status line's badge; nil when
    /// nothing is being held. Re-derived every tick from live state, like every other badge
    /// (PendingNotice.swift), so it disappears the moment the reason does.
    var waiting: PendingBadge?
    /// That this session's `/model` choice was taken as its pin - NEWS rather than a state, like the
    /// cancelled switch one axis over (`ManualMoveState.cancelled`), and held for the same reason:
    /// the thing it describes is finished by the time it is read, so nothing re-derives it.
    ///
    /// It is on this track at all because the adoption is the ONE model-axis event that plans no
    /// relaunch (SessionModel.swift says why). Every other message the supervisor speaks out loud
    /// precedes a tear-down, so stderr lands on a terminal that is about to be redrawn from
    /// scratch; this one landed in the middle of a live TUI's input box and pushed the prompt around
    /// it (owner screenshot, 2026-08-07). The rule was already written down in PendingNotice.swift -
    /// "is the child about to die?" - and this was the one adoption that is not.
    var adopted: PendingBadge?
    /// When that news was raised, so it can stop being news. nil whenever `adopted` is.
    var adoptedAt: Date?

    /// The one badge the status line gets from this session's model axis: a live wait outranks old
    /// news, because it is the thing that is still true (the account axis ranks its two the same
    /// way, `ManualMoveState.badge`).
    var badge: PendingBadge? { waiting ?? adopted }

    /// The adoption notice has been READ: the user has typed since it was raised.
    ///
    /// THE USER, not the session, and not a timer - both for the reasons `expireCancellation`
    /// states one axis over. The adoption happens INSIDE a turn (the `/model` picker is followed by
    /// the answer it applies to), so "an assistant event happened since" is true seconds later and
    /// would take the notice down before anyone saw it; a timer expires unread on a session nobody
    /// is watching and lingers on one being worked in.
    mutating func expireAdoption(lastUserTurnAt: Date?) {
        guard let adoptedAt, let lastUserTurnAt, lastUserTurnAt > adoptedAt else { return }
        adopted = nil
        self.adoptedAt = nil
    }

    /// Pick the adoption notice back up off disk, which is how it survives a self-update.
    ///
    /// The exec keeps the pid and starts this state from nothing, so a notice the replaced image had
    /// just raised exists only in `<pid>.notice` - and the seeded writer's first honest "nothing is
    /// pending" would unlink it. The file carries WHEN it was raised (`since`), so the expiry still
    /// measures from the turn that confirmed the choice rather than from the upgrade.
    ///
    /// A whitelist by kind, like `adoptCancellation`: a live wait is not news and is re-derived
    /// within a tick or two of the new image starting, so adopting one would pick up a value that is
    /// about to be recomputed - or a stale one if its condition has since cleared. No legacy arm
    /// here, unlike the cancellation's: this notice has carried its kind since the day it existed.
    mutating func adoptAdoption(_ notice: PendingNotice?) {
        guard let notice, notice.kind == modelAdoptionNoticeKind else { return }
        adopted = PendingBadge(notice.badge, detail: notice.detail, kind: modelAdoptionNoticeKind)
        adoptedAt = notice.since
    }

    /// Whether this session's own pin is in force, which is the one question the rest of the loop
    /// asks: while it is, the launch-default follow stands down (SessionModel.swift).
    var isPinned: Bool { !pin.isEmpty }

    /// `servedEpoch` defaults to whatever is pending right now, so a request written before this
    /// supervisor existed is never replayed (the file is addressed by pid, and pids come round
    /// again). A test supplies it directly, and so does the ONE caller for which that default is
    /// wrong: a self-update exec keeps the pid and IS the same session, so a request written moments
    /// before it was written for this conversation and would be swallowed by the seed (`resumed`,
    /// Supervisor.swift). `pin` is likewise handed over across that exec
    /// (`--session-model`, ResuperviseContract.swift): it is a promise about the user's SESSION
    /// rather than about this process, and a new image that started without it would undo by itself
    /// an instruction the user gave by hand.
    init(sessionKey: String, servedEpoch: Int? = nil, pin: SessionModelPin = SessionModelPin(),
         dir: URL = modelRequestDir) {
        self.sessionKey = sessionKey
        self.servedEpoch = servedEpoch
            ?? (readModelRequest(sessionKey: sessionKey, dir: dir)?.epoch ?? 0)
        self.pin = pin
    }
}

/// The bookkeeping a PLANNED model change owes, carried from the decision to the execution point and
/// written only once the relaunch is certain.
///
/// Recording it while planning is what the unresolved-fork hold turns into a lost request: the tick
/// stands the relaunch down, and a stamp already marked served makes every later tick read the
/// request as one it has handled (StandDown.swift, where a `tally reload` proved it). Nothing here
/// is undone on a stand-down because nothing has been written yet.
struct PendingModelConsumption {
    let epoch: Int
    /// Where the pin stands once this request has been served: the pair it named, or the empty pin
    /// for an `--auto` that released it.
    let pin: SessionModelPin
    let dir: URL

    /// The file is unlinked only when it still holds the request that was SERVED. Between planning
    /// and here the child is terminated, and a second `tally model` typed in that window overwrites
    /// the same path with a newer stamp: an unconditional unlink would delete an instruction nobody
    /// has carried out, and the millisecond stamps exist precisely so that two changes in quick
    /// succession are two changes. A newer stamp left on disk fires on the next tick, because
    /// `servedEpoch` records the epoch this consumption served rather than "whatever is pending".
    func commit(_ state: inout SessionModelState) {
        state.servedEpoch = epoch
        state.pin = pin
        state.waiting = nil
        if readModelRequest(sessionKey: state.sessionKey, dir: dir)?.epoch == epoch {
            clearModelRequest(sessionKey: state.sessionKey, dir: dir)
        }
    }
}
