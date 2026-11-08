import Foundation

// The welcome window's rules: which screen detection picks, when the window may open by itself,
// what the preview flag walks. Pure checks against WelcomeFlow.swift, plus three source locks for
// the orderings a type check cannot see.

/// WelcomeCopy.swift asks the app's localizer; here the key is its own English text.
func L(_ key: String) -> String { key }

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

// "I use X instead" on the sign-in screen (G7): the other provider's sign-in when its CLI is there,
// else its install. Both providers, the other one installed and not.
for p in ["claude", "codex"] {
    let other = WelcomeFlow.otherProvider(p)
    expect(WelcomeFlow.screen(forChoice: other, installed: { $0 == other }) == .signIn(providerID: other),
           "\(p) sign-in, switching to \(other) with its CLI installed, lands on its sign-in")
    expect(WelcomeFlow.screen(forChoice: other, installed: { $0 == p }) == .needsCLI(providerID: other),
           "\(p) sign-in, switching to \(other) without its CLI, lands on its install")
}

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

// MARK: a stalled install wait (G2)

let stall = WelcomeFlow.installStallSeconds
expect(stall == 180, "the install wait stalls at three minutes")
expect(!WelcomeFlow.isInstallStalled(waited: 179, installed: false), "179 seconds without the CLI is still waiting")
expect(WelcomeFlow.isInstallStalled(waited: 180, installed: false), "180 seconds without the CLI has stalled")
expect(WelcomeFlow.isInstallStalled(waited: 181, installed: false), "181 seconds without the CLI has stalled")
expect(!WelcomeFlow.isInstallStalled(waited: 181, installed: true), "an installed CLI beats the clock")
expect(!WelcomeFlow.isInstallStalled(waited: 0, installed: true), "an installed CLI is never stalled")
expect(WelcomeFlow.previewScreen(named: "waiting-stalled") == .waitingStalled(providerID: "claude"),
       "the stalled wait can be held as a preview")
expect(WelcomeFlow.previewNext(after: .waitingStalled(providerID: "claude")) == .signIn(providerID: "claude"),
       "a held stalled wait walks on to sign-in like the plain wait")
expect(WelcomeCopy.stalledBody.contains("Terminal") && WelcomeCopy.stalledBody.contains("online")
        && WelcomeCopy.stalledBody.contains("paste the command again"),
       "the stalled screen names the Terminal window, the network and pasting again")

// MARK: failure copy (G8)

let oddReason = "Tally could not prepare a zzz-reason for the new account."
let shown = WelcomeCopy.failureBody(.other(oddReason))
expect(!shown.contains("zzz-reason") && !shown.lowercased().contains("config home"),
       "an unclassified failure never shows the flow's own sentence")
expect(shown.contains("Nothing was changed, so trying again is safe."),
       "an unclassified failure says trying again is safe, like the other three")
expect([WelcomeFailure.timedOut, .reported, .couldNotStart, .other("x")]
        .allSatisfy { WelcomeCopy.failureBody($0).contains("Nothing was changed, so trying again is safe.") },
       "all four failure pages end on the same safe-to-retry sentence")

// MARK: the dev preview

let names = ["detecting", "found", "needs-claude", "waiting", "waiting-stalled", "signin", "signing-in", "success", "failed",
             "signin-offpath", "needs-claude-notfound"]
expect(names.allSatisfy { WelcomeFlow.previewScreen(named: $0) != nil }, "all eleven held screens can be held")
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

// MARK: Terminal PATH advice (B-3745)

let home = "/h"
func finds(_ path: [String]?, exe: String = "/h/.local/bin/claude",
           runnable: @escaping (String) -> Bool = { _ in false }) -> Bool? {
    CLIPathAdvice.terminalFinds(cli: "claude", executable: exe, loginPATH: path, isRunnable: runnable)
}
expect(finds(["/usr/bin", "/bin"]) == false, "a login PATH without the CLI's directory: Terminal cannot find it")
expect(finds(["/usr/bin", "/h/.local/bin"]) == true, "a login PATH with the CLI's directory: Terminal finds it")
expect(finds(["/h/.local/bin/"]) == true, "a trailing slash on the PATH entry does not hide the directory")
expect(finds(["/usr/bin", "/opt/x"], runnable: { $0 == "/opt/x/claude" }) == true,
       "another install of the same name on the login PATH counts")
expect(finds(nil) == nil, "an unread login PATH is unknown, not a no")

expect(CLIPathAdvice.installedDetail(location: "~/.local/bin", terminalFinds: false) == .none,
       "no 'Found in' line when Terminal is known not to find the CLI")
expect(CLIPathAdvice.installedDetail(location: "~/.local/bin", terminalFinds: true) == .foundIn("~/.local/bin")
        && CLIPathAdvice.installedDetail(location: "~/.local/bin", terminalFinds: nil) == .foundIn("~/.local/bin"),
       "'Found in' stays when Terminal finds it or Tally cannot tell")
expect(CLIPathAdvice.installedDetail(location: nil, terminalFinds: true) == .none, "no location, no line")

