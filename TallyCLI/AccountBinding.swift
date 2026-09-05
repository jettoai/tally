import Foundation

// WHICH WINDOW IS THIS ACCOUNT'S PROBLEM, and what that answer is worth: the readings taken through
// the nearly-dry gate's own scale, split out of AccountPick.swift for file size. The scoring and the
// picks built on it stay there; nothing here reads a file or touches the environment.
//
// The seam is "how hard can this account be pushed" (AccountPick.swift, a rate) against "how close
// is its wall" (here, an effective remaining). Two different questions with two different answers on
// the same account, which is why `pickReason` and `windowReason` can name different windows and both
// be right.
//
// EVERY READING HERE IS RESERVE-AWARE, through the one subtraction in `effectiveRemaining`
// (AccountComfort.swift). Callers hand in the reserves they are entitled to apply: a decision Tally
// made for itself passes the fleet's, a path a person named an account on passes `.none`
// (AccountReserve.swift states that rule in full). WHICH WINDOWS carry one is settled before any of
// this, where the windows are built (`ratedWindows`): the weekly all-models window, the 5h session
// one and the flagship model's do, so nothing here has to know the difference.

/// One rated window as the nearly-dry gate (AccountComfort.swift) sees it, keyed on the ANCHOR: the
/// gate asks when the wall comes down, and a flagship window with no reset of its own hits the
/// account's weekly wall. Reading the reported field instead would exempt the weekly window and
/// refuse the flagship one for the same moment.
///
/// The reserve rides across with it, so the gate weighs the same windows the score did.
///
/// One conversion for the whole CLI, so everything that asks the gate about a window weighs it the
/// same way: the account gate below, and the rebalance cycle key, which names the window this gate
/// reacted to - and names it by the REPORTED reset, an identity every supervisor agrees on rather
/// than a judgement.
func comfortWindow(_ window: RatedWindow) -> ComfortWindow {
    ComfortWindow(remaining: window.remaining, resetsAt: window.anchor, reserve: window.reserve)
}

/// What the nearly-dry gate weighs for a CLI account: exactly the windows `ratedWindows` counts for
/// the declared primary model, so the gate never re-decides which windows an account spends. Shared
/// by both gate policies, so they can differ in what they do with an empty result and in nothing
/// else.
private func comfortWindows(_ account: Snapshot.Account, primaryModel: String?,
                            reserves: AccountReserves, now: Date) -> [ComfortWindow] {
    ratedWindows(account, primaryModel: primaryModel, reserves: reserves, now: now)
        .map(comfortWindow)
}

/// The launch-side gate: drops the nearly dry, keeps the field whole when nothing is comfortable.
func preferringComfortable(_ accounts: [Snapshot.Account], primaryModel: String?,
                           reserves: AccountReserves = .none,
                           now: Date) -> [Snapshot.Account] {
    preferringComfortable(accounts, now: now) {
        comfortWindows($0, primaryModel: primaryModel, reserves: reserves, now: now)
    }
}

/// The move-side gate: comfortable candidates only, and none when there are none.
///
/// THIS IS WHERE "AN AUTOMATIC MOVE NEVER LANDS BELOW SOMEBODY'S RESERVE" IS ENFORCED, and it costs
/// no rule of its own: an account under its line has an effective remaining of zero or less, and
/// zero is under the 5% the gate already draws. The empty answer means "wait", which is what every
/// mover already does when no sibling has room.
func requiringComfortable(_ accounts: [Snapshot.Account], primaryModel: String?,
                          reserves: AccountReserves = .none,
                          now: Date) -> [Snapshot.Account] {
    requiringComfortable(accounts, now: now) {
        comfortWindows($0, primaryModel: primaryModel, reserves: reserves, now: now)
    }
}

/// Whether ONE account still has room to work in, by exactly the gate the picks apply to candidates
/// (imminent-reset exemption included). Asked of the account a session already RUNS on, which the
/// filtering helpers above cannot answer: they take a field and return a field.
func accountIsComfortable(_ account: Snapshot.Account, primaryModel: String?,
                          reserves: AccountReserves = .none, now: Date = Date()) -> Bool {
    isComfortable(comfortWindows(account, primaryModel: primaryModel, reserves: reserves, now: now),
                  now: now)
}

/// The window that BINDS an account: its emptiest counted window, by the effective remaining the
/// nearly-dry gate weighs rather than by the raw percentage. A session window at 3% resetting in
/// five minutes is a full window to that gate, and a reader told the account is dying because of it
/// would be told something the gate does not believe.
///
/// One derivation for every caller that asks "which window is this account's problem": the
/// rebalance keys its per-drought claim on it, and the advisory knock quotes it. nil when the
/// account reports no counted windows at all.
func bindingWindow(_ account: Snapshot.Account, primaryModel: String?,
                   reserves: AccountReserves = .none, now: Date = Date()) -> RatedWindow? {
    ratedWindows(account, primaryModel: primaryModel, reserves: reserves, now: now)
        .min { effectiveRemaining(comfortWindow($0), now: now)
                 < effectiveRemaining(comfortWindow($1), now: now) }
}

