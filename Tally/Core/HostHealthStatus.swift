import Foundation

// WHAT `tally status` PRINTS ABOUT THE HOST: the one line, and the two helpers that spell an age and
// a wall-clock time in it. Split out of HostHealthLogic.swift for size (that file is the record and
// the rules; this is only text built from them) and compiled by the CLI target with it.

/// The `Host` line `tally status` prints, or nil when there is nothing honest to print.
///
/// FAIL-OPEN, the rule `loadAdvisorReadings` is under: a machine whose Tally is not running has no
/// report, and a report this build cannot read is the same answer. Both leave the section out
/// rather than printing a state nobody measured.
///
/// A REPORT NOBODY HAS REWRITTEN IN A WHILE STILL PRINTS, with its age beside it. The age is the
/// honest field: a stopped app is exactly the case where a stale "ok" would be a lie, and saying
/// how old the reading is says so without this file having to guess a staleness rule.
func hostHealthStatusLine(_ report: HostHealthReport?, now: Date = Date()) -> String? {
    guard let report else { return nil }
    let limit = hostHealthFigure(report.cpuLimit ?? HostHealthLimits.standard.cpuPercent)
    let cpuText = "cpu \(report.cpuPercent.map(hostHealthFigure) ?? "?")%/\(limit)%"
    let free = "free \(hostHealthGigabytes(report.freeBytes)) GB"
    let age = Int(max(0, now.timeIntervalSince(report.sampledAt)).rounded())
    let sampled = " (sampled \(hostHealthAge(age)) ago)"
    switch report.state {
    case .normal:
        return "host: \(cpuText) · \(free) · ok" + sampled
    case .alarmed:
        var text = "host: ALARM since \(hostHealthClock(report.since)) · \(cpuText) · \(free)"
        let top = hostHealthTopText(report.lastAlarm?.top ?? [], unit: "G")
        if !top.isEmpty { text += " · top: \(top)" }
        return text + sampled
    }
}

/// How long ago, in the shortest unit that is still true.
func hostHealthAge(_ seconds: Int) -> String {
    if seconds < 90 { return "\(seconds)s" }
    if seconds < 5_400 { return "\(Int((Double(seconds) / 60).rounded()))m" }
    return "\(Int((Double(seconds) / 3_600).rounded()))h"
}

/// Wall-clock hours and minutes, for the instant an alarm began.
///
/// BUILT BY HAND rather than with a `DateFormatter`, for the reason the figures above are: this
/// line is read out of a terminal and out of scripts, and a formatter would spell it differently
/// per locale for no reader who wanted that.
func hostHealthClock(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
}
