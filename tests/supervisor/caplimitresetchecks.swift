import Foundation

// ANSWERING A 5-HOUR WALL WITH THE ACCOUNT'S OWN WEEKLY RESET (TallyCLI/CapLimitReset.swift): the
// gate table, the hold that keeps the cap handoff standing down while the answer is awaited, and
// the typing itself.
//
// THE GRID IS THE POINT rather than any single case, and it is the whole enumeration rather than a
// sample. What this feature spends is a credit the account gets ONCE A WEEK, and every way of
// spending it wrongly looks identical from outside: a credit gone on a weekly wall it cannot clear,
// a credit gone twice for one wall, a credit gone on an account whose week is nearly over anyway, a
// slash command typed at a permission dialog. So every refusal below is asserted, not just the one
// success.
//
// AND THE ONE THING NO FIXTURE HERE CAN PROVE, said plainly: no account on this machine is in
// Anthropic's rollout for `/limit-reset` (`tengu_nifty_lemur` is false on all five), so nothing
// here has ever seen the command run. What is asserted is the DECISION - which wall, which gates,
// what happens to a session while it waits and when the wait runs out - and the sentences those
// decisions turn on are the product's own, read off its binary and pinned in tests/limitreset.
//
// Everything is pure or pointed at a temporary directory: no `~/.tally`, no terminal, and every
// log and settings document is given a sink of its own.

