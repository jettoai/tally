import Foundation

// A Codex window whose account has run out of quota moves itself to a sibling Codex account (B-2096).
//
// It decides nothing about HOW a window moves: it produces a `CodexHandoffPlan`, the same value
// `tally account <codex account> --session <pid>` produces, and the one gate, kill and exec path of
// CodexHandoff.swift / CodexSupervisor.swift carries it out. So an automatic move waits for the same
// turn boundary a manual one does (answer complete, nothing pending on a person, composer empty,
// nobody typing).
//
// TWO SIGNALS, either one is a wall:
//   rollout  the window's own newest `rate_limits` reading (`codexRolloutWall`). Measured 2026-10-18
//            on 8 recorded 100% readings: the turn that crosses 100% still finishes with
//            `task_complete`, and codex-rs 0.163 emits `TurnComplete` after a usage-limit error too
//            (core/src/tasks/mod.rs `on_task_finished`), so the boundary the gate waits for arrives.
//   snapshot the app's reading of THIS window's account says no headroom. It covers a window whose
//            account another window drained: the rejected request leaves no mark in this rollout.
// Both fail toward "not a wall": an unreadable, stale or failed reading never moves anything.
//
// Codex has no flagship-model window and no session pin, so unlike a Claude cap there is no
// stay-in-place branch; the 5-hour early start (EarlyStart.swift) is Claude-only and not involved.

/// A wall that is redeemed within this long of landing is not worth a restart: the app redeems a banked
/// reset a minute after the reading arrives (measured 2026-09-30: 100% at 13:17:03, 0% at 13:18:12).
let codexWallRedeemHold: TimeInterval = 180
/// How often the snapshot file is re-read, and how often a held decision is re-evaluated.
let codexWallPoll: TimeInterval = 30
/// Two automatic moves in `capResumeBudgetWindow` is the most a pair of accounts can honestly need
/// (there, and back once the other is redeemed); a third is oscillation.
let codexWallMaxMoves = 2
/// Carries the resume line across the exec. A request file cannot: the new supervisor seeds its served
/// epoch from whatever is pending at start (`SessionInputState.init`) and would swallow it.
let codexWallResumeEnv = "TALLY_CODEX_WALL_RESUME"
/// Carries the fuse across the exec that replaces the supervisor, read and removed at start-up.
let codexWallFuseEnv = "TALLY_CODEX_AUTO_HANDOFFS"

/// What the supervisor remembers between ticks.
struct CodexWallWatch {
    var wallAt: Date?
    var source = "rollout"
    var snapshot: Snapshot?
    /// The newest rollout reading a roomier fresh snapshot has already overruled (a redeem or a reset
    /// the rollout has not caught up with); it is never a wall again, only a newer reading can be.
    var settledReading: Date?
    var nextSnapshotRead = Date.distantPast
    var nextEvaluation = Date.distantPast
}

struct CodexWallVerdict: Equatable {
    /// The window's account is out of quota right now.
    var wall = false
    var plan: CodexHandoffPlan?
    /// Why a wall has not produced a move yet; a short word for the audit line.
    var held: String?
}

/// The app's reading of one account says it cannot serve, and says so about a moment that is not
/// over: a failed poll republishes the last good numbers, so only a row that is fresh, error-free and
/// stamped counts.
func codexSnapshotWall(_ account: Snapshot.Account?) -> Bool {
    guard let account, account.error == nil, !account.isStale, account.lastRefreshFailed != true,
          account.refreshedAt != nil,
          account.sessionRemaining != nil || account.weeklyRemaining != nil || account.modelRemaining != nil
    else { return false }
    return headroom(account) <= 0
}

