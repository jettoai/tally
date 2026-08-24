import Foundation

// Assertion harness for the early-start decision layer (Tally/Core/EarlyStart.swift) and for the
// shape of the spawn it produces (Tally/Core/EarlyStartCommand.swift).
//
// Nothing here starts a process. The spawn is a VALUE (`EarlyStartInvocation`), so the flags, the
// config-home variable and the working directory can be asserted exactly, and the fake runner at
// the bottom stands in for CLIRunner to check the whole fleet's worth of them at once. What that
// leaves for review by eye is the store's single unconditional hand-off of that value to
// `CLIRunner.run`, which is one call site in EarlyStartStore.swift.

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// A FIXED calendar, not the machine's. Every date rule below is about local mornings, and a suite
// whose answers moved with the developer's time zone would be asserting the machine.
var taipei = Calendar(identifier: .gregorian)
taipei.timeZone = TimeZone(identifier: "Asia/Taipei")!

func at(_ text: String, calendar: Calendar = taipei) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    guard let date = formatter.date(from: text) else {
        fatalError("test fixture: unparsable date \(text)")
    }
    return date
}

func metric(_ kind: MetricKind, used: Double, resetsAt: Date?) -> UsageMetric {
    UsageMetric(id: kind.rawValue, kind: kind, label: kind.rawValue, modelName: nil,
                usedPercent: used, severity: .fromUsedPercent(used), resetsAt: resetsAt,
                isActive: false)
}

func usage(_ id: String, session: UsageMetric?, error: String? = nil,
           lastRefreshFailed: Bool = false) -> AccountUsage {
    AccountUsage(id: id, providerID: "claude", accountLabel: id, planName: nil,
                 metrics: [session].compactMap { $0 }, refreshedAt: at("2026-08-24 07:00"),
                 error: error, lastRefreshFailed: lastRefreshFailed)
}

func candidate(_ id: String, provider: String = "claude", home: String? = "/Users/tester/.claude2",
               enabled: Bool = true, readable: Bool = true,
               windowOpen: Bool = false) -> EarlyStartCandidate {
    EarlyStartCandidate(accountID: id, providerID: provider, home: home,
                        isEnabled: enabled, readingIsUsable: readable, windowIsOpen: windowOpen)
}

// 1. THE FIRST-RUN GATE. The feature ships on, so the switch alone must not be enough: nothing may
//    be sent before the one-time notice has been answered. All four rows, because the interesting
//    one is "on but never told".
do {
    expect(EarlyStartLogic.isArmed(enabled: true, noticeAcknowledged: true),
           "on and told: armed")
    expect(!EarlyStartLogic.isArmed(enabled: true, noticeAcknowledged: false),
           "on but never told: NOT armed (the default-on gate)")
    expect(!EarlyStartLogic.isArmed(enabled: false, noticeAcknowledged: true),
           "off but told: not armed")
    expect(!EarlyStartLogic.isArmed(enabled: false, noticeAcknowledged: false),
           "off and never told: not armed")
}

// 2. THE NEXT TRIGGER. Strictly after now, so a fire at 07:00 sets tomorrow rather than itself.
do {
    let before = EarlyStartLogic.nextTrigger(after: at("2026-08-24 06:30"), hour: 7, minute: 0,
                                             calendar: taipei)
    expect(before == at("2026-08-24 07:00"), "before the hour, the next trigger is today's")

    let onTheDot = EarlyStartLogic.nextTrigger(after: at("2026-08-24 07:00"), hour: 7, minute: 0,
                                               calendar: taipei)
    expect(onTheDot == at("2026-08-25 07:00"),
           "at the hour, the next trigger is tomorrow's (strictly after)")

    let after = EarlyStartLogic.nextTrigger(after: at("2026-08-24 09:15"), hour: 7, minute: 0,
                                            calendar: taipei)
    expect(after == at("2026-08-25 07:00"), "past the hour, the next trigger is tomorrow's")

    // Changing the time recomputes rather than keeping the old ladder: 06:30 is before 07:00 but
    // after 06:00, so the same instant answers today for one setting and tomorrow for the other.
    let moved = EarlyStartLogic.nextTrigger(after: at("2026-08-24 06:30"), hour: 6, minute: 0,
                                            calendar: taipei)
    expect(moved == at("2026-08-25 06:00"), "a changed time recomputes the next trigger")

    let minutes = EarlyStartLogic.nextTrigger(after: at("2026-08-24 07:00"), hour: 7, minute: 45,
                                              calendar: taipei)
    expect(minutes == at("2026-08-24 07:45"), "the minute is part of the trigger, not ignored")
}

