import Foundation

// `tally reload --self`: restart ONLY the session this command runs in, on the same model and the
// same account, once the current turn ends. The fleet-wide `tally reload` (Reload.swift) is one
// file every supervisor reads; this is the same request, in the same format, addressed to one
// supervisor the way `tally model` addresses one (ModelRequest.swift): a file per supervisor pid.
//
// NOTHING ABOUT THE DECISION IS NEW. The supervisor folds this file and the fleet-wide one into the
// one request a tick acts on (`effectiveReloadRequest`), and `applyReloadRequest` decides about
// that exactly as it always has: the same served stamp, the same fold into a relaunch already
// planned, the same stand-down restore, and the same "reload" tag that the restart wake and the cap
// carry read. What this file adds is the address and two rules about the fold.

/// One request file per supervised session, named for the supervisor pid that reads it. A directory
/// of its own rather than a line in the fleet-wide file: that file holds one stamp for every
/// session, so a stamp addressed to one session there would restart all of them.
let reloadSelfDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/reload-self")

func reloadSelfFile(sessionKey: String, dir: URL = reloadSelfDir) -> URL {
    dir.appendingPathComponent(sessionKey)
}

/// The one request a tick acts on, folded from the fleet-wide file and this session's own.
struct EffectiveReload: Equatable {
    /// What `applyReloadRequest` is handed: nil only when neither file exists.
    let request: ReloadRequest?
    /// This session's own request is among the pending ones.
    let ownPending: Bool

    /// Whether the restart may carry the session to another account. Never while this session's
    /// own request is pending: `--self` promises the same account, and a restart that moved would
    /// be tagged a rebalance, which the restart wake and the cap carry read as something else.
    func carryable(_ base: Bool) -> Bool { base && !ownPending }
}

/// Pure. Both stamps are seconds and share ONE served stamp (`reloadEpoch`, Supervisor.swift), so a
/// restart for either satisfies every request older than it: the child that comes back already runs
/// whatever configuration the older request was about.
///
/// Nothing pending: whichever file exists is handed back unchanged, so the decision reads it as
/// already served and clears the badge, exactly as it did with one file. Something pending: the
/// newest stamp, the short bar if any pending request asked for it (the own request always does),
/// and `ownPending` when this session's own request is one of them.
func effectiveReloadRequest(fleet: ReloadRequest?, own: ReloadRequest?,
                            served: Int) -> EffectiveReload {
    let pending = [fleet, own].compactMap { $0 }.filter { $0.epoch > served }
    guard let newest = pending.map(\.epoch).max() else {
        return EffectiveReload(request: fleet ?? own, ownPending: false)
    }
    return EffectiveReload(
        request: ReloadRequest(epoch: newest, immediate: pending.contains { $0.immediate }),
        ownPending: own.map { $0.epoch > served } ?? false)
}

// MARK: - CLI

/// What asking for it came to: one sentence that stands alone, and anything worth adding to it.
struct ReloadSelfAttempt: Equatable {
    let queued: Bool
    let message: String
    var notes: [String] = []

    var exitCode: Int32 { queued ? 0 : 1 }

    static func refusal(_ message: String) -> ReloadSelfAttempt {
        ReloadSelfAttempt(queued: false, message: message)
    }
}

/// Find this session, check that its supervisor can read the request, and write it. Everything the
/// command does except print, with every reading of the live machine injectable for the tests.
///
/// ONLY THE SESSION MARKER ADDRESSES IT, unlike `tally model`, which falls back to the one supervisor
/// in the working directory. "--self" means the session this command runs in; a shell outside every
/// session that happens to sit in a project directory would otherwise restart a session it is not
/// part of.
func attemptReloadSelf(marker: String? = liveSessionMarker(),
                       stateDir: URL = supervisorStateDir,
                       dir: URL = reloadSelfDir,
                       honourability: (String) -> RequestHonourability = {
                           liveRequestHonourability(marker: $0)
                       },
                       now: Date = Date()) -> ReloadSelfAttempt {
    guard let sessionKey = marker else {
        return .refusal("this is not running inside a supervised session, so there is no session "
            + "here to restart: it was launched bare, with --no-handoff, or with an --account pin. "
            + "Nothing was queued. `tally reload` restarts every supervised session instead.")
    }
    if let refusal = sessionControlRefusal(pid: sessionKey, dir: stateDir) {
        return .refusal(refusal)
    }
    let honour = honourability(sessionKey)
    if honour == .tooOld {
        return .refusal("this session's supervisor predates `tally reload --self` and would never "
            + "read the request, so nothing was queued. Restart this session once (exit, then "
            + "launch again with `tally claude`) and it works from then on.")
    }
    sweepDeadSessionRequests(dir: dir)
    let file = reloadSelfFile(sessionKey: sessionKey, dir: dir)
    do {
        // Always the short bar, the 5s quiet gap `tally model` waits for, so the restart lands as
        // soon as the turn that ran this has ended.
        try writeReloadRequest(now, immediate: true, to: file)
    } catch {
        return .refusal("cannot write \(file.path): \(error.localizedDescription)")
    }
    var attempt = ReloadSelfAttempt(
        queued: true,
        message: "this session restarts once the current turn ends and it has been quiet for 5s: "
            + "same conversation, same model, same account. Other sessions are left alone")
    if honour == .afterSelfUpdate {
        attempt.notes.append("this session runs a supervisor from another build: it replaces "
            + "itself with the installed one at its next idle moment, and that replacement is "
            + "the restart")
    }
    return attempt
}

/// `tally reload --self [--now]`. `--now` is accepted and changes nothing: this request always uses
/// the short bar.
func runReloadSelf(args: [String]) -> Int32 {
    if let stray = args.first(where: { $0 != "--self" && $0 != "--now" }) {
        warn("unknown argument \(stray) - usage: tally reload [--now] | tally reload --self")
        return 2
    }
    let attempt = attemptReloadSelf()
    if attempt.queued { print(attempt.message) } else { warn(attempt.message) }
    for note in attempt.notes { warn(note) }
    return attempt.exitCode
}
