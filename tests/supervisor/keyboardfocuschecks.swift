import Foundation

// Focus reports are not typing (KeyboardIdle.swift, FocusEvents.swift). Split out of
// keyboardchecks.swift for file size; the harness (`check`, `failures`) is shared from main.swift.
//
// Claude Code 2.1.280 turns on the terminal's focus reports, so switching apps stamps the tty in
// out/in PAIRS a few seconds apart, and the tracker read each pair as a typing burst that held a
// reload for 120s (2026-09-23). Every assertion here injects the focus events as a closure, so
// nothing touches the real ~/.tally.

func runKeyboardFocusChecks() {
    // MARK: - 24f. A focus pair the app recorded is not a burst

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    /// Poll every 2s from `from` to `to`, the way the supervisor does: each tick sees the newest
    /// stamp at or before it, and only the focus events already written by then.
    func drive(_ tracker: inout KeyboardActivity, stamps: [Date], events: [Date]?,
               from: TimeInterval, to: TimeInterval) -> [KeyboardObservation] {
        var seen: [KeyboardObservation] = []
        var k = from
        while k <= to {
            let now = at(k)
            let stamp = stamps.filter { $0 <= now }.max()
            seen += tracker.observe(stamp: stamp, now: now,
                                    focusEvents: { events.map { $0.filter { $0 <= now } } })
            k += 2
        }
        return seen
    }

    // T1. Switching out and back in 7s later, nothing typed: both stamps are focus reports.
    let pairStamps = [at(0.10), at(7.10)]
    let pairEvents = [at(0.05), at(7.03)]
    var paired = KeyboardActivity()
    let pairSeen = drive(&paired, stamps: pairStamps, events: pairEvents, from: 0, to: 40)
    check("a recorded focus out/in pair makes no burst", paired.lastBurstAt == nil)
    check("both stamps of the pair were explained by a focus change",
          pairSeen.count == 2 && pairSeen.allSatisfy { $0.focusOffset != nil && !$0.burst })
    check("the reload bar opens once the lone-stamp hold has passed",
          paired.idle(followIdleSeconds, now: at(22.2)))
    check("but the last focus stamp still holds its short window",
          !paired.idle(followIdleSeconds, now: at(21)))

    // T1b. The same tracker through the reload tick itself.
    let tickDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-kbdfocus-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: tickDir, withIntermediateDirectories: true)
    let tickFile = tickDir.appendingPathComponent("session.jsonl")
    try! "{}".write(to: tickFile, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9999)],
                                           ofItemAtPath: tickFile.path)
    var watcher = TranscriptWatcher(projectDir: tickDir, file: tickFile, since: launch)
    let account = Snapshot.Account(
        id: "A", provider: "claude", label: "A", launchHome: "/tmp/A", sessionRemaining: 90,
        weeklyRemaining: 90, modelRemaining: 90, sessionResetsAt: nil, weeklyResetsAt: nil,
        modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
        error: nil)
    let request = ReloadRequest(epoch: 101, immediate: false)
    var plan: RelaunchPlan?
    var epoch = 100
    var notice = ReloadWait()
    func reloadTick(_ tracker: KeyboardActivity, at moment: Date, burstAt: Date? = nil,
                    stampAt: Date? = nil) {
        applyReloadRequest(plan: &plan, epoch: &epoch, notice: &notice, account: account,
                           watcher: &watcher, childAge: 9999,
                           keyboardIdle: { tracker.idle($0, now: moment) },
                           keyboardBurstAt: burstAt, keyboardStampAt: stampAt,
                           request: request, now: moment)
    }
    reloadTick(paired, at: at(21))
    check("the reload is still held inside the focus stamp's short window", plan == nil)
    reloadTick(paired, at: at(22.2))
    check("and lands at 22s instead of 127s", plan != nil && epoch == 101)

    // T2. Two real keys three seconds apart, with a focus file that holds nothing: still a burst.
    var typing = KeyboardActivity()
    _ = drive(&typing, stamps: [at(1), at(4)], events: [], from: 2, to: 10)
    check("real typing with no focus change near it is still a burst", typing.lastBurstAt == at(4))
    check("and holds the full reload bar", !typing.idle(followIdleSeconds, now: at(60)))

    // T3. A key 1.5s after a focus stamp is outside the window, and a focus stamp may be the
    // EARLIER half of a burst: switching in and then pasting is a person.
    var after = KeyboardActivity()
    let focusAt = [t0]
    var afterSeen: [KeyboardObservation] = []
    afterSeen += after.observe(stamp: at(0.02), now: at(0.5), focusEvents: { focusAt })
    afterSeen += after.observe(stamp: at(1.5), now: at(2), focusEvents: { focusAt })
    afterSeen += after.observe(stamp: at(4), now: at(4.2), focusEvents: { focusAt })
    afterSeen += after.observe(stamp: nil, now: at(8), focusEvents: { focusAt })
    let key = afterSeen.first { $0.stamp == at(1.5) }
    check("a key outside the focus window is not explained by it", key != nil && key?.focusOffset == nil)
    check("and pairs with the focus stamp before it into a burst", key?.burst == true)

    // T3b. Inside the window, even with a stamp 5.9s before it that would otherwise pair.
    var inside = KeyboardActivity()
    _ = inside.observe(stamp: at(-5), now: at(-3), focusEvents: { focusAt })
    let insideSeen = inside.observe(stamp: at(0.9), now: at(3), focusEvents: { focusAt })
    check("a stamp 0.9s after a focus change is that change",
          insideSeen.count == 1 && insideSeen[0].burst == false
              && abs((insideSeen[0].focusOffset ?? 0) + 0.9) < 0.001)

    // T4. Tally.app not running (no file): every stamp is classified at once, as it always was.
    var noApp = KeyboardActivity()
    let firstNoApp = noApp.observe(stamp: t0, now: t0, focusEvents: { nil })
    let secondNoApp = noApp.observe(stamp: at(7), now: at(7), focusEvents: { nil })
    check("with no focus source each stamp is classified the tick it is read",
          firstNoApp.count == 1 && secondNoApp.count == 1 && noApp.unclassified.isEmpty)
    check("and the pair is a burst exactly as before", noApp.lastBurstAt == at(7))
    check("holding the reload bar", !noApp.idle(followIdleSeconds, now: at(100)))
    var defaulted = KeyboardActivity()
    defaulted.observe(stamp: t0)
    defaulted.observe(stamp: at(7))
    check("the default parameters are the same as no focus source", defaulted.lastBurstAt == at(7))

    // T5. The race: the tick reads the stamp before the app has written the event.
    var race = KeyboardActivity()
    var written: [Date] = [at(0.05)]
    _ = race.observe(stamp: at(0.10), now: at(2), focusEvents: { written })
    let firstRace = race.observe(stamp: at(7.10), now: at(8), focusEvents: { written })
    check("a fresh stamp waits a tick before it is classified",
          firstRace.isEmpty && race.unclassified.count == 1)
    written.append(at(7.15))
    let secondRace = race.observe(stamp: at(7.10), now: at(10), focusEvents: { written })
    check("and the event written late still explains it",
          secondRace.count == 1 && secondRace[0].focusOffset != nil && !secondRace[0].burst)
    check("so the late pair makes no burst", race.lastBurstAt == nil)

    // T6. Waiting to classify never opens a gate early: the lone-stamp hold covers the delay.
    for bar in [reloadNowIdleSeconds, followIdleSeconds] {
        var waiting = KeyboardActivity()
        _ = waiting.observe(stamp: t0, now: at(0.5), focusEvents: { [] })
        for lag in [0.5, 2, 3.5] {
            check("an unclassified stamp still holds the \(Int(bar))s bar \(lag)s later",
                  !waiting.idle(bar, now: at(lag)))
        }
    }

    // T7. A flood of events is a writer gone wrong, not a person: it explains nothing.
    let flood = (0 ..< 10).map { at(-9 + TimeInterval($0)) }
    var flooded = KeyboardActivity()
    _ = flooded.observe(stamp: at(-8), now: at(-6), focusEvents: { flood })
    let floodSeen = flooded.observe(stamp: at(0.01), now: at(2), focusEvents: { flood })
    check("a stamp amid more than eight events in ten seconds is not explained by them",
          floodSeen.count == 1 && floodSeen[0].focusOffset == nil)
    check("so real typing under a flood is still a burst", floodSeen.first?.burst == true)

    // T8. A stamp older than the one held is time moving backwards, not a quick key.
    var backwards = KeyboardActivity()
    _ = backwards.observe(stamp: at(10), now: at(12), focusEvents: { [] })
    _ = backwards.observe(stamp: at(5), now: at(14), focusEvents: { [] })
    check("a backwards stamp still makes no burst", backwards.lastBurstAt == nil)

    // MARK: - 24g. The escalated badge follows the gate holding it now

    // T9. Five minutes held by the keyboard, then the keyboard frees and the session gets busy.
    var t9Plan: RelaunchPlan?
    var t9Epoch = 100
    var t9Notice = ReloadWait()
    func t9Tick(keyboard: Bool, at moment: Date) {
        applyReloadRequest(plan: &t9Plan, epoch: &t9Epoch, notice: &t9Notice, account: account,
                           watcher: &watcher, childAge: 9999, keyboardIdle: { _ in keyboard },
                           request: request, now: moment)
    }
    t9Tick(keyboard: false, at: t0)
    t9Tick(keyboard: false, at: at(reloadStillWaitingAfter))
    check("five minutes held by the keyboard names the keyboard",
          t9Notice.pending?.badge == "reload waiting (keyboard)")
    try! FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: tickFile.path)
    t9Tick(keyboard: true, at: at(reloadStillWaitingAfter + 2))
    check("a tick later the badge names the gate that holds it now",
          t9Notice.pending?.badge == "reload waiting (session busy)" && t9Plan == nil)
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9999)],
                                           ofItemAtPath: tickFile.path)

    // T10. The detail says what the keyboard gate is holding on.
    var t10Plan: RelaunchPlan?
    var t10Epoch = 100
    var t10Notice = ReloadWait()
    let t10Now = at(reloadStillWaitingAfter)
    let t10Ticks: [(Date, Date?, Date?)] = [(t0, nil, nil),
                                            (t10Now, t10Now.addingTimeInterval(-34), nil)]
    for (moment, burstAt, stampAt) in t10Ticks {
        applyReloadRequest(plan: &t10Plan, epoch: &t10Epoch, notice: &t10Notice, account: account,
                           watcher: &watcher, childAge: 9999, keyboardIdle: { _ in false },
                           keyboardBurstAt: burstAt, keyboardStampAt: stampAt,
                           request: request, now: moment)
    }
    check("the detail names how long ago the burst holding it was",
          t10Notice.pending?.detail?.contains("last burst 30s ago") == true)
    applyReloadRequest(plan: &t10Plan, epoch: &t10Epoch, notice: &t10Notice, account: account,
                       watcher: &watcher, childAge: 9999, keyboardIdle: { _ in false },
                       keyboardBurstAt: nil, keyboardStampAt: t10Now.addingTimeInterval(-8),
                       request: request, now: t10Now.addingTimeInterval(0.5))
    check("and with no burst, how long ago the last input was",
          t10Notice.pending?.detail?.contains("last input 0s ago") == true)
    try? FileManager.default.removeItem(at: tickDir)

    // T12. A detail that changes under the same badge is rewritten, and the wait keeps its age.
    let noticeDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-kbdfocus-notice-\(UUID().uuidString)")
    var writer = PendingNoticeWriter()
    writer.sync(PendingBadge("A", detail: "x"), pid: "4242", dir: noticeDir, now: t0)
    writer.sync(PendingBadge("A", detail: "y"), pid: "4242", dir: noticeDir, now: at(10))
    let rewritten = readPendingNotice(pid: "4242", dir: noticeDir)
    check("a changed detail under the same badge is written", rewritten?.detail == "y")
    check("without restarting the wait's age", rewritten?.since == t0)
    writer.sync(PendingBadge("B"), pid: "4242", dir: noticeDir, now: at(20))
    check("a new badge starts its own age", readPendingNotice(pid: "4242", dir: noticeDir)?.since == at(20))
    try? FileManager.default.removeItem(at: noticeDir)

    // MARK: - 24h. The trace and the file format

    // T13. The trace is bounded and marks each queued request.
    let observation = KeyboardObservation(stamp: t0, gap: 3, burst: true, focusOffset: nil,
                                          nearestFocus: nil)
    var trace = KeyboardTrace()
    check("a trace records nothing while nothing is queued",
          !trace.record([observation], queuedEpoch: nil, now: t0) && trace.lines.isEmpty)
    check("a queued request's observations are recorded",
          trace.record(Array(repeating: observation, count: 250), queuedEpoch: 7, now: t0))
    check("and kept to the last 200 lines", trace.lines.count == keyboardTraceMaxLines)
    _ = trace.record([], queuedEpoch: 8, now: t0)
    check("a new request is marked with its own header", trace.lines.last?.hasSuffix("queued epoch=8") == true)
    check("each line says what was decided",
          keyboardTraceLine(observation).contains("gap=3.000 burst=1 focus=- nearest=-"))

    // T14. The focus-events file: merged, pruned, capped, and absent means nil.
    let merged = parseFocusEvents(mergedFocusEvents(existing: [at(-200), at(-50)], adding: t0))
    check("events past retention are pruned and the rest kept in order", merged == [at(-50), t0])
    check("an unparseable line is skipped", parseFocusEvents("garbage\n1800000000.500\n")
        == [Date(timeIntervalSince1970: 1_800_000_000.5)])
    let many = (0 ..< 70).map { at(-TimeInterval($0)) }
    check("the file keeps at most 64 lines",
          parseFocusEvents(mergedFocusEvents(existing: many, adding: t0)).count == focusEventsMaxLines)
    let focusDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-kbdfocus-events-\(UUID().uuidString)")
    let focusFile = focusDir.appendingPathComponent("focus-events")
    check("no file is no focus source", readFocusEvents(now: t0, from: focusFile) == nil)
    try! appendFocusEvent(t0, to: focusFile)
    try! appendFocusEvent(at(6), to: focusFile)
    check("an event from a clock that jumped ahead is dropped on read",
          readFocusEvents(now: t0, from: focusFile) == [t0])
    try? FileManager.default.removeItem(at: focusDir)

    // T15. The trace is swept with the rest of a dead supervisor's state.
    check("a trace file belongs to its supervisor pid",
          supervisorStatePid(ofFile: "123" + keyboardTraceSuffix) == 123)

    // MARK: - 24i. A glance at a waiting session is not an answer

    // T16. Switching in to look at a dialog and back out used to read as the user answering it.
    let waitingSince = at(1)
    let noticeOpen = UserNotice(message: "", at: waitingSince, type: nil)
    var glance = KeyboardActivity()
    let glanceEvents = [at(2.02), at(6.05)]
    _ = drive(&glance, stamps: [at(2), at(6)], events: glanceEvents, from: 2, to: 12)
    check("a focus pair after the wait began does not close it",
          userNoticeStillOpen(noticeOpen, conversationMovedAt: nil, keyboardBurstAt: glance.lastBurstAt))
    var glanceNoApp = KeyboardActivity()
    _ = drive(&glanceNoApp, stamps: [at(2), at(6)], events: nil, from: 2, to: 12)
    check("with no focus source the same pair closes it, as it always did",
          !userNoticeStillOpen(noticeOpen, conversationMovedAt: nil,
                               keyboardBurstAt: glanceNoApp.lastBurstAt))
}
