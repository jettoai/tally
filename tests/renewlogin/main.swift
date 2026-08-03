import Foundation

// Assertion harness for the "Renew login" background flow: the pure command knowledge
// (Tally/Core/RenewLoginCommand.swift) and the runner that drives it
// (Tally/Core/RenewLoginRunner.swift). Both are Foundation-only on purpose, so nothing else
// comes along.
//
// The runner is exercised against STUB CLIs written by this file, never a real provider login:
// a real one would spend the machine's own credentials, and the point here is the driving, not
// the vendor's OAuth. Each stub answers one question and answers it by its exit code or by a
// file it leaves behind, so a pass cannot come from the harness agreeing with itself.
//
// Two of the pure checks are round trips through the interpreters the strings are built for:
// /bin/sh reports what the environment variable actually became, and osascript reports what the
// AppleScript literal actually decoded to. A quoting rule can only be verified by the thing that
// does the unquoting.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

/// Run a program and return its trimmed stdout (nil when it could not be started).
func capture(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
}

// MARK: the plans

let claudePlan = RenewLoginCommand.plan(providerID: "claude")
let codexPlan = RenewLoginCommand.plan(providerID: "codex")
expect(claudePlan?.arguments == ["--strict-mcp-config", "auth", "login"],
       "claude re-logs in through its own auth subcommand, with the host's MCP config kept out")
// The ordering above is the whole bug the previous release shipped: a main-command option written
// after the subcommand is rejected by Commander ("unknown option"), so the renewal could only ever
// fail. Held as a rule rather than as one literal, because it is the rule that generalises to the
// next flag someone adds.
for plan in [claudePlan, codexPlan].compactMap({ $0 }) {
    expect(plan.arguments.drop(while: { $0.hasPrefix("-") }).allSatisfy { !$0.hasPrefix("-") },
           "every option precedes the subcommand, where the main command parses it: "
               + plan.arguments.joined(separator: " "))
}
expect(claudePlan?.needsTerminal == true,
       "claude draws a terminal UI, so it is given a pty")
expect(claudePlan?.confirmKeystroke == "\r",
       "claude's success screen waits on a key, so one is sent")
expect(codexPlan?.arguments == ["login"], "codex re-logs in through `codex login`")
expect(codexPlan?.needsTerminal == false, "codex has no UI, so it needs no pty")
expect(codexPlan?.successMarkers.isEmpty == true && codexPlan?.failureMarkers.isEmpty == true,
       "codex is judged by its exit code alone, never by a guessed word in its output")
expect(RenewLoginCommand.plan(providerID: "gemini") == nil,
       "a provider with no known login command has no menu entry to enable")

// MARK: which home is the default one, and what that does to the environment

let user = URL(fileURLWithPath: "/Users/u")
expect(RenewLoginCommand.defaultHome(providerID: "claude", userHome: user) == "/Users/u/.claude",
       "the default Claude home is ~/.claude")
expect(RenewLoginCommand.defaultHome(providerID: "codex", userHome: user) == "/Users/u/.codex",
       "the default Codex home is ~/.codex")
expect(RenewLoginCommand.isDefaultHome("/Users/u/.claude/", providerID: "claude", userHome: user),
       "a trailing slash does not hide the default home")
expect(RenewLoginCommand.isDefaultHome("/Users/u/x/../.claude", providerID: "claude", userHome: user),
       "an unnormalised path does not hide the default home")
expect(!RenewLoginCommand.isDefaultHome("/Users/u/.claude2", providerID: "claude", userHome: user),
       "a numbered sibling is NOT the default home")

let named = RenewLoginCommand.environment(envKey: "CLAUDE_CONFIG_DIR", home: "/Users/u/.claude2",
                                          providerID: "claude", userHome: user)
expect(named["CLAUDE_CONFIG_DIR"] == .some("/Users/u/.claude2"),
       "a numbered account points the variable at its own home")
let defaulted = RenewLoginCommand.environment(envKey: "CLAUDE_CONFIG_DIR", home: "/Users/u/.claude",
                                              providerID: "claude", userHome: user)
expect(defaulted.keys.contains("CLAUDE_CONFIG_DIR") && defaulted["CLAUDE_CONFIG_DIR"] == .some(nil),
       "the default home REMOVES the variable rather than spelling out the default path")

// MARK: reading a terminal UI's screen

