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
    var loaded = false
    var document: Snapshot?
    func published() -> Snapshot? {
        if !loaded { document = snapshot(); loaded = true }
        return document
    }
    guard let reason = artifactHookRefusal(
        toolName: payload?["tool_name"] as? String,
        toolInput: payload?["tool_input"] as? [String: Any],
        event: payload?["hook_event_name"] as? String,
        sessionHome: environment[providers[0].envKey],
        settingHome: setting(),
        bypass: environment[artifactAnyAccountVariable],
        standing: {
            artifactAccountStanding($0, snapshot: published(),
                                    exists: { FileManager.default.fileExists(atPath: $0) })
        },
        // NAMED OUT OF THE WHOLE FILE, fresh or not, unlike the standing above: a label does not go
        // stale the way an account's existence does, and an old snapshot is still the only thing
        // that can say "Claude 2" rather than a path.
        name: { artifactAccountName($0, in: published()?.accounts ?? []) })
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
///   6. a chosen account that no longer exists, which is a setting nobody made (a signed-out one is
///      still refused, with a different way out),
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
                         standing: (String) -> ArtifactAccountStanding,
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
    let chosen = standing(setting)
    guard chosen != .gone else { return nil }
    let session = artifactAccountHome(sessionHome) ?? artifactAccountHome(fallbackHome) ?? ""
    guard session != setting else { return nil }
    let here = name(session)
    let there = name(setting)
    // THE WAY OUT HAS TO BE ONE THAT WORKS. `tally account` resolves a name against the accounts it
    // could launch, so offering it for a signed-out account is an instruction that fails for a
    // reason the message never mentions, with the thing that would actually fix it (signing in
    // there) unsaid. The rest of the sentence is the same either way.
    // The command is offered only when there is one to offer, and the rest of the sentence stands
    // without it: a provider this app cannot log in still has Renew login named, the picker named,
    // and the two ways out that need no account at all.
    let renew = artifactRenewLoginCommand(home: setting).map { ", or run `\($0)`" } ?? ""
    let route = chosen == .signedOut
        ? "\(there.label) is signed out; use Renew login on its card in Tally\(renew), or pick "
            + "another account in Tally \u{2192} Settings \u{2192} Integrations, or write a local "
            + ".html file and open it instead."
        : "Run `tally account \(artifactShellWord(there.dir))` to move this session there (takes "
            + "effect when this turn ends), or write a local .html file and open it instead."
    return "Artifacts are private to the account that publishes them. This session is on "
        + "\(here.label); your Artifact publishing account is \(there.label). \(route) Set "
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

/// The command that signs one config home back in, assembled by the app's OWN Renew login rather
/// than written out here.
///
/// TWO THINGS THIS BORROWS, and both of them have been got wrong before. The arguments carry
/// `--strict-mcp-config` BEFORE the subcommand, because Commander rejects a parent option written
/// after one, and the wrong order shipped once (RenewLoginCommand states how it passed review). And
/// the DEFAULT home is spelled by UNSETTING the variable rather than by naming the path: Claude Code
/// namespaces its Keychain item by the exact variable string, so `CLAUDE_CONFIG_DIR=~/.claude claude
/// auth login` signs in somewhere the account is not, and the user would be sent round the loop
/// again. `env` is the prefix for both cases, which is what the app's own visible-Terminal fallback
/// shows a user, so the two surfaces teach one command.
///
/// The command comes back already quoted for a shell, field by field (`RenewLoginCommand.
/// shellQuoted`), so a config home with a space in it survives being copied. It is deliberately not
/// put through `artifactShellWord` afterwards: this is a command line, not one word in one, and
/// quoting it again would quote the quoting.
///
/// nil for a provider the app cannot log in at all, which leaves the sentence naming Renew login and
/// the other ways out.
func artifactRenewLoginCommand(
    home: String,
    executable: String = resolveProviderExecutable(providers[0].cli),
    defaultHome: String = RenewLoginCommand.defaultHome(providerID: providers[0].id)
) -> String? {
    let provider = providers[0]
    guard let plan = RenewLoginCommand.plan(providerID: provider.id) else { return nil }
    // BOTH SIDES THROUGH THE SAME NORMALIZATION. `home` arrives already resolved (the guard compares
    // config homes by `artifactAccountHome`, symlinks and all), so comparing it against the literal
    // `~/.claude` answers "not the default home" on every machine whose default home is a link -
    // and this is the one comparison where being wrong is silent: the command would then NAME the
    // resolved path, Claude Code would key its Keychain item on that exact string, and the user
    // would log in to a namespace their session never reads.
    let isDefault = artifactAccountHome(home) == artifactAccountHome(defaultHome)
    // THE REAL BINARY, NEVER THE BARE NAME. `claude` on a machine with Tally's PATH shim installed is
    // `~/.tally/bin/claude`, which asks `tally launch-dir` which account a bare invocation should
    // land on: with the variable unset (the default-home branch, and exactly the branch that must
    // reach the default account) the shim reads a fresh launch and picks by policy, so the user
    // follows our instruction and signs in to whichever account had headroom. `resolveProviderExecutable`
    // walks PATH the way the system would and passes over that directory; it is the same defence the
    // supervisor's own respawn carries, and for the same failure.
    return RenewLoginCommand.shellCommand(executable: executable, envKey: provider.envKey,
                                          home: isDefault ? nil : home, arguments: plan.arguments)
}