// 3. …across a daylight saving jump, where a naive "add 86400" would drift by an hour. New York
//    springs forward on 2026-03-08 at 02:00; 07:00 exists on both sides of it.
do {
    var newYork = Calendar(identifier: .gregorian)
    newYork.timeZone = TimeZone(identifier: "America/New_York")!
    let eve = at("2026-03-07 09:00", calendar: newYork)
    let next = EarlyStartLogic.nextTrigger(after: eve, hour: 7, minute: 0, calendar: newYork)
    expect(next == at("2026-03-08 07:00", calendar: newYork),
           "the trigger stays at 07:00 local across a spring-forward day")
    let parts = newYork.dateComponents([.hour, .minute], from: next ?? eve)
    expect(parts.hour == 7 && parts.minute == 0, "…and reads as 07:00 in that calendar")
}

// 4. HAS TODAY'S TRIGGER PASSED - the question a wake, and a launch, asks.
do {
    expect(!EarlyStartLogic.triggerHasPassed(now: at("2026-08-24 06:59"), hour: 7, minute: 0,
                                             calendar: taipei),
           "a minute before the hour has not passed")
    expect(EarlyStartLogic.triggerHasPassed(now: at("2026-08-24 07:00"), hour: 7, minute: 0,
                                            calendar: taipei),
           "the hour itself counts as passed")
    expect(EarlyStartLogic.triggerHasPassed(now: at("2026-08-24 23:59"), hour: 7, minute: 0,
                                            calendar: taipei),
           "late the same day has passed")
    expect(!EarlyStartLogic.triggerHasPassed(now: at("2026-08-25 00:30"), hour: 7, minute: 0,
                                             calendar: taipei),
           "just after midnight is a NEW day whose trigger has not come yet")
}

// 5. IS THE WINDOW ALREADY OPEN - read from the numbers the app already polls, both halves
//    required. Every cell of reset (future / past / absent) by spend (some / none), plus the
//    account that reports no session line at all.
do {
    let now = at("2026-08-24 07:00")
    let future = at("2026-08-24 11:00")
    let past = at("2026-08-24 05:00")

    expect(EarlyStartLogic.windowIsOpen(
        usage("a", session: metric(.session, used: 12, resetsAt: future)), now: now),
        "a future reset with something spent is an open window")
    expect(!EarlyStartLogic.windowIsOpen(
        usage("a", session: metric(.session, used: 0, resetsAt: future)), now: now),
        "a future reset with nothing spent is not open")
    expect(!EarlyStartLogic.windowIsOpen(
        usage("a", session: metric(.session, used: 40, resetsAt: past)), now: now),
        "a reset in the past is a window that closed, however much it holds")
    expect(!EarlyStartLogic.windowIsOpen(
        usage("a", session: metric(.session, used: 40, resetsAt: nil)), now: now),
        "a session line with no reset to name is not an open window")
    expect(!EarlyStartLogic.windowIsOpen(usage("a", session: nil), now: now),
           "no session line at all is not an open window")
    // The weekly window is a different window, and a busy week says nothing about this morning.
    expect(!EarlyStartLogic.windowIsOpen(
        AccountUsage(id: "a", providerID: "claude", accountLabel: "a", planName: nil,
                     metrics: [metric(.weeklyAll, used: 80, resetsAt: future)],
                     refreshedAt: now, error: nil), now: now),
        "a spent WEEKLY window is not an open session window")
}

