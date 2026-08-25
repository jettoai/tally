import Foundation

// The relay itself: which accounts are started, which are passed over and why, and the handover
// that gives the feature its name (Tally/Core/EarlyStart.swift).
//
// The sequence in the middle is the whole behaviour change of 2026-08-25 in one run of assertions:
// a window is started, the window it opened is SEEN open, that window closes, and the next message
// goes out. Everything around it exists to pin down the two ways that chain can be faked - by the
// clock alone, and by an attempt that never opened anything.

func runRelayChecks() {
    // 6. IS THE WINDOW ALREADY OPEN - read from the numbers the app already polls, both halves
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
        // The weekly window is a different window, and a busy week says nothing about this moment.
        expect(!EarlyStartLogic.windowIsOpen(
            AccountUsage(id: "a", providerID: "claude", accountLabel: "a", planName: nil,
                         metrics: [metric(.weeklyAll, used: 80, resetsAt: future)],
                         refreshedAt: now, error: nil), now: now),
            "a spent WEEKLY window is not an open session window")
    }

    // 7. IS THE LATEST READING USABLE - both halves, because a failed poll does not announce itself as
    //    an error on the round it happens. `foldLastGood` republishes the last good numbers and sets
    //    `lastRefreshFailed` alone; `error` arrives only once a streak has made the account stale. A
    //    check on `error` would therefore decide on numbers fetched before the failure.
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
        // SENDS a message, and nothing may act on it: they are not this moment's numbers.
        let held = usage("a", session: metric(.session, used: 0, resetsAt: nil), lastRefreshFailed: true)
        let missed = candidate("a", readable: EarlyStartLogic.readingIsUsable(held),
                               keepsFailing: EarlyStartLogic.readingKeepsFailing(held),
                               windowOpen: EarlyStartLogic.windowIsOpen(held, now: now))
        expect(EarlyStartLogic.pass(missed, state: EarlyStartState(), quietHours: loud, now: now,
                                    calendar: taipei) == .pollMissed,
               "an account on a held-over reading is passed over rather than started")

        // …AND ANOTHER FACT FROM THE SAME FOLD DECIDES WHAT IS SAID ABOUT IT. The streak is what a
        // person reading "N skipped" is asking about: the day's list is a set that stands until
        // midnight, so reporting the first miss would name every account that ever lost a poll to a
        // token rotation and go on naming it all day.
        let keptFailing = usage("a", session: metric(.session, used: 0, resetsAt: nil),
                                error: "boom", lastRefreshFailed: true, isStale: true,
                                pollsKeepFailing: true)
        expect(!EarlyStartLogic.readingKeepsFailing(held),
               "one missed round is not an account whose polls keep failing")
        expect(EarlyStartLogic.readingKeepsFailing(keptFailing),
               "…and a streak long enough for the badge to say so is")
        let sustained = candidate("a", readable: EarlyStartLogic.readingIsUsable(keptFailing),
                                  keepsFailing: EarlyStartLogic.readingKeepsFailing(keptFailing),
                                  windowOpen: EarlyStartLogic.windowIsOpen(keptFailing, now: now))
        expect(EarlyStartLogic.pass(sustained, state: EarlyStartState(), quietHours: loud, now: now,
                                    calendar: taipei) == .unreadable,
               "…which is the pass that gets reported, while the single miss is not")

        // THE ACCOUNT THAT HAS NEVER SUCCEEDED, which is the shape this row could not see at all
        // until `pollsKeepFailing` existed. It is signed in and has a home, so it reaches this
        // question; it has no numbers, so the app leaves its BADGE down for good and shows a bare
        // error instead (`foldLastGood`). Asking the badge made a permanently broken account read
        // as one that had blinked, every refresh, forever - the quietest possible way for the row
        // to be wrong (codex review of 60a4fe7).
        let neverLoaded = usage("a", session: nil, error: "network down", lastRefreshFailed: true,
                                isStale: false, pollsKeepFailing: true)
        expect(EarlyStartLogic.readingKeepsFailing(neverLoaded),
               "an account failing every poll since launch is reported though its badge is down")
        let broken = candidate("a", readable: EarlyStartLogic.readingIsUsable(neverLoaded),
                               keepsFailing: EarlyStartLogic.readingKeepsFailing(neverLoaded),
                               windowOpen: EarlyStartLogic.windowIsOpen(neverLoaded, now: now))
        expect(EarlyStartLogic.pass(broken, state: EarlyStartState(), quietHours: loud, now: now,
                                    calendar: taipei) == .unreadable,
               "…so the row names it rather than passing it over in silence")
    }

    // 8. WHO IS PASSED OVER, and in which order. Two orderings are load-bearing: a signed-out account
    //    also reports an unusable reading and "no credential here" is the better answer, and the window
    //    check comes BEFORE the dedup checks, which is the reverse of the morning schedule's order (see
    //    12 for what depends on it).
    do {
        let now = at("2026-08-24 07:30")
        let empty = EarlyStartState()

        func pass(_ item: EarlyStartCandidate, state: EarlyStartState = EarlyStartState(),
                  quiet: EarlyStartQuietHours = loud, at when: Date = at("2026-08-24 07:30"))
            -> EarlyStartSkip? {
            EarlyStartLogic.pass(item, state: state, quietHours: quiet, now: when, calendar: taipei)
        }

        expect(pass(candidate("a")) == nil, "an enabled, launchable, readable, closed account starts")
        expect(pass(candidate("a", provider: "codex")) == .otherProvider,
               "Codex is out of scope in v1")
        expect(pass(candidate("a", enabled: false)) == .accountOff, "a switched-off account is passed")
        expect(pass(candidate("a", home: nil)) == .notLaunchable,
               "an account with nothing to launch with is passed")
        expect(pass(candidate("a", home: nil, readable: false)) == .notLaunchable,
               "…and that answer wins over the unreadable one it also produces")
        expect(pass(candidate("a", readable: false)) == .pollMissed,
               "an account whose latest poll failed is passed: the window state is not known")
        expect(pass(candidate("a", readable: false, keepsFailing: true)) == .unreadable,
               "…and one whose polls keep failing is passed for the reason that gets reported")
        expect(pass(candidate("a", windowOpen: true)) == .windowOpen,
               "an account already working is left alone")

        let quiet = EarlyStartQuietHours(isEnabled: true, startHour: 23, startMinute: 0,
                                         endHour: 7, endMinute: 0)
        expect(pass(candidate("a"), quiet: quiet, at: at("2026-08-24 03:00")) == .quietHours,
               "inside quiet hours nothing is started")
        expect(pass(candidate("a"), quiet: quiet, at: at("2026-08-24 09:00")) == nil,
               "…and outside them the same account starts")
        // Quiet hours sit AFTER the window check, so a night of silence still observes the fleet: the
        // account working at 3am is recorded as such, and its episode ends when that window does.
        expect(pass(candidate("a", windowOpen: true), quiet: quiet, at: at("2026-08-24 03:00"))
                 == .windowOpen,
               "…while an open window is still SEEN during them, not hidden behind the silence")

        var attempted = empty
        attempted.marks["a"] = EarlyStartMark(attemptedAt: now)
        expect(pass(candidate("a"), state: attempted, at: now.addingTimeInterval(60))
                 == .alreadyStarted,
               "one message per account per closed-window stretch")
        expect(pass(candidate("b"), state: attempted, at: now.addingTimeInterval(60)) == nil,
               "…per ACCOUNT: a sibling that has not had its message still gets one")

        var armed = empty
        armed.armedAt = now
        expect(pass(candidate("a"), state: armed, at: now.addingTimeInterval(60)) == .armedMidEpisode,
               "an account whose stretch was underway when the schedule was armed waits for the next")
        expect(pass(candidate("a"), state: armed,
                    at: now.addingTimeInterval(EarlyStartLogic.retryInterval)) == nil,
               "…for at most the retry interval, after which it is started anyway")
    }

    // 9. WHICH PASSES COUNT AS SKIPS, and which are EVIDENCE the window opened. Two axes over the same
    //    nine reasons, listed exhaustively from `everyReason` so a reason added later cannot slip past
    //    both tables. They now share no case at all: one asks what the user should be told, the other
    //    what the provider's numbers proved.
    do {
        expect(everyReason.count == 9 && Set(everyReason.map(\.rawValue)).count == 9,
               "all nine reasons are named here, once each")

        expect(EarlyStartSkip.notLaunchable.countsAsSkip && EarlyStartSkip.unreadable.countsAsSkip,
               "the two that mean an account gets nothing while the switch reads on are reported")
        expect(everyReason.filter(\.countsAsSkip).map(\.rawValue) == ["notLaunchable", "unreadable"],
               "…and they are the ONLY two")
        // The narrowing that came with the relay. Under a once-a-morning schedule "already open at
        // 07:00" was news; under a relay it is the steady state of every account the feature has just
        // successfully started, so counting it would put the whole fleet in the skipped column on a day
        // when everything worked.
        expect(!EarlyStartSkip.windowOpen.countsAsSkip,
               "an account that is simply working is not a skip: that is the feature succeeding")
        expect(!EarlyStartSkip.quietHours.countsAsSkip && !EarlyStartSkip.alreadyStarted.countsAsSkip
                 && !EarlyStartSkip.armedMidEpisode.countsAsSkip,
               "…and neither is silence somebody asked for, nor a stretch already dealt with")
        // The debounce, as a truth-table row: one missed poll is not news, a streak of them is. The
        // list this feeds is a set that only clears at midnight, so the difference is between a row
        // that reads wrong until tomorrow and one that reads wrong for a minute.
        expect(!EarlyStartSkip.pollMissed.countsAsSkip && EarlyStartSkip.unreadable.countsAsSkip,
               "…nor is a single missed poll, though the streak it may become is")

        expect(EarlyStartSkip.windowOpen.observesOpenWindow,
               "an open window is evidence the window opened")
        expect(everyReason.filter(\.observesOpenWindow).map(\.rawValue) == ["windowOpen"],
               "…and it is the only reason that proves anything about the provider's side")
        expect(everyReason.allSatisfy { !($0.countsAsSkip && $0.observesOpenWindow) },
               "the two axes share no case: what is reported and what is proved are different questions")
    }

    // 10. ONE EVALUATION'S PLAN over a mixed fleet.
    do {
        let now = at("2026-08-24 07:30")
        let plan = EarlyStartLogic.plan(
            candidates: [candidate("closed"), candidate("busy", windowOpen: true),
                         candidate("codex", provider: "codex"), candidate("off", enabled: false),
                         candidate("signedout", home: nil)],
            state: EarlyStartState(), quietHours: loud, now: now, calendar: taipei)
        expect(plan.start.map(\.accountID) == ["closed"], "only the closed account is started")
        expect(plan.passed == [EarlyStartPass(accountID: "busy", reason: .windowOpen),
                               EarlyStartPass(accountID: "codex", reason: .otherProvider),
                               EarlyStartPass(accountID: "off", reason: .accountOff),
                               EarlyStartPass(accountID: "signedout", reason: .notLaunchable)],
               "every other account is passed over with its own reason")
        expect(plan.skippedCount == 1,
               "…of which one is worth reporting (the signed-out one; the busy one is working)")
        expect(plan.isReportable && plan.needsRecording,
               "an evaluation that started something is both reported and recorded")

        // A fleet where everything is already working. Nothing to report - and it MUST still be
        // recorded, because "these two are working" is the fact that ends their episodes.
        let allBusy = EarlyStartLogic.plan(
            candidates: [candidate("a", windowOpen: true), candidate("b", windowOpen: true)],
            state: EarlyStartState(), quietHours: loud, now: now, calendar: taipei)
        expect(allBusy.start.isEmpty && allBusy.skippedCount == 0, "an all-busy fleet starts nothing")
        expect(!allBusy.isReportable, "…and puts nothing on the row")
        expect(allBusy.needsRecording,
               "…but is still written down: the observation is what makes the relay a relay")

        // A fleet where one account blinked and another has been failing for a while. Neither is
        // started - the window state is not known for either - and only the sustained one is put on
        // the day's row, which is what keeps a token rotation from leaving a mark until midnight.
        let flaky = EarlyStartLogic.plan(
            candidates: [candidate("blinked", readable: false),
                         candidate("failing", readable: false, keepsFailing: true)],
            state: EarlyStartState(), quietHours: loud, now: now, calendar: taipei)
        expect(flaky.start.isEmpty, "neither unreadable account is started")
        expect(flaky.passed.map(\.reason) == [.pollMissed, .unreadable],
               "…and they are passed over for different reasons")
        expect(flaky.skippedCount == 1 && flaky.isReportable,
               "…of which only the sustained one reaches the row")

        // A fleet whose only content is one missed poll writes nothing at all: no row, and no state,
        // so the account is asked again on the next refresh with nothing carried over.
        let blink = EarlyStartLogic.plan(candidates: [candidate("blinked", readable: false)],
                                         state: EarlyStartState(), quietHours: loud, now: now,
                                         calendar: taipei)
        expect(!blink.isReportable && !blink.needsRecording,
               "a fleet whose only news is one missed poll writes nothing")

        // A fleet with nothing in scope at all: neither reported nor recorded.
        let none = EarlyStartLogic.plan(
            candidates: [candidate("codex", provider: "codex"), candidate("off", enabled: false)],
            state: EarlyStartState(), quietHours: loud, now: now, calendar: taipei)
        expect(!none.isReportable && !none.needsRecording,
               "a fleet with nothing in scope writes nothing at all")

        // A whole fleet inside quiet hours: nothing started, nothing reported, nothing recorded.
        let asleep = EarlyStartLogic.plan(
            candidates: [candidate("a"), candidate("b")], state: EarlyStartState(),
            quietHours: EarlyStartQuietHours(isEnabled: true, startHour: 23, startMinute: 0,
                                             endHour: 7, endMinute: 0),
            now: at("2026-08-24 03:00"), calendar: taipei)
        expect(asleep.start.isEmpty && !asleep.isReportable && !asleep.needsRecording,
               "a fleet inside quiet hours is left entirely alone")
    }

    // 11. THE RELAY, END TO END: an account is started, its window opens, the window closes, and it is
    //     started again. This is the whole behaviour change of 2026-08-25 in one sequence.
    do {
        let opened = at("2026-08-24 09:00")
        var state = EarlyStartState()

        // 09:00 - the window is closed, so a message goes out.
        let first = EarlyStartLogic.plan(candidates: [candidate("a")], state: state, quietHours: loud,
                                         now: opened, calendar: taipei)
        expect(first.start.map(\.accountID) == ["a"], "a closed window is started")
        state = EarlyStartLogic.recording(state, plan: first, attempted: ["a"], failed: [], now: opened,
                                          calendar: taipei)
        expect(state.marks["a"]?.attemptedAt == opened && state.marks["a"]?.sawWindowOpen == false,
               "…and the account is marked with the moment it was attempted")

        // 09:05 - the next refresh reads the window the message opened. Nothing is sent; what happens
        // is the observation.
        let seen = at("2026-08-24 09:05")
        let watching = EarlyStartLogic.plan(candidates: [candidate("a", windowOpen: true)],
                                            state: state, quietHours: loud, now: seen, calendar: taipei)
        expect(watching.start.isEmpty && watching.passed.first?.reason == .windowOpen,
               "the window it opened is seen open, and nothing more is sent")
        state = EarlyStartLogic.recording(state, plan: watching, attempted: [], failed: [], now: seen,
                                          calendar: taipei)
        expect(state.marks["a"]?.sawWindowOpen == true,
               "…and the account is recorded as having had a window since its message")
        expect(state.marks["a"]?.attemptedAt == opened,
               "…without disturbing the attempt time, which is what bounds the worst case")

        // 14:00 - the window has closed. The account is owed another message, and this is the case the
        // old day-keyed schedule could not serve at all.
        let closed = at("2026-08-24 14:00")
        let second = EarlyStartLogic.plan(candidates: [candidate("a")], state: state, quietHours: loud,
                                          now: closed, calendar: taipei)
        expect(second.start.map(\.accountID) == ["a"],
               "when that window closes the account is started again: the relay hands over")
        state = EarlyStartLogic.recording(state, plan: second, attempted: ["a"], failed: [], now: closed,
                                          calendar: taipei)
        expect(state.marks["a"]?.attemptedAt == closed && state.marks["a"]?.sawWindowOpen == false,
               "…and the new attempt starts a fresh episode rather than inheriting the last one's")

        // 14:05 - and it does not fire twice on the next refresh, which is minutes away.
        let again = EarlyStartLogic.plan(candidates: [candidate("a")], state: state, quietHours: loud,
                                         now: at("2026-08-24 14:05"), calendar: taipei)
        expect(again.start.isEmpty && again.passed.first?.reason == .alreadyStarted,
               "the refresh five minutes later starts nothing")
    }

    // 12. THE FAILED ATTEMPT, which is the case the observation exists to tell apart. Nothing opened,
    //     so nothing is seen open, and the account waits out the retry interval rather than being
    //     retried by every refresh for five hours.
    do {
        let tried = at("2026-08-24 09:00")
        var state = EarlyStartState()
        let plan = EarlyStartLogic.plan(candidates: [candidate("a")], state: state, quietHours: loud,
                                        now: tried, calendar: taipei)
        // Marked on the ATTEMPT, whatever the CLI answered: that is the promise about cost.
        state = EarlyStartLogic.recording(state, plan: plan, attempted: ["a"], failed: ["a"], now: tried,
                                          calendar: taipei)

        func startsAgain(_ offset: TimeInterval) -> Bool {
            EarlyStartLogic.pass(candidate("a"), state: state, quietHours: loud,
                                 now: tried.addingTimeInterval(offset), calendar: taipei) == nil
        }
        expect(!startsAgain(60), "a minute later, nothing")
        expect(!startsAgain(4 * 60 * 60), "four hours later, still nothing")
        expect(!startsAgain(EarlyStartLogic.retryInterval - 1),
               "one second short of the retry interval, still nothing")
        expect(startsAgain(EarlyStartLogic.retryInterval),
               "at the retry interval exactly, the account is started again")
        expect(EarlyStartLogic.retryInterval == 5 * 60 * 60,
               "…which is five hours: the length of the window that message would have opened")
    }

    // 13. …AND THE OBSERVATION DOES NOT LIFT THE ATTEMPT'S FLOOR. This is the pair to 12: same
    //     elapsed time, and now the SAME answer, because "at most one message per account every 5
    //     hours" is stated three times in the shipping app (EarlyStart.swift, the Settings row and
    //     the panel notice) and nothing may override it.
    //
    //     THE RULE IS BLIND TO WHOSE WINDOW CLOSED, and has to be. It is tempting to argue that a
    //     window closing early must be somebody else's, since ours would run the full five hours;
    //     that is false on ordinary days, because Anthropic resets sessions on a ten-minute grid and
    //     our own window therefore shuts up to ten minutes before the floor lifts. Provenance is
    //     unknowable from here and the promise never depended on it: the floor is about COST, so it
    //     holds against every observation and the relay hands over a few minutes late.
    //
    //     What the observation DOES release is the suppression with no message behind it, and no
    //     cost to bound: the arming stamp. Both halves are asserted here so that neither the
    //     unconditional release this replaced nor a bare deletion of it can pass.
    do {
        let tried = at("2026-08-24 09:00")
        var withWindow = EarlyStartState()
        withWindow.marks["a"] = EarlyStartMark(attemptedAt: tried, sawWindowOpen: true)
        var withoutWindow = EarlyStartState()
        withoutWindow.marks["a"] = EarlyStartMark(attemptedAt: tried, sawWindowOpen: false)
        let soon = at("2026-08-24 10:00")

        func held(_ state: EarlyStartState, at when: Date) -> EarlyStartSkip? {
            EarlyStartLogic.pass(candidate("a"), state: state, quietHours: loud, now: when,
                                 calendar: taipei)
        }

        expect(held(withWindow, at: soon) == .alreadyStarted,
               "an observed window closing an hour after the message does NOT let a second one out")
        expect(held(withoutWindow, at: soon) == .alreadyStarted,
               "…and the same hour with no window observed waits too: it is one floor, not two")
        expect(held(withWindow, at: tried.addingTimeInterval(EarlyStartLogic.retryInterval - 1))
                 == .alreadyStarted,
               "…one second short of the interval, an observed window still changes nothing")
        expect(held(withWindow, at: tried.addingTimeInterval(EarlyStartLogic.retryInterval)) == nil,
               "…and at the interval exactly it goes, a little after its own window actually shut")

        // THE OBSERVATION'S OWN CASE: a mark with no attempt behind it. Nothing was sent, so there
        // is no cost to bound, and a window seen open and then closed ends the episode the arming
        // stamp was holding. Deleting the observation outright rather than qualifying it would
        // answer `.armedMidEpisode` here and decay the relay into a five-hourly alarm.
        var armedAndSeen = EarlyStartState()
        armedAndSeen.armedAt = tried
        armedAndSeen.marks["a"] = EarlyStartMark(attemptedAt: nil, sawWindowOpen: true)
        expect(held(armedAndSeen, at: soon) == nil,
               "an account held by the arming stamp alone IS released by the window it was seen in")
        var armedUnseen = EarlyStartState()
        armedUnseen.armedAt = tried
        expect(held(armedUnseen, at: soon) == .armedMidEpisode,
               "…while the same stamp with no window observed still holds it")
    }
}
