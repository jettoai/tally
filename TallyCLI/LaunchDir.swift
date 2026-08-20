import Foundation

// The two commands that answer "which account, and with what environment" WITHOUT launching
// anything: `tally best-dir` (a person asking, output eval-able by hand) and `tally launch-dir`
// (the PATH shim asking, output eval'd by a script). Split out of main.swift for file size.
//
// Both print an environment, and that is the whole difference from `runLaunch`, which builds an
// argument vector. A shim-steered launch is a BARE `claude`: nobody passes it a flag, so anything
// this pair cannot say in the environment does not reach the session at all. That constraint is why
// `Provider.modelEnvKey` exists, and why both commands resolve through one `launchSteering`: an
// account chosen for a model is only half an answer until that model is handed over too.
//
// AND IT IS WHY THE ONE SENTENCE A LAUNCH OWES A PERSON TRAVELS THE SAME WAY. This pair makes the
// same pick `runLaunch` does, water line and drought fallback included, so it can spend a reserve
// the owner asked to be left standing - and `warn` cannot tell them, because the shim reads this
// command with its stderr redirected away. The notice is written into the script instead
// (`launchExportLines`), where the shell that evals it is the user's own.

/// The launch both commands predict: where it would run, and the one thing it owes the person
/// running it.
struct SteeredLaunch {
    /// The config home a launch under `policy` would run in.
    let home: String
    /// The reserve that pick had to spend, in the launcher's own words (`reserveDipNotice`), or nil
    /// when it spent none. A PIN CARRIES NONE by construction: naming an account is the answer, so
    /// that branch passes no reserves and has no line to cross.
    let dip: String?
}

/// The pick itself: its manual pin - in Tally or from `tally project set --account` - when that
/// resolves to a launchable account, and otherwise the same headroom pick `runLaunch` makes, this
/// project's model and the live cap quarantine included. A pin resolves regardless of headroom (the
/// user chose by hand) except when its account has signed out, which is not launchable by anyone
/// (AccountPick.swift).
///
/// Shared by `best-dir` and `launch-dir` so neither can print an export line naming an account the
/// launch itself would skip, which is a wrong answer to the only question either command asks - and
/// so neither can walk through a water line the third path says out loud that it crossed.
///
/// The readings each have an argument so the prediction is assertable without a state file, a
/// quarantine directory or a clock on the machine running the test.
func steeredLaunch(_ provider: Provider, in snapshot: Snapshot?, policy: LaunchPolicy,
                   reserves: AccountReserves = accountReserves(),
                   quarantined: Set<String>? = nil, now: Date = Date()) -> SteeredLaunch? {
    if let home = pinnedLaunchHome(snapshot, policy: policy) {
        return SteeredLaunch(home: home, dip: nil)
    }
    // Reserves included for the same reason the quarantine is: this PREDICTS the launch, and a
    // prediction that ignores an exclusion the launcher applies is simply wrong. The shim's
    // bare `claude` is the launch that most needs it - nobody typed an account there.
    guard let snapshot,
          let account = launchPick(providerID: provider.id, in: snapshot,
                                   primaryModel: policy.model,
                                   quarantined: quarantined
                                       ?? quarantinedAccounts(forPrimary: policy.model),
                                   reserves: reserves, now: now),
          let home = account.launchHome else { return nil }
    return SteeredLaunch(home: home,
                         dip: reserveDipNotice(account, primaryModel: policy.model,
                                               reserves: reserves, now: now))
}

/// The eval-able answer both shim commands print, so the shim gets the same environment either way.
///
/// `model` is the model the launch was SCORED for, and passing it is what keeps the launch from
/// contradicting that score - see `launchSteering`. Both commands pass it, for the same reason they
/// both print the config home: an environment that names the account but not the model hands over
/// half a decision, and the half it drops is the half the account was chosen for.
///
/// It is stickier in `best-dir`, whose output a person evals into their own shell, so the model
/// follows them until that shell ends. That is the tradeoff taken deliberately: the config home is
/// exactly as sticky and nobody has ever wanted it otherwise, and a model that outlives its project
/// is a smaller harm than an account picked for a model the session then does not run.
func printLaunchExports(_ provider: Provider, home: String, model: String? = nil,
                        notice: String? = nil) {
    for line in launchExportLines(provider, home: home, model: model, notice: notice) {
        print(line)
    }
}

