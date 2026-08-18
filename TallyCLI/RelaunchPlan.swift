import Foundation

// The relaunch ONE poll tick decides, and how it reaches the child it restarts. Split from
// SupervisorRuntime.swift at that file's size cap; the division is the one the loop already has -
// everything here is about the single respawn a tick may perform, and nothing here knows how a tick
// decides to want one.

/// The pair a session is pinned to, or the empty pin that means it follows the layers below it.
///
/// A value type because the two axes travel together everywhere: into the request
/// (ModelRequest.swift), into the relaunch plan below, across the self-update exec
/// (ResuperviseContract.swift), and out again. It lives HERE, with the plan that consumes it, rather
/// than with the request that first parses one: this is the file every relaunch's args pass
/// through, and it carries no dependencies of its own, so the suites that compile the relaunch
/// rewrite do not have to compile a request parser to get at a two-field struct.
struct SessionModelPin: Equatable {
    var model: String?
    var effort: String?

    var isEmpty: Bool { model == nil && effort == nil }
}

/// The relaunch a single poll tick decided. The loop folds every reason that fired this tick into
/// ONE plan so the child is killed and respawned exactly once: a cap handoff and a Settings Apply
/// landing together used to fire two SIGTERMs and relaunch twice (2026-07-24). The account move is
/// owned by the FIRST reason (pin > cap > degradation > fallback); a follow adoption only enriches
/// the model/effort on whatever target that reason chose.
struct RelaunchPlan {
    /// The account to run on (may be the current one - follow/fallback stay put).
    var target: Snapshot.Account
    /// Audit-log tag.
    var reason: String
    /// Records against the recovery fuse: true only for automatic cross-account recoveries.
    var countsFuse: Bool
    /// Model/effort to set on the relaunch; nil leaves the current args' pairing untouched. A
    /// follow adoption and a fallback fill these; a plain cap handoff or pin switch leaves them nil.
    var model: String?
    var effort: String?
    /// True when a nil `model`/`effort` means REMOVE that flag rather than leave it alone.
    ///
    /// Only a `tally model --auto` sets it, and it is the one caller for which the default reading
    /// is wrong: releasing a pin back to a fleet default that declares no model has to TAKE the
    /// pinned `--model` off the command line, and "nil leaves it alone" would silently keep the
    /// session on the pair it was just released from. Every other filler either names both axes or
    /// means the default reading.
    var clearsAxes = false
    /// Extra flags the fallback profile appends (e.g. --append-system-prompt).
    var extraArgs: [String] = []
    /// True once a follow adoption has folded its pair in, so the same tick does not do it twice.
    var followFolded = false
    /// True when the relaunch must start a NEW conversation rather than carry this one across.
    ///
    /// One mover sets it: a `tally session clear` answered by moving the session asked for an empty
    /// window (SessionClear.swift), and a relaunch that resumed the transcript would deliver the
    /// opposite of that on a different account. Every other plan carries the conversation, which is
    /// what a handoff, a reload and a pin switch all exist to do, so the default is the safe one.
    var fresh = false
}

/// The tick's relaunch, handed to a station that may only ADD to it.
///
/// `plan` is readable everywhere and writable only from this file, so a station holding one of these
/// can fold a model/effort pair onto a relaunch another reason already decided and CANNOT replace
/// it. That is a type-level answer to a defect prose did not prevent: `applySessionModel` rebuilt
/// the plan around an account of its own choosing while a `tally switch` in the same tick had
/// already chosen one, and the execution point went on committing the switch's pin - so the child
/// came up on one account with the state recording another, and that phantom pin then blocked every
/// later automatic move (caught in review of 9ea3ea9).
///
/// The ordering that defect broke was written down, in the file that runs the stations in order, in
/// the same commit that broke it. Writing an order in prose does not make code obey it; taking the
/// ability away does.
struct TickPlan {
    private(set) var plan: RelaunchPlan?

    init(_ plan: RelaunchPlan? = nil) { self.plan = plan }

    /// Whether some earlier reason has already decided this tick's relaunch, and therefore its
    /// account.
    var isPlanned: Bool { plan != nil }

