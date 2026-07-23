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

try? fm.removeItem(at: tmp)
print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
