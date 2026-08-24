import Foundation

// Assertion harness for the login-expiry alert: the pure verdict rules and the dedup state machine
// (Tally/Core/LoginStatusCommand.swift), the spawn that feeds them (Tally/Core/CLIRunner.swift),
// and the wiring that turns a verdict into a chip, a click and one notification.
//
// The probe is exercised against STUB CLIs written by this file, never a real account: the two real
// commands are read-only, but a test that depends on this machine's login state passes for reasons
// that have nothing to do with the code. The stubs print exactly what the real CLIs printed when
// they were measured (claude 2.1.220 and codex-cli 0.146.0, 2026-08-03), including which STREAM
// each answers on, which is the whole reason the runner had to learn to capture stderr.
//
// The fixtures below are verbatim captures, not paraphrases:
//   claude --strict-mcp-config auth status   → stdout JSON, exit 0 / 1
//   codex login status                       → stderr one line, exit 0 / 1

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func readSource(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// One member's body, dug out by its own closing brace at type-member indentation - the way the
/// redeem and renewal suites do it, rather than scanning a whole file where an unrelated call
/// elsewhere in the type would read as a match.
func functionBody(_ source: String, from declaration: String) -> String? {
    guard let start = source.range(of: declaration),
          let end = source.range(of: "\n    }", range: start.upperBound ..< source.endIndex)
    else { return nil }
    return String(source[start.upperBound ..< end.lowerBound])
}

// MARK: the probe commands

expect(LoginStatusCommand.arguments(providerID: "claude") == ["--strict-mcp-config", "auth", "status"],
       "claude is asked through its own auth subcommand, with the host's MCP config kept out")
expect(LoginStatusCommand.arguments(providerID: "codex") == ["login", "status"],
       "codex is asked through its own login subcommand")
expect(LoginStatusCommand.arguments(providerID: "gemini") == nil,
       "a provider with no known status command is not guessed at")
// Same placement rule the renewal shipped a release to learn (13ade3a): a GLOBAL option written
// after the subcommand is rejected as unknown. This probe is in fact the command that measured it.
if let arguments = LoginStatusCommand.arguments(providerID: "claude"),
   let mcpGuard = arguments.firstIndex(of: "--strict-mcp-config"),
   let subcommand = arguments.firstIndex(of: "auth") {
    expect(mcpGuard < subcommand,
           "the global --strict-mcp-config precedes `auth`, where the main command parses it")
} else {
    expect(false, "claude's probe carries both the MCP guard and the auth subcommand")
}

// MARK: reading the answer

let claudeSignedIn = """
{
  "loggedIn": true,
  "authMethod": "claude.ai",
  "apiProvider": "firstParty",
  "email": "alex@example.com",
  "orgId": "d637b994-34be-420e-b565-356f4df16ba7",
  "orgName": "alex@example.com's Organization",
  "subscriptionType": "max"
}
"""
let claudeSignedOut = """
{
  "loggedIn": false,
  "authMethod": "none",
  "apiProvider": "firstParty"
}
"""

expect(LoginStatusCommand.read(exitCode: 0, output: claudeSignedIn)
        == LoginStatusCommand.Reading(verdict: .signedIn, email: "alex@example.com"),
       "claude's live status reads as signed in, and names the account while it is there")
expect(LoginStatusCommand.read(exitCode: 1, output: claudeSignedOut)
        == LoginStatusCommand.Reading(verdict: .signedOut, email: nil),
       "claude's signed-out status reads as signed out")
expect(LoginStatusCommand.read(exitCode: 0, output: "Update available: 2.2.0\n" + claudeSignedIn)
        .verdict == .signedIn,
       "a notice printed above the JSON does not cost the answer")

expect(LoginStatusCommand.read(exitCode: 0, output: "Logged in using ChatGPT\n").verdict == .signedIn,
       "codex's live status line reads as signed in")
expect(LoginStatusCommand.read(exitCode: 1, output: "Not logged in\n").verdict == .signedOut,
       "codex's signed-out line reads as signed out")
// The ordering trap: every signed-out phrase CONTAINS a signed-in one, so a matcher that looked for
// "logged in" first would call an expired account healthy and the alert would never fire at all.
expect(LoginStatusCommand.signedOutMarkers.contains(where: { marker in
    LoginStatusCommand.signedInMarkers.contains { marker.contains($0) }
}), "the two marker sets do overlap, which is why signed-OUT is matched first")
expect(LoginStatusCommand.read(exitCode: 1, output: "\u{1B}[31mNot logged in\u{1B}[0m\n")
        .verdict == .signedOut,
       "a status line wrapped in colour codes is still one run of plain text")

// The conservative direction, and the reason there is no path from an exit code alone to
// "expired": a CLI that broke on its own config file exits non-zero too, and reporting THAT as an
// expired login would put a red chip and a notification on an account that is perfectly fine.
expect(LoginStatusCommand.read(exitCode: 1,
                               output: "error: failed to parse config.toml at line 4\n")
        .verdict == .unknown,
       "a CLI that failed for its own reasons is not reported as an expired login")
expect(LoginStatusCommand.read(exitCode: 0, output: "").verdict == .signedIn,
       "a status subcommand that exits 0 with nothing to say is reporting a healthy account")
expect(LoginStatusCommand.read(exitCode: nil, output: "").verdict == .unknown,
       "a probe that could not be started at all says nothing about the login")

// MARK: the spawn - stub CLIs, run for real

let stubs = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("tally-logincheck-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)

func stub(_ name: String, _ body: String) -> String {
    let url = stubs.appendingPathComponent(name)
    try? ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

/// The whole path the app runs: spawn the CLI, join both streams, read a verdict.
func probe(_ executable: String, arguments: [String] = [],
           environment: [String: String?] = [:]) async -> LoginStatusCommand.Reading {
    let output = await CLIRunner.run(executable, arguments: arguments, environment: environment,
                                     timeout: 20)
    return LoginStatusCommand.read(exitCode: output?.exitCode,
                                   output: (output?.stdout ?? "") + "\n" + (output?.stderr ?? ""))
}

let claudeStub = stub("claude", """
cat <<'JSON'
\(claudeSignedOut)
JSON
exit 1
""")
expect(await probe(claudeStub).verdict == .signedOut,
       "a claude-shaped CLI answering on stdout is read end to end, spawn included")

// stderr, and only stderr - which is where the real `codex login status` puts its entire answer.
// Before the runner captured this stream the same run could only ever come back `unknown`, so a
// Codex account's login could never be reported expired at all.
let codexStub = stub("codex", "printf 'Not logged in\\n' >&2\nexit 1\n")
expect(await probe(codexStub).verdict == .signedOut,
       "a codex-shaped CLI answering on STDERR is read end to end")
let codexLiveStub = stub("codex-live", "printf 'Logged in using ChatGPT\\n' >&2\nexit 0\n")
expect(await probe(codexLiveStub).verdict == .signedIn,
       "…and its live answer, on the same stream, reads as signed in")
expect(await probe(stubs.appendingPathComponent("nothing-here").path).verdict == .unknown,
       "a missing CLI is unknown, never expired")

// A chatty child must not be able to wedge the probe: the two streams are drained concurrently, and
// a version that read one to EOF while the other filled its pipe would wedge until the watchdog
// killed the child, losing the answer (which the CLI prints last) along with it.
//
// The count is load-bearing. A pipe holds 64 KB, so each stream has to exceed that on its own or
// the sequential version passes too - which is exactly what it did at 400 lines (32 KB), a mutant
// that survived until this stub was sized to the buffer it is about. 2000 x 81 bytes = ~162 KB.
let chattyStub = stub("chatty", """
i=0
while [ $i -lt 2000 ]; do
  printf '%s\\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >&2
  printf '%s\\n' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  i=$((i + 1))
done
printf 'Not logged in\\n' >&2
exit 1
""")
let chattyStart = Date()
expect(await probe(chattyStub).verdict == .signedOut,
       "a CLI that fills both pipes is drained rather than deadlocked")
expect(Date().timeIntervalSince(chattyStart) < 15,
       "…and answers promptly, not by hitting the watchdog")

// The environment reaches the child exactly as the renewal composes it - the point of the whole
// feature is that the answer is about THIS account's config home and no other.
let namedHome = "/tmp/a b/.claude2"
let envStub = stub("env-named", "[ \"$CLAUDE_CONFIG_DIR\" = \"\(namedHome)\" ] && exit 0\nexit 3\n")
expect(await probe(envStub, environment: RenewLoginCommand.environment(
    envKey: "CLAUDE_CONFIG_DIR", home: namedHome, providerID: "claude",
    userHome: URL(fileURLWithPath: "/Users/nobody"))).verdict == .signedIn,
       "a non-default home is handed over exactly, spaces intact, with no shell in between")
setenv("CLAUDE_CONFIG_DIR", "/leaked", 1)
let unsetStub = stub("env-unset", "[ -n \"${CLAUDE_CONFIG_DIR:-}\" ] && exit 3\nexit 0\n")
expect(await probe(unsetStub, environment: RenewLoginCommand.environment(
    envKey: "CLAUDE_CONFIG_DIR", home: "/Users/nobody/.claude", providerID: "claude",
    userHome: URL(fileURLWithPath: "/Users/nobody"))).verdict == .signedIn,
       "the DEFAULT home runs with the variable removed, beating one the app itself inherited")
unsetenv("CLAUDE_CONFIG_DIR")

// MARK: an account that signed OUT is still an account

// The trap the whole memory exists for: discovery is credential-shaped (a Claude home is an account
// because its Keychain login exists, a Codex home because its auth.json does), so the very event
// the alert reports - the credential going away - is also the event that removes the account from
// discovery. Nothing would be probed, no chip could light, and the renewal would have no home to
// point at, which is to say the feature could never fire for a real logout at all.

let liveHome = stubs.appendingPathComponent("home-still-here")
try? FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
let removedHome = stubs.appendingPathComponent("home-the-user-deleted").path
/// The same question `KnownAccountsStore` asks the filesystem, run against real paths here so the
/// "directory, specifically" part is not just a claim in a comment.
let onDisk: (String) -> Bool = { path in
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && isDirectory.boolValue
}
let signedIn = KnownAccount(id: "claude:.claude2", providerID: "claude", label: "Claude 2",
                            home: liveHome.path)

var (memory, dormant) = KnownAccountLogic.advance(remembered: [], discovered: [signedIn],
                                                  homeExists: onDisk)
expect(memory == [signedIn] && dormant.isEmpty,
       "an account that is signed in is simply written down, and is not dormant")

(memory, dormant) = KnownAccountLogic.advance(remembered: memory, discovered: [],
                                              homeExists: onDisk)
expect(dormant == [signedIn] && memory == [signedIn],
       "a home whose credential is gone stays on as a dormant account - which is what a logout IS")
expect(dormant.first?.home == liveHome.path,
       "…carrying the config home, because that is what the probe and the renewal both need")

let deleted = KnownAccount(id: "codex:.codex2", providerID: "codex", label: "Codex 2",
                           home: removedHome)
let (afterRemoval, removedDormant) = KnownAccountLogic.advance(remembered: [deleted],
                                                               discovered: [], homeExists: onDisk)
expect(removedDormant.isEmpty && afterRemoval.isEmpty,
       "a home the user actually deleted is forgotten, never reported as an expired login")

// A file where a config home used to be is not an account waiting to be signed back into.
let fileHome = stubs.appendingPathComponent("home-that-is-a-file").path
try? "not a directory".write(toFile: fileHome, atomically: true, encoding: .utf8)
let (_, fileDormant) = KnownAccountLogic.advance(
    remembered: [KnownAccount(id: "claude:.claude3", providerID: "claude", label: "Claude 3",
                              home: fileHome)],
    discovered: [], homeExists: onDisk)
expect(fileDormant.isEmpty, "…and neither is a plain file left at that path")

// What a dormant account may DO, which is the other half of remembering it. Its home is a RENEWAL
// home: the login probe asks about it and "Renew login" acts on it. It is not a LAUNCH home, and
// nothing until 2026-08-03 said so - the reconstruction was indistinguishable from a live account,
// so the panel let the user pin a signed-out home into `~/.tally/state.json`, and the `tally` CLI
// then exec'd claude into a directory with no credential in it.
let revived = ProviderAccount(dormant: signedIn)
expect(revived.isDormant, "an account rebuilt from the memory is marked dormant")
expect(revived.launchHome == liveHome.path,
       "…keeping the home the probe and the renewal both need")
expect(revived.launchableHome == nil,
       "…while having nothing a launch may use, which is what keeps it out of the pin and the pick")
expect(revived.id == signedIn.id && revived.label == signedIn.label && revived.locator.isEmpty,
       "…and carrying only what a renewal needs to name it")
let live = ProviderAccount(id: "claude:.claude", providerID: "claude", label: "Claude",
                           locator: [:], launchHome: "/Users/x/.claude")
expect(!live.isDormant && live.launchableHome == live.launchHome,
       "a discovered account is launchable at the home it was discovered in")
expect(KnownAccount(live)?.home == live.launchHome,
       "and it is remembered by that home")
expect(KnownAccount(ProviderAccount(id: "x", providerID: "claude", label: "x", locator: [:],
                                    launchHome: nil)) == nil,
       "while an account with no home at all is not worth remembering")

// MARK: - a card outlives its account by one round, and no longer

// A refresh does not always speak for every account (the enablement set can change while the CLIs
// run), so unfetched rows are carried over from the previous round. The limit that was missing
// (2026-08-03): an account this round no longer KNOWS about is gone, not unfetched. Deleting a
// config home drops it from discovery and from the memory at the same moment, so it is in neither
// set - and a carry that only asked "was this fetched?" put the card straight back, every round,
// until the app restarted, on a panel and in a snapshot the Settings list could no longer act on.
func row(_ id: String, _ providerID: String = "claude") -> AccountUsage {
    AccountUsage.failure(account: ProviderAccount(id: id, providerID: providerID, label: id,
                                                  locator: [:], launchHome: "/tmp/\(id)"),
                         providerID: providerID, message: "cached")
}
let previousRound = [row("claude:.claude"), row("claude:.claude2"), row("codex:.codex", "codex")]
let ghosted = carriedAccountRows(previous: previousRound, fetched: ["claude:.claude"],
                                 known: ["claude:.claude", "claude:.claude2"],
                                 enabledProviders: ["claude", "codex"])
expect(!ghosted.contains { $0.id == "codex:.codex" },
       "an account whose config home is gone leaves with it, rather than coming back as a ghost")
expect(ghosted.map(\.id) == ["claude:.claude2"],
       "…while an account this round simply did not fetch is still carried")
expect(carriedAccountRows(previous: previousRound, fetched: ["claude:.claude2"],
                          known: Set(previousRound.map(\.id)),
                          enabledProviders: ["claude"]).map(\.id) == ["claude:.claude"],
       "a provider switched off this round takes its rows with it")
expect(carriedAccountRows(previous: previousRound, fetched: Set(previousRound.map(\.id)),
                          known: Set(previousRound.map(\.id)),
                          enabledProviders: ["claude", "codex"]).isEmpty,
       "and a round that fetched everything carries nothing")

var renamed = signedIn
renamed.label = "the nickname it was signed back in under"
let (reconciled, noneDormant) = KnownAccountLogic.advance(remembered: [signedIn],
                                                          discovered: [renamed], homeExists: onDisk)
expect(reconciled == [renamed] && noneDormant.isEmpty,
       "signing back in wins over the memory, rather than the memory shadowing the live account")

// MARK: one notification per outage

let claudeID = "claude:.claude"
let codexID = "codex:.codex"
let known: Set<String> = [claudeID, codexID]

var (state, fresh) = LoginAlertLogic.advance(
    state: LoginAlertState(), verdicts: [claudeID: .signedOut, codexID: .signedIn], known: known)
expect(fresh == [claudeID], "an account that just went out is announced, and only that account")

(state, fresh) = LoginAlertLogic.advance(
    state: state, verdicts: [claudeID: .signedOut, codexID: .signedIn], known: known)
expect(fresh.isEmpty, "the same outage is not announced again on the next round")

(state, fresh) = LoginAlertLogic.advance(state: state, verdicts: [claudeID: .unknown], known: known)
expect(fresh.isEmpty && state.announced.contains(claudeID),
       "a round that could not tell changes nothing in either direction")
(state, fresh) = LoginAlertLogic.advance(state: state, verdicts: [claudeID: .signedOut],
                                         known: known)
expect(fresh.isEmpty,
       "…so an unknown round cannot silently re-arm an alert that would then fire twice")

(state, fresh) = LoginAlertLogic.advance(state: state, verdicts: [claudeID: .signedIn], known: known)
expect(state.announced.isEmpty, "signing back in clears the account")
(state, fresh) = LoginAlertLogic.advance(state: state, verdicts: [claudeID: .signedOut],
                                         known: known)
expect(fresh == [claudeID], "…and the NEXT outage is announced again, as a new event")

let rearmed = LoginAlertLogic.rearm(state: state, accountID: claudeID)
(_, fresh) = LoginAlertLogic.advance(state: rearmed, verdicts: [claudeID: .signedOut], known: known)
expect(fresh == [claudeID],
       "an alert the system refused was never seen, so the account stays armed")

let (pruned, _) = LoginAlertLogic.advance(state: state, verdicts: [:], known: [codexID])
expect(pruned.announced.isEmpty,
       "an account that no longer exists is forgotten rather than remembered forever")

// …which is exactly why `known` cannot be the list that was PROBED. A switched-off account is not
// probed (nobody wants processes spawned for one), so for as long as it is off it appears in
// neither the verdicts nor a probe-derived `known` - and the pruning above would then read its
// outage as over. Switching it back on without signing in would announce the same outage twice.
var offRound = LoginAlertState()
(offRound, fresh) = LoginAlertLogic.advance(state: offRound, verdicts: [claudeID: .signedOut],
                                            known: known)
expect(fresh == [claudeID], "the outage is announced once, while the account is switched on")
(offRound, fresh) = LoginAlertLogic.advance(state: offRound, verdicts: [:], known: known)
expect(offRound.announced.contains(claudeID) && fresh.isEmpty,
       "a round that could not probe it - switched off - does not end its outage")
(offRound, fresh) = LoginAlertLogic.advance(state: offRound, verdicts: [claudeID: .signedOut],
                                            known: known)
expect(fresh.isEmpty,
       "…so switching it back on, still signed out, is not a second announcement")

// MARK: the visible chain - a verdict must reach a chip, and a click must reach a renewal

let cardSource = readSource("Tally/Views/AccountCardView.swift")
let rowSource = readSource("Tally/Views/AccountListRowView.swift")
// The derivations both account surfaces run on - which home an action touches, whether the login is
// still good, which launch affordances apply - live in AccountFacts now, because the compact list
// row asks the very same questions and a second copy would be free to answer differently. So the
// chain this suite pins runs through three files rather than through the card's own body, and what
// it pins is that the chain exists and that no surface reaches past it, not which file a line is in.
let factsSource = readSource("Tally/Views/AccountFacts.swift")
let surfaceSource = cardSource + "\n" + rowSource + "\n" + factsSource
let storeSource = readSource("Tally/Stores/LoginStatusStore.swift")
let usageSource = readSource("Tally/Stores/UsageStore.swift")
let routerSource = readSource("Tally/App/NotificationRouter.swift")
let renewSource = readSource("Tally/Stores/RenewLoginStore.swift")
let memorySource = readSource("Tally/Stores/KnownAccountsStore.swift")
let watcherSource = readSource("Tally/Core/AccountDirWatcher.swift")
expect(!cardSource.isEmpty && !rowSource.isEmpty && !factsSource.isEmpty && !storeSource.isEmpty
        && !usageSource.isEmpty && !routerSource.isEmpty && !renewSource.isEmpty
        && !memorySource.isEmpty,
       "every file the chain runs through was found to read")

expect(factsSource.contains("LoginStatusStore.shared.isExpired(usage.id)"),
       "the surfaces read the verdict for ITS account, not a global flag")
expect(cardSource.contains("RenewLoginStore.shared.renew(accountID: usage.id)"),
       "pressing the chip starts the renewal for that same account")
expect(cardSource.contains("TallyColor.critical")
        && cardSource.range(of: "loginExpiredChip") != nil,
       "the chip is drawn in the severity red the card already speaks in")
for (name, source) in [("card", cardSource), ("list row", rowSource)] {
    if let renewing = source.range(of: "facts.isRenewingLogin {"),
       let expired = source.range(of: "} else if facts.isLoginExpired {") {
        expect(renewing.upperBound <= expired.lowerBound,
               "a renewal in flight replaces the chip, so the \(name) shows one login state at a time")
    } else {
        expect(false, "the \(name)'s two login states are one either/or, not two independent lines")
    }
}
expect(factsSource.contains("RenewLoginStore.shared.canRenew(accountID: usage.id,")
        && cardSource.contains(".disabled(!facts.canRenewLogin)")
        && rowSource.contains(".disabled(!facts.canRenewLogin)"),
       "the chip greys out where the menu entry does, asked of the same place")
// An account that never loaded is EXACTLY the one whose login expired: `lastGood` is a memory-only
// cache, so after every launch a signed-out account is a hard-error row until the first good poll.
// The card has always drawn its login state outside its own error branch for that reason; the
// compact row's error gate has to cover the marks about the READING and nothing else, or the row
// hides the renewal button and the "renewing…" spinner at the one moment they are worth showing.
expect(rowSource.contains("if !facts.isHardError { usageMarks }"),
       "the compact row's error branch gates the usage marks alone")
let rowUsageMarks = functionBody(rowSource, from: "private var usageMarks: some View {") ?? ""
let rowLoginMarks = functionBody(rowSource, from: "private var loginMarks: some View {") ?? ""
expect(rowLoginMarks.contains("facts.isRenewingLogin")
        && rowLoginMarks.contains("facts.isLoginExpired")
        && rowLoginMarks.contains("RenewLoginStore.shared.renew(accountID: usage.id)"),
       "so the two login states, and the renewal the expired one starts, live outside that gate")
expect(!rowUsageMarks.isEmpty
        && !rowUsageMarks.contains("facts.isRenewingLogin")
        && !rowUsageMarks.contains("facts.isLoginExpired"),
       "and the gated marks are about the reading only: stale numbers and banked resets")
// AND THE LOGIN MARK IS THE ONE THAT SPEAKS (owner's report, 2026-08-24). An expired login is why
// the numbers went stale, so both marks lit at once, two triangles a few points apart, saying one
// thing in two colours. The rule lives in the facts, so the card cannot answer it differently.
let staleMarkRule = factsSource.components(separatedBy: "var showsStaleMark: Bool ")
    .last?.components(separatedBy: "\n").first ?? ""
expect(staleMarkRule.contains("usage.isStale") && staleMarkRule.contains("!isLoginExpired"),
       "the stale mark stands down while an expired login is the reason for it")
// AND ONLY THEN. A renewal is startable on any account with a config home (AccountCardMenu), so one
// running says nothing about why a reading went stale - a rate limit or a dropped network is not
// the login, and suppressing there would hide the only warning about a second, unrelated fact
// (codex review, 2026-08-24).
expect(!staleMarkRule.contains("isRenewingLogin"),
       "…and not merely because a renewal is running, which is not a reason for stale numbers")
expect(rowUsageMarks.contains("if facts.showsStaleMark {") && !rowUsageMarks.contains("usage.isStale")
        && cardSource.contains("if facts.showsStaleMark {") && !cardSource.contains("if usage.isStale {"),
       "…and both surfaces ask that one rule instead of lighting a triangle of their own")
// A glyph in a list of eight rows cannot say "this account" and be understood, so each callout
// names the login it belongs to on its FIRST line and qualifies it on the second - the two-line
// shape every other callout in the panel already has, rather than one prefixed sentence.
expect(rowUsageMarks.contains("tallyTooltip(facts.markOwner, detail: usage.error ?? L(\"Outdated\"))")
        && rowLoginMarks.contains("tallyTooltipAroundControl(")
        && rowLoginMarks.contains("facts.markOwner,"),
       "both of the row's marks name their account on the callout's first line")
expect(factsSource.contains("var markOwner: String { identityEmail.isEmpty ? label : identityEmail }"),
       "…by the signed-in address where there is one, and the row's own name otherwise")
// AND THE EXPIRY SAYS WHAT PRESSING IT DOES. The card writes "Login expired" on a chip; the row
// has a 9pt triangle that happens to be a button, so the callout is the only place the click can
// be offered at all (owner's report, 2026-08-24). Both sentences it can carry end in that offer,
// which the accountrow suite asserts on the rule itself; here it is the wiring.
expect(rowLoginMarks.contains("detail: L(AccountSignIn.detailKey("),
       "and the row's expiry mark offers the sign-in the click actually starts")
// The identity chain (live probe answer first, this round's poll next, the remembered address
// last) lives in the STORE, because two surfaces render it now - the card's tooltip and the
// Settings row. The ordering itself is `AccountIdentity.email`, asserted behaviourally in the
// accountrow suite; what this suite pins is that nobody re-derives it.
let settingsSource = readSource("Tally/Views/SettingsAccountsView.swift")
expect(storeSource.contains("AccountIdentity.email(probe:") && !settingsSource.isEmpty,
       "the identity chain is the one shared ordering rather than a second copy in the store")
expect(factsSource.contains("LoginStatusStore.shared.identityEmail(usage)")
        && settingsSource.contains("LoginStatusStore.shared.identityEmail(accountID: item.id,")
        && !surfaceSource.contains("usage.accountEmail"),
       "and both surfaces ask that one chain instead of each reaching past it to the fallback")
// THE SETTINGS CHIP ANSWERS IN TALLY'S OWN CALLOUT TOO (owner's report, 2026-08-24): it was handing
// back the system's yellow box, which is a different application's chrome in the middle of a pane
// full of Tally's. Two things have to be true for that, and the second one fails SILENTLY - a target
// with no host takes the system fallback and looks exactly like it did before.
let rowStatusSource = readSource("Tally/Views/SettingsAccountRowStatus.swift")
let settingsRootSource = readSource("Tally/Views/SettingsView.swift")
expect(!rowStatusSource.isEmpty && !settingsRootSource.isEmpty,
       "the Settings row's status strip and the window root are readable from this suite")
expect(rowStatusSource.contains(".tallyTooltipAroundControl(rowOwner(item, usage: usage),")
        && !rowStatusSource.contains(".help("),
       "the Settings sign-in chip answers in Tally's callout, naming the account then the click")
expect(settingsRootSource.contains(".tallyTooltipLayer()"),
       "…and the Settings window hosts one, without which that callout is the system box again")
// AND BOTH SURFACES NAME THE RIGHT STATE, from one rule. An expired credential and a home the user
// signed out of are one offer and two sentences (`AccountSignIn.detailKey`, asserted behaviourally
// in the accountrow suite); what this suite pins is that neither surface writes a sentence of its
// own. The panel's mark needs it as much as the Settings chip does: it lights on the probe's
// verdict, and the probe asks every account that has a config home, dormant ones included (codex
// review, 2026-08-24).
expect(rowStatusSource.contains("detail: L(AccountSignIn.detailKey(isDormant: item.isDormant))")
        && rowLoginMarks.contains("detail: L(AccountSignIn.detailKey(isDormant: facts.isDormant))"),
       "and both the Settings chip and the panel's expiry mark ask that one rule for the wording")
expect(!rowStatusSource.contains("L(\"Login expired. Click to sign in again.\")")
        && !rowSource.contains("L(\"Login expired. Click to sign in again.\")"),
       "…rather than either of them hard-coding the expiry sentence a dormant home must not get")
// The Settings row asks by account id rather than off a usage row, because the row that most needs
// an address is the one with no usage row at all: a disabled account is never polled.
expect(!settingsSource.contains("usage.flatMap({ LoginStatusStore.shared.identityEmail"),
       "a switched-off row asks who it is instead of going silent with its usage")
expect(storeSource.contains("func rememberIdentities(") && storeSource.contains("func forgetIdentity("),
       "the store both writes down what a round learned and drops it when the account is removed")
// Both live sources feed the memory, not just the poll: the probe asks the provider's own CLI, and
// its answer is the freshest one there is - losing it would leave a switched-off account naming
// itself from a staler round than the app actually had.
if let probeRound = storeSource.range(of: "for (id, reading) in fresh {"),
   let announced = storeSource.range(of: "announce(verdicts: roundVerdicts") {
    expect(storeSource.range(of: "remember(",
                             range: probeRound.upperBound ..< announced.lowerBound) != nil,
           "a probe round writes its answer into the memory as well as into this run's cache")
} else {
    expect(false, "the probe round's own bookkeeping was found to read")
}
let usageStoreSource = readSource("Tally/Stores/UsageStore.swift")
expect(usageStoreSource.contains("LoginStatusStore.shared.rememberIdentities(merged)")
        && usageStoreSource.contains("LoginStatusStore.shared.forgetIdentity(accountID: accountID)"),
       "and the refresh is what feeds it, while a removal is what clears it")

// The surfaces that STEER A LAUNCH have to ask `launchableHome` rather than read the renewal home:
// a pin is denormalized into the policy file the CLI reads, the smart badge predicts what the CLI
// picks, the snapshot IS what the CLI picks from, and a redeem needs a live session to spend a
// credit on. Each one is a way a dormant account could be launched with.
let redeemSource = readSource("Tally/Views/RedeemAction.swift")
let policySource = readSource("Tally/Stores/LaunchPolicyStore.swift")
let pickSource = readSource("TallyCLI/AccountPick.swift")
let mainSource = readSource("TallyCLI/main.swift")
expect(!redeemSource.isEmpty && !policySource.isEmpty && !pickSource.isEmpty && !mainSource.isEmpty,
       "the launch-steering surfaces are readable from this suite")
expect(factsSource.contains("policy.pin(usage.providerID, accountID: usage.id, home: discovered?.launchableHome)")
        && factsSource.contains("!(isDormant && !isPinnedActive)")
        && cardSource.contains(".disabled(!facts.canTogglePin)")
        && rowSource.contains(".disabled(!facts.canTogglePin)"),
       "a signed-out account cannot BECOME the pin on either surface, while releasing one it already holds still works")
// The other half of that, one layer down: a pin the user set before the account signed out is
// denormalized into the policy file, where the CLI can exec it without asking anything. The app
// drops that home the moment it sees the account go dormant (2026-08-03), and the launcher ignores
// it too - either half alone still leaves a pair that launches a logged-out config dir.
expect(policySource.contains("func releasePinnedHome(dormant: Set<String>)")
        && policySource.contains("updated.pinnedHome = nil"),
       "a dormant account's pin lets go of the launch home the CLI would have exec'd")
// Asked of THAT function's body rather than of the whole file: removing an account (2026-08-03)
// deliberately drops the pinned id, because that account is gone rather than signed out, and a
// file-wide ban would have read as "the dormant rule broke" when it did no such thing.
let releaseBody = policySource.range(of: "func releasePinnedHome(").map { start -> String in
    let rest = policySource[start.lowerBound...]
    let end = ["\n    func ", "\n    /// "].compactMap { rest.range(of: $0)?.lowerBound }.min()
        ?? rest.endIndex
    return String(rest[..<end])
} ?? ""
expect(!releaseBody.isEmpty && !releaseBody.contains("updated.pinnedAccountID = nil"),
       "…and keeps the pinned id, so renewing the login restores the choice without a second click")
expect(usageSource.contains("let dormantIDs = Set(dormant.map(\\.id))")
        && usageSource.contains("LaunchPolicyStore.shared.releasePinnedHome(dormant: dormantIDs)"),
       "the refresh drives that release from the accounts it just found dormant")
expect(pickSource.contains("func pinnedLaunchHome(_ snapshot: Snapshot?, policy: LaunchPolicy)")
        && pickSource.contains("return pinnedAccountIsSignedOut(snapshot, policy: policy) ? nil : policy.pinnedHome"),
       "and the launcher refuses a saved home whose account the snapshot lists as signed out")
expect(!mainSource.contains("?.launchHome ?? policy.pinnedHome"),
       "…with no surface left resolving a pin on its own (that is how one of them missed it)")
// That pattern bans one SHAPE of a hand-rolled pin, and the surface it missed wore another: the
// text `tally status` compared the pinned id with no launch home in sight, so it kept printing
// `→ … (pinned)` on an account the launcher had already given up on (2026-08-03). The rule that
// covers both shapes, checked line by line: outside the resolver itself (AccountPick.swift), a
// pinned-id comparison has to carry the "can this be launched" half with it, or not be there at
// all because the surface asks `launchMarkers` / `pinnedLaunchHome` instead.
let reportSource = readSource("TallyCLI/StatusReport.swift")
let looseIDChecks = (mainSource + "\n" + reportSource)
    .split(separator: "\n", omittingEmptySubsequences: false)
    .filter { $0.contains("policy.pinnedAccountID") && !$0.contains("launchHome != nil") }
expect(!reportSource.isEmpty && looseIDChecks.isEmpty,
       "no launch or status surface reads the pinned id without asking whether it can be launched")
expect(mainSource.contains("let (bestID, pinnedID) = launchMarkers(providerID: provider.id"),
       "…so the text status takes both of its markers from the resolver the JSON status uses")
expect(cardSource.contains(".disabled(redeemBusy || facts.isDormant)")
        && rowSource.contains(".disabled(redeemBusy || facts.isDormant)"),
       "a signed-out account's banked resets are visible but not spendable - the redeem has no session")
expect(factsSource.contains("$0.launchableHome != nil ? $0.id : nil"),
       "the smart-pick badge counts only accounts a launch could actually land on")
expect(usageSource.contains("if let home = account.launchableHome { launchHomes"),
       "the snapshot the tally CLI launches from carries launchable homes only")
expect(redeemSource.contains("?.launchableHome"),
       "and a redeem is asked of an account that still has a session to spend it on")
expect(usageSource.contains("carriedAccountRows(previous: accounts"),
       "the refresh carries rows through the one carry rule rather than a filter of its own")

expect(usageSource.contains("LoginStatusStore.shared.evaluate(accounts: polled,"),
       "the refresh loop drives the probe, so there is no second timer to keep honest")
expect(usageSource.contains("SettingsStore.shared.isAccountEnabled($0.id)")
        && usageSource.range(of: "let polled = known.filter {") != nil,
       "…and only for accounts the user actually has switched on")

// The signed-out account has to survive discovery to reach any of this, and there are three places
// it has to survive to: the list a renewal resolves a config home from, the probe list, and a card
// for the chip to sit on.
expect(usageSource.contains("let (known, dormant) = KnownAccountsStore.shared.reconcile(discovered: allDiscovered)"),
       "the refresh remembers what it discovered, so a logout leaves a dormant account behind")
expect(usageSource.contains("adoptDiscovered(known)")
        && usageSource.contains("discoveredAccounts = accounts"),
       "…which stays in the list `RenewLoginStore.renew(accountID:)` resolves a home from")
expect(memorySource.contains("return (discovered + revived, revived)"),
       "…because `all` really is discovery WITH the dormant accounts merged back into it, which "
           + "is the only reason the probe (and every list built from it) can see one")
expect(usageSource.contains("message: L(\"Login expired\")"),
       "…and gets a row of its own, because the chip lives on a card")
expect(usageSource.contains("known: Set(known.map(\\.id))"),
       "the dedup is pruned against every account that exists, not the ones probed this round")
expect(storeSource.contains("accounts: [ProviderAccount], known: Set<String>)")
        && !storeSource.contains("known: Set(accounts.map(\\.id))"),
       "…which the store takes as its own argument rather than deriving from the probe list")
expect(storeSource.contains("UsageStore.shared.discoveredAccountsNow().first")
        && usageSource.contains("func discoveredAccountsNow()"),
       "the sample expiry alert discovers an account itself: it fires from launch, before the "
           + "first refresh has filled the store, and an alert naming nothing cannot be renewed")

expect(storeSource.contains("guard !DemoUsage.isActive else { return }"),
       "demo mode never runs a provider CLI")
expect(storeSource.contains("accountID == Self.demoExpiredAccountID"),
       "…and the demo chip comes from a fixture instead")
expect(storeSource.contains("isProbing = true") && storeSource.contains("defer { isProbing = false }"),
       "…because two rounds racing would each read the dedup state before either wrote it, "
           + "and announce the same outage twice")
// `isUnshipped`, not `isDev`: a Release built locally carries the release bundle id, so it shares
// this alert's dedup state as well as its notification centre - it would say the outage twice and
// then mark it announced on the installed app's behalf.
expect(storeSource.contains("guard !BuildVariant.isUnshipped else { return }"),
       "a build nobody installed never speaks on the shared surfaces, so it posts no notification")
expect(storeSource.contains("LoginProbeGate.decide(state: gate, isProbing: isProbing,"),
       "the probe throttles itself through the one gate, rather than a guard of its own")

// MARK: - The chip that outlived the login (codex review + Albert's machine, 2026-08-03)

// A Codex account renewed on the SECOND attempt: the quota came back at the full Team allowance and
// the red "Login expired" chip stayed on the card. The verdict behind that chip is written by a
// probe throttled to five minutes, and every way a renewal had of forcing a round could be dropped:
// the refresh could be coalesced (losing `userInitiated`), the forced round could arrive while
// another was out (dropped by the overlap guard), or the probe could beat the credential to disk.
let gateIdle = LoginProbeGate.State()
let probedAt = Date(timeIntervalSince1970: 1_000_000)
let soonAfter = probedAt.addingTimeInterval(30)
func decide(_ state: LoginProbeGate.State, isProbing: Bool = false, userInitiated: Bool = false,
            at now: Date = soonAfter) -> LoginProbeGate.Decision {
    LoginProbeGate.decide(state: state, isProbing: isProbing, userInitiated: userInitiated,
                          lastProbeAt: probedAt, now: now, interval: 300)
}
expect(decide(gateIdle) == .skip,
       "a routine refresh inside the interval asks nothing - a credential is not a quota")
expect(decide(gateIdle, at: probedAt.addingTimeInterval(301)) == .run,
       "…and asks again once the interval is up")
expect(decide(gateIdle, userInitiated: true) == .run,
       "an explicit refresh always asks")
var renewed = LoginProbeGate.State()
renewed.forced["codex:.codex2"] = LoginProbeGate.renewed
expect(decide(renewed) == .run,
       "a just-renewed account forces a round even on a refresh that carried no flag at all - "
           + "which is what a coalesced refresh looks like from here")
expect(decide(renewed, isProbing: true) == .queue && decide(gateIdle, isProbing: true) == .skip,
       "…and a round already in flight holds it rather than dropping it on the floor")
// The three rounds after a renewal, in the order the user's machine produced them. `known` is every
// account that still exists on the machine, which for these rounds is the one being renewed.
let stillHere: Set<String> = ["codex:.codex2"]
func afterRound(_ state: LoginProbeGate.State,
                _ verdicts: [String: LoginStatusCommand.Verdict],
                known: Set<String> = stillHere) -> (next: LoginProbeGate.State, retrySoon: Bool) {
    LoginProbeGate.afterRound(state: state, verdicts: verdicts, known: known)
}
let stillOut = afterRound(renewed, ["codex:.codex2": .signedOut])
expect(stillOut.retrySoon,
       "the probe beating the credential to disk buys a short re-ask, not a five-minute wait")
let landed = afterRound(renewed, ["codex:.codex2": .signedIn])
expect(!landed.next.isForcing && !landed.retrySoon,
       "…and the moment it reads signed in the account stops forcing anything")
expect(!stillOut.next.isForcing,
       "a renewal that really did not take runs out of forcings instead of probing forever")
expect(afterRound(renewed, [:]).next == renewed,
       "an account this round never probed keeps its forcing: it was not asked")
// …unless there is nobody left to ask. An account removed after its login was handed to a Terminal
// window produces no verdict ever again, and a forcing left behind is not idle: `isForcing` puts
// EVERY later refresh past the five-minute throttle, spawning a probe per enabled account each
// time (codex review, 2026-08-03).
expect(!afterRound(renewed, [:], known: []).next.isForcing,
       "an account that no longer exists stops forcing rounds nobody can answer")
expect(!afterRound(renewed, [:], known: ["claude:.claude2"]).next.isForcing,
       "…and it is THIS account's absence that ends it, not the round being empty")
expect(afterRound(renewed, ["codex:.codex2": .signedOut], known: []).next.forced.isEmpty,
       "…even when the round did answer: a removed account's verdict is about a home in the Trash")
// The other way a login finishes, and the one Albert's first attempt took: Tally hands the command
// to a Terminal window and goes blind. The credential landing there triggers a refresh through the
// directory watcher, and that refresh carries no flag - so the forcing has to outlive a few rounds.
var handed = LoginProbeGate.State()
handed.forced["codex:.codex2"] = LoginProbeGate.handedOff
expect(decide(handed) == .run && !LoginProbeGate.handedOff.retrySoon,
       "a login handed to a Terminal forces the next round, without assuming a file is landing")
var patience = handed
for _ in 0 ..< 3 {
    patience = afterRound(patience, ["codex:.codex2": .signedOut]).next
}
expect(!patience.isForcing,
       "…and its patience is bounded, or a login abandoned in a Terminal probes on every refresh")

expect(renewSource.contains("LoginStatusStore.shared.loginRenewed(accountID)"),
       "a renewal that reported success drops the stale verdict itself, so the chip cannot "
           + "survive on a probe that ran before the login did")
expect(renewSource.contains("LoginStatusStore.shared.loginHandedOff(accountID)")
        && renewSource.components(separatedBy: "handOff(accountID, providerID: providerID, home: home)")
            .count == 3,
       "…and BOTH Terminal handoffs (the refused announcement and the failed attempt) force the "
           + "rounds that follow - the failed-then-finished-by-hand path is the reported one")

// MARK: - Forcing a round is not having one (codex review, 2026-08-03)

// The handoff's own rounds. `loginHandedOff` only lifts the throttle; nothing in that path SCHEDULES
// a round, and the one thing that would otherwise notice the credential landing - the config-dir
// watcher - is fail-open by contract. Without a ladder of its own the chip sat there until the poll
// timer came round, which is up to fifteen minutes at the interval the user can set.
expect(renewSource.contains("private func handOff(_ accountID: String, providerID: String, home: String) {")
        && renewSource.contains("LoginStatusStore.shared.loginHandedOff(accountID)")
        && renewSource.contains("await UsageStore.shared.refresh()"),
       "a handed-off login asks for rounds of its own rather than only being allowed to have them")
expect(renewSource.contains("LoginProbeGate.handoffTick(")
        && renewSource.contains(".landed(after: before)")
        && renewSource.contains("guard tick != .wait else { continue }")
        && renewSource.contains("if tick == .askThenStop { return }"),
       "…and it looks at the credential itself before it spends a probe round on the question")
expect(renewSource.contains("handoffPolls[accountID]?.cancel()"),
       "a second handoff replaces the first ladder rather than running beside it")

// The ladder as it actually runs, one tick at a time: when does the first refresh get asked for,
// given a user who finishes their login `landsAt` seconds into it?
func firstAsk(landsAt: TimeInterval) -> TimeInterval? {
    var elapsed: TimeInterval = 0
    while true {
        elapsed += LoginProbeGate.handoffPollDelay
        switch LoginProbeGate.handoffTick(elapsed: elapsed, credentialLanded: elapsed >= landsAt,
                                          awaitingLogin: true) {
        case .wait: continue
        case .ask, .askThenStop: return elapsed
        case .stop: return nil
        }
    }
}
// The bug, as a number: three probe rounds ten seconds apart is a thirty-second deadline, and a
// browser sign-in with a human in it routinely takes longer than that.
let oldDeadline = LoginProbeGate.handoffPollDelay * Double(LoginProbeGate.handedOff.roundsLeft)
expect(oldDeadline < 60 && LoginProbeGate.handoffPatience >= 5 * 60,
       "the person's clock and the probe's clock are not the same clock: the gate's rounds were "
           + "never a statement about how long somebody takes to sign in")
for slow in [oldDeadline + 10, 90.0, 240.0] {
    guard let asked = firstAsk(landsAt: slow) else {
        expect(false, "a login that took \(Int(slow))s in the Terminal window still clears the chip")
        continue
    }
    expect(asked - slow <= LoginProbeGate.handoffPollDelay,
           "a login that took \(Int(slow))s in the Terminal window is asked about within one tick "
               + "of landing, not at the fifteen-minute poll")
}
expect(firstAsk(landsAt: 45) != nil && oldDeadline < 45,
       "…which is exactly the case the old ladder had already given up on")
expect(firstAsk(landsAt: LoginProbeGate.handoffPatience + 10) == nil,
       "a login abandoned in that window stops at the deadline rather than polling forever")
expect(LoginProbeGate.handoffTick(elapsed: 20, credentialLanded: false, awaitingLogin: true) == .wait,
       "waiting costs a file check, not a probe per enabled account")
expect(LoginProbeGate.handoffTick(elapsed: 20, credentialLanded: true, awaitingLogin: false) == .stop,
       "…and the ladder ends the moment the account is no longer waiting on a login")

// The deadline reads the credential before it closes the ladder (codex review, 2026-08-03): a login
// finished at 4:55 is news the 5:00 tick is the first to have, and stopping on the clock before
// reading it put that user back on the ordinary poll.
expect(LoginProbeGate.handoffTick(elapsed: LoginProbeGate.handoffPatience, credentialLanded: true,
                                  awaitingLogin: true) == .askThenStop,
       "a credential that landed just before the deadline still gets its round asked for")
expect(LoginProbeGate.handoffTick(elapsed: LoginProbeGate.handoffPatience, credentialLanded: false,
                                  awaitingLogin: true) == .stop,
       "…and the deadline is still a deadline: nothing landed by then ends the ladder")

// What the ladder reads to decide a credential landed. The Keychain can stop describing an item it
// still holds (locked: present, no attributes), so the stamp flickers between a date and nil on a
// machine where nothing happened - and a plain inequality called that a login (codex review,
// 2026-08-03).
let handedOverStamp = LoginProbeGate.CredentialStamp(
    fileExists: true, fileModifiedAt: Date(timeIntervalSince1970: 1_000), fileSize: 42,
    keychain: true, keychainModifiedAt: Date(timeIntervalSince1970: 1_000))
var lockedStamp = handedOverStamp
lockedStamp.keychainModifiedAt = nil
expect(!lockedStamp.landed(after: handedOverStamp)
        && !handedOverStamp.landed(after: lockedStamp),
       "a Keychain that stops describing itself, and one that starts again, is not a login landing")
var renewedStamp = handedOverStamp
renewedStamp.keychainModifiedAt = Date(timeIntervalSince1970: 2_000)
var rewrittenFile = handedOverStamp
rewrittenFile.fileModifiedAt = Date(timeIntervalSince1970: 2_000)
let nothingThere = LoginProbeGate.CredentialStamp(fileExists: false, fileModifiedAt: nil,
                                                  fileSize: nil, keychain: false,
                                                  keychainModifiedAt: nil)
expect(renewedStamp.landed(after: handedOverStamp)
        && rewrittenFile.landed(after: handedOverStamp)
        && handedOverStamp.landed(after: nothingThere),
       "a credential that was rewritten, or that appeared where there was none, is one")

// The account the handoff was built for: a dormant Codex one has no `auth.json` and never a
// Keychain item, so every field is nil before the login and a date after it - which "both sides had
// to be readable" read as nothing happening, and the ladder waited out its five minutes without
// asking once (codex review, 2026-08-03). File existence answers where the attributes cannot.
let dormantCodex = nothingThere
let signedInCodex = LoginProbeGate.CredentialStamp(
    fileExists: true, fileModifiedAt: Date(timeIntervalSince1970: 2_000), fileSize: 512,
    keychain: false, keychainModifiedAt: nil)
expect(signedInCodex.landed(after: dormantCodex),
       "an auth.json appearing where there was none is a login landing, Keychain or no Keychain")
expect(!dormantCodex.landed(after: signedInCodex),
       "…and the same file going away is not: existence speaks in one direction, like the Keychain's")
var unreadableCodex = signedInCodex
unreadableCodex.fileModifiedAt = nil
unreadableCodex.fileSize = nil
expect(!unreadableCodex.landed(after: signedInCodex)
        && !signedInCodex.landed(after: unreadableCodex),
       "a file that stops describing itself, and one that starts again, still moved nothing: a "
           + "failed stat is a worse view of the machine, not a new credential")
expect(renewSource.contains("FileManager.default.fileExists(atPath: file.path)"),
       "…and the stamp reads existence itself rather than inferring it from a stat that can fail")

// The other half of the same bug, and the one that covers a user who takes their time in that
// Terminal window: a dormant account becoming discoverable again IS the login landing. The watcher
// only reacts to a CHANGED account set, and a dormant account carries the same id and home as the
// live one it becomes - so the transition has to be part of that identity, and the stale verdict
// the chip is read off has to go when it happens.
expect(watcherSource.contains("$0.isDormant ? \" (dormant)\" : \"\""),
       "signing back in changes the discovered set, or the watcher would call the login a non-event")
expect(usageSource.contains("private func adoptDiscovered(_ accounts: [ProviderAccount]) {")
        && usageSource.contains("self.adoptDiscovered(all)")
        && usageSource.contains("adoptDiscovered(known)"),
       "both passes that discover accounts (the watcher's and the refresh's) adopt them the same "
           + "way, or the one that ran first would swallow the transition")
expect(usageSource.contains("LoginStatusStore.shared.loginLanded(")
        && storeSource.contains("func loginLanded(_ accountIDs: Set<String>)"),
       "…and a credential back on disk retires the verdict a probe wrote before it landed")
expect(storeSource.contains("verdicts[accountID] = nil"),
       "the verdict really is cleared rather than merely re-asked for")

// …and clearing it is only half of the answer. A round is several CLI spawns wide: one that started
// before the credential landed comes home saying "signed out", which was true when it asked, and
// writing that answer puts the chip straight back for another interval (codex review, 2026-08-03).
var landings = LoginProbeGate.Landings()
let roundBefore = landings.mark
landings.land(["codex:.codex2"])
let roundAfter = landings.mark
expect(landings.isStale("codex:.codex2", since: roundBefore),
       "a round that asked before the login landed does not get to answer for that account")
expect(!landings.isStale("claude:.claude2", since: roundBefore),
       "…and only for that account: the same round's other readings are current")
expect(!landings.isStale("codex:.codex2", since: roundAfter),
       "a round that started after the landing is the one that knows better")
landings.land(["claude:.claude2"])
expect(landings.isStale("codex:.codex2", since: roundBefore)
        && !landings.isStale("codex:.codex2", since: roundAfter),
       "a second landing does not re-open the first: what is stale is what was asked too early")
var untouched = LoginProbeGate.Landings()
untouched.land([])
expect(untouched == LoginProbeGate.Landings(),
       "an empty landing is not news, and does not invalidate a round that is out")
// The same generation machinery answers a second question, and it had to: an account REMOVED
// while a round is out leaves that round holding a reading which names the person who used to be
// here. Without voiding it, the reading comes home after `forgetIdentity` has run, writes the old
// address back and PERSISTS it, so a `~/.codex3` recreated tomorrow wears the previous owner's
// email across restarts (codex review, 2026-08-04).
if let forget = functionBody(storeSource, from: "func forgetIdentity(accountID: String)") {
    expect(forget.contains("landings.land([accountID])"),
           "a removal voids the answers of every probe round already out for that account")
    expect(forget.contains("identities.forget(accountID: accountID)")
            && forget.contains("emails[accountID] = nil") && forget.contains("verdicts[accountID] = nil"),
           "…and drops what this run already knew: the memory, the probe cache and the verdict")
} else {
    expect(false, "the removal path was found to read")
}
expect(storeSource.contains("let mark = landings.mark")
        && storeSource.contains("let fresh = readings.filter { !landings.isStale($0.key, since: mark) }")
        && storeSource.contains("let roundVerdicts = fresh.mapValues(\\.verdict)"),
       "the probe takes its mark before it spawns anything and drops the readings a landing "
           + "overtook - chip, notification and gate together, or they would disagree")
expect(storeSource.contains("landings.land([accountID])")
        && storeSource.contains("landings.land(accountIDs)"),
       "both witnesses of a landing retire the rounds that predate them: the CLI that reported the "
           + "renewal, and discovery finding the account live again")
expect(usageSource.contains("queuedUserInitiated = queuedUserInitiated || userInitiated")
        && usageSource.contains("Task { await refresh(userInitiated: inherited) }"),
       "a refresh coalesced into one already running keeps the reason it was asked for, or the "
           + "renewal's forced probe is lost with it")
expect(storeSource.contains("(output?.stdout ?? \"\") + \"\\n\" + (output?.stderr ?? \"\")"),
       "both streams are read, because the two CLIs answer on different ones")

expect(routerSource.contains("LoginStatusStore.category"),
       "the expiry category is registered, or its button would not exist on the alert")
expect(routerSource.contains("action == LoginStatusStore.renewActionID"),
       "the alert's button renews, and only that button does")
expect(renewSource.contains("func renew(accountID: String) {")
        && renewSource.contains("UsageStore.shared.discoveredAccounts.first(where: { $0.id == accountID })"),
       "an id alone is enough to renew, which is all a notification ever carries")

try? FileManager.default.removeItem(at: stubs)
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
