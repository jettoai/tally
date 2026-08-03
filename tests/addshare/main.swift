import Foundation

// Assertion harness for the `tally add claude --share` harness-linking surgery
// (linkSharedHarness in TallyCLI/Snapshot.swift).

var passed = 0, failed = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("tally-share-\(UUID())")
let source = tmp.appendingPathComponent("claude")
let target = tmp.appendingPathComponent("claude3")
try! fm.createDirectory(at: source, withIntermediateDirectories: true)
try! fm.createDirectory(at: target, withIntermediateDirectories: true)

// A representative main account: harness files, a harness dir, an identity file.
try! "instructions".write(to: source.appendingPathComponent("CLAUDE.md"),
                          atomically: true, encoding: .utf8)
try! "{}".write(to: source.appendingPathComponent("settings.json"),
                atomically: true, encoding: .utf8)
try! fm.createDirectory(at: source.appendingPathComponent("skills/demo"),
                        withIntermediateDirectories: true)
try! "secret".write(to: source.appendingPathComponent(".credentials.json"),
                    atomically: true, encoding: .utf8)

let first = linkSharedHarness(from: source, to: target)
check("existing allowlisted items are linked",
      first.linked.contains("CLAUDE.md") && first.linked.contains("settings.json")
          && first.linked.contains("skills"))
check("missing allowlisted items are silently skipped",
      !first.linked.contains("hooks") && !first.kept.contains("hooks"))
check("identity files are never part of the share",
      !fm.fileExists(atPath: target.appendingPathComponent(".credentials.json").path))
check("links point at the main account",
      (try? fm.destinationOfSymbolicLink(
          atPath: target.appendingPathComponent("CLAUDE.md").path))
          == source.appendingPathComponent("CLAUDE.md").path)
check("linked dirs read through",
      fm.fileExists(atPath: target.appendingPathComponent("skills/demo").path))

// Idempotence: a second run keeps every link, creates nothing new.
let second = linkSharedHarness(from: source, to: target)
check("second run links nothing", second.linked.isEmpty)
check("second run reports everything as kept",
      second.kept.sorted() == first.linked.sorted())

// A half-shared account: the user's own file must never be replaced by a link.
let own = tmp.appendingPathComponent("claude4")
try! fm.createDirectory(at: own, withIntermediateDirectories: true)
try! "my own rules".write(to: own.appendingPathComponent("CLAUDE.md"),
                          atomically: true, encoding: .utf8)
let mixed = linkSharedHarness(from: source, to: own)
check("an existing target file is kept, not replaced",
      mixed.kept.contains("CLAUDE.md")
          && (try? String(contentsOf: own.appendingPathComponent("CLAUDE.md"),
                          encoding: .utf8)) == "my own rules")
check("the rest still links around it", mixed.linked.contains("settings.json"))

// A dangling symlink at the target is still "already there" - never replaced.
let dangling = tmp.appendingPathComponent("claude5")
try! fm.createDirectory(at: dangling, withIntermediateDirectories: true)
try! fm.createSymbolicLink(at: dangling.appendingPathComponent("CLAUDE.md"),
                           withDestinationURL: tmp.appendingPathComponent("gone"))
let third = linkSharedHarness(from: source, to: dangling)
check("a dangling target symlink is kept, not replaced",
      third.kept.contains("CLAUDE.md")
          && (try? fm.destinationOfSymbolicLink(
              atPath: dangling.appendingPathComponent("CLAUDE.md").path))
              == tmp.appendingPathComponent("gone").path)

// Link failures surface in `failed`, never vanish (read-only target dir).
try! fm.createDirectory(at: source.appendingPathComponent("projects"),
                        withIntermediateDirectories: true)
let sealed = tmp.appendingPathComponent("claude6")
try! fm.createDirectory(at: sealed, withIntermediateDirectories: true)
try! fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sealed.path)
let blocked = linkSharedHarness(from: source, to: sealed)
try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealed.path)
check("a link that cannot be created lands in failed, not nowhere",
      blocked.linked.isEmpty && !blocked.failed.isEmpty
          && blocked.failed.contains("CLAUDE.md"))

// The privacy truth: sharesProjects follows actual resolution, not this run's report.
let withProjects = tmp.appendingPathComponent("claude7")
try! fm.createDirectory(at: withProjects, withIntermediateDirectories: true)
_ = linkSharedHarness(from: source, to: withProjects)
check("linked projects reports as shared",
      sharesConversations(providerID: "claude", source: source, target: withProjects))
let ownProjects = tmp.appendingPathComponent("claude8")
try! fm.createDirectory(at: ownProjects.appendingPathComponent("projects"),
                        withIntermediateDirectories: true)
