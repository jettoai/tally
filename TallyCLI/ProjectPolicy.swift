import Foundation

// Per-project launch profiles: "in THIS repo, launch opus" - and everything downstream agreeing.
//
// The app's launch policy (Snapshot.swift) is one fleet-wide answer to "what do new sessions run".
// That is the right default and the wrong granularity for the case this file exists for: most
// projects want the flagship, a few are happy a tier down, and the few are exactly where the
// flagship quota should NOT be spent. Declaring that per project turns it into a fact the launcher
// can act on rather than a discipline someone has to remember at every `tally claude`.
//
// The override is not just a flag on the command line. `primaryModel` runs through every account
// pick (AccountPick.swift): with opus declared here, a drained Fable window stops ruling an account
// out, so this project's sessions land on the accounts the Fable-first projects have finished with.
// That is the whole point - the profile changes WHICH ACCOUNT gets picked, not only what is typed.
//
// Precedence, everywhere: a flag the user typed > this project's profile > the app's defaults.
// The middle term is new; the outer two already outranked each other the same way.
//
// Storage is `~/.tally/project-policies.json`, owned by this CLI (the app only ever reads it).
// Versioned and additive, like the `status --json` contract: fields may appear in later versions,
// never vanish or change meaning.

// MARK: - Model

/// One project's declared overrides for one provider. Every field is optional and an absent one
/// means "no opinion, keep what the app decided" - a profile that sets only the model must not
/// silently reset the effort.
struct ProjectPolicy: Codable, Equatable {
    var model: String?
    var effort: String?
    /// A per-project account pin, stored as the account id even when a label was typed: labels are
    /// how people talk about accounts and ids are what survives a rename of the label.
    var accountID: String?
    /// Prefer the account set for Claude in Chrome (`chromeAccountSetting`) when a NEW launch here
    /// takes the headroom pick. Claude only. nil is no opinion; false is an explicit off.
    var chrome: Bool?

    var isEmpty: Bool { model == nil && effort == nil && accountID == nil && chrome == nil }
}

let projectPolicyVersion = 1

/// The file behind `tally project`. The CLI writes it; the app is free to read it.
struct ProjectPolicyFile: Codable {
    var version: Int
    /// project key (an absolute path, see `projectPolicyKey`) → provider id → overrides.
    var projects: [String: [String: ProjectPolicy]]
    /// project key → the provider new windows there open with (`tally start`, `tally session clear`),
    /// written by `tally project set --default`. Absent is "no opinion": Claude, as before it existed.
    var defaults: [String: String]

    init(version: Int = projectPolicyVersion,
         projects: [String: [String: ProjectPolicy]] = [:], defaults: [String: String] = [:]) {
        self.version = version
        self.projects = projects
        self.defaults = defaults
    }

    /// Decoded field by field rather than by the synthesized initializer, which requires every
    /// non-optional key to be present: this file is a contract other versions of Tally write, and a
    /// reader that refuses a document for a key it has never heard of is the opposite of additive.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? projectPolicyVersion
        projects = try container.decodeIfPresent([String: [String: ProjectPolicy]].self,
                                                 forKey: .projects) ?? [:]
        defaults = try container.decodeIfPresent([String: String].self, forKey: .defaults) ?? [:]
    }

    /// One project's overrides for one provider; an unknown project or provider is simply "none".
    func policy(_ providerID: String, for key: String) -> ProjectPolicy {
        projects[key]?[providerID] ?? ProjectPolicy()
    }

    /// One project's providers that actually declare something. The filter is here rather than at
    /// each reader because "has a profile" has to mean the same thing to `show`, to `clear` and to
    /// the `status --json` block: an entry that sets nothing is not a profile, and a document
    /// written by an older build (or by hand) can still contain one.
    func declared(for key: String) -> [String: ProjectPolicy] {
        (projects[key] ?? [:]).filter { !$0.value.isEmpty }
    }
}

let projectPoliciesURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/project-policies.json")

// MARK: - Project identity

/// The identity a launch profile is keyed by: the MAIN repo's working tree, fully resolved
/// (GitRepoRoot.swift), or this directory itself when git says it is not a repository.
///
/// The main repo rather than the current checkout, so a parallel line inherits what its project
/// declared: `tally claude -w feature` lands in `../<repo>-feature`, and a worktree that had to be
/// told again which model it runs would be a worktree that silently runs the wrong one. It is also
/// the only key that survives the worktree being removed and made again under the same name.
func projectPolicyKey(cwd: String = FileManager.default.currentDirectoryPath) -> String {
    projectPolicyKey(cwd: cwd, mainRepo: resolveMainRepo(cwd: cwd))
}

