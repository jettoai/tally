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

private let overloadCorpus: [(id: String, offset: TimeInterval, last: String?)] = [
    ("s01", 0, "sonnet"), ("s02", 1, "sonnet"), ("s03", 1, "opus"), ("s04", 1693, "sonnet"),
    ("s05", 1696, "sonnet"), ("s06", 1696, "sonnet"), ("s07", 2087, "opus"), ("s08", 2090, "sonnet"),
    ("s09", 2091, "opus"), ("s10", 2092, "opus"), ("s11", 2094, "sonnet"), ("s12", 2094, "sonnet"),
    ("s13", 2098, "sonnet"), ("s14", 2103, "sonnet"), ("s15", 2109, "sonnet"), ("s16", 2109, "sonnet"),
    ("s17", 2111, "sonnet"), ("s18", 2111, "sonnet"), ("s19", 2116, "opus"), ("s20", 2124, "sonnet"),
    ("s21", 2125, "sonnet"), ("s22", 2127, "sonnet"), ("s23", 2128, "sonnet"), ("s24", 2129, "sonnet"),
    ("s25", 2132, "sonnet"), ("s26", 11099, "sonnet"), ("s27", 11105, "sonnet"), ("s28", 12824, "opus"),
    ("s29", 12825, nil), ("s30", 12827, "opus"), ("s31", 13504, "opus"),
]
private let tallyRelaunched: Set<String> = ["s03", "s07", "s09", "s10", "s28", "s30"]
private let stillOnOpus: Set<String> = tallyRelaunched.union(["s19", "s31"])

func runOverloadReplayChecks() {
    let now = launch.addingTimeInterval(20_000)
    func event(_ row: (id: String, offset: TimeInterval, last: String?)) -> OverloadFallbackEvent {
        OverloadFallbackEvent(at: launch.addingTimeInterval(row.offset), from: "claude-sonnet-5-5",
                              to: "claude-opus-5-5", trigger: "server_error", uuid: row.id)
    }
    func actual(_ row: (id: String, offset: TimeInterval, last: String?)) -> String? {
        row.last.map { "claude-\($0)-5-5" }
    }
    func input(_ row: (id: String, offset: TimeInterval, last: String?),
               primary: String = "sonnet") -> OverloadRevertInput {
        OverloadRevertInput(event: event(row), actualModel: actual(row), primaryModel: primary,
                            providerID: "claude", safeguardDriftActive: false, modelCommandAt: nil,
                            quiet: true)
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
              overloadRevertDecision(input($0), brake: OverloadRevertBrake(), now: now)
                  == .none("recovered")
          })
    check("a window whose declared model was opus all along is never touched",
          overloadCorpus.allSatisfy {
              overloadRevertDecision(input($0, primary: "opus"), brake: OverloadRevertBrake(), now: now)
                  == .none("primary-mismatch")
          })
    check("each acted-on event is switched once: the same event again is handled",
          acted.allSatisfy { row in
              var brake = OverloadRevertBrake()
              guard case let .revert(_, key) = overloadRevertDecision(input(row), brake: brake, now: now)
              else { return false }
              brake.handled.append(key)
              return overloadRevertDecision(input(row), brake: brake, now: now) == .none("handled")
          })
    check("(c): every event is explained at the moment it happened, so neither mover fires",
          overloadCorpus.allSatisfy {
              overloadFallbackExplains(event: event($0), actualModel: "claude-opus-5-5",
                                       primaryModel: "sonnet")
          })

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
                      OverloadRevertInput(event: watcher.lastOverloadFallback,
                                          actualModel: "claude-opus-4-8", primaryModel: "fable",
                                          providerID: "claude", safeguardDriftActive: true,
                                          modelCommandAt: nil, quiet: true),
                      brake: OverloadRevertBrake(), now: now) == .none("no-event"))
    }
    check("a capacity event beside an active safeguard drift is never reverted",
          overloadRevertDecision(
              OverloadRevertInput(event: event(overloadCorpus[2]), actualModel: "claude-opus-5-5",
                                  primaryModel: "sonnet", providerID: "claude",
                                  safeguardDriftActive: true, modelCommandAt: nil, quiet: true),
              brake: OverloadRevertBrake(), now: now) == .none("safeguard"))
}
