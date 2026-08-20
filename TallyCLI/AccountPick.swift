import Foundation

// Which account a launch, a follow adoption, a cap handoff or a prediction lands on: the burn-rate
// scoring and every pick built on it, split out of Snapshot.swift for file size. The snapshot model
// and the launch plumbing stay there; nothing here reads a file or touches the environment.
//
// Every pick below is the same number read differently: `smartScore`, the rate of the account's
// tightest window. They differ only in the field they start from, the gate they apply to it, and
// how hard a challenger has to push to take the lead.
//
// EVERY PICK ALSO TAKES `reserves`, which is how much of each account its owner keeps for their own
// use (AccountReserve.swift). A call site that passes the fleet's reserves is saying "Tally chose
// this"; one that passes `.none` is saying "a person named this account", and there is no third
// answer - so the parameter is the audit trail for the one rule the feature has.

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

/// Whether an account can be launched or moved onto AT ALL. Deliberately reserve-blind: what a
/// reserve says is "spend somewhere else if you can", not "this account does not exist", and the
/// difference is the whole of how `tally claude` still starts when the fleet is under water
/// (`best`). The reserve is applied by the gate one step later.
///
/// `lastRefreshFailed` joins the badge and the error here for the reason `accountIsSpent` gives
/// about its own copy of the test: a failed poll republishes the last good numbers, so a row held
/// over from before the failure is spelled exactly like one fetched a moment ago, and every reading
/// built on it - eligible, comfortable, spent - is a judgement about a moment that has passed. nil
/// (a snapshot from an app that predates the flag) is "cannot tell" and keeps the account, which is
/// what the badge and the error are still here for.
func eligible(_ account: Snapshot.Account, primaryModel: String? = nil) -> Bool {
    account.launchHome != nil && account.error == nil && !account.isStale
        && account.lastRefreshFailed != true
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
/// with days to go binds hard.
///
/// A MISSING RESET TIME IS READ IN ONE OF TWO WAYS, and which one applies turns on whether the
/// window has been spent at all. The provider assigns each account a FIXED weekly reset moment that
/// does not move with use (support.claude.com, "What is the Max plan"), but it only publishes that
/// moment once usage opens the window: an account that has never run a request reports 100% and a
/// null reset on every window it has (measured 2026-08-19). So, after a reported reset and the
/// borrowed one below (a flagship window taking the weekly reset, still a reading), the fallback:
///
///   - SPENT, reset unread (below 100%): assume the full window. That is the conservative
///     degradation rather than a reading, it denies such an account a phantom advantage, and old
///     snapshots (a v1 file, an account the app has not polled) degrade to plain headroom ordering.
///   - UNTOUCHED (still at 100%) AND ON A FIXED CYCLE: the window was never opened, so its PHASE is
///     unknown rather than late, and the expected distance to a reset drawn uniformly across the
///     window is half of it. Here the full window is the WORST case rather than a neutral one, and
///     assuming it deadlocks: a brand new account rated 100/168 = 0.60 %/h loses to a working
///     account holding 16% of its week with a reset a day out (0.67 %/h), so it is never launched,
///     so it never earns a reset to be rated by. Broken by hand with `tally account` on 2026-08-19.
///
/// THE SESSION WINDOW IS THE EXCEPTION to that second reading, because its phase is not unknown:
/// the 5h session clock starts on the first message rather than on a schedule the provider fixes
/// (MetricRowView.swift says the same to the user), so an untouched session window has its whole
/// 5h still ahead of it. Halving it would double the rate of every idle account's session window
/// (100/2.5 = 40 %/h against the true 100/5 = 20 %/h) and let an untouched account outrank the
/// field on a window nobody has started.
///
/// Both inferences ride in `anchor` and never in `resetsAt`, so no sentence quotes them.
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
    /// Percentage points of this window its owner reserved for themselves, carried so the gate one
    /// step downstream weighs the same window this rate was measured on (`comfortWindow`). Zero
    /// unless the caller handed reserves in.
    var reserve: Double = 0
    /// How fast the part of this window Tally may spend can be spent: the EFFECTIVE remaining over
    /// the hours until the anchor. Reserve-aware because ranking is where "spend somewhere else if
    /// you can" has to bite - a floor alone would leave a personal account at 90% out-ranking a
    /// sibling at 70% right up until it crossed the line, which is the opposite of the instruction.
    let rate: Double
}

