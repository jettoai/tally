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

// MARK: - What the LIST says when it has no rows at all (AccountListState.swift)

// The bug: an empty list was read as an answer. On a cold start - which every self-update performs,
// and which is when somebody opens Settings to see what survived - discovery has not run yet, and
// the pane told a user with five accounts that it found none.
check("nothing found and nothing asked is not an answer",
      AccountListState.resolve(hasDiscovered: false, accountCount: 0) == .discovering)
check("nothing found AFTER a pass is",
      AccountListState.resolve(hasDiscovered: true, accountCount: 0) == .empty)
check("accounts are drawn once there are any",
      AccountListState.resolve(hasDiscovered: true, accountCount: 3) == .populated)
// A set can arrive from the config-dir watcher rather than a refresh, and rows already in hand are
// never withheld waiting for the flag to catch up.
check("rows in hand outrank the flag",
      AccountListState.resolve(hasDiscovered: false, accountCount: 1) == .populated)

// MARK: - …and that the two halves of it are actually wired up

// The rule is only worth having if the store really reports the fact and the pane really asks for
// it; neither end compiles into this harness (one is @Observable and @MainActor, the other is a
// SwiftUI view), so the wiring is checked as text - the same way the login suite does it.
func readSource(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}
let storeSource = readSource("Tally/Stores/UsageStore.swift")
let paneSource = readSource("Tally/Views/SettingsAccountsView.swift")

/// One member's body, cut at its own closing brace at type-member indentation - so a match
/// elsewhere in the file (the demo branch also sets this flag) cannot stand in for this one.
func memberBody(_ source: String, from declaration: String) -> String {
    guard let start = source.range(of: declaration),
          let end = source.range(of: "\n    }", range: start.upperBound ..< source.endIndex)
    else { return "" }
    return String(source[start.upperBound ..< end.lowerBound])
}

check("the one route every discovered set is adopted through reports the pass",
      memberBody(storeSource, from: "private func adoptDiscovered")
          .contains("discoveredAccounts = accounts")
          && memberBody(storeSource, from: "private func adoptDiscovered")
          .contains("hasDiscovered = true"))
check("a demo run, whose refresh replaces the pass entirely, still gets a final answer",
      storeSource.range(of: "if DemoUsage.isActive \\{[^}]*hasDiscovered = true",
                        options: .regularExpression) != nil)
check("the pane asks the rule rather than reading emptiness as an answer",
      paneSource.contains("AccountListState.resolve(hasDiscovered: store.hasDiscovered")
          && paneSource.contains("if state != .populated"))
check("and the sentence is only ever reachable through that rule",
      paneSource.components(separatedBy: "No signed-in accounts found").count == 2
          && paneSource.contains("state == .discovering ? L(\"Loading…\")"))
// The pane opens before the first round finishes, so it asks for the pass itself instead of
// waiting out every provider CLI that round polls.
check("the pane starts the discovery it needs",
      paneSource.contains(".onAppear { store.ensureDiscovered() }")
          && storeSource.contains("func ensureDiscovered()"))
check("…once, and never on a demo instance",
      storeSource.contains("guard !hasDiscovered, !DemoUsage.isActive else { return }"))

// MARK: - The menu-bar switch, in the layout where it decides nothing

// The pooled layout's segment sums EVERY account of a provider, so the per-account "Menu bar"
// switch has nothing to pick between there - the strip reads `orderedAccounts` and never asks it
// (UsageStorePresentation). Left live it would be a silent no-op: flip it, nothing moves in the
// bar, and nothing on screen says why. So it is disabled, and the hover carries the way back.
// Checked as text for the reason the section above gives - a SwiftUI view does not compile in here.
//
// It lives one file over from the rest of the pane (the row's status strip was split out of it for
// file size), which is why this reads a source of its own: a member body cut out of the wrong file
// is an empty string, and an empty string satisfies every `!contains` in here.
let rowStatusSource = readSource("Tally/Views/SettingsAccountRowStatus.swift")
check("the row's status strip is readable from these checks", !rowStatusSource.isEmpty)
check("the switch is dead exactly when the layout is pooled",
      rowStatusSource.contains("let pooled = settings.menuBarLayout == .pooled")
          && memberBody(rowStatusSource, from: "func menuBarToggle").contains(".disabled(pooled)"))
// NOT SILENTLY: a greyed control with no explanation is the same dead end one step later.
check("…and says why, with the way back in it",
      rowStatusSource.contains(".help(pooled")
          && rowStatusSource.contains("Set Menu bar shows to Accounts in Display to pick which ones appear."))