/// The rule itself, with git's answer already in hand.
///
/// For a caller that had to ask git about this directory anyway: the session rows of
/// `tally status --json` want the parallel line's NAME as well as the key, and both are built from
/// the same two answers, so asking twice would double the subprocesses for one directory and, worse,
/// could key a project one way while naming it another if the two calls disagreed (a worktree
/// removed between them). Pure, so the rule can be asserted without a repository on disk.
func projectPolicyKey(cwd: String, mainRepo: String?) -> String {
    mainRepo ?? realpathString(cwd)
}

// MARK: - Reading and writing

/// Fail open, exactly like the snapshot read: a missing file is the ordinary case (nobody has
/// declared a profile), and an unreadable one must not stop a launch either - the launcher's job is
/// to start a session, and no profile is a worse outcome than no session.
///
/// For READING only. A write must not come through here (see `loadProjectPoliciesForWrite`).
func loadProjectPolicies(_ url: URL = projectPoliciesURL) -> ProjectPolicyFile {
    guard let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(ProjectPolicyFile.self, from: data)
    else { return ProjectPolicyFile() }
    return file
}

/// The strict read behind every WRITE, because `set` and `clear` are read-modify-write and the
/// fail-open read above is a data-loss bug in that position: a file that exists but does not parse
/// would come back as an empty set, and saving that empty set on top of it deletes every OTHER
/// project's profile to record one. Failing open costs a launch its profile for one run; failing
/// open here costs the file.
///
/// Existence is what separates the two cases, and it has to be asked separately: "no such file" and
/// "there but unreadable" are the same `Data(contentsOf:)` failure, and only the first one means
/// there is nothing to lose. An absent file is a normal empty start - the first `set` creates it.
func loadProjectPoliciesForWrite(_ url: URL = projectPoliciesURL) throws -> ProjectPolicyFile {
    guard FileManager.default.fileExists(atPath: url.path) else { return ProjectPolicyFile() }
    return try JSONDecoder().decode(ProjectPolicyFile.self, from: try Data(contentsOf: url))
}

