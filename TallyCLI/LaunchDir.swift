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

/// The config home a launch under `policy` would run in: its manual pin - in Tally or from
/// `tally project set --account` - when that resolves to a launchable account, and otherwise the
/// same headroom pick `runLaunch` makes, this project's model and the live cap quarantine included.
/// A pin resolves regardless of headroom (the user chose by hand) except when its account has
/// signed out, which is not launchable by anyone (AccountPick.swift).
///
/// Shared by `best-dir` and `launch-dir` so neither can print an export line naming an account the
/// launch itself would skip, which is a wrong answer to the only question either command asks.
func steeredLaunchHome(_ provider: Provider, in snapshot: Snapshot?,
                       policy: LaunchPolicy) -> String? {
    pinnedLaunchHome(snapshot, policy: policy)
        ?? snapshot.flatMap {
            launchPick(providerID: provider.id, in: $0, primaryModel: policy.model,
                       quarantined: quarantinedAccounts(forPrimary: policy.model))?.launchHome
        }
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
func printLaunchExports(_ provider: Provider, home: String, model: String? = nil) {
    for line in launchExportLines(provider, home: home, model: model) { print(line) }
}

/// The lines themselves, as values. The shim `eval`s every line of this output
/// (IntegrationsStore.shimScript), so what this returns IS the environment a bare launch runs in,
/// and it is worth being able to assert on without capturing stdout.
func launchExportLines(_ provider: Provider, home: String, model: String? = nil) -> [String] {
    // Mirror launchEnv: the default home must UNSET the variable (explicitly setting the default
    // path makes Claude Code look up a hashed Keychain item that doesn't exist). Both lines eval.
    var lines = [launchEnv(provider, home: home) == nil
        ? "unset \(provider.envKey)"
        : "export \(provider.envKey)=\(home)"]
    // The status line reads this to show "this session runs under Tally" (✦). A shim-steered bare
    // launch has no resident supervisor, so mark it unsupervised (the status line stays quiet
    // rather than nagging "supervisor unknown").
    lines.append("export TALLY_LAUNCHED=1")
    lines.append("export TALLY_SUPERVISED=0")
    // A provider with no model variable gets no line, which is the same thing as not steering by
    // model at all - and `launchSteering` has already stopped scoring it that way.
    if let model, let key = provider.modelEnvKey { lines.append("export \(key)=\(model)") }
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
    guard let home = steeredLaunchHome(provider, in: snapshot, policy: policy) else {
        warn("no eligible \(providerID) account")
        exit(1)
    }
    printLaunchExports(provider, home: home, model: model)
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
    guard let home = steeredLaunchHome(provider, in: snapshot, policy: policy) else { return }
    printLaunchExports(provider, home: home, model: model)
}