check("the label greys with the control it labels",
      memberBody(rowStatusSource, from: "func menuBarToggle")
          .contains(".opacity(pooled ? 0.55 : 1)"))
// And it is still a live switch in the layout that asks the question.
check("the per-account layout keeps the switch usable",
      memberBody(rowStatusSource, from: "func menuBarToggle")
          .contains("settings.setShownInMenuBar(accountID, $0)")
          && !memberBody(rowStatusSource, from: "func menuBarToggle").contains(".disabled(true)"))
// The sentence names two things the Display pane really shows, so it cannot send anyone looking
// for a control that is not there.
let displaySource = readSource("Tally/Views/SettingsDisplayPane.swift")
check("the display pane is readable from these checks", !displaySource.isEmpty)
check("the hover points at wording the Display pane actually uses",
      displaySource.contains("L(\"Menu bar shows\")")
          && displaySource.contains("Text(L(\"Accounts\")).tag(MenuBarLayout.perAccount)"))


// MARK: - The personal account and its reserve (Tally/Core/AccountReserve.swift)

// ONE ACCOUNT MAY BE MARKED as the one the user also browses claude.ai on, and given a water line
// Tally's own choices may not spend past. The rules are pure so the whole state table below can be
// asserted without a state file: every combination of {nothing marked, A marked, A -> B, unmarked}
// against {reserve 0, 30, 100} and against that account later being removed.
typealias Block = [String: AccountRoleSetting]
let homeA = "/Users/x/.claude"
let homeB = "/Users/x/.claude2"

// Nothing marked - which is every machine until somebody says otherwise.
let empty = Block()
check("nobody is the personal account until somebody is marked",
      AccountRoles.personalHome(empty) == nil && !AccountRoles.isPersonal(empty, home: homeA))
check("…and an unmarked account reserves nothing", AccountRoles.reserve(empty, home: homeA) == 0)
check("…and asking about no home at all is not an error either",
      AccountRoles.personalHome(empty) == nil && !AccountRoles.isPersonal(empty, home: nil)
          && AccountRoles.reserve(empty, home: nil) == 0)

// A marked, with no reserve yet: the marking is one answer and the water line is another.
let markedA = AccountRoles.settingPersonal(empty, home: homeA)
check("marking an account names it and nothing else",
      AccountRoles.personalHome(markedA) == homeA && AccountRoles.isPersonal(markedA, home: homeA)
          && !AccountRoles.isPersonal(markedA, home: homeB))
check("…and it starts at no reserve at all", AccountRoles.reserve(markedA, home: homeA) == 0)

// The water line, at each end of its range and past both.
let reserved = AccountRoles.settingReserve(markedA, home: homeA, percent: 30)
check("the marked account takes a reserve", AccountRoles.reserve(reserved, home: homeA) == 30)
check("…100 is legal: Tally then never picks it by itself",
      AccountRoles.reserve(AccountRoles.settingReserve(markedA, home: homeA, percent: 100),
                           home: homeA) == 100)
check("…and anything past either end is clamped rather than stored",
      AccountRoles.reserve(AccountRoles.settingReserve(markedA, home: homeA, percent: 250),
                           home: homeA) == 100
          && AccountRoles.reserve(AccountRoles.settingReserve(markedA, home: homeA, percent: -20),
                                  home: homeA) == 0)
// Zero clears the key rather than storing it: absent and zero are the same answer, and the shorter
// one is the one an older reader cannot misread.
check("…and zero leaves nothing behind in the document",
      AccountRoles.settingReserve(reserved, home: homeA, percent: 0)[homeA]?.reserve == nil)

// AN ACCOUNT THAT DOES NOT HOLD THE ROLE HAS NO RESERVE, in both directions: the stepper cannot
// write one, and a document that somehow carries one is not read as one. The control lives on the
// marked row and nowhere else, so a reserve anywhere else is a setting with no surface that could
// show it, change it, or explain it.
check("an unmarked account cannot be given a reserve",
      AccountRoles.settingReserve(markedA, home: homeB, percent: 30) == markedA)
check("…and a hand-edited one on an unmarked account is not read either",
      AccountRoles.reserve([homeB: AccountRoleSetting(role: nil, reserve: 40)], home: homeB) == 0)

// A -> B. The marking is single select, and the reserve goes with it.
let movedToB = AccountRoles.settingPersonal(reserved, home: homeB)
check("marking another account moves the role rather than adding a second",
      AccountRoles.personalHome(movedToB) == homeB && !AccountRoles.isPersonal(movedToB, home: homeA))
