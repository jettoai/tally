import Foundation

// THE ONE PLACE A LAUNCH IS DECIDED. `runLaunch` (main.swift) and the PATH shim's pair
// (`steeredLaunch` / `steeredRefusal`, LaunchDir.swift) used to each carry their own copy of the
// branches below, and every fix to one of them had to be found again in the others (B-1706, five
// rounds; B-1736). They now read their inputs, hand them to `resolveLaunch`, and only carry out the
// answer.
//
// Pure: no I/O, no getenv, no warn. What a launch was asked for comes in as a `LaunchIntent` (its
// own argv, environment and terminal), what it is decided against as `LaunchReadings` (snapshot,
// policy, reserves, quarantine, clock), and every line it owes the person comes back as text in
// `LaunchDecision.notices`, in the order the launcher prints them.

// MARK: - What the launch's own flags and environment say

/// Whether auto-handoff is on for this launch (opt out with `--no-handoff` or TALLY_AUTO_HANDOFF=0).
func autoHandoffEnabled(args: [String],
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    if optionsOnly(args).contains("--no-handoff") { return false }
    return environment["TALLY_AUTO_HANDOFF"] != "0"
}

/// Whether a running session adopts a later change to the launch-default model (Settings). Mirrors
/// the `--no-handoff` opt-out. A hand-typed `--model` is handled separately at the call site (a
/// deliberate model choice must never be overridden), so this only covers the explicit escape hatch.
func autoFollowEnabled(args: [String],
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    if optionsOnly(args).contains("--no-follow") { return false }
    return environment["TALLY_AUTO_FOLLOW"] != "0"
}

/// The two halves of `sessionFlags` (Snapshot.swift), partitioned rather than listed again so a flag
/// added there lands in one of them instead of being silently uncovered (`resumeFlags`,
/// LaunchFlags.swift).
let printFlags: Set<String> = ["--print", "-p"]

/// Whether a launch gets a resident supervisor at all, or is left to `exec` on its own.
///
/// Supervision earns its keep by outliving a conversation: it moves the session between accounts,
/// adopts Settings changes, restarts on request. Every one of those does the same physical thing -
/// kill the child, start it again - which a CONVERSATION survives (it is resumed by id) and a
/// one-shot run does not. Re-running `claude -p "ship it"` on another account does not continue
/// anything; it does the work a second time, tool calls, writes and all.
///
/// The mover paths each learned that separately and one at a time (`carryableSession` is the scar),
/// which is the tell that the question was being asked in the wrong place. A one-shot run does not
/// need a cheaper handoff, it needs no supervisor, and refusing it here retires the question for
/// every path at once - including the ones that never asked it: the cap handoff, the degradation
/// rescue and the follow adoption all restart the child too.
///
/// `stdoutIsTTY` is not a detail. `--print` is the explicit spelling, but claude also enters print
/// mode implicitly when its stdout is not a terminal, so `tally claude 'summarise this' | tee out`
/// is a one-shot run carrying no flag that says so. Reading the terminal is how the CLI itself
/// decides, so it is how this decides.
func shouldSupervise(args: [String], stdoutIsTTY: Bool,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    guard autoHandoffEnabled(args: args, environment: environment) else { return false }
    return stdoutIsTTY && !optionsOnly(args).contains(where: { printFlags.contains($0) })
}

/// Whether a Codex launch gets the monitor (CodexSupervisor.swift): an interactive session, not a
/// piped run, a help or version query, or a subcommand other than `resume`.
func shouldMonitorCodex(args: [String], stdoutIsTTY: Bool,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    guard stdoutIsTTY, autoHandoffEnabled(args: args, environment: environment) else { return false }
    let options = optionsOnly(args)
    guard !options.contains(where: { ["--help", "-h", "--version", "-V"].contains($0) }) else { return false }
    let command = codexSubcommand(options)
    return command == nil || command == "resume"
}