let dressed = "\u{1B}[2m\u{1B}[32mLogin \u{1B}[1msuccessful\u{1B}[0m. Press Enter\u{1B}]0;title\u{07}"
expect(RenewLoginCommand.plainText(dressed) == "Login successful. Press Enter",
       "colour codes, cursor moves and window titles come off before matching")
expect(RenewLoginCommand.contains(anyOf: ["login successful"],
                                  in: RenewLoginCommand.plainText(dressed)),
       "a marker split by escape codes is still found")
expect(RenewLoginCommand.contains(anyOf: ["LOGIN SUCCESSFUL"], in: "...login successful..."),
       "matching ignores case, so a reworded capitalisation does not break it")
expect(!RenewLoginCommand.contains(anyOf: ["login failed"], in: "opening browser to sign in"),
       "an absent marker is absent")

// MARK: the visible-Terminal fallback's quoting

expect(RenewLoginCommand.shellQuoted("/Users/u/.claude2") == "/Users/u/.claude2",
       "an ordinary path is shown to the user unquoted")
expect(RenewLoginCommand.shellQuoted("/o'brien") == #"'/o'\''brien'"#,
       "an embedded single quote is broken out the only way single quotes allow")
expect(RenewLoginCommand.shellQuoted("") == "''", "an empty word still has to occupy a word")
for hostile in ["a;rm -rf /", "a b", "$(id)", "`id`", "a\nb", "a|b", "a&b", "a*b", "a\\b", "a\"b"] {
    expect(RenewLoginCommand.shellQuoted(hostile).hasPrefix("'"),
           "shell metacharacters are quoted: \(hostile.debugDescription)")
}
expect(RenewLoginCommand.shellCommand(executable: "/usr/local/bin/claude",
                                      envKey: "CLAUDE_CONFIG_DIR", home: "/Users/u/.claude2",
                                      arguments: ["auth", "login"])
        == "env CLAUDE_CONFIG_DIR=/Users/u/.claude2 /usr/local/bin/claude auth login",
       "the fallback command sets the account's config home and nothing else")
expect(RenewLoginCommand.shellCommand(executable: "/usr/local/bin/claude",
                                      envKey: "CLAUDE_CONFIG_DIR", home: nil,
                                      arguments: ["auth", "login"])
        == "env -u CLAUDE_CONFIG_DIR /usr/local/bin/claude auth login",
       "the default home's fallback UNSETS the variable")

let awkward = "/tmp/o'brien's dir/.claude 2"
let readBack = RenewLoginCommand.shellCommand(
    executable: "/usr/bin/printenv", envKey: "CLAUDE_CONFIG_DIR", home: awkward,
    arguments: ["CLAUDE_CONFIG_DIR"])
expect(capture("/bin/sh", ["-c", readBack]) == awkward,
       "the shell hands the CLI back the exact config home, quotes and spaces intact")
let unset = RenewLoginCommand.shellCommand(
    executable: "/usr/bin/printenv", envKey: "CLAUDE_CONFIG_DIR", home: nil,
    arguments: ["CLAUDE_CONFIG_DIR"])
expect(capture("/bin/sh", ["-c", "export CLAUDE_CONFIG_DIR=/leaked; " + unset]) == "",
       "the default home's fallback beats an exported CLAUDE_CONFIG_DIR from the user's profile")

