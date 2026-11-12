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
        && WelcomeCopy.stalledBody.contains("Open Terminal Again") && !WelcomeCopy.stalledBody.contains("paste"),
       "the stalled screen names the Terminal window, the network and opening Terminal again, never pasting")

// MARK: success copy (G3)

expect(["tally claude", "tally codex", "Settings > Integrations", "menu bar"].allSatisfy { WelcomeCopy.successBody.contains($0) },
       "the success page names the menu bar and how to start sessions with the command line tool")

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
             "signin-offpath", "needs-claude-notfound", "waiting-opening", "waiting-copied",
             "installing", "installing-details", "install-failed", "signing-in-installed"]
expect(names.allSatisfy { WelcomeFlow.previewScreen(named: $0) != nil }, "all seventeen held screens can be held")
expect(WelcomeFlow.previewScreen(named: "NEEDS-CODEX") == .needsCLI(providerID: "codex"),
       "the Codex install screen can be held, and names are not case sensitive")
expect(WelcomeFlow.previewScreen(named: nil) == nil && WelcomeFlow.previewScreen(named: "YES") == nil
        && WelcomeFlow.previewScreen(named: "") == nil,
       "no value, or one that names no screen, means a real detection from the start")
var walked: [WelcomeScreen] = [.needsCLI(providerID: "claude")]
while let next = WelcomeFlow.previewNext(after: walked.last!), walked.count < 12 { walked.append(next) }
expect(walked == [.needsCLI(providerID: "claude"), .installing(providerID: "claude"),
                  .signingIn(providerID: "claude"), .success],
       "a held Claude install screen walks install, signing in, success and stops")
var walkedCodex: [WelcomeScreen] = [.needsCLI(providerID: "codex")]
while let next = WelcomeFlow.previewNext(after: walkedCodex.last!), walkedCodex.count < 12 { walkedCodex.append(next) }
expect(walkedCodex == [.needsCLI(providerID: "codex"), .waiting(providerID: "codex"),
                       .signIn(providerID: "codex"), .signingIn(providerID: "codex"), .success],
       "a held Codex install screen walks install, wait, sign in, signing in, success and stops")
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
/// Both texts are present and `first` comes before `second`.
func precedes(_ first: String, _ second: String, in text: String) -> Bool {
    guard let a = text.range(of: first), let b = text.range(of: second) else { return false }
    return a.lowerBound < b.lowerBound
}
/// The body of the four-space-indented member that starts with `header`, up to its closing brace.
func memberBody(_ header: String, in text: String) -> String {
    text.components(separatedBy: header).dropFirst().first?.components(separatedBy: "\n    }").first ?? ""
}
let delegate = source("Tally/App/AppDelegate.swift")
expect(precedes("LaunchAtLoginDefault.hasLaunchedBefore()", "LaunchAtLoginDefault.recordLaunch()", in: delegate),
       "the launch reads whether this app ran before BEFORE it records this launch")
expect(!delegate.contains("applyIfNeeded") && !delegate.contains("setRegistered")
        && !delegate.contains("registerFromWelcome") && !delegate.contains("SMAppService"),
       "launch registers no login item (B-3747: the welcome window's box is the only way in)")

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

expect(WelcomeFlow.previewScreen(named: "signing-in-waiting") == .signingIn(providerID: "claude")
        && WelcomeFlow.previewBrowserWaiting(named: "signing-in-waiting")
        && WelcomeFlow.previewBrowserWaiting(named: "SIGNING-IN-WAITING")
        && !WelcomeFlow.previewBrowserWaiting(named: "signing-in")
        && !WelcomeFlow.previewBrowserWaiting(named: nil),
       "signing-in-waiting holds the sign-in page in its waiting state; signing-in stays ticked")
let welcomeStoreSource = source("Tally/Stores/WelcomeStore.swift")
expect(welcomeStoreSource.contains("preview != nil ? !previewBrowserWaiting : flow.browserOpened")
        && welcomeStoreSource.contains("previewBrowserWaiting = WelcomeFlow.previewBrowserWaiting(named: previewName)"),
       "the store reads the preview's waiting flag, set from the preview name on every begin")

