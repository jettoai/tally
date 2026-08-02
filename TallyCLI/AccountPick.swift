import Foundation

// Which account a launch, a follow adoption, a cap handoff or a prediction lands on: the burn-rate
// scoring and every pick built on it, split out of Snapshot.swift for file size. The snapshot model
// and the launch plumbing stay there; nothing here reads a file or touches the environment.
//
// Every pick below is the same number read differently: `smartScore`, the rate of the account's
// tightest window. They differ only in the field they start from, the gate they apply to it, and
// how hard a challenger has to push to take the lead.

/// Proven headroom: the tightest of the windows the account actually reports. Any window at 0
/// means the account is capped right now regardless of the others. The flagship window only
/// binds when the declared primary model IS that tier: a sonnet primary does not drain the fable
/// window, so a fable window at 0 must not report the account as capped (same rule as
/// `ratedWindows`, which the score already follows - eligibility was the one place still counting
/// the flagship window unconditionally). No declared primary keeps it flagship-first, the app's
/// display philosophy, and matches the historical behavior for callers that pass nil.
func headroom(_ account: Snapshot.Account, primaryModel: String? = nil) -> Double {
    var windows = [account.sessionRemaining, account.weeklyRemaining].compactMap { $0 }
    let windowModel = account.modelWindowName?.lowercased()
    let primary = primaryModel?.lowercased()
    let modelWindowCounts = primary == nil || windowModel == nil
        || windowModel!.contains(primary!) || primary!.contains(windowModel!)
    if modelWindowCounts, let model = account.modelRemaining { windows.append(model) }
    return windows.min() ?? -1
}

func eligible(_ account: Snapshot.Account, primaryModel: String? = nil) -> Bool {
    account.launchHome != nil && account.error == nil && !account.isStale
        && headroom(account, primaryModel: primaryModel) > 0
}

/// One usage window with its sustainable burn rate: how much quota per hour it can spend until
/// it refreshes. A window about to reset stops being a constraint (its rate soars, and its
/// leftover quota would evaporate unused) - the "burn the dying quota first" intuition; a window
/// with days to go binds hard. Missing reset times assume a full window, so old snapshots
/// degrade to plain headroom ordering instead of gaining a phantom advantage.
struct RatedWindow {
    let name: String
    let remaining: Double
    let resetsAt: Date?
    let rate: Double
}

func ratedWindows(_ account: Snapshot.Account, primaryModel: String?,
                  now: Date = Date()) -> [RatedWindow] {
    func window(_ name: String, _ remaining: Double?, _ resetsAt: Date?,
                fullWindowHours: Double) -> RatedWindow? {
        guard let remaining else { return nil }
        let hours = resetsAt.map { max($0.timeIntervalSince(now) / 3600, 0.05) } ?? fullWindowHours
        return RatedWindow(name: name, remaining: remaining, resetsAt: resetsAt,
                           rate: remaining / hours)
    }
    var windows = [
        window("session", account.sessionRemaining, account.sessionResetsAt, fullWindowHours: 5),
        window("weekly", account.weeklyRemaining, account.weeklyResetsAt, fullWindowHours: 168),
    ].compactMap { $0 }
    // The flagship window only constrains the pick when the declared primary model IS that tier
    // (a sonnet primary doesn't drain the fable window, so a drained fable window must not veto
    // the account). No declared primary = flagship-first, the app's display philosophy.
    let windowModel = account.modelWindowName?.lowercased()
    let primary = primaryModel?.lowercased()
    let modelWindowCounts = primary == nil || windowModel == nil
        || windowModel!.contains(primary!) || primary!.contains(windowModel!)
    if modelWindowCounts,
       let model = window(account.modelWindowName ?? "model", account.modelRemaining,
                          account.modelResetsAt, fullWindowHours: 168) {
        windows.append(model)
    }
    return windows
}

/// One rated window as the nearly-dry gate (AccountComfort.swift) sees it. One conversion for the
/// whole CLI, so everything that asks the gate about a window weighs it the same way: the account
/// gate below, and the rebalance cycle key, which has to name the window the gate is reacting to.
func comfortWindow(_ window: RatedWindow) -> ComfortWindow {
    ComfortWindow(remaining: window.remaining, resetsAt: window.resetsAt)
}

/// What the nearly-dry gate weighs for a CLI account: exactly the windows `ratedWindows` counts for
/// the declared primary model, so the gate never re-decides which windows an account spends. Shared
/// by both gate policies, so they can differ in what they do with an empty result and in nothing
/// else.
private func comfortWindows(_ account: Snapshot.Account, primaryModel: String?,
                            now: Date) -> [ComfortWindow] {
    ratedWindows(account, primaryModel: primaryModel, now: now).map(comfortWindow)
}

/// The launch-side gate: drops the nearly dry, keeps the field whole when nothing is comfortable.
func preferringComfortable(_ accounts: [Snapshot.Account], primaryModel: String?,
                           now: Date) -> [Snapshot.Account] {
    preferringComfortable(accounts, now: now) {
        comfortWindows($0, primaryModel: primaryModel, now: now)
    }
}

/// Whether ONE account still has room to work in, by exactly the gate the picks apply to candidates
/// (imminent-reset exemption included). Asked of the account a session already RUNS on, which the
/// filtering helpers above cannot answer: they take a field and return a field.
func accountIsComfortable(_ account: Snapshot.Account, primaryModel: String?,
                          now: Date = Date()) -> Bool {
    isComfortable(comfortWindows(account, primaryModel: primaryModel, now: now), now: now)
}

