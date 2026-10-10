import Foundation

// The badge-side mirror of the launcher pick, split out of LaunchPolicyStore.swift (line limit).
extension LaunchPolicyStore {
    /// The badge the panel shows. Two steps, exactly as the launcher picks (`launchPick` on the
    /// CLI side): the cap quarantine is applied first, and when it empties the field the
    /// unfiltered pick is shown rather than no badge at all, because that is the account a launch
    /// would still land on. The app had no notion of quarantine until 2026-07-26; on 2026-07-25
    /// the badge sat on a quarantined account and its reader concluded the picker was broken.
    ///
    /// `reserves` is percentage points held back per ACCOUNT ID, which is the shape this side of the
    /// contract holds: the CLI joins the state file's homes onto the snapshot's accounts, and the
    /// panel already knows which card is which (`PersonalAccount.reserves`). Empty is the ordinary
    /// answer and computes exactly what this function computed before the feature existed. A launch
    /// this badge predicts is Tally's OWN choice, so it always weighs them - the paths a person names
    /// an account on (a pin, `tally claude --account X`) do not come through here at all, so the
    /// panel does not show a pin the launcher would refuse under its line (named blind spot).
    ///
    /// The badge applies the launcher's LOAD GATE too (jettoai/tally#4): a thin account already
    /// carrying `clearanceMaxSessions` live sessions is passed over while a sibling can take the
    /// launch, counted from the same live-session read the clearance lane uses.
    func autoPickID(providerID: String, accounts: [AccountUsage], launchable: Set<String>,
                    reserves: [String: Double] = [:], now: Date = Date()) -> String? {
        autoPickID(providerID: providerID, accounts: accounts, launchable: launchable,
                   reserves: reserves, occupancy: liveSessionsNow(now: now), now: now)
    }

    /// The same pick with the live session counts handed in. nil (not read yet) reads every
    /// clearance account as full, so the badge never names one it cannot vouch for.
    func autoPickID(providerID: String, accounts: [AccountUsage], launchable: Set<String>,
                    reserves: [String: Double] = [:], occupancy: [String: Int]?,
                    now: Date = Date()) -> String? {
        autoPickID(providerID: providerID, accounts: accounts, launchable: launchable,
                   reserves: reserves,
                   quarantined: quarantinedNow(primaryModel: policy(providerID).model, now: now),
                   occupancy: occupancy, now: now)
    }

    /// The quarantine step with the quarantine handed in, mirroring `launchPick`: when it empties
    /// the field the retry only ranks, so the clearance lane gets no second look there either.
    func autoPickID(providerID: String, accounts: [AccountUsage], launchable: Set<String>,
                    reserves: [String: Double], quarantined: Set<String>,
                    occupancy: [String: Int]?, now: Date) -> String? {
        autoPickID(providerID: providerID, accounts: accounts, launchable: launchable,
                   reserves: reserves, excluding: quarantined, clearance: true,
                   occupancy: occupancy, now: now)
            ?? autoPickID(providerID: providerID, accounts: accounts, launchable: launchable,
                          reserves: reserves, excluding: [], clearance: false,
                          occupancy: occupancy, now: now)
    }

    private func autoPickID(providerID: String, accounts: [AccountUsage], launchable: Set<String>,
                            reserves: [String: Double], excluding: Set<String>, clearance: Bool,
                            occupancy: [String: Int]?, now: Date) -> String? {
        let primary = policy(providerID).model
        // The CLI's nearly-dry gate, from the file both targets compile (AccountComfort.swift):
        // the badge has to predict the launch, so the same accounts leave before the ordering.
        //
        // `lastRefreshFailed` is in that predicate for the reason `accountIsSpent` gives about its
        // own (TallyCLI/AccountPick.swift): `isStale` waits for a SECOND consecutive failure so the
        // "Outdated" badge cannot flicker on a token rotation, which leaves a whole poll interval in
        // which held-over numbers are published looking freshly fetched. Deciding eligibility on
        // those is deciding it on a reading nobody confirmed - and the badge that results is not the
        // account `tally` would launch, which is the one promise this function makes. Mirror of the
        // CLI's `eligible`; keep both sides in lockstep.
        let eligibleAccounts = accounts.filter {
            $0.providerID == providerID && $0.error == nil && !$0.isStale
                && !$0.lastRefreshFailed
                && launchable.contains($0.id) && !excluding.contains($0.id)
                && (Self.headroom($0, primaryModel: primary) ?? -1) > 0
        }
        // AN ACCOUNT UNDER ITS OWN LINE NEVER CARRIES THE BADGE, exactly as `best` keeps it out of
        // the field (TallyCLI/AccountPick.swift, B-1213 hard reserve): when that empties the field
        // the launcher refuses, so no card is marked. Unreachable on a fleet where nobody marked an
        // account: an eligible account has every window above zero, so it is above a zero reserve.
        let above = eligibleAccounts.filter {
            Self.aboveReserve($0, primaryModel: primary, reserve: reserves[$0.id] ?? 0, now: now)
        }
        // The launcher's clearance lane comes first (`launchPick`, TallyCLI/AccountPick.swift).
        // Read: an account with no live session has no entry. Not read yet, or unknown: full.
        let sessions: (AccountUsage) -> Int = { account in
            occupancy.map { $0[account.id] ?? 0 } ?? clearanceMaxSessions
        }
        let windows: (AccountUsage) -> [ComfortWindow] = {
            Self.comfortWindows($0, primaryModel: primary, reserve: reserves[$0.id] ?? 0, now: now)
        }
        if clearance, let clearance = clearancePick(above, now: now, windows: {
            Self.clearanceWindows($0, primaryModel: primary, reserve: reserves[$0.id] ?? 0, now: now)
        }, sessions: sessions) { return clearance.id }
        // The CLI's load gate, in the order `best` applies it (TallyCLI/AccountPick.swift, #4).
        let candidates = preferringUncrowded(preferringComfortable(above, now: now, windows: windows),
                                             now: now, windows: windows, sessions: sessions)
        guard var leader = candidates.first else { return nil }
        var leaderScore = Self.smartScore(leader, primaryModel: primary,
                                          reserve: reserves[leader.id] ?? 0, now: now)
        for candidate in candidates.dropFirst() {
            let score = Self.smartScore(candidate, primaryModel: primary,
                                        reserve: reserves[candidate.id] ?? 0, now: now)
            if score > leaderScore * Self.smartPickMargin,
               score > leaderScore + Self.smartPickMinGain {
                leader = candidate
                leaderScore = score
            } else if score >= leaderScore,
                      (candidate.resetCreditsAvailable ?? 0) > (leader.resetCreditsAvailable ?? 0) {
                // Mirror of the CLI's near-tie tie-breaker: a wall with banked resets behind
                // it is softer. Reads the count only; never spends.
                leader = candidate
                leaderScore = score
            }
        }
        return leader.id
    }
}