/// What this machine can say about the account artifacts are published from. Three answers, because
/// the guard owes a different sentence to each of them.
enum ArtifactAccountStanding: Equatable {
    /// Nothing vouches for that home any more. The guard says nothing at all: a setting naming a
    /// directory that has gone would otherwise refuse every publish on the machine.
    case gone
    /// A session can be moved there, which is what the refusal offers.
    case live
    /// The home is there and the account is signed out, so `tally account` will refuse it
    /// (`accountMatching` drops an account with no launch home). Still a refusal, because signing
    /// out of a config home does not change which account the browser is signed into: publishing
    /// from anywhere else still makes a link the user cannot open. What changes is the way out.
    case signedOut
}

/// Which account the chosen home belongs to, and whether a session can be moved to it.
///
/// TWO WITNESSES, AND ONE OF THEM IS ON A CLOCK. The published snapshot can name the account, and
/// the directory can simply be there; the first is the only one that can tell a signed-out account
/// from a live one, and the second is the only one that can tell a REMOVED account from either.
///
/// The snapshot is only evidence while it is fresh, on the file's own rule (`snapshotMaxAge`, the
/// same age `loadSnapshot` warns about). Without that clock the vote runs the wrong way: somebody
/// trashing `~/.claude3` while Tally is not running leaves a snapshot that names the account for
/// ever, and the guard the app cannot correct (the setting is cleared by the app's own Remove, and
/// this is the defence for every other way a home leaves) would refuse every publish on the machine
/// and name a folder in the Trash as the way out. Measured on this very code by the reviewing model,
/// which built a probe for it: snapshot from 1970, home deleted, refusal printed.
///
/// A DORMANT RECORD STILL HAS TO SURVIVE THE DISK TEST for the same reason: "signed out" means the
/// home is still there, so a dormant account whose directory has gone is a record describing a
/// machine that has moved on.
///
/// `exists` is injected so the rule is assertable without making or removing directories.
func artifactAccountStanding(_ home: String, snapshot: Snapshot?, now: Date = Date(),
                             exists: (String) -> Bool) -> ArtifactAccountStanding {
    guard let account = artifactAccountMatch(home, in: artifactVouchingAccounts(snapshot, now: now))
    else { return exists(home) ? .live : .gone }
    guard account.launchHome == nil else { return .live }
    return exists(home) ? .signedOut : .gone
}

/// The accounts a snapshot may vouch for: none at all once it is older than the age this repo
/// already treats as "is Tally even running?".
func artifactVouchingAccounts(_ snapshot: Snapshot?, now: Date) -> [Snapshot.Account] {
    guard let snapshot, now.timeIntervalSince(snapshot.generatedAt) <= snapshotMaxAge else {
        return []
    }
    return snapshot.accounts
}

/// The Claude account a config home belongs to, if the snapshot knows one. ONE matching rule, read
/// by both the naming below and the standing above: a second spelling would let the refusal name an
/// account the standing had just decided was gone.
///
/// TWO WAYS TO BE THAT ACCOUNT, because a SIGNED-OUT one publishes no launch home at all
/// (`ProviderAccount.launchableHome`, and the snapshot carries only the launchable one): matched by
/// the home it launches on, or by the id, which the app derives from this very directory's name.
/// `accountConfigHome` is the one place that derivation is written down, guards included, and
/// without this second reading a dormant account is invisible here - which is exactly the account
/// whose refusal has to say something different.
func artifactAccountMatch(_ home: String, in accounts: [Snapshot.Account]) -> Snapshot.Account? {
    let target = artifactAccountHome(home) ?? home
    return accounts.first { account in
        guard account.provider == providers[0].id else { return false }
        if artifactAccountHome(account.launchHome) == target { return true }
        return account.launchHome == nil
            && artifactAccountHome(accountConfigHome(account.id, provider: providers[0])) == target
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
/// this process is a hook running inside somebody's session.
///
/// WHAT IS NOT SKIPPED WITH THEM is the age those warnings are about. This file used to say the
/// snapshot was only ever used to put a name on two config homes, so a stale one cost a nicer
/// sentence and nothing else; that stopped being true the moment it began deciding whether the
/// chosen account still exists, and the sentence stayed behind to tell the next reader not to look
/// (which is how the defect survived a review). The clock is applied where the evidence is weighed,
/// in `artifactVouchingAccounts`, so naming can go on using a file too old to vouch for anything.
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