/// One tick. `readSnapshot` answers nil when the file is missing, unreadable or older than the app
/// publishes (a hand-off to an account chosen from numbers nobody refreshed is a guess).
func codexWallPlan(watch: inout CodexWallWatch, reading: CodexRateReading?, accountID: String, pid: String,
                   fuse: inout RecoveryFuse, reserves: @autoclosure () -> AccountReserves, now: Date = Date(),
                   fallbackDirectory: @autoclosure () -> String?, readSnapshot: () -> Snapshot?,
                   dir: URL = supervisorStateDir, quarantineDir: URL = quarantineDir) -> CodexWallVerdict {
    if now >= watch.nextSnapshotRead {
        watch.snapshot = readSnapshot()
        watch.nextSnapshotRead = now.addingTimeInterval(codexWallPoll)
    }
    let current = watch.snapshot?.accounts.first { $0.id == accountID && $0.provider == "codex" }
    var byRollout = codexRolloutWall(reading, now: now) && reading.map { $0.at > (watch.settledReading ?? .distantPast) } == true
    // A fresh, roomy reading taken after the rollout's own says a redeem or a reset landed that the
    // rollout has not recorded yet.
    if byRollout, let reading, let current, current.error == nil, !current.isStale, current.lastRefreshFailed != true,
       let refreshed = current.refreshedAt, refreshed > reading.at, headroom(current) > 0 {
        watch.settledReading = reading.at
        byRollout = false
    }
    let walled = byRollout || codexSnapshotWall(current)
    guard walled else {
        watch = CodexWallWatch(snapshot: watch.snapshot, settledReading: watch.settledReading,
                               nextSnapshotRead: watch.nextSnapshotRead)
        return CodexWallVerdict()
    }
    if watch.wallAt == nil {
        watch.wallAt = byRollout ? reading?.at ?? now : now
        watch.source = byRollout ? "rollout" : "snapshot"
        // The app's snapshot lags the real wall: keep a launch that starts right now off this account.
        quarantineAccount(accountID, model: nil, until: now.addingTimeInterval(capQuarantineTTL), dir: quarantineDir)
    }
    var verdict = CodexWallVerdict(wall: true)
    guard now >= watch.nextEvaluation else { return verdict }
    func held(_ reason: String) -> CodexWallVerdict {
        watch.nextEvaluation = now.addingTimeInterval(codexWallPoll)
        verdict.held = reason
        return verdict
    }
    guard let snapshot = watch.snapshot else { return held("no-snapshot") }
    if let current, (current.resetCreditsAvailable ?? 0) > 0, !["used", "notSupported"].contains(current.resetState ?? ""),
       now < (watch.wallAt ?? now).addingTimeInterval(codexWallRedeemHold) {
        return held("redeem")
    }
    guard fuse.allows(now: now) else { return held("fuse") }
    guard let sourceHome = SessionMonitoring.read(pid: pid, dir: dir)?.home else { return held("no-conversation") }
    let excluded = quarantinedAccounts(forPrimary: nil, now: now, dir: quarantineDir)
    let candidates = snapshot.accounts.filter {
        $0.provider == "codex" && $0.id != accountID && eligible($0) && !excluded.contains($0.id)
            && $0.launchHome.map { codexSharesHistory(sourceHome: sourceHome, targetHome: $0) } == true
    }
    guard !candidates.isEmpty else { return held("no-target") }
    guard let target = capHandoffPick(candidates, primaryModel: nil, reserves: reserves(), now: now),
          let targetHome = target.launchHome else { return held("reserve") }
    switch codexHandoffSource(pid: pid, targetHome: targetHome, fallbackDirectory: fallbackDirectory(), dir: dir) {
    case .refused: return held("source")
    case .ready(let thread, let directory):
        if codexHandoffOtherWriter(thread: thread, pid: pid, dir: dir) != nil { return held("other-writer") }
        watch.nextEvaluation = now.addingTimeInterval(codexWallPoll)
        // `spendReserve` stays false: a move never crosses a reserve (the pick above already kept it).
        verdict.plan = CodexHandoffPlan(
            threadID: thread, directory: directory, targetHome: targetHome, spendReserve: false,
            wall: CodexWallMove(source: watch.source, fromID: accountID, toID: target.id,
                                fromName: current.map { quotaKnockName($0) } ?? accountID, toName: quotaKnockName(target),
                                resumeLine: current.map { capResumeMessage(from: $0, to: target) }))
        return verdict
    }
}

/// The line typed into the moved window, only when the wall cut a turn short. A turn that crossed
/// 100% and finished has nothing to resume, and a line there would set the model working unasked.
/// The two-moves-per-two-hours fuse bounds how often this can recur.
func codexWallResumeLine(_ move: CodexWallMove, turnFailed: Bool) -> String? {
    turnFailed ? move.resumeLine : nil
}

/// The resume line the previous image carried, accepted only in the exact shape this file writes
/// (the cap resume's own marker, inside the input channel's byte limit): the variable is the user's
/// environment too, and anything else in it is not ours to type.
func codexWallCarriedResume(_ raw: String?) -> String? {
    guard let raw, raw.hasPrefix(capResumeMarker), raw.utf8.count <= sessionInputMaxBytes else { return nil }
    return raw
}

/// The line left in the terminal as the old window ends and before the new one draws.
func codexWallNotice(_ move: CodexWallMove) -> String {
    "\(move.fromName) hit its weekly usage limit, moving this Codex conversation to \(move.toName)"
}

/// The `input.log` line for a move the supervisor chose itself, and the same words for a hold.
func codexWallAuditLine(pid: String, result: String, move: CodexWallMove?, held: String? = nil,
                        now: Date = Date()) -> String {
    let detail = move.map { " source=\($0.source) from=\($0.fromID) to=\($0.toID)" } ?? ""
    return "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=codex-handoff result=\(result) "
        + "origin=wall\(detail)\(held.map { " reason=\($0)" } ?? "")\n"
}
