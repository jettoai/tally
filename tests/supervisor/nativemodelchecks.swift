import Foundation

// Claude Code's OWN `/model`, made to work inside a Tally session.
//
// THE INCIDENT. A user typed `/model` in a supervised geo session and chose Opus 5 at xhigh. The
// next turn was served by opus, `applyDegradationRescue` read "the serving model is not the one we
// expect" as a quota degradation, moved the session to another account and relaunched it from the
// argv - which put fable back. Typing `/model` again went round the same loop
// (handoff.log reason=degraded, 2026-08-06T19:40:59Z, session 7cfa11a4). The owner's question was
// "why is the native one not supported".
//
// The transcript cannot tell a degradation from a person on the serving model alone: both look like
// "not what we expect". The `/model` event is the signal that separates them, and once the two are
// separable the right answer is the opposite of a rescue - the choice is an instruction, so it joins
// the pin layer `tally model` already built, and nothing needs to restart because the session is
// already serving it.

func runNativeModelChecks() {
    // MARK: - 35a. Reading a foreign command's output

    // The exact line from the incident, ANSI and all. The model NAME in it is a display string
    // ("Opus 5 (1M context)") that changes with the product and is never parsed; the effort is one
    // of the levels the CLI itself enumerates, and that is the only thing read here.
    let real = "Set model to \u{1B}[1mOpus 5 (1M context)\u{1B}[22m and saved as your default for "
        + "new sessions with \u{1B}[1mxhigh\u{1B}[22m effort"
    check("the effort is read out of the real line, past its escape codes",
          nativeModelEffort(inStdout: real) == "xhigh")
    check("…and the display name in it is not mistaken for a model id",
          nativeModelEffort(inStdout: real) != "Opus 5 (1M context)")
    // BOTH SHAPES ARE ORDINARY. Counted across this machine's transcripts: 78 lines end after "for
    // new sessions", 92 carry an effort. An absent one is not a parse failure.
    check("a line naming no effort answers nil, which means leave that axis alone",
          nativeModelEffort(inStdout: "Set model to \u{1B}[1mFable 5\u{1B}[22m and saved as your "
              + "default for new sessions") == nil)
    check("every level the enumeration holds is recognised",
          claudeEffortNames().allSatisfy {
              nativeModelEffort(inStdout: "... with \($0) effort") == $0
          })
    // The whole phrase is matched, which is what keeps the shorter level out of the longer one.
    check("`high` does not claim a line that says `xhigh`",
          nativeModelEffort(inStdout: "... with xhigh effort") == "xhigh")
    check("…and a level outside the enumeration is not invented into one",
          nativeModelEffort(inStdout: "... with extreme effort") == nil)
    check("…nor is a bare word that happens to be a level",
          nativeModelEffort(inStdout: "Set model to high") == nil)
    check("escape codes are stripped, and nothing else is",
          strippingANSI("\u{1B}[1mOpus 5 (1M context)\u{1B}[22m/x")
              == "Opus 5 (1M context)/x")
    check("text with no escape codes survives untouched",
          strippingANSI("plain text") == "plain text")
    check("a truncated escape sequence does not run off the end",
          strippingANSI("done\u{1B}[") == "done")

    // MARK: - 35b. Which `/model` events count

    /// The two adjacent main-chain user events Claude Code writes for one `/model`.
    func modelCommandLines(at offset: TimeInterval, effort: String?,
                           sidechain: Bool = false) -> [String] {
        let side = sidechain ? "true" : "false"
        let tail = effort.map { " with \\u001b[1m\($0)\\u001b[22m effort" } ?? ""
        return [
            #"{"type":"user","isSidechain":\#(side),"timestamp":"\#(stamp(offset))","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-message>model</command-message>"}}"#,
            #"{"type":"user","isSidechain":\#(side),"timestamp":"\#(stamp(offset))","message":{"role":"user","content":"<local-command-stdout>Set model to \#("\\u001b[1mOpus 5 (1M context)\\u001b[22m")\#(" and saved as your default for new sessions")\#(tail)</local-command-stdout>"}}"#,
        ]
    }
    func servedLine(_ model: String, at offset: TimeInterval) -> String {
        #"{"type":"assistant","isSidechain":false,"timestamp":"\#(stamp(offset))","message":{"model":"\#(model)"}}"#
    }

    let typed = watcherAfterScanning(modelCommandLines(at: 30, effort: "xhigh")
        + [servedLine("claude-opus-4-8", at: 60)])
    check("a post-launch /model is noticed, with the effort it printed",
          typed.lastModelCommandAt == launch.addingTimeInterval(30)
              && typed.lastModelCommandEffort == "xhigh")
    // THE GUARD THAT MATTERS MOST. A resumed session replays its entire history, and that history
    // holds every earlier /model - the incident session had four. A replayed one is not somebody
    // changing the model now, and adopting it would pin a choice from another day.
    let replayed = watcherAfterScanning(modelCommandLines(at: -3600, effort: "high")
        + [servedLine("claude-opus-4-8", at: 60)])
    check("a /model replayed out of history is not one",
          replayed.lastModelCommandAt == nil)
    check("a /model on a subagent's chain is not this session's either",
          watcherAfterScanning(modelCommandLines(at: 30, effort: "high", sidechain: true))
              .lastModelCommandAt == nil)
    check("a session where nobody typed it has none",
          watcherAfterScanning([servedLine("claude-opus-4-8", at: 60)]).lastModelCommandAt == nil)
    check("a /model that printed no effort leaves that axis unnamed",
          watcherAfterScanning(modelCommandLines(at: 30, effort: nil)).lastModelCommandEffort == nil)
    // `/tally-model` writes a command event too, and it is a different command: it asks this
    // supervisor for something, where the native one only reports what already happened.
    check("Tally's own slash command is not mistaken for the native one",
          watcherAfterScanning([
              #"{"type":"user","isSidechain":false,"timestamp":"\#(stamp(30))","message":{"role":"user","content":"<command-name>/tally-model</command-name>"}}"#,
          ]).lastModelCommandAt == nil)

    // MARK: - 35c. Adopting it

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-native-model-\(UUID().uuidString)")
    func freshState() -> SessionModelState {
        SessionModelState(sessionKey: "6001", servedEpoch: 0, dir: dir)
    }
    var state = freshState()
    var follow = FollowState(launchArgs: ["--model", "fable", "--effort", "high"])
    check("the choice becomes this session's pin",
          adoptNativeModelChoice(state: &state, follow: &follow, watcher: typed,
                                 primaryModel: "fable",
                                 launchArgs: ["--model", "fable", "--effort", "high"]))
    check("…as the OBSERVED id, never the display name the line showed",
          state.pin.model == "claude-opus-4-8")
    check("…with the effort that line named", state.pin.effort == "xhigh")
    check("…and the launch-default baseline re-pointed, so the follow does not undo it",
          follow.followedModel == "claude-opus-4-8" && follow.followedEffort == "xhigh")
    // Once is once: re-announcing a choice the user made a minute ago, every two seconds, would be
    // its own defect.
    check("a second tick does not adopt it again",
          !adoptNativeModelChoice(state: &state, follow: &follow, watcher: typed,
                                  primaryModel: "claude-opus-4-8",
                                  launchArgs: ["--model", "fable"]))

    // THE TENSE GUARD, and the fixture is the sequence that makes it load-bearing. `lastModel` is
    // the model that served the last answer WRITTEN DOWN, so between a /model and the next turn it
    // still holds the previous one. That is harmless while the previous one was what we expected -
    // and it is exactly wrong in the case a user is most likely to be IN: something had already
    // degraded the session onto another model, they opened /model to fix it, and no answer has come
    // back yet. Adopting then would pin the degradation as though they had asked for it.
    //
    // (Written first with a fixture where the previous answer AGREED with the primary. It passed,
    // and it passed for the wrong reason - the agreement check refused it long before the tense
    // check was consulted - so a mutation removing the tense guard stayed green.)
    let degradedThenTyped = watcherAfterScanning([servedLine("claude-opus-4-8", at: 10)]
        + modelCommandLines(at: 30, effort: "xhigh"))
    var waiting = freshState()
    var waitingFollow = FollowState(launchArgs: ["--model", "fable"])
    check("a /model with no answer served since it is not adopted yet",
          !adoptNativeModelChoice(state: &waiting, follow: &waitingFollow,
                                  watcher: degradedThenTyped, primaryModel: "fable",
                                  launchArgs: ["--model", "fable"]))
    check("…so a degradation the user was reacting TO is never pinned as their choice",
          !waiting.isPinned)
    // Once an answer does come back, it is that answer that is adopted - which may be neither the
    // model they were degraded onto nor the one they were launched with.
    let confirmed = watcherAfterScanning([servedLine("claude-opus-4-8", at: 10)]
        + modelCommandLines(at: 30, effort: "xhigh")
        + [servedLine("claude-haiku-4-5", at: 60)])
    var settled = freshState()
    var settledFollow = FollowState(launchArgs: ["--model", "fable"])
    check("the answer that arrives after the command is the one adopted",
          adoptNativeModelChoice(state: &settled, follow: &settledFollow, watcher: confirmed,
                                 primaryModel: "fable", launchArgs: ["--model", "fable"])
              && settled.pin.model == "claude-haiku-4-5")

    // A /model that chose what the session was already running changes nothing, so there is nothing
    // to adopt and nothing to say.
    var agreeing = freshState()
    var agreeingFollow = FollowState(launchArgs: ["--model", "fable"])
    check("choosing the model already running adopts nothing",
          !adoptNativeModelChoice(state: &agreeing, follow: &agreeingFollow,
                                  watcher: watcherAfterScanning(
                                      modelCommandLines(at: 30, effort: nil)
                                          + [servedLine("claude-fable-5", at: 60)]),
                                  primaryModel: "fable", launchArgs: ["--model", "fable"]))
    // An effort the line did not name leaves that axis alone rather than resetting it - the same
    // thing `tally model <model>` with no effort means.
    var effortless = freshState()
    var effortlessFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "max"])
    _ = adoptNativeModelChoice(state: &effortless, follow: &effortlessFollow,
                               watcher: watcherAfterScanning(
                                   modelCommandLines(at: 30, effort: nil)
                                       + [servedLine("claude-opus-4-8", at: 60)]),
                               primaryModel: "fable",
                               launchArgs: ["--model", "fable", "--effort", "max"])
    check("a choice that named no effort pins only the model",
          effortless.pin == SessionModelPin(model: "claude-opus-4-8", effort: nil))
    check("…and the baseline keeps the effort the command line still carries",
          effortlessFollow.followedEffort == "max")

    // MARK: - 35c2. One command, one adoption

    // WITHOUT THIS THE ADOPTION IS A STANDING RULE, not a decision. The `/model` marker lives as
    // long as the child, so every later disagreement between the serving model and the pin still
    // satisfied "a /model happened, and this observation is newer than it" - a genuine quota
    // fallback included. It would be adopted as the user's choice, and the degradation rescue would
    // never fire again for the rest of that child (review of c914b41).
    var consumed = freshState()
    var consumedFollow = FollowState(launchArgs: ["--model", "fable"])
    check("the first adoption is served",
          adoptNativeModelChoice(state: &consumed, follow: &consumedFollow, watcher: typed,
                                 primaryModel: "fable", launchArgs: ["--model", "fable"])
              && consumed.servedModelCommandAt == launch.addingTimeInterval(30))
    // Now a REAL degradation, on the same child: the serving model moves again, and no new /model
    // was typed. This is the rescue's case and it must stay the rescue's case.
    let laterDegradation = watcherAfterScanning(modelCommandLines(at: 30, effort: "xhigh")
        + [servedLine("claude-opus-4-8", at: 60), servedLine("claude-haiku-4-5", at: 90)])
    check("a later degradation under the SAME /model is not adopted as a second choice",
          !adoptNativeModelChoice(state: &consumed, follow: &consumedFollow,
                                  watcher: laterDegradation, primaryModel: "claude-opus-4-8",
                                  launchArgs: ["--model", "fable"]))
    check("…so the pin still names what the user actually chose",
          consumed.pin.model == "claude-opus-4-8")
    // A genuinely new /model is a new instruction, and is adopted.
    let typedAgain = watcherAfterScanning(modelCommandLines(at: 30, effort: "xhigh")
        + [servedLine("claude-opus-4-8", at: 60)] + modelCommandLines(at: 90, effort: nil)
        + [servedLine("claude-haiku-4-5", at: 120)])
    check("a NEWER /model is a new instruction",
          adoptNativeModelChoice(state: &consumed, follow: &consumedFollow, watcher: typedAgain,
                                 primaryModel: "claude-opus-4-8", launchArgs: ["--model", "fable"])
              && consumed.pin.model == "claude-haiku-4-5")

    // MARK: - 35c3. Keeping the model and moving only the depth

    // The picker can leave the model alone and change the effort, and reading "the model still
    // agrees" as "nothing happened" threw the parsed effort away: the child ran xhigh while the
    // next relaunch would put high back (review of c914b41).
    let depthOnly = watcherAfterScanning(modelCommandLines(at: 30, effort: "xhigh")
        + [servedLine("claude-fable-5", at: 60)])
    var depth = freshState()
    var depthFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "high"])
    check("a /model that kept the model but moved the depth is still adopted",
          adoptNativeModelChoice(state: &depth, follow: &depthFollow, watcher: depthOnly,
                                 primaryModel: "fable",
                                 launchArgs: ["--model", "fable", "--effort", "high"]))
    check("…pinning the effort, and leaving the model alone because it did not move",
          depth.pin == SessionModelPin(model: nil, effort: "xhigh"))
    check("…and it is consumed once, so the same event cannot be adopted again",
          !adoptNativeModelChoice(state: &depth, follow: &depthFollow, watcher: depthOnly,
                                  primaryModel: "fable",
                                  launchArgs: ["--model", "fable", "--effort", "high"]))
    // Choosing the depth already running is not a change either.
    var sameDepth = freshState()
    var sameDepthFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "xhigh"])
    check("choosing the depth already running adopts nothing",
          !adoptNativeModelChoice(state: &sameDepth, follow: &sameDepthFollow, watcher: depthOnly,
                                  primaryModel: "fable",
                                  launchArgs: ["--model", "fable", "--effort", "xhigh"]))

    // MARK: - 35d. What the rest of the tick then believes

    // The pin leads, and that is what stops the rescue: the session runs what was chosen, so the
    // difference the rescue exists to cure no longer exists.
    check("the pin outranks the command line when the tick asks what this session runs",
          sessionPrimaryModel(pin: state.pin, launchArgs: ["--model", "fable"],
                              providerID: "claude", policy: LaunchPolicy()) == "claude-opus-4-8")
    var declaredPolicy = LaunchPolicy()
    declaredPolicy.model = "haiku"
    check("with no pin it is the command line, then the configured default",
          sessionPrimaryModel(pin: SessionModelPin(), launchArgs: ["--model", "fable"],
                              providerID: "claude", policy: declaredPolicy) == "fable"
              && sessionPrimaryModel(pin: SessionModelPin(), launchArgs: [],
                                     providerID: "claude", policy: declaredPolicy) == "haiku")
    // ADOPTION DOES NOT RESTART. The session is already serving the chosen model; a relaunch would
    // interrupt a conversation to arrive where it already is, and that pointless restart is the
    // whole cost of the incident. The argv catches up at the next relaunch something else asks for.
    // Asserted THROUGH THE TICK'S OWN SEQUENCE, not through the adoption alone: the adoption has no
    // plan to write, so testing it by itself cannot tell whether the caller turns the result into a
    // restart. A mutation that made it plan one passed that weaker check silently.
    var plan: RelaunchPlan?
    var replanState = freshState()
    var replanFollow = FollowState(launchArgs: ["--model", "fable"])
    var moves = ManualMoveState(sessionKey: "6001", servedEpoch: 0, dir: dir)
    var switchRecord: PendingSwitchConsumption?
    var modelRecord: PendingModelConsumption?
    var tickPolicy = LaunchPolicy()
    var tickPrimary: String? = "fable"
    var tickWatcher = typed
    applySessionDirectives(plan: &plan, moves: &moves, switchRecord: &switchRecord,
                           model: &replanState, modelRecord: &modelRecord,
                           follow: &replanFollow, following: false, policy: &tickPolicy,
                           account: switchAccount("A"), providerID: "claude",
                           launchArgs: ["--model", "fable"], primaryModel: &tickPrimary,
                           quarantine: [:], watcher: &tickWatcher, childAge: 600,
                           keyboardIdle: { _ in true }, modelRequest: { _ in nil },
                           switchRequest: { _ in nil })
    check("the tick adopts the choice", replanState.pin.model == "claude-opus-4-8")
    check("…and plans NO relaunch for it: the session already serves that model",
          plan == nil && modelRecord == nil)
    check("…while handing the rest of the tick the model it now runs",
          tickPrimary == "claude-opus-4-8")
    // And with the pin in hand the rescue no longer sees a degradation. Asserted through the real
    // function: its first guard is what returns here, so it never reaches a snapshot read.
    var rescued = typed
    applyDegradationRescue(plan: &plan, watcher: &rescued, driftActive: false,
                           policy: LaunchPolicy(), account: switchAccount("A"),
                           providerID: "claude",
                           primaryModel: sessionPrimaryModel(pin: replanState.pin,
                                                             launchArgs: ["--model", "fable"],
                                                             providerID: "claude",
                                                             policy: LaunchPolicy()),
                           quarantine: [:], fuseAllows: true)
    check("and the degradation rescue no longer has anything to cure", plan == nil)

    // MARK: - 35d2. The pin reaches the next relaunch's command line

    // The adoption deliberately does not relaunch, which leaves the argv saying what the session
    // was LAUNCHED with. So any later plan carrying no axes of its own - a reload, a switch, a cap
    // handoff, a self-update - would respawn the child on the old pair while `sessionPrimaryModel`
    // reported the new one, and the two would disagree until something noticed (review of c914b41).
    // Closed at the one place every relaunch's args pass through, rather than in each mover.
    let adopted = SessionModelPin(model: "claude-opus-4-8", effort: "xhigh")
    let reload = RelaunchPlan(target: switchAccount("A"), reason: "reload", countsFuse: false)
    check("a plan naming no axes carries the adopted pair onto the new command line",
          planLaunchArgs(["--model", "fable", "--effort", "high", "--continue"], plan: reload,
                         sessionPin: adopted)
              == ["--continue", "--model", "claude-opus-4-8", "--effort", "xhigh"])
    check("…and with no pin at all it leaves the args exactly as they were",
          planLaunchArgs(["--model", "fable", "--continue"], plan: reload)
              == ["--model", "fable", "--continue"])
    // An effort-only pin keeps the model the args already carry: everything below strips both
    // flags before injecting, so the axis nobody pinned has to be re-named from the args.
    check("an effort-only pin keeps the model the command line already had",
          planLaunchArgs(["--model", "fable", "--effort", "high"], plan: reload,
                         sessionPin: SessionModelPin(effort: "xhigh"))
              == ["--model", "fable", "--effort", "xhigh"])
    check("…and the injected pair lands where a flag is READ, before any bare marker",
          planLaunchArgs(["--model", "fable", "--", "write a haiku"], plan: reload,
                         sessionPin: adopted)
              == ["--model", "claude-opus-4-8", "--effort", "xhigh", "--", "write a haiku"])
    // A plan that names its own axes is the more specific instruction and wins; a release is an
    // instruction to take them off, and the pin must not put them back.
    let follows = RelaunchPlan(target: switchAccount("A"), reason: "follow", countsFuse: false,
                               model: "haiku", effort: "low")
    check("a plan that names its own pair outranks the pin",
          planLaunchArgs(["--model", "fable"], plan: follows, sessionPin: adopted)
              == ["--model", "haiku", "--effort", "low"])
    var release = RelaunchPlan(target: switchAccount("A"), reason: "model", countsFuse: false)
    release.clearsAxes = true
    check("a release takes the axes off rather than having the pin put them back",
          planLaunchArgs(["--model", "fable", "--continue"], plan: release, sessionPin: adopted)
              == ["--continue"])

    // A REAL DEGRADATION IS UNTOUCHED. No /model event, so nothing is adopted, the primary stays
    // what it was, and the difference the rescue acts on is still there.
    let degraded = watcherAfterScanning([servedLine("claude-opus-4-8", at: 60)])
    var untouched = freshState()
    var untouchedFollow = FollowState(launchArgs: ["--model", "fable"])
    check("a serving model nobody asked for is not adopted",
          !adoptNativeModelChoice(state: &untouched, follow: &untouchedFollow, watcher: degraded,
                                  primaryModel: "fable", launchArgs: ["--model", "fable"]))
    check("…so the session is still understood to run what it was launched with",
          !untouched.isPinned
              && sessionPrimaryModel(pin: untouched.pin, launchArgs: ["--model", "fable"],
                                     providerID: "claude", policy: LaunchPolicy()) == "fable")
    check("…which is exactly the difference the rescue reads",
          degraded.lastModel?.contains("fable") == false)
    try? FileManager.default.removeItem(at: dir)
}
