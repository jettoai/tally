import Foundation

// Assertion harness for the first-run-wizard seed a finished login leaves behind
// (Tally/Core/ClaudeOnboarding.swift).
//
// Every assertion runs against a fake home directory this file builds, so the suite reads no real
// account, writes to no real config home and never starts a provider CLI.

var passed = 0, failed = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func read(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return [:] }
    return root
}

// MARK: The merge itself

// A state file a real login leaves: an identity, per-project history, nothing about onboarding.
let signedIn = json(["oauthAccount": ["emailAddress": "a@example.com"],
                     "projects": ["/tmp/x": ["hasTrustDialogAccepted": true]],
                     "numStartups": 3])
let merged = claudeOnboardingSeed(intoState: signedIn, donorVersion: { "2.1.220" })
let mergedRoot = (try? JSONSerialization.jsonObject(with: merged ?? Data())) as? [String: Any] ?? [:]
check("the wizard's key is added", mergedRoot["hasCompletedOnboarding"] as? Bool == true)
check("a donor version is carried over", mergedRoot["lastOnboardingVersion"] as? String == "2.1.220")
check("the account's identity survives",
      ((mergedRoot["oauthAccount"] as? [String: Any])?["emailAddress"] as? String)
          == "a@example.com")
check("per-project history survives",
      ((mergedRoot["projects"] as? [String: Any])?["/tmp/x"] as? [String: Any])?[
          "hasTrustDialogAccepted"] as? Bool == true)
check("unrelated keys survive", mergedRoot["numStartups"] as? Int == 3)

check("no state file yet is a file to create",
      (claudeOnboardingSeed(intoState: nil, donorVersion: { nil })).map {
          ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?[
              "hasCompletedOnboarding"] as? Bool == true
      } == true)
check("an empty file is treated as no file",
      claudeOnboardingSeed(intoState: Data(), donorVersion: { nil }) != nil)

check("a home already past the wizard is left alone",
      claudeOnboardingSeed(intoState: json(["hasCompletedOnboarding": true]),
                           donorVersion: { "2.1.220" }) == nil)
check("an explicit false is flipped",
      ((try? JSONSerialization.jsonObject(
          with: claudeOnboardingSeed(intoState: json(["hasCompletedOnboarding": false]),
                                     donorVersion: { nil }) ?? Data())) as? [String: Any])?[
          "hasCompletedOnboarding"] as? Bool == true)

let keptVersion = claudeOnboardingSeed(intoState: json(["lastOnboardingVersion": "1.0.77"]),
                                       donorVersion: { "2.1.220" })
check("a version already recorded is never rewritten",
      ((try? JSONSerialization.jsonObject(with: keptVersion ?? Data())) as? [String: Any])?[
          "lastOnboardingVersion"] as? String == "1.0.77")
let noDonor = claudeOnboardingSeed(intoState: nil, donorVersion: { nil })
check("no donor means the version key is simply omitted",
      ((try? JSONSerialization.jsonObject(with: noDonor ?? Data())) as? [String: Any])?[
          "lastOnboardingVersion"] == nil)
check("an empty donor version is not written",
      ((try? JSONSerialization.jsonObject(
          with: claudeOnboardingSeed(intoState: nil, donorVersion: { "" }) ?? Data()))
          as? [String: Any])?["lastOnboardingVersion"] == nil)

check("a state file that cannot be parsed is refused, not replaced",
      claudeOnboardingSeed(intoState: Data("{not json".utf8), donorVersion: { nil }) == nil)
check("a JSON document that is not an object is refused too",
      claudeOnboardingSeed(intoState: Data("[1,2,3]".utf8), donorVersion: { nil }) == nil)

// The donor lookup costs file reads, so it must not happen for a home that needs nothing.
var donorAsked = 0
_ = claudeOnboardingSeed(intoState: json(["hasCompletedOnboarding": true]),
                         donorVersion: { donorAsked += 1; return nil })
check("the donor is not looked up when nothing will be written", donorAsked == 0)