/// `reserves` defaults to none so that every caller that has not been taught about them - the
/// prediction surfaces, the tests, the app - keeps the behaviour it had. The picks that ARE Tally's
/// own choice pass the fleet's.
func ratedWindows(_ account: Snapshot.Account, primaryModel: String?,
                  reserves: AccountReserves = .none, now: Date = Date()) -> [RatedWindow] {
    let reserve = reserves.reserve(for: account)
    /// `fixedCycle` marks a window that turns over on a moment the account does not set: the weekly
    /// one, and the flagship window riding on it. Only those get the midpoint reading, because only
    /// their phase is unknown while untouched. The session window is not one of them (above).
    func window(_ name: String, _ remaining: Double?, _ resetsAt: Date?,
                inferredAnchor: Date? = nil, fullWindowHours: Double,
                fixedCycle: Bool = false) -> RatedWindow? {
        guard let remaining else { return nil }
        // An untouched fixed-cycle window has published no reset because nothing has opened it yet,
        // so it is rated against the midpoint of its own length rather than its far edge (above). A
        // spent one whose reset nobody has read keeps the full-window assumption below, and so does
        // an untouched session window, whose clock has not started rather than started unseen.
        let untouchedAnchor = fixedCycle && remaining >= 100
            ? now.addingTimeInterval(fullWindowHours / 2 * 3600) : nil
        let anchor = resetsAt ?? inferredAnchor ?? untouchedAnchor
        let hours = anchor.map { max($0.timeIntervalSince(now) / 3600, 0.05) } ?? fullWindowHours
        return RatedWindow(name: name, remaining: remaining, resetsAt: resetsAt, anchor: anchor,
                           reserve: reserve, rate: (remaining - reserve) / hours)
    }
    var windows = [
        window("session", account.sessionRemaining, account.sessionResetsAt, fullWindowHours: 5),
        window("weekly", account.weeklyRemaining, account.weeklyResetsAt, fullWindowHours: 168,
               fixedCycle: true),
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
                          fullWindowHours: 168, fixedCycle: true) {
        windows.append(model)
    }
    return windows
}

/// An account's score is its TIGHTEST window's rate - the binding constraint. `best()` then picks
/// the account whose binding constraint is loosest, which naturally prefers an account whose low
/// session quota resets in minutes over one hoarding a bigger but slower-refreshing allowance.
func smartScore(_ account: Snapshot.Account, primaryModel: String?,
                reserves: AccountReserves = .none, now: Date = Date()) -> Double {
    ratedWindows(account, primaryModel: primaryModel, reserves: reserves, now: now)
        .map(\.rate).min() ?? -1
}