_ = linkSharedHarness(from: source, to: ownProjects)
check("an account with its OWN projects does not report as shared",
      !sharesConversations(providerID: "claude", source: source, target: ownProjects))

// The codex face: its own allowlist, its own conversation entry, identity still out.
try! "codex instructions".write(to: source.appendingPathComponent("AGENTS.md"),
                                atomically: true, encoding: .utf8)
try! "model = \"gpt\"".write(to: source.appendingPathComponent("config.toml"),
                             atomically: true, encoding: .utf8)
try! fm.createDirectory(at: source.appendingPathComponent("sessions"),
                        withIntermediateDirectories: true)
try! "auth".write(to: source.appendingPathComponent("auth.json"),
                  atomically: true, encoding: .utf8)
let codexHome = tmp.appendingPathComponent("codex2")
try! fm.createDirectory(at: codexHome, withIntermediateDirectories: true)
let codex = linkSharedHarness(from: source, to: codexHome, items: codexSharedItems)
check("codex: AGENTS.md and config.toml link",
      codex.linked.contains("AGENTS.md") && codex.linked.contains("config.toml"))
check("codex: sessions is the shared conversation record",
      sharesConversations(providerID: "codex", source: source, target: codexHome))
check("codex: auth.json is never part of the share",
      !fm.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path))
check("codex: archived conversations ride along in the record",
      codexSharedItems.contains("archived_sessions"))

// Profile v2 layers: every <name>.config.toml the main account has joins the share list.
try! "model = \"pro\"".write(to: source.appendingPathComponent("work.config.toml"),
                             atomically: true, encoding: .utf8)
try! "junk".write(to: source.appendingPathComponent("config.toml.bak"),
                  atomically: true, encoding: .utf8)
let expanded = harnessItems(for: "codex", in: source)
check("codex: named profiles are discovered dynamically",
      expanded.contains("work.config.toml") && !expanded.contains("config.toml.bak"))
check("claude list is static", harnessItems(for: "claude", in: source) == sharedHarnessItems)

// --no-share on a reused directory: OUR links go, everything else stays.
let undo = tmp.appendingPathComponent("claude9")
try! fm.createDirectory(at: undo, withIntermediateDirectories: true)
_ = linkSharedHarness(from: source, to: undo)
try! "kept".write(to: undo.appendingPathComponent("memory"),
                  atomically: true, encoding: .utf8)   // user's own file on a list name
try! fm.createSymbolicLink(at: undo.appendingPathComponent("hooks"),
                           withDestinationURL: tmp.appendingPathComponent("elsewhere"))
let removed = unlinkSharedHarness(from: source, to: undo, items: sharedHarnessItems)
check("unlink removes exactly the links pointing at the main account",
      removed.contains("CLAUDE.md") && removed.contains("projects")
          && !fm.fileExists(atPath: undo.appendingPathComponent("CLAUDE.md").path))
check("unlink keeps a user's own file even on an allowlisted name",
      (try? String(contentsOf: undo.appendingPathComponent("memory"),
                   encoding: .utf8)) == "kept")
check("unlink keeps a symlink pointing anywhere else",
      (try? fm.destinationOfSymbolicLink(atPath: undo.appendingPathComponent("hooks").path))
          == tmp.appendingPathComponent("elsewhere").path)

// MARK: - Which slot `tally add` picks

// The bug this locks (2026-07-28): a Claude Code login now lives in the KEYCHAIN and writes no
// credentials file, so a probe that only looked for `<dir>/.credentials.json` read a fully
// logged-in `~/.claude3` as an unfinished login to resume. `tally add claude` reused that home,
// exec'd claude into it, and claude found its Keychain token and opened a session on the existing
// account. Nothing errored: every step did what it was told.
//
// Both probes are injected here, so these assertions read no Keychain and do not care which
// accounts exist on the machine running them.
let noFiles: (String) -> Bool = { _ in false }
let noKeychain: (URL) -> Bool = { _ in false }
let fakeHome = URL(fileURLWithPath: "/nowhere")
func slot(base: String = ".claude", authFile: String = ".credentials.json",
          files: @escaping (String) -> Bool = noFiles,
          keychain: @escaping (URL) -> Bool = noKeychain) -> String? {
    nextFreeSlot(base: base, authFile: authFile, home: fakeHome,
                 fileExists: files, keychainLogin: keychain).map(\.name)
}

// An old-style account: the credentials file is there, no Keychain item. Still someone's login.
check("a dir with a credentials file is occupied",
      slot(files: { $0.hasSuffix("/.claude/.credentials.json") }) == ".claude2")
