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
    return knock.observe(account: "A", cycle: cycle, remaining: remaining, now: moment)
}

expect(fires(12), "an account under the line is owed the sentence")
expect(fires(quotaKnockPercent),
       "an account exactly on the line is under it, the rule every threshold here follows")
expect(!fires(quotaKnockPercent + 0.1), "a hair above the line is not")
expect(!fires(80), "a healthy account is told nothing")

// Once per drought. The second reading of the same window says nothing, which is the whole
// difference between an advisory and a nag.
var repeated = QuotaKnockState(forced: false)
expect(repeated.observe(account: "A", cycle: "100", remaining: 12, now: now), "the first reading fires")
repeated.spend()
expect(!repeated.observe(account: "A", cycle: "100", remaining: 11, now: now.addingTimeInterval(60)),
       "the same drought is not announced twice")
expect(!repeated.observe(account: "A", cycle: "100", remaining: 2, now: now.addingTimeInterval(600)),
       "and it stays quiet as the same window drains further")

// The gap between the two lines is what stops an account hovering at the threshold from talking.
expect(!repeated.observe(account: "A", cycle: "100", remaining: quotaKnockRearmPercent,
                         now: now.addingTimeInterval(900)),
       "recovering exactly to the re-arm line does not re-arm it")
expect(!repeated.observe(account: "A", cycle: "100", remaining: 12, now: now.addingTimeInterval(960)),
       "so a window bouncing between the two lines says its sentence once")
expect(!repeated.observe(account: "A", cycle: "100", remaining: quotaKnockRearmPercent + 0.1,
                         now: now.addingTimeInterval(1_000)),
       "a real recovery is not itself news")
expect(repeated.observe(account: "A", cycle: "100", remaining: 12, now: now.addingTimeInterval(1_200)),
       "but draining again after one is a fresh drought")

// A new cycle re-arms it: the window refilled, so the next time it empties is different news.
var cycled = QuotaKnockState(forced: false)
_ = cycled.observe(account: "A", cycle: "100", remaining: 12, now: now)
cycled.spend()
expect(!cycled.observe(account: "A", cycle: "160", remaining: 12, now: now.addingTimeInterval(60)),
       "a reset time that drifted by a minute is the same drought")
expect(!cycled.observe(account: "A", cycle: "40", remaining: 12, now: now.addingTimeInterval(120)),
       "and so is one that drifted the other way")
