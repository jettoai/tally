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

/// What a hand-written name resolved to.
///
/// Three answers, because `nil` used to carry two of them and they are opposite instructions to the
/// person who just typed the name: "there is no such account" sends them to `tally status`, while
/// "several answer to that" means type more of one. Collapsing them into one silence left every
/// caller saying the first sentence for both.
enum AccountMatch: Equatable {
    /// Exactly one account answers to the name.
    case one(Snapshot.Account)
    /// Nothing does.
    case none
    /// Several do, in the order the snapshot lists them. Never acted on: acting on the first of
    /// these is the failure this type exists to make impossible.
    case several([Snapshot.Account])
}

/// The account a hand-written NAME picks out. Only launchable accounts are candidates - naming a
/// signed-out one is not a way to launch it.
///
/// THREE STAGES, most exact first, and the order is the whole point:
///
///   1. an EXACT hit on either name (the label, case-insensitively, or the config-dir name), when
///      exactly one account has one
///   2. a substring of either name, when exactly one account contains it
///   3. anything else that hit: refuse, and hand back the candidates
///
/// The two names share one stage rather than being tried in turn, and that is not a tidy-up. A label
/// is free text the user can edit, so account A's label can be exactly account B's directory name -
/// and then a label-first order answers A for an input that points just as exactly at B. Trying them
/// together makes that what it is: one input, two exact readings, no answer.
///
/// It used to be stage 3 alone, answering with the FIRST hit, which is wrong on the fleet this repo
/// is written for. Accounts labelled "Claude", "Claude 2", "Claude 3", "Claude 4" all contain
/// "Claude", so typing the full, exact, unambiguous name of the first one resolved to whichever of
/// the four the snapshot happened to list first: `tally switch Claude` moved the session to
/// "Claude 2" and reported success. Substring matching is still the convenience it was added to be
/// (`--account claude2` finds "Claude 2" and `~/.claude2`); it is now the LAST thing tried rather
/// than the only thing, and it no longer guesses when it is ambiguous.
///
/// REFUSING IS THE SAFE SIDE HERE, which is worth stating because it usually is not. This matcher
/// serves exactly one moment: a person has just typed a name and is waiting. The alternative to
/// refusing is silently acting on an account they did not name - a live conversation moved, or a
/// project pinned, somewhere else - and unlike a refusal, that failure is invisible until much
/// later. Nothing else comes through here: a project profile stores the RESOLVED id
/// (ProjectPolicy.swift), so a launch carrying an existing pin never re-runs this.
///
/// One matcher for `tally claude --account`, `tally switch` and `tally project set --account`,
/// because the last stores what the first would have launched: a name that resolves one way when it
/// is written down and another way when it is used is a pin that lands somewhere nobody asked for.
func accountMatching(_ name: String, provider: String, in snapshot: Snapshot?) -> AccountMatch {
    let query = name.lowercased()
    // The config-dir name is derived once per account: every stage below reads it.
    let candidates = (snapshot?.accounts ?? []).compactMap {
        account -> (account: Snapshot.Account, dir: String)? in
        guard account.provider == provider, let home = account.launchHome else { return nil }
        return (account, URL(fileURLWithPath: home).lastPathComponent.lowercased())
    }
    // Uniqueness is required even of an exact hit, and it is required ACROSS both names. Two
    // accounts carrying the same label are indistinguishable by it; an account whose label is
    // another's directory name is exactly as indistinguishable, in a way no ordering can break -
    // whichever name is tried first wins, and both readings were exact. Filtering over the
    // per-account rows above is also what deduplicates: an account matching on both of its own
    // names is still one candidate, not two.
    let exact = candidates.filter { $0.account.label.lowercased() == query || $0.dir == query }
    if exact.count == 1 { return .one(exact[0].account) }
    let hits = candidates.filter {
        $0.account.label.lowercased().contains(query) || $0.dir.contains(query)
    }
    if hits.count == 1 { return .one(hits[0].account) }
    return hits.isEmpty ? .none : .several(hits.map(\.account))
}

/// How every surface names the accounts an ambiguous query hit: the label, with the config-dir name
/// beside it.
///
/// Both, for two reasons. The label alone cannot always tell them apart - two accounts may carry the
/// same one, and the directory is then the only name that resolves - and both are things the matcher
/// accepts, so the list doubles as the set of answers to retype.
func accountMatchCandidates(_ accounts: [Snapshot.Account]) -> String {
    accounts.map { account in
        guard let home = account.launchHome else { return account.label }
        return "\(account.label) (\(URL(fileURLWithPath: home).lastPathComponent))"
    }.joined(separator: ", ")
}

/// The whole sentence a `.several` becomes, so the three surfaces that resolve a typed name cannot
/// describe the same refusal differently - which they had already started to do within one change.
/// Each still adds its own tail (`; nothing was changed` for a write, a note for the switch), which
/// is the part that really is per-surface; the count, the candidates and the instruction are not.
func accountMatchAmbiguity(_ name: String, provider: String,
                           candidates: [Snapshot.Account]) -> String {
    "\"\(name)\" matches \(candidates.count) \(provider) accounts "
        + "(\(accountMatchCandidates(candidates))) - name one of them exactly"
}

// MARK: The manual pin, resolved