/// Write the file back, atomically. Empty entries are pruned first, so clearing a project leaves no
/// husk behind for `tally project list` to report as a profile that sets nothing.
func saveProjectPolicies(_ file: ProjectPolicyFile, to url: URL = projectPoliciesURL) throws {
    var next = file
    next.version = projectPolicyVersion
    for (key, byProvider) in next.projects {
        let kept = byProvider.filter { !$0.value.isEmpty }
        if kept.isEmpty { next.projects.removeValue(forKey: key) } else { next.projects[key] = kept }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try encoder.encode(next).write(to: url, options: .atomic)
}

/// The provider new windows in this project open with, or nil when none was declared or the
/// declared one is not a provider this build knows.
func projectDefaultProvider(_ file: ProjectPolicyFile, key: String) -> String? {
    guard let id = file.defaults[key], providers.contains(where: { $0.id == id }) else { return nil }
    return id
}

func projectDefaultProvider(cwd: String = FileManager.default.currentDirectoryPath) -> String? {
    projectDefaultProvider(loadProjectPolicies(), key: projectPolicyKey(cwd: cwd))
}

/// Drop this project's declared default: every provider's when `provider` is nil (a bare `clear`),
/// otherwise only when it names that provider. True when something was removed.
@discardableResult
func clearProjectDefault(_ file: inout ProjectPolicyFile, key: String, provider: String?) -> Bool {
    guard let current = file.defaults[key], provider == nil || provider == current else { return false }
    file.defaults.removeValue(forKey: key)
    return true
}

/// This directory's overrides for one provider, the one-line read every launch surface uses.
func projectPolicy(_ providerID: String,
                   cwd: String = FileManager.default.currentDirectoryPath) -> ProjectPolicy {
    loadProjectPolicies().policy(providerID, for: projectPolicyKey(cwd: cwd))
}

// MARK: - The overlay

/// The launch policy THIS invocation runs under: the app's own, with the project's declared
/// overrides laid on top. Flags the user typed outrank both and are applied by the caller, which is
/// where they have always been applied.
///
/// A project ACCOUNT reads as a manual pin, deliberately: "this project runs on that account" and
/// "this fleet runs on that account" are the same instruction at different scopes, and expressing it
/// as the pin the whole CLI already understands is what makes every consequence follow for free -
/// the pin is launched even when it is dry, `tally status` marks it, the supervisor stays resident
/// but stops handing the session off, and the degradation rescue leaves the account alone. All of
/// which holds until the account has nothing left at all, where the supervisor releases it for the
/// same reason it releases a session's own pin (DroughtWatch.swift). The
/// denormalized `pinnedHome` is dropped with it: that fallback exists for a pin the APP wrote
/// alongside a home it had just seen, and carrying the app's home under a different account's id
/// would launch the wrong config dir. Without it a project pin whose account is missing from the
/// snapshot falls through to the headroom pick, which is what the launcher does with any pin it
/// cannot resolve.
func effectivePolicy(_ base: LaunchPolicy, project: ProjectPolicy) -> LaunchPolicy {
    var policy = base
    if let model = project.model { policy.model = model }
    if let effort = project.effort { policy.effort = effort }
    if let accountID = project.accountID {
        policy.mode = "manual"
        policy.pinnedAccountID = accountID
        policy.pinnedHome = nil
    }
    return policy
}

/// The `projectPolicy` block of `tally status --json`, or nil when this directory declares nothing.
/// Built here rather than in StatusReport.swift so the report stays a pure value type with no idea
/// where a policy file lives.
func statusProjectProfile(_ file: ProjectPolicyFile, key: String) -> StatusReport.ProjectProfile? {
    let byProvider = file.declared(for: key)
    guard !byProvider.isEmpty else { return nil }
    return StatusReport.ProjectProfile(
        path: key,
        providers: byProvider.mapValues {
            StatusReport.ProjectProfile.Overrides(model: $0.model, effort: $0.effort,
                                                  accountID: $0.accountID)
        })
}

/// The account a launch in this project should prefer for Claude in Chrome: the setting, read only
/// when the project turned the preference on. nil when off or when no account is set.
func launchChromeAccount(_ project: ProjectPolicy, setting: @autoclosure () -> String?) -> String? {
    project.chrome == true ? setting() : nil
}

// MARK: - Human summary

/// The name the rest of the CLI gives the account a profile pins: nil when it pins none, and nil
/// when the snapshot no longer lists the one it does. The label to hand `projectPolicySummary`.
func projectPolicyAccountLabel(_ policy: ProjectPolicy, in snapshot: Snapshot?) -> String? {
    policy.accountID.flatMap { id in snapshot?.accounts.first { $0.id == id }?.label }
}

/// One line describing what a profile does, shared by `set`, `show` and `list` so the three cannot
/// describe the same stored value differently. `accountLabel` is the account's own name when the
/// snapshot still knows it; the id is a fair fallback, not a nicer one.
func projectPolicySummary(_ policy: ProjectPolicy, accountLabel: String? = nil) -> String {
    var parts: [String] = []
    if let model = policy.model { parts.append("model \(model)") }
    if let effort = policy.effort { parts.append("effort \(effort)") }
    if let accountID = policy.accountID { parts.append("account \(accountLabel ?? accountID)") }
    if let chrome = policy.chrome { parts.append("chrome \(chrome ? "on" : "off")") }
    return parts.isEmpty ? "nothing set" : parts.joined(separator: " · ")
}

// MARK: - Launch axis values

/// Whether a value is usable as a launch axis: a model or an effort name, and nothing else.
///
/// Letters, digits, dot, underscore, colon and dash, ASCII only - every model and effort name any
/// provider here has ever used (`opus`, `gpt-5.6-sol`, `us.anthropic.claude-opus-4:1`, `xhigh`) fits
/// inside that, and nothing a shell reacts to does.
///
/// A FULL BEDROCK ARN DOES NOT FIT, and that is a decision rather than an oversight (raised in
/// review, 2026-08-07, deferred deliberately). Those carry `/`, which this refuses. Widening it for
/// the model axis alone would put the two entrances that share this rule - `tally project set
/// --model` and `tally model` - in disagreement about what may be stored; and this is the entrance
/// half of a shell-injection fix whose other half is `shellSingleQuoted` (LaunchDir.swift), so
/// loosening one lock for a case nobody has hit is a bad trade. Supporting such an id means
/// widening BOTH entrances and adding the quoting tests that go with it, which is its own change.
///
/// The entrance half of the shell-injection fix whose other half is `shellSingleQuoted`
/// (LaunchDir.swift, where the mechanism is written down). Quoting alone would leave the profile
/// itself holding a payload for whichever reader is written next; refusing it here alone would
/// leave every profile an older build already wrote unquoted. Neither lock covers the other.
///
/// A value that is itself a flag is not a model, the same rule `launchPrimaryModel` states for the
/// same reason (Snapshot.swift): `optionValue` hands back whatever token follows the flag, so
/// `tally project set --model --account "Claude 4"` read `--account` as the model - and the dash is
/// a legal character, so everything above waved it through. What got stored was then injected back
/// as `--model --account`, breaking the launch it was meant to steer. The dash is legal INSIDE a
/// name (`gpt-5.6-sol`) and never at the front of one.
func isLaunchAxisValue(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("-") && value.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0))
    }
}
