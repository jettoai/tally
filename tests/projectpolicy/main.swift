import Foundation

// Assertion harness for the per-project launch profile (TallyCLI/ProjectPolicy.swift): what a
// project is keyed by, what the file round-trips, how the overlay ranks against the app's defaults
// and against a typed flag, and the two predictions that must agree with it (the pin resolution the
// launcher shares, and the `status --json` block).
//
// The key resolution runs against real git repositories the harness builds in a temp directory,
// because that answer is git's and a stub would be asserting our own idea of it.

var passed = 0, failed = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

let now = parseISO("2026-07-23T12:00:00Z")!
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("tally-projectpolicy-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

// MARK: - The project key: the MAIN repo, so every worktree of it answers the same

func git(_ args: [String], in dir: URL) {
    let result = runGit(["-c", "user.email=t@t", "-c", "user.name=T",
                         "-c", "commit.gpgsign=false"] + args, cwd: dir.path)
    if result.code != 0 { print("FAIL setup: git \(args.joined(separator: " ")): \(result.err)") }
}

let repo = tmp.appendingPathComponent("repo")
let nested = repo.appendingPathComponent("deep/sub")
try! FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
git(["init", "-q", "-b", "main", repo.path], in: tmp)
git(["commit", "-q", "--allow-empty", "-m", "root"], in: repo)
let worktree = tmp.appendingPathComponent("repo-feature")
git(["worktree", "add", "-q", "-b", "feature", worktree.path], in: repo)

let repoKey = realpathString(repo.path)
check("a repo's own root keys on itself", projectPolicyKey(cwd: repo.path) == repoKey)
check("a subdirectory keys on the repo root, not on itself",
      projectPolicyKey(cwd: nested.path) == repoKey)
// The reason the key is the MAIN repo: `tally claude -w feature` must run what the project declared
// without the worktree being told again, and it must survive that worktree being remade.
check("a worktree inherits its main repo's key",
      projectPolicyKey(cwd: worktree.path) == repoKey)
let plain = tmp.appendingPathComponent("not-a-repo")
try! FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
check("a directory outside any repository keys on itself",
      projectPolicyKey(cwd: plain.path) == realpathString(plain.path))

// MARK: - The file: round trip, pruning, and a fail-open read

let store = tmp.appendingPathComponent("project-policies.json")
check("a missing file reads as no profiles at all", loadProjectPolicies(store).projects.isEmpty)
try! "{ not json".write(to: store, atomically: true, encoding: .utf8)
check("an unreadable file reads the same way rather than failing a launch",
      loadProjectPolicies(store).projects.isEmpty)

var file = ProjectPolicyFile()
file.projects[repoKey] = ["claude": ProjectPolicy(model: "opus", effort: "high",
                                                  accountID: "claude:.claude2")]
try! saveProjectPolicies(file, to: store)
let reloaded = loadProjectPolicies(store)
check("what was written comes back unchanged",
      reloaded.policy("claude", for: repoKey)
          == ProjectPolicy(model: "opus", effort: "high", accountID: "claude:.claude2"))
check("the file records its contract version", reloaded.version == projectPolicyVersion)
check("a provider with no profile reads as an empty one, not as a failure",
      reloaded.policy("codex", for: repoKey).isEmpty)
check("so does an unknown project", reloaded.policy("claude", for: "/nowhere").isEmpty)
// A document written by a later version must not be refused for a key this build has never seen,
// and must not lose the projects it does understand.
try! """
{ "version": 99, "projects": { "\(repoKey)": { "claude": { "model": "opus", "future": 1 } } },
  "somethingNew": true }
""".write(to: store, atomically: true, encoding: .utf8)
check("a document from a later version still yields its projects",
      loadProjectPolicies(store).policy("claude", for: repoKey).model == "opus")

var pruning = ProjectPolicyFile()
pruning.projects[repoKey] = ["claude": ProjectPolicy()]
try! saveProjectPolicies(pruning, to: store)
check("clearing every axis removes the project instead of leaving a husk",
      loadProjectPolicies(store).projects.isEmpty)

// MARK: - Precedence: a typed flag > the project > the app

let appDefaults = LaunchPolicy(mode: "auto", permissionMode: "bypass", startMode: "continue",
                               model: "fable", fallbackModel: "opus", effort: "high")
let both = effectivePolicy(appDefaults, project: ProjectPolicy(model: "opus", effort: "xhigh"))
check("the project's model outranks the app default", both.model == "opus")
check("so does its effort", both.effort == "xhigh")
let modelOnly = effectivePolicy(appDefaults, project: ProjectPolicy(model: "opus"))
check("an axis the project leaves alone keeps the app's value", modelOnly.effort == "high")
check("and the app's other launch defaults ride along untouched",
      modelOnly.permissionMode == "bypass" && modelOnly.startMode == "continue"
          && modelOnly.fallbackModel == "opus")
check("an empty profile changes nothing at all",
      effectivePolicy(appDefaults, project: ProjectPolicy()).model == appDefaults.model)

/// The value after `flag`, read the way the CLI's own reader would.
func after(_ flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

let injected = applyLaunchDefaults([], policy: both, providerID: "claude")
check("a project profile is injected as the launch's own flags",
      after("--model", in: injected) == "opus" && after("--effort", in: injected) == "xhigh")
let typedModel = applyLaunchDefaults(["--model", "haiku"], policy: both, providerID: "claude")
check("a typed --model outranks the project profile",
      after("--model", in: typedModel) == "haiku"
          && typedModel.filter { $0 == "--model" }.count == 1)
check("…while the axis the user did not type still comes from the project",
      after("--effort", in: typedModel) == "xhigh")
check("a typed --effort is left alone too",
      after("--effort", in: applyLaunchDefaults(["--effort", "low"], policy: both,
                                                providerID: "claude")) == "low")
// The same rule at the other scope, so this cannot be satisfied by never injecting anything.
check("with no project profile the app's own default is what lands",
      after("--model", in: applyLaunchDefaults([], policy: appDefaults,
                                               providerID: "claude")) == "fable")
check("codex takes the profile in its own spelling",
      after("-m", in: applyLaunchDefaults([], policy: both, providerID: "codex")) == "opus")
// Past a bare `--` lies the user's prompt: a flag injected there is read by nobody, and a `--model`
// the user WROTE in a sentence is not a choice about this launch.
let withPrompt = applyLaunchDefaults(["--", "explain", "--model"], policy: both,
                                     providerID: "claude")
check("defaults are injected before the prompt marker, where they are read",
      withPrompt.firstIndex(of: "--")! > withPrompt.firstIndex(of: "--model")!)
check("…and the word --model inside the prompt is not mistaken for a typed flag",
      after("--model", in: withPrompt) == "opus"
          && withPrompt.suffix(3) == ["--", "explain", "--model"])

// MARK: - The model the launch actually runs, which is what the accounts are scored FOR

// The defect this closes: the ranking was applied to the FLAG and then computed a second time,
// from the policy alone, for the pick. `tally claude --model opus` reached the child as opus and
// the pick went on scoring accounts for fable, so a session deliberately launched a tier down was
// still refused an account whose flagship window was dry.
check("the model a launch carries is read back off its own args",
      launchPrimaryModel(applyLaunchDefaults([], policy: both, providerID: "claude"),
                         providerID: "claude") == "opus")
check("a typed --model is what comes back, not the profile it outranked",
      launchPrimaryModel(applyLaunchDefaults(["--model", "haiku"], policy: both,
                                             providerID: "claude"),
                         providerID: "claude") == "haiku")
check("codex is read in its own spelling",
      launchPrimaryModel(applyLaunchDefaults([], policy: both, providerID: "codex"),
                         providerID: "codex") == "opus")
check("…including a typed -m", launchPrimaryModel(["-m", "gpt-5.6-sol"], providerID: "codex")
          == "gpt-5.6-sol")
check("a launch declaring no model at all reads as none",
      launchPrimaryModel([], providerID: "claude") == nil)
// A dangling flag suppresses the injection (the user typed the axis), and the CLI gets to complain
// about its own flag; the caller falls back to the configured default rather than inventing one.
check("a dangling --model reads as none, so the caller falls back",
      launchPrimaryModel(applyLaunchDefaults(["--model"], policy: both, providerID: "claude"),
                         providerID: "claude") == nil)
check("a --model inside the prompt is a word, not a declaration",
      launchPrimaryModel(["--", "compare", "--model", "haiku"], providerID: "claude") == nil)

let fixture = """
{
  "version": 2,
  "generatedAt": "2026-07-23T11:55:00Z",
  "accounts": [
    { "id": "claude:.claude", "provider": "claude", "label": "Claude",
      "launchHome": "/Users/u/.claude", "isStale": false,
      "sessionRemaining": 80, "sessionResetsAt": "2026-07-23T14:00:00Z",
      "weeklyRemaining": 90, "weeklyResetsAt": "2026-07-27T12:00:00Z",
      "modelWindowName": "Fable", "modelRemaining": 0,
      "modelResetsAt": "2026-07-27T12:00:00Z" },
    { "id": "claude:.claude2", "provider": "claude", "label": "Claude 2",
      "launchHome": "/Users/u/.claude2", "isStale": false,
      "sessionRemaining": 40, "sessionResetsAt": "2026-07-23T16:00:00Z",
      "weeklyRemaining": 20, "weeklyResetsAt": "2026-07-29T12:00:00Z",
      "modelWindowName": "Fable", "modelRemaining": 60,
      "modelResetsAt": "2026-07-29T12:00:00Z" }
  ]
}
"""
func decodeSnapshot(_ json: String) -> Snapshot {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(Snapshot.self, from: Data(json.utf8))
}
let snapshot = decodeSnapshot(fixture)

let projectPinned = effectivePolicy(LaunchPolicy(),
                                    project: ProjectPolicy(accountID: "claude:.claude2"))
check("a project account reads as the manual pin the whole CLI already understands",
      projectPinned.mode == "manual" && projectPinned.pinnedAccountID == "claude:.claude2")
check("it carries no denormalized home: that fallback belongs to the pin the app wrote",
      projectPinned.pinnedHome == nil)
check("the shared resolver launches it",
      pinnedLaunchHome(snapshot, policy: projectPinned) == "/Users/u/.claude2")
// The app's pin and the project's are the same instruction at different scopes; the narrower wins,
// and it must not inherit the wider one's home (that would exec the wrong config dir).
let appPin = LaunchPolicy(mode: "manual", pinnedAccountID: "claude:.claude",
                          pinnedHome: "/Users/u/.claude")
let over = effectivePolicy(appPin, project: ProjectPolicy(accountID: "claude:.claude2"))
check("a project pin outranks the app's pin", over.pinnedAccountID == "claude:.claude2")
check("…and drops the app's home along with it",
      over.pinnedHome == nil && pinnedLaunchHome(snapshot, policy: over) == "/Users/u/.claude2")
// An account the snapshot does not list: with no home to fall back on, the pin resolves to nothing
// and the launcher picks by headroom instead (main.swift), rather than exec'ing a guess.
let ghost = effectivePolicy(LaunchPolicy(), project: ProjectPolicy(accountID: "claude:.gone"))
check("a project pin on an unknown account resolves to nothing",
      pinnedLaunchHome(snapshot, policy: ghost) == nil)
// A listed account with no launch home is Tally saying the login is gone.
let dormant = decodeSnapshot(fixture.replacingOccurrences(
    of: "\"launchHome\": \"/Users/u/.claude2\", \"isStale\": false", with: "\"isStale\": false"))
check("a project pin on a signed-out account resolves to nothing either",
      pinnedLaunchHome(dormant, policy: projectPinned) == nil)
check("and `tally status` puts its arrow where the launch would go",
      launchMarkers(providerID: "claude", in: snapshot, policy: projectPinned,
                    quarantined: [], now: now) == ("claude:.claude2", "claude:.claude2"))

// MARK: - The model override reaches the ACCOUNT pick, which is the point of the feature

func pick(_ primaryModel: String?) -> String? {
    launchPick(providerID: "claude", in: snapshot, primaryModel: primaryModel,
               quarantined: [], now: now)?.id
}
check("under the fleet's Fable default the drained account is ruled out",
      pick("fable") == "claude:.claude2")
check("under this project's opus profile it is eligible again",
      pick(effectivePolicy(appDefaults, project: ProjectPolicy(model: "opus")).model)
          == "claude:.claude")
check("…which is the same answer `status` predicts for that project",
      launchMarkers(providerID: "claude", in: snapshot,
                    policy: effectivePolicy(appDefaults, project: ProjectPolicy(model: "opus")),
                    quarantined: [], now: now).best == "claude:.claude")

// The whole chain the launcher runs, end to end: rank the sources into the args, read the answer
// back, score the accounts with it. A typed flag has to move the ACCOUNT, not just the flag.
let opusProject = effectivePolicy(appDefaults, project: ProjectPolicy(model: "opus"))
func pickFor(_ typed: [String]) -> String? {
    let args = applyLaunchDefaults(typed, policy: opusProject, providerID: "claude")
    return pick(launchPrimaryModel(args, providerID: "claude") ?? opusProject.model)
}
check("an opus project lands on the account whose Fable window is spent",
      pickFor([]) == "claude:.claude")
check("typing --model fable over it moves the LAUNCH, not only the flag",
      pickFor(["--model", "fable"]) == "claude:.claude2")

// The launcher itself, by source: the three consumers of that value are in `runLaunch`, which this
// harness cannot call (it execs). What it can pin is that none of them went back to reading the
// policy directly, which is exactly how the flag stopped reaching the pick the first time.
let source = (try? String(contentsOfFile: "TallyCLI/main.swift", encoding: .utf8)) ?? ""
// `runLaunch` only: `best-dir` and `launch-dir` legitimately score on the policy, having no args a
// model could have been typed into.
let launcher = source.components(separatedBy: "func runStatus").first ?? ""
check("the harness really read the launcher", launcher.contains("func runLaunch"))
check("the launcher scores the pick on the model the launch carries",
      launcher.contains("let primaryModel = launchPrimaryModel(passthrough, providerID: provider.id)"))
check("…and hands that same value to the quarantine, the pick and the reason",
      launcher.contains("quarantinedAccounts(forPrimary: primaryModel)")
          && launcher.contains("primaryModel: primaryModel, quarantined: quarantined")
          && launcher.contains("pickReason(account, primaryModel: primaryModel)"))
check("…with none of the three reading the configured default behind the flag's back",
      !launcher.contains("forPrimary: policy.model")
          && !launcher.contains("primaryModel: policy.model"))

// MARK: - `accountMatching`: one matcher for `--account` and for what `project set` stores

/// The account a hand-written name resolves to, by id.
func matchedID(_ name: String, provider: String = "claude", in snapshot: Snapshot) -> String? {
    accountMatching(name, provider: provider, in: snapshot)?.id
}
check("an account matches on its label", matchedID("claude 2", in: snapshot) == "claude:.claude2")
check("…and on its config-dir name", matchedID(".claude2", in: snapshot) == "claude:.claude2")
check("matching is case-insensitive", matchedID("CLAUDE 2", in: snapshot) == "claude:.claude2")
check("a name nobody answers to matches nothing", matchedID("zzz", in: snapshot) == nil)
check("another provider's accounts are not candidates",
      matchedID("claude 2", provider: "codex", in: snapshot) == nil)
check("a signed-out account is not matchable: naming it is not a way to launch it",
      matchedID("claude 2", in: dormant) == nil)

// MARK: - `status --json`: additive, and only when the directory has a profile

func parse(_ encoded: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(encoded.utf8))) as? [String: Any] ?? [:]
}
var reporting = ProjectPolicyFile()
reporting.projects[repoKey] = ["claude": ProjectPolicy(model: "opus", accountID: "claude:.claude2"),
                               "codex": ProjectPolicy()]
