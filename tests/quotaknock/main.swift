import Foundation

// The advisory knock's pure half (TallyCLI/QuotaKnockLogic.swift): when a session is owed the
// sentence, and what the sentence says. The tick that acts on this decision is asserted next door
// in the supervisor suite (tests/supervisor/quotaknockchecks.swift), along the same seam the source
// is split on: nothing here reads a snapshot, a terminal or a state directory.
//
// What the feature is for, because it decides what these assertions are worth: the movers that
// carry a session off a dying account (the idle rebalance, the window repick) both need the session
// to be IDLE, so the sessions that ride an account into the wall are the busy ones they leave alone.
// This tells such a session the fact, once per drought, while there is still runway to act on it.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)

/// An account whose SESSION window is the interesting one: the weekly and flagship windows stay
/// healthy, so the session window alone decides what binds.
func account(_ id: String, label: String? = nil, session: Double, sessionResetHours: Double = 3,
             weekly: Double = 90, weeklyResetHours: Double = 100) -> Snapshot.Account {
    Snapshot.Account(id: id, provider: "claude", label: label ?? id, launchHome: "/tmp/\(id)",
                     sessionRemaining: session, weeklyRemaining: weekly, modelRemaining: 90,
                     sessionResetsAt: now.addingTimeInterval(sessionResetHours * 3600),
                     weeklyResetsAt: now.addingTimeInterval(weeklyResetHours * 3600),
                     modelResetsAt: now.addingTimeInterval(weeklyResetHours * 3600),
                     modelWindowName: "fable", resetCreditsAvailable: nil, isStale: false,
                     error: nil)
}

// MARK: - 1. Which window the reading is taken from

// The binding window is the EMPTIEST by effective remaining, which is the reading every gate in
// this repo weighs. It is shared with the rebalance's cycle key on purpose: the sentence a session
// is sent must name the window the key that stops it being re-sent was taken from.
let dying = account("A", label: "Claude", session: 12)
expect(bindingWindow(dying, primaryModel: "fable", now: now)?.name == "session",
       "the emptiest window is the one that binds")
expect(bindingWindow(account("A", session: 95, weekly: 4), primaryModel: "fable", now: now)?.name
           == "weekly",
       "a spent weekly under a fresh session window binds the account")
// The comfort gate's imminent-reset exemption comes along for free, which is why the reading is
// taken through it: 3% that refills in five minutes is a full window, and advising somebody to wrap
// up over it would be advice against their own interest.
expect(bindingWindow(account("A", session: 3, sessionResetHours: 0.08, weekly: 40),
                     primaryModel: "fable", now: now)?.name == "weekly",
       "a window minutes from resetting is not what binds the account")
expect(bindingWindow(Snapshot.Account(id: "E", provider: "claude", label: "E", launchHome: "/tmp/E",
                                      sessionRemaining: nil, weeklyRemaining: nil,
                                      modelRemaining: nil, sessionResetsAt: nil,
                                      weeklyResetsAt: nil, modelResetsAt: nil, modelWindowName: nil,
                                      resetCreditsAvailable: nil, isStale: false, error: nil),
                     primaryModel: nil, now: now) == nil,
       "an account reporting no windows binds on nothing")

// MARK: - 2. The line, and the hysteresis around it

/// One reading folded into a fresh state.
func fires(_ remaining: Double, cycle: String? = "100", state: QuotaKnockState? = nil,
           at moment: Date = now) -> Bool {
    var knock = state ?? QuotaKnockState(forced: false)
    return knock.observe(cycle: cycle, remaining: remaining, now: moment)
}

expect(fires(12), "an account under the line is owed the sentence")
expect(fires(quotaKnockPercent),
       "an account exactly on the line is under it, the rule every threshold here follows")
expect(!fires(quotaKnockPercent + 0.1), "a hair above the line is not")
expect(!fires(80), "a healthy account is told nothing")

// Once per drought. The second reading of the same window says nothing, which is the whole
// difference between an advisory and a nag.
var repeated = QuotaKnockState(forced: false)
expect(repeated.observe(cycle: "100", remaining: 12, now: now), "the first reading fires")
repeated.spend()
expect(!repeated.observe(cycle: "100", remaining: 11, now: now.addingTimeInterval(60)),
       "the same drought is not announced twice")