func fix(_ dir: String, _ shell: String) -> String? { CLIPathAdvice.fixCommand(directory: dir, home: home, shell: shell) }
expect(fix("/h/.local/bin", "zsh") == #"echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc"#, "zsh fix line")
expect(fix("/h/.local/bin", "bash") == #"echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bash_profile"#, "bash fix line")
expect(fix("/h/.local/bin", "dash") == #"echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.profile"#, "sh family fix line")
expect(fix("/h/.local/bin", "fish") == #"fish_add_path "$HOME/.local/bin""#, "fish fix line")
expect(fix("/opt/x/bin", "zsh") == #"echo 'export PATH="/opt/x/bin:$PATH"' >> ~/.zshrc"#,
       "a directory outside home keeps its absolute path")
expect(fix("/h/My Tools", "zsh") == nil && fix("/opt/it's", "zsh") == nil && fix("/opt/$x", "zsh") == nil,
       "a directory that would need quoting gets no line")
expect(fix("/h/.local/bin", "tcsh") == nil, "an unknown shell gets no line")

func word(_ exe: String?, _ finds: Bool?) -> String {
    CLIPathAdvice.commandWord(cli: "claude", executable: exe, terminalFinds: finds, home: home)
}
expect(word("/h/.local/bin/claude", true) == "claude", "the bare name when Terminal finds it")
expect(word("/h/.local/bin/claude", false) == "~/.local/bin/claude", "the full path when it does not")
expect(word("/h/.local/bin/claude", nil) == "~/.local/bin/claude", "the full path when unknown: it works either way")
expect(word(nil, false) == "claude", "nothing found keeps the bare name")
expect(word("/h/My Tools/claude", false) == "'/h/My Tools/claude'", "an unplain path is single-quoted absolute")

func command(_ provider: String, _ homes: [String], word: String, tally: Bool = false) -> String {
    CLIPathAdvice.addAccountCommand(providerID: provider, homes: homes, tallyInstalled: tally, cliWord: word)
}
expect(command("claude", [], word: "claude", tally: true) == "tally add claude", "the tally CLI wins when installed")
expect(command("claude", [], word: "claude") == "claude", "first Claude account, bare name (as before)")
expect(command("claude", [], word: "~/.local/bin/claude") == "~/.local/bin/claude",
       "first Claude account, full path when Terminal cannot find the bare name")
expect(command("claude", ["/h/.claude"], word: "claude") == "CLAUDE_CONFIG_DIR=~/.claude2 claude",
       "second Claude account, bare name (as before)")
expect(command("claude", ["/h/.claude"], word: "~/.local/bin/claude")
        == "CLAUDE_CONFIG_DIR=~/.claude2 ~/.local/bin/claude", "second Claude account, full path")
expect(command("claude", ["/h/.claude", "/h/.claude2"], word: "claude") == "CLAUDE_CONFIG_DIR=~/.claude3 claude",
       "the first unused numbered sibling")
expect(command("codex", [], word: "codex") == "codex login", "first Codex account (as before)")
expect(command("codex", [], word: "~/.local/bin/codex") == "~/.local/bin/codex login", "first Codex account, full path")
expect(command("codex", ["/h/.codex"], word: "codex")
        == "mkdir -p ~/.codex2 && CODEX_HOME=~/.codex2 codex login", "second Codex account (as before)")
expect(command("codex", ["/h/.codex"], word: "~/.local/bin/codex")
        == "mkdir -p ~/.codex2 && CODEX_HOME=~/.codex2 ~/.local/bin/codex login", "second Codex account, full path")

expect(WelcomeFlow.previewPathState(named: "signin-offpath") == (true, false)
        && WelcomeFlow.previewPathState(named: "NEEDS-CLAUDE-NOTFOUND") == (false, true)
        && WelcomeFlow.previewPathState(named: "signin") == (false, false)
        && WelcomeFlow.previewPathState(named: nil) == (false, false),
       "only the two path fixtures show path guidance")

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

let welcomeView = source("Tally/Views/WelcomeView.swift")
if let detail = welcomeView.range(of: ".foundIn(let"),
   let line = welcomeView.range(of: "L(\"Found in %@\")") {
    expect(welcomeView.components(separatedBy: "L(\"Found in %@\")").count == 2
            && detail.lowerBound < line.lowerBound
            && welcomeView.distance(from: detail.lowerBound, to: line.lowerBound) < 200,
           "'Found in' is drawn only from the .foundIn case")
} else { expect(false, "'Found in' is drawn only from the .foundIn case") }

let welcomeStore = source("Tally/Stores/WelcomeStore.swift")
if let again = welcomeStore.range(of: "func checkAgain("),
   let end = welcomeStore.range(of: "private static func signedInAccounts", range: again.upperBound..<welcomeStore.endIndex),
   let read = welcomeStore.range(of: "readLoginPATH()", range: again.upperBound..<end.lowerBound),
   let verdict = welcomeStore.range(of: "WelcomeFlow.verdict(", range: again.upperBound..<end.lowerBound) {
    expect(read.lowerBound < verdict.lowerBound, "Check again reads the login PATH BEFORE it decides")
} else { expect(false, "Check again reads the login PATH BEFORE it decides") }
if let again = welcomeStore.range(of: "func checkAgain("),
   let end = welcomeStore.range(of: "private static func signedInAccounts", range: again.upperBound..<welcomeStore.endIndex),
   let installed = welcomeStore.range(of: "if cliInstalled(providerID), case .needsCLI = flow.phase { flow.reset() }",
                                      range: again.upperBound..<end.lowerBound),
   let verdict = welcomeStore.range(of: "WelcomeFlow.verdict(", range: again.upperBound..<end.lowerBound) {
    expect(installed.lowerBound < verdict.lowerBound,
           "Check again lets go of a held install screen (reset) once the CLI is found, before it decides")
} else { expect(false, "Check again lets go of a held install screen (reset) once the CLI is found, before it decides") }
if let detect = welcomeStore.range(of: "private func detect("),
   let read = welcomeStore.range(of: "Self.readLoginPATH()", range: detect.upperBound..<welcomeStore.endIndex),
   let verdict = welcomeStore.range(of: "WelcomeFlow.verdict(", range: detect.upperBound..<welcomeStore.endIndex) {
    expect(read.lowerBound < verdict.lowerBound, "detection reads the login PATH BEFORE it decides")
} else { expect(false, "detection reads the login PATH BEFORE it decides") }
expect(welcomeStore.contains("loginPATH(waitIfCold: true)"), "the login PATH read waits for the shell (off the main thread)")

let settingsPane = source("Tally/Views/SettingsAccountsView.swift")
expect(settingsPane.contains("CLIPathAdvice.addAccountCommand(") && !settingsPane.contains("CLAUDE_CONFIG_DIR=~/"),
       "Settings builds its fallback command in one place")

// B-3745 capture fixtures: each is read only inside a Debug block that also asks for demo data, and
// Settings reaches the off-PATH answer through its one command builder and its one note closure.
func readOnlyInDebugDemo(_ text: String, _ flag: String) -> Bool {
    guard let at = text.range(of: "\"\(flag)\""),
          let debug = text.range(of: "#if DEBUG", options: .backwards,
                                 range: text.startIndex ..< at.lowerBound) else { return false }
    let between = debug.upperBound ..< at.lowerBound
    return text.range(of: "#endif", range: between) == nil
        && text.range(of: "DemoUsage.isActive", range: between) != nil
}
expect(readOnlyInDebugDemo(source("Tally/Core/CLIPathAdvice+System.swift"), "TallyDemoCLIOffPath")
        && readOnlyInDebugDemo(source("Tally/Stores/AddAccountStore.swift"), "TallyDemoAddAccountSheet"),
       "both capture fixtures are read only in a Debug build with demo data")
expect(settingsPane.components(separatedBy: "CLIPathAdvice.demoOffPath(").count == 3
        && settingsPane.contains("tallyInstalled: demo == nil &&"),
       "the off-PATH fixture reaches both the command and its note, with the tally CLI counted absent")
expect(settingsPane.contains("addingAccount = AddAccountStore.demoOpensSheet"),
       "the add-account sheet opens by itself only through the capture flag")

let controller = source("Tally/MenuBar/WelcomeWindowController.swift")
expect(controller.contains("BuildVariant.isDev || DemoUsage.isActive")
        && controller.components(separatedBy: "flagsHonoured").count >= 4,
       "both welcome flags are read only through the Dev-or-demo gate")

expect(!welcomeStore.contains("case .detecting, .signIn: break")
        && welcomeStore.contains("case .needsCLI(let p), .signIn(let p):\n            flow.reset()"),
       "the sign-in screen's secondary button switches provider like the install screen's")
expect(!welcomeView.contains("Text(verbatim: \"T\")")
        && welcomeView.contains("StatusItemController.fallbackSymbolName"),
       "the welcome menu bar hint draws the status item's own glyph, not a letter")
expect(welcomeView.contains("case .signIn(let p):\n                link("),
       "the sign-in screen carries the 'I use X instead' link")
let emptyState = source("Tally/Views/EmptyStateView.swift")
expect(emptyState.contains("Add a Claude or Codex account to get started.")
        && !emptyState.contains("supported CLI"),
       "the empty state asks for a Claude or Codex account in plain words")
let userFacing = ["Tally/Views", "Tally/Stores/AddAccountStore.swift", "Tally/Stores/WelcomeStore.swift",
                  "Tally/Core/WelcomeCopy.swift"]
var configHomeLiterals: [String] = []
for root in userFacing {
    var paths = [root]
    if let found = FileManager.default.enumerator(atPath: root)?.allObjects as? [String] {
        paths = found.filter { $0.hasSuffix(".swift") }.map { root + "/" + $0 }
    }
    for path in paths {
        for line in source(path).split(separator: "\n") where line.contains("L(\"") && line.contains("config home") {
            configHomeLiterals.append(path)
        }
    }
}
expect(configHomeLiterals.isEmpty, "no user-facing string says 'config home' (it is 'account folder')")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