/// `--account <name>` taken out of `args`: the manual override, matched against the label or the
/// config-dir name (`accountMatching`). Taken before anything else reads the args, the worktree flag
/// included, so its value can never be read as anything else.
func takeAccountFlag(_ args: inout [String]) -> String? {
    guard let index = args.firstIndex(of: "--account"), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index ... index + 1)
    return value
}

/// Which launch-default axes a running session still follows (#14). A typed `--model` holds the model
/// axis and leaves the effort axis following the default, and the other way round: a deliberate
/// choice outranks the default for ITS axis only.
///
/// A boolean literal speaks for the pair (`true` is `.both`, `false` is `.none`), so a caller that
/// only knows "follows" or "does not" reads as it always did. That also means a production
/// `following: true` silently means BOTH axes: where one axis is held, build the value from the
/// launch (`launchIntent`), never from a literal.
struct FollowAxes: Equatable {
    var model: Bool
    var effort: Bool

    static let both = FollowAxes(model: true, effort: true)
    static let none = FollowAxes(model: false, effort: false)

    var any: Bool { model || effort }

    /// `.none` unless `allowed`: the per-tick stand-down (a live model pin, a session pair).
    func gated(by allowed: Bool) -> FollowAxes { allowed ? self : .none }
}

// In an extension so the memberwise `init(model:effort:)` stays synthesized.
extension FollowAxes: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self.init(model: value, effort: value)
    }
}

/// What a launch was asked for, read off its own command line, environment and terminal.
struct LaunchIntent: Equatable {
    /// `--account <v>`, already taken out of the args (`takeAccountFlag`).
    var accountFlag: String?
    /// `--spend-reserve` (B-1213).
    var spendReserve: Bool
    /// Neither `--no-handoff` nor TALLY_AUTO_HANDOFF=0.
    var autoHandoff: Bool
    /// A run the CLI does once and exits: claude printing (a print flag, or stdout on a pipe), codex
    /// piped, asked for help or a version, or a subcommand other than a session.
    var oneShot: Bool
    /// One-shot ONLY because stdout is a pipe, the one reason nobody typed: the launcher says so.
    var pipedOnly: Bool
    /// The axes of the running session that follow a later Settings change: none under `--no-follow`,
    /// and a typed `--model` or `--effort` holds only its own axis.
    var follow: FollowAxes
    /// The config home exported by hand, or nil (none, or an inherited leak).
    var exportedHome: String?
    /// Claude Code's child marker in a launch somebody typed (`inheritedSessionEnvironment`).
    var inheritedLeak: Bool
    /// A leak that actually carried a config home, the one that is worth a sentence.
    var leakedHome: Bool
    /// The same marker on a pipe: a real child session, which follows its parent's home.
    var realChild: Bool
    /// The args with Tally's own flags taken out (`--no-handoff`, `--spend-reserve`, `--no-follow`).
    /// `--new` stays: the caller reads it as the start mode.
    var passthrough: [String]

    /// The PATH shim's launch: nothing typed, nothing exported that it asks about here
    /// (`runLaunchReserve` asks about an exported home on its own), and no supervisor.
    static let shim = LaunchIntent(accountFlag: nil, spendReserve: false, autoHandoff: true,
                                   oneShot: true, pipedOnly: false, follow: false,
                                   exportedHome: nil, inheritedLeak: false, leakedHome: false,
                                   realChild: false, passthrough: [])
}