/// Whether Tally KNOWS the pinned account's login is gone: the snapshot LISTS that account and
/// gives it no launch home, which is the app publishing "this one is dormant" (a signed-out home is
/// kept out of the launch map on purpose - UsageStore publishes `launchableHome`, not `launchHome`).
///
/// Deliberately different from "not in the snapshot at all", which says only that Tally has not seen
/// the account this round: a refresh mid-flight, a provider switched off, an app that has not run
/// yet. That case keeps the denormalized fallback below; this one must not.
func pinnedAccountIsSignedOut(_ snapshot: Snapshot?, policy: LaunchPolicy) -> Bool {
    guard policy.mode == "manual", let pinnedID = policy.pinnedAccountID,
          let listed = snapshot?.accounts.first(where: { $0.id == pinnedID }) else { return false }
    return listed.launchHome == nil
}

/// The home a manual pin launches, or nil when the pin cannot be launched right now (and the caller
/// should fall through to the headroom pick).
///
/// Two sources in order: the pinned account in the snapshot, then the home the app denormalized into
/// the policy file - the fallback that exists so a pin still works while its account is briefly
/// missing from the snapshot. That fallback is the one that needed a rule. It asks nothing about the
/// account, so a pin left behind on an account that later signed OUT kept exec'ing a logged-out
/// config dir long after the panel stopped offering it (2026-08-03). The app clears the home too
/// (`LaunchPolicyStore.releasePinnedHome`); both halves, because either alone still leaves a
/// version of the pair that launches a dormant home.
///
/// One function for every surface that resolves a pin - launch, `best-dir`, `launch-dir` and the
/// status report - so a prediction cannot disagree with what launching does.
func pinnedLaunchHome(_ snapshot: Snapshot?, policy: LaunchPolicy) -> String? {
    guard policy.mode == "manual" else { return nil }
    if let home = snapshot?.accounts.first(where: { $0.id == policy.pinnedAccountID })?.launchHome {
        return home
    }
    return pinnedAccountIsSignedOut(snapshot, policy: policy) ? nil : policy.pinnedHome
}

/// One usage window with its sustainable burn rate: how much quota per hour it can spend until
/// it refreshes. A window about to reset stops being a constraint (its rate soars, and its
/// leftover quota would evaporate unused) - the "burn the dying quota first" intuition; a window
/// with days to go binds hard. A missing reset time is read as a full window, which is the
/// conservative degradation rather than a reading: the provider assigns each account a FIXED
/// weekly reset moment that does not move with use (support.claude.com, "What is the Max plan"),
/// so an absent reset only ever means nobody has read one yet (a v1 snapshot, an account the app
/// has not polled). Assuming the longest window keeps such an account from gaining a phantom
/// advantage; old snapshots degrade to plain headroom ordering.
struct RatedWindow {
    let name: String
    let remaining: Double
    /// What the PROVIDER reported for this window, and nil when it reported nothing. This is the
    /// reading a human-facing sentence may quote (`pickReason`) and the one identity-like readers
    /// key on (the rebalance cycle key, the cap recovery deadline): never inferred, so nothing
    /// outside this file can quote a time nobody published.
    let resetsAt: Date?
    /// The reset this window's RATE is measured against: its own when it has one, and otherwise an
    /// inferred anchor (below). Kept apart from `resetsAt` precisely because it can be inferred -
    /// a number good enough to rank two accounts by is not automatically good enough to print.
    let anchor: Date?
    let rate: Double
}

func ratedWindows(_ account: Snapshot.Account, primaryModel: String?,
                  now: Date = Date()) -> [RatedWindow] {
    func window(_ name: String, _ remaining: Double?, _ resetsAt: Date?,
                inferredAnchor: Date? = nil, fullWindowHours: Double) -> RatedWindow? {
        guard let remaining else { return nil }
        let anchor = resetsAt ?? inferredAnchor
        let hours = anchor.map { max($0.timeIntervalSince(now) / 3600, 0.05) } ?? fullWindowHours
        return RatedWindow(name: name, remaining: remaining, resetsAt: resetsAt, anchor: anchor,
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
    // THE FLAGSHIP WINDOW BORROWS THE WEEKLY RESET WHEN IT REPORTS NONE OF ITS OWN. Both turn over
    // on the account's one fixed weekly moment (above): measured 2026-08-12 across the live fleet,
    // every account that has opened its week reports `modelResetsAt` EQUAL to `weeklyResetsAt`. So
    // a null flagship reset is the provider declining to repeat itself rather than a window on some
    // other cycle, and the 168h fallback understated its rate by up to a week - which reads as
    // "this account is the scarce one" exactly when it is not. Inferred, so it rides in the anchor;
    // with no weekly reset to borrow, both stay nil and the full-window assumption stands.
    if modelWindowCounts,
       let model = window(account.modelWindowName ?? "model", account.modelRemaining,
                          account.modelResetsAt, inferredAnchor: account.weeklyResetsAt,
                          fullWindowHours: 168) {
        windows.append(model)
    }
    return windows
}

/// One rated window as the nearly-dry gate (AccountComfort.swift) sees it, keyed on the ANCHOR: the
/// gate asks when the wall comes down, and a flagship window with no reset of its own hits the
/// account's weekly wall. Reading the reported field instead would exempt the weekly window and
/// refuse the flagship one for the same moment.
///
/// One conversion for the whole CLI, so everything that asks the gate about a window weighs it the
/// same way: the account gate below, and the rebalance cycle key, which names the window this gate
/// reacted to - and names it by the REPORTED reset, an identity every supervisor agrees on rather
/// than a judgement.
func comfortWindow(_ window: RatedWindow) -> ComfortWindow {
    ComfortWindow(remaining: window.remaining, resetsAt: window.anchor)
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