// 6. IS THE LATEST READING USABLE - both halves, because a failed poll does not announce itself as
//    an error on the round it happens. `foldLastGood` republishes the last good numbers and sets
//    `lastRefreshFailed` alone; `error` arrives only once a streak has made the account stale. A
//    check on `error` would therefore decide this morning on numbers fetched before it.
do {
    let now = at("2026-08-24 07:30")
    let open = metric(.session, used: 12, resetsAt: at("2026-08-24 11:00"))

    expect(EarlyStartLogic.readingIsUsable(usage("a", session: open)),
           "a poll that succeeded is usable")
    expect(!EarlyStartLogic.readingIsUsable(usage("a", session: open, lastRefreshFailed: true)),
           "a held-over reading is NOT usable, though it carries no error yet (the first failure)")
    expect(!EarlyStartLogic.readingIsUsable(
        usage("a", session: open, error: "boom", lastRefreshFailed: true)),
        "…nor once the streak has added the error the badge reads")
    expect(!EarlyStartLogic.readingIsUsable(usage("a", session: open, error: "boom")),
           "…nor a bare error with the flag somehow unset")

    // What that produces. The held-over numbers say the window is closed, which is the answer that
    // SENDS a message, and this morning may not act on it: they are not this morning's numbers.
    let held = usage("a", session: metric(.session, used: 0, resetsAt: nil), lastRefreshFailed: true)
    let stale = candidate("a", readable: EarlyStartLogic.readingIsUsable(held),
                          windowOpen: EarlyStartLogic.windowIsOpen(held, now: now))
    expect(EarlyStartLogic.pass(stale, state: EarlyStartState(), now: now, calendar: taipei)
             == .unreadable,
           "an account on a held-over reading is passed over rather than started")
}

// 7. WHO IS PASSED OVER, and in which order. The order matters: a signed-out account also reports
//    an unusable reading, and "no credential here" is the better of the two answers.
do {
    let now = at("2026-08-24 07:30")
    let today = EarlyStartLogic.dayKey(now, calendar: taipei)
    let empty = EarlyStartState()

    func pass(_ item: EarlyStartCandidate, state: EarlyStartState = EarlyStartState())
        -> EarlyStartSkip? {
        EarlyStartLogic.pass(item, state: state, now: now, calendar: taipei)
    }

    expect(pass(candidate("a")) == nil, "an enabled, launchable, readable, closed account starts")
    expect(pass(candidate("a", provider: "codex")) == .otherProvider,
           "Codex is out of scope in v1")
    expect(pass(candidate("a", enabled: false)) == .accountOff, "a switched-off account is passed")
    expect(pass(candidate("a", home: nil)) == .notLaunchable,
           "an account with nothing to launch with is passed")
    expect(pass(candidate("a", home: nil, readable: false)) == .notLaunchable,
           "…and that answer wins over the unreadable one it also produces")
    expect(pass(candidate("a", readable: false)) == .unreadable,
           "an account whose latest poll failed is passed: the window state is not known")
    expect(pass(candidate("a", windowOpen: true)) == .windowOpen,
           "an account already working is left alone")

    var suppressed = empty
    suppressed.suppressedDay = today
    expect(pass(candidate("a"), state: suppressed) == .daySuppressed,
           "a day the schedule was armed after is not its day")
    var yesterdaySuppressed = empty
    yesterdaySuppressed.suppressedDay = "2026-08-23"
    expect(pass(candidate("a"), state: yesterdaySuppressed) == nil,
           "…and yesterday's suppression does not carry into today")

    var started = empty
    started.startedDays["a"] = today
    expect(pass(candidate("a"), state: started) == .alreadyStarted,
           "one message per account per morning")
    expect(pass(candidate("b"), state: started) == nil,
           "…per ACCOUNT: a sibling that has not had its message still gets one")
    var startedYesterday = empty
    startedYesterday.startedDays["a"] = "2026-08-23"
    expect(pass(candidate("a"), state: startedYesterday) == nil,
           "yesterday's message does not stand in for today's")
}

// 8. WHICH PASSES COUNT AS SKIPS, and which FINISH the account's day. Two axes over the same seven
//    reasons, and they disagree about every case they share. The first is what the row reports, and
//    getting `alreadyStarted` wrong there is what would let a 9am wake overwrite the 7am run's
//    record with a true sentence about the wrong event (see 10). The second is what stops a later
//    refresh from acting (see 11), and getting `unreadable` wrong there would silently delete the
//    catch-up this feature is most obviously for.
do {
    expect(EarlyStartSkip.windowOpen.countsAsSkip && EarlyStartSkip.unreadable.countsAsSkip
             && EarlyStartSkip.notLaunchable.countsAsSkip,
           "the three in-scope passes count as skips")
    expect(!EarlyStartSkip.otherProvider.countsAsSkip && !EarlyStartSkip.accountOff.countsAsSkip
             && !EarlyStartSkip.daySuppressed.countsAsSkip
             && !EarlyStartSkip.alreadyStarted.countsAsSkip,
           "the four out-of-scope ones do not")

    expect(EarlyStartSkip.windowOpen.completesDay,
           "an account that was already working has had its morning")
    expect(!EarlyStartSkip.unreadable.completesDay && !EarlyStartSkip.notLaunchable.completesDay,
           "…while 'not known yet' is not 'not today': both stay retryable all day")
    expect(!EarlyStartSkip.otherProvider.completesDay && !EarlyStartSkip.accountOff.completesDay
             && !EarlyStartSkip.alreadyStarted.completesDay
             && !EarlyStartSkip.daySuppressed.completesDay,
           "the other four are terminal elsewhere in the state, or were never in scope")
}

