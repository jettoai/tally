import Foundation

// The 2026-11-13 evening, replayed through the capacity-fallback decision. Structure only: no
// session id, no path, no conversation text. Each row is one `model_fallback` event (sonnet to
// opus, trigger=server_error) with its offset in seconds from the first, and the model of the LAST
// main-chain answer before the next event in that conversation or before the 22:36 cut-off (nil: no
// answer followed). The corpus is reproducible from ~/.claude/projects with the extraction in the
// B-4551 P4 plan (events with the file's mtime from 17:00, records cut at 22:36 local).
//
// Eight rows end on opus. Six of them are the windows Tally itself relaunched with `--model opus`
// within 10 to 20 seconds of the event (s03 s07 s09 s10 s28 s30; handoff.log `reason=fallback`),
// which is the failure (c) removes. The other two (s19, s31) were still on opus when the corpus was
// cut and are the same shape to the net, so it acts on them as well.

let overloadCorpus: [(id: String, offset: TimeInterval, last: String?)] = [
    ("s01", 0, "sonnet"), ("s02", 1, "sonnet"), ("s03", 1, "opus"), ("s04", 1693, "sonnet"),
    ("s05", 1696, "sonnet"), ("s06", 1696, "sonnet"), ("s07", 2087, "opus"), ("s08", 2090, "sonnet"),
    ("s09", 2091, "opus"), ("s10", 2092, "opus"), ("s11", 2094, "sonnet"), ("s12", 2094, "sonnet"),
    ("s13", 2098, "sonnet"), ("s14", 2103, "sonnet"), ("s15", 2109, "sonnet"), ("s16", 2109, "sonnet"),
    ("s17", 2111, "sonnet"), ("s18", 2111, "sonnet"), ("s19", 2116, "opus"), ("s20", 2124, "sonnet"),
    ("s21", 2125, "sonnet"), ("s22", 2127, "sonnet"), ("s23", 2128, "sonnet"), ("s24", 2129, "sonnet"),
    ("s25", 2132, "sonnet"), ("s26", 11099, "sonnet"), ("s27", 11105, "sonnet"), ("s28", 12824, "opus"),
    ("s29", 12825, nil), ("s30", 12827, "opus"), ("s31", 13504, "opus"),
]
let tallyRelaunched: Set<String> = ["s03", "s07", "s09", "s10", "s28", "s30"]
let stillOnOpus: Set<String> = tallyRelaunched.union(["s19", "s31"])