// MARK: Against a fake machine

let fm = FileManager.default
let userHome = fm.temporaryDirectory.appendingPathComponent("tally-onboarding-\(UUID())")
let main = userHome.appendingPathComponent(".claude")
let neighbour = userHome.appendingPathComponent(".claude4")
let fresh = userHome.appendingPathComponent(".claude5")
for dir in [main, neighbour, fresh] {
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
}
// The default home keeps its state one level up; the numbered ones keep it inside.
// Two homes that have been through the wizard, recording DIFFERENT versions, so the walk's order
// and its exclusion are both visible in the answer.
let mainState = userHome.appendingPathComponent(".claude.json")
try! json(["hasCompletedOnboarding": true, "lastOnboardingVersion": "1.0.77",
           "oauthAccount": ["emailAddress": "main@example.com"]]).write(to: mainState)
let neighbourState = neighbour.appendingPathComponent(".claude.json")
let neighbourBefore = json(["hasCompletedOnboarding": true, "lastOnboardingVersion": "2.1.220",
                            "oauthAccount": ["emailAddress": "four@example.com"]])
try! neighbourBefore.write(to: neighbourState)
// The home the login just landed in: signed in, never launched.
let freshState = fresh.appendingPathComponent(".claude.json")
try! json(["oauthAccount": ["emailAddress": "new@example.com"]]).write(to: freshState)

check("a home that just signed in is seeded",
      markClaudeOnboardingComplete(providerID: "claude", home: fresh.path, userHome: userHome))
check("the seeded home is past the wizard",
      read(freshState)["hasCompletedOnboarding"] as? Bool == true)
check("the version comes from a home that has one",
      read(freshState)["lastOnboardingVersion"] as? String == "1.0.77")
check("the login's own identity is still there",
      ((read(freshState)["oauthAccount"] as? [String: Any])?["emailAddress"] as? String)
          == "new@example.com")
check("no other home is touched", (try! Data(contentsOf: neighbourState)) == neighbourBefore)

check("a second run writes nothing",
      !markClaudeOnboardingComplete(providerID: "claude", home: fresh.path, userHome: userHome))
let settled = try! Data(contentsOf: freshState)
_ = markClaudeOnboardingComplete(providerID: "claude", home: fresh.path, userHome: userHome)
check("and leaves the file byte for byte", (try! Data(contentsOf: freshState)) == settled)

// codex has no wizard and no such file: the errand must not create one.
let codex = userHome.appendingPathComponent(".codex2")
try! fm.createDirectory(at: codex, withIntermediateDirectories: true)
check("codex is never seeded",
      !markClaudeOnboardingComplete(providerID: "codex", home: codex.path, userHome: userHome))
check("codex gets no state file",
      !fm.fileExists(atPath: codex.appendingPathComponent(".claude.json").path))
check("an empty home path is refused",
      !markClaudeOnboardingComplete(providerID: "claude", home: "", userHome: userHome))

// The default home's state file lives one level UP, and this is the path rule that decides it.
let bareHome = fm.temporaryDirectory.appendingPathComponent("tally-onboarding-bare-\(UUID())")
let bareMain = bareHome.appendingPathComponent(".claude")
try! fm.createDirectory(at: bareMain, withIntermediateDirectories: true)
check("the default home is seeded too",
      markClaudeOnboardingComplete(providerID: "claude", home: bareMain.path, userHome: bareHome))
check("…at ~/.claude.json, not inside the directory",
      read(bareHome.appendingPathComponent(".claude.json"))["hasCompletedOnboarding"] as? Bool
          == true
          && !fm.fileExists(atPath: bareMain.appendingPathComponent(".claude.json").path))
check("a machine with only one home records no version",
      read(bareHome.appendingPathComponent(".claude.json"))["lastOnboardingVersion"] == nil)

// MARK: A state file that IS there and cannot be read