// 9. ONE MORNING'S PLAN over a mixed fleet.
do {
    let now = at("2026-08-24 07:30")
    let plan = EarlyStartLogic.plan(
        candidates: [candidate("closed"), candidate("busy", windowOpen: true),
                     candidate("codex", provider: "codex"), candidate("off", enabled: false),
                     candidate("signedout", home: nil)],
        state: EarlyStartState(), now: now, calendar: taipei)
    expect(plan.start.map(\.accountID) == ["closed"], "only the closed account is started")
    expect(plan.passed == [EarlyStartPass(accountID: "busy", reason: .windowOpen),
                           EarlyStartPass(accountID: "codex", reason: .otherProvider),
                           EarlyStartPass(accountID: "off", reason: .accountOff),
                           EarlyStartPass(accountID: "signedout", reason: .notLaunchable)],
           "every other account is passed over with its own reason")
    expect(plan.skippedCount == 2,
           "…of which two are in scope and counted (the busy one and the signed-out one)")
    expect(plan.isReportable, "a morning that started something is a morning")

    // A fleet where everything is already working: nothing to send, and still worth writing down -
    // "0 started, 2 skipped" is the answer to "did it run this morning?".
    let allBusy = EarlyStartLogic.plan(
        candidates: [candidate("a", windowOpen: true), candidate("b", windowOpen: true)],
        state: EarlyStartState(), now: now, calendar: taipei)
    expect(allBusy.start.isEmpty && allBusy.skippedCount == 2, "an all-busy fleet starts nothing")
    expect(allBusy.isReportable, "…and still counts as a run that happened")

    // A fleet with nothing in scope at all: not a run, and must not be written down.
    let none = EarlyStartLogic.plan(
        candidates: [candidate("codex", provider: "codex"), candidate("off", enabled: false)],
        state: EarlyStartState(), now: now, calendar: taipei)
    expect(!none.isReportable, "a fleet with nothing in scope is not a run")
}

// 10. THE WAKE THAT MUST NOT OVERWRITE THE MORNING. 07:00 starts two accounts; the lid opens at
//    09:00 and every account reports `alreadyStarted`, which is not a run.
do {
    let morning = at("2026-08-24 07:00")
    let later = at("2026-08-24 09:00")
    let fleet = [candidate("a"), candidate("b")]

    let first = EarlyStartLogic.plan(candidates: fleet, state: EarlyStartState(), now: morning,
                                     calendar: taipei)
    let afterFirst = EarlyStartLogic.recording(EarlyStartState(), plan: first,
                                               attempted: first.start.map(\.accountID),
                                               failed: 0, now: morning, calendar: taipei)
    expect(afterFirst.lastRun?.started == 2 && afterFirst.lastRun?.skipped == 0,
           "the morning records two started")

    let second = EarlyStartLogic.plan(candidates: fleet, state: afterFirst, now: later,
                                      calendar: taipei)
    expect(second.start.isEmpty, "the 9am wake starts nothing")
    expect(!second.isReportable, "…and is not a run at all")
    let afterSecond = EarlyStartLogic.recording(afterFirst, plan: second, attempted: [], failed: 0,
                                                now: later, calendar: taipei)
    expect(afterSecond.lastRun == afterFirst.lastRun,
           "…so the 7am record survives it untouched")
}