/// Whether an account is SPENT rather than merely nearly dry: its binding window has no effective
/// remaining at all, so there is no work left on it to be had. The far end of the same scale
/// `accountIsComfortable` reads, beside it for that reason.
///
/// TWO READERS. The rebalance claim (Rebalance.swift), where a spent account is exempt from the
/// one-move-per-drought record: what justifies refusing a move there is that the cap handoff will
/// make it later, and a cap handoff needs a turn to hit a wall, which an idle session on an empty
/// account never produces. And the drought watch (DroughtWatch.swift), where the same reading is
/// the one state in which a pin stops protecting anything - the same argument one scope up, since
/// waiting for the cap is waiting for a turn to be lost.
///
/// EFFECTIVE remaining, through the gate's own scale rather than a raw percentage, which is what
/// keeps the exemption honest at both ends. A window minutes from resetting reads as FULL there, so
/// "0% resetting in five minutes" is not a spent account and the claim still governs it; and it
/// asks about the same window the claim keys on, so the exemption and the record can never disagree
/// about which window made the account dry.
///
/// A RESERVE COUNTS HERE TOO, and that is a ruling rather than a side effect (2026-08-20): an
/// account under the line its owner drew - in its WEEK or in the 5h window it shares with their
/// browser (2026-09-02) - is spent AS FAR AS TALLY IS CONCERNED, which is the only sense this
/// function has ever been asked in. A spent flagship window makes an account spent on its own
/// merits, reserve or no reserve, which is what it always did. Its one reader exempts such an
/// account from the per-drought claim, and the whole of that argument carries: the cap handoff
/// cannot rescue an idle session either way, and the sessions this releases are precisely the ones
/// the reserve exists to get off the account. One scale for the gate and for this, or "dying" would
/// mean two things.
///
/// ZERO AND NOT THE 5% LINE, deliberately. The stampede the claim exists to stop is a real drought,
/// and 1% is one - the 2026-08-02 double move ran on a 1% window. What changes at zero is not how
/// dry the account is but what NOT moving costs, which is the whole of the argument above.
///
/// An account reporting no counted windows is not spent. Nothing is known about it, and an
/// exemption invented out of missing data is a move made on evidence nobody has.
///
/// NEITHER IS A HELD-OVER ONE, the same sentence about missing data wearing the clothes of a
/// reading. A failed refresh keeps the last good numbers (`foldLastGood`, Core/LastGoodFold.swift),
/// so a zero left from before the failure is spelled exactly like one read a moment ago, and every
/// idle supervisor on that account holds it on the same tick: exempted together they land on one
/// sibling at once, the stampede the claim was written to stop. It asks `lastRefreshFailed` rather
/// than the badge because `isStale` waits for a second consecutive failure so the app's "Outdated"
/// badge cannot flicker on a token rotation, and that debounce leaves a poll interval in which a
/// failed round is published looking like a successful one. Badge and `error` stay behind it for
/// the sustained case and for snapshots older than the flag, where nil is "cannot tell" and the
/// first failing round is still unannounced: a gap closed by updating the app, not by guessing.
///
/// THOSE THREE GUARDS COME FIRST WHATEVER THE RESERVE SAYS. A reserve is a preference read off a
/// file; it is not evidence about quota, and it must not be the thing that makes a held-over zero
/// actionable.
func accountIsSpent(_ account: Snapshot.Account, primaryModel: String?,
                    reserves: AccountReserves = .none, now: Date = Date()) -> Bool {
    guard account.lastRefreshFailed != true, account.error == nil, !account.isStale,
          let binding = bindingWindow(account, primaryModel: primaryModel, reserves: reserves,
                                      now: now)
    else { return false }
    return effectiveRemaining(comfortWindow(binding), now: now) <= 0
}

/// One window as a person reads it: "weekly 32% · resets 2d", and without the tail when the
/// provider published no reset time. Its own function because two sentences quote a window - the
/// reason behind a pick, and the advisory knock's news about the account a session is on - and two
/// spellings of the same reading is how they would come to disagree about what 32% of a week means.
///
/// THE PROVIDER'S OWN PERCENTAGE, never the reserve-adjusted one. What a person is owed here is the
/// reading their provider published; "weekly 32%" has to mean the same thing in this sentence, in
/// the panel and on claude.ai, and a reserve is Tally's arithmetic rather than news about the
/// account. Same rule, and the same field split, as the inferred anchor that `resetsAt` refuses to
/// carry.
func windowReason(_ window: RatedWindow, now: Date = Date()) -> String {
    var text = "\(window.name) \(Int(window.remaining.rounded()))%"
    if let resetsAt = window.resetsAt {
        text += " · resets \(shortETA(resetsAt.timeIntervalSince(now)))"
    }
    return text
}

// MARK: - The reserve, read through the same scale

