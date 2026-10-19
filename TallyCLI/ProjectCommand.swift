import Foundation

// MARK: - `tally project`

/// The value after `flag` in this subcommand's own arguments, or nil when it is absent or dangling.
/// Deliberately not `flagValue` (Snapshot.swift): that one stops at a bare `--` because past the
/// marker lies the user's PROMPT, and these arguments carry no prompt to protect.
private func optionValue(_ args: [String], _ flag: String) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
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
    let makeDefault = args.contains("--default")
    let chromeValue = optionValue(args, "--chrome")
    guard model != nil || effort != nil || account != nil || makeDefault || args.contains("--chrome") else {
        warn("nothing to set - pass --model, --effort, --account, --chrome or --default")
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
    // Same rule as the axes above: refused before the file is read. `--chrome` is Claude in Chrome's.
    var chrome: Bool?
    if args.contains("--chrome") {
        guard chromeValue == "on" || chromeValue == "off" else {
            warn("--chrome takes on or off, not \"\(chromeValue ?? "")\"; nothing was changed")
            return 2
        }
        guard providerID == "claude" else {
            warn("--chrome is for claude only (Claude in Chrome); nothing was changed")
            return 2
        }
        chrome = chromeValue == "on"
    }
    let key = projectPolicyKey()
    guard var file = readProjectPoliciesForWrite() else { return 1 }
    var policy = file.policy(providerID, for: key)
    if let model { policy.model = model }
    if let chrome { policy.chrome = chrome }
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
    // A bare `--default` writes no empty provider entry, only the default.
    if !policy.isEmpty { file.projects[key, default: [:]][providerID] = policy }
    if makeDefault { file.defaults[key] = providerID }
    guard writeProjectPolicies(file) else { return 1 }
    if !policy.isEmpty {
        warn("\(key): \(providerID) runs \(projectPolicySummary(policy, accountLabel: accountLabel))")
    }
    if makeDefault {
        warn("new windows here open with \(providerID) (tally start, tally session clear)")
    }
    if chrome == true, chromeAccountSetting() == nil {
        warn("no account is set for Claude in Chrome in Tally's settings yet; launches here keep " +
             "the usual pick until one is")
    }
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
    let opens = projectDefaultProvider(file, key: key)
    guard !byProvider.isEmpty || opens != nil else {
        warn("no launch profile for \(key) - set one with `tally project set --model opus`")
        return 0
    }
    print(key)
    if realpathString(cwd) != key {
        print("  (inherited here: this directory belongs to that repo)")
    }
    if let opens { print("  opens with: \(opens)") }
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
    let droppedDefault = clearProjectDefault(&file, key: key, provider: narrowed ? providerID : nil)
    guard !dropping.isEmpty || droppedDefault else {
        warn("no \(narrowed ? "\(providerID) " : "")launch profile for \(key) - nothing to clear")
        return 0
    }
    for id in dropping { file.projects[key]?.removeValue(forKey: id) }
    guard writeProjectPolicies(file) else { return 1 }
    if !dropping.isEmpty { warn("cleared \(dropping.sorted().joined(separator: ", ")) launch profile for \(key)") }
    if droppedDefault { warn("cleared the default provider for \(key)") }
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
          tally project set --model <model> [--effort <effort>] [--account <name>] [--chrome on|off] [--provider claude|codex] [--default]
                                    declare what this project launches. Applies to the whole repo
                                    (worktrees included) and outranks the app's defaults, while a
                                    flag you type outranks it. A model here also steers the ACCOUNT
                                    pick: a drained window for another model stops ruling one out.
                                    --default: new windows here open with that provider (tally start)
                                    --chrome on: a new launch here prefers the account Claude in
                                    Chrome is set to, when that account has room (claude only)
          tally project show        this directory's profile and the app defaults it overrides
                                    (bare `tally project` is the same)
          tally project list        every project with a profile, one tab-separated line per
                                    provider, marking the one you are in
          tally project clear [--provider claude|codex]
                                    drop this project's profile and default (or one provider's half)
        """)
        exit(2)
    }
}
