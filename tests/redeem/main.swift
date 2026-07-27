import Foundation

// Assertion harness for RedeemPropagation (compiled with Tally/Core/RedeemPropagation.swift
// alone - it is Foundation-only on purpose).

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let redeemedAt = Date(timeIntervalSince1970: 1_800_000_000)
let window = RedeemPropagation.settlingWindow

func settling(after seconds: TimeInterval, remaining: Double?,
              redeemed: Date? = redeemedAt) -> Bool {
    RedeemPropagation.isSettling(redeemedAt: redeemed,
                                 now: redeemedAt.addingTimeInterval(seconds),
                                 bindingRemaining: remaining)
}

// MARK: isSettling - the truth table of "a redeem landed recently AND the data is still capped"

expect(!settling(after: 5, remaining: 0, redeemed: nil),
       "no redeem on record - a capped account is just capped")
expect(settling(after: 5, remaining: 0),
       "fresh redeem over a still-exhausted window - the settling voice")
expect(settling(after: 0, remaining: 0),
       "the instant of the redeem is inside the window")
expect(settling(after: window, remaining: 0),
       "the last instant of the window still counts")
expect(!settling(after: window + 1, remaining: 0),
       "past the window a still-capped account goes back to reporting the limit")
expect(!settling(after: 5, remaining: 100),
       "the numbers moved - nothing left to wait for")
expect(!settling(after: 5, remaining: 0.4),
       "any quota at all means the window is not exhausted")
expect(!settling(after: 5, remaining: nil),
       "an account reporting no windows never reads as empty")
expect(!settling(after: -30, remaining: 0),
       "a timestamp in the future (clock jump) is not a fresh redeem")

// MARK: hasPropagated - what stops the retry ladder

func propagated(_ baseline: Double, _ current: Double) -> Bool {
    RedeemPropagation.hasPropagated(baselineRemaining: baseline, currentRemaining: current)
}

expect(!propagated(0, 0), "drained account, unchanged - keep retrying")
expect(propagated(0, 100), "drained account, quota back - done")
expect(!propagated(0, 0.3), "a rounding wobble is not a reset")
expect(propagated(40, 100), "redeemed with room left, quota back - done")
expect(!propagated(40, 40), "redeemed with room left, unchanged - keep retrying")
expect(!propagated(40, 39),
       "remaining fell (usage burnt while waiting) - still not a reset")

// MARK: the ladder itself

expect(RedeemPropagation.retryDelays.count == 3, "three deferred re-fetches")
expect(zip(RedeemPropagation.retryDelays, RedeemPropagation.retryDelays.dropFirst())
        .allSatisfy { $1 > $0 }, "the ladder backs off")
expect(RedeemPropagation.retryDelays.reduce(0, +) < window,
       "the whole ladder finishes inside the settling window")

// MARK: the wiring - every redeem goes through followThrough, and nothing refreshes beside it

// `RedeemPropagationStore.begin` reads its baseline from the snapshot the caller already had, which
// is the only reading known to predate the reset. A caller that fires its own refresh alongside the
// follow-through hands it a post-reset baseline instead, the retry ladder decides on its first look
// that the numbers have already moved, and the card goes back to saying "Limit reached" over an
// account that just redeemed. None of that shows up in a type check, and the rule itself lives in a
// comment, so the source is where it has to be held.
//
// The assertions dig each function's body out by its own closing brace (four spaces at type scope)
// rather than reading the whole file: `AccountCardView` legitimately refreshes elsewhere, from the
// Retry button on its error row, and a file-wide scan would call that a violation.

/// The body of a function, from its declaration to the closing brace at type-member indentation.
func functionBody(_ source: String, from declaration: String) -> String? {
    guard let start = source.range(of: declaration),
          let end = source.range(of: "\n    }",
                                 range: start.upperBound ..< source.endIndex) else { return nil }
    return String(source[start.upperBound ..< end.lowerBound])
}

func readSource(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

let cardSource = readSource("Tally/Views/AccountCardView.swift")
let actionSource = readSource("Tally/Views/RedeemAction.swift")
expect(!cardSource.isEmpty && !actionSource.isEmpty,
       "the redeem call sites are readable from the suite")

for (label, source, declaration) in [
    ("the card's redeem button", cardSource, "private func startRedeem() {"),
    ("the notification's redeem", actionSource, "static func present(accountID: String?) {"),
] {
    if let body = functionBody(source, from: declaration) {
        expect(body.contains("followThrough("),
               "\(label) hands off to the shared follow-through")
        expect(!body.contains("UsageStore.shared.refresh"),
               "\(label) does not refresh beside it, which would spoil the baseline")
    } else {
        expect(false, "\(label)'s body was found")
    }
}

// One entry point into the propagation store, so the rule above has exactly one place to hold.
var beginCallers: [String] = []
let tallyRoot = URL(fileURLWithPath: "Tally")
if let walk = FileManager.default.enumerator(at: tallyRoot, includingPropertiesForKeys: nil) {
    for case let url as URL in walk where url.pathExtension == "swift" {
        if readSource(url.path).contains("RedeemPropagationStore.shared.begin(") {
            beginCallers.append(url.lastPathComponent)
        }
    }
}
let singleEntryPoint = beginCallers == ["RedeemAction.swift"]
expect(singleEntryPoint, "the propagation store is started from RedeemAction alone")
// The list itself belongs on the way OUT, not in the assertion's name: `expect` prints the one
// string it is given whichever way the check went, so interpolating the callers into that string
// makes the passing line contradict itself, naming the very file it just confirmed.
if !singleEntryPoint { print("  begin() is called from: \(beginCallers)") }

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
