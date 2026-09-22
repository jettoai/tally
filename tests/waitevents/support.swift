import Foundation

// A TEST-ONLY STAND-IN, never part of the app: `TallyCLI/OpenTurn.swift` calls `parseISO` (the real
// one lives in `TallyCLI/Snapshot.swift:470`, part of the quota/account read this suite has nothing
// to do with) inside `openToolCall(inTail:)`, a function this suite never calls. Pulling in the real
// `parseISO` means pulling in `Snapshot.swift`'s whole compile closure (the same ~14 files
// `tests/run-quotaknock-tests.sh` needs), which is disproportionate for satisfying the type checker
// on a code path with zero coverage here. This gives the symbol the same signature so
// `OpenTurn.swift` compiles; it is intentionally never as complete as the real one (no fractional-
// second handling) because nothing in this suite depends on its actual behaviour.
func parseISO(_ string: String) -> Date? {
    ISO8601DateFormatter().date(from: string)
}