func runCapLimitResetChecks() {
    let wall = Date(timeIntervalSince1970: 1_800_000_000)
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-caplimitreset-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("input.log")
    let settingsFile = dir.appendingPathComponent("settings.json")

    /// A fixture account. `session` is what separates the capped one from the sibling it would be
    /// handed to: a cap handoff needs a target with room in every window the model spends, so a
    /// sibling built with the capped one's zeroes is not eligible and no plan is ever made
    /// (which is how the first version of the stand-down check below passed for the wrong reason).
    ///
    /// The four freshness fields are parameters because the weekly floor's whole question is which
    /// reading may answer it: every one of them can be true of a row still carrying 60%.
    func account(_ id: String, weekly: Double, session: Double = 0,
                 model: Double = 40, refreshed: Date? = nil, stale: Bool = false,
                 failed: Bool? = nil, error: String? = nil) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: "Claude 2",
                         launchHome: "/tmp/\(id)", sessionRemaining: session,
                         weeklyRemaining: weekly, modelRemaining: model,
                         sessionResetsAt: wall.addingTimeInterval(3 * 3600),
                         weeklyResetsAt: wall.addingTimeInterval(90 * 3600),
                         modelResetsAt: wall.addingTimeInterval(90 * 3600),
                         modelWindowName: "fable", resetCreditsAvailable: nil, isStale: stale,
                         error: error, refreshedAt: refreshed, lastRefreshFailed: failed)
    }

    /// The quarantine a wall leaves behind, in this suite's own directory rather than `~/.tally`:
    /// the session-local map the supervisor holds and the shared per-account file every other
    /// supervisor reads. Both are what a landed reset has to undo.
    let quarantineHome = dir.appendingPathComponent("quarantine")
    var localQuarantine: [String: (model: String?, until: Date)] = [:]
    func quarantineTheWall(model: String? = "fable") {
        let until = wall.addingTimeInterval(capQuarantineTTL)
        localQuarantine["A"] = (model: model, until: until)
        quarantineAccount("A", model: model, until: until, dir: quarantineHome)
    }
    /// Whether an automatic pick for the capped window would still skip the account.
    func stillQuarantined() -> Bool {
        quarantinedAccounts(forPrimary: "fable", sessionLocal: localQuarantine,
                            now: wall.addingTimeInterval(5), dir: quarantineHome).contains("A")
    }
    func sharedRecordExists() -> Bool {
        FileManager.default.fileExists(atPath: quarantineHome.appendingPathComponent("A").path)
    }

    func pending(_ scope: CapScope?, at when: Date = wall,
                 account id: String = "A") -> PendingCapRecovery {
        PendingCapRecovery(cappedAccountID: id, cappedAt: when, primaryModel: "fable",
                           recoveryResetsAt: nil, nextRetry: .distantPast, reason: "",
                           capScope: scope)
    }

    // MARK: - 41a. The gate table, on its own

    // EVERY REFUSAL, one input at a time off a cell that passes, so a check that went green for the
    // wrong reason would have to be green about a different input as well.
    check("a 5-hour wall on an available reset with weekly headroom is allowed",
          capLimitResetAllowed(scope: .session, enabled: true, state: .available,
                               weeklyRemaining: 60, alreadyAttempted: false))
    check("a WEEKLY wall is refused: the reset explicitly does not clear that window",
          !capLimitResetAllowed(scope: .weekly, enabled: true, state: .available,
                                weeklyRemaining: 60, alreadyAttempted: false))
    check("a model-tier wall is refused: it is a different window entirely",
          !capLimitResetAllowed(scope: .model, enabled: true, state: .available,
                                weeklyRemaining: 60, alreadyAttempted: false))
    check("a wall this build could not name is refused rather than guessed at",
          !capLimitResetAllowed(scope: nil, enabled: true, state: .available,
                                weeklyRemaining: 60, alreadyAttempted: false))
    check("the switch off refuses it",
          !capLimitResetAllowed(scope: .session, enabled: false, state: .available,
                                weeklyRemaining: 60, alreadyAttempted: false))
    check("a reset already spent this week is refused",
          !capLimitResetAllowed(scope: .session, enabled: true, state: .used,
                                weeklyRemaining: 60, alreadyAttempted: false))
    check("a login outside the rollout is refused",
          !capLimitResetAllowed(scope: .session, enabled: true, state: .notEnabled,
                                weeklyRemaining: 60, alreadyAttempted: false))
    // THE ONE DELIBERATE EXCEPTION: `unknown` is what every account reads before anything has been
    // observed, so refusing it would mean the feature never fires at all.
    check("an account nothing has been observed about is still tried once",
          capLimitResetAllowed(scope: .session, enabled: true, state: .unknown,
                               weeklyRemaining: 60, alreadyAttempted: false))
    // A CLEARED SESSION WALL IS WORTH NOTHING BEHIND A WEEKLY ONE.
    check("an account with almost no week left is refused: a cleared 5h wall buys minutes",
          !capLimitResetAllowed(scope: .session, enabled: true, state: .available,
                                weeklyRemaining: capLimitResetWeeklyFloor - 1,
                                alreadyAttempted: false))
    check("…and the floor itself is allowed, so the boundary is not off by one",
          capLimitResetAllowed(scope: .session, enabled: true, state: .available,
                               weeklyRemaining: capLimitResetWeeklyFloor, alreadyAttempted: false))
    check("a snapshot that cannot say how much of the week is left refuses",
          !capLimitResetAllowed(scope: .session, enabled: true, state: .available,
                                weeklyRemaining: nil, alreadyAttempted: false))
    check("and a wall already answered once is never answered twice",
          !capLimitResetAllowed(scope: .session, enabled: true, state: .available,
                                weeklyRemaining: 60, alreadyAttempted: true))

    // MARK: - 41a2. WHICH READING may answer that floor

    // A HELD-OVER 60% IS SPELLED EXACTLY LIKE A FRESHLY READ ONE, and the table above cannot tell
    // them apart: it is handed a `Double`. So every fixture here carries the SAME 60% and differs
    // only in what the snapshot says about where that number came from - which is the difference
    // between a floor that is met and a weekly credit spent on a week that may be over
    // (review, 2026-09-06).
    let polled = wall.addingTimeInterval(-60)
    func reading(_ row: Snapshot.Account, problem: String? = nil,
                 now: Date = wall.addingTimeInterval(1)) -> Double? {
        capLimitResetWeekly((Snapshot(version: 2, generatedAt: wall, accounts: [row]), problem),
                            accountID: "A", now: now)
    }
    check("a freshly polled row is a reading the floor may be asked about",
          reading(account("A", weekly: 60, refreshed: polled)) == 60)
    check("a document the loader itself calls too old answers nothing",
          reading(account("A", weekly: 60, refreshed: polled),
                  problem: "snapshot is 40m old - is Tally.app running?") == nil)
    check("a row whose LATEST poll failed answers nothing: those numbers are held over",
          reading(account("A", weekly: 60, refreshed: polled, failed: true)) == nil)
    check("a row the app has marked stale answers nothing",
          reading(account("A", weekly: 60, refreshed: polled, stale: true)) == nil)
    check("a row carrying its own error answers nothing",
          reading(account("A", weekly: 60, refreshed: polled, error: "unauthorized")) == nil)
    // THE ONE THE FOUR ABOVE CANNOT COVER: a setting change rewrites the whole document from cached
    // accounts, so the file is seconds old while every number in it is not (`republishSnapshot`).
    check("a fetch older than the snapshot age limit answers nothing, however new the file is",
          reading(account("A", weekly: 60,
                          refreshed: wall.addingTimeInterval(-snapshotMaxAge - 60))) == nil)
    check("…and an app too old to stamp its fetches cannot vouch for one either",
          reading(account("A", weekly: 60)) == nil)
    check("…while a fetch inside that limit still answers",
          reading(account("A", weekly: 60,
                          refreshed: wall.addingTimeInterval(-snapshotMaxAge + 60))) == 60)
    check("another account's row is not this account's reading",
          reading(account("B", weekly: 60, refreshed: polled)) == nil)

    // AND THE STATION IS WIRED TO THAT ANSWER rather than to the raw number, which is the half no
    // pure table can state.
    func holdOnReading(_ row: Snapshot.Account, problem: String? = nil) -> Bool {
        var state = CapLimitResetState()
        var carried: PendingCapRecovery? = pending(.session)
        var lines: [String] = []
        return capLimitResetHold(
            &state, pendingCap: &carried, accountID: "A", accountLabel: "Claude 2",
            resetState: { .available }, observed: nil,
            weeklyRemaining: { reading(row, problem: problem) },
            clearQuarantine: { _ in },
            settings: { LimitResetSettings(autoReset: true) },
            now: wall.addingTimeInterval(1), announce: { lines.append($0) })
    }
    check("a wall over a freshly read 60% week is held for",
          holdOnReading(account("A", weekly: 60, refreshed: polled)))
    check("…and the very same 60% held over from a failed poll holds nothing",
          !holdOnReading(account("A", weekly: 60, refreshed: polled, failed: true)))
    check("…nor the same 60% on a row the app has marked stale",
          !holdOnReading(account("A", weekly: 60, refreshed: polled, stale: true)))
    check("…nor the same 60% inside a snapshot the loader calls too old",
          !holdOnReading(account("A", weekly: 60, refreshed: polled),
                         problem: "snapshot is 40m old - is Tally.app running?"))

    // MARK: - 41b. The hold, where the handoff is decided

    /// One tick of the hold station over a fixture world.
    func hold(_ state: inout CapLimitResetState, cap: inout PendingCapRecovery?,
              reset: LimitResetState = .available, weekly: Double? = 60, autoReset: Bool = true,
              observed: (outcome: LimitResetOutcome, at: Date)? = nil,
              now: Date = wall.addingTimeInterval(1),
              said: inout [String]) -> Bool {
        var lines = said
        let held = capLimitResetHold(&state, pendingCap: &cap, accountID: "A",
                                     accountLabel: "Claude 2", resetState: { reset },
                                     observed: observed, weeklyRemaining: { weekly },
                                     clearQuarantine: { model in
                                         releaseQuarantine("A", model: model,
                                                           sessionLocal: &localQuarantine,
                                                           dir: quarantineHome)
                                     },
                                     settings: { LimitResetSettings(autoReset: autoReset) },
                                     now: now, announce: { lines.append($0) })
        said = lines
        return held
    }

    var said: [String] = []
    var fresh = CapLimitResetState()
    var cap: PendingCapRecovery? = pending(.session)
    check("a fresh 5-hour wall holds the handoff so the line can be typed this tick",
          hold(&fresh, cap: &cap, said: &said))
    check("…and the cap itself is left standing, since nothing has answered yet", cap != nil)

    // EVERY REFUSAL LETS THE HANDOFF THROUGH, which is the half that matters: this feature may
    // delay a move, never prevent one.
    for (name, run) in [
        ("a weekly wall", { (s: inout CapLimitResetState, c: inout PendingCapRecovery?,
                             l: inout [String]) -> Bool in
            c = pending(.weekly); return hold(&s, cap: &c, said: &l)
        }),
        ("a reset already spent", { s, c, l in hold(&s, cap: &c, reset: .used, said: &l) }),
        ("a login outside the rollout", { s, c, l in
            hold(&s, cap: &c, reset: .notEnabled, said: &l)
        }),
        ("the switch off", { s, c, l in hold(&s, cap: &c, autoReset: false, said: &l) }),
        ("almost no week left", { s, c, l in hold(&s, cap: &c, weekly: 3, said: &l) }),
        ("a snapshot that cannot say", { s, c, l in hold(&s, cap: &c, weekly: nil, said: &l) }),
    ] {
        var state = CapLimitResetState()
        var carried: PendingCapRecovery? = pending(.session)
        var lines: [String] = []
        check("\(name) holds nothing, so the handoff moves the session as it always did",
              !run(&state, &carried, &lines))
        check("…and leaves the cap for that handoff to act on", carried != nil)
    }

    // A CAP THIS SESSION IS NOT ON is not this station's business at all.
    var otherState = CapLimitResetState()
    var otherCap: PendingCapRecovery? = pending(.session, account: "B")
    check("a cap belonging to another account is not held for",
          !hold(&otherState, cap: &otherCap, said: &said))

    // ONE WALL, ONE LINE, ASKED OF THE HOLD ITSELF. A wall this session has already typed at is not
    // a candidate any more, and the difference is not academic: after a refused write, or after an
    // answer that settled nothing in this session's favour, `injectedAt` is nil again while the cap
    // is still standing - so without this the station would hold the handoff and type the command
    // again on every tick until the window closed. Found by a surviving mutant, 2026-09-06.
    var spent = CapLimitResetState(attemptedCapAt: wall, injectedAt: nil)
    var spentCap: PendingCapRecovery? = pending(.session)
    check("a wall this session has already answered is not held for a second time",
          !hold(&spent, cap: &spentCap, now: wall.addingTimeInterval(3), said: &said))
    check("…and the cap goes to the handoff rather than waiting out the window", spentCap != nil)
    // A DIFFERENT WALL IS A DIFFERENT QUESTION, which is what keeps the rule above from being "one
    // per session": a second genuine cap gets its own attempt.
    var second = CapLimitResetState(attemptedCapAt: wall, injectedAt: nil)
    let later = wall.addingTimeInterval(600)
    var secondCap: PendingCapRecovery? = pending(.session, at: later)
    check("a later wall gets an attempt of its own",
          hold(&second, cap: &secondCap, now: later.addingTimeInterval(1), said: &said))

    // THE HOLD IS BOUNDED FROM THE CAP, so a session whose composer never frees up hands off late
    // rather than never.
    var stale = CapLimitResetState()
    var staleCap: PendingCapRecovery? = pending(.session)
    check("a candidate wall still inside the window is held for",
          hold(&stale, cap: &staleCap,
               now: wall.addingTimeInterval(capLimitResetHoldWindow - 1), said: &said))
    check("…and past that window the station stops asking for anything",
          !hold(&stale, cap: &staleCap,
                now: wall.addingTimeInterval(capLimitResetHoldWindow + 1), said: &said))

    // MARK: - 41c. Waiting for the answer, and the four ways the wait ends

    /// A station that has already typed at `wall + 1`.
    func waiting() -> CapLimitResetState {
        CapLimitResetState(attemptedCapAt: wall, injectedAt: wall.addingTimeInterval(1))
    }

    var midWait = waiting()
    var midCap: PendingCapRecovery? = pending(.session)
    check("a line typed and not yet answered holds the handoff",
          hold(&midWait, cap: &midCap, now: wall.addingTimeInterval(5), said: &said))
    check("…and the cap stays standing while it waits", midCap != nil)

    // 1. THE RESET LANDED: the wall is gone, so the recovery describes nothing still true.
    // AND NEITHER DOES THE QUARANTINE THAT WALL WROTE, which is a record on disk that outlives this
    // session: left standing it keeps the account out of every automatic pick on the machine for
    // ten minutes after its 5-hour window was reset (review, 2026-09-06).
    quarantineTheWall()
    check("the wall this session hit had quarantined its account", stillQuarantined())
    var landed = waiting()
    var landedCap: PendingCapRecovery? = pending(.session)
    var landedSaid: [String] = []
    check("an answer saying the reset landed releases the hold",
          !hold(&landed, cap: &landedCap,
                observed: (.reset(nextAvailableAt: wall.addingTimeInterval(7 * 86_400)),
                           wall.addingTimeInterval(4)),
                now: wall.addingTimeInterval(5), said: &landedSaid))
    check("…and clears the pending cap, so the session stays where it is", landedCap == nil)
    check("…and says so on the terminal, naming the account it kept",
          landedSaid.contains { $0.contains("Claude 2") && $0.contains("staying put") })
    check("…and stops waiting", landed.injectedAt == nil)
    check("…and lifts the quarantine that wall wrote, so picks stop steering around the account",
          !stillQuarantined())
    check("…on this supervisor's own record", localQuarantine["A"] == nil)
    check("…and on the shared one every other supervisor reads", !sharedRecordExists())

    // A RECORD ABOUT ANOTHER WINDOW IS NOT THIS RESET'S TO LIFT: the reset clears the 5-hour wall
    // this session hit, and a quarantine naming a different model window describes a wall it did
    // not touch.
    quarantineTheWall(model: "sonnet")
    var otherWindow = waiting()
    var otherWindowCap: PendingCapRecovery? = pending(.session)
    var otherWindowSaid: [String] = []
    _ = hold(&otherWindow, cap: &otherWindowCap,
             observed: (.reset(nextAvailableAt: nil), wall.addingTimeInterval(4)),
             now: wall.addingTimeInterval(5), said: &otherWindowSaid)
    check("a quarantine on a window this reset did not clear is left standing",
          localQuarantine["A"] != nil && sharedRecordExists())
    localQuarantine["A"] = nil
    try? FileManager.default.removeItem(at: quarantineHome.appendingPathComponent("A"))

    // 2. ANY OTHER ANSWER: nothing was cleared, so the handoff goes ahead.
    for (name, answer) in [("already used", LimitResetOutcome.alreadyUsed(availableAgain: nil)),
                           ("not available", .unavailable),
                           ("this login cannot", .loginRequired),
                           ("not in the rollout", .notEnabled)] {
        var state = waiting()
        var carried: PendingCapRecovery? = pending(.session)
        var lines: [String] = []
        quarantineTheWall()
        check("an answer of \(name) releases the hold",
              !hold(&state, cap: &carried, observed: (answer, wall.addingTimeInterval(4)),
                    now: wall.addingTimeInterval(5), said: &lines))
        check("…and leaves the cap standing for the handoff", carried != nil)
        check("…and says nothing about staying put", lines.isEmpty)
        check("…and leaves the quarantine standing: no wall was cleared", stillQuarantined())
        localQuarantine["A"] = nil
        try? FileManager.default.removeItem(at: quarantineHome.appendingPathComponent("A"))
    }

    // 3. AN OBSERVATION OLDER THAN THE INJECTION IS NOT ITS ANSWER. The watcher holds the newest
    // signal it has ever seen, so a reset spent an hour ago is sitting right there.
    var stalePair = waiting()
    var stalePairCap: PendingCapRecovery? = pending(.session)
    check("a signal older than the line just typed is not read as its answer",
          hold(&stalePair, cap: &stalePairCap,
               observed: (.reset(nextAvailableAt: nil), wall.addingTimeInterval(-3600)),
               now: wall.addingTimeInterval(5), said: &said))
    check("…so the cap is not cleared by somebody else's reset", stalePairCap != nil)

    // 4. THE WAIT RUNS OUT.
    var timedOut = waiting()
    var timedOutCap: PendingCapRecovery? = pending(.session)
    check("a wait that runs out releases the hold",
          !hold(&timedOut, cap: &timedOutCap,
                now: wall.addingTimeInterval(1 + capLimitResetAnswerWait + 1), said: &said))
    check("…and leaves the cap for the handoff", timedOutCap != nil)
    check("…and does not go on waiting for ever", timedOut.injectedAt == nil)

    // MARK: - 41d. The typing, under the composer's own gates

    /// One tick of the writer, with a terminal that records what reached it.
    func type(_ state: inout CapLimitResetState, cap: PendingCapRecovery? = nil,
              holding: Bool = true, typedAlready: Bool = false,
              session: SupervisedState = .idle, quiet: SessionQuiet = .quiet,
              turnEnded: Bool = false, keyboardIdle: Bool = true, relaunchPlanned: Bool = false,
              draftSuspected: Bool = false, waitingOnPerson: Bool = false,
              autoReset: Bool = true, noticeShown: Bool = true,
              refuse: Bool = false, typed: inout [String],
              said: inout [String]) -> String? {
        var written = typed
        var lines = said
        let carried = cap ?? pending(.session)
        let answer = applyCapLimitReset(
            &state, pendingCap: carried, pid: "9601", accountLabel: "Claude 2", holding: holding,
            typedAlready: typedAlready, session: session, quiet: quiet, turnEnded: { turnEnded },
            keyboardIdle: keyboardIdle, relaunchPlanned: relaunchPlanned,
            draftSuspected: draftSuspected, waitingOnPerson: waitingOnPerson,
            settings: { LimitResetSettings(autoReset: autoReset, noticeShown: noticeShown) },
            now: wall.addingTimeInterval(1), log: log, settingsURL: settingsFile,
            announce: { lines.append($0) },
            inject: { text, _ in
                if refuse { return .failed(ENXIO) }
                written.append(text)
                return .done
            })
        typed = written
        said = lines
        return answer
    }

    var typed: [String] = []
    var writer = CapLimitResetState()
    var writerSaid: [String] = []
    let sent = type(&writer, typed: &typed, said: &writerSaid)
    check("a held wall on a free composer types the command", sent == limitResetCommand)
    check("…and it is Claude Code's own command, spelled once", typed == ["/limit-reset"])
    check("…and the station starts waiting for its answer", writer.injectedAt != nil)
    check("…and marks the wall answered, so this one never gets a second line",
          writer.attemptedCapAt == wall)
    check("…and leaves an audit line naming what typed into this session",
          ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
              .contains("input=\(capLimitResetOutcome)"))

    // THE SAME WALL, A SECOND TICK: the hold may still be true (nothing has answered), and this must
    // not type again.
    var again: [String] = []
    check("a wall already typed at is not typed at again",
          type(&writer, typed: &again, said: &writerSaid) == nil)
    check("…and nothing reached the terminal", again.isEmpty)
    // AND WITH THE WAIT ALREADY OVER, which is the shape the check above cannot reach: `injectedAt`
    // is nil again after a refused write or a settled answer, so the only thing left between this
    // wall and a second command is this station's OWN record of having answered it. Handed
    // `holding: true` on purpose - the point is that this function refuses even a caller that says
    // yes, rather than trusting the hold to have asked the question (mutation run, 2026-09-06).
    var settled = CapLimitResetState(attemptedCapAt: wall, injectedAt: nil)
    var settledTyped: [String] = []
    check("a wall answered once is not typed at again even when the caller says to",
          type(&settled, typed: &settledTyped, said: &writerSaid) == nil)
    check("…and nothing reached that terminal either", settledTyped.isEmpty)
    // A LATER WALL IS A DIFFERENT QUESTION, so the rule above is one per WALL rather than one per
    // session.
    var nextWall = CapLimitResetState(attemptedCapAt: wall, injectedAt: nil)
    var nextTyped: [String] = []
    check("a later wall is typed at",
          type(&nextWall, cap: pending(.session, at: wall.addingTimeInterval(600)),
               typed: &nextTyped, said: &writerSaid) == limitResetCommand)

    // EVERY GATE, one at a time off a cell that types.
    for (name, run) in [
        ("the hold saying no", { (s: inout CapLimitResetState, t: inout [String],
                                  l: inout [String]) -> String? in
            type(&s, holding: false, typed: &t, said: &l)
        }),
        ("a line already typed this tick", { s, t, l in
            type(&s, typedAlready: true, typed: &t, said: &l)
        }),
        ("a relaunch this tick is about to perform", { s, t, l in
            type(&s, relaunchPlanned: true, typed: &t, said: &l)
        }),
        ("a session sitting on a dialog", { s, t, l in
            type(&s, waitingOnPerson: true, typed: &t, said: &l)
        }),
        ("a conversation mid-turn", { s, t, l in
            type(&s, session: .working, quiet: .busy, typed: &t, said: &l)
        }),
        ("a session that reports nothing about itself", { s, t, l in
            type(&s, session: .unknown, typed: &t, said: &l)
        }),
        ("somebody typing in that terminal", { s, t, l in
            type(&s, keyboardIdle: false, typed: &t, said: &l)
        }),
    ] {
        var state = CapLimitResetState()
        var written: [String] = []
        var lines: [String] = []
        check("\(name) stops the line", run(&state, &written, &lines) == nil)
        check("…and nothing reached that terminal", written.isEmpty)
        check("…and no wall is marked answered by a tick that typed nothing",
              state.attemptedCapAt == nil)
    }

    // A SESSION WHOSE DISPATCHED AGENTS ARE WRITING IS TYPED INTO, which is the exemption the input
    // station already keeps: that is a head waiting on work rather than a conversation mid-turn.
    var dispatched = CapLimitResetState()
    var dispatchedTyped: [String] = []
    check("a head whose subagents are writing is still typed into",
          type(&dispatched, session: .working, quiet: .subagentsWriting,
               typed: &dispatchedTyped, said: &writerSaid) == limitResetCommand)

    // A REFUSED WRITE STARTS NO WAIT: nothing was typed, so no answer is coming and the handoff
    // must not be held for one.
    var refused = CapLimitResetState()
    var refusedTyped: [String] = []
    check("a terminal that refuses the write reports nothing typed",
          type(&refused, refuse: true, typed: &refusedTyped, said: &writerSaid) == nil)
    check("…and the station does not sit waiting for an answer that cannot come",
          refused.injectedAt == nil)
    check("…while the wall is still marked, so a failing terminal is not retried every 2s",
          refused.attemptedCapAt == wall)
    check("…and the failure is in the log with its errno",
          ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
              .contains("input=\(capLimitResetFailedOutcome)"))

    // THE ONE-TIME NOTICE, said once and written down so it is never said again.
    try? FileManager.default.removeItem(at: settingsFile)
    var firstRun = CapLimitResetState()
    var firstTyped: [String] = []
    var firstSaid: [String] = []
    _ = type(&firstRun, noticeShown: false, typed: &firstTyped, said: &firstSaid)
    check("the first automatic reset says so on the terminal",
          firstSaid.contains { $0.contains("Claude 2") && $0.contains("/limit-reset") })
    check("…and names the switch that turns it off",
          firstSaid.contains { $0.contains("Settings") })
    check("…and records that it has been said",
          readLimitResetSettings(url: settingsFile).noticeShown)
    check("…without touching the switch itself",
          readLimitResetSettings(url: settingsFile).autoReset)

    // MARK: - 41e. The observer, which is about the account rather than the wall

    var folded: Date?
    observeLimitReset((.noticeAvailable, wall), folded: &folded, accountID: "A", now: wall, dir: dir)
    check("a signal is folded into the account's own record",
          limitResetEffective(readLimitReset(accountID: "A", dir: dir), now: wall) == .available)
    check("…and the reading is marked as folded", folded == wall)
    // WRITTEN ONCE, because the watcher goes on holding the newest signal it has seen: a fold per
    // tick would rewrite that file every two seconds for the rest of the session.
    let firstWrite = readLimitReset(accountID: "A", dir: dir)
    observeLimitReset((.notEnabled, wall), folded: &folded, accountID: "A",
                      now: wall.addingTimeInterval(60), dir: dir)
    check("the same reading is not folded twice", readLimitReset(accountID: "A", dir: dir)
        == firstWrite)
    // A NEWER ONE IS.
    observeLimitReset((.alreadyUsed(availableAgain: nil), wall.addingTimeInterval(30)),
                      folded: &folded, accountID: "A", now: wall.addingTimeInterval(60), dir: dir)
    check("a newer reading is folded", readLimitReset(accountID: "A", dir: dir)?.state == .used)
    // NOTHING TO OBSERVE writes nothing at all.
    var never: Date?
    observeLimitReset(nil, folded: &never, accountID: "B", now: wall, dir: dir)
    check("a session that has been told nothing writes no record for its account",
          readLimitReset(accountID: "B", dir: dir) == nil)

    // MARK: - 41f. The handoff really does stand down

    // THE HOLD IS WORTH NOTHING IF THE HANDOFF IGNORES IT, and that is a different function in a
    // different file: this drives the real one both ways over one fixture world.
    let sibling = account("B", weekly: 80, session: 80, model: 80)
    let capped = account("A", weekly: 60)
    let snapshot = Snapshot(version: 2, generatedAt: wall, accounts: [capped, sibling])
    func handoff(held: Bool) -> RelaunchPlan? {
        var plan: RelaunchPlan?
        var carried: PendingCapRecovery? = pending(.session)
        applyCapHandoff(plan: &plan, pendingCap: &carried, account: capped, providerID: "claude",
                        fleet: LaunchPolicy(mode: "auto"), steering: true, sessionPin: nil,
                        quarantine: [:], fuseAllows: true, heldByLimitReset: held,
                        now: wall.addingTimeInterval(1), loaded: (snapshot, nil))
        return plan
    }
    check("without the hold this cap hands the session to the sibling", handoff(held: false) != nil)
    check("…and with it the very same tick plans nothing at all", handoff(held: true) == nil)

    // MARK: - 41g. Which wall the watcher reports

    // OFF A REAL TRANSCRIPT LINE rather than by calling `capScope` directly, because what has to be
    // true is that the SCAN carries the scope out with the cap it reports.
    let project = dir.appendingPathComponent("project")
    try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    func scanned(_ body: String) -> CapScope? {
        let file = project.appendingPathComponent("\(UUID().uuidString).jsonl")
        let event: [String: Any] = [
            "type": "assistant", "isApiErrorMessage": true,
            "timestamp": ISO8601DateFormatter().string(from: wall.addingTimeInterval(60)),
            "message": ["role": "assistant", "content": body],
        ]
        let line = String(data: try! JSONSerialization.data(withJSONObject: event),
                          encoding: .utf8)!
        try? Data((line + "\n").utf8).write(to: file)
        var watcher = TranscriptWatcher(projectDir: project, file: file, since: wall)
        return watcher.sawCapHit() ? watcher.capHitScope : nil
    }
    check("a 5-hour wall reaches the loop as the session scope",
          scanned("You've hit your session limit · resets 4:20pm (Asia/Taipei)") == .session)
    check("a weekly wall reaches it as the weekly one",
          scanned("You've hit your weekly limit · resets 5am (Asia/Taipei)") == .weekly)
    check("and a model-tier wall as the model one",
          scanned("You've reached your Fable 5 limit. Run /usage-credits to continue or switch "
                  + "models with /model.") == .model)

    // MARK: - 41h. The scope survives a self-update

    // A cap the session is still waiting out rides the exec in the argv, and the wall it names has
    // to ride with it: without the scope the new image refuses to spend a reset, which is the safe
    // answer but also a feature that stops working at every app update.
    let carried = pending(.session)
    check("the wall a pending cap names survives the resupervise contract",
          encodePendingCap(carried).flatMap(decodePendingCap)?.capScope == .session)
    check("…and a record naming no wall still decodes, as an older build's does",
          encodePendingCap(pending(nil)).flatMap(decodePendingCap).map { $0.capScope == nil } == true)
    // A WORD THIS BUILD CANNOT READ DISCARDS THE WHOLE RECORD, the rule the two fields beside it
    // keep: the value comes from another BUILD, so an unreadable one is a disagreement about the
    // format rather than a field to shrug at.
    let tampered = (encodePendingCap(carried) ?? "")
        .replacingOccurrences(of: "\"session\"", with: "\"fortnightly\"")
    check("…while a wall named in a word this build does not know discards the record",
          decodePendingCap(tampered) == nil)

    try? FileManager.default.removeItem(at: dir)
}
