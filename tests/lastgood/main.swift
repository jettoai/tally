import Foundation

// Assertion harness for what a failed refresh publishes (Tally/Core/LastGoodFold.swift).
//
// THE BEHAVIOUR UNDER TEST is one round told to two audiences. The card is debounced: a single
// missed poll (the seconds while the CLI rotates an OAuth token) keeps the last-good numbers with
// no "Outdated" badge, so the badge does not flicker. A supervisor is not: it decides whether to
// move a session off an account that reads 0%, and between the first failure and the second the
// numbers look freshly fetched and are not. That interval is a real one, at least a poll apart,
// and every idle supervisor on the account reads the same held-over zero inside it (codex review
// of 54eebaa, the second finding: the CLI guard added there only saw the badge, which had not
// been raised yet).
//
// So the fold sets `lastRefreshFailed` on the FIRST failure and leaves `isStale` on its two, and
// these checks hold the two apart at every step: the failure that is not yet a badge, the one that
// is, and the success that clears both.

var passed = 0, failed = 0
func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

let fetched = Date(timeIntervalSince1970: 1_700_000_000)
let window = UsageMetric(id: "weekly", kind: .weeklyAll, label: "Weekly", modelName: nil,
                         usedPercent: 100, severity: .critical, resetsAt: nil, isActive: true)
/// A good round: real numbers, no error. The metric is a spent weekly window on purpose, because
/// the reading this whole fold protects is exactly the one that says "nothing left here".
let good = AccountUsage(id: "A", providerID: "claude", accountLabel: "Claude",
                        planName: "Max 20x", accountEmail: "a@example.com",
                        metrics: [window], refreshedAt: fetched)
/// The same account's failing round: providers return the failure rather than throwing, so it
/// arrives with no metrics at all and an error string.
let failure = AccountUsage.failure(account: ProviderAccount(id: "A", providerID: "claude",
                                                            label: "Claude", locator: [:]),
                                   providerID: "claude", message: "network down")

func fold(_ usage: AccountUsage, previous: AccountUsage?, streak: Int) -> AccountUsage {
    foldLastGood(usage, previous: previous, failureStreak: streak, staleAfterFailures: 2)
}

// MARK: - A successful round

let fresh = fold(good, previous: nil, streak: 0)
check("a successful round keeps its own numbers", fresh.metrics.first?.remainingPercent == 0)
check("…and reports that the latest poll did not fail", !fresh.lastRefreshFailed)
check("…and is not badged", !fresh.isStale && fresh.error == nil)

// MARK: - The first failure: the numbers are held over, and it says so

// This is the whole point of the field. The card must look unchanged here, so nothing about the
// PRESENTATION may move; the machine-readable fact must move immediately, because the interval
// this state lasts is the one in which a supervisor would act on the zero above.
let first = fold(failure, previous: fresh, streak: 1)
check("a first failure keeps the last-good numbers", first.metrics.first?.remainingPercent == 0)
check("…and says the latest refresh failed, with no debounce at all", first.lastRefreshFailed)
check("…while the badge has not moved", !first.isStale)
check("…nor the tooltip behind it", first.error == nil)
check("…so the card is unchanged, which is what the debounce is for",
      first.isStale == fresh.isStale && first.error == fresh.error
          && first.metrics == fresh.metrics)

// MARK: - The second failure: now the person is told too

let second = fold(failure, previous: first, streak: 2)
check("a sustained failure raises the badge", second.isStale)
check("…with the reason behind it", second.error == "network down")
check("…and the flag is still set, rather than handed over to the badge",
      second.lastRefreshFailed)

// MARK: - Recovery clears both

// The flag describes THIS account's latest poll, not any poll it ever had: a reader that saw it
// set once and never cleared would refuse to believe the account for the rest of the session.
var recovered = good
recovered.isStale = true
recovered.lastRefreshFailed = true
let healed = fold(recovered, previous: second, streak: 0)
check("a round that succeeds clears the flag", !healed.lastRefreshFailed)

// MARK: - An account that never succeeded

// Nothing to hold over, so the failure is returned as it arrived: a bare error, which the app has
// always shown immediately rather than debounced. It is flagged all the same, since what the flag
// states is that the latest poll failed.
let never = fold(failure, previous: nil, streak: 1)
check("an account that never succeeded keeps its bare error", never.error == "network down")
check("…and has no numbers to be believed", never.metrics.isEmpty)
check("…and is flagged too, because its latest poll did fail", never.lastRefreshFailed)
// The badge, asserted rather than assumed: this branch never raises it, and three surfaces read
// that as "this account has never loaded" (see the sustained case below, which is where raising it
// would actually be tempting).
check("…while its badge stays down, which is what keeps the card on the error and a Retry",
      !never.isStale)

