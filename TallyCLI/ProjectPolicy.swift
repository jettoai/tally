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

    var isEmpty: Bool { model == nil && effort == nil && accountID == nil }
}

let projectPolicyVersion = 1

/// The file behind `tally project`. The CLI writes it; the app is free to read it.
struct ProjectPolicyFile: Codable {
    var version: Int
    /// project key (an absolute path, see `projectPolicyKey`) → provider id → overrides.
    var projects: [String: [String: ProjectPolicy]]

    init(version: Int = projectPolicyVersion,
         projects: [String: [String: ProjectPolicy]] = [:]) {
        self.version = version
        self.projects = projects
    }

    /// Decoded field by field rather than by the synthesized initializer, which requires every
    /// non-optional key to be present: this file is a contract other versions of Tally write, and a
    /// reader that refuses a document for a key it has never heard of is the opposite of additive.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? projectPolicyVersion
        projects = try container.decodeIfPresent([String: [String: ProjectPolicy]].self,
                                                 forKey: .projects) ?? [:]
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
/// but stops handing the session off, and the degradation rescue leaves the account alone. The
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
    return parts.isEmpty ? "nothing set" : parts.joined(separator: " · ")
}

// MARK: - `tally project`

/// The value after `flag` in this subcommand's own arguments, or nil when it is absent or dangling.
/// Deliberately not `flagValue` (Snapshot.swift): that one stops at a bare `--` because past the
/// marker lies the user's PROMPT, and these arguments carry no prompt to protect.
private func optionValue(_ args: [String], _ flag: String) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

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

/// The provider a `tally project` invocation is about (claude unless asked otherwise), or nil when
/// the flag was given and cannot be honoured - said here rather than at each caller so a subcommand
/// cannot teach a different vocabulary than its sibling.
///
/// A `--provider` with NO VALUE is refused rather than defaulted, and that is the whole reason this
/// distinguishes "absent" from "present but empty". Both read as nil through `optionValue`, so
/// defaulting on nil silently turned `tally project clear --provider` (a typo away from
/// `--provider codex`) into a bare `clear`, which drops EVERY provider's profile for the project.
/// A flag the user typed and this CLI cannot act on is an error, never a fallback.
private func projectProvider(_ args: [String]) -> String? {
    guard args.contains("--provider") else { return "claude" }
    guard let id = optionValue(args, "--provider") else {
        warn("--provider needs a value - use claude or codex; nothing was changed")
        return nil
    }
    guard providers.contains(where: { $0.id == id }) else {
        warn("unknown provider `\(id)` - use claude or codex; nothing was changed")
        return nil
    }
    return id
}

/// Write the file back, reporting a failure the way every subcommand here reports it. False means
/// the caller must leave with an error rather than announce a change that did not land.
private func readProjectPoliciesForWrite() -> ProjectPolicyFile? {
    do {
        return try loadProjectPoliciesForWrite()
    } catch {
        warn("\(projectPoliciesURL.path) exists but cannot be read as a launch-profile file " +
             "(\(error.localizedDescription)) - refusing to rewrite it, because rewriting from " +
             "an empty set would drop every other project's profile. Nothing was changed; fix or " +
             "delete the file and try again.")
        return nil
    }
}

private func writeProjectPolicies(_ file: ProjectPolicyFile) -> Bool {
    do {
        try saveProjectPolicies(file)
        return true
    } catch {
        warn("could not write \(projectPoliciesURL.path): \(error.localizedDescription)")
        return false
    }
}

/// `tally project set`: declare what this project launches. Writes only the axes named, so setting
/// a model later does not erase an effort set earlier.
private func runProjectSet(args: [String]) -> Int32 {
    guard let providerID = projectProvider(args) else { return 2 }
    let model = optionValue(args, "--model")
    let effort = optionValue(args, "--effort")
    let account = optionValue(args, "--account")
    guard model != nil || effort != nil || account != nil else {
        warn("nothing to set - pass --model, --effort or --account")
        return 2
    }
    // Checked before the file is even read, so a refused value cannot rewrite anything. The account
    // needs no check of its own: it is not stored as typed but resolved against the live fleet
    // below, and only an id the snapshot already listed is ever written.
    for (flag, value) in [("--model", model), ("--effort", effort)] {
        guard let value, !isLaunchAxisValue(value) else { continue }
        // A value that is another flag gets its own wording, because the general one ends in "and
        // dash" and would be read as a contradiction by the one person who most needs to act on it.
        warn(value.hasPrefix("-")
            ? "\(flag) was given no value: \"\(value)\" is another flag, not a model or effort " +
              "name; nothing was changed"
            : "\(flag) value \"\(value)\" is not a model or effort name - letters, digits, dot, " +
              "underscore, colon and dash only; nothing was changed")
        return 2
    }
    let key = projectPolicyKey()
    guard var file = readProjectPoliciesForWrite() else { return 1 }
    var policy = file.policy(providerID, for: key)
    if let model { policy.model = model }
    if let effort { policy.effort = effort }
    var accountLabel: String?
    if let account {
        // Resolved to an id NOW, against the fleet as it stands: a label stored verbatim would be a
        // second name for the account that stops matching the day it is renamed, and an id that
        // matches nothing today is a pin that silently never applies.
        let (snapshot, problem) = loadSnapshot()
        if let problem { warn(problem) }
        switch accountMatching(account, provider: providerID, in: snapshot) {
        case .one(let match):
            policy.accountID = match.id
            accountLabel = match.label
        case .none:
            warn("no \(providerID) account matches \"\(account)\" - try `tally status`; " +
                 "nothing was changed")
            return 1
        case .several(let candidates):
            // Stored profiles outlive the moment they are written, so an ambiguous name is worse
            // here than anywhere else: the wrong account would be pinned for every future launch in
            // this repo, with nothing on screen to say which one was chosen.
            warn(accountMatchAmbiguity(account, provider: providerID, candidates: candidates) +
                 "; nothing was changed")
            return 1
        }
    }
    file.projects[key, default: [:]][providerID] = policy
    guard writeProjectPolicies(file) else { return 1 }
    warn("\(key): \(providerID) runs \(projectPolicySummary(policy, accountLabel: accountLabel))")
    if let model = policy.model {
        warn("the account pick now scores this project on \(model) - a drained window for another " +
             "model no longer rules an account out")
    }
    return 0
}