// The sign-in page ticks "Browser opened" only on the CLI's own signal, never unconditionally (B-4392).
expect(welcomeView.contains("store.browserOpened ? .done : .active")
        && !welcomeView.contains("(.done, L(\"Browser opened\"))"),
       "the first sign-in step is drawn done only once the browser-up signal arrived")
expect(store.contains("onBrowserUp:") && store.contains("browserOpened = plan.progressMarkers.isEmpty"),
       "an add resets the signal per run, and wires the runner's browser-up callback to it")

// The sign-in page shows the green card and nothing yellow under it, and the two Cancel buttons
// answer Escape (B-3747).
let signInBlock = welcomeView.components(separatedBy: "let advice = store.pathAdvice(p)").dropFirst().first?
    .components(separatedBy: "case .signingIn:").first ?? ""
expect(!signInBlock.isEmpty && signInBlock.contains("checkmark.circle.fill") && !signInBlock.contains("pathCard("),
       "the sign-in page's body carries no path card under the green check")
expect(!welcomeView.contains("pathCard(") && !signInBlock.contains("is installed"),
       "no path card is left in the view, and the sign-in title is always 'is ready'")
let signingInFooter = welcomeView.components(separatedBy: "Browser didn't open? Open it again").dropFirst().first?
    .components(separatedBy: "case .success:").first ?? ""
let failedFooter = welcomeView.components(separatedBy: "case .failed:\n                Spacer()").dropFirst().first?
    .components(separatedBy: "prominent(L(\"Try Again\"))").first ?? ""
expect(signingInFooter.contains("plain(L(\"Cancel\"))") && signingInFooter.contains(".keyboardShortcut(.cancelAction)"),
       "the signing-in page's Cancel answers Escape")
expect(failedFooter.contains("plain(L(\"Cancel\"))") && failedFooter.contains(".keyboardShortcut(.cancelAction)"),
       "the failed page's Cancel answers Escape")

// Albert chose to keep (B-3747): closing the window does not cancel an in-flight sign-in, because
// people close it to approve in the browser. windowClosed() stops only the CLI watch.
let windowClosedBody = welcomeStore.components(separatedBy: "func windowClosed() {").dropFirst().first?
    .components(separatedBy: "\n    }").first ?? ""
expect(windowClosedBody.contains("flow.stopWatchingForCLI()") && !windowClosedBody.contains("cancelSignIn"),
       "closing the welcome window leaves an in-flight sign-in running (no cancelSignIn in windowClosed)")
expect(windowClosedBody.contains("flow.signInAfterInstall = false") && !windowClosedBody.contains("cancelInstall"),
       "closing the welcome window lets an install finish but drops the sign-in after it")

// MARK: "Open Tally when you log in" (B-3747, option A)

/// The text of one `case` branch of a switch, up to the next `case` at the same indent or a `}`.
func branch(_ header: String, in text: String, after marker: String) -> String {
    let tail = text.components(separatedBy: marker).dropFirst().first ?? ""
    return tail.components(separatedBy: header).dropFirst().first?
        .components(separatedBy: "\n        case ").first ?? ""
}
let primaryFound = branch("case .found, .success:", in: welcomeStore, after: "func primary() {")
let secondaryFound = branch("case .found, .success:", in: welcomeStore, after: "func secondary() {")
expect(precedes("commitLoginChoice()", "showUsage()", in: primaryFound),
       "Show My Usage registers (when ticked) before it closes the window")
expect(precedes("commitLoginChoice()", "addAnotherAccount()", in: secondaryFound),
       "Add Another Account registers (when ticked) before it opens Settings")
expect(!windowClosedBody.contains("commitLoginChoice") && !windowClosedBody.contains("LaunchAtLoginDefault"),
       "closing the welcome window registers nothing")
