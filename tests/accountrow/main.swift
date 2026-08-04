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

// MARK: - …and so does a renewal that just SUCCEEDED, until discovery agrees (RenewalSettling)

// The race: on success the store drops the in-flight flag and clears the expired verdict in the
// same breath, but discovery only catches up when the refresh behind it finishes - and a refresh
// coalesced into one already running returns immediately without having re-discovered anything. In
// that window every input said "offer a sign-in" about an account that had just been signed in,
// and a second click fired a second login into the same config home.
//
// The set lives in the store and feeds the SAME `isRenewing` above, which is the point: the offer
// has four entry points, and the first version of this fix guarded one of them.
var settling = RenewalSettling()
let renewed = "codex:.codex2"
let other = "claude:.claude"

check("an account nothing renewed is not settling", settling.contains(renewed) == false)
check("a success starts one", settling.begin(renewed, isDormant: true))
check("and the account counts as renewing from then on", settling.contains(renewed))
// Only an account discovery still calls signed out: for any other one the expired verdict was
// cleared by the same success, so there is no gap and "renewing" would be an invented state.
check("a success on an account discovery already calls fine starts nothing",
      settling.begin("claude:.claude3", isDormant: false) == false
          && settling.contains("claude:.claude3") == false)
check("the row therefore offers nothing while it settles",
      AccountSignIn.state(isRenewing: settling.contains(renewed), isExpired: false,
                          isDormant: true) == .renewing)
check("starting the same one twice is not a second deadline",
      settling.begin(renewed, isDormant: true) == false)
check("and it says nothing about any other account", settling.contains(other) == false)

// Discovery is the better witness: an account it no longer calls dormant is signed in again, so
// the settling ends NOW rather than running out the deadline.
settling.begin(other, isDormant: true)
check("discovery keeps the accounts it still calls signed out",
      settling.discovered(dormant: [renewed]) && settling.contains(renewed)
          && settling.contains(other) == false)
check("a round that changes nothing reports no change",
      settling.discovered(dormant: [renewed]) == false)
check("and the account it agreed about offers the sign-in again",
      AccountSignIn.state(isRenewing: settling.contains(other), isExpired: false,
                          isDormant: true) == .needsSignIn)

// Bounded the other way too: a login that reported success but silently did not land has its
// deadline run out, and the offer comes back.
check("the deadline ends it", settling.end(renewed))
check("ending it twice changes nothing", settling.end(renewed) == false)
check("so the offer is back",
      AccountSignIn.state(isRenewing: settling.contains(renewed), isExpired: false,
                          isDormant: true) == .needsSignIn)
check("the window is long enough for a coalesced refresh to finish", RenewalSettling.window >= 60)
// …and short enough that it is a safety net rather than the normal path (discovery ends it first).
check("and short enough not to be the normal way out", RenewalSettling.window <= 300)

// A settling account that discovery has NOTHING to say about (it vanished entirely, which is what
// a removal looks like) stops settling too: there is no row left to protect.
var vanished = RenewalSettling(["codex:.codex9"])
check("an account discovery no longer lists at all stops settling",
      vanished.discovered(dormant: []) && vanished.contains("codex:.codex9") == false)

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

// MARK: - The line UNDER the address, for when the address is not the answer

// Every rule below is stated against THIS home, never the one the machine running the test happens
// to have: an assertion that "/Volumes/work/codex-team" reads as an outside path is only true until
// somebody's home IS /Volumes/work, and an open-source contributor's machine is not ours to assume.
let fixtureHome = "/Users/fixture"

// The case it exists for: one ChatGPT login in a personal workspace and in a team's is two accounts
// answering with ONE email, and the provider names no organization Tally could add. Plan and config
// home are what is left, and they do separate them.
let personal = AccountIdentity.detail(plan: "Pro", home: fixtureHome + "/.codex",
                                      userHome: fixtureHome)
let team = AccountIdentity.detail(plan: "Team", home: fixtureHome + "/.codex2",
                                  userHome: fixtureHome)
check("two logins on one address still read as two accounts", personal != team)
// Even on the same plan, which is the harder half: the plan is often identical, the home never is.
check("and they do when the plan matches too",
      AccountIdentity.detail(plan: "Pro", home: fixtureHome + "/.codex", userHome: fixtureHome)
          != AccountIdentity.detail(plan: "Pro", home: fixtureHome + "/.codex2",
                                    userHome: fixtureHome))

// Composition, against the fixture home so the abbreviation is exercised end to end.
check("both parts, one separator",
      AccountIdentity.detail(plan: "Team", home: fixtureHome + "/.codex2", userHome: fixtureHome)
          == "Team · ~/.codex2")