/// `args` are what remains after `--account` and the worktree flag were taken out by the caller.
func launchIntent(_ provider: Provider, args: [String], accountFlag: String?, stdoutIsTTY: Bool,
                  environment: [String: String] = ProcessInfo.processInfo.environment) -> LaunchIntent {
    let options = optionsOnly(args)
    let autoHandoff = autoHandoffEnabled(args: args, environment: environment)
    let printing = options.contains(where: { printFlags.contains($0) })
    // A one-shot run is deliberately left unsupervised: every supervisor action restarts the child,
    // which RE-RUNS a command. Read before Tally's own flags are stripped.
    let supervisable = provider.id == "codex"
        ? shouldMonitorCodex(args: args, stdoutIsTTY: true, environment: environment)
        : shouldSupervise(args: args, stdoutIsTTY: true, environment: environment)
    let oneShot = !stdoutIsTTY || (autoHandoff && !supervisable) || (provider.id == "claude" && printing)
    // Tally's own flags, never passed through - and never taken out of the PROMPT, where the same
    // word belongs to the user (Snapshot.swift: `removingOption`).
    var passthrough = removingOption(args, "--no-handoff")
    let spendReserve = optionsOnly(passthrough).contains(spendReserveFlag)
    passthrough = removingOption(passthrough, spendReserveFlag)
    // A running session follows a later Settings change to the default model/effort UNLESS the user
    // opted out (--no-follow), and a typed --model or --effort opts out ITS axis only (#14): a
    // deliberate choice outranks the default, but the axis nobody typed keeps following it. That
    // includes a lone typed --effort, so the untyped model follows the default then (the twin of a
    // lone typed --model leaving the effort to follow). A project profile does not opt the session
    // out (B-1091): the supervisor follows the EFFECTIVE pair.
    let allowed = autoFollowEnabled(args: passthrough, environment: environment)
    let typedFlags = optionsOnly(passthrough)
    let follow = FollowAxes(model: allowed && !typedFlags.contains("--model"),
                            effort: allowed && !typedFlags.contains("--effort"))
    passthrough = removingOption(passthrough, "--no-follow")
    let leak = inheritedSessionEnvironment(providerID: provider.id, stdoutIsTTY: stdoutIsTTY,
                                           environment: environment)
    let exported = environment[provider.envKey]
    return LaunchIntent(
        accountFlag: accountFlag, spendReserve: spendReserve, autoHandoff: autoHandoff,
        oneShot: oneShot, pipedOnly: !stdoutIsTTY && autoHandoff && !printing, follow: follow,
        exportedHome: leak ? nil : exported, inheritedLeak: leak,
        leakedHome: leak && exported != nil,
        realChild: !leak && environment[childSessionMarker] != nil, passthrough: passthrough)
}

// MARK: - What the launch is decided against

/// Everything a launch is decided AGAINST, read by the caller (the I/O lives there).
struct LaunchReadings {
    var snapshot: Snapshot?
    /// Effective: the app's policy with this project's profile laid over it.
    var policy: LaunchPolicy
    /// How the pin is named in what the launch says ("pinned for this project", "pinned in Tally",
    /// "pinned" for the shim).
    var pinnedBy: String
    /// The model the accounts are scored for.
    var primaryModel: String?
    var reserves: AccountReserves
    var quarantined: Set<String>
    /// Whether an automatic pick may take a clearance account for a new conversation
    /// (`settleLaunch`). The launcher can tell; the shim cannot.
    var clearance: Bool
    var now: Date
    /// The account set for Claude in Chrome when this project prefers it (`launchChromeAccount`),
    /// else nil. Only the headroom pick reads it.
    var chromeAccount: String? = nil
}

struct LaunchDecision: Equatable {
    /// Which rule settled the account.
    enum Route: Equatable { case exportedHome, accountFlag, pin, pinHome, pick, bare }
    enum Supervision: Equatable { case handoff, monitor, none(Unsupervised) }
    /// THE ONE PLACE a launch is said not to be supervised, and why.
    enum Unsupervised: Equatable {
        /// A print run, a piped stdout, a Codex help/version or non-session subcommand.
        case oneShot
        /// `--no-handoff` or TALLY_AUTO_HANDOFF=0.
        case optedOut
        /// Claude on `--account` or an exported home: nowhere else to move a capped session to.
        case handPinned
        /// Claude on a home the snapshot has no row for (a pin missing from it, a bare launch).
        case noAccountRow
    }
    /// The environment the child gets: this process's own (`env: nil`), or one set for the home.
    enum ChildEnv: Equatable { case inherit, forHome }
    enum Refusal: Equatable {
        case noMatch(String), ambiguous(String)
        /// `namedReserveRefusal`'s text, before any surface adds its own tail.
        case named(String)
        case hold(String)
    }

