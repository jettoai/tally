import Foundation

// The capacity fallback (`model_fallback`, trigger=server_error): the reading that keeps the two
// degradation movers off it, and the safety net that types `/model` for a window left on the
// fallback model. Top-level statements live in main.swift, so these run as one function it calls.

private let overloadReal = #"""
{"parentUuid":"6b0a53a8-7f36-4a3d-9c1a-0d2f3e4b5a69","isSidechain":false,"type":"system","subtype":"model_fallback","content":"Switched to Opus 5.5 due to high demand for Sonnet 5.5","level":"warning","trigger":"server_error","direction":"retry","originalModel":"claude-sonnet-5-5","fallbackModel":"claude-opus-5-5","requestId":"req_011Cg0000000000000000000","isMeta":false,"uuid":"c3f1a2b4-0000-4000-8000-00000000f001","timestamp":"\#(stamp(60))","userType":"external","entrypoint":"cli","cwd":"/w","sessionId":"s","version":"2.1.300"}
"""#

private func overloadEvent(at offset: TimeInterval = 60, uuid: String? = "c3f1a2b4-0000-4000-8000-00000000f001",
                           trigger: String = "server_error") -> OverloadFallbackEvent {
    OverloadFallbackEvent(at: launch.addingTimeInterval(offset), from: "claude-sonnet-5-5",
                          to: "claude-opus-5-5", trigger: trigger, uuid: uuid)
}

private func overloadInput(event: OverloadFallbackEvent? = overloadEvent(),
                           actual: String? = "claude-opus-5-5", primary: String? = "sonnet",
                           provider: String = "claude", drift: Bool = false,
                           command: Date? = nil, quiet: Bool = true) -> OverloadRevertInput {
    OverloadRevertInput(event: event, actualModel: actual, primaryModel: primary,
                        providerID: provider, safeguardDriftActive: drift,
                        modelCommandAt: command, quiet: quiet)
}

func runOverloadRevertChecks() {
    let now = launch.addingTimeInterval(600)
    func decide(_ input: OverloadRevertInput, _ brake: OverloadRevertBrake = OverloadRevertBrake(),
                at: Date = now) -> OverloadRevertDecision {
        overloadRevertDecision(input, brake: brake, now: at)
    }

    // MARK: - The decision gates, one counter-example each
    check("every gate open: revert to the declared alias, keyed by the event uuid",
          decide(overloadInput()) == .revert(model: "sonnet",
                                             eventKey: "c3f1a2b4-0000-4000-8000-00000000f001"))
    check("no event: nothing", decide(overloadInput(event: nil)) == .none("no-event"))
    check("codex is never touched", decide(overloadInput(provider: "codex")) == .none("codex"))
    check("a safeguard drift is never reverted", decide(overloadInput(drift: true)) == .none("safeguard"))
    check("an unseen trigger is left alone",
          decide(overloadInput(event: overloadEvent(trigger: "refusal"))) == .none("trigger"))
    check("a session the person pinned to opus is not this event's session",
          decide(overloadInput(primary: "opus")) == .none("primary-mismatch"))
    check("no primary at all is a mismatch, not a guess",
          decide(overloadInput(primary: nil)) == .none("primary-mismatch"))
    check("a /model after the event is the person's choice",
          decide(overloadInput(command: launch.addingTimeInterval(90))) == .none("user-chose"))
    check("a /model before the event is not",
          decide(overloadInput(command: launch.addingTimeInterval(30))) != .none("user-chose"))
    check("the original model answered again: recovered",
          decide(overloadInput(actual: "claude-sonnet-5-5")) == .none("recovered"))
    check("not quiet: wait", decide(overloadInput(quiet: false)) == .none("not-quiet"))
    check("an alias that is not typable never reaches the terminal",
          decide(overloadInput(primary: "claude-sonnet-5-5 x")) == .none("model-name"))
    let key = overloadEventKey(overloadEvent())
    check("one switch per event", decide(overloadInput(), OverloadRevertBrake(handled: [key]))
          == .none("handled"))
    let keyless = overloadEvent(uuid: nil)
    check("no uuid: the key is the event time",
          overloadEventKey(keyless) == ISO8601DateFormatter().string(from: keyless.at))

    // MARK: - Backoff and the hourly cap
    let switched = OverloadRevertBrake(reverts: [launch.addingTimeInterval(60)])
    let soon = overloadEvent(at: 60 + 5 * 60, uuid: "again")
    let braked = overloadRevertBrakeOnEvent(switched, event: soon)
    check("a new event 5 minutes after our switch sets a 15-minute backoff",
          braked.notBefore == soon.at.addingTimeInterval(15 * 60))
    let againInput = overloadInput(event: soon)
    check("14 minutes into it: wait",
          decide(againInput, braked, at: soon.at.addingTimeInterval(14 * 60))
              == .wait(until: soon.at.addingTimeInterval(15 * 60)))
    check("15 minutes in: revert again",
          decide(againInput, braked, at: soon.at.addingTimeInterval(15 * 60))
              == .revert(model: "sonnet", eventKey: "again"))
    check("an event 11 minutes after our switch sets no backoff",
          overloadRevertBrakeOnEvent(switched, event: overloadEvent(at: 60 + 11 * 60, uuid: "late"))
              .notBefore == nil)
    check("brake-on-event is idempotent",
          overloadRevertBrakeOnEvent(braked, event: soon) == braked)
    let spent = OverloadRevertBrake(reverts: [0, 600, 1200].map { launch.addingTimeInterval($0) })
    check("three switches in the hour: capped",
          decide(overloadInput(), spent, at: launch.addingTimeInterval(1800)) == .none("hour-cap"))
    check("…and the oldest one an hour old frees a slot",
          decide(overloadInput(), spent, at: launch.addingTimeInterval(3600))
              == .revert(model: "sonnet", eventKey: key))

    // MARK: - (c): the movers stay off a capacity fallback
    check("explained: server_error, serving the fallback model, primary is the original",
          overloadFallbackExplains(event: overloadEvent(), actualModel: "claude-opus-5-5",
                                   primaryModel: "sonnet"))
    check("an unseen trigger explains nothing",
          !overloadFallbackExplains(event: overloadEvent(trigger: "x"), actualModel: "claude-opus-5-5",
                                    primaryModel: "sonnet"))
    check("a third model explains nothing",
          !overloadFallbackExplains(event: overloadEvent(), actualModel: "claude-haiku-5",
                                    primaryModel: "sonnet"))
    check("a different primary explains nothing",
          !overloadFallbackExplains(event: overloadEvent(), actualModel: "claude-opus-5-5",
                                    primaryModel: "fable"))
    check("no event explains nothing",
          !overloadFallbackExplains(event: nil, actualModel: "claude-opus-5-5", primaryModel: "sonnet"))

    let account = Snapshot.Account(
        id: "claude:A", provider: "claude", label: "A", launchHome: "/tmp/A",
        sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: 0, sessionResetsAt: nil,
        weeklyResetsAt: nil, modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
        isStale: false, error: nil)
    let sibling = Snapshot.Account(
        id: "claude:B", provider: "claude", label: "B", launchHome: "/tmp/B",
        sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: 90, sessionResetsAt: nil,
        weeklyResetsAt: nil, modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
        isStale: false, error: nil)
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-overload-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("session.jsonl")
    try! "{}".write(to: file, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9999)],
                                           ofItemAtPath: file.path)
    var watcher = TranscriptWatcher(projectDir: dir, file: file, since: launch)
    watcher.lastModel = "claude-opus-5-5"
    let policy = LaunchPolicy(mode: "auto", model: "sonnet", fallbackModel: "opus", effort: "high",
                              fallbackEffort: "high")
    let fleet = { (Snapshot(version: 2, generatedAt: Date(), accounts: [account, sibling]), nil as String?) }
    func rescue(overload: Bool) -> RelaunchPlan? {
        var plan: RelaunchPlan?
        applyDegradationRescue(plan: &plan, watcher: &watcher, driftActive: false,
                               overloadActive: overload, policy: policy, account: account,
                               providerID: "claude", primaryModel: "sonnet", quarantine: [:],
                               steering: true, fuseAllows: true, snapshot: fleet)
        return plan
    }
    check("pass-to-pass: a dry account with a roomy sibling is still moved", rescue(overload: false)?.reason == "degraded")
    check("a capacity fallback is not a reason to move: same fleet, same watcher, no plan",
          rescue(overload: true) == nil)
    func profile(overload: Bool, applied: inout Bool) -> RelaunchPlan? {
        var plan: RelaunchPlan?
        applyFallbackProfile(plan: &plan, applied: &applied, watcher: &watcher, driftActive: false,
                             overloadActive: overload, policy: policy, account: account,
                             primaryModel: "sonnet")
        return plan
    }
    var applied = false
    check("a capacity fallback does not freeze the session on the fallback model",
          profile(overload: true, applied: &applied) == nil && !applied)
    check("pass-to-pass: the quota fallback profile still applies",
          profile(overload: false, applied: &applied)?.reason == "fallback" && applied)

    // MARK: - The watcher reads the event
    let reader = watcherAfterScanning([overloadReal])
    check("the real event is read", reader.lastOverloadFallback == OverloadFallbackEvent(
        at: launch.addingTimeInterval(60), from: "claude-sonnet-5-5", to: "claude-opus-5-5",
        trigger: "server_error", uuid: "c3f1a2b4-0000-4000-8000-00000000f001"))
    check("a sidechain one is not the session's",
          watcherAfterScanning([overloadReal.replacingOccurrences(
              of: "\"isSidechain\":false", with: "\"isSidechain\":true")]).lastOverloadFallback == nil)
    check("one from before this child launched is replayed history",
          watcherAfterScanning([overloadReal.replacingOccurrences(
              of: stamp(60), with: stamp(-60))]).lastOverloadFallback == nil)
    let answered = watcherAfterScanning([
        overloadReal,
        #"{"timestamp":"\#(stamp(90))","isSidechain":false,"type":"assistant","message":{"model":"claude-opus-5-5"}}"#,
    ])
    check("answers from the fallback model keep it", answered.lastOverloadFallback != nil)
    let back = watcherAfterScanning([
        overloadReal,
        #"{"timestamp":"\#(stamp(90))","isSidechain":false,"type":"assistant","message":{"model":"claude-opus-5-5"}}"#,
        #"{"timestamp":"\#(stamp(120))","isSidechain":false,"type":"assistant","message":{"model":"claude-sonnet-5-5"}}"#,
    ])
    check("the original model answering again clears it", back.lastOverloadFallback == nil)
    let refusal = watcherAfterScanning([
        #"{"isSidechain":false,"type":"system","subtype":"model_refusal_fallback","trigger":"refusal","originalModel":"claude-fable-5","fallbackModel":"claude-opus-4-8","apiRefusalCategory":"cyber","uuid":"r1","timestamp":"\#(stamp(60))"}"#,
    ])
    check("a safeguard fallback is a safeguard flag and not a capacity one",
          refusal.lastFlag != nil && refusal.lastOverloadFallback == nil)
    check("the capacity one raises no safeguard flag", reader.lastFlag == nil)

    // MARK: - The net, driven through its own tick
    let log = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-overload-log-\(UUID().uuidString).log")
    func tick(_ state: inout OverloadRevertState, mode: OverloadRevertMode = .auto, hook: Bool = true,
              event: OverloadFallbackEvent? = overloadEvent(), command: Date? = nil,
              dialog: Bool = false, at: Date = now, typed: inout [String],
              result: SessionInputInjection = .done) -> String? {
        applyOverloadRevert(&state, pid: "4242", event: event, actualModel: "claude-opus-5-5",
                            primaryModel: "sonnet", providerID: "claude", driftActive: false,
                            modelCommandAt: command, mode: mode, hookInstalled: hook,
                            typedAlready: false, session: .idle, quiet: .quiet, turnEnded: { true },
                            keyboardIdle: true, relaunchPlanned: false, draftSuspected: false,
                            waitingOnPerson: dialog, now: at, log: log,
                            inject: { text, _ in typed.append(text); return result })
    }
    func logText() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    var observed = OverloadRevertState(); var observedTyped: [String] = []
    check("observe: decided and logged, nothing typed",
          tick(&observed, mode: .observe, typed: &observedTyped) == nil && observedTyped.isEmpty
              && logText().contains("overload-revert=would-revert event=c3f1a2b4 model=sonnet"))
    var off = OverloadRevertState(); var offTyped: [String] = []
    check("off: nothing at all", tick(&off, mode: .off, typed: &offTyped) == nil && offTyped.isEmpty)
    var bare = OverloadRevertState(); var bareTyped: [String] = []
    check("auto without the hook observes", tick(&bare, hook: false, typed: &bareTyped) == nil
          && bareTyped.isEmpty && bare.brake.handled == [key])

    var acting = OverloadRevertState(); var typed: [String] = []
    check("auto with the hook types exactly the declared model, once",
          tick(&acting, typed: &typed) == "/model sonnet" && typed == ["/model sonnet"])
    check("the same event on the next tick types nothing",
          tick(&acting, at: now.addingTimeInterval(2), typed: &typed) == nil && typed.count == 1)
    check("a /model record after the typed line: done, and its stamp is handed on to be spent",
          tick(&acting, command: now.addingTimeInterval(3), at: now.addingTimeInterval(4), typed: &typed) == nil
              && acting.typedAt == nil && acting.confirmedCommandAt == now.addingTimeInterval(3)
              && logText().contains("overload-revert=done event=c3f1a2b4"))
    check("the line typed is the only thing typed: no digit, no Esc, no confirmation key",
          typed == ["/model sonnet"])

    var stuck = OverloadRevertState(); var stuckTyped: [String] = []
    _ = tick(&stuck, typed: &stuckTyped)
    check("nothing recorded within the window: stuck-confirm once, never retried",
          tick(&stuck, at: now.addingTimeInterval(overloadRevertConfirmWindow + 1), typed: &stuckTyped) == nil
              && logText().contains("overload-revert=stuck-confirm event=c3f1a2b4")
              && tick(&stuck, at: now.addingTimeInterval(300), typed: &stuckTyped) == nil
              && stuckTyped.count == 1)
    var dialog = OverloadRevertState(); var dialogTyped: [String] = []
    check("a possible dialog: nothing typed",
          tick(&dialog, dialog: true, typed: &dialogTyped) == nil && dialogTyped.isEmpty)
    var held = OverloadRevertState(); var heldTyped: [String] = []
    check("a hold from the terminal door keeps the event for the next tick",
          tick(&held, typed: &heldTyped, result: .held) == nil && held.brake.handled.isEmpty
              && tick(&held, at: now.addingTimeInterval(2), typed: &heldTyped) == "/model sonnet")
    let lines = logText()
    check("the log names a session, an event prefix and a model, and nothing of the conversation",
          lines.split(separator: "\n").allSatisfy {
              $0.contains("pid=4242 overload-revert=") && !$0.contains("/model")
          })

    // The adoption of a person's `/model` must not pin OUR switch: its stamp is spent first.
    var model = SessionModelState(sessionKey: "4242")
    model.servedModelCommandAt = acting.confirmedCommandAt
    var follow = FollowState(launchArgs: ["--model", "sonnet"])
    var confirmed = watcherAfterScanning([])
    confirmed.lastModelCommandAt = now.addingTimeInterval(3)
    check("our own switch is not adopted as a person's choice",
          !adoptNativeModelChoice(state: &model, follow: &follow, watcher: confirmed,
                                  primaryModel: "sonnet", launchArgs: ["--model", "sonnet"],
                                  now: now, log: testAuditLog))
    try? FileManager.default.removeItem(at: log)
    try? FileManager.default.removeItem(at: dir)
}