/// `tally project show`: what this directory launches, and which project it inherited that from.
private func runProjectShow(cwd: String = FileManager.default.currentDirectoryPath) -> Int32 {
    let key = projectPolicyKey(cwd: cwd)
    let file = loadProjectPolicies()
    let byProvider = file.declared(for: key)
    guard !byProvider.isEmpty else {
        warn("no launch profile for \(key) - set one with `tally project set --model opus`")
        return 0
    }
    print(key)
    if realpathString(cwd) != key {
        print("  (inherited here: this directory belongs to that repo)")
    }
    let (snapshot, _) = loadSnapshot()
    for provider in providers {
        guard let policy = byProvider[provider.id] else { continue }
        let label = projectPolicyAccountLabel(policy, in: snapshot)
        let app = launchPolicy(provider.id)
        print("  \(provider.id): \(projectPolicySummary(policy, accountLabel: label))" +
              "   (app default: model \(app.model ?? "none") · effort \(app.effort ?? "none"))")
    }
    return 0
}

/// `tally project list`: every project with a profile, one tab-separated line per provider, with
/// `→` on the one this directory belongs to. Machine-readable like `worktree list`.
private func runProjectList(cwd: String = FileManager.default.currentDirectoryPath) -> Int32 {
    let file = loadProjectPolicies()
    let keys = file.projects.keys.filter { !file.declared(for: $0).isEmpty }.sorted()
    guard !keys.isEmpty else {
        warn("no project launch profiles yet - set one with `tally project set --model opus`")
        return 0
    }
    let here = projectPolicyKey(cwd: cwd)
    for key in keys {
        for (providerID, policy) in file.declared(for: key).sorted(by: { $0.key < $1.key }) {
            print("\(key == here ? "→" : " ") \(key)\t\(providerID)\t" +
                  "\(projectPolicySummary(policy))")
        }
    }
    return 0
}

/// `tally project clear`: drop this project's profile, or just one provider's half of it.
private func runProjectClear(args: [String],
                             cwd: String = FileManager.default.currentDirectoryPath) -> Int32 {
    guard let providerID = projectProvider(args) else { return 2 }
    // Whether the flag was TYPED, not whether it carried a value: a dangling `--provider` was
    // refused above, so this can no longer read a typo as "clear everything".
    let narrowed = args.contains("--provider")
    let key = projectPolicyKey(cwd: cwd)
    guard var file = readProjectPoliciesForWrite() else { return 1 }
    let existing = file.declared(for: key)
    // A bare `clear` drops the whole project; `--provider` narrows it to that provider's half.
    let dropping = narrowed ? existing.keys.filter { $0 == providerID } : Array(existing.keys)
    guard !dropping.isEmpty else {
        warn("no \(narrowed ? "\(providerID) " : "")launch profile for \(key) - nothing to clear")
        return 0
    }
    for id in dropping { file.projects[key]?.removeValue(forKey: id) }
    guard writeProjectPolicies(file) else { return 1 }
    warn("cleared \(dropping.sorted().joined(separator: ", ")) launch profile for \(key)")
    return 0
}

/// `tally project <subcommand>`: dispatch. Bare (`tally project`) shows this directory's profile,
/// since a bare command is the one someone types by hand.
func runProject(args: [String]) -> Never {
    switch args.first {
    case "set":
        exit(runProjectSet(args: Array(args.dropFirst())))
    case "show", nil:
        exit(runProjectShow())
    case "list":
        exit(runProjectList())
    case "clear":
        exit(runProjectClear(args: Array(args.dropFirst())))
    default:
        warn("""
        usage:
          tally project set --model <model> [--effort <effort>] [--account <name>] [--provider claude|codex]
                                    declare what this project launches. Applies to the whole repo
                                    (worktrees included) and outranks the app's defaults, while a
                                    flag you type outranks it. A model here also steers the ACCOUNT
                                    pick: a drained window for another model stops ruling one out
          tally project show        this directory's profile and the app defaults it overrides
                                    (bare `tally project` is the same)
          tally project list        every project with a profile, one tab-separated line per
                                    provider, marking the one you are in
          tally project clear [--provider claude|codex]
                                    drop this project's profile (or one provider's half of it)
        """)
        exit(2)
    }
}
