import Foundation

// The `tally hook-artifact` subcommand: Claude Code's `PreToolUse` hook on the `Artifact` tool,
// registered by the app's Integrations pane. It refuses a publish that would produce a link the user
// cannot open, and says how to publish one they can (Tally/Core/ArtifactHookContract.swift holds the
// whole reasoning and the spellings both processes share).
//
// THE SAME HARD CONSTRAINTS AS THE OTHER HOOKS: this runs inside somebody's session, on an event
// they did not ask for, and it never throws, never blocks and answers 0 whatever happens. Like
// `hook-knock` it PRINTS, so the rule is the sharper one: STDOUT CARRIES THE HOOK JSON OR NOTHING AT
// ALL. A diagnostic on stdout is not a diagnostic, it is a parse error in the middle of a turn.
//
// AND IT FAILS OPEN, which is where it differs from every gate this repo has written before. The
// guard is a convenience: it exists because Tally decides which account a session runs on, so Tally
// owes the session the one fact it cannot see. Anything that leaves it unable to judge (no account
// chosen in Settings, no state file, a payload that will not parse, a tool call that is not a
// publish) comes out as SILENCE rather than as a refusal. A wrong deny stops a person from
// publishing over a guess; a wrong abstain leaves them exactly where they were before this existed.

/// `tally hook-artifact` - the `PreToolUse` hook on the `Artifact` tool.
///
/// NO SUPERVISOR MARKER IS REQUIRED, unlike `hook-knock` and `hook-agents`. Those speak for a
/// supervisor and have nothing to say without one; this one answers a question about the
/// environment the session is running in, which is true whether Tally launched it or the user did.
/// A session started by hand with `CLAUDE_CONFIG_DIR` exported is exactly a session that can publish
/// to the wrong account.
///
/// Every collaborator is injected with the real one as its default, so the whole table is assertable
/// without a config home, a state file or a snapshot.
func runHookArtifact(environment: [String: String] = ProcessInfo.processInfo.environment,
                     input: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
                     setting: () -> String? = { artifactAccountSetting() },
                     snapshot: () -> Snapshot? = { artifactHookSnapshot() },
                     emit: (String) -> Void = { print($0) }) -> Int32 {
    let payload = (try? JSONSerialization.jsonObject(with: input())) as? [String: Any]
    // The snapshot is read only when the decision actually needs it, and then ONCE for all three
    // questions that ask (is the chosen account still real, and what to call each of the two homes):
    // the ordinary run of this hook has nothing to say, and should cost a parse of stdin and no file
    // reads at all.
    var accounts: [Snapshot.Account]?
    func known() -> [Snapshot.Account] {
        if let accounts { return accounts }
        let read = snapshot()?.accounts ?? []
        accounts = read
        return read
    }
    guard let reason = artifactHookRefusal(
        toolName: payload?["tool_name"] as? String,
        toolInput: payload?["tool_input"] as? [String: Any],
        event: payload?["hook_event_name"] as? String,
        sessionHome: environment[providers[0].envKey],
        settingHome: setting(),
        bypass: environment[artifactAnyAccountVariable],
        settingResolves: {
            artifactSettingResolves($0, accounts: known(),
                                    exists: { FileManager.default.fileExists(atPath: $0) })
        },
        name: { artifactAccountName($0, in: known()) })
    else { return 0 }
    emit(artifactHookOutput(reason: reason))
    return 0
}

