import Foundation

/// The account a RUNNING session should adopt when its launch-default model changes, with the
/// current account SEEDED as the incumbent leader: a challenger only takes over by clearing BOTH
/// gates (1.15x rate AND an absolute gain) and being eligible for the new model. So a session
/// stays put whenever its account can still serve the new model, and switches only when the
/// incumbent genuinely can't (the 02:22 storm relaunched five sessions onto an account with no
/// room for the new model) or a sibling is decisively healthier. Returns nil only when nothing,
/// incumbent included, is eligible - a dead end the caller must not relaunch into. No banked-reset
/// tie-breaker here: this pick is about NOT churning a serviceable session, not launch economics.
///
/// A CHALLENGER must also clear the nearly-dry gate, which is the one thing this pick was missing:
/// `best` has applied it since it was written, the cap handoff and the idle rebalance both apply it,
/// and this was the last account pick in the repo deciding on a bare rate. A rate has no floor, so a
/// nearly empty window whose reset is close beats a full one whose reset is days away - which is how
/// two sessions moved onto an account with 4% of its week left and 1.2h until it refilled, while a
/// sibling sat at 98% (2026-08-02T06:47Z, reason=follow; measured 3.33 %/h against 0.67 %/h).
///
/// The INCUMBENT is deliberately not gated. Seeding it is the whole design, and dropping a dry
/// incumbent would turn every Settings change into a fleet-wide evacuation of a spent account, with
/// no claim to serialize it - five sessions adopting at once would all land on the one healthy
/// sibling, which is the storm above wearing a different hat. Moving a session off a dying account
/// is the idle rebalance's job (Rebalance.swift), where it happens once per account per drought.
///
/// A RESERVE BINDS THE CHALLENGERS AND NOT THE INCUMBENT, which falls out of the seeding rather than
/// being a rule of its own and is the right answer either way: a session already ON the personal
/// account is not moved by this station (that is the idle rebalance's job, once per drought), and
/// nothing may be moved onto an account under its line.
///
/// A CHALLENGER MUST ALSO NOT BE THIN AND CROWDED (jettoai/tally#4): the strict half of the load
/// gate (`requiringUncrowded`), with no fallback, because staying on the incumbent costs nothing.
/// The incumbent is not load-gated for the same reason it is not comfort-gated.
func incumbentSeededBest(providerID: String, in snapshot: Snapshot, incumbentID: String,
                         primaryModel: String?, excluding: Set<String> = [],
                         reserves: AccountReserves = .none,
                         now: Date = Date()) -> Snapshot.Account? {
    let candidates = pickField(providerID: providerID, in: snapshot, primaryModel: primaryModel,
                               excluding: excluding)
    // The incumbent can't serve the new model (or was quarantined): no incumbent to stabilize, so
    // fall back to the plain best of what remains.
    guard var leader = candidates.first(where: { $0.id == incumbentID }) else {
        return best(providerID: providerID, in: snapshot, primaryModel: primaryModel,
                    excluding: excluding, reserves: reserves, now: now)
    }
    var leaderScore = smartScore(leader, primaryModel: primaryModel, reserves: reserves, now: now)
    // A challenger must also not be a thin account already carrying two conversations (#4): the
    // incumbent is a safe place to stay, so this is the strict half, never a fallback.
    let challengers = requiringUncrowded(
        requiringComfortable(candidates.filter { $0.id != incumbentID },
                             primaryModel: primaryModel, reserves: reserves, now: now),
        primaryModel: primaryModel, reserves: reserves, now: now)
    for candidate in challengers {
        let score = smartScore(candidate, primaryModel: primaryModel, reserves: reserves, now: now)
        if score > leaderScore * smartPickMargin, score > leaderScore + smartPickMinGain {
            leader = candidate
            leaderScore = score
        }
    }
    return leader
}

/// The account a CAP HANDOFF moves a running session to, or nil to keep waiting on the capped one.
/// Takes the field the supervisor has already narrowed (right provider, eligible for the running
/// model, not the current account, not quarantined) and applies the STRICT half of the nearly-dry
/// gate: unlike a launch, this has a live session to lose, and a thin account is not worth the
/// restart it costs, so an empty field means wait rather than move. Waiting is not giving up: the
/// supervisor keeps polling and hands off the moment a sibling is genuinely usable.
///
/// THE ONE TARGET-CHOOSER EVERY AUTOMATIC MOVE SHARES (cap handoff, idle rebalance, turn boundary,
/// window repick), which is also where "a reserve is never crossed by a move" is enforced for all
/// four at once: the strict gate drops an account under its line, and no target means wait.
///
/// The LOAD GATE applies here in its preferring half (jettoai/tally#4, `preferringUncrowded`): among
/// the comfortable targets, a thin account already carrying `clearanceMaxSessions` live sessions is
/// passed over while another exists. When it is the only one, the move still goes there: whether
/// to move or wait stays the strict comfort gate's call, not the load gate's.
func capHandoffTarget(_ eligibleAccounts: [Snapshot.Account], primaryModel: String?,
                      reserves: AccountReserves = .none,
                      now: Date = Date()) -> Snapshot.Account? {
    // The load gate's preferring half (#4): a move avoids a thin crowded target when another
    // comfortable one exists, and never turns a move into a wait.
    preferringUncrowded(requiringComfortable(eligibleAccounts, primaryModel: primaryModel,
                                             reserves: reserves, now: now),
                        primaryModel: primaryModel, reserves: reserves, now: now)
        .max { smartScore($0, primaryModel: primaryModel, reserves: reserves, now: now)
            < smartScore($1, primaryModel: primaryModel, reserves: reserves, now: now) }
}