// 11. THE ACCOUNT THAT WAS ALREADY WORKING AT 07:00 gets nothing later the same day. Its window
//     closes at lunchtime, and without a stamp the next refresh reads a closed window and opens a
//     new one on its behalf, hours after the morning the Settings row promises.
do {
    let morning = at("2026-08-24 07:00")
    let noon = at("2026-08-24 12:00")

    let plan = EarlyStartLogic.plan(
        candidates: [candidate("idle"), candidate("busy", windowOpen: true)],
        state: EarlyStartState(), now: morning, calendar: taipei)
    expect(plan.skippedCount == 1, "the busy account is still counted in the row's 'N skipped'")
    let after = EarlyStartLogic.recording(EarlyStartState(), plan: plan, attempted: ["idle"],
                                          failed: 0, now: morning, calendar: taipei)
    expect(after.startedDays["busy"] == "2026-08-24",
           "…and its morning is stamped, though no message was sent on its behalf")
    expect(EarlyStartLogic.pass(candidate("busy"), state: after, now: noon, calendar: taipei)
             == .alreadyStarted,
           "so noon, with that window since closed, starts nothing for it")

    // THE CONTRAST, and the reason this is a property of the reason rather than of every pass: an
    // account whose poll failed at 07:00 is the case the catch-up exists for, and must not be
    // stamped by the same code path.
    let hazy = EarlyStartLogic.plan(candidates: [candidate("hazy", readable: false)],
                                    state: EarlyStartState(), now: morning, calendar: taipei)
    let afterHazy = EarlyStartLogic.recording(EarlyStartState(), plan: hazy, attempted: [],
                                              failed: 0, now: morning, calendar: taipei)
    expect(afterHazy.startedDays["hazy"] == nil, "an unreadable account is not stamped")
    expect(EarlyStartLogic.pass(candidate("hazy"), state: afterHazy, now: at("2026-08-24 08:00"),
                                calendar: taipei) == nil,
           "…so 08:00, with the poll succeeding again, still opens its window")
}

// 12. ARMING NEVER BACKFILLS THE DAY SOMEBODY CHANGED THEIR MIND ON, and never suppresses a day
//     that is still going to happen.
do {
    let early = at("2026-08-24 06:00")
    let late = at("2026-08-24 10:00")

    let armedEarly = EarlyStartLogic.arming(EarlyStartState(), now: early, hour: 7, minute: 0,
                                            calendar: taipei)
    expect(armedEarly.suppressedDay == nil,
           "switched on before the hour: today still happens")
    expect(EarlyStartLogic.pass(candidate("a"), state: armedEarly, now: at("2026-08-24 07:05"),
                                calendar: taipei) == nil,
           "…and 07:05 that same day starts the account")

    let armedLate = EarlyStartLogic.arming(EarlyStartState(), now: late, hour: 7, minute: 0,
                                           calendar: taipei)
    expect(armedLate.suppressedDay == "2026-08-24",
           "switched on after the hour: today is spent")
    expect(EarlyStartLogic.pass(candidate("a"), state: armedLate, now: late,
                                calendar: taipei) == .daySuppressed,
           "…so nothing is sent the moment the switch moves")
    expect(EarlyStartLogic.pass(candidate("a"), state: armedLate, now: at("2026-08-25 07:00"),
                                calendar: taipei) == nil,
           "…and tomorrow is unaffected")

    // Arming keeps whatever the state already held: it says something about today, not about the
    // accounts.
    var held = EarlyStartState()
    held.startedDays["a"] = "2026-08-24"
    held.lastRun = EarlyStartRun(at: early, started: 1, skipped: 0)
    let armedOver = EarlyStartLogic.arming(held, now: late, hour: 7, minute: 0, calendar: taipei)
    expect(armedOver.startedDays == held.startedDays && armedOver.lastRun == held.lastRun,
           "arming leaves the run record and the day stamps alone")
}