// THE REGRESSION LOCK: the reverse, which is what every new login looks like.
check("a keychain-only login is occupied too, not a free slot",
      slot(keychain: { $0.lastPathComponent == ".claude" }) == ".claude2")
check("and the two mix, as they do on a real machine",
      slot(files: { $0.hasSuffix("/.claude/.credentials.json") },
           keychain: { $0.lastPathComponent == ".claude2" }) == ".claude3")
// The resume case the numbering deliberately keeps: a home from an aborted login has neither, so
// it is handed back rather than skipped, and an abandoned attempt never burns a number.
check("a home with no login at all is the slot to use", slot() == ".claude")
check("an aborted login is resumed rather than skipped",
      slot(keychain: { ["\(fakeHome.path)/.claude"].contains($0.path) }) == ".claude2")
// Nowhere left to go.
check("all 99 taken has no answer", slot(keychain: { _ in true }) == nil)
check("and the file probe alone can exhaust it too", slot(files: { _ in true }) == nil)

// codex keeps its credential in a file, so the Keychain is never asked about it: a question with
// no answer there would only ever return false, and asking it invites a copy of this bug in
// reverse (a codex home judged free because the Keychain, correctly, knows nothing about it).
var codexKeychainAsks = 0
check("codex finds its own free slot from the file alone",
      slot(base: ".codex", authFile: "auth.json",
           files: { $0.hasSuffix("/.codex/auth.json") },
           keychain: { _ in codexKeychainAsks += 1; return false }) == ".codex2")
check("and the keychain is never consulted for it", codexKeychainAsks == 0)

// The name the probe asks about has to be the name the app's discovery writes, or it finds nothing
// and everything reads as "not logged in". One derivation, delegated, so they cannot drift.
check("the default config dir uses the bare service name",
      claudeKeychainService(forConfigDir: URL(fileURLWithPath: "/Users/x/.claude"))
          == "Claude Code-credentials")
check("any other dir appends 8 hex of its path hash",
      claudeKeychainService(forConfigDir: URL(fileURLWithPath: "/Users/x/.claude2"))
          .hasPrefix("Claude Code-credentials-"))
check("the suffix is exactly 8 hex characters",
      claudeKeychainService(forConfigDir: URL(fileURLWithPath: "/Users/x/.claude2"))
          .dropFirst("Claude Code-credentials-".count).count == 8)
check("the same dir always derives the same name",
      claudeKeychainService(forConfigDir: URL(fileURLWithPath: "/Users/x/.claude2"))
          == claudeKeychainService(forConfigDir: URL(fileURLWithPath: "/Users/x/.claude2")))
check("and two dirs never share one",
      claudeKeychainService(forConfigDir: URL(fileURLWithPath: "/Users/x/.claude2"))
          != claudeKeychainService(forConfigDir: URL(fileURLWithPath: "/Users/x/.claude3")))
// Measured against the real machine this bug was found on (2026-07-28): `~/.claude3` there is a
// keychain-only login under exactly this service name, so the derivation is pinned to a value
// observed in the wild rather than to itself.
check("the derivation matches the name observed on the affected machine",
      claudeKeychainService(forConfigDir: URL(fileURLWithPath: "/Users/albertliu/.claude3"))
          == "Claude Code-credentials-72082ca3")

// The app side must go through that same function rather than keeping its own copy.
let accountsSource = (try? String(contentsOfFile: "Tally/Providers/Claude/ClaudeAccounts.swift",
                                  encoding: .utf8)) ?? ""
check("the app's discovery source is readable from this suite", !accountsSource.isEmpty)
check("the app delegates its service name instead of deriving one",
      accountsSource.contains("claudeKeychainService(forConfigDir: dir)"))
check("and keeps no second copy of the hash rule",
      !accountsSource.contains("SHA256.hash"))

// MARK: - Folder trust carried to a new account

// Why this exists: `.claude.json` is deliberately NOT shared (it is an identity file that every
// session rewrites), so a newly added account re-asks "do you trust this folder?" for every project
// the user already vouched for on the main account. `tally add` seeds the ANSWERS instead of sharing
// the file. Measured against claude 2.1.220 on 2026-07-28: a pre-seeded projects map is merged, not
// reset, and the control (same config dir, a cwd absent from the map) still showed the dialog.

// The asymmetry that makes this easy to get wrong: the default home keeps its state ABOVE itself.
check("the default config dir keeps its state at the home root",
      claudeStateFile(forConfigDir: URL(fileURLWithPath: "/Users/x/.claude")).path
          == "/Users/x/.claude.json")