/// Why this publish may not go out, or nil to say nothing at all. The whole decision, pure.
///
/// The order is the order of the reasons, and every step before the comparison is a way of NOT
/// having an opinion:
///
///   1. another tool entirely (a matcher set wrong, a hook wired by hand onto everything),
///   2. an event that is not the one a permission decision may be given on,
///   3. an action that names an artifact which already exists, or an update carrying its `url`,
///   4. the environment saying this publish is meant to leave this account,
///   5. no account chosen in Settings, so there is nothing to compare against,
///   6. a chosen account that no longer exists, which is a setting nobody made,
///   7. the session already being on it, which is the ordinary case.
///
/// `sessionHome` absent is the DEFAULT config home (`fallbackHome`) rather than an abstention: a
/// session launched without the variable is running on `~/.claude`, and that is a fact rather than a
/// gap.
///
/// `name` turns a config home into what to call it in the sentence, injected because the labels come
/// from a file this function may not read (`artifactAccountName` is the real one).
func artifactHookRefusal(toolName: String?,
                         toolInput: [String: Any]?,
                         event: String?,
                         sessionHome: String?,
                         settingHome: String?,
                         bypass: String?,
                         fallbackHome: String = defaultHome(providers[0]),
                         settingResolves: (String) -> Bool,
                         name: (String) -> ArtifactAccountName) -> String? {
    guard toolName == artifactHookToolName else { return nil }
    // An event the payload NAMES and we do not answer on is not the same as a payload that names
    // none: the first is a witness saying this arrived somewhere else (a hand-wired registration),
    // the second is a Claude Code that sends no such field, or bytes that would not parse.
    if let event, event != artifactHookEvent { return nil }
    guard artifactActionPublishes(toolInput?["action"] as? String) else { return nil }
    let url = (toolInput?["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard url.isEmpty else { return nil }
    guard bypass?.trimmingCharacters(in: .whitespacesAndNewlines) != "1" else { return nil }
    guard let setting = artifactAccountHome(settingHome), !setting.isEmpty else { return nil }
    // A SETTING THAT NO LONGER NAMES ANYTHING IS A SETTING NOBODY MADE. The account it names can be
    // removed from under it - Tally's own Remove clears this setting with the account (the app half
    // of this defect family), but an older app with a newer CLI does not, and neither does somebody
    // trashing `~/.claude3` by hand. Left standing, a dead setting refuses EVERY publish on the
    // machine and tells the user to move to a directory that is in the Trash.
    guard settingResolves(setting) else { return nil }
    let session = artifactAccountHome(sessionHome) ?? artifactAccountHome(fallbackHome) ?? ""
    guard session != setting else { return nil }
    let here = name(session)
    let there = name(setting)
    return "Artifacts are private to the account that publishes them. This session is on "
        + "\(here.label); your Artifact publishing account is \(there.label). Run "
        + "`tally account \(artifactShellWord(there.dir))` to move this session there (takes effect "
        + "when this turn ends), or write a local .html file and open it instead. Set "
        + "\(artifactAnyAccountVariable)=1 to publish from any account."
}

/// What to call one config home in that sentence, and what to type to reach it.
///
/// BOTH, because they answer different questions and only one of them is always a name the user
/// recognises: the label is what the panel calls the account ("Main", a nickname they typed), and
/// the directory is what `tally account` will certainly match on without quoting (the matcher takes
/// either, `accountMatching`). A label with a space in it inside a command line is a command that
/// fails for a reason nobody can see.
struct ArtifactAccountName: Equatable {
    let label: String
    let dir: String
}

/// One directory as a word a shell will hand to `tally account` IN ONE PIECE.
///
/// `runSwitch` takes one argument, so a config home whose last component holds a space ("~/.claude
/// work") turned the instruction into `tally account .claude work`: two words, and following it
/// exactly gets you the usage text (codex review of 7113edc).
///
/// A CLEAN NAME STAYS BARE, which is the case every reader will actually meet: quoting `.claude2`
/// would put punctuation into the one line somebody is meant to copy, for a hazard it does not have.
/// Anything else is single-quoted, where the only character that needs saying is the single quote
/// itself: the shell has no escape inside single quotes, so the quoting is closed, the quote is
/// added literally, and the quoting is opened again.
func artifactShellWord(_ text: String) -> String {
    // An ASCII allow-list rather than a list of what is dangerous, and no wider than it needs to be:
    // a letter outside it costs a pair of quotes, while a character missing from a deny-list costs
    // the instruction. The empty string is not a word at all and is quoted into one.
    let unquoted = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
    guard text.isEmpty || !text.allSatisfy(unquoted.contains) else { return text }
    return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Whether the chosen account is still a thing on this machine.
///
/// EITHER WITNESS IS ENOUGH, and the order is the cheap one first: the published snapshot naming a
/// Claude account at that home, or the directory simply being there. The second is what keeps this
/// answering during the window where Tally is not running or its snapshot is stale, and the first is
/// what keeps it answering for a home the process cannot stat.
///
/// `exists` is injected so the rule is assertable without making directories.
func artifactSettingResolves(_ home: String, accounts: [Snapshot.Account],
                             exists: (String) -> Bool) -> Bool {
    artifactAccountMatch(home, in: accounts) != nil || exists(home)
}

/// The Claude account a config home belongs to, if the snapshot knows one. ONE matching rule, read
/// by both the naming below and the resolution above: a second spelling would let the refusal name
/// an account the staleness test had just decided was gone.
func artifactAccountMatch(_ home: String, in accounts: [Snapshot.Account]) -> Snapshot.Account? {
    let target = artifactAccountHome(home) ?? home
    return accounts.first {
        $0.provider == providers[0].id && artifactAccountHome($0.launchHome) == target
    }
}

/// The label the snapshot gives a config home, or the home itself when nothing names it.
///
/// The home comparison goes through `artifactAccountHome` on BOTH sides, so an account listed with a
/// trailing slash, through a symlinked home, or with a `~` in it still answers for the directory the
/// session is actually running in.
func artifactAccountName(_ home: String, in accounts: [Snapshot.Account]) -> ArtifactAccountName {
    let target = artifactAccountHome(home) ?? home
    let dir = URL(fileURLWithPath: target).lastPathComponent
    let match = artifactAccountMatch(target, in: accounts)
    // The home itself when the snapshot cannot name it (an account signed out since, a machine
    // where Tally has never run): a path is a worse name than a label and a far better one than
    // nothing, and it is still the thing the user has to act on. The DIRECTORY is the directory
    // either way, because that is the word `tally account` matches on and it is right even in a
    // snapshot that has not caught up with the machine yet.
    return ArtifactAccountName(label: match?.label ?? target, dir: dir)
}

/// The account the user chose to publish artifacts from, read out of the app's state file.
///
/// A READER OF ITS OWN, deliberately not folded into `launchPolicy`: this is a top-level setting
/// rather than one of a provider's launch policies, and a decoder that only knows about the one key
/// it needs cannot be broken by a `launch` block from a version this binary predates. nil for every
/// way of not having an answer (no file, bytes that will not parse, the key absent), which is the
/// abstention this whole hook is built around.
func artifactAccountSetting(_ url: URL = stateURL) -> String? {
    struct StateFile: Decodable {
        // Mirror of the app's `LaunchPolicyStore.StateFile` field of the same name; the schema only
        // ever gains keys, so a supervisor from an older build simply does not see this one.
        var artifactAccount: String?
    }
    guard let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(StateFile.self, from: data) else { return nil }
    return file.artifactAccount
}

/// The published snapshot, read WITHOUT the warnings `loadSnapshot` prints: they go to stderr, and
/// this process is a hook running inside somebody's session. Its only use here is to put a name on
/// two config homes, so a missing or stale file costs a nicer sentence and nothing else.
func artifactHookSnapshot(_ url: URL = snapshotURL) -> Snapshot? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(Snapshot.self, from: data)
}

/// The one line this subcommand ever prints: Claude Code's `PreToolUse` decision, carrying the
/// refusal and the way out of it.
///
/// BUILT BY THE SERIALIZER rather than by interpolation, because what goes in it is a sentence
/// carrying an account label the user typed: a quote or a backslash in that label would otherwise
/// end the JSON early and hand Claude Code a document it cannot parse (the same rule, and the same
/// empty-object fallback, as `quotaKnockHookOutput`).
func artifactHookOutput(reason: String) -> String {
    let document: [String: Any] = ["hookSpecificOutput": ["hookEventName": artifactHookEvent,
                                                          "permissionDecision": "deny",
                                                          "permissionDecisionReason": reason]]
    guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}