let showUsageBody = memberBody("func showUsage() {", in: welcomeStore)
expect(!showUsageBody.isEmpty && !showUsageBody.contains("LaunchAtLoginDefault")
        && !showUsageBody.contains("commitLoginChoice"),
       "showUsage() itself registers nothing: only the two finishing buttons do")
let commitBody = memberBody("private func commitLoginChoice() {", in: welcomeStore)
expect(commitBody.contains("guard preview == nil")
        && commitBody.contains("LaunchAtLoginDefault.registerFromWelcome(wanted: openAtLogin)"),
       "a held preview registers nothing; otherwise the box decides")
expect(welcomeStore.components(separatedBy: "commitLoginChoice()").count - 1 == 3,
       "commitLoginChoice is called from exactly the two finishing buttons (plus its definition)")
expect(welcomeStore.contains("var openAtLogin = true")
        && memberBody("func begin(", in: welcomeStore).contains("openAtLogin = true"),
       "the box starts ticked, and every visit to the window starts it ticked again")
let found2 = welcomeView.components(separatedBy: "case .found:\n            rowsCard").dropFirst().first?
    .components(separatedBy: "case .needsCLI").first ?? ""
let success2 = welcomeView.components(separatedBy: "case .success:\n            rowsCard").dropFirst().first?
    .components(separatedBy: "case .failed:").first ?? ""
expect(found2.contains("loginRow") && success2.contains("loginRow"),
       "the box is on the found page and on the success page")
expect(welcomeView.components(separatedBy: "loginRow").count - 1 == 3,
       "and on no other page (two uses plus the definition)")
expect(welcomeView.contains("Toggle(isOn: $store.openAtLogin)") && welcomeView.contains(".toggleStyle(.checkbox)")
        && welcomeView.contains("L(\"Open Tally when you log in\")")
        && welcomeView.contains("L(\"macOS will let you know once. You can turn this off in Settings.\")"),
       "the row is a checkbox bound to the store, with the designed words")

// MARK: install in Terminal (B-3747)

/// Runs a script file with /bin/bash and returns its stdout.
func runScript(_ file: URL) -> (out: String, rc: Int32) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [file.path]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    try? task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), task.terminationStatus)
}