check("…and the old account keeps no reserve, nor an entry to hold one",
      movedToB[homeA] == nil && AccountRoles.reserve(movedToB, home: homeA) == 0)
check("…while the newly marked one starts fresh at zero",
      AccountRoles.reserve(movedToB, home: homeB) == 0)

// Unmarking, which leaves the document as empty as it started.
check("unmarking empties the block rather than leaving a husk in it",
      AccountRoles.settingPersonal(reserved, home: nil).isEmpty)
check("…and a home that normalizes to nothing is the same instruction as nil",
      AccountRoles.settingPersonal(reserved, home: "   ").isEmpty)

// THE ACCOUNT BEING REMOVED OUT FROM UNDER THE MARKING. Keyed by a directory, exactly like the
// Artifact publishing account beside it, so the id-shaped forgetting cannot reach it: left standing,
// the entry marks a folder in the Trash as the account this machine browses on, and hands the role
// plus a number nobody chose to the next `~/.claudeN` created in that slot.
check("removing the marked account clears it",
      AccountRoles.removingHome(reserved, home: homeA).isEmpty)
check("…recognised through the same normalization the CLI compares homes with",
      AccountRoles.removingHome(reserved, home: homeA + "/").isEmpty
          && AccountRoles.removingHome(AccountRoles.settingPersonal(empty, home: homeA + "/"),
                                       home: homeA).isEmpty)
check("removing any other account leaves the marking exactly as it was",
      AccountRoles.removingHome(reserved, home: homeB) == reserved)
check("…and a home that is a prefix of it is another account",
      AccountRoles.removingHome(AccountRoles.settingPersonal(empty, home: homeB), home: homeA)
          == AccountRoles.settingPersonal(empty, home: homeB))
check("…and a home that normalizes to nothing clears nothing",
      AccountRoles.removingHome(reserved, home: "   ") == reserved)

// The lookup itself goes through that normalization on BOTH sides, because this key is written from
// the app's own discovery and asked about with whatever a caller happens to hold.
check("a marking is found through a trailing slash",
      AccountRoles.isPersonal(reserved, home: homeA + "/")
          && AccountRoles.reserve(reserved, home: homeA + "//") == 30)
// And a document with two of them still answers the same thing on every read, rather than following
// a dictionary's iteration order. Only a hand edit can produce this; the setter never does.
let twoRoles: Block = [homeB: AccountRoleSetting(role: AccountRoles.personal, reserve: nil),
                       homeA: AccountRoleSetting(role: AccountRoles.personal, reserve: nil)]
check("a hand-edited document with two markings answers one of them, always the same one",
      (0 ..< 20).allSatisfy { _ in AccountRoles.personalHome(twoRoles) == homeA })

// The document itself: only the keys that carry something, so a marked account with no reserve
// writes no reserve key at all and every reader's "absent means zero" stays true.
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
func written(_ entry: AccountRoleSetting?) -> String {
    String(data: (try? encoder.encode(entry ?? AccountRoleSetting())) ?? Data(),
           encoding: .utf8) ?? ""
}
check("an entry writes exactly what was set",
      written(reserved[homeA]) == "{\"reserve\":30,\"role\":\"personal\"}")
check("…and a marking with no reserve writes no reserve key",
      written(markedA[homeA]) == "{\"role\":\"personal\"}")
check("…and the block decodes back to the same answers",
      (try? JSONDecoder().decode(Block.self, from:
        (try? encoder.encode(reserved)) ?? Data()))
          .map { AccountRoles.reserve($0, home: homeA) } == 30)

// MARK: - …and the surfaces are really wired to those rules

let facts = readSource("Tally/Views/AccountFacts.swift")
let reserveRowSource = readSource("Tally/Views/SettingsPersonalAccountRow.swift")
let policySource = readSource("Tally/Stores/LaunchPolicyStore.swift")
check("the personal-account sources are readable from here",
      !facts.isEmpty && !reserveRowSource.isEmpty && !policySource.isEmpty)
// THE STEPPER APPEARS ON THE MARKED ROW AND NOWHERE ELSE. A pane that always carried the line would
// be asking a question a single-account machine cannot answer.
check("the pane draws the reserve row only under the marked account",
      paneSource.contains("PersonalAccount.isPersonal(accountID: item.id, home: home) {")
          && paneSource.components(separatedBy: "reserveRow(home,").count == 2)
// One reading for every surface, so a bar cannot draw a water line the pane says is not there.
check("both meters ask the shared reading rather than the store directly",
      facts.contains("PersonalAccount.isPersonal(") && facts.contains("PersonalAccount.reserve(")
          && !readSource("Tally/Views/MetricRowView.swift").contains("LaunchPolicyStore")
          && !readSource("Tally/Views/AccountListRowView.swift").contains("LaunchPolicyStore"))