func runOverloadReplayChecks() {
    let now = launch.addingTimeInterval(20_000)
    func event(_ row: (id: String, offset: TimeInterval, last: String?)) -> OverloadFallbackEvent {
        OverloadFallbackEvent(at: launch.addingTimeInterval(row.offset), from: "claude-sonnet-5-5",
                              to: "claude-opus-5-5", trigger: "server_error", uuid: row.id)
    }
    func actual(_ row: (id: String, offset: TimeInterval, last: String?)) -> String? {
        row.last.map { "claude-\($0)-5-5" }
    }
    // Every decision below is fed the way the supervisor feeds it: the tick's attribution of the
    // event and what answered it, never the watcher's raw fields.
    func input(_ row: (id: String, offset: TimeInterval, last: String?),
               primary: String = "sonnet", ledger: ModelGapLedger = ModelGapLedger())
        -> OverloadRevertInput {
        OverloadRevertInput(
            gap: attributeModelGap(declared: primary, source: .app, executing: primary,
                                   facts: ModelGapFacts(observed: actual(row), overload: event(row)),
                                   ledger: ledger, quotaEvidence: { false }, now: now),
            providerID: "claude", quiet: true)
    }
    check("the corpus is the 31 events of the evening", overloadCorpus.count == 31)
    let acted = overloadCorpus.filter {
        if case .revert = overloadRevertDecision(input($0), brake: OverloadRevertBrake(), now: now) {
            return true
        }
        return false
    }
    check("the net acts on exactly the windows still on the fallback model",
          Set(acted.map(\.id)) == stillOnOpus && acted.count == 8)
    check("…which includes every window Tally relaunched onto opus",
          tallyRelaunched.isSubset(of: Set(acted.map(\.id))))
    check("every other event, including the one nothing followed, is left alone",
          overloadCorpus.filter { !stillOnOpus.contains($0.id) }.allSatisfy {
              overloadRevertDecision(input($0), brake: OverloadRevertBrake(), now: now) == .none("none")
          })
    check("a window whose declared model was opus all along is never touched",
          overloadCorpus.allSatisfy {
              if case .revert = overloadRevertDecision(input($0, primary: "opus"),
                                                       brake: OverloadRevertBrake(), now: now) {
                  return false
              }
              return true
          })
    check("each acted-on event is switched once: the same event again is handled",
          acted.allSatisfy { row in
              var ledger = ModelGapLedger()
              guard case let .revert(_, key) = overloadRevertDecision(
                  input(row, ledger: ledger), brake: OverloadRevertBrake(), now: now)
              else { return false }
              ledger.handleCapacity(key)
              return overloadRevertDecision(input(row, ledger: ledger), brake: OverloadRevertBrake(),
                                            now: now) == .none("handled")
          })
    check("(c): every event is explained at the moment it happened, so neither mover fires",
          overloadCorpus.allSatisfy {
              !degradationMoversMayAct(attributeModelGap(
                  declared: "sonnet", source: .app, executing: "sonnet",
                  facts: ModelGapFacts(observed: "claude-opus-5-5", overload: event($0)),
                  ledger: ModelGapLedger(), quotaEvidence: { false }, now: now))
          })

    // B-4551 step 5: the eight `overloaded` events of the last 60 days, structure only (the trigger,
    // sonnet to opus, the event's own time, and the model of the last answer after it; read off
    // b4551-s2-overloaded-structure). The old decision refused every one of them as `.none("trigger")`,
    // so the sessions that ended on opus stayed there. The switch back acts on exactly those.
    let overloadedRows: [(at: String, last: String)] = [
        ("2026-10-21T15:14:09.662Z", "opus"), ("2026-10-25T06:07:30.046Z", "opus"),
        ("2026-10-25T06:10:18.736Z", "opus"), ("2026-10-27T09:08:01.366Z", "sonnet"),
        ("2026-10-27T09:09:30.690Z", "sonnet"), ("2026-10-27T09:09:43.208Z", "sonnet"),
        ("2026-11-09T05:08:29.228Z", "sonnet"), ("2026-11-11T11:29:13.607Z", "opus"),
    ]
    var overloadedActed = [Int]()
    for (n, row) in overloadedRows.enumerated() {
        let overloaded = OverloadFallbackEvent(at: parseISO(row.at)!, from: "claude-sonnet-5-5",
                                               to: "claude-opus-5-5", trigger: "overloaded", uuid: "o\(n + 1)")
        let gap = attributeModelGap(declared: "sonnet", source: .app, executing: "sonnet",
                                    facts: ModelGapFacts(observed: "claude-\(row.last)-5-5", overload: overloaded),
                                    ledger: ModelGapLedger(), quotaEvidence: { false }, now: overloaded.at)
        let decision = overloadRevertDecision(OverloadRevertInput(gap: gap, providerID: "claude", quiet: true),
                                              brake: OverloadRevertBrake(), now: overloaded.at)
        if case .revert = decision { overloadedActed.append(n + 1) }
        check("S-E o\(n + 1) (\(row.last)): \(row.last == "opus" ? "reverted" : "left alone")",
              row.last == "opus" ? decision == .revert(model: "sonnet", eventKey: "o\(n + 1)")
                                 : decision == .none("none"))
    }
    check("the eight overloaded events: the switch back acts on the four that ended on opus",
          overloadedRows.count == 8 && overloadedActed == [1, 2, 3, 8])

    // The safeguard classifier's events: three in the real shape (trimmed from a live transcript,
    // varied only in uuid and category), one with a capacity event beside it and a drift active.
    let refusal = { (n: Int, category: String) in
        #"{"isSidechain":false,"type":"system","subtype":"model_refusal_fallback","trigger":"refusal","direction":"retry","originalModel":"claude-fable-5","fallbackModel":"claude-opus-4-8","apiRefusalCategory":"\#(category)","uuid":"refusal-\#(n)","timestamp":"\#(stamp(60))"}"#
    }
    for (n, category) in [(1, "cyber"), (2, "bio"), (3, "cyber")] {
        let watcher = watcherAfterScanning([refusal(n, category)])
        check("safeguard sample \(n): a flag and no capacity event, so no decision",
              watcher.lastFlag != nil && watcher.lastOverloadFallback == nil
                  && overloadRevertDecision(
                      OverloadRevertInput(
                          gap: attributeModelGap(
                              declared: "fable", source: .app, executing: "fable",
                              facts: ModelGapFacts(watcher: watcher, driftActive: true),
                              ledger: ModelGapLedger(), quotaEvidence: { false }, now: now),
                          providerID: "claude", quiet: true),
                      brake: OverloadRevertBrake(), now: now) == .none("none"))
    }
    check("a capacity event beside an active safeguard drift is never reverted",
          overloadRevertDecision(
              OverloadRevertInput(
                  gap: attributeModelGap(
                      declared: "sonnet", source: .app, executing: "sonnet",
                      facts: ModelGapFacts(observed: "claude-opus-5-5", overload: event(overloadCorpus[2]),
                                           safeguardActive: true),
                      ledger: ModelGapLedger(), quotaEvidence: { false }, now: now),
                  providerID: "claude", quiet: true),
              brake: OverloadRevertBrake(), now: now) == .none("safeguard"))
}
