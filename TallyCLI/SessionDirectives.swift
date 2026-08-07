import Foundation

// What decides, on one poll tick, WHERE this session runs and WHAT it runs there.
//
// Three sources can change either answer while a conversation is alive, and they are ordered:
//
//   1. `tally switch` / a pin moved in the panel - the ACCOUNT (SessionSwitch.swift)
//   2. `tally model` - the MODEL AND EFFORT, on whatever account the step above settled on
//      (SessionModel.swift)
//   3. the launch default in Settings - both axes, but only for a session that has not been told
//      otherwise (FollowAdoption.swift)
//
// Lifted out of the poll loop, which is at the repo's file-size cap, in the shape its other deferred
// decisions already use: each owns its own `inout` state, the plan they may write comes in as
// another, and everything they consult is injected. What is new is only that the three arrive
// TOGETHER, and that is the point of the file rather than a side effect of moving them.
//
// THE ORDER IS A RULE, NOT AN ARRANGEMENT, and having it in one function is what stops a later edit
// from quietly changing it:
//
//   - The account instruction runs first because it is about a different question. "Run this
//     conversation over there" and "run it on opus" compose - the second folds its pair onto
//     whatever target the first chose - so a `tally switch` and a `tally model` typed in the same
//     window are both honoured on the same restart rather than racing for it.
//   - Both of them outrank the follow, and the follow STANDS DOWN entirely while a model pin
//     stands. The session scope beats the fleet scope on this axis exactly as it does on the
//     account one: a Settings change after a `tally model` is a change to what NEW sessions run,
//     not an instruction to take this conversation off the pair its user just chose.
//   - The follow runs last so that, when it does run, it can fold its pair into a relaunch one of
//     the others already planned instead of costing a second one.

/// One tick's answer to all three, in that order. `policy` comes in as the fleet's (the app's, with
/// this project's profile over it) and goes out as this SESSION's, because the account pin can
/// change inside this call and every mover after it must be judged by the pin the session has now
/// (the reasoning is `applyManualMoves`'s own).
///
/// Both request readings are injected, for the reason every other file-touching helper here injects
/// them: the sequence has to be reachable in a test without a home directory.
///
/// `primaryModel` comes in as what the session was understood to run and goes out as what it runs
/// now, which the adoption below can change without any relaunch at all.
///
/// `following` is the session-lifetime opt-out: false when the user typed their own `--model` or
/// `--effort` at launch, or passed `--no-follow`. The per-tick stand-down for a live model pin is
/// decided here rather than by the caller, so the two cannot come apart.
func applySessionDirectives(plan: inout RelaunchPlan?,
                            moves: inout ManualMoveState,
                            switchRecord: inout PendingSwitchConsumption?,
                            model: inout SessionModelState,
                            modelRecord: inout PendingModelConsumption?,
                            follow: inout FollowState, following: Bool,
                            policy: inout LaunchPolicy,
                            account: Snapshot.Account, providerID: String, launchArgs: [String],
                            primaryModel: inout String?,
                            quarantine: [String: (model: String?, until: Date)],
                            watcher: inout TranscriptWatcher, childAge: TimeInterval,
                            keyboardIdle: (TimeInterval) -> Bool,
                            modelRequest: (String) -> ModelRequest? = {
                                readModelRequest(sessionKey: $0)
                            },
                            switchRequest: (String) -> SwitchRequest? = {
                                readSwitchRequest(sessionKey: $0)
                            }) {
    // Claude Code's own `/model`, read out of the transcript and taken as the instruction it is.
    // FIRST, because it changes what this session is understood to run, and everything after it -
    // including the degradation rescue one call further down the tick - has to be judged against
    // that rather than against the command line the session was launched with. It plans no
    // relaunch, so it cannot compete with the two below for the tick's one restart.
    // The notice it leaves is NEWS on the status line rather than a line on the terminal (that
    // adoption is the one model-axis event with no relaunch behind it), so something that runs every
    // tick has to take it down again - the same shape, and the same reason, as the cancelled switch
    // one axis over (`expireCancellation`, SessionSwitch.swift). Before the adoption, so a notice
    // raised on THIS tick is never expired by a prompt older than it.
    model.expireAdoption(lastUserTurnAt: watcher.lastUserTurnAt)
    adoptNativeModelChoice(state: &model, follow: &follow, watcher: watcher,
                           primaryModel: primaryModel, launchArgs: launchArgs)
    // Re-derived HERE rather than by the caller, exactly as `policy` is and for the same reason:
    // this call can change the pin, and every reader after it - the degradation rescue above all -
    // must judge the session by what it runs now.
    primaryModel = sessionPrimaryModel(pin: model.pin, launchArgs: launchArgs,
                                       providerID: providerID, policy: policy)
    applyManualMoves(plan: &plan, state: &moves, record: &switchRecord, policy: &policy,
                     account: account, providerID: providerID, watcher: &watcher,
                     childAge: childAge, keyboardIdle: keyboardIdle, request: switchRequest)
    // Handed the tick's relaunch as something it may only ADD to: with an account already chosen
    // above, this station folds its pair onto that plan and cannot replace it (`TickPlan`,
    // SupervisorRuntime.swift). The wrap is here rather than around the whole sequence because the
    // station before it is the one that legitimately DOES choose an account.
    var planning = TickPlan(plan)
    applySessionModel(plan: &planning, state: &model, record: &modelRecord, follow: &follow,
                      policy: policy, account: account, providerID: providerID,
                      launchArgs: launchArgs,
                      // Every way an account can already be spoken for arrives as one question:
                      // this session's own pin, the project's and the app's are all folded into
                      // `policy.mode` by the call above (`sessionPolicy`).
                      accountPinned: moves.sessionPin != nil || policy.mode == "manual",
                      quarantine: quarantine, watcher: &watcher, childAge: childAge,
                      keyboardIdle: keyboardIdle, request: modelRequest(model.sessionKey))
    plan = planning.plan
    applyFollowAdoption(plan: &plan, state: &follow, following: following && !model.isPinned,
                        policy: policy, account: account, providerID: providerID,
                        launchArgs: launchArgs, quarantine: quarantine, watcher: &watcher,
                        keyboardIdle: keyboardIdle)
}