check("every other config dir keeps its own",
      claudeStateFile(forConfigDir: URL(fileURLWithPath: "/Users/x/.claude2")).path
          == "/Users/x/.claude2/.claude.json")

// The app reads that same file for the card's plan and email, so it must ask the same function.
// Its own copy of the rule was wrong (2026-08-03): it read `~/.claude/.claude.json`, a leftover
// that agreed with the real file until the default account was signed in as somebody else.
check("the app's profile reader delegates the state path",
      accountsSource.contains("= claudeStateFile(forConfigDir:"))
check("and keeps no second copy of the path rule",
      !accountsSource.contains("appendingPathComponent(\".claude.json\")"))

// The seed carries accepted paths and nothing else. The source below is shaped like the real file:
// identity at the top level, per-project history inside each entry, and one project the user
// declined.
let stateBody = """
{
  "oauthAccount": {"emailAddress": "someone@example.com", "accountUuid": "u-1"},
  "userID": "deadbeef",
  "projects": {
    "/Users/x/work/a": {"hasTrustDialogAccepted": true, "lastVersionBase": "2.1.220",
                        "projectOnboardingSeenCount": 3},
    "/Users/x/work/b": {"hasTrustDialogAccepted": true},
    "/Users/x/work/declined": {"hasTrustDialogAccepted": false},
    "/Users/x/work/unanswered": {"lastVersionBase": "2.1.220"}
  }
}
"""
let seed = trustedProjectSeed(fromState: Data(stateBody.utf8))
check("every accepted path is carried", seed.count == 2 && seed["/Users/x/work/a"] != nil
      && seed["/Users/x/work/b"] != nil)
check("a folder the user declined is not carried", seed["/Users/x/work/declined"] == nil)
check("and neither is one they were never asked about", seed["/Users/x/work/unanswered"] == nil)
// The entries are REDUCED, not copied: the new account inherits the answer, not the history.
check("an accepted entry carries the single fact and nothing else",
      seed["/Users/x/work/a"] == ["hasTrustDialogAccepted": true])
// The identity guard, stated as its own assertion because it is the one that matters if this ever
// grows: no top-level field of the source may reach the seed.
let encoded = String(decoding: (try? JSONSerialization.data(withJSONObject: ["projects": seed])) ?? Data(),
                     as: UTF8.self)
check("the seed carries no account identity",
      !encoded.contains("oauthAccount") && !encoded.contains("someone@example.com")
          && !encoded.contains("deadbeef") && !encoded.contains("accountUuid"))
check("nor any per-project history", !encoded.contains("lastVersionBase")
      && !encoded.contains("projectOnboardingSeenCount"))
// Malformed or trust-free input is simply nothing to do, never a crash.
check("a state file with no projects map seeds nothing",
      trustedProjectSeed(fromState: Data("{\"userID\":\"x\"}".utf8)).isEmpty)
check("an unreadable body seeds nothing",
      trustedProjectSeed(fromState: Data("not json".utf8)).isEmpty)

// Writing it: only into a home that has no state file yet.
let seedRoot = tmp.appendingPathComponent("seed-\(UUID().uuidString)")
let seedSource = seedRoot.appendingPathComponent(".claude")
let seedTarget = seedRoot.appendingPathComponent(".claude4")
try! fm.createDirectory(at: seedSource, withIntermediateDirectories: true)
try! fm.createDirectory(at: seedTarget, withIntermediateDirectories: true)
// The source is the DEFAULT home, so its state lives at the root beside it, not inside it.
try! stateBody.write(to: seedRoot.appendingPathComponent(".claude.json"),
                     atomically: true, encoding: .utf8)
check("seeding reports how many projects it carried", seedFolderTrust(from: seedSource, to: seedTarget) == 2)
let written = (try? Data(contentsOf: seedTarget.appendingPathComponent(".claude.json")))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
check("the new home now has a state file with just the trust map",
      (written?["projects"] as? [String: Any])?.count == 2 && written?.count == 1)