/// Whether this account still has quota ABOVE the line its owner drew: EVERY window that carries
/// the number, read through the gate's own scale.
///
/// THE QUESTION IS ABOUT THE LINE, so it is asked of exactly the windows the line is drawn on - the
/// weekly all-models one, the 5h session one and the flagship model's (`AccountRoles.carriesReserve`
/// settles which, and the builders apply it). Asked of every window instead, a window nobody drew a
/// line on would answer "below its water line" and a launch onto it would announce a dip into a
/// reserve it never touched: a sentence about the owner's preference, printed for a window the
/// preference says nothing about.
///
/// ALL OF THEM RATHER THAN THE FIRST ONE FOUND, which is what the arrival of a second reserved
/// window changed here. Reading one would leave it to the order `ratedWindows` happens to build its
/// array in which of the lines actually binds, and the ones it skipped would be crossed in silence -
/// the water line the launcher walks straight through, arrived at by array index. So this is asked
/// as "is the crossed set empty" (`crossedReserves` below), which has no first element to be
/// tempted by.
///
/// The far end of `accountIsSpent` without its trust guards, and that difference is the point of
/// having both. That one is asked of the account a session is RUNNING on, where acting on numbers
/// held over from a failed poll moves every idle session at once; this is asked of CANDIDATES, which
/// have already been through `eligible` (a failed poll, a stale row and an errored one are all
/// refused there), so asking again would only be a second spelling of the same filter.
///
/// An account reporting no reserved window at all is treated as above its line: nothing is known
/// about it, and refusing it on the strength of missing data is the mistake `accountIsSpent` names.
func aboveReserve(_ account: Snapshot.Account, primaryModel: String?,
                  reserves: AccountReserves, now: Date = Date()) -> Bool {
    crossedReserves(account, primaryModel: primaryModel, reserves: reserves, now: now).isEmpty
}

/// The reserved windows this account is UNDER the line on, in the order they are rated.
///
/// ONE DERIVATION FOR THE TWO QUESTIONS asked about that line - may an automatic pick take this
/// account, and what does a launch that took it anyway have to say - so the gate and the sentence
/// can never come to disagree about which window was crossed. Everything the two of them state
/// between them is in the doc above and in `reserveDipNotice` below.
///
/// Empty is "above every line it has", which is also the answer for an account nobody reserved
/// anything on and for one reporting no reserved window at all.
private func crossedReserves(_ account: Snapshot.Account, primaryModel: String?,
                             reserves: AccountReserves, now: Date) -> [RatedWindow] {
    guard reserves.reserve(for: account) > 0 else { return [] }
    return ratedWindows(account, primaryModel: primaryModel, reserves: reserves, now: now)
        .filter { $0.reserve > 0 && effectiveRemaining(comfortWindow($0), now: now) <= 0 }
}

/// The candidates an automatic MOVE may land on: everything still above its own reserve.
///
/// Its own helper because two picks need it that do not go through the nearly-dry gate at all - the
/// degradation rescue and `tally resume`, both of which rank on a bare score. Everything that does
/// go through that gate gets this for free: a reserve pushes the effective remaining to zero or
/// below, and zero is under the 5% line by any reading.
func aboveReserve(_ accounts: [Snapshot.Account], primaryModel: String?,
                  reserves: AccountReserves, now: Date = Date()) -> [Snapshot.Account] {
    accounts.filter { aboveReserve($0, primaryModel: primaryModel, reserves: reserves, now: now) }
}

/// The one line a launch prints when it had to spend somebody's reserve, or nil when it did not.
///
/// SAID OUT LOUD, EVERY TIME, because the alternative is the failure this feature exists to prevent
/// wearing a different hat: a person who set a reserve and is never told it was crossed learns about
/// it in the browser, at the moment they have no quota and no idea why. It costs one line of stderr
/// on a fleet that is out of room anyway.
///
/// It names the account and the size of the reserve rather than how far in the launch went: the
/// reader's next act is either to stop working or to accept it, and neither turns on the depth.
///
/// AND IT NAMES THE WINDOW IT CROSSED, which is what the arrival of a second reserved window made
/// load-bearing. Three lines are drawn now (`aboveReserve` above, and AccountReserve.swift for the
/// ruling), and they mean different things to the reader: a week that will not refill for days, a
/// 5h window their browser shares and that comes back this afternoon, or the flagship pool they do
/// their own thinking in. A fixed "weekly" would have named the wrong one most of the time, and a
/// bare "reserve" would leave them looking at three bars wondering which. The names are the
/// windows' own, so the sentence and the meters agree.
///
/// Crossing more than one at once says all of them, in the order the windows are rated, rather than
/// picking a winner: the reader is owed the whole of what the launch just spent.
func reserveDipNotice(_ account: Snapshot.Account, primaryModel: String?,
                      reserves: AccountReserves, now: Date = Date()) -> String? {
    let crossed = crossedReserves(account, primaryModel: primaryModel, reserves: reserves, now: now)
    guard !crossed.isEmpty else { return nil }
    let reserve = reserves.reserve(for: account)
    return "dipping into \(account.label)'s \(crossed.map(\.name).joined(separator: " and ")) "
        + "reserve (\(Int(reserve.rounded()))% kept for web use)"
}