// The removal reaches this block as well as the Artifact setting beside it - the one other thing in
// that file keyed by a directory rather than by an account id.
check("removing an account puts this block through the rule above",
      policySource.contains("accountSettings = AccountRoles.removingHome(accountSettings, home: home)"))
// And the two things the marking answers stay in step: the CLI reads `artifactAccount` first, so a
// marking that did not write it would be a marking artifacts ignore.
check("marking an account also answers the Artifact row",
      memberBody(policySource, from: "func setPersonalAccount")
          .contains("artifactAccount = chosen"))

// THE DOCUMENT ITSELF IS THE CONTRACT, and it is written by one process and read by another: the app
// publishes `~/.tally/state.json` and the `tally` supervisor steers real launches by it. THE TWO
// HALVES ARE NO LONGER MIRRORED IN TEXT - they compile the ONE file that holds the rules
// (Tally/Core/AccountReserve.swift, listed under both targets in project.yml), which is the
// arrangement ArtifactHookContract.swift already has and for the same reason. A rule spelled once per
// target is a rule that can come to mean two things, and this one decides quota: read literally, a
// second spelling is a water line the launcher walks straight through, or quota held back on an
// account whose Settings row shows none. That drift was real for a day and is what this convergence
// closed (2026-08-20: the CLI read a reserve off an unmarked account, the app read the same entry as
// zero).
//
// So what is checked here is that the CLI reader DELEGATES rather than re-spells. Both files are
// asserted readable first: an empty string satisfies nothing below, but it would satisfy a
// `!contains`, and two of these are that.
check("the app publishes the block at the top level, and omits it while it is empty",
      policySource.contains("var accounts: [String: AccountRoleSetting]?")
          && policySource.contains("accounts: accountSettings.isEmpty ? nil : accountSettings"))
let cliReader = readSource("TallyCLI/AccountReserveReader.swift")
check("the CLI's reader of that block is readable from here", !cliReader.isEmpty)
check("…and decodes it into the shared entry type rather than one of its own",
      cliReader.contains("var accounts: [String: AccountRoleSetting]?"))
check("…and asks the shared rules for both answers it gives",
      cliReader.contains("AccountRoles.reserve(settings, home: account.launchHome)")
          && cliReader.contains("AccountRoles.personalHome(settings)"))
// The negative half, which is the one that actually holds the line: no second role word, no second
// clamp, no second normalization. Any of the three coming back is the drift returning.
check("…and spells no rule of its own",
      !cliReader.contains("= \"personal\"") && !cliReader.contains("min(max(")
          && !cliReader.contains("artifactAccountHome("))
let generator = readSource("project.yml")
check("the project definition is readable from here", !generator.isEmpty)
// The app compiles it by living in `Tally/`; the CLI has to be told, so THAT is the line that can go
// missing, and going missing is a build failure rather than a drift - which is the point of moving
// the rules here rather than mirroring them.
check("…and the CLI target is told to compile the one file the rules live in",
      generator.contains("- path: Tally/Core/AccountReserve.swift")
          && readSource("Tally/Core/AccountReserve.swift")
              .contains("static let personal = \"personal\""))

// EVERY WORD OF THE NEW ROW IS IN THE CATALOGUE, in all four translations: the app ships five
// languages, and a sentence that reaches somebody in English on a Japanese machine is a missing
// translation nobody notices until they see it.
let catalogue = (try? Data(contentsOf: URL(fileURLWithPath:
    "Tally/Resources/Localizable.xcstrings")))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
let catalogueStrings = catalogue?["strings"] as? [String: Any] ?? [:]
check("the string catalogue is readable from this suite", !catalogueStrings.isEmpty)
for word in ["Personal", "Personal account (web)", "Keep at least %lld%% for web use",
             "Kept for web use",
             "Tally leaves this much of the account's quota alone when it picks or moves sessions "
                 + "by itself. Launching on it yourself always works.",
             "The account you are signed into on claude.ai. Tally publishes artifacts from it, and "
                 + "can keep part of its quota free for you."] {
    let entry = catalogueStrings[word] as? [String: Any]
    let localizations = entry?["localizations"] as? [String: Any] ?? [:]
    check("\(word.prefix(30)) is translated into every language Tally ships",
          ["zh-Hant", "zh-Hans", "ja", "ko"].allSatisfy { localizations[$0] != nil })
}

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