// An aborted login left its own file here: that one is the account's, and must not be overwritten.
check("an existing state file is never overwritten", seedFolderTrust(from: seedSource, to: seedTarget) == 0)
check("and its contents are left exactly as they were",
      ((try? Data(contentsOf: seedTarget.appendingPathComponent(".claude.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?.count == 1)
// Nothing to carry, nothing written: a first-ever account has no trusted folders to pass on.
let bareSource = seedRoot.appendingPathComponent(".bare")
let bareTarget = seedRoot.appendingPathComponent(".claude5")
try! fm.createDirectory(at: bareSource, withIntermediateDirectories: true)
try! "{}".write(to: bareSource.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
check("a source with nothing trusted writes no file at all",
      seedFolderTrust(from: bareSource, to: bareTarget) == 0
          && !fm.fileExists(atPath: bareTarget.appendingPathComponent(".claude.json").path))
check("and a source with no state file at all is simply a no-op",
      seedFolderTrust(from: seedRoot.appendingPathComponent(".missing"), to: bareTarget) == 0)

// MARK: - Preparing a new account's home, end to end

// The whole act as both surfaces perform it (`tally add` and Settings' "Add account"): pick the
// slot, create the home, link the share, seed the trust. Behavioural rather than textual, and run
// against a throwaway home directory - the Keychain probe is injected as "nothing is logged in", so
// this reads no Keychain and does not care what accounts the machine running it has.
let realFiles: (String) -> Bool = { fm.fileExists(atPath: $0) }
let addRoot = tmp.appendingPathComponent("add-\(UUID().uuidString)")
let addMain = addRoot.appendingPathComponent(".claude")
try! fm.createDirectory(at: addMain.appendingPathComponent("skills"), withIntermediateDirectories: true)
try! "instructions".write(to: addMain.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
try! fm.createDirectory(at: addMain.appendingPathComponent("projects"), withIntermediateDirectories: true)
// The main account is LOGGED IN (that is what makes it occupied), and its state file - the trust
// source - sits one level up because it is the default home.
try! "secret".write(to: addMain.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
try! stateBody.write(to: addRoot.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

let prepared = try! prepareAddedAccountHome(providerID: "claude", share: true, home: addRoot,
                                            fileExists: realFiles, keychainLogin: noKeychain)
check("the new home is the next number, not the occupied main one", prepared.name == ".claude2")
check("and it exists on disk before any login is started",
      fm.fileExists(atPath: prepared.dir.path))
check("the main account's harness is linked into it",
      prepared.linked.contains("CLAUDE.md") && prepared.linked.contains("skills"))
check("identity never rides along",
      !fm.fileExists(atPath: prepared.dir.appendingPathComponent(".credentials.json").path))
check("the conversation record is shared, and reported as shared", prepared.sharesConversations)
check("folder trust is carried over", prepared.trustSeeded == 2)
check("as a state file holding the trust map and nothing else",
      ((try? Data(contentsOf: prepared.dir.appendingPathComponent(".claude.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?.count == 1)
check("and this is not the main home", !prepared.isMainHome && prepared.unlinked.isEmpty)

// Opting out on the SAME home: an unfinished login hands the number back, so this is the directory
// the previous run left, links and all - and they have to go.
let optedOut = try! prepareAddedAccountHome(providerID: "claude", share: false, home: addRoot,
                                            fileExists: realFiles, keychainLogin: noKeychain)
check("the unfinished home is resumed rather than skipped", optedOut.name == ".claude2")
check("opting out removes the earlier run's share links",
      optedOut.unlinked.contains("CLAUDE.md") && optedOut.linked.isEmpty
          && !fm.fileExists(atPath: prepared.dir.appendingPathComponent("CLAUDE.md").path))
// The other half of that undo, and the one it shipped without (2026-08-03): the first, shared
// attempt also SEEDED folder trust into this home, so opting out while that file stayed left the
// new account skipping the trust prompt for every project the main account vouched for - while the
// sheet said it starts empty.
check("opting out removes the folder trust the earlier run seeded", optedOut.trustCleared == 2)
check("…so the resumed home really is empty of the main account's answers",
      !fm.fileExists(atPath: optedOut.dir.appendingPathComponent(".claude.json").path))
// And only ever OUR file. A state file the account (or the user) has written to belongs to them.
let ownedRoot = tmp.appendingPathComponent("owned-\(UUID().uuidString)")
let ownedMain = ownedRoot.appendingPathComponent(".claude")
try! fm.createDirectory(at: ownedMain, withIntermediateDirectories: true)
try! "secret".write(to: ownedMain.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
try! stateBody.write(to: ownedRoot.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
let ownedTarget = ownedRoot.appendingPathComponent(".claude2")
try! fm.createDirectory(at: ownedTarget, withIntermediateDirectories: true)
try! stateBody.write(to: ownedTarget.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
let keptState = try! prepareAddedAccountHome(providerID: "claude", share: false, home: ownedRoot,
                                             fileExists: realFiles, keychainLogin: noKeychain)
check("a state file the account itself wrote is never removed",
      keptState.trustCleared == 0
          && fm.fileExists(atPath: ownedTarget.appendingPathComponent(".claude.json").path))
// The shape that tells the two apart, asserted on its own: the seed is one top-level key whose
// every entry is the single accepted fact, and anything else has somebody's data in it.
check("a pure seed is recognised, and counted",
      untouchedTrustSeedCount(Data("{\"projects\":{\"/a\":{\"hasTrustDialogAccepted\":true}}}".utf8)) == 1)
check("a seed with any other top-level field is not ours",
      untouchedTrustSeedCount(Data("{\"userID\":\"x\",\"projects\":{\"/a\":{\"hasTrustDialogAccepted\":true}}}".utf8)) == nil)
check("nor is one whose entries carry per-project history",
      untouchedTrustSeedCount(Data("{\"projects\":{\"/a\":{\"hasTrustDialogAccepted\":true,\"lastVersionBase\":\"2.1\"}}}".utf8)) == nil)
check("nor one holding an answer the seed never writes",
      untouchedTrustSeedCount(Data("{\"projects\":{\"/a\":{\"hasTrustDialogAccepted\":false}}}".utf8)) == nil)
check("an empty map is not a seed either, so an unknown file is left alone",
      untouchedTrustSeedCount(Data("{\"projects\":{}}".utf8)) == nil)
check("and neither is a body that is not JSON at all",
      untouchedTrustSeedCount(Data("not json".utf8)) == nil)
// Sharing again never removes anything: the undo belongs to the opt-out alone.
let resharedRoot = tmp.appendingPathComponent("reshare-\(UUID().uuidString)")
let resharedMain = resharedRoot.appendingPathComponent(".claude")
try! fm.createDirectory(at: resharedMain, withIntermediateDirectories: true)
try! "secret".write(to: resharedMain.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
try! stateBody.write(to: resharedRoot.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
let reshared = try! prepareAddedAccountHome(providerID: "claude", share: true, home: resharedRoot,
                                            fileExists: realFiles, keychainLogin: noKeychain)
let resharedAgain = try! prepareAddedAccountHome(providerID: "claude", share: true, home: resharedRoot,
                                                 fileExists: realFiles, keychainLogin: noKeychain)
check("a second shared run clears nothing and keeps the seed it already wrote",
      reshared.trustCleared == 0 && resharedAgain.trustCleared == 0
          && fm.fileExists(atPath: reshared.dir.appendingPathComponent(".claude.json").path))

// codex: its own allowlist, and no trust seeding at all (it has no such prompt).
let codexMain = addRoot.appendingPathComponent(".codex")
try! fm.createDirectory(at: codexMain, withIntermediateDirectories: true)
try! "auth".write(to: codexMain.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
try! "codex instructions".write(to: codexMain.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
let codexPrepared = try! prepareAddedAccountHome(providerID: "codex", share: true, home: addRoot,
                                                 fileExists: realFiles, keychainLogin: noKeychain)
check("codex gets its own numbered home", codexPrepared.name == ".codex2")
check("with its own allowlist linked", codexPrepared.linked.contains("AGENTS.md"))
check("no trust is seeded for a provider that never asks", codexPrepared.trustSeeded == 0
      && !fm.fileExists(atPath: codexPrepared.dir.appendingPathComponent(".claude.json").path))

// The first-ever account: there is nothing to share FROM, and nothing is invented.
let bareRoot = tmp.appendingPathComponent("bare-\(UUID().uuidString)")
try! fm.createDirectory(at: bareRoot, withIntermediateDirectories: true)
let firstEver = try! prepareAddedAccountHome(providerID: "claude", share: true, home: bareRoot,
                                             fileExists: realFiles, keychainLogin: noKeychain)
check("the first account IS the main home", firstEver.isMainHome && firstEver.name == ".claude")
check("and nothing is linked into it", firstEver.linked.isEmpty && firstEver.kept.isEmpty
      && !firstEver.sharesConversations && firstEver.trustSeeded == 0)

// Nowhere left to go is an error the surface can show, not a home pointed at nothing.
var exhausted: AddAccountFailure?
do {
    _ = try prepareAddedAccountHome(providerID: "claude", share: true, home: addRoot,
                                    fileExists: { _ in true }, keychainLogin: noKeychain)
} catch let failure as AddAccountFailure {
    exhausted = failure
} catch {}
check("all 99 taken is reported as a failure, not a directory",
      exhausted == .noFreeSlot(base: ".claude"))

// A home that cannot be created is reported too, rather than handed to a login that would fail
// later, further from the cause, and with a message about the provider instead.
let sealedRoot = tmp.appendingPathComponent("sealed-\(UUID().uuidString)")
try! fm.createDirectory(at: sealedRoot, withIntermediateDirectories: true)
try! fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sealedRoot.path)
var blockedFailure: AddAccountFailure?
do {
    _ = try prepareAddedAccountHome(providerID: "claude", share: true, home: sealedRoot,
                                    fileExists: realFiles, keychainLogin: noKeychain)
} catch let failure as AddAccountFailure {
    blockedFailure = failure
} catch {}
try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealedRoot.path)
check("a home that cannot be created is a reported failure",
      blockedFailure == .couldNotCreateHome(path: sealedRoot.appendingPathComponent(".claude").path))

// MARK: - "Is there a login in this home?", asked by both sides of the flow

// One rule, two callers with opposite intent: the slot walk SKIPS a home that has a login, and the
// add flow concludes a login FINISHED because one appeared in the home it created. A second copy of
// the two-generation probe would have Tally hand out a home it also considers signed in.
let claudeBase = ".claude", claudeAuth = ".credentials.json"
let occupied = tmp.appendingPathComponent(".claude2")
check("a credentials file means somebody's login is in there",
      addAccountHomeHasLogin(base: claudeBase, authFile: claudeAuth, dir: occupied,
                             fileExists: { $0.hasSuffix("/.claude2/.credentials.json") },
                             keychainLogin: noKeychain))
check("and so does a keychain-only login, which is what a new one looks like",
      addAccountHomeHasLogin(base: claudeBase, authFile: claudeAuth, dir: occupied,
                             fileExists: noFiles, keychainLogin: { $0.lastPathComponent == ".claude2" }))
check("an empty home has neither", !addAccountHomeHasLogin(base: claudeBase, authFile: claudeAuth,
                                                           dir: occupied, fileExists: noFiles,
                                                           keychainLogin: noKeychain))
var codexAsks = 0
check("codex reads its file alone",
      addAccountHomeHasLogin(base: ".codex", authFile: "auth.json", dir: occupied,
                             fileExists: { $0.hasSuffix("auth.json") },
                             keychainLogin: { _ in codexAsks += 1; return false }))
check("…and the keychain is never asked about it", codexAsks == 0)
// The same question by provider id, which is what the app's re-check holds.
check("the provider-shaped wrapper agrees with the base-shaped one",
      addedAccountHomeHasLogin(providerID: "claude", dir: occupied, fileExists: noFiles,
                               keychainLogin: { $0.lastPathComponent == ".claude2" })
          && !addedAccountHomeHasLogin(providerID: "codex", dir: occupied, fileExists: noFiles,
                                       keychainLogin: { _ in true }))
// The two callers cannot disagree: a home the slot walk skipped is one this says holds a login.
let takenProbe: (String) -> Bool = { $0.hasSuffix("/.claude/.credentials.json") }
check("what the slot walk skips is exactly what reads as signed in",
      slot(files: takenProbe) == ".claude2"
          && addedAccountHomeHasLogin(providerID: "claude",
                                      dir: fakeHome.appendingPathComponent(".claude"),
                                      fileExists: takenProbe, keychainLogin: noKeychain))

// MARK: - One login at a time (the add-account sheet's state machine)

// Tally can start a provider login two ways against ONE config home: in the background from the
// sheet, and in a Terminal window the user drives. It only ever sees the end of the first
// (LoginTerminalFallback waits for the WINDOW to open, not for the login running inside it), and two
// logins racing on one home fight over the credential they each mean to leave there. So the retry is
// withheld for as long as a Terminal handoff might still be working, and only the user can end it.
let handedOff = AddAccountPhase.pending(name: ".claude2", reason: "r", handoff: .terminal)
let onItsOwn = AddAccountPhase.pending(name: ".claude2", reason: "r", handoff: .none)
let copied = AddAccountPhase.pending(name: ".claude2", reason: "r", handoff: .clipboard)

// THE LOCK. Everything else on this screen is a consequence of this one line.
check("a live Terminal handoff withholds the in-app retry", !handedOff.allowsNewRun)
check("…and offers the only thing that can end it instead",
      handedOff.allowsRecheck && !handedOff.allowsTerminalHandoff)
check("an unfinished login nothing else is working on can simply be retried",
      onItsOwn.allowsNewRun && onItsOwn.allowsTerminalHandoff && !onItsOwn.allowsRecheck)
check("a Terminal that refused leaves nothing running, so the retry is back",
      copied.allowsNewRun && copied.allowsTerminalHandoff && !copied.allowsRecheck)
check("while Tally's own attempt is running, nothing else may start",
      !AddAccountPhase.preparing.allowsNewRun
          && !AddAccountPhase.signingIn(name: ".claude2").allowsNewRun
          && AddAccountPhase.preparing.isRunning
          && AddAccountPhase.signingIn(name: ".claude2").isRunning)
check("a finished or never-started flow is neither running nor holding a login",
      AddAccountPhase.idle.allowsNewRun && AddAccountPhase.failed(reason: "r").allowsNewRun
          && AddAccountPhase.added(prepared).allowsNewRun
          && !AddAccountPhase.added(prepared).isRunning
          && !AddAccountPhase.added(prepared).holdsTerminalLogin)
// Only a pending phase can hand off or be re-checked - the buttons exist nowhere else.
check("no other phase offers a Terminal handoff or a re-check",
      ![AddAccountPhase.idle, .preparing, .signingIn(name: ".claude2"), .added(prepared),
        .failed(reason: "r")]
        .contains { $0.allowsTerminalHandoff || $0.allowsRecheck })

// A finished add carries the preparation REPORT, not just a directory name. The share is
// best-effort by design (a permission can refuse a link, a resumed home can already hold its own
// file), so a success that kept only the name had nothing left to disclose an incomplete share
// with, and said "Account added" over one that never fully happened.
if case .added(let landed) = AddAccountPhase.added(prepared) {
    check("the finished phase carries what preparing the home actually did",
          landed == prepared && landed.name == ".claude2")
} else {
    check("the finished phase carries what preparing the home actually did", false)
}

// The rule is only worth having if the surfaces ASK it. Both do, and both are pinned here: the
// store gates starting and resetting on it, and the sheet gates the button.
let sheetSource = (try? String(contentsOfFile: "Tally/Views/SettingsAddAccountView.swift",
                               encoding: .utf8)) ?? ""
let storeSource = (try? String(contentsOfFile: "Tally/Stores/AddAccountStore.swift",
                               encoding: .utf8)) ?? ""
check("both surfaces are readable from this suite", !sheetSource.isEmpty && !storeSource.isEmpty)
check("the store gates starting AND resetting on the one rule",
      storeSource.components(separatedBy: "guard phase.allowsNewRun").count == 3)
if let gate = sheetSource.range(of: "if flow.phase.allowsNewRun"),
   let retry = sheetSource.range(of: "Button(L(\"Try again\"))") {
    check("the sheet's retry button is behind that gate", gate.lowerBound < retry.lowerBound)
} else {
    check("the sheet's retry button is behind that gate", false)
}
// And the fallback is a CHOICE now, not something that starts underneath the retry: a window opened
// by the failure branch itself is the race, already armed, with "Try again" sitting on top of it.
let opensTerminal = storeSource.components(separatedBy: "LoginTerminalFallback.openTerminal")
if let handoff = storeSource.range(of: "func handOffToTerminal()"),
   let call = storeSource.range(of: "LoginTerminalFallback.openTerminal") {
    check("the one call that opens a Terminal window lives in the handoff, not in the run",
          opensTerminal.count == 2 && call.lowerBound > handoff.lowerBound)
} else {
    check("the one call that opens a Terminal window lives in the handoff, not in the run", false)
}
check("and the re-check asks the home rather than taking the user's word",
      storeSource.contains("addedAccountHomeHasLogin("))
check("the sheet discloses each way a share can fall short of what was asked for",
      sheetSource.contains("prepared.failed") && sheetSource.contains("prepared.kept")
          && sheetSource.contains("prepared.sharesConversations"))

// MARK: - One implementation, two surfaces

// The CLI and the app both go THROUGH the shared preparation above. A second copy on either side is
// what would put them on different account numbers, or have one share a set the other does not -
// and neither drift shows up in a type check.
let addSource = (try? String(contentsOfFile: "TallyCLI/AddCommand.swift", encoding: .utf8)) ?? ""
let appFlowSource = (try? String(contentsOfFile: "Tally/Stores/AddAccountStore.swift",
                                 encoding: .utf8)) ?? ""
check("both call sites are readable from this suite", !addSource.isEmpty && !appFlowSource.isEmpty)
check("the CLI delegates the preparation", addSource.contains("prepareAddedAccountHome("))
check("and keeps no second copy of the slot or the share",
      !addSource.contains("nextFreeSlot(") && !addSource.contains("linkSharedHarness(")
          && !addSource.contains("seedFolderTrust("))
check("the app delegates the same preparation", appFlowSource.contains("prepareAddedAccountHome("))
check("and keeps no second copy either",
      !appFlowSource.contains("nextFreeSlot(") && !appFlowSource.contains("linkSharedHarness(")
          && !appFlowSource.contains("seedFolderTrust("))
check("the CLI's login message still promises no wait",
      addSource.contains("as soon as the login completes") && !addSource.contains("within a minute"))

try? fm.removeItem(at: tmp)
print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
