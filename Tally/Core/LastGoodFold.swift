import Foundation

/// What one refresh round leaves on an account when the poll failed: the last good numbers, plus a
/// machine-readable note saying they are held over rather than freshly fetched.
///
/// TWO AUDIENCES READ THE SAME ROUND AND NEED OPPOSITE ANSWERS, which is why the fold publishes two
/// facts about one failure. The person looking at the card is served by DEBOUNCE: a single miss (the
/// brief window while the CLI rotates an OAuth token, which one-minute polling reliably catches)
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
/// `previous` nil is an account that has never succeeded: there are no numbers to hold over, so the
/// failure is returned as it arrived, carrying its own bare error. It is flagged all the same, since
/// what the flag states is that the latest poll failed, which it did.
func foldLastGood(_ usage: AccountUsage, previous: AccountUsage?, failureStreak streak: Int,
                  staleAfterFailures: Int) -> AccountUsage {
    guard usage.error != nil else {
        var fresh = usage
        fresh.lastRefreshFailed = false
        return fresh
    }
    guard var previous else {
        var bare = usage
        bare.lastRefreshFailed = true
        return bare
    }
    // The numbers are stale; the identity need not be. Whatever this round established without the
    // poll (Claude reads plan and email from a local config file) replaces the last-good copy, so a
    // config dir signed in as somebody else stops showing the previous account's email. Nil means
    // this round could not tell, not that there is no identity, so it leaves the known value alone.
    if let plan = usage.planName { previous.planName = plan }
    if let email = usage.accountEmail { previous.accountEmail = email }
    previous.lastRefreshFailed = true
    if streak >= staleAfterFailures {
        previous.isStale = true
        previous.error = usage.error  // reason, shown as an "Outdated" tooltip
    }
    return previous
}