expect(cycled.observe(account: "A", cycle: "18000", remaining: 12, now: now.addingTimeInterval(180)),
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
expect(unkeyed.observe(account: "A", cycle: nil, remaining: 4, now: now),
       "an account with no reset time still gets its one sentence")
unkeyed.spend()
expect(!unkeyed.observe(account: "A", cycle: nil, remaining: 4, now: now.addingTimeInterval(600)),
       "and only one")

// MARK: - 2b. The account the flag belongs to

// A CYCLE KEY IS NOT AN IDENTITY. Two accounts can report the same reset (this fleet's weekly
// windows turn over within the five-minute tolerance of each other), and two accounts that report
// none at all both key on nil, which matches every other nil. A session handed from a spent account
// to a sibling would then arrive carrying a flag raised for somebody else, and the account it is
// now ON would never be announced.
var moved = QuotaKnockState(forced: false)
expect(moved.observe(account: "A", cycle: "100", remaining: 8, now: now),
       "the account it is on is announced")
moved.spend()
expect(!moved.observe(account: "A", cycle: "100", remaining: 8, now: now.addingTimeInterval(60)),
       "…once")
expect(moved.observe(account: "B", cycle: "100", remaining: 8, now: now.addingTimeInterval(120)),
       "a different account with the SAME reset time is a different piece of news")
moved.spend()
expect(!moved.observe(account: "B", cycle: "102", remaining: 8, now: now.addingTimeInterval(180)),
       "…and once there, the drifted reading is still that account's one drought")
expect(moved.observe(account: "A", cycle: "100", remaining: 8, now: now.addingTimeInterval(240)),
       "moving back is news again: nothing here remembers two accounts at once")

var unkeyedMove = QuotaKnockState(forced: false)
expect(unkeyedMove.observe(account: "A", cycle: nil, remaining: 3, now: now),
       "an account with no published reset is announced")
unkeyedMove.spend()
expect(unkeyedMove.observe(account: "B", cycle: nil, remaining: 3, now: now.addingTimeInterval(60)),
       "and so is the next one, which the nil-matches-nil rule alone would have swallowed")

// MARK: - 3. How often the reading is taken at all

var throttled = QuotaKnockState(forced: false)
expect(throttled.due(now: now), "the first tick always takes a reading")
_ = throttled.observe(account: "A", cycle: "100", remaining: 80, now: now)
expect(!throttled.due(now: now.addingTimeInterval(quotaKnockInterval - 1)),
       "and then not again until the interval is up, whatever the poll loop's own pace")
expect(throttled.due(now: now.addingTimeInterval(quotaKnockInterval)),
       "the interval is inclusive, so a reading due at exactly 30s is taken")

var forced = QuotaKnockState(forced: true)
_ = forced.observe(account: "A", cycle: "100", remaining: 90, now: now)
expect(forced.due(now: now.addingTimeInterval(2)),
       "a forced knock does not wait out the interval: somebody is watching for it")
expect(forced.forced, "…and it is still owed while nothing has been typed")
forced.spend()
expect(!forced.forced, "the first sentence spends it")
expect(!forced.due(now: now.addingTimeInterval(2)), "after which the interval applies again")

// The arm is spent by the SEND, never by the reading: a session whose composer was busy at the
// moment the account crossed the line still gets told.
var held = QuotaKnockState(forced: false)
expect(held.observe(account: "A", cycle: "100", remaining: 12, now: now), "the reading says the sentence is owed")
expect(held.observe(account: "A", cycle: "100", remaining: 12, now: now.addingTimeInterval(30)),
       "and it keeps saying so until something is actually typed")
held.spend()
expect(!held.observe(account: "A", cycle: "100", remaining: 12, now: now.addingTimeInterval(60)),
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

// MARK: - 4b. The budget, which is bytes and is a guarantee

// The budget is the poll loop's own time (30ms a byte) and the channel's own limit, so the sentence
// is bounded by construction rather than by hope: what goes first is the clause a reader can get
// for themselves.
let clipped = line(limit: 120)
expect(!clipped.contains("Best alternative"),
       "over the budget, the alternative account is what the sentence drops")
expect(clipped.contains("Wrap up and switch accounts"), "…and never the advice")
expect(clipped.utf8.count <= 120, "…and the form that is returned is inside the budget it was given")

let longLabel = account("C", label: String(repeating: "Very Long Account Label ", count: 4),
                        session: 4)
let clippedName = line(longLabel, alternative: longLabel, sessions: 2)
expect(clippedName.contains("Very Long Account Label Very \u{2026}"),
       "a label longer than the budget allows is clipped rather than left to eat the sentence")
expect(clippedName.utf8.count <= 200,
       "so even two absurd labels cannot push the line past the channel's limit "
           + "(\(clippedName.utf8.count) bytes)")

// BYTES, NOT CHARACTERS, which is the correction this section carries. A character budget counted
// 24 emoji as inside it and handed the channel 230 bytes; 24 CJK characters made 206. Both went
// through the two returns that did not check the budget at all, so each script is asked here on
// each of the three forms: with an alternative, without one, and clipped.
for (script, label) in [("emoji", String(repeating: "🙂", count: 24)),
                        ("CJK", String(repeating: "額度", count: 12))] {
    let wide = account("W", label: label, session: 7)
    for (form, sentence) in [("with an alternative", line(wide, alternative: healthy)),
                             ("with none", line(wide, alternative: nil)),
                             ("clipped", line(wide, alternative: healthy, limit: 120))] {
        expect(sentence.utf8.count <= (form == "clipped" ? 120 : 200),
               "a \(script) label \(form) stays inside the budget (\(sentence.utf8.count) bytes)")
    }
    expect(quotaKnockName(wide).utf8.count <= quotaKnockLabelBytes,
           "…because the name itself is clipped by BYTES (\(quotaKnockName(wide).utf8.count))")
    expect(!quotaKnockName(wide).unicodeScalars.contains { $0.value == 0xFFFD },
           "…on a character boundary, so no scalar is cut in half")
}

// The one thing nothing here bounds: a window name is published by the provider. The guarantee is
// held by measuring rather than by reasoning about it, which is what the last cut is for.
let hugeWindow = Snapshot.Account(
    id: "H", provider: "claude", label: "Claude", launchHome: "/tmp/H", sessionRemaining: nil,
    weeklyRemaining: nil, modelRemaining: 9, sessionResetsAt: nil, weeklyResetsAt: nil,
    modelResetsAt: now.addingTimeInterval(3600),
    modelWindowName: String(repeating: "fable ", count: 60), resetCreditsAvailable: nil,
    isStale: false, error: nil)
let measured = line(hugeWindow, alternative: nil, sessions: 1)
expect(measured.utf8.count <= 200,
       "a window name nothing bounds is cut to the budget rather than reasoned about "
           + "(\(measured.utf8.count) bytes)")
expect(measured.hasPrefix("[tally] account Claude is running low:"),
       "…keeping the front of the sentence, which is the news")

// MARK: - 4c. A label is free text on a keystroke channel

// The rename popover trims the ends and accepts everything else, so a label can carry a newline -
// and every byte of this sentence is pushed into a terminal as though it had been typed, where a
// newline is a Return: half the sentence submitted, the rest typed into whatever comes up next.
let awkward = Snapshot.Account(id: "claude:.claude2", provider: "claude",
                               label: "Claude\n2 \u{1B}[31m", launchHome: "/Users/a/.claude2",
                               sessionRemaining: 9, weeklyRemaining: 90, modelRemaining: 90,
                               sessionResetsAt: now.addingTimeInterval(3600), weeklyResetsAt: nil,
                               modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
                               isStale: false, error: nil)
expect(quotaKnockName(awkward) == ".claude2",
       "a label that cannot be typed is refused and the config-dir name answers instead, "
           + "which is what `completionAccountNames` does with the same label")
let typedLine = line(awkward, alternative: awkward, sessions: 1)
expect(!typedLine.contains("\n") && !typedLine.contains("\u{1B}"),
       "so nothing that a terminal reads as a keystroke reaches the sentence")
expect(typedLine.contains("account .claude2 is running low"),
       "…and the name in it is one `tally account` can resolve, which a repaired label is not")

// Only when there is no usable name at all is the label repaired, because something has to be
// printed by then.
let homeless = Snapshot.Account(id: "claude:.claude9", provider: "claude", label: "Cla\nude",
                                launchHome: nil, sessionRemaining: 9, weeklyRemaining: 90,
                                modelRemaining: 90, sessionResetsAt: now.addingTimeInterval(3600),
                                weeklyResetsAt: nil, modelResetsAt: nil, modelWindowName: nil,
                                resetCreditsAvailable: nil, isStale: false, error: nil)
expect(quotaKnockName(homeless) == "Claude",
       "an account with no other name has its label stripped rather than dropped")
let unnamed = Snapshot.Account(id: "claude:.claude7", provider: "claude", label: "\n",
                               launchHome: nil, sessionRemaining: 9, weeklyRemaining: 90,
                               modelRemaining: 90, sessionResetsAt: now.addingTimeInterval(3600),
                               weeklyResetsAt: nil, modelResetsAt: nil, modelWindowName: nil,
                               resetCreditsAvailable: nil, isStale: false, error: nil)
expect(quotaKnockName(unnamed) == "claude:.claude7",
       "and one whose every name is unusable is called by its id rather than by nothing")

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

// MARK: - 8. The reserve, at the threshold this station reads

// CONSUMER 8 OF THE PERSONAL ACCOUNT'S RESERVE (AccountReserve.swift). The knock warns a session
// that the account under it is running out, and what "running out" means here has to be the same
// thing it means to the movers: the part of the account TALLY MAY SPEND. Without that, a personal
// account with 30 points held back is announced 30 points late - which is to say, after every mover
// has already refused to place work on it.
//
// The threshold itself is `quotaKnockPercent`; what the reserve changes is the reading handed to it,
// and that reading is taken through the same `bindingWindow` + `effectiveRemaining` pair the gates
// use, so a drift between the sentence and the refusals is impossible by construction.
let reserved = AccountReserves(settings: [
    "/tmp/R": AccountRoleSetting(role: AccountRoles.personal, reserve: 30),
])
let browsing = account("R", session: 40, weekly: 90)
func knockReading(_ acct: Snapshot.Account, reserves: AccountReserves) -> Double {
    let binding = bindingWindow(acct, primaryModel: nil, reserves: reserves, now: now)
    return binding.map { effectiveRemaining(comfortWindow($0), now: now) } ?? .nan
}
expect(knockReading(browsing, reserves: reserved) <= quotaKnockPercent,
       "a reserved account at 40% is already inside the knock's threshold")
expect(knockReading(browsing, reserves: .none) > quotaKnockPercent,
       "and the same account is nowhere near it when nobody reserved anything")
// AND THE SENTENCE STILL QUOTES THE PROVIDER'S OWN PERCENTAGE. What the reader is owed is the
// number their provider published - it has to mean the same thing here, in the panel and on
// claude.ai - so the reserve moves the threshold and never the news.
let reservedLine = quotaKnockMessage(
    account: browsing,
    alternative: bindingWindow(browsing, primaryModel: nil, reserves: reserved, now: now)
        .map { _ in healthy },
    sessions: 1, primaryModel: nil, limit: 200, now: now) ?? ""
expect(reservedLine.contains("session 40%"),
       "the knock quotes the reading the provider published, not the reserved one")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all quota-knock tests passed")