    var route: Route
    /// The account the launch lands on, a synthesized row for a home with none
    /// (`offSnapshotAccount`). nil only when refused.
    var account: Snapshot.Account?
    /// `.pick` only: what a new conversation would take instead (`launchPick(emptyConversation:)`).
    var clearanceAccount: Snapshot.Account?
    var supervision: Supervision
    var childEnv: ChildEnv
    var refusal: Refusal?
    /// The pin row a launch stepped aside from (B-1540).
    var stepAside: Snapshot.Account?
    /// Every line said before the launch, in order (for `.pick`, the dip and the arrow come after the
    /// start mode settles the landing account, so they are the caller's).
    var notices: [String]
    /// Variables an inherited environment leaves behind, dropped before any exec.
    var envToUnset: [String]
    var spendReserve: Bool
    var follow: FollowAxes
}

/// A config home with no snapshot row, as an account a launch can carry: the row's own id when the
/// home is one the snapshot lists, else `id`, else `<provider>:<directory name>`.
func offSnapshotAccount(_ provider: Provider, home: String, id: String?,
                        in snapshot: Snapshot? = nil) -> Snapshot.Account {
    let key = normalizedConfigHome(home)
    let listed = key == nil ? nil : snapshot?.accounts.first(where: {
        $0.provider == provider.id && normalizedConfigHome($0.launchHome) == key
    })
    let name = URL(fileURLWithPath: home).lastPathComponent
    return Snapshot.Account(
        id: listed?.id ?? id ?? "\(provider.id):\(name)", provider: provider.id,
        label: listed?.label ?? name, launchHome: home, sessionRemaining: nil,
        weeklyRemaining: nil, modelRemaining: nil, sessionResetsAt: nil, weeklyResetsAt: nil,
        modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
        error: nil)
}

