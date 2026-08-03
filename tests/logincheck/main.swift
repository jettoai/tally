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
let storeSource = readSource("Tally/Stores/LoginStatusStore.swift")
let usageSource = readSource("Tally/Stores/UsageStore.swift")
let routerSource = readSource("Tally/App/NotificationRouter.swift")
let renewSource = readSource("Tally/Stores/RenewLoginStore.swift")
let memorySource = readSource("Tally/Stores/KnownAccountsStore.swift")
expect(!cardSource.isEmpty && !storeSource.isEmpty && !usageSource.isEmpty
        && !routerSource.isEmpty && !renewSource.isEmpty && !memorySource.isEmpty,
       "every file the chain runs through was found to read")

expect(cardSource.contains("LoginStatusStore.shared.isExpired(usage.id)"),
       "the card reads the verdict for ITS account, not a global flag")
expect(cardSource.contains("RenewLoginStore.shared.renew(accountID: usage.id)"),
       "pressing the chip starts the renewal for that same account")
expect(cardSource.contains("TallyColor.critical")
        && cardSource.range(of: "loginExpiredChip") != nil,
       "the chip is drawn in the severity red the card already speaks in")
if let renewing = cardSource.range(of: "RenewLoginStore.shared.isRenewing(usage.id) {"),
   let expired = cardSource.range(of: "} else if LoginStatusStore.shared.isExpired(usage.id) {") {
    expect(renewing.upperBound <= expired.lowerBound,
           "a renewal in flight replaces the chip, so the card shows one login state at a time")
} else {
    expect(false, "the card's two login states are one either/or, not two independent lines")
}
expect(cardSource.contains("RenewLoginStore.shared.canRenew(providerID: usage.providerID, home: configHome)"),
       "the chip greys out where the menu entry does, asked of the same place")
expect(cardSource.contains("LoginStatusStore.shared.email(usage.id) ?? usage.accountEmail"),
       "the identity tooltip prefers the CLI's live answer over the config file's stale copy")

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
expect(usageSource.contains("discoveredAccounts = known"),
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

expect(storeSource.contains("guard !DemoUsage.isActive, !isProbing else { return }"),
       "demo mode never runs a provider CLI, and two rounds never overlap")
expect(storeSource.contains("accountID == Self.demoExpiredAccountID"),
       "…and the demo chip comes from a fixture instead")
expect(storeSource.contains("isProbing = true") && storeSource.contains("defer { isProbing = false }"),
       "…because two rounds racing would each read the dedup state before either wrote it, "
           + "and announce the same outage twice")
expect(storeSource.contains("guard !BuildVariant.isDev else { return }"),
       "the dev variant never speaks on the shared surfaces, so it posts no notification")
expect(storeSource.contains("now.timeIntervalSince(last) < Self.probeInterval { return }")
        && storeSource.contains("if !userInitiated,"),
       "the probe throttles itself, but an explicit refresh always asks")
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
