import Foundation

// B-429: early weekly resets. The detection (`earlyResets`), its threshold at the reading, and the
// English headline that stops advising purchases once the resets are irregular.

/// A weekly reading at `at`, reporting `due` as its reset instant.
private func w(_ account: String, _ used: Double, at: Date, due: Date?,
               window: String = "weeklyAll") -> UsageAdvisor.Sample {
    UsageAdvisor.Sample(ts: at, account: account, provider: "codex", window: window, model: nil,
                        used: used, resetAt: due)
}

/// The reset instant a pair's first reading promises; its second reading lands `lead` before it.
private let due = now.addingTimeInterval(-10 * 86_400)
private func pair(drop: Double = 50, lead: TimeInterval, account: String = "a1",
              window: String = "weeklyAll", dueAt: Date? = due) -> [UsageAdvisor.Sample] {
    let restart = due.addingTimeInterval(-lead)
    let next = due.addingTimeInterval(7 * 86_400)
    return [w(account, 60, at: due.addingTimeInterval(-3 * 86_400), due: dueAt, window: window),
            w(account, 60 - drop, at: restart, due: next, window: window),
            // The next poll still reads low: that is what confirms the restart.
            w(account, 60 - drop, at: restart.addingTimeInterval(600), due: next, window: window)]
}

/// `n` three-day-and-a-half cycles ending now, each reporting a reset a week after it started, so
/// every restart is days early: n - 1 early resets, heavy demand (an addAccount verdict).
private func earlyCycles(_ n: Int) -> [UsageAdvisor.Sample] {
    let length = 3.5 * 86_400
    return (0..<n).flatMap { i -> [UsageAdvisor.Sample] in
        let start = now.addingTimeInterval(-Double(n - i) * length)
        let reset = start.addingTimeInterval(7 * 86_400)
        return [w("a1", 5, at: start, due: reset),
                w("a1", 6, at: start.addingTimeInterval(600), due: reset),
                w("a1", 95, at: start.addingTimeInterval(length - 600), due: reset)]
    }
}

func runResetChecks() {
    let long = UsageAdvisor.earlyResetLead
    func early(_ samples: [UsageAdvisor.Sample], since: Date = .distantPast) -> Int {
        UsageAdvisor.earlyResets(samples, since: since).values.reduce(0, +)
    }
    check("a 10 point drop a day and more before the reset is an early reset",
          early(pair(drop: 10, lead: long + 1)) == 1)
    check("a 9 point drop is a rounding dip, not a reset", early(pair(drop: 9, lead: 2 * long)) == 0)
    check("exactly a day early is not early", early(pair(lead: long)) == 0)
    check("a second over a day early is", early(pair(lead: long + 1)) == 1)
    check("a reset on schedule is not early", early(pair(lead: 60)) == 0)
    check("a nil reset time on the earlier reading says nothing", early(pair(lead: 3 * long, dueAt: nil)) == 0)
    check("a model window is not looked at", early(pair(lead: 3 * long, window: "weeklyModel")) == 0)
    check("each account counts its own restarts",
          early(pair(lead: 3 * long, account: "a1") + pair(lead: 3 * long, account: "a2")) == 2)
    func most(_ samples: [UsageAdvisor.Sample]) -> Int {
        UsageAdvisor.earlyResets(samples, since: .distantPast).values.max() ?? 0
    }
    check("the count is kept per account", most(pair(lead: 3 * long, account: "a1")
        + pair(lead: 3 * long, account: "a2")) == 1)
    // codex review of a185363, Critical 1: a counter that bounces straight back is a provider
    // serving the wrong figures for a poll, not a reset (`oneLow`, `nilBlips` in main.swift).
    let blips: [UsageAdvisor.Sample] = [60, 0, 60, 0, 60, 0, 60].enumerated().map { i, used in
        w("a1", used, at: now.addingTimeInterval(-Double(7 - i) * 86_400), due: now.addingTimeInterval(5 * 86_400))
    }
    check("60,0,60,0,60,0,60 a day apart is no reset at all", early(blips) == 0)
    check("…so it cannot make the resets irregular", reading(blips)?.resetsIrregular == false)
    check("a drop is not confirmed by the next reading being missing",
          early(Array(pair(lead: 3 * long).dropLast())) == 0)
    let stays = pair(lead: 3 * long)
    check("the same drop confirmed by a low next reading counts", early(stays) == 1)
    check("…and a next reading that recovers to 10 points under the high still confirms",
          early([stays[0], stays[1], w("a1", 50, at: stays[1].ts.addingTimeInterval(600), due: stays[1].resetAt)]) == 1)
    check("…but one that recovers to 9 under does not",
          early([stays[0], stays[1], w("a1", 51, at: stays[1].ts.addingTimeInterval(600), due: stays[1].resetAt)]) == 0)
    let restart = due.addingTimeInterval(-3 * long)
    check("a restart before `since` is not counted", early(pair(lead: 3 * long), since: restart.addingTimeInterval(60)) == 0)
    check("a restart at `since` is", early(pair(lead: 3 * long), since: restart) == 1)

    guard let two = reading(earlyCycles(3)), let three = reading(earlyCycles(4)) else {
        check("early-cycle readings exist", false); return
    }
    check("two early resets are counted", two.earlyResets == 2)
    check("two early resets do not make the resets irregular", !two.resetsIrregular)
    check("three early resets do", three.earlyResets == 3 && three.resetsIrregular)
    var spread: [UsageAdvisor.Sample] = []
    for account in ["a1", "a2", "a3"] { spread += pair(lead: 3 * long, account: account) }
    let fleetwide = UsageAdvisor.reading(provider: "codex", samples: spread + earlyCycles(1)
        .map { var x = $0; x.account = "a4"; return x }, now: now)
    check("one early reset on each of three accounts is no irregularity",
          fleetwide?.earlyResets == 3 && fleetwide?.resetsIrregular == false)
    check("both fixtures still carry the add-account verdict, which keeps its meaning",
          two.verdict == .addAccount && three.verdict == .addAccount)
    check("the headline advises as before until the resets are irregular",
          UsageAdvisor.englishHeadline(two) == "consider adding an account")
    for dry in [nil, true, false] {
        check("irregular resets replace the advice whatever the gauge says (poolsDry \(String(describing: dry)))",
              UsageAdvisor.englishHeadline(three, poolsDry: dry) == "resets irregular: demand figure unreliable")
    }
    var calm = three
    calm.verdict = .sufficient
    check("a sufficient verdict keeps its words", UsageAdvisor.englishHeadline(calm) == "current accounts are sufficient")
}