// 13. RECORDING: stamps, counts and the prune.
do {
    let now = at("2026-08-24 07:00")
    let plan = EarlyStartLogic.plan(candidates: [candidate("a"), candidate("b"),
                                                 candidate("c", windowOpen: true)],
                                    state: EarlyStartState(), now: now, calendar: taipei)
    var before = EarlyStartState()
    before.startedDays["ancient"] = "2026-08-01"
    before.suppressedDay = "2026-08-23"

    let after = EarlyStartLogic.recording(before, plan: plan, attempted: ["a", "b"], failed: 0,
                                          now: now, calendar: taipei)
    expect(after.startedDays["a"] == "2026-08-24" && after.startedDays["b"] == "2026-08-24",
           "every attempted account is stamped with today")
    expect(after.startedDays["ancient"] == nil, "stamps from other days are pruned")
    expect(after.suppressedDay == nil, "a suppression from another day is cleared")
    expect(after.lastRun?.started == 2 && after.lastRun?.skipped == 1 && after.lastRun?.failed == 0,
           "the record counts started and skipped")
    expect(after.lastRun?.at == now, "…and is stamped with the moment the run began")

    // A failure is subtracted from "started" and reported on its own, because a switch that reads
    // "on" and sends nothing has to say so somewhere.
    let withFailure = EarlyStartLogic.recording(before, plan: plan, attempted: ["a", "b"],
                                                failed: 1, now: now, calendar: taipei)
    expect(withFailure.lastRun?.started == 1 && withFailure.lastRun?.failed == 1,
           "one failure of two attempts records one started and one failed")
    expect(withFailure.startedDays["a"] == "2026-08-24" && withFailure.startedDays["b"] == "2026-08-24",
           "…and BOTH are still stamped: the promise is one attempt per account per morning")

    // No claude on the machine: nothing was attempted, so nothing that WOULD have been started is
    // stamped, and the row says so.
    let missing = EarlyStartLogic.recording(EarlyStartState(), plan: plan, attempted: [],
                                            failed: plan.start.count, now: now, calendar: taipei)
    expect(missing.lastRun?.started == 0 && missing.lastRun?.failed == 2,
           "a missing CLI records two that could not start")
    expect(missing.startedDays["a"] == nil && missing.startedDays["b"] == nil,
           "…and stamps neither of them, so an install that lands later still gets its morning")
    // The busy account is stamped all the same: whether a CLI exists has nothing to do with it,
    // its morning was over before the question came up (see 11).
    expect(missing.startedDays["c"] == "2026-08-24",
           "…while the account that was already working is finished with or without a CLI")
}

