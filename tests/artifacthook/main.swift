import Foundation

// The Artifact publishing guard's whole decision (TallyCLI/HookArtifact.swift): whether a tool call
// about to publish a page would produce a link the person who asked for it cannot open.
//
// WHAT THESE ASSERT IS MOSTLY WHEN IT SAYS NOTHING, which is the shape of the feature rather than an
// accident of the tests. A deny costs somebody a publish they meant to make; an abstain costs
// nothing that was not already lost, because without this hook every publish goes out unchecked. So
// every input the hook cannot judge has an assertion of its own here, and the deny is one row of the
// table rather than its subject.
//
// The enumeration is DELIBERATELY EXHAUSTIVE over the tool's own action list rather than sampled:
// the actions are published in the tool's schema, so "does this action publish a new page" is a
// question with a finite answer set, and a sample of it could only ever show that the ones somebody
// thought of are right.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("tally-artifact-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

/// The two accounts every case below is about: the one the session is on, and the one the user
/// browses with. Real directories, because the comparison resolves symlinks.
let browserHome = tmp.appendingPathComponent(".claude").path
let sessionHome = tmp.appendingPathComponent(".claude2").path
for home in [browserHome, sessionHome] {
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: home),
                                            withIntermediateDirectories: true)
}

func account(_ label: String, home: String?, provider: String = "claude") -> Snapshot.Account {
    Snapshot.Account(id: label, provider: provider, label: label, launchHome: home,
                     sessionRemaining: 50, weeklyRemaining: 50, modelRemaining: 50,
                     sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                     modelWindowName: nil, resetCreditsAvailable: nil, isStale: false, error: nil)
}

let fleet = [account("Main", home: browserHome), account("Work", home: sessionHome)]

/// One run of the decision, with the ordinary mismatch as every default: an `Artifact` publish, on a
/// session whose account is not the one artifacts are published from. Each check below changes one
/// thing about it.
func refusal(tool: String? = artifactHookToolName,
             action: String? = nil,
             url: String? = nil,
             event: String? = artifactHookEvent,
             session: String? = sessionHome,
             setting: String? = browserHome,
             bypass: String? = nil,
             fallback: String = browserHome,
             resolves: Bool = true,
             accounts: [Snapshot.Account] = fleet) -> String? {
    var input: [String: Any] = [:]
    if let action { input["action"] = action }
    if let url { input["url"] = url }
    return artifactHookRefusal(toolName: tool, toolInput: input, event: event,
                               sessionHome: session, settingHome: setting, bypass: bypass,
                               fallbackHome: fallback, settingResolves: { _ in resolves },
                               name: { artifactAccountName($0, in: accounts) })
}

// MARK: - 1. The case it exists for

expect(refusal() != nil, "a publish from an account other than the chosen one is held")
expect(refusal(action: "publish") != nil, "…whether the action is named or left to default")
expect(refusal(action: "  ") != nil, "…and whitespace is not an action either")

// MARK: - 2. Every action the tool takes

// The full list out of the Artifact tool's own schema. Only the first publishes a NEW page; every
// other one names an artifact that already exists, so none of them can make a dead link.
let publishing = ["publish"]
let existing = ["list", "comments", "reply", "resolve",
                "upload_asset", "list_assets", "read_asset", "delete_asset"]
expect(publishing.allSatisfy { refusal(action: $0) != nil },
       "every action that publishes a new page is judged")
expect(existing.allSatisfy { refusal(action: $0) == nil },
       "and every action that names an artifact already published is left alone")
expect(existing.allSatisfy { !artifactActionPublishes($0) } && artifactActionPublishes(nil)
           && artifactActionPublishes("") && artifactActionPublishes(" publish "),
       "the contract both processes read says the same thing about that list")
// An action nobody has heard of is the tool having gained one, and a new verb is far likelier to
// name an existing artifact than to publish a page: this hook has no opinion about it.
expect(refusal(action: "sprinkle") == nil, "an action this build does not know is not judged")

// MARK: - 3. The update path, which is the one correct route through a mismatch