expect(RenewLoginCommand.appleScriptString(#"a"b"#) == #""a\"b""#,
       "a double quote cannot end the AppleScript literal early")
expect(RenewLoginCommand.appleScriptString(#"a\b"#) == #""a\\b""#,
       "a backslash is escaped, so the one `'\\''` introduces survives the second layer")
for value in [awkward, readBack, #"quote " and \ backslash"#] {
    let literal = RenewLoginCommand.appleScriptString(value)
    expect(capture("/usr/bin/osascript", ["-e", "return \(literal)"]) == value,
           "AppleScript decodes the literal back to the original: \(value.debugDescription)")
}
let script = RenewLoginCommand.terminalScript(command: readBack)
expect(script.contains("do script ") && script.contains("activate") && !script.contains(" in window"),
       "the fallback command runs in a NEW Terminal window, brought forward")

// MARK: the runner, against stub CLIs

let stubs = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("tally-renewlogin-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: stubs) }

func stub(_ name: String, _ body: String) -> String {
    let url = stubs.appendingPathComponent(name)
    try? ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

/// A plan shaped like Claude's (pty, markers, one keystroke) but pointed at a stub.
func terminalPlan(confirm: String? = "\r") -> RenewLoginCommand.Plan {
    RenewLoginCommand.Plan(arguments: [], needsTerminal: true,
                           progressMarkers: ["opening browser"],
                           successMarkers: ["login successful"],
                           failureMarkers: ["login failed"],
                           confirmKeystroke: confirm)
}

/// A plan shaped like Codex's: no pty, no markers, exit code is the whole answer.
let exitCodePlan = RenewLoginCommand.Plan(arguments: [], needsTerminal: false,
                                          progressMarkers: [], successMarkers: [],
                                          failureMarkers: [], confirmKeystroke: nil)

let keyReceipt = stubs.appendingPathComponent("keystroke-arrived").path

// The success stub proves three things at once: it refuses to run without a pty, its markers arrive
// wrapped in escape codes, and it only writes the receipt file after a keystroke reaches its stdin.
let successStub = stub("success", """
[ -t 0 ] && [ -t 1 ] || exit 9
printf 'Opening \\033[0mbrowser to sign in\\n'
printf 'Login \\033[1msuccessful\\033[0m. Press Enter to continue\\n'
head -c 1 > /dev/null
: > "\(keyReceipt)"
sleep 5
""")
let successOutcome = await RenewLoginRunner.run(executable: successStub, plan: terminalPlan(),
                                                environment: [:],
                                                handshakeIdleLimit: 3, overallLimit: 15)
expect(successOutcome == .renewed, "a success marker under a pty reads as renewed")
var receipted = false
for _ in 0 ..< 60 where !receipted {
    receipted = FileManager.default.fileExists(atPath: keyReceipt)
    if !receipted { usleep(50_000) }
}
expect(receipted, "the keystroke the success screen waits on actually reaches the CLI's stdin")

let failureStub = stub("failure", """
printf 'Opening browser to sign in\\n'
printf '\\033[31mLogin failed\\033[0m: something the CLI did not like\\n'
sleep 10
""")
expect(await RenewLoginRunner.run(executable: failureStub, plan: terminalPlan(), environment: [:],
                                  handshakeIdleLimit: 3, overallLimit: 15) == .failed(.reported),
       "a failure marker reads as refused, without waiting for the deadline")

let silentStub = stub("silent", "sleep 30\n")
let silentStart = Date()
expect(await RenewLoginRunner.run(executable: silentStub, plan: terminalPlan(), environment: [:],
                                  handshakeIdleLimit: 1, overallLimit: 30) == .failed(.timedOut),
       "silence before the browser is up times out on the short guard")
expect(Date().timeIntervalSince(silentStart) < 10,
       "…and does so on the SHORT guard, not by sitting out the whole renewal window")

let strandedStub = stub("stranded", "printf 'Opening browser to sign in\\n'\nsleep 30\n")
expect(await RenewLoginRunner.run(executable: strandedStub, plan: terminalPlan(), environment: [:],
                                  handshakeIdleLimit: 1, overallLimit: 3) == .failed(.timedOut),
       "once the browser is up the short guard stops applying, and the renewal window ends it")

// A killed stub must not outlive its runner: a login process left running would sit on the
// account's config home against a challenge nobody can complete.
expect(capture("/bin/sh", ["-c", "pgrep -f \(stubs.path)/stranded | wc -l"])?
        .trimmingCharacters(in: .whitespaces) == "0",
       "a timed-out login process is gone, not orphaned")

expect(await RenewLoginRunner.run(executable: stub("ok", "exit 0\n"), plan: exitCodePlan,
                                  environment: [:], handshakeIdleLimit: 3, overallLimit: 15)
        == .renewed,
       "a marker-less provider that exits 0 read as renewed")
expect(await RenewLoginRunner.run(executable: stub("bad", "exit 3\n"), plan: exitCodePlan,
                                  environment: [:], handshakeIdleLimit: 3, overallLimit: 15)
        == .failed(.reported),
       "a marker-less provider that exits non-zero reads as refused")
expect(await RenewLoginRunner.run(executable: stub("notty", "[ -t 1 ] && exit 4\nexit 0\n"),
                                  plan: exitCodePlan, environment: [:],
                                  handshakeIdleLimit: 3, overallLimit: 15) == .renewed,
       "the marker-less path runs on a plain pipe, with no pty spent on a CLI that has no UI")
expect(await RenewLoginRunner.run(executable: stubs.appendingPathComponent("nothing-here").path,
                                  plan: exitCodePlan, environment: [:],
                                  handshakeIdleLimit: 1, overallLimit: 5) == .failed(.couldNotStart),
       "a login command that cannot be started says so instead of hanging")

// The environment reaches the child exactly as `environment` composed it - the whole point of the
// feature is that the login lands on THIS account's config home.
let envStub = stub("env-named", "[ \"$CLAUDE_CONFIG_DIR\" = \"/tmp/a b/.claude2\" ] && exit 0\nexit 3\n")
expect(await RenewLoginRunner.run(executable: envStub, plan: exitCodePlan,
                                  environment: ["CLAUDE_CONFIG_DIR": "/tmp/a b/.claude2"],
                                  handshakeIdleLimit: 3, overallLimit: 15) == .renewed,
       "the child is handed the exact config home, spaces intact, with no shell in between")
setenv("CLAUDE_CONFIG_DIR", "/leaked", 1)
let unsetStub = stub("env-unset", "[ -n \"${CLAUDE_CONFIG_DIR:-}\" ] && exit 3\nexit 0\n")
expect(await RenewLoginRunner.run(executable: unsetStub, plan: exitCodePlan,
                                  environment: ["CLAUDE_CONFIG_DIR": nil],
                                  handshakeIdleLimit: 3, overallLimit: 15) == .renewed,
       "a nil value REMOVES the variable, beating one the app itself inherited")
unsetenv("CLAUDE_CONFIG_DIR")

// MARK: the visible chain - a click must never be able to do nothing

// The rule these hold is an ORDERING, and an ordering does not show up in a type check: the card
// has to be marked before anything can go async, and the "it started" signal has to be out before
// the login process is spawned, or a failure to spawn takes the announcement down with it. The
// bodies are dug out by their own closing brace at type-member indentation, the way the redeem
// suite does it, rather than scanning whole files where an unrelated call would read as a match.
func functionBody(_ source: String, from declaration: String) -> String? {
    guard let start = source.range(of: declaration),
          let end = source.range(of: "\n    }", range: start.upperBound ..< source.endIndex)
    else { return nil }
    return String(source[start.upperBound ..< end.lowerBound])
}

func readSource(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

let storeSource = readSource("Tally/Stores/RenewLoginStore.swift")
let cardSource = readSource("Tally/Views/AccountCardView.swift")
let menuSource = readSource("Tally/Views/AccountCardMenu.swift")
expect(!storeSource.isEmpty && !cardSource.isEmpty && !menuSource.isEmpty,
       "the renewal's call sites are readable from the suite")

if let body = functionBody(storeSource, from: "func renew(accountID: String,"),
   let marked = body.range(of: "inFlight.insert"),
   let async = body.range(of: "Task {"),
   let announced = body.range(of: "SystemAlert.post"),
   let spawned = body.range(of: "RenewLoginRunner.run(") {
    expect(marked.lowerBound < async.lowerBound,
           "the card is marked BEFORE any async work, so the menu closes onto a changed card")
    expect(announced.lowerBound < spawned.lowerBound,
           "the 'it started' notification goes out BEFORE the login process is spawned")
    expect(body.contains("guard announced else"),
           "a notification that could not be delivered is not treated as a signal")
    expect(body.range(of: "openTerminal", range: announced.upperBound ..< spawned.lowerBound) != nil,
           "…and falls back to a window the user can watch, before anything runs unseen")
    expect(body.components(separatedBy: "SystemAlert.post").count - 1 >= 3,
           "every ending speaks: started, renewed, and not renewed")
} else {
    expect(false, "renew()'s body was found with its ordering intact")
}

expect(functionBody(storeSource, from: "func canRenew(")?.contains("DemoUsage.isActive") == true,
       "demo fixtures have no config home, so the entry is dead on those cards by construction")
expect(cardSource.contains("RenewLoginStore.shared.isRenewing(usage.id)"),
       "the card itself reads the in-flight state, which is the signal that needs no permission")
expect(menuSource.contains("RenewLoginStore.shared.canRenew(")
        && menuSource.contains("RenewLoginStore.shared.isRenewing(usage.id)"),
       "the menu entry greys out for an account Tally cannot renew, and while one is running")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