    /// Put a pair on a relaunch that already exists, leaving its target and its audit tag exactly
    /// as the reason that chose them left them. A no-op when nothing is planned - the caller asks
    /// `isPlanned` first, and this guard is what makes getting that wrong harmless.
    ///
    /// `followFolded` goes up with it, because the launch-default adoption runs after every station
    /// that uses this and would otherwise fold the FLEET's pair over the one just applied.
    mutating func foldAxes(model: String?, effort: String?, clearsAxes: Bool) {
        guard plan != nil else { return }
        plan?.model = model
        plan?.effort = effort
        plan?.clearsAxes = clearsAxes
        plan?.followFolded = true
    }

    /// Propose a relaunch, honoured only when nothing else has planned one. Silently ignored
    /// otherwise, which is the same rule every `plan == nil` gate in the loop already applies -
    /// stated once, here, rather than trusted to each caller.
    mutating func propose(_ proposed: RelaunchPlan) {
        guard plan == nil else { return }
        plan = proposed
    }
}

/// The launch args a plan's relaunch runs with: the pairing it carries replaces whatever `--model`
/// and `--effort` the current args hold, and its extra flags follow. A plan carrying none (a plain
/// cap handoff, a pin switch, a reload) leaves the args exactly as the resume path produced them.
/// One function rather than an inline rewrite because a self-update folded into the plan execs with
/// these same args: the new build must receive what the child would have been given.
func planLaunchArgs(_ args: [String], plan: RelaunchPlan,
                    sessionPin: SessionModelPin = SessionModelPin()) -> [String] {
    var plan = plan
    // A SESSION PIN THAT NEVER REACHED THE COMMAND LINE. A `tally model` rewrites the argv on its
    // way past, so its pin is on every later relaunch for free; a native `/model` adopted from the
    // transcript deliberately does NOT relaunch (the session already serves it), so the argv still
    // says what the session was launched with. Any later plan carrying no axes of its own - a
    // reload, a switch, a cap handoff, a self-update - would then respawn the child on the old pair
    // while `sessionPrimaryModel` went on reporting the new one, and the two would disagree until
    // something noticed (caught in review of c914b41).
    //
    // HERE rather than in each mover, because "each mover learns to carry one more thing" is the
    // shape of the flag family this feature spent a package collapsing. Every relaunch's args pass
    // through this function; a pin that reaches it reaches all of them.
    //
    // Only when the plan names NEITHER axis: one that names them is more specific and wins, and a
    // release (`clearsAxes`) is an instruction to take them off. The other axis is re-named from the
    // args because everything below strips both before injecting.
    if plan.model == nil, plan.effort == nil, !plan.clearsAxes, !sessionPin.isEmpty {
        plan.model = sessionPin.model ?? flagValue(args, "--model")
        plan.effort = sessionPin.effort ?? flagValue(args, "--effort")
    }
    guard plan.model != nil || plan.effort != nil || !plan.extraArgs.isEmpty || plan.clearsAxes
    else { return args }
    // Gathered first, then placed where they will be READ (`injectingOptions`, Snapshot.swift).
    // Appended, a relaunch that changed the model landed it past the user's `--` and into the
    // prompt: claude ran the OLD pairing, `FollowState` could not see the new one either, and its
    // baseline had already been re-pointed - so the session ran on a setting nobody could observe
    // and no later tick would ever correct it, while each pass added another copy to the prompt.
    var injected: [String] = []
    if let model = plan.model { injected += ["--model", model] }
    if let effort = plan.effort { injected += ["--effort", effort] }
    // The extra flags go through the positional strip as well, because they are the ONE way a word
    // can still enter a relaunch's args after `relaunchArgs` has cleaned them: `fallbackArgs` is
    // free text the user configured and it is split on spaces (ModelDegradation.swift), so
    // `--append-system-prompt be brief` arrives here as a flag, a value, and a stray word - and a
    // stray word in a child's args is an initial prompt, submitted again at every restart
    // (`withoutPositionals`, LaunchFlags.swift). Truncating a configured sentence is the lesser
    // failure of the two, and the real defect is the space split rather than this.
    return injectingOptions(removingFlagPairs(args, ["--model", "--effort"]),
                            injected + withoutPositionals(plan.extraArgs))
}