// 14. THE PERSISTED STATE READS BACK, including a payload written before a field existed. The
//     store treats a decode failure as "no state at all", which would re-send every message
//     already sent today, so a throwing decoder is the expensive kind of wrong.
do {
    var state = EarlyStartState()
    state.startedDays = ["a": "2026-08-24"]
    state.suppressedDay = "2026-08-24"
    state.lastRun = EarlyStartRun(at: at("2026-08-24 07:00"), started: 2, skipped: 1, failed: 0)
    let data = try! JSONEncoder().encode(state)
    expect((try? JSONDecoder().decode(EarlyStartState.self, from: data)) == state,
           "the state round-trips")

    let older = Data(#"{"startedDays":{"a":"2026-08-24"}}"#.utf8)
    let decodedOlder = try? JSONDecoder().decode(EarlyStartState.self, from: older)
    expect(decodedOlder?.startedDays == ["a": "2026-08-24"] && decodedOlder?.lastRun == nil,
           "a payload without the later fields still reads")

    let emptiest = Data("{}".utf8)
    expect((try? JSONDecoder().decode(EarlyStartState.self, from: emptiest)) == EarlyStartState(),
           "an empty payload reads as an empty state rather than throwing")

    let runWithoutFailed = Data(#"{"at":776415600,"started":2,"skipped":1}"#.utf8)
    expect((try? JSONDecoder().decode(EarlyStartRun.self, from: runWithoutFailed))?.failed == 0,
           "a run record written before the failure count reads it as zero")
}

// 15. THE SPAWN'S SHAPE. Asserted exactly rather than by "contains", so a flag that goes missing
//     goes red instead of being covered by the ones that remain.
do {
    expect(EarlyStartCommand.arguments
             == ["-p", "Good morning", "--strict-mcp-config", "--safe-mode",
                 "--no-session-persistence"],
           "the argument list is exactly the five words it is meant to be")
    expect(EarlyStartCommand.arguments.contains("--strict-mcp-config"),
           "…and carries the MCP isolation flag, which is the one that is not negotiable")
    expect(EarlyStartCommand.prompt.count <= 32, "the prompt stays short")
    expect(EarlyStartCommand.timeout == 120, "a wedged CLI is terminated the same morning")

    let directory = EarlyStartCommand.directory.standardizedFileURL.path
    expect(directory.hasSuffix("/.tally/early-start"),
           "the run happens in Tally's own scratch directory")
    // The reason that directory exists at all: a `claude -p` started inside a repository adopts
    // that repository's hooks and instructions.
    expect(!directory.contains("/workspace/"),
           "…which is not inside any repository")
}

// 16. THE CONFIG HOME, which is the one thing that decides WHICH account a message is sent from.
do {
    let userHome = URL(fileURLWithPath: "/Users/tester")

    let second = EarlyStartCommand.environment(home: "/Users/tester/.claude2", userHome: userHome)
    expect(second["CLAUDE_CONFIG_DIR"] == .some("/Users/tester/.claude2"),
           "a numbered home is passed in CLAUDE_CONFIG_DIR")
    expect(second.count == 1, "…and nothing else is added to the environment")

    // The default home runs with the variable REMOVED, not set to its own path: the CLI namespaces
    // its keychain item by the exact variable string, so spelling out the default makes it look up
    // an item that does not exist. A key present with a nil value is what CLIRunner reads as
    // "remove this"; a missing key would leave whatever the user's shell profile exported.
    let main = EarlyStartCommand.environment(home: "/Users/tester/.claude", userHome: userHome)
    expect(main.keys.contains("CLAUDE_CONFIG_DIR"),
           "the default home still names the variable")
    expect(main["CLAUDE_CONFIG_DIR"] == .some(nil),
           "…with a nil value, which is how it gets UNSET rather than left inherited")

    let trailing = EarlyStartCommand.environment(home: "/Users/tester/./.claude/",
                                                 userHome: userHome)
    expect(trailing["CLAUDE_CONFIG_DIR"] == .some(nil),
           "the default home is recognised through a non-standardized spelling of it")
}

// 17. THE WHOLE FLEET THROUGH A FAKE RUNNER. It stands in for CLIRunner: every invocation the
//     morning would have made, recorded instead of spawned.
final class FakeProcessRunner {
    struct Call: Equatable {
        var accountID: String
        var invocation: EarlyStartInvocation
    }
    private(set) var calls: [Call] = []
    func run(_ account: EarlyStartCandidate, _ invocation: EarlyStartInvocation) {
        calls.append(Call(accountID: account.accountID, invocation: invocation))
    }
}

do {
    let now = at("2026-08-24 07:00")
    let userHome = URL(fileURLWithPath: "/Users/tester")
    let scratch = userHome.appendingPathComponent(".tally/early-start", isDirectory: true)
    let fleet = [
        candidate("claude:.claude", home: "/Users/tester/.claude"),
        candidate("claude:.claude2", home: "/Users/tester/.claude2"),
        candidate("claude:.claude3", home: "/Users/tester/.claude3", windowOpen: true),
        candidate("codex:.codex", provider: "codex", home: "/Users/tester/.codex"),
    ]
    let plan = EarlyStartLogic.plan(candidates: fleet, state: EarlyStartState(), now: now,
                                    calendar: taipei)
    let runner = FakeProcessRunner()
    for account in plan.start {
        runner.run(account, EarlyStartCommand.invocation(home: account.home ?? "",
                                                         userHome: userHome, directory: scratch))
    }

    expect(runner.calls.map(\.accountID) == ["claude:.claude", "claude:.claude2"],
           "the busy Claude account and the Codex one are never spawned for")
    expect(runner.calls.allSatisfy { $0.invocation.arguments.contains("--strict-mcp-config") },
           "every spawn carries --strict-mcp-config")
    expect(runner.calls.allSatisfy { $0.invocation.currentDirectory == scratch },
           "every spawn runs in the scratch directory")
    expect(runner.calls.allSatisfy { $0.invocation.timeout == 120 },
           "every spawn carries the same timeout")
    expect(runner.calls.first?.invocation.environment["CLAUDE_CONFIG_DIR"] == .some(nil),
           "the default account's spawn unsets CLAUDE_CONFIG_DIR")
    expect(runner.calls.last?.invocation.environment["CLAUDE_CONFIG_DIR"]
             == .some("/Users/tester/.claude2"),
           "the second account's spawn names its own home")
    // Two accounts, two different homes: the whole point is that they are not the same message
    // sent twice from one account.
    expect(Set(runner.calls.compactMap { $0.invocation.environment["CLAUDE_CONFIG_DIR"] ?? nil })
             .count == 1,
           "…and only one of the two spells a home at all (the other is the unset default)")
    expect(runner.calls.count == 2, "one spawn per account started, and no more")
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
