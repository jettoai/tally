import Foundation

// The capacity fallback (`model_fallback`, any trigger): the reading that keeps the two
// degradation movers off it, and the safety net that types `/model` for a window left on the
// fallback model. The net reads the tick's attribution (ModelGapAttribution.swift), so each gate's
// counter-example below is a state the attribution reads, not a field the decision looks at.
// Top-level statements live in main.swift, so these run as one function it calls.

private let overloadReal = #"""
{"parentUuid":"6b0a53a8-7f36-4a3d-9c1a-0d2f3e4b5a69","isSidechain":false,"type":"system","subtype":"model_fallback","content":"Switched to Opus 5.5 due to high demand for Sonnet 5.5","level":"warning","trigger":"server_error","direction":"retry","originalModel":"claude-sonnet-5-5","fallbackModel":"claude-opus-5-5","requestId":"req_011Cg0000000000000000000","isMeta":false,"uuid":"c3f1a2b4-0000-4000-8000-00000000f001","timestamp":"\#(stamp(60))","userType":"external","entrypoint":"cli","cwd":"/w","sessionId":"s","version":"2.1.300"}
"""#

private func overloadEvent(at offset: TimeInterval = 60, uuid: String? = "c3f1a2b4-0000-4000-8000-00000000f001",
                           trigger: String = "server_error") -> OverloadFallbackEvent {
    OverloadFallbackEvent(at: launch.addingTimeInterval(offset), from: "claude-sonnet-5-5",
                          to: "claude-opus-5-5", trigger: trigger, uuid: uuid)
}

private func overloadGap(event: OverloadFallbackEvent? = overloadEvent(),
                         actual: String? = "claude-opus-5-5", primary: String? = "sonnet",
                         drift: Bool = false, command: Date? = nil,
                         ledger: ModelGapLedger = ModelGapLedger()) -> ModelGapAttribution {
    attributeModelGap(declared: primary, source: .app, executing: primary,
                      facts: ModelGapFacts(observed: actual, commandAt: command, overload: event,
                                           safeguardActive: drift),
                      ledger: ledger, quotaEvidence: { false }, now: launch.addingTimeInterval(600))
}

private func overloadInput(event: OverloadFallbackEvent? = overloadEvent(),
                           actual: String? = "claude-opus-5-5", primary: String? = "sonnet",
                           provider: String = "claude", drift: Bool = false,
                           command: Date? = nil, quiet: Bool = true,
                           ledger: ModelGapLedger = ModelGapLedger()) -> OverloadRevertInput {
    OverloadRevertInput(gap: overloadGap(event: event, actual: actual, primary: primary, drift: drift,
                                         command: command, ledger: ledger),
                        providerID: provider, quiet: quiet)
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
    check("no event: nothing is attributed to capacity", decide(overloadInput(event: nil))
          == .none("unexplained"))
    check("codex is never touched", decide(overloadInput(provider: "codex")) == .none("codex"))
    check("a safeguard drift is never reverted", decide(overloadInput(drift: true)) == .none("safeguard"))
    check("an unseen trigger is a capacity fallback too: the subtype says so, the trigger is a record",
          ["refusal", "overloaded", "server_error", "x"].allSatisfy {
              decide(overloadInput(event: overloadEvent(trigger: $0)))
                  == .revert(model: "sonnet", eventKey: "c3f1a2b4-0000-4000-8000-00000000f001")
          })
    check("a session the person pinned to opus is not this event's session",
          decide(overloadInput(primary: "opus")) == .none("none"))
    check("no declared model at all is nothing to switch back to, not a guess",
          decide(overloadInput(primary: nil)) == .none("none"))
    check("a /model nobody has served is the person's choice",
          decide(overloadInput(command: launch.addingTimeInterval(90))) == .none("person-command"))
    var servedLedger = ModelGapLedger()
    servedLedger.consumeCommand(at: launch.addingTimeInterval(30))
    check("a /model that was served before the event is not",
          decide(overloadInput(command: launch.addingTimeInterval(30), ledger: servedLedger))
              == .revert(model: "sonnet", eventKey: "c3f1a2b4-0000-4000-8000-00000000f001"))
    var typedInFlight = ModelGapLedger()
    typedInFlight.observeOverloadRevert(typedAt: launch.addingTimeInterval(590), typedModel: "sonnet",
                                   confirmedAt: nil)
    check("our own /model still in flight is nobody's to answer a second time",
          decide(overloadInput(ledger: typedInFlight)) == .none("own-command"))
    check("the original model answered again: recovered",
          decide(overloadInput(actual: "claude-sonnet-5-5")) == .none("none"))
    check("not quiet: wait", decide(overloadInput(quiet: false)) == .none("not-quiet"))
    check("an alias that is not typable never reaches the terminal",
          decide(overloadInput(primary: "claude-sonnet-5-5 x")) == .none("model-name"))
    let key = overloadEventKey(overloadEvent())
    var handledLedger = ModelGapLedger()
    handledLedger.handleCapacity(key)
    check("one switch per event", decide(overloadInput(ledger: handledLedger)) == .none("handled"))
    var capped = ModelGapLedger()
    for n in 0 ..< 20 { capped.handleCapacity("e\(n)") }
    check("the ledger keeps the newest 16 keys, and releasing one offers the event again",
          capped.handledCapacityKeys.count == 16 && capped.handledCapacityKeys.first == "e4" && {
              var released = handledLedger
              released.releaseCapacity(key)
              return decide(overloadInput(ledger: released)) == .revert(model: "sonnet", eventKey: key)
          }())
    let keyless = overloadEvent(uuid: nil)
    check("no uuid: the key is the event time",
          overloadEventKey(keyless) == ISO8601DateFormatter().string(from: keyless.at))

    // MARK: - Backoff and the hourly cap
    let switched = OverloadRevertBrake(reverts: [launch.addingTimeInterval(60)])
    let soon = overloadEvent(at: 60 + 5 * 60, uuid: "again")
    let braked = overloadRevertBrakeOnEvent(switched, at: soon.at)
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
          overloadRevertBrakeOnEvent(switched, at: overloadEvent(at: 60 + 11 * 60, uuid: "late").at)
              .notBefore == nil)
    check("brake-on-event is idempotent",
          overloadRevertBrakeOnEvent(braked, at: soon.at) == braked)
    let spent = OverloadRevertBrake(reverts: [0, 600, 1200].map { launch.addingTimeInterval($0) })
    check("three switches in the hour: capped",
          decide(overloadInput(), spent, at: launch.addingTimeInterval(1800)) == .none("hour-cap"))
    check("…and the oldest one an hour old frees a slot",
          decide(overloadInput(), spent, at: launch.addingTimeInterval(3600))
              == .revert(model: "sonnet", eventKey: key))

    // MARK: - (c): the movers stay off a capacity fallback
    // The movers read the attribution now (ModelGapAttribution.swift), so what these five asserted of
    // `overloadFallbackExplains` is asserted of the gap the movers are handed.
    func gapFor(_ event: OverloadFallbackEvent?, actual: String, declared: String) -> ModelGapAttribution {
        attributeModelGap(declared: declared, source: .app, executing: declared,
                          facts: ModelGapFacts(observed: actual, overload: event),
                          ledger: ModelGapLedger(), quotaEvidence: { true }, now: launch)
    }
    check("explained: server_error, serving the fallback model, primary is the original",
          !degradationMoversMayAct(gapFor(overloadEvent(), actual: "claude-opus-5-5", declared: "sonnet")))
    check("an unseen trigger is explained too: the subtype says capacity, the trigger is only recorded",
          !degradationMoversMayAct(gapFor(overloadEvent(trigger: "x"), actual: "claude-opus-5-5",
                                          declared: "sonnet")))
    check("a third model explains nothing",
          degradationMoversMayAct(gapFor(overloadEvent(), actual: "claude-haiku-5", declared: "sonnet")))
    check("a different primary explains nothing",
          degradationMoversMayAct(gapFor(overloadEvent(), actual: "claude-opus-5-5", declared: "fable")))
    check("no event explains nothing",
          degradationMoversMayAct(gapFor(nil, actual: "claude-opus-5-5", declared: "sonnet")))

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
    func rescue(gap: ModelGapAttribution) -> RelaunchPlan? {
        var plan: RelaunchPlan?
        applyDegradationRescue(plan: &plan, watcher: &watcher, gap: gap, policy: policy,
                               account: account, providerID: "claude", primaryModel: "sonnet",
                               quarantine: [:], steering: true, fuseAllows: true, snapshot: fleet)
        return plan
    }
    check("pass-to-pass: a dry account with a roomy sibling is still moved",
          rescue(gap: moversFree)?.reason == "degraded")
    check("a capacity fallback is not a reason to move: same fleet, same watcher, no plan",
          rescue(gap: capacityGap) == nil)
    func profile(gap: ModelGapAttribution, applied: inout Bool) -> RelaunchPlan? {
        var plan: RelaunchPlan?
        applyFallbackProfile(plan: &plan, applied: &applied, watcher: &watcher, gap: gap,
                             policy: policy, account: account, primaryModel: "sonnet")
        return plan
    }
    var applied = false
    check("a capacity fallback does not freeze the session on the fallback model",
          profile(gap: capacityGap, applied: &applied) == nil && !applied)
    check("pass-to-pass: the quota fallback profile still applies",
          profile(gap: moversFree, applied: &applied)?.reason == "fallback" && applied)

    // B-4551 step 2, on the real structure of the eight `overloaded` events of the last 60 days
    // (offset, trigger, sonnet to opus, and the model of the last answer after each; nothing of the
    // conversations). Four of them end on opus, and those are the four a Tally relaunch followed
    // (10-21, 10-25, 10-27 twice, handoff.log `reason=fallback`): the old explanation only knew
    // `server_error`, so the movers read them as quota.
    let overloadedEvents: [(id: String, last: String)] = [
        ("e1", "opus"), ("e2", "opus"), ("e3", "opus"), ("e4", "sonnet"),
        ("e5", "sonnet"), ("e6", "sonnet"), ("e7", "sonnet"), ("e8", "opus"),
    ]
    var sePlans = 0, seActing = 0
    for (n, row) in overloadedEvents.enumerated() {
        let event = OverloadFallbackEvent(at: launch.addingTimeInterval(Double(n) * 60),
                                          from: "claude-sonnet-5-5", to: "claude-opus-5-5",
                                          trigger: "overloaded", uuid: row.id)
        watcher.lastModel = "claude-\(row.last)-5-5"
        let gap = gapFor(event, actual: watcher.lastModel!, declared: "sonnet")
        var spent = false
        if rescue(gap: gap) != nil { sePlans += 1 }
        if profile(gap: gap, applied: &spent) != nil { sePlans += 1 }
        if row.last == "opus" {
            seActing += 1
            check("S-E \(row.id): an overloaded capacity fallback is the capacity cause",
                  { if case .capacity = gap.cause { return true } else { return false } }())
        }
    }
    check("S-E replay: eight overloaded events, four of them still on opus, and neither mover plans",
          overloadedEvents.count == 8 && seActing == 4 && sePlans == 0)
    watcher.lastModel = "claude-opus-5-5"
    // A person's `/model` the session has not answered yet is theirs to settle: the movers wait.
    let personAt = launch.addingTimeInterval(30)
    let pending = attributeModelGap(
        declared: "sonnet", source: .app, executing: "sonnet",
        facts: ModelGapFacts(observed: "claude-opus-5-5", commandAt: personAt),
        ledger: ModelGapLedger(), quotaEvidence: { true }, now: launch.addingTimeInterval(40))
    var pendingApplied = false
    check("a person's /model with no answer yet: neither mover plans",
          pending.cause == .personCommand(at: personAt, settled: nil)
              && rescue(gap: pending) == nil
              && profile(gap: pending, applied: &pendingApplied) == nil && !pendingApplied)
    var typedLedger = ModelGapLedger()
    typedLedger.observeOverloadRevert(typedAt: launch.addingTimeInterval(20), typedModel: "sonnet",
                                      confirmedAt: nil)
    let inFlight = attributeModelGap(
        declared: "sonnet", source: .app, executing: "sonnet",
        facts: ModelGapFacts(observed: "claude-opus-5-5"), ledger: typedLedger,
        quotaEvidence: { true }, now: launch.addingTimeInterval(30))
    check("our own /model still in flight: neither mover plans",
          rescue(gap: inFlight) == nil && profile(gap: inFlight, applied: &pendingApplied) == nil)
    check("control: the same opus answer with nothing else to explain it is still moved",
          rescue(gap: moversFree)?.reason == "degraded")

    // The order is part of the rule: attributed before the movers look, and handed to both.
    let supervisorText = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    func movers(_ opening: String) -> String {
        guard let start = supervisorText.range(of: opening),
              let end = supervisorText.range(of: ")\n", range: start.upperBound ..< supervisorText.endIndex)
        else { return "" }
        return String(supervisorText[start.lowerBound ..< end.upperBound])
    }
    check("the tick attributes the gap before either degradation mover runs", {
        guard let gap = supervisorText.range(of: "let gap = tickModelGap("),
              let rescue = supervisorText.range(of: "applyDegradationRescue(plan:"),
              let profile = supervisorText.range(of: "applyFallbackProfile(plan:") else { return false }
        return gap.lowerBound < rescue.lowerBound && rescue.lowerBound < profile.lowerBound
    }())
    check("both movers are handed the attribution and nothing is read off the drift monitor for them",
          movers("applyDegradationRescue(plan:").contains("gap: gap")
              && movers("applyFallbackProfile(plan:").contains("gap: gap")
              && !movers("applyDegradationRescue(plan:").contains("drift.isActive")
              && !movers("applyFallbackProfile(plan:").contains("drift.isActive")
              && !supervisorText.contains("overloadFallbackExplains"))

    // B-4551 step 5, as source locks (the repo's way to say "this code reads that and nothing else").
    // I6: the code that decides on a model gap does not read the raw signals the attribution is made
    // of. Comment lines are dropped, so prose may still name them.
    let rawSignals = ["lastOverloadFallback", "drift.isActive", "lastModelCommandAt", "modelConfirmation",
                      "lastFlag"]
    func codeLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }
    func code(of file: String) -> String {
        codeLines((try? String(contentsOfFile: "TallyCLI/\(file)", encoding: .utf8)) ?? "")
    }
    check("I6: the switch back and the degradation movers read no raw signal",
          ["OverloadFallback.swift", "OverloadRevert.swift", "ModelDegradation.swift"].allSatisfy { file in
              let text = code(of: file)
              return !text.isEmpty && !rawSignals.contains { text.contains($0) }
          })
    // The whole population: who reads the raw signals. These are the watcher, the drift monitor, the
    // attribution and the safeguard restore (which still reads the flag itself, B-4551 step 6 P3).
    // The supervisor is held to a narrower rule below: only where it FEEDS the attribution.
    let allowedReaders: Set<String> = ["TranscriptWatcher.swift", "TranscriptWatcherScan.swift",
                                       "TranscriptFork.swift", "DriftMonitor.swift", "SafeguardDrift.swift",
                                       "ModelGapAttribution.swift"]
    let swiftFiles = ((try? FileManager.default.contentsOfDirectory(atPath: "TallyCLI")) ?? [])
        .filter { $0.hasSuffix(".swift") }
    let readers = Set(swiftFiles.filter { file in
        let text = code(of: file)
        return file != "Supervisor.swift" && rawSignals.contains { text.contains($0) }
    })
    check("I6: the files that read the raw signals are the known ones", swiftFiles.count > 50
          && readers.isSubset(of: allowedReaders))
    // The supervisor reads them in ONE stretch: from the drift observation to the end of the
    // `tickModelGap` call, which is the station that feeds the attribution. Outside it the count is zero.
    let supervisorCode = codeLines(supervisorText)
    let feeding: (inside: String, outside: String)? = {
        guard let start = supervisorCode.range(of: "observeDrift("),
              let tick = supervisorCode.range(of: "let gap = tickModelGap(",
                                              range: start.upperBound ..< supervisorCode.endIndex),
              let end = supervisorCode.range(of: "writeLog:", range: tick.upperBound ..< supervisorCode.endIndex)
        else { return nil }
        return (String(supervisorCode[start.lowerBound ..< end.upperBound]),
                String(supervisorCode[supervisorCode.startIndex ..< start.lowerBound])
                    + String(supervisorCode[end.upperBound...]))
    }()
    check("I6: the supervisor reads the raw signals only where it feeds the attribution",
          feeding.map { stretch in
              stretch.inside.contains("lastModelCommandAt") && stretch.inside.contains("drift.isActive")
                  && !rawSignals.contains { stretch.outside.contains($0) }
          } == true)
    // The adoption of a person's `/model` reads the tick's attribution, and is handed it.
    let adoptionCode = String(code(of: "SessionModel.swift").split(separator: "\n", omittingEmptySubsequences: false)
        .drop { !$0.contains("func adoptNativeModelChoice(") }.joined(separator: "\n").prefix(5000))
    check("I6: the adoption asks the gap whose command it is, not the watcher",
          adoptionCode.contains("gap.owner == .adoption") && !adoptionCode.contains("modelCommandCause(")
              && !adoptionCode.contains("watcher.modelConfirmation"))
    check("I6: the tick hands the directives its gap", {
        guard let start = supervisorText.range(of: "applySessionDirectives(plan:"),
              let end = supervisorText.range(of: "heldElsewhere:", range: start.upperBound ..< supervisorText.endIndex)
        else { return false }
        return supervisorText[start.upperBound ..< end.lowerBound].contains("gap: gap")
    }())
    // I2: the line typed into the composer is the capacity cause's own evidence, decided from the gap.
    let revertCall: String = {
        guard let start = supervisorText.range(of: "applyOverloadRevert("),
              let end = supervisorText.range(of: "if reverted != nil {", range: start.upperBound ..< supervisorText.endIndex)
        else { return "" }
        return String(supervisorText[start.upperBound ..< end.lowerBound])
    }()
    let decisionCode = code(of: "OverloadRevert.swift")
    check("I2: the switch back is handed the tick's gap, and the ledger, and nothing off the watcher",
          revertCall.contains("gap: gap") && revertCall.contains("ledger: &sessionModelState.gap")
              && !rawSignals.contains { revertCall.contains($0) } && !revertCall.contains("watcher")
              && !revertCall.contains("effectivePrimary") && !revertCall.contains("actualModel"))
    check("I6: whether our typed line landed is read off the ledger's claim, not the watcher's record",
          decisionCode.contains("ledger.ownClaimedAt") && !decisionCode.contains("modelCommandArgsMatch"))
    check("I2: the decision acts on a capacity cause and its owner, with no trigger or model gate of its own",
          decisionCode.contains("guard case let .capacity(key, _) = input.gap.cause")
              && decisionCode.contains("input.gap.owner == .overloadRevert")
              && !decisionCode.contains("event.trigger") && !decisionCode.contains("modelsAgree"))

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
    // One tick as the supervisor runs it: our own `/model` is settled in the ledger, the gap is
    // attributed, and only then does the net look at it.
    func tick(_ state: inout OverloadRevertState, ledger: inout ModelGapLedger,
              mode: OverloadRevertMode = .auto, hook: Bool = true,
              event: OverloadFallbackEvent? = overloadEvent(), command: Date? = nil,
              dialog: Bool = false, at: Date = now, args: String? = "sonnet", drift: Bool = false,
              typed: inout [String], result: SessionInputInjection = .done) -> String? {
        ledger.settleOwnCommand(typedAt: state.ownCommandSince, typedModel: state.ownCommandModel,
                                confirmedAt: state.confirmedCommandAt, commandAt: command, args: args,
                                now: at)
        let gap = attributeModelGap(
            declared: "sonnet", source: .app, executing: "sonnet",
            facts: ModelGapFacts(observed: "claude-opus-5-5", commandAt: command, overload: event,
                                 safeguardActive: drift),
            ledger: ledger, quotaEvidence: { false }, now: at)
        return applyOverloadRevert(&state, ledger: &ledger, pid: "4242", gap: gap, providerID: "claude",
                            mode: mode, hookInstalled: hook,
                            typedAlready: false, session: .idle, quiet: .quiet, turnEnded: { true },
                            keyboardIdle: true, relaunchPlanned: false, draftSuspected: false,
                            waitingOnPerson: dialog, now: at, log: log,
                            inject: { text, _ in typed.append(text); return result })
    }
    func logText() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    var observed = OverloadRevertState(); var observedLedger = ModelGapLedger(); var observedTyped: [String] = []
    check("observe: decided and logged, nothing typed",
          tick(&observed, ledger: &observedLedger, mode: .observe, typed: &observedTyped) == nil && observedTyped.isEmpty
              && logText().contains("overload-revert=would-revert event=c3f1a2b4 model=sonnet"))
    var off = OverloadRevertState(); var offLedger = ModelGapLedger(); var offTyped: [String] = []
    check("off: nothing at all", tick(&off, ledger: &offLedger, mode: .off, typed: &offTyped) == nil && offTyped.isEmpty)
    var bare = OverloadRevertState(); var bareLedger = ModelGapLedger(); var bareTyped: [String] = []
    check("auto without the hook observes", tick(&bare, ledger: &bareLedger, hook: false, typed: &bareTyped) == nil
          && bareTyped.isEmpty && bareLedger.handledCapacityKeys == [key])

    var acting = OverloadRevertState(); var actingLedger = ModelGapLedger(); var typed: [String] = []
    check("auto with the hook types exactly the declared model, once",
          tick(&acting, ledger: &actingLedger, typed: &typed) == "/model sonnet" && typed == ["/model sonnet"])
    check("I2: what was typed hangs on the capacity cause's evidence",
          { if case .capacity = overloadGap().cause { return true } else { return false } }()
              && acting.typedKey == overloadGap().cause.evidence && acting.typedKey == key)
    check("the same event on the next tick types nothing",
          tick(&acting, ledger: &actingLedger, at: now.addingTimeInterval(2), typed: &typed) == nil && typed.count == 1)
    check("a /model record after the typed line: done, and its stamp is handed on to be spent",
          tick(&acting, ledger: &actingLedger, command: now.addingTimeInterval(3), at: now.addingTimeInterval(4), typed: &typed) == nil
              && acting.typedAt == nil && acting.confirmedCommandAt == now.addingTimeInterval(3)
              && logText().contains("overload-revert=done event=c3f1a2b4"))
    check("the line typed is the only thing typed: no digit, no Esc, no confirmation key",
          typed == ["/model sonnet"])

    var stuck = OverloadRevertState(); var stuckLedger = ModelGapLedger(); var stuckTyped: [String] = []
    _ = tick(&stuck, ledger: &stuckLedger, typed: &stuckTyped)
    check("nothing recorded within the window: stuck-confirm once, never retried",
          tick(&stuck, ledger: &stuckLedger, at: now.addingTimeInterval(overloadRevertConfirmWindow + 1), typed: &stuckTyped) == nil
              && logText().contains("overload-revert=stuck-confirm event=c3f1a2b4")
              && tick(&stuck, ledger: &stuckLedger, at: now.addingTimeInterval(300), typed: &stuckTyped) == nil
              && stuckTyped.count == 1)
    var dialog = OverloadRevertState(); var dialogLedger = ModelGapLedger(); var dialogTyped: [String] = []
    check("a possible dialog: nothing typed",
          tick(&dialog, ledger: &dialogLedger, dialog: true, typed: &dialogTyped) == nil && dialogTyped.isEmpty)
    var held = OverloadRevertState(); var heldLedger = ModelGapLedger(); var heldTyped: [String] = []
    check("a hold from the terminal door keeps the event for the next tick",
          tick(&held, ledger: &heldLedger, typed: &heldTyped, result: .held) == nil && heldLedger.handledCapacityKeys.isEmpty
              && tick(&held, ledger: &heldLedger, at: now.addingTimeInterval(2), typed: &heldTyped) == "/model sonnet")
    let lines = logText()
    check("the log names a session, an event prefix and a model, and nothing of the conversation",
          lines.split(separator: "\n").allSatisfy {
              $0.contains("pid=4242 overload-revert=") && !$0.contains("/model")
          })

    // OUR switch must not be pinned as a person's choice, in the order the tick really runs: the
    // scan reads the transcript, our stamp is spent, and only then does the adoption look at it.
    // The fixture is the incident sequence: our `/model`, a prompt, the reply of the model a
    // capacity fallback moved the window to, the next prompt (so the reply is a confirmation).
    func commandRecords(at offset: TimeInterval, args: String = "sonnet") -> [String] {
        [#"{"type":"user","isSidechain":false,"timestamp":"\#(stamp(offset))","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>\#(args)</command-args>"}}"#,
         #"{"type":"user","isSidechain":false,"timestamp":"\#(stamp(offset))","message":{"role":"user","content":"<local-command-stdout>Set model to \#("\\u001b[1mSonnet 5.5\\u001b[22m")</local-command-stdout>"}}"#]
    }
    let fallbackReply = #"{"parentUuid":"u-own1","type":"assistant","isSidechain":false,"uuid":"a-own","timestamp":"\#(stamp(612))","message":{"model":"claude-opus-5-5"}}"#
    let capacityLine = overloadReal.replacingOccurrences(of: stamp(60), with: stamp(611.5))
    let beforeCommand = commandRecords(at: 610) + [userLine(611, uuid: "u-own1", text: "go on")]
    let afterReply = [fallbackReply, userLine(613, uuid: "u-own2", text: "and then?")]

    var own = OverloadRevertState(); var ownLedger = ModelGapLedger(); var ownTyped: [String] = []
    check("typing our line starts the claim on its record",
          tick(&own, ledger: &ownLedger, at: launch.addingTimeInterval(605), typed: &ownTyped) == "/model sonnet"
              && own.ownCommandSince == launch.addingTimeInterval(605))
    let ownReply = watcherAfterScanning(beforeCommand + afterReply)
    check("the fixture: the reply of the model we moved off is the confirmation",
          ownReply.modelConfirmation?.model == "claude-opus-5-5")
    var owned = SessionModelState(sessionKey: "4242")
    var ownedFollow = FollowState(launchArgs: ["--model", "sonnet"])
    // The tick's claim: what the revert state says we typed, then the record it produced.
    owned.gap.settleOwnCommand(typedAt: own.ownCommandSince, typedModel: own.ownCommandModel,
                               confirmedAt: own.confirmedCommandAt,
                               commandAt: ownReply.lastModelCommandAt, args: ownReply.lastModelCommandArgs,
                               now: launch.addingTimeInterval(614))
    check("our own record is claimed once, before the adoption looks",
          owned.servedModelCommandAt == launch.addingTimeInterval(610) && owned.gap.ownCommandSince == nil)
    check("our own switch is not adopted as a person's choice, whatever answered after it",
          !adoptNativeModelChoice(state: &owned, follow: &ownedFollow, watcher: ownReply,
                                  primaryModel: "sonnet", launchArgs: ["--model", "sonnet"],
                                  now: now, log: testAuditLog)
              && owned.pin.model == nil)
    // The control, and the pre-fix order: the same transcript adopted first pins the reply's model.
    var control = SessionModelState(sessionKey: "4243")
    var controlFollow = FollowState(launchArgs: ["--model", "sonnet"])
    check("control: a person's /model with that same reply is still adopted",
          adoptNativeModelChoice(state: &control, follow: &controlFollow, watcher: ownReply,
                                 primaryModel: "sonnet", launchArgs: ["--model", "sonnet"],
                                 now: now, log: testAuditLog)
              && control.pin.model == "claude-opus-5-5")
    let supervisorSource = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift",
                                        encoding: .utf8)) ?? ""
    check("the tick claims our record before the directives adopt anything", {
        guard let claim = supervisorSource.range(of: "gap.settleOwnCommand("),
              let adopt = supervisorSource.range(of: "applySessionDirectives(plan:") else { return false }
        return claim.lowerBound < adopt.lowerBound
    }())

    // A record that lands after the stuck-confirm is still ours, within the window.
    check("stuck-confirm keeps the claim on a record that arrives late",
          stuck.typedAt == nil && stuck.ownCommandSince == now && {
              var ledger = ModelGapLedger()
              ledger.observeOverloadRevert(typedAt: stuck.ownCommandSince, typedModel: stuck.ownCommandModel,
                                           confirmedAt: nil)
              return ledger.claimOwnCommand(commandAt: launch.addingTimeInterval(800), args: "sonnet",
                                            now: launch.addingTimeInterval(801))
                  == launch.addingTimeInterval(800) && ledger.ownCommandSince == nil
          }())
    var noRecord = ModelGapLedger()
    noRecord.observeOverloadRevert(typedAt: now, typedModel: "sonnet", confirmedAt: nil)
    check("no record, or one older than our line: nothing claimed",
          noRecord.claimOwnCommand(commandAt: nil, args: nil, now: now.addingTimeInterval(5)) == nil
              && noRecord.claimOwnCommand(commandAt: now.addingTimeInterval(-5), args: "sonnet",
                                          now: now.addingTimeInterval(5)) == nil
              && noRecord.ownCommandSince == now)
    check("past the window a record is a person's, and the claim is dropped",
          noRecord.claimOwnCommand(commandAt: now.addingTimeInterval(400), args: "sonnet",
                                   now: now.addingTimeInterval(modelGapOwnRecordWindow + 1)) == nil
              && noRecord.ownCommandSince == nil)

    // B-4551, third round: T=0 we type, T=90 stuck-confirm keeps the claim open, T=100 a PERSON picks
    // another model. Time alone called that record ours, spent it, and the adoption skipped it for
    // good (no pin). The record's argument is what separates the two.
    let personReply = #"{"parentUuid":"u-per1","type":"assistant","isSidechain":false,"uuid":"a-per","timestamp":"\#(stamp(702))","message":{"model":"claude-opus-5-5"}}"#
    let personRecords = watcherAfterScanning(commandRecords(at: 700, args: "opus")
        + [userLine(701, uuid: "u-per1", text: "go on"), personReply,
           userLine(703, uuid: "u-per2", text: "and then?")])
    check("the fixture: a person's /model opus after our stuck line carries its own argument",
          personRecords.lastModelCommandArgs == "opus"
              && personRecords.modelConfirmation?.model == "claude-opus-5-5")
    var theirs = SessionModelState(sessionKey: "4245")
    var theirsFollow = FollowState(launchArgs: ["--model", "sonnet"])
    theirs.gap.settleOwnCommand(typedAt: stuck.ownCommandSince, typedModel: stuck.ownCommandModel,
                                confirmedAt: stuck.confirmedCommandAt,
                                commandAt: personRecords.lastModelCommandAt,
                                args: personRecords.lastModelCommandArgs,
                                now: launch.addingTimeInterval(705))
    check("a person's /model inside the stuck window is not claimed as ours",
          theirs.servedModelCommandAt == nil && theirs.gap.ownCommandSince != nil)
    check("…so the adoption pins it",
          adoptNativeModelChoice(state: &theirs, follow: &theirsFollow, watcher: personRecords,
                                 primaryModel: "sonnet", launchArgs: ["--model", "sonnet"],
                                 now: launch.addingTimeInterval(705), log: testAuditLog)
              && theirs.pin.model == "claude-opus-5-5")
    // The adoption obeys the gap it is handed, not the watcher: the same confirmed record of a person's
    // is adopted under an attribution that gives it to the adoption, and left alone under any other.
    let handed = attributeModelGap(declared: "sonnet", source: .app, executing: "sonnet",
                                   facts: ModelGapFacts(watcher: personRecords, driftActive: false),
                                   ledger: ModelGapLedger(), quotaEvidence: { false },
                                   now: launch.addingTimeInterval(705))
    check("the fixture: the tick's attribution of that record is the adoption's, with the confirming stamp",
          handed.owner == .adoption && handed.confirmedAt != nil
              && handed.confirmedAt == personRecords.modelConfirmation?.at)
    func adoptedUnder(_ gap: ModelGapAttribution) -> Bool {
        var state = SessionModelState(sessionKey: "4246")
        var follow = FollowState(launchArgs: ["--model", "sonnet"])
        return adoptNativeModelChoice(state: &state, follow: &follow, watcher: personRecords, gap: gap,
                                      primaryModel: "sonnet", launchArgs: ["--model", "sonnet"],
                                      now: launch.addingTimeInterval(705), log: testAuditLog)
    }
    check("control: handed that attribution the adoption pins it", adoptedUnder(handed))
    check("a person's /model the gap gives to somebody else is not adopted",
          !adoptedUnder(ModelGapAttribution(declared: handed.declared, declaredSource: handed.declaredSource,
                                            executing: handed.executing, observed: handed.observed,
                                            cause: handed.cause, owner: .nobody,
                                            confirmedAt: handed.confirmedAt)))
    check("…and neither is one the gap does not see at all, whatever the watcher holds",
          !adoptedUnder(ModelGapAttribution(declared: "sonnet", declaredSource: .app, executing: "sonnet",
                                            observed: nil, cause: .none, owner: .nobody)))
    var elsewhere = OverloadRevertState(); var elsewhereLedger = ModelGapLedger(); var elsewhereTyped: [String] = []
    _ = tick(&elsewhere, ledger: &elsewhereLedger, typed: &elsewhereTyped)
    _ = tick(&elsewhere, ledger: &elsewhereLedger, command: now.addingTimeInterval(30), at: now.addingTimeInterval(31),
             args: "opus", typed: &elsewhereTyped)
    check("a record naming another model is not the confirmation of our line",
          elsewhere.confirmedCommandAt == nil && elsewhere.typedAt != nil)

    // The watcher half: a reply served by a capacity fallback is never a confirmation, so neither
    // our switch nor a person's is pinned to it whichever way the tick runs.
    let viaFallback = watcherAfterScanning(beforeCommand + [capacityLine] + afterReply)
    check("a reply served by a capacity fallback confirms nothing",
          viaFallback.lastOverloadFallback != nil && viaFallback.modelConfirmation == nil)
    var viaState = SessionModelState(sessionKey: "4244")
    var viaFollow = FollowState(launchArgs: ["--model", "sonnet"])
    check("…and the adoption alone, with no stamp spent, pins nothing from it",
          !adoptNativeModelChoice(state: &viaState, follow: &viaFollow, watcher: viaFallback,
                                  primaryModel: "sonnet", launchArgs: ["--model", "sonnet"],
                                  now: now, log: testAuditLog)
              && viaState.pin.model == nil)
    let fallbackFirst = watcherAfterScanning([capacityLine.replacingOccurrences(of: stamp(611.5),
                                                                                with: stamp(605))]
        + beforeCommand + afterReply)
    check("a capacity fallback from BEFORE the command does not hold its answer back",
          fallbackFirst.modelConfirmation?.model == "claude-opus-5-5")
    try? FileManager.default.removeItem(at: log)
    try? FileManager.default.removeItem(at: dir)
}