/// The human reason behind a pick: its binding window, e.g. "weekly 32% · resets 2d".
///
/// The window whose RATE binds, which is the question a pick asks (how hard can this account be
/// pushed), and deliberately not the one `bindingWindow` names (how close is the wall).
///
/// Reserve-blind, and it takes no `reserves` to be so: this is a sentence for a person, the rate is
/// only being used to choose WHICH window to quote, and the percentage it prints is the provider's
/// (`windowReason` states that rule). A reserve can shift which window binds; it can never make a
/// reader's line disagree with `tally status`.
func pickReason(_ account: Snapshot.Account, primaryModel: String?, now: Date = Date()) -> String {
    guard let binding = ratedWindows(account, primaryModel: primaryModel, now: now)
        .min(by: { $0.rate < $1.rate }) else { return "no usage windows" }
    return windowReason(binding, now: now)
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

///
/// WHEN NOBODY IS ABOVE THEIR RESERVE, THIS PICK DROPS THE RESERVES ENTIRELY and ranks the fleet as
/// it did before the feature existed. A launch has nowhere else to go: refusing to start a session
/// because of a preference set weeks ago is a worse outcome than spending 3% of it, and every path
/// that makes this pick says so out loud when it happens - `runLaunch` on its own stderr, the two
/// shim commands through the script they print (`reserveDipNotice`, and LaunchDir.swift for why the
/// same sentence needs two ways out). Dropped rather than ranked-on-negatives,
/// because negative rates are not a scale - the hysteresis gates below were written for a quantity
/// with a floor at zero, and letting them compare -0.06 against -0.05 would decide the fleet's
/// worst-case launch by an accident of arithmetic. On a fleet with no reserves set this substitution
/// cannot fire at all: an eligible account has every window above zero, so it is above a reserve of
/// zero by definition.
func best(providerID: String, in snapshot: Snapshot, primaryModel: String? = nil,
          excluding: Set<String> = [], reserves: AccountReserves = .none,
          now: Date = Date()) -> Snapshot.Account? {
    // The nearly-dry gate runs first (AccountComfort.swift): a rate cannot tell "healthy" from
    // "1% left with a close reset", so accounts that are actually dry leave before the ordering.
    let eligibleAccounts = snapshot.accounts.filter {
        $0.provider == providerID && eligible($0, primaryModel: primaryModel)
            && !excluding.contains($0.id)
    }
    let reserves = aboveReserve(eligibleAccounts, primaryModel: primaryModel, reserves: reserves,
                                now: now).isEmpty ? .none : reserves
    let candidates = preferringComfortable(eligibleAccounts, primaryModel: primaryModel,
                                           reserves: reserves, now: now)
    guard var leader = candidates.first else { return nil }
    var leaderScore = smartScore(leader, primaryModel: primaryModel, reserves: reserves, now: now)
    for candidate in candidates.dropFirst() {
        let score = smartScore(candidate, primaryModel: primaryModel, reserves: reserves, now: now)
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
///
/// A RESERVE BINDS THE CHALLENGERS AND NOT THE INCUMBENT, which falls out of the seeding rather than
/// being a rule of its own and is the right answer either way: a session already ON the personal
/// account is not moved by this station (that is the idle rebalance's job, once per drought), and
/// nothing may be moved onto an account under its line.
func incumbentSeededBest(providerID: String, in snapshot: Snapshot, incumbentID: String,
                         primaryModel: String?, excluding: Set<String> = [],
                         reserves: AccountReserves = .none,
                         now: Date = Date()) -> Snapshot.Account? {
    let candidates = snapshot.accounts.filter {
        $0.provider == providerID && eligible($0, primaryModel: primaryModel)
            && !excluding.contains($0.id)
    }
    // The incumbent can't serve the new model (or was quarantined): no incumbent to stabilize, so
    // fall back to the plain best of what remains.
    guard var leader = candidates.first(where: { $0.id == incumbentID }) else {
        return best(providerID: providerID, in: snapshot, primaryModel: primaryModel,
                    excluding: excluding, reserves: reserves, now: now)
    }
    var leaderScore = smartScore(leader, primaryModel: primaryModel, reserves: reserves, now: now)
    let challengers = requiringComfortable(candidates.filter { $0.id != incumbentID },
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
func capHandoffTarget(_ eligibleAccounts: [Snapshot.Account], primaryModel: String?,
                      reserves: AccountReserves = .none,
                      now: Date = Date()) -> Snapshot.Account? {
    requiringComfortable(eligibleAccounts, primaryModel: primaryModel, reserves: reserves, now: now)
        .max { smartScore($0, primaryModel: primaryModel, reserves: reserves, now: now)
            < smartScore($1, primaryModel: primaryModel, reserves: reserves, now: now) }
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
                quarantined: Set<String>, reserves: AccountReserves = .none,
                now: Date = Date()) -> Snapshot.Account? {
    best(providerID: providerID, in: snapshot, primaryModel: primaryModel,
         excluding: quarantined, reserves: reserves, now: now)
        ?? best(providerID: providerID, in: snapshot, primaryModel: primaryModel,
                reserves: reserves, now: now)
}