expect(!repeated.observe(cycle: "100", remaining: 2, now: now.addingTimeInterval(600)),
       "and it stays quiet as the same window drains further")

// The gap between the two lines is what stops an account hovering at the threshold from talking.
expect(!repeated.observe(cycle: "100", remaining: quotaKnockRearmPercent,
                         now: now.addingTimeInterval(900)),
       "recovering exactly to the re-arm line does not re-arm it")
expect(!repeated.observe(cycle: "100", remaining: 12, now: now.addingTimeInterval(960)),
       "so a window bouncing between the two lines says its sentence once")
expect(!repeated.observe(cycle: "100", remaining: quotaKnockRearmPercent + 0.1,
                         now: now.addingTimeInterval(1_000)),
       "a real recovery is not itself news")
expect(repeated.observe(cycle: "100", remaining: 12, now: now.addingTimeInterval(1_200)),
       "but draining again after one is a fresh drought")

// A new cycle re-arms it: the window refilled, so the next time it empties is different news.
var cycled = QuotaKnockState(forced: false)
_ = cycled.observe(cycle: "100", remaining: 12, now: now)
cycled.spend()
expect(!cycled.observe(cycle: "160", remaining: 12, now: now.addingTimeInterval(60)),
       "a reset time that drifted by a minute is the same drought")
expect(!cycled.observe(cycle: "40", remaining: 12, now: now.addingTimeInterval(120)),
       "and so is one that drifted the other way")
expect(cycled.observe(cycle: "18000", remaining: 12, now: now.addingTimeInterval(180)),
       "a genuinely new reset is a new drought, and is announced")

// The tolerance itself is the CLI's one rule, not a second copy of it.
expect(quotaKnockSameCycle("100", "\(100 + Int(rebalanceCycleTolerance))"),
       "the same-drought tolerance is the rebalance claim's, to the second")
expect(!quotaKnockSameCycle("100", "\(101 + Int(rebalanceCycleTolerance))"),
       "and past it the drought is a different one")
expect(quotaKnockSameCycle(nil, nil),
       "an account publishing no reset time keeps one drought rather than one per tick")
expect(!quotaKnockSameCycle(nil, "100") && !quotaKnockSameCycle("100", nil),
       "a window that has started reporting a reset is not the drought that had none")

var unkeyed = QuotaKnockState(forced: false)
expect(unkeyed.observe(cycle: nil, remaining: 4, now: now),
       "an account with no reset time still gets its one sentence")
unkeyed.spend()
expect(!unkeyed.observe(cycle: nil, remaining: 4, now: now.addingTimeInterval(600)),
       "and only one")

// MARK: - 3. How often the reading is taken at all

var throttled = QuotaKnockState(forced: false)
expect(throttled.due(now: now), "the first tick always takes a reading")
_ = throttled.observe(cycle: "100", remaining: 80, now: now)
expect(!throttled.due(now: now.addingTimeInterval(quotaKnockInterval - 1)),
       "and then not again until the interval is up, whatever the poll loop's own pace")
expect(throttled.due(now: now.addingTimeInterval(quotaKnockInterval)),
       "the interval is inclusive, so a reading due at exactly 30s is taken")

var forced = QuotaKnockState(forced: true)
_ = forced.observe(cycle: "100", remaining: 90, now: now)
expect(forced.due(now: now.addingTimeInterval(2)),
       "a forced knock does not wait out the interval: somebody is watching for it")
expect(forced.forced, "…and it is still owed while nothing has been typed")
forced.spend()
expect(!forced.forced, "the first sentence spends it")
expect(!forced.due(now: now.addingTimeInterval(2)), "after which the interval applies again")

// The arm is spent by the SEND, never by the reading: a session whose composer was busy at the
// moment the account crossed the line still gets told.
var held = QuotaKnockState(forced: false)
expect(held.observe(cycle: "100", remaining: 12, now: now), "the reading says the sentence is owed")
expect(held.observe(cycle: "100", remaining: 12, now: now.addingTimeInterval(30)),
       "and it keeps saying so until something is actually typed")