let scriptDir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-welcome-test-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
let words = TerminalInstallScript.Words(intro: "Installing:", done: "DONE-LINE", failed: "FAILED-LINE", pathNote: "PATH-NOTE")
func scriptFile(_ command: String, _ w: TerminalInstallScript.Words = words, name: String = "s.sh") -> URL {
    let url = scriptDir.appendingPathComponent(name)
    let text = TerminalInstallScript.text(command: command, receipt: scriptDir.appendingPathComponent("r").path, words: w)
    try? text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

let okRun = runScript(scriptFile("true", name: "ok.sh"))
expect(okRun.out.contains("DONE-LINE") && okRun.out.contains("PATH-NOTE") && !okRun.out.contains("FAILED-LINE"),
       "a script whose command succeeds prints the done line and the PATH note")
let failRun = runScript(scriptFile("false | true", name: "fail.sh"))
expect(failRun.out.contains("FAILED-LINE") && !failRun.out.contains("DONE-LINE"),
       "a failed download is a failed install, not an empty success (pipefail)")
let receiptRun = runScript(scriptFile("test -e '\(scriptDir.path)/r'", name: "receipt.sh"))
expect(receiptRun.out.contains("DONE-LINE"), "the script touches its receipt before the install command runs")
expect(!FileManager.default.fileExists(atPath: scriptDir.appendingPathComponent("ok.sh").path),
       "the script deletes itself")
var odd = words
odd.intro = "Terminal'i açar"
let oddFile = scriptFile("true", odd, name: "odd.sh")
let syntax = Process()
syntax.executableURL = URL(fileURLWithPath: "/bin/bash")
syntax.arguments = ["-n", oddFile.path]
try? syntax.run()
syntax.waitUntilExit()
expect(syntax.terminationStatus == 0 && runScript(oddFile).out.contains("Terminal'i açar"),
       "a translation with an apostrophe keeps the script valid")
expect(TerminalInstallScript.text(command: WelcomeFlow.installCommand(providerID: "claude"), receipt: "/r", words: words)
        .contains("\nif curl -fsSL https://claude.ai/install.sh | bash; then\n"),
       "the vendor command appears verbatim as the line that runs")
expect(WelcomeCopy.terminalScriptWords("codex").pathNote == nil && WelcomeCopy.terminalScriptWords("claude").pathNote != nil,
       "a Codex script carries no PATH note")
if let written = try? TerminalInstallScript.write(command: "true", words: words, in: scriptDir) {
    let mode = (try? FileManager.default.attributesOfItem(atPath: written.script.path))?[.posixPermissions] as? Int
    expect(mode == 0o755 && getxattr(written.script.path, "com.apple.quarantine", nil, 0, 0, 0) == -1,
           "the written script is executable and carries no quarantine mark")
    expect(!TerminalInstallScript.hasStarted(written.receipt), "a receipt does not exist before the script runs")
} else {
    expect(false, "the written script is executable and carries no quarantine mark")
}
try? FileManager.default.removeItem(at: scriptDir)

expect(WelcomeCopy.terminalFirstStep(.opening) == "Opening Terminal…"
        && WelcomeCopy.terminalFirstStep(.running) == "Terminal opened and started the install"
        && WelcomeCopy.terminalFirstStep(.copied) == "Install command copied"
        && WelcomeCopy.terminalSecondStep(.copied) == "Paste it in Terminal and press Return"
        && WelcomeCopy.terminalSecondStep(.opening) == "Installing in Terminal"
        && WelcomeCopy.terminalSecondStep(.running) == "Installing in Terminal",
       "the waiting page's first step ticks only once the script is running")
expect(WelcomeFlow.previewTerminalStart(named: "WAITING-OPENING") == .opening
        && WelcomeFlow.previewTerminalStart(named: "waiting-copied") == .copied
        && WelcomeFlow.previewTerminalStart(named: "waiting") == .running
        && WelcomeFlow.previewTerminalStart(named: nil) == .running,
       "the Terminal fixtures map from their preview names")

let installBody = store.components(separatedBy: "func installInTerminal()").dropFirst().first?
    .components(separatedBy: "\n    func ").first ?? ""
expect(store.contains("withApplicationAt: terminal") && !installBody.isEmpty
        && !installBody.contains("osascript") && !installBody.contains("do script"),
       "Install in Terminal opens the script with Terminal, not by driving it")
expect(welcomeView.contains("start == .opening ? .active : .done") && !welcomeView.contains("(.done, L(\"Install command copied\"))"),
       "the waiting step is ticked from the store's Terminal state, never unconditionally")
expect(!welcomeStore.contains("copyInstallCommandAndWait") && !source("Tally/Views/SettingsAddAccountView.swift").contains("copyInstallCommandAndWait"),
       "no surface still calls the copy-and-open install")

// MARK: install in the app (B-3747 C)

let installSource = source("Tally/Core/ClaudeInstall.swift")
let failureBody = installSource.components(separatedBy: "static func failure(").dropFirst().first?
    .components(separatedBy: "\n    }").first ?? ""
expect(failureBody.contains("exitCode == 0 && cliFound"),
       "success is the exit code and a findable CLI, never the script's words")
let runnerSource = source("Tally/Core/ClaudeInstallRunner.swift")
expect(runnerSource.contains("\"-o\", \"pipefail\", \"-c\"") && runnerSource.contains("POSIX_SPAWN_SETPGROUP")
        && runnerSource.contains("kill(-pid"),
       "the install runs the vendor line under pipefail in its own process group")
if let guardAt = store.range(of: "guard signInAfterInstall else { return }"),
   let beginAt = store.range(of: "beginEntry(providerID: providerID)", range: guardAt.upperBound ..< store.endIndex) {
    expect(guardAt.lowerBound < beginAt.lowerBound, "an install hands to the login only while its window is open")
} else {
    expect(false, "an install hands to the login only while its window is open")
}
expect(ClaudeInstall.supports("claude") && !ClaudeInstall.supports("codex"),
       "the in-app install is Claude only; Codex keeps Install in Terminal")
expect(WelcomeFlow.installCommand(providerID: "claude") == "curl -fsSL https://claude.ai/install.sh | bash"
        && WelcomeCopy.officialScript.contains("the same line their docs give")
        && WelcomeCopy.officialScript.contains("never asks for your password")
        && !WelcomeCopy.officialScript.contains("home folder"),
       "the ready page claims only what was checked: the vendor's own line, no password, no unverified scope")
expect(welcomeView.contains("store.openInstallGuide()") && welcomeStoreSource.contains("https://code.claude.com/docs/en/setup")
        && !welcomeStoreSource.contains("claude.ai/install.sh"),
       "the guide link opens the docs page, never the script URL a browser would download")
expect(WelcomeCopy.installFailureBody(.stalled).contains("90 seconds")
        && WelcomeCopy.installFailureBody(.tooLong).contains("10 minutes")
        && WelcomeCopy.installFailureBody(.unreachable).hasSuffix("Trying again is safe.")
        && !WelcomeCopy.installFailureBody(.other).contains("Nothing was installed"),
       "failure pages say why in plain words and only that trying again is safe")
expect(WelcomeCopy.installProgress(.downloading(bytes: 52_000_000)).contains("52 MB")
        && WelcomeCopy.installProgress(.downloading(bytes: nil)).hasPrefix("Downloading.")
        && WelcomeCopy.installTitle("claude") == "Set up Claude Code",
       "the progress line shows the download size when it is readable")
let settingsInstall = source("Tally/Views/SettingsAddAccountView.swift")
expect(welcomeStoreSource.contains("flow.installAndSignIn()") && settingsInstall.contains("flow.installAndSignIn()")
        && welcomeStoreSource.contains("case .installing: flow.cancelInstall()"),
       "both surfaces start the in-app install, and Cancel on the installing page ends it")

// The store needs AppKit, so it is not compiled here: lock the order as source text.
// First run shows .needsCLI from the base screen while the flow is idle; flow.installInTerminal()
// guards on .needsCLI, so "Install in Terminal instead" did nothing until showNeedsCLI ran first (B-3747).
if let fn = welcomeStoreSource.range(of: "func installInTerminal() {"),
   let show = welcomeStoreSource.range(of: "flow.showNeedsCLI(providerID: p)", range: fn.upperBound..<welcomeStoreSource.endIndex),
   let open = welcomeStoreSource.range(of: "flow.installInTerminal()", range: fn.upperBound..<welcomeStoreSource.endIndex) {
    let body = welcomeStoreSource[fn.upperBound..<open.lowerBound]
    // Entry 1: flow idle, page .needsCLI: showNeedsCLI runs first, taking the page's providerID.
    expect(show.lowerBound < open.lowerBound && body.contains("if case .needsCLI(let p) = screen"),
           "Install in Terminal moves an idle flow to .needsCLI BEFORE it opens Terminal")
    // Entries 2 and 3 (Open Terminal Again, after a failed install): flow already at .needsCLI, so no showNeedsCLI.
    expect(body.contains("if case .needsCLI = flow.phase {} else { flow.showNeedsCLI(providerID: p) }"),
           "Install in Terminal never re-runs showNeedsCLI on a flow already at .needsCLI (it would end the wait)")
    // Those two pages come from a flow at .needsCLI: waiting -> .waiting, failed report -> .installFailed.
    expect(welcomeStoreSource.contains("flow.installReport != nil ? .installFailed(providerID: p) : .needsCLI(providerID: p)")
            && welcomeStoreSource.contains("flow.cliWaitStalled ? .waitingStalled(providerID: p) : .waiting(providerID: p)"),
           "the waiting and failed pages are derived from phase .needsCLI, so the guard above covers them")
} else { expect(false, "Install in Terminal moves an idle flow to .needsCLI BEFORE it opens Terminal") }

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