// MARK: - …and the streak reaches that branch too

// THE THIRD FACT, and the reason it exists. Both fields above are about NUMBERS - are these this
// moment's, are the held-over ones old enough to badge - so on a branch that has none, neither of
// them could ever say that a signed-in account has been failing every poll since launch. That is
// the one account a "something is wrong here" reader most wants named, and before this field it was
// the one account no reader could see (codex review of 60a4fe7).
let neverAgain = fold(failure, previous: nil, streak: 2)
check("a never-succeeded account whose failures are sustained says so", neverAgain.pollsKeepFailing)
check("…while one missed round does not, which is the badge's own debounce",
      !never.pollsKeepFailing)
// AND THE BADGE STAYS DOWN HERE, permanently and on purpose. `AccountFacts.isHardError` is
// `error != nil && !isStale`, and it is what collapses a never-loaded card to the message and a
// Retry button (the menu bar's "!" mark and the hover's error line read the same pair). Raising the
// badge to carry the streak would have taken all three away from the only accounts they are for.
check("…and the badge is still not raised, so the card keeps its error and its Retry",
      !neverAgain.isStale && neverAgain.error == "network down" && neverAgain.metrics.isEmpty)

// The held-over branch answers the same question the same way, which is what lets one reader ask
// one field and get both kinds of broken account.
check("a sustained failure over good numbers says it too", second.pollsKeepFailing)
check("…a first failure over them does not", !first.pollsKeepFailing)
check("…and a round that succeeds clears it, like the flag beside it", !healed.pollsKeepFailing)

// MARK: - The identity a failed round did establish still lands

// Unchanged behaviour, asserted because the fold moved file: a config dir signed in as somebody
// else corrects the email while the numbers stay held over.
var reidentified = failure
reidentified.accountEmail = "b@example.com"
let renamed = fold(reidentified, previous: fresh, streak: 1)
check("a failed round still replaces the identity it could establish",
      renamed.accountEmail == "b@example.com")
check("…and leaves what it could not tell alone", renamed.planName == "Max 20x")

// MARK: - The flag reaches the CLI, which is the only reason it exists

// The snapshot is the app→CLI channel, so a fact the fold sets and the publisher drops is a fact
// nobody downstream can read.
let published = UsageSnapshot.make(accounts: [first, fresh], launchHomes: ["A": "/tmp/A"])
check("the published row carries the held-over flag",
      published.accounts.first?.lastRefreshFailed == true)
check("…and a healthy row publishes false rather than nothing, which is a different sentence",
      published.accounts.last?.lastRefreshFailed == false)
// nil is reserved for an app that predates the field: a reader must be able to tell "the poll
// succeeded" from "this writer cannot answer", because it treats them differently.
check("…so nil is left to mean cannot tell",
      UsageSnapshot.Account(id: "A", provider: "claude", label: "A", isStale: false)
          .lastRefreshFailed == nil)

// MARK: - The store is really wired to this fold

// The streak counters stay in the store, so the wiring cannot be compiled in here; without this
// the checks above would pass against a function nobody calls.
let storeSource = (try? String(contentsOfFile: "Tally/Stores/UsageStore.swift", encoding: .utf8))
    ?? ""
check("the store source is readable from these checks", !storeSource.isEmpty)
check("the failing branch folds through this function with its own streak",
      storeSource.contains("foldLastGood(usage, previous: lastGood[usage.id], failureStreak: streak,"))
check("…and the successful branch through it too, so recovery clears the flag",
      storeSource.contains("foldLastGood(usage, previous: nil, failureStreak: 0,"))
check("…and the badge's debounce is still the store's own constant",
      storeSource.contains("staleAfterFailures: Self.staleAfterFailures")
          && storeSource.contains("staleAfterFailures = 2"))

// MARK: - The reader the third fact was added for

// Asserted from here because THIS suite is the one that knows the two fields apart: the early-start
// suite hands its rule a fixture and cannot tell which field the app fills in, so a consumer that
// went back to asking the badge would pass there while silently never seeing a never-succeeded
// account again. Read as the one line the rule is, so a rule that grew a second one fails loudly
// rather than being matched by a prefix.
let earlyStartSource = (try? String(contentsOfFile: "Tally/Core/EarlyStart.swift", encoding: .utf8))
    ?? ""
let keepsFailingRule = earlyStartSource.components(separatedBy: "func readingKeepsFailing")
    .dropFirst().first?.components(separatedBy: "\n").first ?? ""
check("the early-start row asks this fact rather than the badge",
      keepsFailingRule.contains("usage.pollsKeepFailing")
          && !keepsFailingRule.contains("usage.isStale"))

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
