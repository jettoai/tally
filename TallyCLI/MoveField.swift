import Foundation

// THE FIELD EVERY PROACTIVE MOVER PLAYS ON: this account as the snapshot reports it NOW, and the
// siblings a move could go to. Its own file because THREE movers share it - the idle rebalance, the
// turn-boundary move and the window repick - and the advisory knock reads it a fourth time to name
// where there is room. They differ in WHEN they fire and in nothing else about which siblings exist
// or which windows count, and a second copy of this narrowing is exactly how they would come to
// disagree.
//
// DELIBERATELY RESERVE-BLIND, which is the one thing to understand before adding a filter here.
// What this answers is "which accounts exist and could serve this model"; what a reserve answers is
// "which of them may Tally spend", and that is the gate one step later (`capHandoffTarget`, which
// all three movers share too). Filtering here instead would also hide a reserved account from the
// SENTENCE the knock writes, and the whole point of that sentence is to describe the fleet honestly.

/// The live picture any proactive move needs: this account as the snapshot reports it NOW, and the
/// field of siblings narrowed exactly as the cap handoff narrows it (this provider, eligible for the
/// model actually running, not the account we are on, nothing quarantined).
///
/// nil when the snapshot cannot answer: too old to trust, unreadable, or not naming this account at
/// all. Every caller reads that as "stay put", the same rule the cap handoff applies
/// (`CapAction.waitStale`) and for the same reason - moving a session on hours-old numbers is how a
/// session lands somewhere worse than it started.
///
/// SHARED WITH THE WINDOW REPICK (WindowRepick.swift) rather than copied there. The two movers
/// differ in WHEN they fire and in nothing else about the field: they must never come to disagree
/// about which siblings exist or which windows count, and a second copy of this narrowing is
/// exactly how they would.
///
/// - Parameter dir: where the cross-supervisor quarantine records live. A seam rather than a
///   constant because reading them is a real directory read that also DELETES the expired files
///   (`quarantineRecords`), so an assertion walking this path was writing to the machine's own
///   `~/.tally/quarantine` - and would go red for whatever a real cap had just recorded there.
func liveMoveField(provider: String, account: Snapshot.Account, primaryModel: String?,
                   quarantine: [String: (model: String?, until: Date)],
                   loaded: (Snapshot?, String?), now: Date, dir: URL = quarantineDir)
    -> (current: Snapshot.Account, candidates: [Snapshot.Account])? {
    let (snapshot, problem) = loaded
    guard problem == nil, let snapshot,
          let live = snapshot.accounts.first(where: { $0.id == account.id }) else { return nil }
    let excluded = quarantinedAccounts(forPrimary: primaryModel, sessionLocal: quarantine, now: now,
                                       dir: dir)
    return (live, snapshot.accounts.filter {
        $0.provider == provider && eligible($0, primaryModel: primaryModel)
            && $0.id != account.id && !excluded.contains($0.id)
    })
}