let profile = statusProjectProfile(reporting, key: repoKey)
let report = parse(encodeStatusReport(statusReport(snapshot, policies: [:],
                                                   projectPolicy: profile, now: now)))
check("the contract version does not move for an added key", report["version"] as? Int == 1)
let block = report["projectPolicy"] as? [String: Any] ?? [:]
check("the block names the project it is keyed by", block["path"] as? String == repoKey)
let byProvider = block["providers"] as? [String: [String: Any]] ?? [:]
check("and carries the provider's overrides", byProvider["claude"]?["model"] as? String == "opus")
check("…including the resolved account id",
      byProvider["claude"]?["accountID"] as? String == "claude:.claude2")
check("an axis the profile leaves alone is omitted, not null",
      byProvider["claude"]?["effort"] == nil)
check("a provider that sets nothing does not appear", byProvider["codex"] == nil)
check("a directory with no profile gets no key at all",
      parse(encodeStatusReport(statusReport(snapshot, policies: [:], now: now)))["projectPolicy"]
          == nil)
check("a project whose every provider is empty produces no block",
      statusProjectProfile(ProjectPolicyFile(projects: [repoKey: ["claude": ProjectPolicy()]]),
                           key: repoKey) == nil)
check("neither does a key nobody has written",
      statusProjectProfile(reporting, key: "/nowhere") == nil)

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