held.spend()
expect(!held.observe(cycle: "100", remaining: 12, now: now.addingTimeInterval(60)),
       "which is what closes it")

// MARK: - 4. The sentence

let healthy = account("B", label: "Claude 2", session: 90, weekly: 82, weeklyResetHours: 50)
func line(_ current: Snapshot.Account = dying, alternative: Snapshot.Account? = healthy,
          sessions: Int = 3, limit: Int = 200) -> String {
    quotaKnockMessage(account: current, alternative: alternative, sessions: sessions,
                      primaryModel: "fable", limit: limit, now: now) ?? "<nothing>"
}

let full = line()
expect(full.hasPrefix("[tally] account Claude is running low: session 12%"),
       "the sentence names the account and quotes the window that binds it")
expect(full.contains("resets 3h"), "with how long until it refills, which is what waiting costs")
expect(full.contains("3 sessions on it"),
       "and how many conversations are sharing that window: three drain it three times as fast")
expect(full.contains("Best alternative: Claude 2 (weekly 82% · resets 2d2h)"),
       "then where there is room, quoted exactly as an account pick states its reason")
expect(full.contains("Wrap up and switch accounts, or wait for the reset."),
       "and the two things the reader can do about it")
expect(full.utf8.count <= 200, "a fleet-shaped sentence fits the channel's budget (\(full.utf8.count) bytes)")

expect(line(sessions: 1).contains(", 1 session on it."),
       "one session is one session, not one sessions")
let alone = line(sessions: 0)
expect(!alone.contains("session on it") && !alone.contains("sessions on it"),
       "a count of zero is a reading that failed rather than an empty account, so it is not printed")
expect(alone.contains("session 12%"), "…and the rest of the sentence stands without it")

let nowhere = line(alternative: nil)
expect(nowhere.contains("No account has headroom; consider pausing until the reset."),
       "with nothing comfortable anywhere the advice is the other one")
expect(!nowhere.contains("Best alternative"), "…and no account is named")

// The budget is the poll loop's own time (30ms a byte), so the sentence is bounded by construction
// rather than by hope: what goes is the clause a reader can get for themselves.
let clipped = line(limit: 120)
expect(!clipped.contains("Best alternative"),
       "over the budget, the alternative account is what the sentence drops")
expect(clipped.contains("Wrap up and switch accounts"), "…and never the advice")
expect(clipped.utf8.count <= 200, "the short form is bounded whatever the labels are")

let longLabel = account("C", label: String(repeating: "Very Long Account Label ", count: 4),
                        session: 4)
let clippedName = line(longLabel, alternative: longLabel, sessions: 2)
expect(clippedName.contains("Very Long Account Label \u{2026}"),
       "a label longer than the budget allows is clipped rather than left to eat the sentence")
expect(clippedName.utf8.count <= 200,
       "so even two absurd labels cannot push the line past the channel's limit "
           + "(\(clippedName.utf8.count) bytes)")

expect(quotaKnockMessage(account: Snapshot.Account(
        id: "E", provider: "claude", label: "E", launchHome: "/tmp/E", sessionRemaining: nil,
        weeklyRemaining: nil, modelRemaining: nil, sessionResetsAt: nil, weeklyResetsAt: nil,
        modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
        error: nil), alternative: healthy, sessions: 1, primaryModel: nil, limit: 200,
        now: now) == nil,
       "an account that reports no windows has no news, and says nothing")

// A window the provider published no reset for still makes a sentence: the percentage is the news,
// and inventing a reset time is what `RatedWindow` keeps `resetsAt` and `anchor` apart to prevent.
let unreported = Snapshot.Account(id: "D", provider: "claude", label: "D", launchHome: "/tmp/D",
                                  sessionRemaining: 6, weeklyRemaining: nil, modelRemaining: nil,
                                  sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                                  modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
                                  error: nil)
let quiet = line(unreported, alternative: nil, sessions: 1)
expect(quiet.contains("session 6%") && !quiet.contains("resets"),
       "a window with no published reset says how much is left and nothing about when it returns")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all quota-knock tests passed")