/// The whole decision, in the order the launcher has always taken it.
func resolveLaunch(_ provider: Provider, intent: LaunchIntent,
                   readings r: LaunchReadings) -> LaunchDecision {
    let model = r.primaryModel
    let spend = intent.spendReserve
    var notices: [String] = []
    // An environment inherited from another session is not a hand pin: its home is ignored, and
    // both it and the marker that gave it away are dropped before any exec (main.swift says why).
    if intent.leakedHome {
        notices.append("\(provider.envKey) was inherited from another session rather than exported "
            + "by you - ignoring it and choosing the account normally")
    }
    let envToUnset = intent.inheritedLeak ? [provider.envKey, childSessionMarker] : []

    func decided(_ route: LaunchDecision.Route, _ account: Snapshot.Account?,
                 env: LaunchDecision.ChildEnv = .forHome, refusal: LaunchDecision.Refusal? = nil,
                 clearance: Snapshot.Account? = nil,
                 stepAside: Snapshot.Account? = nil) -> LaunchDecision {
        LaunchDecision(route: route, account: refusal == nil ? account : nil,
                       clearanceAccount: clearance,
                       supervision: supervision(provider, intent: intent, route: route),
                       childEnv: env, refusal: refusal, stepAside: stepAside, notices: notices,
                       envToUnset: envToUnset, spendReserve: spend, follow: intent.follow)
    }
    func bare() -> LaunchDecision {
        notices.append("no eligible \(provider.id) account - launching bare `\(provider.cli)`")
        return decided(.bare, offSnapshotAccount(provider, home: defaultHome(provider), id: nil,
                                                 in: r.snapshot), env: .inherit)
    }

    // 1. An exported config home: the user choosing the ACCOUNT by hand. `--account` outranks it
    // (that flag names an account, this variable names a directory). A marker still set is a REAL
    // child following its parent's home: not a choice, so never refused.
    if intent.accountFlag == nil, let home = intent.exportedHome {
        if !spend, !intent.realChild, let refusal = exportedHomeRefusal(home,
            providerID: provider.id, in: r.snapshot, primaryModel: model, reserves: r.reserves,
            now: r.now) {
            return decided(.exportedHome, nil, refusal: .named(refusal))
        }
        notices.append("\(provider.envKey) already set - keeping that account, launch defaults still apply")
        return decided(.exportedHome, offSnapshotAccount(provider, home: home, id: nil, in: r.snapshot),
                       env: .inherit)
    }
    // 2. `--account`.
    if let name = intent.accountFlag {
        switch accountMatching(name, provider: provider.id, in: r.snapshot) {
        case .none:
            return decided(.accountFlag, nil,
                           refusal: .noMatch("no \(provider.id) account matches \"\(name)\" - try `tally status`"))
        case .several(let candidates):
            // Refused rather than picked: `--account` means "not the one you would have chosen".
            return decided(.accountFlag, nil, refusal: .ambiguous(
                accountMatchAmbiguity(name, provider: provider.id, candidates: candidates)))
        case .one(let match):
            if !spend, let refusal = namedReserveRefusal(match, primaryModel: model,
                                                         reserves: r.reserves, now: r.now) {
                return decided(.accountFlag, nil, refusal: .named(refusal))
            }
            notices.append("→ \(match.label) (pinned)")
            return decided(.accountFlag, match)
        }
    }
    // 3. The manual pin (Settings, or `tally project set --account`). A pin over an account out of
    // quota steps aside to the smart pick when another account can take the launch (B-1540).
    var aside: Snapshot.Account?
    if r.policy.mode == "manual" {
        aside = pinStepAsideRow(r.snapshot, policy: r.policy, primaryModel: model,
                                quarantined: r.quarantined, reserves: r.reserves,
                                spendReserve: spend, now: r.now)
        if let row = aside {
            notices.append(pinStepAsideNotice(row, pinnedBy: r.pinnedBy))
        } else {
            let row = r.snapshot?.accounts.first(where: {
                $0.id == r.policy.pinnedAccountID && $0.launchHome != nil
            })
            // Not under the owner's line: that launch is about to be refused, and "launching anyway"
            // first would contradict it.
            if let row, pinnedOutOfQuota(row, primaryModel: model),
               spend || aboveReserve(row, primaryModel: model, reserves: r.reserves, now: r.now) {
                notices.append("\(row.label) is out of quota and no other account can take this "
                    + "launch - launching it anyway (\(r.pinnedBy))")
            }
            if let match = row {
                if !spend, let refusal = namedReserveRefusal(match, primaryModel: model,
                                                             reserves: r.reserves, now: r.now) {
                    return decided(.pin, nil, refusal: .named(refusal))
                }
                notices.append("→ \(match.label) (\(r.pinnedBy))")
                return decided(.pin, match)
            }
            // The denormalized home, for a pin whose account is missing from this snapshot. NOT
            // for one the snapshot lists WITHOUT a launch home: that login is gone.
            if let home = pinnedLaunchHome(r.snapshot, policy: r.policy) {
                notices.append("→ pinned account (set in Tally)")
                return decided(.pinHome, offSnapshotAccount(provider, home: home,
                                                            id: r.policy.pinnedAccountID))
            }
            notices.append(pinnedAccountIsSignedOut(r.snapshot, policy: r.policy)
                ? "pinned account is signed out - renew its login in Tally; picking by headroom instead"
                : "pinned account not found - picking by headroom instead")
        }
    }
    // 4. No snapshot: the bare CLI.
    guard let snapshot = r.snapshot else { return bare() }
    // 5. The headroom pick. A field the reserves emptied is a refusal; only `--spend-reserve` ranks
    // it again without them.
    func pick(_ empty: Bool) -> Snapshot.Account? {
        let pick = { launchPick(providerID: provider.id, in: snapshot,
                                primaryModel: model, quarantined: r.quarantined,
                                reserves: $0, emptyConversation: empty, now: r.now) }
        return pick(r.reserves) ?? (spend ? pick(.none) : nil)
    }
    guard let ranked = pick(false) else {
        if let hold = reserveHoldout(providerID: provider.id, in: snapshot, primaryModel: model,
                                     reserves: r.reserves, now: r.now) {
            return decided(.pick, nil,
                           refusal: .hold(reserveHoldNotice(hold, providerID: provider.id, now: r.now)))
        }
        return bare()
    }
    if let row = chromeLaunchRow(r.chromeAccount, providerID: provider.id, in: snapshot,
                                 primaryModel: model, quarantined: r.quarantined,
                                 reserves: r.reserves, now: r.now) {
        notices.append(chromeLaunchNotice(row))
        // No clearance lane: the point of this launch is the account Chrome is signed in to.
        return decided(.pick, row, stepAside: aside)
    }
    return decided(.pick, ranked, clearance: r.clearance ? pick(true) : nil, stepAside: aside)
}