// A `url` means the page already exists and belongs to somebody; the server checks that itself, and
// denying here would close the one action that is RIGHT when the session is on the account that
// published it in the first place.
expect(refusal(url: "https://claude.ai/code/artifacts/abc") == nil,
       "updating an artifact by url is never held")
expect(refusal(action: "publish", url: "https://claude.ai/code/artifacts/abc") == nil,
       "…including when the action says publish, which is what an update is")
expect(refusal(url: "   ") != nil, "…while an empty url is not a url")

// MARK: - 4. The two accounts

expect(refusal(session: browserHome) == nil, "a session already on that account publishes freely")
expect(refusal(session: browserHome + "/") == nil, "…a trailing slash is the same account")
expect(refusal(session: browserHome, setting: browserHome + "/") == nil,
       "…on either side of the comparison")
// The home most likely to arrive spelled two ways on this machine: shared-harness setups point
// several config homes at one tree, and a session's environment carries whichever path launched it.
let link = tmp.appendingPathComponent("linked-claude").path
try? FileManager.default.removeItem(atPath: link)
try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: browserHome)
expect(refusal(session: link) == nil, "…and a home reached through a symlink is that home")
expect(refusal(session: sessionHome) != nil, "a genuinely different account is still held")

// MARK: - 5. Nothing to compare against

expect(refusal(setting: nil) == nil, "no account chosen means no opinion")
expect(refusal(setting: "") == nil, "…nor does an empty one")
expect(refusal(setting: "   ") == nil, "…nor whitespace")
// The session's own home is the opposite case: absent means the default config home, which is a
// fact about where the session is running rather than a gap in what we know.
expect(refusal(session: nil, fallback: browserHome) == nil,
       "a session with no CLAUDE_CONFIG_DIR is on the default home, and that can match")
expect(refusal(session: nil, fallback: sessionHome) != nil, "…and can just as well not")
// An exported variable holding nothing is a variable nobody set, on either side of the pair.
expect(refusal(session: "", fallback: browserHome) == nil,
       "an empty CLAUDE_CONFIG_DIR is read as no CLAUDE_CONFIG_DIR")
// A tool_input of a shape this build cannot read costs the two exemptions that live in it, and the
// comparison still runs: what is left is a publish nobody could show was safe.
expect(artifactHookRefusal(toolName: artifactHookToolName, toolInput: nil, event: nil,
                           sessionHome: sessionHome, settingHome: browserHome, bypass: nil,
                           fallbackHome: browserHome, settingResolves: { _ in true },
                           name: { artifactAccountName($0, in: fleet) }) != nil,
       "a payload with no readable tool input is still judged on the two accounts")

// MARK: - 5b. A chosen account that is no longer there

// The app clears this setting when it removes an account, but an older app with a newer CLI does
// not, and neither does somebody trashing `~/.claudeN` by hand. A setting pointing at a home that
// has gone would otherwise refuse EVERY publish on the machine and name a folder in the Trash as
// the way out.
expect(refusal(resolves: false) == nil, "a chosen account that no longer exists is not compared")
expect(refusal(resolves: true) != nil, "…while one that is still there is")
// Either witness answers, and the snapshot is the one that works while the directory cannot be
// stat'ed at all.
expect(artifactSettingResolves(browserHome, accounts: fleet, exists: { _ in false }),
       "a home the snapshot names is real whatever the filesystem says")
expect(artifactSettingResolves("/gone/.claude9", accounts: fleet, exists: { $0 == "/gone/.claude9" }),
       "…and a home on disk is real whatever the snapshot says")
expect(!artifactSettingResolves("/gone/.claude9", accounts: fleet, exists: { _ in false }),
       "…and neither witness means the setting names nothing")
expect(!artifactSettingResolves(browserHome, accounts: [account("Codex", home: browserHome,
                                                               provider: "codex")],
                                exists: { _ in false }),
       "a Codex account at that home is not a Claude account being named")
// The real witness this runs against: these two homes exist, the third never did.
expect(artifactSettingResolves(browserHome, accounts: [],
                               exists: { FileManager.default.fileExists(atPath: $0) }),
       "and the live filesystem answers the same way for a home that is really there")