// The case a bare `try?` answered nil to, exactly as it answers nil to "no file at all": a home
// full of somebody's state, whose file is unreadable and replaceable at the same time. An atomic
// write needs no permission on the target, only on the parent directory, so one historical `sudo
// claude` (root-owned 0600 state file) is enough to reach this. Mode 000 is how the suite gets
// there without a root-owned file; running the suite AS root would read it anyway, and the
// assertion is deliberately left to fail loudly in that case rather than quietly skip.
let locked = userHome.appendingPathComponent(".claude6")
try! fm.createDirectory(at: locked, withIntermediateDirectories: true)
let lockedState = locked.appendingPathComponent(".claude.json")
let lockedBefore = json(["oauthAccount": ["emailAddress": "locked@example.com"],
                         "projects": ["/tmp/y": ["hasTrustDialogAccepted": true]]])
try! lockedBefore.write(to: lockedState)
try! fm.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedState.path)
check("a state file that cannot be READ is refused, not replaced",
      !markClaudeOnboardingComplete(providerID: "claude", home: locked.path, userHome: userHome))
// Restored before reading it back, and so the harness can clean up after itself either way.
try! fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockedState.path)
check("…and is left byte for byte", (try! Data(contentsOf: lockedState)) == lockedBefore)

// MARK: The sweep `tally add` runs (Tally/Core/AddAccount.swift)

// The app is not always running, so the CLI's marker sweep is the other place a home Tally created
// is first seen signed in - and the marker is gone for whoever gets there second. A sweep that
// cleared without seeding put the wizard back for that home.
let sweepHome = fm.temporaryDirectory.appendingPathComponent("tally-onboarding-sweep-\(UUID())")
let swept = sweepHome.appendingPathComponent(".claude2")
let unfinished = sweepHome.appendingPathComponent(".claude3")
for dir in [swept, unfinished] {
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try! Data("{}".utf8).write(to: dir.appendingPathComponent(addAccountPendingMarker))
}
let sweptState = swept.appendingPathComponent(".claude.json")
try! json(["oauthAccount": ["emailAddress": "swept@example.com"]]).write(to: sweptState)
// A login that landed: the older credentials-file shape, so the assertion needs no Keychain.
try! "token".write(to: swept.appendingPathComponent(".credentials.json"), atomically: true,
                   encoding: .utf8)
let realFiles = { (path: String) in fm.fileExists(atPath: path) }
let noKeychain = { (_: URL) in false }
check("the sweep clears the marker of a home whose login has landed",
      clearFinishedPendingMarkers(providerID: "claude", home: sweepHome, fileExists: realFiles,
                                  keychainLogin: noKeychain) == [".claude2"])
check("…and leaves the wizard's note as it clears",
      read(sweptState)["hasCompletedOnboarding"] as? Bool == true)
check("…without disturbing the login's identity",
      ((read(sweptState)["oauthAccount"] as? [String: Any])?["emailAddress"] as? String)
          == "swept@example.com")
check("a pending home with no login yet is neither swept nor seeded",
      clearFinishedPendingMarkers(providerID: "claude", home: sweepHome, fileExists: realFiles,
                                  keychainLogin: noKeychain).isEmpty
          && fm.fileExists(atPath: unfinished.appendingPathComponent(addAccountPendingMarker).path)
          && !fm.fileExists(atPath: unfinished.appendingPathComponent(".claude.json").path))

// The donor walk reads neighbours and excludes the home being seeded: with ~/.claude excluded the
// answer has to come from ~/.claude4, which recorded a different version.
check("the walk answers with the first home that has a version",
      claudeOnboardingDonorVersion(excluding: fresh, userHome: userHome) == "1.0.77")
check("the home being seeded is not its own donor",
      claudeOnboardingDonorVersion(excluding: main, userHome: userHome) == "2.1.220")
check("a machine with no other home has no donor",
      claudeOnboardingDonorVersion(excluding: bareMain, userHome: bareHome) == nil)

try? fm.removeItem(at: userHome)
try? fm.removeItem(at: bareHome)
try? fm.removeItem(at: sweepHome)

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
