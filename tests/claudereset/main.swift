import Foundation

// Assertion harness for ClaudeUsageTextMapper.parseReset's year inference, compiled against the
// real source. The rule under test: pick the occurrence CLOSEST to now, past allowed - a reset
// read minutes after it passed must stay "just passed", never jump a year ahead (that jump made
// the smart pick score a fresh session as needing to last 8760h; live incident 2026-07-19 03:02).

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

let taipei = TimeZone(identifier: "Asia/Taipei")!
func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var parts = DateComponents()
    (parts.year, parts.month, parts.day, parts.hour, parts.minute) = (y, mo, d, h, mi)
    parts.timeZone = taipei
    return Calendar(identifier: .gregorian).date(from: parts)!
}

// The live incident: 03:02, stamp of the reset that passed at 03:00 - must stay 2 minutes in
// the past, not become next year's Jul 19.
let justPassed = ClaudeUsageTextMapper.parseReset(
    "Jul 19 at 3am (Asia/Taipei)", now: date(2026, 7, 19, 3, 2))
check("just-passed reset stays just passed", justPassed == date(2026, 7, 19, 3, 0))

let future = ClaudeUsageTextMapper.parseReset(
    "Jul 24 at 1am (Asia/Taipei)", now: date(2026, 7, 19, 3, 2))
check("future reset stays this year", future == date(2026, 7, 24, 1, 0))

// Year boundary, both directions.
let lastYear = ClaudeUsageTextMapper.parseReset(
    "Dec 31 at 11pm (Asia/Taipei)", now: date(2027, 1, 1, 0, 30))
check("early-January read of a Dec 31 reset lands in the old year",
      lastYear == date(2026, 12, 31, 23, 0))

let nextYear = ClaudeUsageTextMapper.parseReset(
    "Jan 2 at 4am (Asia/Taipei)", now: date(2026, 12, 30, 22, 0))
check("late-December read of a Jan 2 reset lands in the new year",
      nextYear == date(2027, 1, 2, 4, 0))

// End to end through the mapper: the metric carries the parsed reset.
let metrics = ClaudeUsageTextMapper.map(
    text: "Current session: 5% used · resets Jul 19 at 3am (Asia/Taipei)",
    now: date(2026, 7, 19, 3, 2))
check("mapper end-to-end keeps the just-passed reset",
      metrics.first?.resetsAt == date(2026, 7, 19, 3, 0))

exit(failures == 0 ? 0 : 1)
