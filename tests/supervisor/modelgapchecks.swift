import Foundation

// The gap attribution (ModelGapAttribution.swift), driven by the 31 events of 2026-11-13 that
// overloadreplaychecks.swift already replays through the old decision, so "the old decision and the
// new cause agree" is asserted on real structure, not on a fixture written for the new code.

func runModelGapChecks() {
    let now = launch.addingTimeInterval(20_000)
    let sonnet = "claude-sonnet-5-5", opus = "claude-opus-5-5"
    typealias Row = (id: String, offset: TimeInterval, last: String?)

    func event(_ row: Row, trigger: String = "server_error") -> OverloadFallbackEvent {
        OverloadFallbackEvent(at: launch.addingTimeInterval(row.offset), from: sonnet, to: opus,
                              trigger: trigger, uuid: row.id)
    }
    func facts(_ row: Row, trigger: String = "server_error") -> ModelGapFacts {
        ModelGapFacts(observed: row.last.map { "claude-\($0)-5-5" }, overload: event(row, trigger: trigger))
    }
    func attribute(_ facts: ModelGapFacts, declared: String? = "sonnet",
                   source: DeclarationSource = .project, ledger: ModelGapLedger = ModelGapLedger(),
                   quota: Bool = false) -> ModelGapAttribution {
        attributeModelGap(declared: declared, source: source, executing: declared, facts: facts,
                          ledger: ledger, quotaEvidence: { quota }, now: now)
    }

    // MARK: the 31 events

    let corpus = overloadCorpus
    let causes = corpus.map { attribute(facts($0)) }
    func isCapacity(_ a: ModelGapAttribution) -> Bool {
        if case .capacity = a.cause { return true }
        return false
    }
    check("replay: 8 events end on the fallback model and are attributed to capacity",
          causes.filter(isCapacity).count == 8
              && Set(zip(corpus, causes).filter { isCapacity($0.1) }.map(\.0.id)) == stillOnOpus)
    check("replay: the other 23, including the one nothing followed, are none",
          zip(corpus, causes).filter { !stillOnOpus.contains($0.0.id) }.allSatisfy { $0.1.cause == .none })
    check("replay: the movers may act on none of them, whichever side of the gap they stand on",
          zip(corpus, causes).allSatisfy { row, attribution in
              // Nothing observed or an agreeing answer leaves the movers their own gate; a capacity
              // cause is not theirs.
              isCapacity(attribution) ? !degradationMoversMayAct(attribution)
                  : attribution.cause == .none && attribution.declared != nil
          })
    check("replay: the old switch back and the new owner agree on every event",
          zip(corpus, causes).allSatisfy { row, attribution in
              let old = overloadRevertDecision(
                  OverloadRevertInput(event: event(row), actualModel: row.last.map { "claude-\($0)-5-5" },
                                      primaryModel: "sonnet", providerID: "claude",
                                      safeguardDriftActive: false, modelCommandAt: nil, quiet: true),
                  brake: OverloadRevertBrake(), now: now)
              if case .revert = old { return attribution.owner == .overloadRevert }
              return attribution.owner == .nobody
          })
    check("replay: no event is left to the degradation movers (the old gates never let one through)",
          causes.allSatisfy { $0.owner != .degradationMovers })
    check("a handled capacity key hands the owner to nobody",
          {
              var ledger = ModelGapLedger()
              ledger.mirror(reasserted: false, handled: ["s03"], now: now)
              return attribute(facts(corpus[2]), ledger: ledger).owner == .nobody
          }())

    // The trigger is not a whitelist: 4 of the 8 fallback relaunches since October carried
    // `overloaded`, which the old explanation read as quota.
    let overloaded = attribute(facts(corpus[2], trigger: "overloaded"))
    check("an unseen trigger is still a capacity cause",
          isCapacity(overloaded) && overloaded.owner == .overloadRevert
              && !degradationMoversMayAct(overloaded))

    // MARK: log: one line per change of cause

    let log = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-modelgap-\(getpid()).log")
    try? FileManager.default.removeItem(at: log)
    var ledger = ModelGapLedger()
    var expected = 0
    var previous = GapCause.none.name
    for (row, cause) in zip(corpus, causes) {
        let key = cause.cause.name + (cause.cause.evidence.map { ":" + $0 } ?? "")
        if key != previous { expected += 1 }
        previous = key
        observeModelGap(ledger: &ledger, declared: "sonnet", source: .project, executing: "sonnet",
                        facts: facts(row), sessionID: "0123456789abcdef", quotaEvidence: { false },
                        now: now, log: log)
    }
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    let lines = text.split(separator: "\n")
    check("a change of cause is one line, and a session that stays on none writes nothing",
          lines.count == expected && expected > 8 && lines.allSatisfy { $0.contains(" model-gap=") })
    check("the line names the session, the three models, the evidence prefix and the owner",
          lines.contains {
              $0.contains(" session=01234567 ") && $0.contains(" model-gap=capacity ")
                  && $0.contains(" declared=sonnet executing=sonnet observed=\(opus) ")
                  && $0.contains(" owner=overloadRevert")
          })
    check("…and nothing of the conversation, and no em dash", !text.contains("\u{2014}"))
    try? FileManager.default.removeItem(at: log)

    // MARK: the other causes, one real shape each

    let refusal = #"{"isSidechain":false,"type":"system","subtype":"model_refusal_fallback","trigger":"refusal","direction":"retry","originalModel":"claude-fable-5","fallbackModel":"claude-opus-4-8","apiRefusalCategory":"cyber","uuid":"refusal-1","timestamp":"\#(stamp(60))"}"#
    let flagged = watcherAfterScanning([refusal])
    var flaggedFacts = ModelGapFacts(watcher: flagged, driftActive: true)
    flaggedFacts.observed = "claude-opus-4-8"
    let safeguard = attribute(flaggedFacts, declared: "fable")
    check("a safeguard fallback is the safeguard restore's, and never a capacity or quota cause",
          safeguard.cause == .safeguard(eventKey: "refusal-1") && safeguard.owner == .safeguardRestore)
    check("the same watcher with no drift active and nothing else observed is unexplained",
          attribute(ModelGapFacts(observed: "claude-opus-4-8"), declared: "fable").cause
              == .unexplained(quotaEvidence: false))
    check("unexplained carries the quota evidence it was handed, and is the movers' today",
          attribute(ModelGapFacts(observed: "claude-opus-4-8"), declared: "fable", quota: true).cause
              == .unexplained(quotaEvidence: true)
              && attribute(ModelGapFacts(observed: "claude-opus-4-8"), declared: "fable").owner
              == .degradationMovers)
    check("nothing observed yet, or an observation that agrees, is none",
          attribute(ModelGapFacts()).cause == .none
              && attribute(ModelGapFacts(observed: sonnet)).cause == .none
              && attribute(ModelGapFacts(observed: opus), declared: nil).cause == .none)

    var rewritten = ModelGapLedger()
    rewritten.noteRelaunch(reason: "fallback", model: "claude-haiku-4-5", at: launch)
    check("a child we spawned on another model is an execution rewrite, owned by nobody",
          attribute(ModelGapFacts(observed: "claude-haiku-4-5"), ledger: rewritten).cause
              == .executionRewrite(reason: "fallback", model: "claude-haiku-4-5", at: launch)
              && attribute(ModelGapFacts(observed: "claude-haiku-4-5"), ledger: rewritten).owner == .nobody)
    var cleared = rewritten
    cleared.noteRelaunch(reason: "follow", model: "sonnet", at: launch)
    check("a follow relaunch clears the rewrite; a cap handoff does not",
          cleared.rewrite == nil && { () -> Bool in
              var kept = rewritten
              kept.noteRelaunch(reason: "cap", model: nil, at: launch)
              return kept.rewrite != nil
          }())

    var restated = ModelGapLedger()
    restated.mirror(reasserted: true, handled: [], now: now)
    check("a restated profile is the follow's, ahead of any gap",
          attribute(ModelGapFacts(observed: opus), ledger: restated).cause
              == .declarationMoved(source: .project)
              && attribute(ModelGapFacts(observed: opus), ledger: restated).owner == .follow)
    var moved = ModelGapLedger()
    moved.noteTick(spawnedAt: launch, declared: "sonnet", source: .project)
    check("a new default the child was not spawned for is a moved declaration, until it runs it",
          attributeModelGap(declared: "opus", source: .app, executing: "sonnet", facts: ModelGapFacts(),
                            ledger: moved, quotaEvidence: { false }, now: now).cause
              == .declarationMoved(source: .app)
              && attributeModelGap(declared: "opus", source: .app, executing: "opus",
                                   facts: ModelGapFacts(), ledger: moved, quotaEvidence: { false },
                                   now: now).cause == .none)
    var pinned = ModelGapLedger()
    pinned.noteTick(spawnedAt: launch, declared: "sonnet", source: .project)
    pinned.noteTick(spawnedAt: launch, declared: "opus", source: .pin)
    check("a pin re-bases the declaration, so adopting a /model is not a moved declaration",
          attributeModelGap(declared: "opus", source: .pin, executing: "sonnet", facts: ModelGapFacts(),
                            ledger: pinned, quotaEvidence: { false }, now: now).cause == .none)

    // MARK: whose command it is

    var typed = ModelGapLedger()
    typed.observeOverloadRevert(typedAt: launch.addingTimeInterval(605), typedModel: "sonnet", confirmedAt: nil)
    check("our typed line is an own command while its record has not arrived",
          modelCommandCause(commandAt: nil, confirmation: nil, ledger: typed,
                            now: launch.addingTimeInterval(610)) == .ownCommand(since: launch.addingTimeInterval(605)))
    check("past the window nothing claims it any more",
          modelCommandCause(commandAt: nil, confirmation: nil, ledger: typed,
                            now: launch.addingTimeInterval(605 + modelGapOwnRecordWindow + 1)) == nil)
    check("a record older than our line is not ours",
          typed.claimOwnCommand(commandAt: launch.addingTimeInterval(600), args: "sonnet",
                                now: launch.addingTimeInterval(610)) == nil)
    check("a record naming another model, or none, inside the window is a person's and is left alone",
          typed.claimOwnCommand(commandAt: launch.addingTimeInterval(610), args: "opus",
                                now: launch.addingTimeInterval(611)) == nil
              && typed.claimOwnCommand(commandAt: launch.addingTimeInterval(610), args: nil,
                                       now: launch.addingTimeInterval(611)) == nil
              && typed.servedCommandAt == nil && typed.ownCommandSince != nil
              && modelCommandCause(commandAt: launch.addingTimeInterval(610), confirmation: nil,
                                   ledger: typed, now: launch.addingTimeInterval(611))
              == .personCommand(at: launch.addingTimeInterval(610), settled: nil))
    check("the record of our line is claimed once, and what it was is an own command until it settles",
          typed.claimOwnCommand(commandAt: launch.addingTimeInterval(610), args: "Sonnet",
                                now: launch.addingTimeInterval(611)) == launch.addingTimeInterval(610)
              && typed.servedCommandAt == launch.addingTimeInterval(610)
              && modelCommandCause(commandAt: launch.addingTimeInterval(610), confirmation: nil,
                                   ledger: typed, now: launch.addingTimeInterval(612))
              == .ownCommand(since: launch.addingTimeInterval(610))
              && modelCommandCause(commandAt: launch.addingTimeInterval(610), confirmation: opus,
                                   ledger: typed, now: launch.addingTimeInterval(612)) == nil
              && typed.claimOwnCommand(commandAt: launch.addingTimeInterval(610), args: "sonnet",
                                       now: launch.addingTimeInterval(613)) == nil)
    check("a record nobody served is a person's, and settled once an answer confirms it",
          modelCommandCause(commandAt: launch.addingTimeInterval(30), confirmation: nil,
                            ledger: ModelGapLedger(), now: now)
              == .personCommand(at: launch.addingTimeInterval(30), settled: nil)
              && modelCommandCause(commandAt: launch.addingTimeInterval(30), confirmation: opus,
                                   ledger: ModelGapLedger(), now: now)
              == .personCommand(at: launch.addingTimeInterval(30), settled: opus))
    var spent = ModelGapLedger()
    spent.consumeCommand(at: launch.addingTimeInterval(30))
    check("a consumed record is nobody's, and a newer one is a person's again",
          modelCommandCause(commandAt: launch.addingTimeInterval(30), confirmation: opus,
                            ledger: spent, now: now) == nil
              && modelCommandCause(commandAt: launch.addingTimeInterval(40), confirmation: nil,
                                   ledger: spent, now: now)
              == .personCommand(at: launch.addingTimeInterval(40), settled: nil))

    // MARK: the whole function, every cell

    // Dimensions, not a sample: own command x person command x moved declaration x safeguard x
    // capacity event x execution rewrite x observation x quota evidence. The reference below is the
    // priority list written as data, in a different shape from the function it checks.
    let haiku = "claude-haiku-4-5", fable = "claude-fable-5"
    let commandAt = launch.addingTimeInterval(700)
    var cells = 0, wrong: [String] = []
    for own in 0 ... 2 {
        for person in 0 ... 2 {
            if own == 2 && person != 0 { continue }
            for moved in [false, true] {
                for safe in [false, true] {
                    for cap in [false, true] {
                        for rewrite in [false, true] {
                            for observed in [nil, sonnet, opus, haiku, fable] as [String?] {
                                for quota in [false, true] {
                                    var ledger = ModelGapLedger()
                                    var f = ModelGapFacts(observed: observed)
                                    if own == 1 {
                                        ledger.observeOverloadRevert(typedAt: now.addingTimeInterval(-10), typedModel: "sonnet",
                                                                     confirmedAt: nil)
                                    }
                                    if own == 2 {
                                        ledger.observeOverloadRevert(typedAt: nil, typedModel: nil, confirmedAt: commandAt)
                                        f.commandAt = commandAt
                                    }
                                    if person != 0 {
                                        f.commandAt = commandAt
                                        f.confirmation = person == 2 ? opus : nil
                                    }
                                    if moved { ledger.mirror(reasserted: true, handled: [], now: now) }
                                    f.safeguardActive = safe
                                    f.safeguardKey = safe ? "flag" : nil
                                    if cap { f.overload = event(corpus[0]) }
                                    if rewrite { ledger.noteRelaunch(reason: "safeguard", model: haiku, at: launch) }
                                    let got = attributeModelGap(declared: sonnet, source: .project,
                                                                executing: sonnet, facts: f, ledger: ledger,
                                                                quotaEvidence: { quota }, now: now).cause.name
                                    // The reference: first rule that holds.
                                    let rules: [(String, Bool)] = [
                                        ("person-command", person != 0),
                                        ("own-command", own != 0),
                                        ("declaration-moved", moved),
                                        ("none", observed == nil || observed == sonnet),
                                        ("safeguard", safe),
                                        ("capacity", cap && observed == opus),
                                        ("execution-rewrite", rewrite && observed == haiku),
                                        ("unexplained", true),
                                    ]
                                    let want = rules.first { $0.1 }!.0
                                    cells += 1
                                    if got != want && wrong.count < 3 {
                                        wrong.append("own=\(own) person=\(person) moved=\(moved) safe=\(safe) cap=\(cap) rewrite=\(rewrite) observed=\(observed ?? "nil"): \(got) != \(want)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    check("every cell of the attribution agrees with the priority list (\(cells) cells)",
          wrong.isEmpty && cells == 2 * 2 * 2 * 2 * 5 * 2 * 7)
    if !wrong.isEmpty { print("modelgap cells that differ: \(wrong)") }

    // MARK: one writer

    // The served-command stamp has one writer, the ledger: the adoption and the claim of our own
    // record both spend it through the ledger's methods, so no second file can spend it differently
    // (the 6aad49a4 case had three writers in two files). Read off the sources, which is how this
    // suite already states "nobody else writes this".
    let sourceDir = "TallyCLI"
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: sourceDir)) ?? [])
        .filter { $0.hasSuffix(".swift") }
    var writers: [String] = []
    for file in files where file != "ModelGapAttribution.swift" {
        let text = (try? String(contentsOfFile: "\(sourceDir)/\(file)", encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            if line.range(of: #"\bserved(Model)?CommandAt\s*=[^=]"#, options: .regularExpression) != nil {
                writers.append("\(file): \(line)")
            }
        }
    }
    check("the suite reads the sources it scans", files.count > 100)
    check("nothing outside the ledger writes the served-command stamp", writers.isEmpty)
    let supervisorText = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor loop no longer carries a claim of its own",
          !supervisorText.contains("ownModelCommandStamp") && !supervisorText.contains("servedModelCommandAt"))
}