check("a plan nobody reported leaves the home alone",
      AccountIdentity.detail(plan: nil, home: fixtureHome + "/.codex", userHome: fixtureHome)
          == "~/.codex")
check("and an account with no home reads as its plan",
      AccountIdentity.detail(plan: "Max 20x", home: nil) == "Max 20x")
// Nil rather than an empty string: the surfaces render NOTHING for nil, and an empty second line
// under an address reads as a rendering fault.
check("an account neither could describe has no second line",
      AccountIdentity.detail(plan: nil, home: nil) == nil)
check("an empty answer is the same as no answer",
      AccountIdentity.detail(plan: "", home: nil) == nil)

// MARK: - …and how a home is written there

check("a home inside the user's own is abbreviated",
      AccountIdentity.homeName("/Users/fixture/.codex2", userHome: "/Users/fixture") == "~/.codex2")
check("the home directory itself is just the tilde",
      AccountIdentity.homeName("/Users/fixture", userHome: "/Users/fixture") == "~")
// A path that merely STARTS with the home directory's characters is a different directory, and
// abbreviating it would produce a path that does not exist.
check("a sibling directory with a longer name is left alone",
      AccountIdentity.homeName("/Users/fix2/.codex", userHome: "/Users/fix") == "/Users/fix2/.codex")
// Said the other way for the longer one, which the length rule below shortens: whatever it comes
// back as, it must not be the tilde form, because that would name a directory nobody has.
check("and a long one is still not read as being inside the home",
      AccountIdentity.homeName("/Users/fixture2/.codex", userHome: "/Users/fixture")
          .hasPrefix("~") == false)
check("a path outside the home is left as it is",
      AccountIdentity.homeName("/opt/codex", userHome: "/Users/fixture") == "/opt/codex")
check("and no tilde is invented when there is no home to speak of",
      AccountIdentity.homeName("/opt/codex", userHome: "") == "/opt/codex")

// MARK: - …and a home that is somewhere else entirely (a custom CODEX_HOME)

// Returning one of these in full is what the rule is shaped around: the card's callout sizes itself
// to its text and would run past the 380pt panel, and the Settings row truncates from the END -
// which cuts off the directory name that is the whole reason the home is on screen.
check("a long home outside the user's own keeps its last segment",
      AccountIdentity.homeName("/Volumes/work/codex-team", userHome: "/Users/fixture")
          == "…/codex-team")
// The segment itself is never shortened: whatever the user called that directory IS the answer.
check("and that segment is never itself cut",
      AccountIdentity.homeName("/Volumes/shared/clients/acme/codex-home-for-acme",
                               userHome: "/Users/fixture") == "…/codex-home-for-acme")
// Short enough to read as it is: an ellipsis would cost information and buy nothing.
check("a short outside home is left whole",
      AccountIdentity.homeName("/opt/codex", userHome: "/Users/fixture") == "/opt/codex")
check("and so is one directly under the root",
      AccountIdentity.homeName("/opt", userHome: "/Users/fixture") == "/opt")
// Nothing to drop, so nothing is dropped - an ellipsis longer than what it replaces is not shorter.
check("a long single-segment path has no parent to give up",
      AccountIdentity.homeName("/codex-home-on-this-machine-for-work", userHome: "/Users/fixture")
          == "/codex-home-on-this-machine-for-work")
check("a trailing slash is not mistaken for the last segment",
      AccountIdentity.homeName("/Volumes/work/codex-team/", userHome: "/Users/fixture")
          == "…/codex-team")
// The same cap applies under the home too: a deep custom home there overflows the same callout.
check("a long home under the user's own is shortened the same way",
      AccountIdentity.homeName("/Users/fixture/Documents/work/codex-team", userHome: "/Users/fixture")
          == "…/codex-team")

// The point of all of it: an outside home and a numbered one still read as two different accounts.
check("an outside home and a numbered one stay apart",
      AccountIdentity.detail(plan: "Team", home: "/Volumes/work/codex-team", userHome: fixtureHome)
          != AccountIdentity.detail(plan: "Team", home: fixtureHome + "/.codex2",
                                    userHome: fixtureHome))
check("and the outside one reads as a plan and a place",
      AccountIdentity.detail(plan: "Team", home: "/Volumes/work/codex-team", userHome: fixtureHome)
          == "Team · …/codex-team")

// The default is the machine's own home, which is what every caller on screen relies on. Said with
// a path built FROM that home, so the assertion holds wherever the test is run - the point here is
// that the parameter defaults to a home at all, not which one this machine has.
check("a caller that names no home gets this machine's",
      AccountIdentity.detail(plan: "Team", home: NSHomeDirectory() + "/.codex2")
          == "Team · ~/.codex2")

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
