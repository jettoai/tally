import Foundation

// WHAT TALLY TYPED, AND WHEN (TallyCLI/AutomaticInput.swift). Claude Code records Tally's own lines
// and a person's prompts the same way, so the cap resume budget tells them apart by the ledger the
// supervisor keeps of its own writes. Every failure leans towards "not a person".
func runAutomaticInputChecks() {
    let t = Date(timeIntervalSince1970: 1_791_000_000)
    var ledger = AutomaticInputLedger(knownSince: t.addingTimeInterval(-3600))
    ledger.note(start: t.addingTimeInterval(-1), end: t)

    check("AI1 the ledger explains a turn landing 18.4s after a write",
          ledger.explains(t.addingTimeInterval(18.4)))
    check("AI2 …not one landing 61s after it", !ledger.explains(t.addingTimeInterval(61)))
    check("AI3 a turn before knownSince is explained",
          ledger.explains(t.addingTimeInterval(-3601)))
    check("the lag is the measured worst case with room to spare", automaticTurnLag == 60)

    var full = AutomaticInputLedger(knownSince: t)
    for i in 0...automaticInputLedgerCap {
        let end = t.addingTimeInterval(Double(i) * 600)
        full.note(start: end.addingTimeInterval(-1), end: end)
    }
    check("AI4 dropping the oldest write moves knownSince past it",
          full.writes.count == automaticInputLedgerCap
              && full.knownSince == t.addingTimeInterval(automaticTurnLag)
              && full.explains(t.addingTimeInterval(30)))

    var both = AutomaticInputLedger(knownSince: t.addingTimeInterval(-3600))
    both.note(start: t.addingTimeInterval(-1), end: t)
    both.note(start: t.addingTimeInterval(199), end: t.addingTimeInterval(200))
    check("AI5 lastPersonTurn finds the person behind a later automatic line",
          lastPersonTurn([t.addingTimeInterval(120), t.addingTimeInterval(200)], automatic: both)
              == t.addingTimeInterval(120))
    check("…and finds nobody when every turn is Tally's own",
          lastPersonTurn([t.addingTimeInterval(2), t.addingTimeInterval(205)], automatic: both)
              == nil)

    let saved = automaticInputLedger
    defer { automaticInputLedger = saved }
    automaticInputLedger = AutomaticInputLedger(knownSince: t)
    _ = injectSessionInput("x", draft: .none, tty: "/dev/null", gap: 0, pause: 0)
    check("AI6 injectSessionInput records a write even when the terminal refuses it",
          automaticInputLedger.writes.count == 1)
}