expect(!artifactSettingResolves(tmp.appendingPathComponent(".claude404").path, accounts: [],
                                exists: { FileManager.default.fileExists(atPath: $0) }),
       "…and for one that is really not")

// MARK: - 6. The way out, and the ways that are not it

expect(refusal(bypass: "1") == nil, "the environment variable waives the whole guard")
expect(refusal(bypass: " 1 ") == nil, "…around whitespace")
expect(refusal(bypass: "0") != nil && refusal(bypass: "") != nil && refusal(bypass: "true") != nil,
       "…and nothing else does")

// MARK: - 7. Somebody else's tool call

expect(refusal(tool: "Bash") == nil, "another tool is not this hook's business")
expect(refusal(tool: nil) == nil, "…nor is a payload that names no tool at all")
expect(refusal(tool: "artifact") == nil, "…and the name is the tool's own spelling")
// A permission decision is only a decision on the event that asks for one. A registration somebody
// wired by hand onto another event gets silence rather than a reply naming an event that did not
// fire, which Claude Code discards anyway.
expect(refusal(event: "Stop") == nil, "an event that cannot carry a permission decision is skipped")
expect(refusal(event: nil) != nil, "…while a payload that names no event is judged on the tool")

// MARK: - 8. What the refusal says

let message = refusal() ?? ""
expect(message.contains("Main") && message.contains("Work"),
       "the refusal names both accounts by the label the panel gives them")
expect(message.contains("`tally account .claude`"),
       "…and the command that moves this session, on the config-dir name it always matches")
// A HOME WHOSE NAME HOLDS A SPACE IS ONE ARGUMENT, not two: `runSwitch` takes one, so an unquoted
// instruction is one a reader can follow exactly and still get the usage text (codex review).
let spaced = tmp.appendingPathComponent(".claude work").path
try FileManager.default.createDirectory(at: URL(fileURLWithPath: spaced),
                                        withIntermediateDirectories: true)
let spacedMessage = refusal(setting: spaced,
                            accounts: [account("Main", home: browserHome),
                                       account("Spaced", home: spaced)]) ?? ""
expect(spacedMessage.contains("`tally account '.claude work'`"),
       "a config-dir name with a space is quoted into one argument")
expect(artifactShellWord(".claude2") == ".claude2" && artifactShellWord("/Users/x/.claude-work")
           == "/Users/x/.claude-work",
       "…while an ordinary name is left bare, with no punctuation to copy by mistake")
expect(artifactShellWord("it's") == "'it'\\''s'",
       "…and a single quote is closed, added literally, and reopened")
expect(artifactShellWord("") == "''", "…and nothing at all is still one argument")
expect(message.contains(artifactAnyAccountVariable),
       "…and the way to publish anyway, so the refusal carries its own exception")
expect(message.contains(".html"), "…and the way that needs no account at all")
// The repo's own rule about prose that ships, and this sentence ships into somebody's context.
expect(!message.contains("—") && !message.contains("–"), "no em dash reaches a user-facing string")

// MARK: - 9. Naming a config home

expect(artifactAccountName(browserHome, in: fleet) == ArtifactAccountName(label: "Main",
                                                                         dir: ".claude"),
       "a home the snapshot knows is named by its label")
expect(artifactAccountName(browserHome + "/", in: fleet).label == "Main",
       "…however that home is spelled")
let unknown = artifactAccountName("/nowhere/.claude7", in: fleet)
expect(unknown.label == "/nowhere/.claude7" && unknown.dir == ".claude7",
       "a home nothing knows about is named by its path, and still typed as its directory")
expect(artifactAccountName(browserHome, in: [account("Codex", home: browserHome,
                                                     provider: "codex")]).label == browserHome,
       "and a Codex account sharing a path does not name a Claude one")
expect(artifactAccountName(browserHome, in: [account("Nowhere", home: nil)]).label == "Main"
           || artifactAccountName(browserHome, in: [account("Nowhere", home: nil)]).label
           == browserHome,
       "an account with no launch home cannot claim one")

// MARK: - 10. Reading the setting out of the state file

