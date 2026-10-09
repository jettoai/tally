import Foundation

// The add-account chain, end to end without a real login: prepare a config home, drive the
// provider's login command against it, and check that what comes out is exactly what makes an
// account APPEAR in Tally.
//
// The login is a stub CLI this file writes (as tests/renewlogin does), never a vendor's OAuth: a
// real one would spend the machine's own credentials, and the question here is the wiring, not the
// vendor's sign-in. Codex is the provider under test because its logged-in signal is a FILE
// (`auth.json`), so the last link of the chain can be asserted directly against the same predicate
// `CodexAccounts.discover()` uses, rather than against a mock of it.
//
// What the sheet adds on top of this is SwiftUI state (which phase is on screen); what it must never
// add is a second copy of the steps, which tests/addshare pins by source.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("tally-addaccount-\(UUID())")
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
let noKeychain: (URL) -> Bool = { _ in false }
let realFiles: (String) -> Bool = { fm.fileExists(atPath: $0) }

/// An executable stand-in for `codex login`, doing the one thing a finished login leaves behind.
func stub(_ name: String, _ body: String) -> String {
    let url = tmp.appendingPathComponent(name)
    try! ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

// A machine that already has one codex account, so the new one is the next number.
let home = tmp.appendingPathComponent("home")
let mainHome = home.appendingPathComponent(".codex")
try! fm.createDirectory(at: mainHome, withIntermediateDirectories: true)
try! "auth".write(to: mainHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
try! "codex instructions".write(to: mainHome.appendingPathComponent("AGENTS.md"),
                                atomically: true, encoding: .utf8)
try! fm.createDirectory(at: mainHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)

// MARK: the failed run, first - because its whole point is that it leaves the number alone

let refused = try! prepareAddedAccountHome(providerID: "codex", share: true, home: home,
                                           fileExists: realFiles, keychainLogin: noKeychain)
expect(refused.name == ".codex2", "the flow prepares the next free home")
let plan = RenewLoginCommand.plan(providerID: "codex")!
let envKey = "CODEX_HOME"
let refusedOutcome = await RenewLoginRunner.run(
    executable: stub("refuse", "exit 3\n"), plan: plan,
    environment: RenewLoginCommand.environment(envKey: envKey, home: refused.dir.path,
                                               providerID: "codex", userHome: home),
    overallLimit: 10)
expect(refusedOutcome == .failed(.reported), "a login that refuses is reported as refused")
expect(!fm.fileExists(atPath: refused.dir.appendingPathComponent("auth.json").path),
       "and leaves no logged-in signal behind")
// The cleanup decision, pinned: the home STAYS. It holds the share links this run created, and the
// next attempt resumes it rather than taking the next number - so an abandoned attempt costs the
// user nothing and deletes nothing.
expect(fm.fileExists(atPath: refused.dir.path), "the prepared home survives a failed login")
expect(refused.linked.contains("AGENTS.md"), "with the share it was given")
let retried = try! prepareAddedAccountHome(providerID: "codex", share: true, home: home,
                                           fileExists: realFiles, keychainLogin: noKeychain)
expect(retried.name == refused.name, "retrying resumes that same home, burning no number")
expect(retried.kept.contains("AGENTS.md") && retried.linked.isEmpty,
       "and links nothing twice")

// MARK: the successful run - the chain that ends in a card

// The stub writes the vendor's own logged-in signal into whatever home the environment names, which
// is the only way this can pass: if the config-home variable were mis-set, the file would land
// somewhere else and every assertion below would fail.
let loginStub = stub("login", "printf 'ok' > \"$CODEX_HOME/auth.json\"\nexit 0\n")
let added = try! prepareAddedAccountHome(providerID: "codex", share: true, home: home,
                                         fileExists: realFiles, keychainLogin: noKeychain)
let outcome = await RenewLoginRunner.run(
    executable: loginStub, plan: plan,
    environment: RenewLoginCommand.environment(envKey: envKey, home: added.dir.path,
                                               providerID: "codex", userHome: home),
    overallLimit: 10)
expect(outcome == .renewed, "a login that completes is reported as completed")
expect(fm.fileExists(atPath: added.dir.appendingPathComponent("auth.json").path),
       "the credential landed in the home the flow created, not in the main one")
expect((try? String(contentsOf: mainHome.appendingPathComponent("auth.json"), encoding: .utf8)) == "auth",
       "and the existing account's own credential was never touched")

// The last link: what the app does with that. Discovery's signal for a codex account is exactly the
// file above; the watcher decides whether the app looks before the next poll.
expect(accountDirEventIsInteresting(path: added.dir.path, home: home.path),
       "a write inside the new home wakes the watcher")
expect(accountDirEventIsInteresting(path: home.path, home: home.path),
       "and so does the home directory itself, which is how a NEW directory is reported")
expect(!accountDirEventIsInteresting(path: home.appendingPathComponent("Documents/notes").path,
                                     home: home.path),
       "while the rest of the home directory is left alone")
func account(_ dir: URL) -> ProviderAccount {
    ProviderAccount(id: "codex:\(dir.lastPathComponent)", providerID: "codex",
                    label: dir.lastPathComponent, locator: [:], launchHome: dir.path)
}
expect(accountSetChanged(from: [account(mainHome)], to: [account(mainHome), account(added.dir)]),
       "the account that just appeared is a change worth a refresh")
expect(!accountSetChanged(from: [account(mainHome)], to: [account(mainHome)]),
       "while an unchanged set buys nothing")

// The default home is the exception the environment has to get right: it runs with the variable
// UNSET, because the CLI namespaces its own storage by the exact variable string.
let firstEver = tmp.appendingPathComponent("empty-home")
try! fm.createDirectory(at: firstEver, withIntermediateDirectories: true)
let first = try! prepareAddedAccountHome(providerID: "codex", share: true, home: firstEver,
                                         fileExists: realFiles, keychainLogin: noKeychain)
expect(first.isMainHome, "the first account of all is the default home")
expect(RenewLoginCommand.environment(envKey: envKey, home: first.dir.path, providerID: "codex",
                                     userHome: firstEver)[envKey] == .some(nil),
       "which the login runs against with the variable removed, not spelled out")

// THE GATE IS ASYNC AND SERIALIZED (2026-09-26): its owner reads off the main thread, so a debounce
// that settles while one is running folds into one follow-up, and a torn-down watcher reports nothing.
let watcherGateSource = (try? String(contentsOfFile: "Tally/Core/AccountDirWatcher.swift",
                                     encoding: .utf8)) ?? ""
expect(watcherGateSource.contains("guard gate.request() else { return }")
        && watcherGateSource.contains("} while self.gate.finish()"),
       "the watcher never runs two gates at once")
expect(watcherGateSource.contains("generation += 1")
        && watcherGateSource.contains("if changed, self.generation == started { self.onChange() }"),
       "a torn-down watcher reports nothing")

// THE STREAM STARTS OFF THE MAIN THREAD (Sentry TALLY-1N): FSEventStreamStart is a synchronous RPC
// to fseventsd and hung launch for seconds on a loaded machine. So a start is in flight for a while,
// and these run a REAL stream through the two races that opens: stop-then-start while the first start
// is still in flight must still end up watching, and a bare stop must not adopt the stream that lands.
@MainActor
func watcherSees(_ name: String, restart: Bool) async -> Bool {
    let dir = tmp.appendingPathComponent(name)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var fired = false
    let watcher = AccountDirWatcher(roots: [dir], debounce: .milliseconds(50), isInteresting: { _ in true },
                                    discoverChanged: { true }, onChange: { fired = true })
    watcher.start()
    watcher.stop()
    if restart { watcher.start() }
    // Keep writing rather than write once: on a loaded machine fseventsd can take seconds to
    // register the stream, and a write before that is invisible to a since-now stream.
    for i in 0 ..< 50 where !fired {
        try! "\(i)".write(to: dir.appendingPathComponent("probe"), atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(200))
    }
    watcher.stop()
    return fired
}
expect(await watcherSees("watch-restart", restart: true),
       "a start asked for while one is in flight still ends up watching")
expect(!(await watcherSees("watch-stopped", restart: false)),
       "a stop while the start is in flight leaves nothing watching")

// THE MARKER SWEEP RUNS OFF THE MAIN THREAD (Sentry TALLY-38): discovery's callers clear the
// pending-add markers (and write the onboarding note) beside the listing, not in the reconcile.
let sweep = tmp.appendingPathComponent("sweep")
let pendingHome = sweep.appendingPathComponent(".claude7")
let settledHome = sweep.appendingPathComponent(".claude8")
for dir in [pendingHome, settledHome] { try! fm.createDirectory(at: dir, withIntermediateDirectories: true) }
let marker = pendingHome.appendingPathComponent(addAccountPendingMarker)
try! "".write(to: marker, atomically: true, encoding: .utf8)
func claudeAccount(_ home: URL) -> ProviderAccount {
    ProviderAccount(id: "claude:\(home.lastPathComponent)", providerID: "claude",
                    label: home.lastPathComponent, locator: [:], launchHome: home.path)
}
let (pendingAccount, settledAccount) = (claudeAccount(pendingHome), claudeAccount(settledHome))
expect(KnownAccountsStore.clearPendingMarkers([pendingAccount, settledAccount], unshipped: true).isEmpty
        && fm.fileExists(atPath: marker.path),
       "an unshipped build's sweep leaves every marker where it is")
let onboarded = { (home: URL) in
    (try? String(contentsOf: home.appendingPathComponent(".claude.json"), encoding: .utf8))?
        .contains("hasCompletedOnboarding") == true
}
let swept = await Task.detached {
    KnownAccountsStore.clearPendingMarkers([pendingAccount, settledAccount], unshipped: false)
}.value
expect(swept.map(\.id) == [pendingAccount.id] && !fm.fileExists(atPath: marker.path),
       "the sweep answers with exactly the accounts whose marker it removed, off the main actor")
expect(onboarded(pendingHome) && !onboarded(settledHome),
       "…and writes the onboarding note for that account only, in the same pass")
expect(KnownAccountsStore.clearPendingMarkers([pendingAccount, settledAccount], unshipped: false).isEmpty,
       "…and a second sweep has nothing left to report")
let knownStoreSource = (try? String(contentsOfFile: "Tally/Stores/KnownAccountsStore.swift", encoding: .utf8)) ?? ""
let usageStoreSource = (try? String(contentsOfFile: "Tally/Stores/UsageStore.swift", encoding: .utf8)) ?? ""
expect(knownStoreSource.contains("nonisolated static func clearPendingMarkers(")
        && knownStoreSource.contains("nonisolated static func discoverClearingMarkers(")
        && usageStoreSource.components(separatedBy: "KnownAccountsStore.discoverClearingMarkers(").count == 4
        && usageStoreSource.contains("Task.detached(priority: .utility) {\n"
            + "            KnownAccountsStore.discoverClearingMarkers(providers)")
        && usageStoreSource.contains("Task.detached(priority: .utility) {\n"
            + "                KnownAccountsStore.discoverClearingMarkers([provider])")
        && usageStoreSource.contains(".reconcile(discovered: KnownAccountsStore.discoverClearingMarkers(providers))")
        && !knownStoreSource.contains("cleared:"),
       "all three discovery paths sweep before they reconcile, two of them inside the detached pass")

// THE ROW BEFORE THE NOTICE (B-1033): the add flow adopts the new account through the watcher's own
// fast path before it posts "Account added", rather than waiting on a refresh round that polls every
// Claude account first; and a round that started before such an adopt does not overwrite it.
let addStoreSource = (try? String(contentsOfFile: "Tally/Stores/AddAccountStore.swift", encoding: .utf8)) ?? ""
if let adopt = addStoreSource.range(of: "await UsageStore.shared.adoptFreshDiscovery()"),
   let notice = addStoreSource.range(of: "L(\"Account added\")"),
   let refresh = addStoreSource.range(of: "await UsageStore.shared.refresh(userInitiated: true)") {
    expect(adopt.lowerBound < notice.lowerBound && notice.lowerBound < refresh.lowerBound,
           "land adopts the new account, then posts the notice, then refreshes usage")
} else {
    expect(false, "land adopts the new account, then posts the notice, then refreshes usage")
}
expect(usageStoreSource.contains("discoverChanged: { [weak self] in await self?.adoptFreshDiscovery() ?? false }")
        && usageStoreSource.components(separatedBy: "func adoptFreshDiscovery()").count == 2,
       "the watcher and the add flow share one fast path")
expect(usageStoreSource.contains("let epochAtStart = discoveryEpoch")
        && usageStoreSource.contains("if discoveryEpoch == epochAtStart { adoptDiscovered(known) }"),
       "a round that started before a mid-round adopt leaves that adopt standing")

try? fm.removeItem(at: tmp)
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
