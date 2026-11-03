import Foundation

// The welcome window's rules: which screen detection picks, when the window may open by itself,
// what the preview flag walks. Pure checks against WelcomeFlow.swift, plus three source locks for
// the orderings a type check cannot see.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// MARK: detection

let none: (String) -> Bool = { _ in false }
let both: (String) -> Bool = { _ in true }
expect(WelcomeFlow.verdict(signedInAccounts: 2, installed: none) == .found,
       "a signed-in account is found even with no CLI on the PATH")
expect(WelcomeFlow.verdict(signedInAccounts: 1, installed: both) == .found,
       "found wins over an installed CLI")
expect(WelcomeFlow.verdict(signedInAccounts: 0, installed: both) == .signIn(providerID: "claude"),
       "both CLIs installed and nobody signed in goes to Claude's sign-in first")
expect(WelcomeFlow.verdict(signedInAccounts: 0, installed: { $0 == "codex" }) == .signIn(providerID: "codex"),
       "only Codex installed goes to Codex's sign-in")
expect(WelcomeFlow.verdict(signedInAccounts: 0, installed: none) == .needsCLI(providerID: "claude"),
       "neither CLI installed offers Claude Code's install")

// MARK: install commands

expect(WelcomeFlow.installCommand(providerID: "claude") == "curl -fsSL https://claude.ai/install.sh | bash",
       "Claude Code's official installer line")
expect(WelcomeFlow.installCommand(providerID: "codex") == "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
       "Codex's official installer line")
expect(WelcomeFlow.otherProvider("claude") == "codex" && WelcomeFlow.otherProvider("codex") == "claude",
       "the other provider flips both ways")

// MARK: when the window opens by itself

func show(seen: Bool = false, before: Bool = false, restored: Bool = false, record: Bool = true,
          forced: Bool = false, preview: Bool = false) -> Bool {
    WelcomeFlow.shouldShow(seen: seen, hadLaunchedBefore: before, restoredWindow: restored,
                           mayRecordWindowState: record, forced: forced, preview: preview)
}
expect(show(), "a first launch of a fresh Mac opens it")
expect(!show(seen: true), "a Mac that has shown it does not show it again")
expect(!show(before: true), "an update of an app that ran before does not welcome the user")
expect(!show(restored: true), "a launch that restored a window does not add another")
expect(!show(record: false), "a capture launch, which may not write window state, does not open it")
expect(show(seen: true, forced: true), "the force flag opens it on a Mac that has seen it")
expect(show(seen: true, before: true, restored: true, record: false, preview: true),
       "a held preview opens it whatever else is true")
expect(WelcomeFlow.shouldRecordSeen(forced: false, preview: false, mayRecordWindowState: true),
       "a real first run is remembered")
expect(!WelcomeFlow.shouldRecordSeen(forced: true, preview: false, mayRecordWindowState: true)
        && !WelcomeFlow.shouldRecordSeen(forced: false, preview: true, mayRecordWindowState: true)
        && !WelcomeFlow.shouldRecordSeen(forced: false, preview: false, mayRecordWindowState: false),
       "a forced open, a preview and a capture launch are never remembered as the first run")

// MARK: the dev preview

let names = ["detecting", "found", "needs-claude", "waiting", "signin", "signing-in", "success", "failed"]
expect(names.allSatisfy { WelcomeFlow.previewScreen(named: $0) != nil }, "all eight screens can be held")
expect(WelcomeFlow.previewScreen(named: "NEEDS-CODEX") == .needsCLI(providerID: "codex"),
       "the Codex install screen can be held, and names are not case sensitive")
expect(WelcomeFlow.previewScreen(named: nil) == nil && WelcomeFlow.previewScreen(named: "YES") == nil
        && WelcomeFlow.previewScreen(named: "") == nil,
       "no value, or one that names no screen, means a real detection from the start")
var walked: [WelcomeScreen] = [.needsCLI(providerID: "claude")]
while let next = WelcomeFlow.previewNext(after: walked.last!), walked.count < 12 { walked.append(next) }
expect(walked == [.needsCLI(providerID: "claude"), .waiting(providerID: "claude"),
                  .signIn(providerID: "claude"), .signingIn(providerID: "claude"), .success],
       "a held install screen walks install, wait, sign in, signing in, success and stops")
expect(WelcomeFlow.previewNext(after: .failed(providerID: "claude", reason: .timedOut))
        == .signingIn(providerID: "claude"),
       "Try Again on a held failure runs the sign-in again")

// MARK: orderings a type check cannot see

func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
let delegate = source("Tally/App/AppDelegate.swift")
if let read = delegate.range(of: "UserDefaults.standard.bool(forKey: LaunchAtLoginDefault.appliedKey)"),
   let apply = delegate.range(of: "LaunchAtLoginDefault.applyIfNeeded()") {
    expect(read.lowerBound < apply.lowerBound,
           "the launch reads whether this app ran before BEFORE the login-item default records this launch")
} else { expect(false, "the launch reads whether this app ran before BEFORE the login-item default records this launch") }

let store = source("Tally/Stores/AddAccountStore.swift")
if let resolve = store.range(of: "guard let executable = ProviderCLI.resolved("),
   let prepare = store.range(of: "prepareAddedAccountHome(providerID: providerID, share: share)") {
    expect(resolve.lowerBound < prepare.lowerBound,
           "an add looks for the CLI before it creates a config home")
} else { expect(false, "an add looks for the CLI before it creates a config home") }

let controller = source("Tally/MenuBar/WelcomeWindowController.swift")
expect(controller.contains("BuildVariant.isDev || DemoUsage.isActive")
        && controller.components(separatedBy: "flagsHonoured").count >= 4,
       "both welcome flags are read only through the Dev-or-demo gate")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
