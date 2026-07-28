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

// The wiring: claude only (codex has no such prompt), and only when sharing.
let addSource = (try? String(contentsOfFile: "TallyCLI/AddCommand.swift", encoding: .utf8)) ?? ""
check("the add command source is readable", !addSource.isEmpty)
check("trust is seeded only when sharing, and only for claude",
      addSource.contains("if share, provider.id == \"claude\", dir.path != mainHome.path"))
check("and the login message no longer promises a wait",
      addSource.contains("as soon as the login completes") && !addSource.contains("within a minute"))

try? fm.removeItem(at: tmp)
print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