let state = tmp.appendingPathComponent("state.json")
func writeState(_ object: [String: Any]) throws {
    try JSONSerialization.data(withJSONObject: object).write(to: state)
}
try writeState(["version": 1, "launch": [:], "artifactAccount": browserHome])
expect(artifactAccountSetting(state) == browserHome, "the chosen account is read back")
// The half of the schema rule that matters here: this reader only knows about its own key, so a
// launch block from a version it has never seen cannot stop it answering.
try writeState(["version": 9, "launch": ["claude": ["mode": "manual", "somethingNew": true]],
                "artifactAccount": browserHome])
expect(artifactAccountSetting(state) == browserHome,
       "…out of a document carrying fields this build does not know")
try writeState(["version": 1, "launch": [:]])
expect(artifactAccountSetting(state) == nil, "a state file that never named one answers nothing")
try Data("{not json".utf8).write(to: state)
expect(artifactAccountSetting(state) == nil, "…and so does one nobody can parse")
expect(artifactAccountSetting(tmp.appendingPathComponent("absent.json")) == nil,
       "…and a file that is not there")

// MARK: - 11. The one line it prints

let quoted = artifactHookOutput(reason: "a \"label\" with quotes \\ and a backslash")
let decoded = (try? JSONSerialization.jsonObject(with: Data(quoted.utf8))) as? [String: Any]
let specific = decoded?["hookSpecificOutput"] as? [String: Any]
expect(specific?["hookEventName"] as? String == artifactHookEvent,
       "the reply names the event it is answering")
expect(specific?["permissionDecision"] as? String == "deny", "…as a refusal")
expect(specific?["permissionDecisionReason"] as? String == "a \"label\" with quotes \\ and a backslash",
       "…carrying the sentence intact, whatever the account label has in it")

// MARK: - 12. The subcommand end to end

func run(payload: Any?, environment: [String: String] = [:], setting: String? = browserHome,
         accounts: [Snapshot.Account] = fleet) -> (code: Int32, printed: [String]) {
    var printed: [String] = []
    let data = payload.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{".utf8)
    let snapshot = Snapshot(version: 2, generatedAt: Date(), accounts: accounts)
    let code = runHookArtifact(environment: environment, input: { data }, setting: { setting },
                               snapshot: { snapshot }, emit: { printed.append($0) })
    return (code, printed)
}

let held = run(payload: ["tool_name": "Artifact", "hook_event_name": "PreToolUse",
                         "tool_input": ["file_path": "/tmp/page.html"]],
               environment: ["CLAUDE_CONFIG_DIR": sessionHome])
expect(held.code == 0 && held.printed.count == 1,
       "a held publish answers 0 and prints exactly one document")
expect(held.printed.first?.contains("\"deny\"") == true, "…and that document is the refusal")

let allowed = run(payload: ["tool_name": "Artifact", "tool_input": ["action": "list"]],
                  environment: ["CLAUDE_CONFIG_DIR": sessionHome])
expect(allowed.code == 0 && allowed.printed.isEmpty,
       "a call it has no opinion about prints nothing at all")
expect(run(payload: nil, environment: ["CLAUDE_CONFIG_DIR": sessionHome]).printed.isEmpty,
       "…and neither does a payload nobody can parse")
expect(run(payload: ["tool_name": "Artifact"], environment: ["CLAUDE_CONFIG_DIR": sessionHome],
           setting: nil).printed.isEmpty,
       "…and neither does a machine that has chosen no account")
expect(run(payload: ["tool_name": "Artifact"],
           environment: ["CLAUDE_CONFIG_DIR": sessionHome,
                         artifactAnyAccountVariable: "1"]).printed.isEmpty,
       "…and neither does a session that has waived the guard")
// The hook answers for the environment rather than for a supervisor, so a session Tally never
// launched is judged exactly like one it did.
expect(run(payload: ["tool_name": "Artifact"],
           environment: ["CLAUDE_CONFIG_DIR": sessionHome]).printed.count == 1,
       "no supervisor marker is required for any of this")

try? FileManager.default.removeItem(at: tmp)

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all artifact-hook tests passed")