/// `value` as one single-quoted shell word, so a line carrying it means exactly what it says.
///
/// The shim `eval`s every line of `launchExportLines` (IntegrationsStore.shimScript), which makes an
/// unquoted value shell SOURCE rather than data: a profile of `opus; touch /tmp/x` ran the `touch`
/// on the next bare `claude`, and a config home under "~/My Projects" broke in the same place for
/// the same reason. Single quotes suspend every expansion bash has; the one character they cannot
/// contain, a quote itself, is closed, escaped and reopened ('it'\''s').
///
/// Always quoted, unlike `shellQuoted` (WorktreeKill.swift), which leaves tidy paths bare because it
/// writes a line for a person to read. Here the shape of the line must not depend on the value: a
/// quoting rule with an exception is a rule someone has to re-derive at every call site.
func shellSingleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The lines themselves, as values. The shim `eval`s every line of this output
/// (IntegrationsStore.shimScript), so what this returns IS the environment a bare launch runs in,
/// and it is worth being able to assert on without capturing stdout.
///
/// `notice` is the one line that is not environment at all, and being a LINE OF THE SCRIPT is the
/// whole of why it reaches anybody. The shim asks this command inside a command substitution with
/// `2> /dev/null` (IntegrationsStore.shimScript), which it has to: `launch-dir` also warns about a
/// stale snapshot, and a bare `claude` is no place for that. So the sentence a launch owes the owner
/// of a reserve it just spent - the sentence `runLaunch` writes with `warn` - would be thrown away
/// on the one path that most needs it, the launch nobody typed an account on. Printed by the user's
/// own shell instead, onto the user's own stderr, carrying the prefix every other line of ours has.
func launchExportLines(_ provider: Provider, home: String, model: String? = nil,
                       notice: String? = nil) -> [String] {
    // Single-quoted for the same reason every value here is: the account label in that sentence is
    // text somebody typed, and this line is source the shell is about to run.
    var lines = notice.map { ["printf '%s\\n' \(shellSingleQuoted(warnPrefix + $0)) >&2"] } ?? []
    // Mirror launchEnv: the default home must UNSET the variable (explicitly setting the default
    // path makes Claude Code look up a hashed Keychain item that doesn't exist). Both lines eval.
    lines.append(launchEnv(provider, home: home) == nil
        ? "unset \(provider.envKey)"
        : "export \(provider.envKey)=\(shellSingleQuoted(home))")
    // The status line reads this to show "this session runs under Tally" (✦). A shim-steered bare
    // launch has no resident supervisor, so mark it unsupervised (the status line stays quiet
    // rather than nagging "supervisor unknown").
    lines.append("export TALLY_LAUNCHED=1")
    lines.append("export TALLY_SUPERVISED=0")
    // A provider with no model variable gets no line, which is the same thing as not steering by
    // model at all - and `launchSteering` has already stopped scoring it that way.
    if let model, let key = provider.modelEnvKey {
        lines.append("export \(key)=\(shellSingleQuoted(model))")
    }
    return lines
}

func runBestDir(_ providerID: String) {
    guard let provider = providers.first(where: { $0.id == providerID }) else {
        warn("unknown provider `\(providerID)` - use claude or codex")
        exit(2)
    }
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }
    let (policy, model) = launchSteering(provider, appPolicy: launchPolicy(provider.id),
                                        project: projectPolicy(provider.id))
    guard let steered = steeredLaunch(provider, in: snapshot, policy: policy) else {
        warn("no eligible \(providerID) account")
        exit(1)
    }
    printLaunchExports(provider, home: steered.home, model: model, notice: steered.dip)
}

/// What a launch may be steered BY: the app's policy with this project's profile laid over it, and
/// the model to hand over alongside the account that profile just chose. Shared by both commands.
///
/// The pair is the point. A project declaring opus made `launch-dir` score accounts for opus, while
/// the shim went on to run a bare `claude` that took its model from its own settings - so the
/// session was placed on an account chosen because its Fable window was spent, and then asked for
/// Fable. The account pick's own promise ("this account can serve what you are about to run") was
/// being broken by the one launch path that had no way to pass a flag.
///
/// So the model is only allowed to steer when it can also be DELIVERED, which is what
/// `Provider.modelEnvKey` answers. For codex, which has no such variable, the project's model is
/// dropped from the scoring here rather than acted on: an unsteered pick is merely unoptimised,
/// while a steered one that cannot deliver is wrong. Everything else in the profile still applies
/// to codex, including the account pin, which needs no handover at all.
///
/// The profile's EFFORT is not handed over either, for a plainer reason: no environment variable for
/// it has been verified the way the model's was. Unlike the model it does not steer the account
/// pick, so a bare launch simply runs the CLI's own depth - a missing optimisation, not a
/// contradiction. `tally claude` (which passes flags) applies it as always.
func launchSteering(_ provider: Provider, appPolicy: LaunchPolicy,
                   project: ProjectPolicy) -> (policy: LaunchPolicy, model: String?) {
    var declared = project
    if provider.modelEnvKey == nil { declared.model = nil }
    let policy = effectivePolicy(appPolicy, project: declared)
    // Only a model this project ASKED for is exported. The app's own default already reaches a bare
    // launch through the CLI's settings, and re-stating it in the environment would override a
    // per-directory setting the user made in Claude Code itself, which Tally has no business doing.
    return (policy, declared.model)
}

/// `tally launch-dir` - the machine interface for the codex/claude PATH shims. Unlike `best-dir`
/// (an explicit "which is best" question), this answers "should a BARE invocation be steered, and
/// where": mode off prints nothing (the shim passes through untouched), manual prints the pin,
/// auto prints the headroom pick. Output is eval-able (`export …` / `unset …`) or empty.
func runLaunchDir(_ providerID: String) {
    guard let provider = providers.first(where: { $0.id == providerID }) else {
        warn("unknown provider `\(providerID)` - use claude or codex")
        exit(2)
    }
    // The "off" gate is asked of the APP's policy, before the project overlay: off is about whether
    // Tally may steer a launch it was not asked into at all, which is a question about the shim and
    // not about what any one project runs.
    let appPolicy = launchPolicy(provider.id)
    guard appPolicy.mode != "off" else { return }
    let (policy, model) = launchSteering(provider, appPolicy: appPolicy,
                                        project: projectPolicy(provider.id))
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }
    // Nothing eligible - stay silent, the shim runs the bare CLI.
    guard let steered = steeredLaunch(provider, in: snapshot, policy: policy) else { return }
    printLaunchExports(provider, home: steered.home, model: model, notice: steered.dip)
}