/// An account's score is its TIGHTEST window's rate - the binding constraint. `best()` then picks
/// the account whose binding constraint is loosest, which naturally prefers an account whose low
/// session quota resets in minutes over one hoarding a bigger but slower-refreshing allowance.
func smartScore(_ account: Snapshot.Account, primaryModel: String?, now: Date = Date()) -> Double {
    ratedWindows(account, primaryModel: primaryModel, now: now).map(\.rate).min() ?? -1
}

/// The human reason behind a pick: its binding window, e.g. "weekly 32% · resets 2d".
func pickReason(_ account: Snapshot.Account, primaryModel: String?, now: Date = Date()) -> String {
    guard let binding = ratedWindows(account, primaryModel: primaryModel, now: now)
        .min(by: { $0.rate < $1.rate }) else { return "no usage windows" }
    var text = "\(binding.name) \(Int(binding.remaining.rounded()))%"
    if let resetsAt = binding.resetsAt {
        text += " · resets \(shortETA(resetsAt.timeIntervalSince(now)))"
    }
    return text
}

/// Hysteresis: near-equal scores must not flip the pick. Quota percentages are coarse and
/// refresh-lagged, so the account just used dips a point below its idle sibling - without a
/// margin every new launch would bounce between the two (scattering conversation history
/// across accounts) for zero real gain. A later account only takes the lead by beating the
/// current leader by BOTH gates; ties and noise-level differences stay with the earlier
/// account in the (stable) list order.
///
/// Two gates because one ratio lies at the low end: at 2% vs 3% remaining the relative gap is
/// 50% yet the real difference is one noise-level point - two nearly-drained accounts would
/// ping-pong on it. The absolute gate (~8 weekly points over a full week) keeps them put; a
/// genuinely healthier sibling clears both gates easily. Sticking with a nearly-drained leader
/// is safe: the cap-hit handoff is the net.
let smartPickMargin = 1.15
let smartPickMinGain = 0.05   // %/h

func best(providerID: String, in snapshot: Snapshot, primaryModel: String? = nil,
          excluding: Set<String> = [], now: Date = Date()) -> Snapshot.Account? {
    // The nearly-dry gate runs first (AccountComfort.swift): a rate cannot tell "healthy" from
    // "1% left with a close reset", so accounts that are actually dry leave before the ordering.
    let eligibleAccounts = snapshot.accounts.filter {
        $0.provider == providerID && eligible($0, primaryModel: primaryModel)
            && !excluding.contains($0.id)
    }
    let candidates = preferringComfortable(eligibleAccounts, primaryModel: primaryModel, now: now)
    guard var leader = candidates.first else { return nil }
    var leaderScore = smartScore(leader, primaryModel: primaryModel, now: now)
    for candidate in candidates.dropFirst() {
        let score = smartScore(candidate, primaryModel: primaryModel, now: now)
        if score > leaderScore * smartPickMargin, score > leaderScore + smartPickMinGain {
            leader = candidate
            leaderScore = score
        } else if score >= leaderScore,
                  (candidate.resetCreditsAvailable ?? 0) > (leader.resetCreditsAvailable ?? 0) {
            // Near-tie tie-breaker: a wall with banked resets behind it is SOFTER (capped =
            // redeemable), so burn that account and preserve the one whose wall is terminal.
            // Reads the banked count only - the smart pick never spends a reset.
            leader = candidate
            leaderScore = score
        }
    }
    return leader
}

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
func incumbentSeededBest(providerID: String, in snapshot: Snapshot, incumbentID: String,
                         primaryModel: String?, excluding: Set<String> = [],
                         now: Date = Date()) -> Snapshot.Account? {
    let candidates = snapshot.accounts.filter {
        $0.provider == providerID && eligible($0, primaryModel: primaryModel)
            && !excluding.contains($0.id)
    }
    // The incumbent can't serve the new model (or was quarantined): no incumbent to stabilize, so
    // fall back to the plain best of what remains.
    guard var leader = candidates.first(where: { $0.id == incumbentID }) else {
        return best(providerID: providerID, in: snapshot, primaryModel: primaryModel,
                    excluding: excluding, now: now)
    }
    var leaderScore = smartScore(leader, primaryModel: primaryModel, now: now)
    let challengers = requiringComfortable(candidates.filter { $0.id != incumbentID }, now: now) {
        comfortWindows($0, primaryModel: primaryModel, now: now)
    }
    for candidate in challengers {
        let score = smartScore(candidate, primaryModel: primaryModel, now: now)
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
func capHandoffTarget(_ eligibleAccounts: [Snapshot.Account], primaryModel: String?,
                      now: Date = Date()) -> Snapshot.Account? {
    requiringComfortable(eligibleAccounts, now: now) {
        comfortWindows($0, primaryModel: primaryModel, now: now)
    }
    .max { smartScore($0, primaryModel: primaryModel, now: now)
        < smartScore($1, primaryModel: primaryModel, now: now) }
}

/// The account an automatic launch would actually land on: `best` with the live cap quarantine
/// applied, falling back to the unfiltered pick when quarantine empties the field (launching on
/// an account that just capped still beats refusing to launch).
///
/// Every surface that PREDICTS the launch goes through here rather than calling `best` directly,
/// because a prediction that skips an exclusion the launcher applies is simply wrong: on
/// 2026-07-25 the app's smart-pick badge named a quarantined account, and the reader concluded
/// the picker was broken rather than that the badge was. One function, so a display cannot
/// contradict what launching does.
func launchPick(providerID: String, in snapshot: Snapshot, primaryModel: String?,
                quarantined: Set<String>, now: Date = Date()) -> Snapshot.Account? {
    best(providerID: providerID, in: snapshot, primaryModel: primaryModel,
         excluding: quarantined, now: now)
        ?? best(providerID: providerID, in: snapshot, primaryModel: primaryModel, now: now)
}
