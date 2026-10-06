import Foundation

/// The store's thresholds for the fold below, kept beside it so the store stays a caller.
enum LastGoodThresholds {
    /// Only flag "Outdated" after this many consecutive failures. A single miss - e.g. the brief window
    /// while the CLI rotates the OAuth token, which 1-minute polling reliably catches - keeps showing the
    /// last-good numbers unbadged, so the badge stops flickering on every token refresh.
    static let staleAfterFailures = 2
    /// No numbers yet: "Reading quota, retrying" until this many failures in a row. Relaunch polls every
    /// account at once; 2026-10-06 two read empty and recovered within 4 minutes. Signed-out accounts
    /// still get LoginStatusStore's own alert.
    static let bareErrorAfterFailures = 3
}

/// What one refresh round leaves on an account when the poll failed: the last good numbers, plus a
/// machine-readable note saying they are held over rather than freshly fetched.
///
/// TWO AUDIENCES READ THE SAME ROUND AND NEED OPPOSITE ANSWERS, which is why the fold publishes
/// several facts about one failure. The person looking at the card is served by DEBOUNCE: a single
/// miss (the brief window while the CLI rotates an OAuth token, which one-minute polling catches)
/// must not flash an "Outdated" badge, so `isStale` waits for a second consecutive failure. A
/// supervisor deciding whether to move a session is served by the reverse: it has to know on the
/// FIRST failure, because between the first and the second the numbers look freshly fetched and are
/// not, and one of the readings it acts on is "no quota left" (`accountIsSpent`,
/// TallyCLI/AccountPick.swift, where the cost of believing a held-over zero is spelled out).
///
/// So `lastRefreshFailed` is set on every failing round from the first, and the badge's debounce is
/// left exactly where it was. One field could not have served both: the debounce is a presentation
/// decision about flicker, and a presentation decision that doubles as the fact channel hands the
/// machine a minute of staleness it cannot see. The badge remains the backstop for readers old
/// enough to know only about it.
///
/// A round that SUCCEEDS clears the note, so the flag always describes this account's latest poll
/// rather than any poll it ever had.
///
/// `previous` nil is an account that has never succeeded IN THIS PROCESS: there are no numbers to
/// hold over, so the failure is returned as it arrived, flagged all the same, since what the flag
/// states is that the latest poll failed, which it did. Its short line is held back for the first
/// `bareErrorAfterFailures - 1` rounds and reads "Reading quota, retrying" instead: right after a
/// relaunch every account polls at once, and a /usage that comes back empty under that load clears
/// by itself a few rounds later, so the provider's own line ("run /login") would send the person
/// to fix nothing. The longer `errorDetail` is left as it arrived, so the real reason still hovers.
///
/// AND A THIRD READER ASKS NEITHER QUESTION. Both facts above are about the NUMBERS - are these
/// this moment's, are the held-over ones old enough to badge - so on the branch just described,
/// where there are none, both stay quiet about an account that has been failing since launch. That
/// account is exactly the one worth reporting, and `pollsKeepFailing` is what reports it: the same
/// streak, stated without mentioning numbers, on both branches. It is not a rename of the badge and
/// must not be folded into it - the badge staying false here is what keeps the card showing the
/// error and a Retry rather than an empty set of meters (`AccountFacts.isHardError`).
func foldLastGood(_ usage: AccountUsage, previous: AccountUsage?, failureStreak streak: Int,
                  staleAfterFailures: Int, bareErrorAfterFailures: Int) -> AccountUsage {
    guard usage.error != nil else {
        var fresh = usage
        fresh.lastRefreshFailed = false
        fresh.pollsKeepFailing = false
        return fresh
    }
    // The streak is a fact about the ACCOUNT, so it is read once, before the branch that asks
    // whether there are numbers to hold over. Only the badge below needs there to be some.
    let sustained = streak >= staleAfterFailures
    guard var previous else {
        var bare = usage
        bare.lastRefreshFailed = true
        // AND THE BADGE IS STILL NOT RAISED HERE, deliberately, however long the streak gets.
        // Three shipping surfaces read `error != nil && !isStale` as "this account has never
        // loaded": the card collapses to the message and a Retry (`AccountFacts.isHardError`), the
        // menu bar draws "!", and the hover names the error. Raising the badge to carry a streak
        // would turn all three off for the one account they exist for. The streak goes on the
        // field that does not mention numbers instead.
        bare.pollsKeepFailing = sustained
        if streak < bareErrorAfterFailures { bare.error = L("Reading quota, retrying") }
        return bare
    }
    // The numbers are stale; the identity need not be. Whatever this round established without the
    // poll (Claude reads plan and email from a local config file) replaces the last-good copy, so a
    // config dir signed in as somebody else stops showing the previous account's email. Nil means
    // this round could not tell, not that there is no identity, so it leaves the known value alone.
    if let plan = usage.planName { previous.planName = plan }
    if let email = usage.accountEmail { previous.accountEmail = email }
    previous.lastRefreshFailed = true
    previous.pollsKeepFailing = sustained
    if sustained {
        previous.isStale = true
        // The reason, shown as an "Outdated" tooltip. BOTH HALVES OF IT: the short line the badge
        // hovers and the longer WHY under it travel together or the second one never arrives on
        // the commonest path there is. An account with numbers behind it that starts failing is
        // folded here on every round, so a fold that carried only `error` would leave the last
        // GOOD round's `errorDetail` standing, which is nil, and the provider's reason would be
        // visible on no card that had ever loaded (`AccountUsage.errorDetail`, `CodexProvider`).
        previous.error = usage.error
        previous.errorDetail = usage.errorDetail
    }
    return previous
}
