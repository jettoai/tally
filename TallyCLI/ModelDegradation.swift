import Foundation

// The two answers to "this session is no longer running the model it was launched for", both read
// off the same signal: `watcher.lastModel`, the serving model of the newest real, main-chain,
// post-launch assistant event (TranscriptWatcher.swift).
//
// They are ordered, and only one can fire on a tick, because they say opposite things. The rescue
// keeps the model and changes the account: somewhere in the fleet is a flagship window with room,
// and the conversation belongs there. The fallback profile gives up on the model and stays put: no
// sibling can serve it, so accept the configured pairing instead of pretending. Trying the rescue
// first is what makes "flagship-first" true rather than a preference.
//
// Both are deliberately blind to a SAFEGUARD drift, which looks identical in the transcript and is
// not a quota problem at all: the API itself moved this conversation onto a fallback model, and no
// sibling account cures that. What that case wants is the declared depth put back on the model the
// API chose, which is SafeguardDrift.swift's job.

/// Move the conversation to a sibling whose flagship window still has real room, KEEPING the model
/// this session was launched for: the flagship-first response to a quota degradation. Not for
/// pinned sessions (a pin means "this account"), and under the same fuse as every automatic
/// recovery.
///
/// `primaryModel` is what THIS session is expected to run, which is not always the configured
/// default: a hand-typed `--model` outranks it, so a deliberate haiku session is never "rescued"
/// back to fable.
///
/// `snapshot` is injected for the reason the follow adoption's is (FollowAdoption.swift): this is
/// the one branch here that reads the fleet, and a decision that cannot be exercised without a home
/// directory is a decision whose gates are asserted in one direction only.
///
/// `steering` is the fleet's own answer to whether Tally may pick an account for a running session
/// (AutoSteering.swift). It sits beside the pin because it means the same thing here for a
/// different reason: this rescue's entire act is choosing a sibling, so a fleet set to observe only
/// has nothing left for it to do. The fallback profile below is untouched - that one changes the
/// model on the account the session is already on.
func applyDegradationRescue(plan: inout RelaunchPlan?, watcher: inout TranscriptWatcher,
                            driftActive: Bool, policy: LaunchPolicy, account: Snapshot.Account,
                            providerID: String, primaryModel: String?,
                            quarantine: [String: (model: String?, until: Date)],
                            steering: Bool, fuseAllows: Bool,
                            snapshot loadSnapshotting: () -> (Snapshot?, String?) = loadSnapshot) {
    guard plan == nil, !driftActive, let primary = primaryModel?.lowercased(),
          let actual = watcher.lastModel?.lowercased(),
          !actual.contains(primary), steering, policy.mode != "manual", fuseAllows,
          watcher.isQuiet() else { return }
    let (snapshot, _) = loadSnapshotting()
    // Account-switching only cures QUOTA degradation. If THIS account's flagship window still has
    // real room, the cause is something a sibling shares too (live case 2026-07-20: the session's
    // context outgrew the flagship's subscription tier - every account hits that same wall), so
    // switching would just churn the fuse. Skip; if quota IS the cause, the next poll's snapshot
    // shows this account dry and the rescue proceeds. Score the target against the EFFECTIVE
    // primary (a hand-typed --model outranks the configured default).
    let currentDry = (snapshot?.accounts
        .first { $0.id == account.id }?.modelRemaining).map { $0 <= 5 } ?? true
    let excluded = quarantinedAccounts(forPrimary: primaryModel, sessionLocal: quarantine)
    let rescue = !currentDry ? nil : snapshot?.accounts
        .filter { $0.provider == providerID
            && eligible($0, primaryModel: primaryModel)
            && $0.id != account.id && ($0.modelRemaining ?? 0) > 5
            && !excluded.contains($0.id) }
        .max {
            smartScore($0, primaryModel: primaryModel)
                < smartScore($1, primaryModel: primaryModel)
        }
    if let rescue {
        warn("\(actual) took over from \(primary) → moving to \(rescue.label) " +
             "to stay on \(primary) (\(pickReason(rescue, primaryModel: primaryModel)))")
        plan = RelaunchPlan(target: rescue, reason: "degraded", countsFuse: true)
    }
}

/// Accept the configured fallback: no sibling can serve the primary model, and a weaker model can
/// deserve a different depth and extra flags, so relaunch ONCE with the fallback pairing - same
/// account, same conversation. Deliberate configuration, so no fuse.
///
/// `applied` is held for the life of the SESSION rather than the child, which is why it comes in
/// as `inout` from outside the child loop: the profile is a one-shot, and the relaunch it asks for
/// must not hand it a fresh chance to fire.
func applyFallbackProfile(plan: inout RelaunchPlan?, applied: inout Bool,
                          watcher: inout TranscriptWatcher, driftActive: Bool,
                          policy: LaunchPolicy, account: Snapshot.Account,
                          primaryModel: String?) {
    guard plan == nil, !driftActive, !applied,
          let fallbackList = policy.fallbackModel,
          policy.fallbackEffort != nil || policy.fallbackArgs != nil,
          let actual = watcher.lastModel?.lowercased(),
          primaryModel.map({ !actual.contains($0.lowercased()) }) ?? true,
          let matched = fallbackList.split(separator: ",")
              .map({ $0.trimmingCharacters(in: .whitespaces).lowercased() })
              .first(where: { !$0.isEmpty && actual.contains($0) }),
          watcher.isQuiet() else { return }
    warn("model fell back to \(actual) → applying fallback profile")
    let extra = policy.fallbackArgs?.split(separator: " ").map(String.init) ?? []
    plan = RelaunchPlan(target: account, reason: "fallback", countsFuse: false,
                        model: matched, effort: policy.fallbackEffort, extraArgs: extra)
    applied = true
}