/// The row a launch takes because this project prefers the account set for Claude in Chrome, or
/// nil to keep the headroom pick. Every gate the automatic pick applies still holds: the account has
/// to be in the pick's field (eligible for the model, not quarantined), above its owner's reserve
/// whatever `--spend-reserve` says (that flag is about running out of room, not about naming this
/// account), and comfortable, because the idle rebalance moves a session off an account that is not
/// (Rebalance.swift) and would undo this choice on the first quiet tick.
/// (Comfortable already implies above the reserve, AccountBinding.swift; both guards stay so the
/// reserve rule is readable here.)
func chromeLaunchRow(_ id: String?, providerID: String, in snapshot: Snapshot,
                     primaryModel: String?, quarantined: Set<String>,
                     reserves: AccountReserves, now: Date) -> Snapshot.Account? {
    guard let id,
          let row = pickField(providerID: providerID, in: snapshot, primaryModel: primaryModel,
                              excluding: quarantined).first(where: { $0.id == id }),
          aboveReserve(row, primaryModel: primaryModel, reserves: reserves, now: now),
          accountIsComfortable(row, primaryModel: primaryModel, reserves: reserves, now: now)
    else { return nil }
    return row
}

func chromeLaunchNotice(_ row: Snapshot.Account) -> String {
    "Claude in Chrome is on for this project: launching on \(row.label), the account set for Chrome"
}

/// Supervision by route. A one-shot run never gets one; an opt-out never does. Claude's handoff
/// supervisor needs a snapshot account it may move the session OFF, so a hand-pinned home and a
/// home with no row stay plain execs. Codex's monitor never moves the window off its home, so it
/// runs on every route: an exported home, a pin missing from the snapshot and a bare launch are
/// windows `tally session` still has to reach (B-1736).
private func supervision(_ provider: Provider, intent: LaunchIntent,
                         route: LaunchDecision.Route) -> LaunchDecision.Supervision {
    if intent.oneShot { return .none(.oneShot) }
    if !intent.autoHandoff { return .none(.optedOut) }
    if provider.id == "codex" { return .monitor }
    switch route {
    case .pin, .pick: return .handoff
    case .accountFlag, .exportedHome: return .none(.handPinned)
    case .pinHome, .bare: return .none(.noAccountRow)
    }
}

/// The sentence a refused launch prints. A pin's refusal names the pin.
func launchRefusalText(_ decision: LaunchDecision, pinnedBy: String) -> String? {
    switch decision.refusal {
    case nil: return nil
    case .noMatch(let text)?, .ambiguous(let text)?, .hold(let text)?: return text
    case .named(let text)?: return decision.route == .pin ? "\(text) (\(pinnedBy))" : text
    }
}
