import Foundation

// The account re-pick a `tally reload` restart carries for free, split out of reloadchecks.swift for
// file size. Called from `runReloadChecks`, which owns the tick fixtures these borrow.
//
// The reasoning: a reload restart is already terminating the child, so the one thing that normally
// makes the idle rebalance expensive - a restart it has to justify on its own - is already paid for.
// The DECISION stays the rebalance's (Rebalance.swift, unchanged, asked as a closure); what is
// asserted here is that reload asks it at the right moment and does the right thing with either
// answer, the tag included.

func runReloadRepickChecks(account tickAccount: Snapshot.Account,
                           watcher tickWatcher: inout TranscriptWatcher, t0 tickT0: Date) {

    // A restart is already being paid for, so the session may as well come back somewhere better
    // than a nearly-dry account. The decision itself is the idle rebalance's, unchanged and asked
    // as a closure; what is asserted here is that reload asks it at the right moment and does the
    // right thing with both answers.
    func reloadTick(repick: @escaping () -> Snapshot.Account?,
                    watcher: inout TranscriptWatcher, carryable: Bool = true,
                    request: ReloadRequest = ReloadRequest(epoch: 101, immediate: false),
                    keyboardIdle: @escaping (TimeInterval) -> Bool = { _ in true })
        -> (plan: RelaunchPlan?, asked: Bool) {
        var plan: RelaunchPlan?
        var epoch = 100
        var notice = ReloadWait()
        var asked = false
        applyReloadRequest(plan: &plan, epoch: &epoch, notice: &notice, account: tickAccount,
                           watcher: &watcher, childAge: 9999, keyboardIdle: keyboardIdle,
                           carryable: carryable, request: request,
                           repick: { asked = true; return repick() }, now: tickT0)
        return (plan, asked)
    }
    func elsewhere(_ id: String) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: 90,
                         sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                         modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
                         error: nil)
    }
    // Nothing to improve on: the account this session is already on is a healthy one, the rebalance
    // says so by answering nil, and the reload is the same same-account restart it has always been.
    // This is the zero-behaviour-change case, and it is the common one.
    let stays = reloadTick(repick: { nil }, watcher: &tickWatcher)
    check("a reload with nowhere better to go restarts on the same account",
          stays.plan?.target.id == "A")
    check("and is still tagged a reload", stays.plan?.reason == "reload")
    // Which is load-bearing, not cosmetic: a pending cap is carried across a relaunch for exactly
    // that tag, because a reload comes back on the same account and the cap is still this session's.
    check("so a pending cap recovery still rides across it",
          capCarriedAcrossRelaunch(PendingCapRecovery(
              cappedAccountID: "A", cappedAt: tickT0, primaryModel: "fable",
              recoveryResetsAt: nil, nextRetry: .distantPast, reason: ""),
              reason: stays.plan!.reason) != nil)
    // A nearly-dry account with a comfortable sibling: the move the rebalance would have made later,
    // made now, on a restart that was happening anyway.
    let moves = reloadTick(repick: { elsewhere("B") }, watcher: &tickWatcher)
    check("a reload off a dying account lands on the target the rebalance names",
          moves.plan?.target.id == "B")
    // Tagged for what it IS. Calling this a reload would hand the next child a cap belonging to the
    // account it just left.
    check("and it is tagged a rebalance, so the cap does not follow it onto the new account",
          moves.plan?.reason == "rebalance")
    check("nor does it carry one", capCarriedAcrossRelaunch(PendingCapRecovery(
              cappedAccountID: "A", cappedAt: tickT0, primaryModel: "fable",
              recoveryResetsAt: nil, nextRetry: .distantPast, reason: ""),
              reason: moves.plan!.reason) == nil)
    // An automatic cross-account move spends the recovery budget; a same-account restart never has.
    check("the move counts against the fuse", moves.plan?.countsFuse == true)
    check("while staying put still does not", stays.plan?.countsFuse == false)
    // The gates that make this safe (pinned, in use, no comfortable target, one claim per drought)
    // all live in `rebalanceMove` and are asserted where they are implemented. What reload owes them
    // is to ask ONCE, at the moment it restarts, and never on a tick that only queues: answering
    // takes the account's one claim for the drought, and a claim spent on a tick that then does
    // nothing leaves the account unable to move until its window resets.
    let queued = reloadTick(repick: { elsewhere("B") }, watcher: &tickWatcher,
                            keyboardIdle: { _ in false })
    check("a queued reload plans nothing", queued.plan == nil)
    check("and does not spend the drought's claim while it waits", !queued.asked)
    check("whereas the one that restarts does ask", moves.asked)
    // `--now` shortens reload's own idle bar; it does not change any of the above. The restart is
    // still happening, so aiming it is still free.
    let immediate = reloadTick(repick: { elsewhere("B") }, watcher: &tickWatcher,
                               request: ReloadRequest(epoch: 101, immediate: true))
    check("a --now reload aims its restart the same way", immediate.plan?.target.id == "B")

    // A session that was told to resume a conversation and whose transcript is not bound yet: a
    // `--continue` child that has not written a turn since it launched, still up long enough for a
    // reload to take it (`reloadQuiet` accepts the child's AGE in place of a transcript, which is
    // what puts this state in reach). Crossing accounts from here would come back BLANK -
    // `performHandoff` strips `--continue` on a move by design, because on the target account it
    // names a different conversation entirely - and there is no id to resume in its place.
    let blindDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-reload-unlocated-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: blindDir, withIntermediateDirectories: true)
    var blindWatcher = TranscriptWatcher(projectDir: blindDir, since: tickT0)
    check("the fixture really is a session with nothing bound to resume from",
          blindWatcher.file == nil)
    let unlocated = reloadTick(repick: { elsewhere("B") }, watcher: &blindWatcher, carryable: false)
    check("a reload with a conversation it cannot carry restarts where it is",
          unlocated.plan?.target.id == "A")
    check("and as a reload, so `--continue` survives the restart",
          unlocated.plan?.reason == "reload")
    // The claim is not spent, and not by a refusal after the fact: the rebalance is never ASKED, so
    // the account is still free to make this same move at its next quiet moment, once there is a
    // conversation to bring along.
    check("and the drought's claim is never even asked for", !unlocated.asked)
    check("nor is it charged to the fuse", unlocated.plan?.countsFuse == false)
    // The other half of the same rule: a session that never asked to resume anything has nothing to
    // lose by moving, transcript or no transcript. Same unbound watcher, opposite answer - which is
    // the point, because the decision is about what the child was LAUNCHED to do, not about whether
    // a file happens to exist yet. Gating this one too would have stranded every brand new session
    // on a dying account, to protect a conversation that does not exist.
    let fresh = reloadTick(repick: { elsewhere("B") }, watcher: &blindWatcher, carryable: true)
    check("a brand new session moves even with nothing bound", fresh.plan?.target.id == "B")
    check("and it is a rebalance like any other move", fresh.plan?.reason == "rebalance")
    try? FileManager.default.removeItem(at: blindDir)

    // The wiring itself is not reachable in a test (it needs a child and a snapshot), so the source
    // carries it, the technique the fuse carry and the rebalance placement already use.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the re-pick checks", !loop.isEmpty)
    check("the tick offers the reload a re-pick", loop.contains("repick: {"))
    check("and it is the idle rebalance's own decision, not a second copy of it",
          loop.contains("repick: {\n                                   rebalanceMove("))
    // `isQuiet: true` reads like a bypass and is not one: the closure's only caller is the branch
    // reload reaches after its OWN idle gate said yes. Asserted so that if the closure is ever moved
    // somewhere that gate has not run, this line has to be looked at again.
    check("it does not re-ask an idleness question reload has already answered",
          loop.contains("isQuiet: true, carryable: carryable"))
    // The value is READ before the call and captured, never read from inside the closure: `watcher`
    // is passed inout to that same call, so touching it from within is a simultaneous access, which
    // compiles without a word and traps at runtime (measured 2026-08-02). A source check because the
    // natural-looking version is the broken one, and nothing else would catch it before a user did.
    check("and it captures the carryable flag instead of reading the watcher under inout",
          loop.contains("let carryable = carryableSession("))
    if let capture = loop.range(of: "let carryable = carryableSession("),
       let call = loop.range(of: "applyReloadRequest(") {
        check("captured before the call that borrows the watcher",
              capture.upperBound < call.lowerBound)
        let closure = loop[call.lowerBound...].prefix(900)
        check("and the closure itself never touches the watcher", !closure.contains("watcher.file"))
    } else {
        check("the capture and the call were both found in the tick", false)
    }
}
