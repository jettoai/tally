import Foundation

// What is written down between evaluations, and what the Settings row reads off it
// (Tally/Core/EarlyStartState.swift, and the folds in EarlyStartLogic).
//
// Two properties carry most of the weight here. The day's tally ACCUMULATES, so every fold has to
// say whether it adds, replaces or leaves alone; and the persisted payload has to READ whatever an
// older build wrote, because the store treats a decode failure as "nothing was ever sent" and would
// send it all again.

func runStateChecks() {
    // 14. ARMING NEVER BACKFILLS THE EPISODE SOMEBODY CHANGED THEIR MIND DURING.
    do {
        let flipped = at("2026-08-24 10:00")
        let armed = EarlyStartLogic.arming(EarlyStartState(), now: flipped)
        expect(armed.armedAt == flipped, "arming stamps the moment the switch moved")
        expect(EarlyStartLogic.pass(candidate("a"), state: armed, quietHours: loud, now: flipped,
                                    calendar: taipei) == .armedMidEpisode,
               "…so nothing is sent the instant the switch moves, even with a closed window in front of it")

        // The next episode is the first window that opens and closes while the feature is on, and it is
        // served without waiting out the retry interval.
        let seen = EarlyStartLogic.recording(
            armed,
            plan: EarlyStartLogic.plan(candidates: [candidate("a", windowOpen: true)], state: armed,
                                       quietHours: loud, now: at("2026-08-24 11:00"), calendar: taipei),
            attempted: [], failed: 0, now: at("2026-08-24 11:00"), calendar: taipei)
        expect(seen.marks["a"]?.sawWindowOpen == true,
               "a window opening after the switch moved is recorded against that account")
        expect(EarlyStartLogic.pass(candidate("a"), state: seen, quietHours: loud,
                                    now: at("2026-08-24 12:00"), calendar: taipei) == nil,
               "…and when it closes, the relay starts: the NEXT episode, as promised")

        // Arming clears the marks it finds, so a `sawWindowOpen` left over from before the feature was
        // switched off cannot let an account through on the strength of a window nobody was watching.
        var stale = EarlyStartState()
        stale.marks["a"] = EarlyStartMark(attemptedAt: at("2026-08-20 09:00"), sawWindowOpen: true)
        let rearmed = EarlyStartLogic.arming(stale, now: flipped)
        expect(rearmed.marks.isEmpty, "arming clears the marks it finds")
        expect(EarlyStartLogic.pass(candidate("a"), state: rearmed, quietHours: loud, now: flipped,
                                    calendar: taipei) == .armedMidEpisode,
               "…so a stale observation cannot survive the switch being turned back on")

        // Arming says something about the schedule, not about the day's tally.
        var held = EarlyStartState()
        held.today = EarlyStartToday(day: "2026-08-24", started: 2)
        expect(EarlyStartLogic.arming(held, now: flipped).today == held.today,
               "arming leaves the day's record alone")
    }

    // 15. RECORDING: marks, observations, and the prune.
    do {
        let now = at("2026-08-24 09:00")
        let plan = EarlyStartLogic.plan(candidates: [candidate("a"), candidate("b"),
                                                     candidate("c", windowOpen: true)],
                                        state: EarlyStartState(), quietHours: loud, now: now,
                                        calendar: taipei)
        var before = EarlyStartState()
        // Two marks that can no longer change an answer: one aged past the retry interval, one with no
        // floor at all.
        before.marks["ancient"] = EarlyStartMark(attemptedAt: at("2026-08-24 03:00"))
        before.marks["floating"] = EarlyStartMark(attemptedAt: nil, sawWindowOpen: true)

        let after = EarlyStartLogic.recording(before, plan: plan, attempted: ["a", "b"], failed: 0,
                                              now: now, calendar: taipei)
        expect(after.marks["a"]?.attemptedAt == now && after.marks["b"]?.attemptedAt == now,
               "every attempted account is marked with the moment of the attempt")
        // The account that was merely working keeps NO mark, and that is the prune doing its job rather
        // than the observation going missing: with nothing suppressing that account there is nothing
        // for an observation to unlock, and a fleet of accounts quietly working would otherwise each
        // carry an entry for the life of the install. The behaviour it would have bought is asserted
        // straight after, because "the record is absent" is only acceptable if the answer is unchanged.
        expect(after.marks["c"] == nil,
               "an observation about an account nothing is suppressing is not kept")
        expect(EarlyStartLogic.pass(candidate("c"), state: after, quietHours: loud,
                                    now: at("2026-08-24 14:00"), calendar: taipei) == nil,
               "…and that account is started the moment its window closes all the same")
        expect(after.marks["ancient"] == nil,
               "a mark older than the retry interval is pruned: it suppresses nothing")
        expect(after.marks["floating"] == nil,
               "…and so is one with no attempt and no arming behind it")

        // An arming stamp keeps the floorless marks alive, because with it they DO suppress something.
        var armedBefore = before
        armedBefore.armedAt = at("2026-08-24 08:00")
        let afterArmed = EarlyStartLogic.recording(armedBefore, plan: plan, attempted: [], failed: 0,
                                                   now: now, calendar: taipei)
        expect(afterArmed.marks["floating"]?.sawWindowOpen == true,
               "with a live arming stamp, a mark with no attempt of its own is kept")
        expect(afterArmed.armedAt == at("2026-08-24 08:00"), "…and the stamp itself is kept")

        var armedLongAgo = before
        armedLongAgo.armedAt = at("2026-08-24 03:00")
        let afterExpired = EarlyStartLogic.recording(armedLongAgo, plan: plan, attempted: [], failed: 0,
                                                     now: now, calendar: taipei)
        expect(afterExpired.armedAt == nil,
               "an arming stamp older than the retry interval is cleared")
        expect(afterExpired.marks["floating"] == nil, "…and takes the marks that leaned on it with it")
    }

    // 16. TODAY'S TALLY: what the Settings row reads. It accumulates across the day, counts accounts
    //     rather than passes for the skipped column, and rolls over at midnight.
    do {
        let morning = at("2026-08-24 09:00")
        let plan = EarlyStartLogic.plan(candidates: [candidate("a"), candidate("b"),
                                                     candidate("busy", windowOpen: true),
                                                     candidate("gone", home: nil)],
                                        state: EarlyStartState(), quietHours: loud, now: morning,
                                        calendar: taipei)
        var state = EarlyStartLogic.recording(EarlyStartState(), plan: plan, attempted: ["a", "b"],
                                              failed: 0, now: morning, calendar: taipei)
        expect(state.today?.day == "2026-08-24" && state.today?.started == 2,
               "the tally names its day and counts what went out")
        expect(state.today?.skipped == ["gone"],
               "…lists the account that could not be reached, and not the one that was merely working")
        expect(state.today?.lastAttemptAt == morning, "…and remembers when the last message went")

        // Later the same day: the counts add up rather than replacing each other, and the same blocked
        // account is not counted twice.
        let noon = at("2026-08-24 13:00")
        let second = EarlyStartLogic.plan(candidates: [candidate("a"), candidate("gone", home: nil)],
                                          state: EarlyStartState(), quietHours: loud, now: noon,
                                          calendar: taipei)
        state = EarlyStartLogic.recording(state, plan: second, attempted: ["a"], failed: 0, now: noon,
                                          calendar: taipei)
        expect(state.today?.started == 3, "a later relay adds to the day rather than replacing it")
        expect(state.today?.skipped == ["gone"] && state.today?.skippedCount == 1,
               "…and the same blocked account is counted once, not once per refresh")
        expect(state.today?.lastAttemptAt == noon, "…while the last-message time moves forward")

        // An evaluation that starts nothing and blocks on nothing must not touch the record.
        let quietPlan = EarlyStartLogic.plan(candidates: [candidate("a", windowOpen: true)],
                                             state: EarlyStartState(), quietHours: loud,
                                             now: at("2026-08-24 13:05"), calendar: taipei)
        let untouched = EarlyStartLogic.recording(state, plan: quietPlan, attempted: [], failed: 0,
                                                  now: at("2026-08-24 13:05"), calendar: taipei)
        expect(untouched.today == state.today,
               "an evaluation with nothing to report leaves the day's record exactly as it was")

        // Midnight: a new day starts from zero rather than adding to yesterday.
        let tomorrow = at("2026-08-25 09:00")
        let fresh = EarlyStartLogic.recording(state, plan: second, attempted: ["a"], failed: 0,
                                              now: tomorrow, calendar: taipei)
        expect(fresh.today?.day == "2026-08-25" && fresh.today?.started == 1,
               "a new day's tally starts from zero")
        expect(fresh.today?.skipped == ["gone"],
               "…and rebuilds its own skipped list rather than inheriting yesterday's counts")

        // No CLI on the machine: nothing was attempted, so nothing is marked, and the row says the
        // accounts could not be started rather than that they were skipped.
        let missing = EarlyStartLogic.recording(EarlyStartState(), plan: plan, attempted: [],
                                                failed: plan.start.count, now: morning,
                                                calendar: taipei)
        expect(missing.today?.started == 0 && missing.today?.failed == 2,
               "a missing CLI records two that could not start")
        expect(missing.today?.lastAttemptAt == nil,
               "…and names no time, because no message was sent")
        expect(missing.marks["a"] == nil && missing.marks["b"] == nil,
               "…and marks neither of them, so an install that lands later is served at once")
        // The observation about the busy account is recorded whether or not a CLI exists - shown here
        // against an arming stamp, which is the state where that observation has something to unlock.
        var armed = EarlyStartState()
        armed.armedAt = at("2026-08-24 08:30")
        let missingArmed = EarlyStartLogic.recording(armed, plan: plan, attempted: [],
                                                     failed: plan.start.count, now: morning,
                                                     calendar: taipei)
        expect(missingArmed.marks["busy"]?.sawWindowOpen == true,
               "…while the observation about the busy account is recorded either way")
    }

    // 17. THE CORRECTION, once the CLIs have answered. The tally is written optimistically before the
    //     spawn (an auto-update relaunch inside the two minutes a CLI gets would otherwise resend
    //     everything), so the answers arrive minutes later and move failures out of the started column.
    do {
        let now = at("2026-08-24 09:00")
        let plan = EarlyStartLogic.plan(candidates: [candidate("a"), candidate("b")],
                                        state: EarlyStartState(), quietHours: loud, now: now,
                                        calendar: taipei)
        let optimistic = EarlyStartLogic.recording(EarlyStartState(), plan: plan,
                                                   attempted: ["a", "b"], failed: 0, now: now,
                                                   calendar: taipei)
        expect(optimistic.today?.started == 2, "both attempts are counted before the answers land")

        let answered = EarlyStartLogic.correcting(optimistic, failed: 1,
                                                  now: at("2026-08-24 09:02"), calendar: taipei)
        expect(answered.today?.started == 1 && answered.today?.failed == 1,
               "one failure of two moves one account out of the started column")
        expect(answered.marks == optimistic.marks,
               "…and the marks are untouched: an attempt costs its five hours whatever the CLI said")

        expect(EarlyStartLogic.correcting(optimistic, failed: 0, now: now, calendar: taipei)
                 == optimistic,
               "no failures corrects nothing")
        // A batch that started before midnight and answered after it would otherwise describe messages
        // the new day never sent.
        expect(EarlyStartLogic.correcting(optimistic, failed: 1, now: at("2026-08-25 00:01"),
                                          calendar: taipei) == optimistic,
               "an answer that lands on the next day leaves both days alone")
        expect(EarlyStartLogic.correcting(EarlyStartState(), failed: 1, now: now, calendar: taipei)
                 == EarlyStartState(),
               "…and a correction with no tally to correct is a no-op rather than a crash")
        // A double correction cannot drive the column negative.
        let twice = EarlyStartLogic.correcting(
            EarlyStartLogic.correcting(optimistic, failed: 2, now: now, calendar: taipei),
            failed: 2, now: now, calendar: taipei)
        expect(twice.today?.started == 0, "the started column never goes below zero")
    }

    // 18. THE PERSISTED STATE READS BACK, including payloads written before a field existed and by the
    //     build before this one. The store treats a decode failure as "no state at all", which would
    //     re-send every message already sent, so a throwing decoder is the expensive kind of wrong.
    do {
        var state = EarlyStartState()
        state.marks = ["a": EarlyStartMark(attemptedAt: at("2026-08-24 09:00"), sawWindowOpen: true)]
        state.armedAt = at("2026-08-24 08:00")
        state.today = EarlyStartToday(day: "2026-08-24", started: 2, failed: 1, skipped: ["gone"],
                                      lastAttemptAt: at("2026-08-24 09:00"))
        let data = try! JSONEncoder().encode(state)
        expect((try? JSONDecoder().decode(EarlyStartState.self, from: data)) == state,
               "the state round-trips")

        let emptiest = Data("{}".utf8)
        expect((try? JSONDecoder().decode(EarlyStartState.self, from: emptiest)) == EarlyStartState(),
               "an empty payload reads as an empty state rather than throwing")

        // THE PAYLOAD THE MORNING SCHEDULE WROTE. Every key in it is gone, and it still has to read:
        // a throw here would be read as "nothing was ever sent" by a build that has just changed the
        // rules about when it sends.
        let morningEra = Data(#"""
            {"startedDays":{"a":"2026-08-24"},"suppressedDay":"2026-08-24",
             "lastRun":{"at":776415600,"started":2,"skipped":1,"failed":0}}
            """#.utf8)
        let migrated = try? JSONDecoder().decode(EarlyStartState.self, from: morningEra)
        expect(migrated == EarlyStartState(),
               "a payload from the morning schedule reads as an empty relay state, not a throw")

        let partialMark = Data(#"{"marks":{"a":{"attemptedAt":776415600}}}"#.utf8)
        let decodedMark = try? JSONDecoder().decode(EarlyStartState.self, from: partialMark)
        expect(decodedMark?.marks["a"]?.sawWindowOpen == false,
               "a mark written before the observation flag reads it as false")

        let partialDay = Data(#"{"day":"2026-08-24","started":2}"#.utf8)
        let decodedDay = try? JSONDecoder().decode(EarlyStartToday.self, from: partialDay)
        expect(decodedDay?.failed == 0 && decodedDay?.skipped == [] && decodedDay?.lastAttemptAt == nil,
               "a tally written before the later columns reads them as empty")
    }
}
