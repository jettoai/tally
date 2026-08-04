import Foundation

// Assertion harness for the two rules an account row runs on:
//
//   - its login state (Tally/Core/AccountSignIn.swift): which of "sign in again", "renewing", or
//     nothing the row shows, from the three facts the app already holds. The rule is small and the
//     reason it exists is not: two independent sources say "signed out" and each sees a state the
//     other cannot, while a renewal already in flight has to outrank both. The card learned that
//     ordering from a live report; the Settings row now shares the answer instead of re-deriving it.
//   - its identity (Tally/Core/AccountIdentity.swift): which address the row shows, including on a
//     row nothing is polling.

var passed = 0, failed = 0
func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

// MARK: - Nothing wrong: the row says nothing

check("a signed-in account offers nothing",
      AccountSignIn.state(isRenewing: false, isExpired: false, isDormant: false) == .signedIn)

// MARK: - Either source alone is enough

// The probe asks the provider's CLI, so it sees a credential that expired inside a home that still
// looks complete to discovery.
check("the login probe alone raises it",
      AccountSignIn.state(isRenewing: false, isExpired: true, isDormant: false) == .needsSignIn)
// Discovery sees a home whose login is gone entirely - which is exactly the account the probe can
// no longer ask about, so waiting for the probe would leave this row silent.
check("dormancy alone raises it",
      AccountSignIn.state(isRenewing: false, isExpired: false, isDormant: true) == .needsSignIn)
check("both agreeing is still one answer",
      AccountSignIn.state(isRenewing: false, isExpired: true, isDormant: true) == .needsSignIn)

// MARK: - A renewal in flight outranks both

// Offering to start a sign-in that is already running is the bug this ordering exists to prevent:
// the button would fire a second renewal against the same home.
check("a running renewal replaces the offer",
      AccountSignIn.state(isRenewing: true, isExpired: true, isDormant: true) == .renewing)
check("even before either source has noticed",
      AccountSignIn.state(isRenewing: true, isExpired: false, isDormant: false) == .renewing)

// MARK: - …and so does a renewal that just SUCCEEDED, until discovery agrees

// The race: on success the store drops the in-flight flag and clears the expired verdict in the
// same breath, but discovery only catches up when the refresh behind it finishes - and a refresh
// coalesced into one already running returns immediately without having re-discovered anything. In
// that window all three original inputs said "offer a sign-in" about an account that had just been
// signed in, and a second click fired a second login into the same config home.
let renewedAt = Date(timeIntervalSince1970: 1_000_000)
let justAfter = renewedAt.addingTimeInterval(2)
check("a success still settling does not offer another sign-in",
      AccountSignIn.state(isRenewing: false, isExpired: false, isDormant: true,
                          renewalSucceededAt: renewedAt, now: justAfter) == .renewing)
// The moment discovery agrees the row is done waiting - it does not sit out the rest of the window.
check("and the row is finished the moment discovery agrees",
      AccountSignIn.state(isRenewing: false, isExpired: false, isDormant: false,
                          renewalSucceededAt: renewedAt, now: justAfter) == .signedIn)
// Bounded, so a login that reported success but silently did not land is offered again rather than
// leaving the row saying "renewing" for the rest of the session.
check("a settle that never lands gives the offer back",
      AccountSignIn.state(isRenewing: false, isExpired: false, isDormant: true,
                          renewalSucceededAt: renewedAt,
                          now: renewedAt.addingTimeInterval(AccountSignIn.settleWindow + 1))
          == .needsSignIn)
check("the window is long enough for a coalesced refresh to finish",
      AccountSignIn.settleWindow >= 60)
// An account that was never renewed is unaffected: the fourth input is absent, not false.
check("an account with no renewal behind it is unchanged",
      AccountSignIn.state(isRenewing: false, isExpired: false, isDormant: true,
                          renewalSucceededAt: nil, now: justAfter) == .needsSignIn)
// Only dormancy is bridged. An expired verdict is cleared synchronously by the same success, so a
// row still reading "expired" after one is reporting something the settle does not know about.
check("a fresh expiry after a successful renewal is still an expiry",
      AccountSignIn.state(isRenewing: false, isExpired: true, isDormant: false,
                          renewalSucceededAt: renewedAt, now: justAfter) == .needsSignIn)

// MARK: - Which address the row shows

// Live answers first, and in that order. A memory that outranked either would keep the previous
// address on a config home that has since been signed into as somebody else.
check("the probe's answer wins over everything older",
      AccountIdentity.email(probe: "now@example.com", polled: "poll@example.com",
                            remembered: "old@example.com") == "now@example.com")
check("this round's poll wins over the memory",
      AccountIdentity.email(probe: nil, polled: "poll@example.com",
                            remembered: "old@example.com") == "poll@example.com")
check("an account nothing could name has no address",
      AccountIdentity.email(probe: nil, polled: nil, remembered: nil) == nil)

// MARK: - The memory, which is what a switched-off row reads

var memory = AccountIdentityMemory()
check("an account never seen has no remembered address", memory.email("codex:.codex2") == nil)
check("learning an address is a change worth persisting",
      memory.remember(accountID: "codex:.codex2", email: "alex@example.com"))
check("and it is the answer from then on", memory.email("codex:.codex2") == "alex@example.com")
check("hearing the same address again changes nothing",
      memory.remember(accountID: "codex:.codex2", email: "alex@example.com") == false)

// The case the memory exists for: a disabled account is never polled, so nothing live can name it,
// and the Settings row is exactly where somebody asks which login this is.
check("a switched-off account still names itself",
      AccountIdentity.email(probe: nil, polled: nil,
                            remembered: memory.email("codex:.codex2")) == "alex@example.com")

// A round that could not name the account knows LESS than the previous one did, so it must not
// blank a row that was already answered. One failed poll would otherwise clear every disabled row.
check("a round with no answer does not erase the memory",
      memory.remember(accountID: "codex:.codex2", email: nil) == false)
check("nor does one answering with an empty address",
      memory.remember(accountID: "codex:.codex2", email: "") == false)
check("so the address is still there", memory.email("codex:.codex2") == "alex@example.com")

// Switched back on: the account is polled again, and the fresh reading replaces what was kept -
// including when the home was signed into as somebody else while it was off.
check("a fresh reading replaces the remembered one",
      memory.remember(accountID: "codex:.codex2", email: "dana@example.com"))
check("and the row shows the new address",
      AccountIdentity.email(probe: nil, polled: "dana@example.com",
                            remembered: memory.email("codex:.codex2")) == "dana@example.com")

// Accounts are remembered one by one, not as one answer for the machine.
memory.remember(accountID: "claude:.claude", email: "work@example.com")
check("each account is remembered on its own",
      memory.email("codex:.codex2") == "dana@example.com"
          && memory.email("claude:.claude") == "work@example.com")

// A REMOVED account is forgotten outright: a recreated home takes the same id, and the previous
// account's address on the new one's row would be a lie the user cannot correct.
check("forgetting a removed account is a change", memory.forget(accountID: "codex:.codex2"))
check("and it takes the address with it", memory.email("codex:.codex2") == nil)
check("forgetting it twice changes nothing", memory.forget(accountID: "codex:.codex2") == false)
check("the other account is untouched", memory.email("claude:.claude") == "work@example.com")

// It survives a relaunch, which is the other half of "switched off before the last quit".
let restored = try! JSONDecoder().decode(AccountIdentityMemory.self,
                                         from: JSONEncoder().encode(memory))
check("the memory round-trips through storage", restored == memory)
check("and still names the account afterwards", restored.email("claude:.claude") == "work@example.com")

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
