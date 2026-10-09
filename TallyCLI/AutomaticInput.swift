import Foundation

// WHAT TALLY ITSELF TYPED INTO THIS TERMINAL, and when: the record that tells a person's prompt from
// one of Tally's. Claude Code writes both the same way (`promptSource: "typed"`, `origin.kind:
// "human"`), so nothing in the transcript can make the distinction; the supervisor can, because
// every byte it types goes through `injectSessionInput`.

/// How long after a write ends its prompt may still be landing in the transcript. Measured
/// 2026-10-10 over 79 automatic resume lines: from the decision to type to the transcript stamp,
/// p50 1.8s, p95 6.8s, max 18.4s. Three times the worst seen. A person who types inside this
/// window after an automatic line is not counted, which only ever withholds a budget reset.
let automaticTurnLag: TimeInterval = 60

/// How many writes the ledger keeps. Forgetting one moves `knownSince` past it, so a turn it would
/// have explained is never promoted to a person's.
let automaticInputLedgerCap = 64

struct AutomaticWrite: Equatable { let start: Date; let end: Date }

struct AutomaticInputLedger: Equatable {
    /// Before this instant the ledger knows nothing, and a turn it cannot account for is not a
    /// person's: this supervisor's start, or the end of the oldest write it has dropped.
    private(set) var knownSince: Date
    private(set) var writes: [AutomaticWrite] = []

    init(knownSince: Date) { self.knownSince = knownSince }

    mutating func note(start: Date, end: Date, lag: TimeInterval = automaticTurnLag) {
        writes.append(AutomaticWrite(start: start, end: end))
        while writes.count > automaticInputLedgerCap {
            let dropped = writes.removeFirst()
            knownSince = max(knownSince, dropped.end.addingTimeInterval(lag))
        }
    }

    /// Whether Tally's own typing, or the ledger's ignorance, accounts for a user turn at `turn`.
    func explains(_ turn: Date, lag: TimeInterval = automaticTurnLag) -> Bool {
        turn < knownSince
            || writes.contains { turn >= $0.start && turn <= $0.end.addingTimeInterval(lag) }
    }
}

/// The newest user turn the ledger cannot account for, or nil: what "a person has typed" means
/// to the cap resume budget.
func lastPersonTurn(_ turns: [Date], automatic: AutomaticInputLedger) -> Date? {
    turns.filter { !automatic.explains($0) }.max()
}

/// This supervisor's ledger. One supervised session per process; reset when supervision starts.
nonisolated(unsafe) var automaticInputLedger = AutomaticInputLedger(knownSince: Date())
