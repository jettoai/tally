import Foundation

// Which rows from the previous refresh survive into this one.
//
// A refresh does not always speak for every account: the enablement set can change while the CLIs
// run, so a provider switched ON mid-flight has rows nobody fetched this round. Those are carried
// over from the previous round rather than blinked away, and the queued follow-up replaces them
// with live data.
//
// The carry has one hard limit, which is the whole reason it is a named rule rather than a filter
// inline: an account this round no longer KNOWS about is gone, not unfetched. A config home the
// user deleted is dropped by the memory (KnownAccounts.swift) and by discovery at the same moment,
// so it appears in neither `fetched` nor `known` - and a carry that only asked "was this fetched?"
// answered no and put the card straight back, every round, until the app restarted. The panel and
// the snapshot kept a ghost the Settings list could no longer act on.

/// The previous round's rows worth keeping: still on an enabled provider, not fetched this round,
/// and still an account this machine has.
func carriedAccountRows(previous: [AccountUsage], fetched: Set<String>, known: Set<String>,
                        enabledProviders: Set<String>) -> [AccountUsage] {
    previous.filter {
        enabledProviders.contains($0.providerID) && !fetched.contains($0.id) && known.contains($0.id)
    }
}
