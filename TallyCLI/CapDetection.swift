import Foundation

// Noticing that this session has hit a cap, and noticing that it has stopped being capped.
//
// Split from Supervisor.swift for file size, and it is the right seam: what the loop needs back from
// this is one value (`pendingCap`), the decision is about the transcript rather than about accounts,
// and the account MOVE it eventually leads to is a separate block with its own gates
// (SupervisorRuntime.swift holds the pieces both use).
//
// Everything here runs BEFORE any relaunch path in the tick, and the order is load-bearing: a
// relaunch resets the watcher's `since`, so a cap event read after one would be filtered as old
// history and lost (2026-07-24).

/// Fold this tick's transcript evidence into the pending cap recovery: clear one the session has
/// recovered from, raise one for a cap it has just hit, and quarantine the account for the model
/// window that capped.
///
/// `quarantine` is the supervisor's own session-local record; the shared per-account file is written
/// alongside it so a session launching right now avoids the same wall.
///
/// `snapshotAccounts` is a closure because it is only paid for on the tick a cap actually lands: it
/// is the one snapshot read this path costs, and it has to happen while the evidence still exists
/// (the next refresh puts the window that capped back at 100%).
func observeCapHit(pendingCap: inout PendingCapRecovery?,
                   quarantine: inout [String: (model: String?, until: Date)],
                   watcher: inout TranscriptWatcher, account: Snapshot.Account,
                   primaryModel: String?, now: Date = Date(),
                   snapshotAccounts: () -> [Snapshot.Account] = { loadSnapshot().0?.accounts ?? [] }) {
    // The scan also refreshes the model-degradation signal the rescue and fallback blocks read, so
    // it runs on every tick rather than only while a cap is possible.
    let sawCap = watcher.sawCapHit()
    // The session came back on its own - a real assistant turn on the main chain, newer than the cap
    // (the account's window refilled, or the user waited the cooldown out) - so a later genuine cap
    // starts fresh. Unannounced: the cap badge disappearing is the news, and the turn that just
    // succeeded already told them.
    //
    // Or nobody typed and the window simply reset underneath the session, which that first arm can
    // never see: it needs an assistant turn, and an idle session produces none, so the badge hung
    // there naming an account that was back at 100%. The boundary it compares against was fixed when
    // the cap happened, so this reads no files at all (SupervisorRuntime.swift explains why it
    // cannot be recomputed here).
    if let pending = pendingCap,
       watcher.lastMainChainEventAt.map({ $0 > pending.cappedAt }) == true
           || capRecoveredByReset(pending, now: now) {
        pendingCap = nil
    }
    guard sawCap, pendingCap == nil else { return }
    // The cap's own instant, not the moment this 2s poll noticed it. The recovery boundary is
    // measured against this once and never recomputed, so the poll delay would otherwise be enough
    // to read a reset landing inside it as a stale stamp and strand the session with no reset path
    // at all (00:59:59 cap, 01:00:00 tick, 01:00:00 reset). Falls back to now for a cap event
    // carrying no timestamp.
    let cappedAt = watcher.capHitAt ?? now
    pendingCap = PendingCapRecovery(
        cappedAccountID: account.id, cappedAt: cappedAt, primaryModel: primaryModel,
        recoveryResetsAt: capRecoveryDeadline(accounts: snapshotAccounts(),
                                              cappedAccountID: account.id,
                                              primaryModel: primaryModel, cappedAt: cappedAt),
        nextRetry: .distantPast, reason: "")
    // Keep every session (this one and any launching now) off the account for the model window that
    // just capped until its snapshot catches up - a different model the account still serves is not
    // blocked.
    let until = now.addingTimeInterval(capQuarantineTTL)
    quarantine[account.id] = (model: primaryModel, until: until)
    quarantineAccount(account.id, model: primaryModel, until: until)
}
