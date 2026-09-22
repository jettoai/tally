import Foundation

// The bounds on one delivery pass (`deliverPendingEvents`'s `rounds`) and what happens when they
// are reached with events still past the cursor (`handoff`). Uses API the pre-fix tree did not
// have, so it lives apart from `main.swift`'s T17/T18, which also compile against that tree.
// `expect`, `now`, `identity`, `t6Request` and `t12Event` are top-level in `main.swift`.
func runDeliveryHandoffChecks() {
    func freshDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-waitevents-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // T17b: cap forced to 1, over the real send path. The receiver appends a closing event while it
    // answers the first request, so the one round ends with it past the cursor; the handoff runs
    // what the spawned `tally events --deliver-once` runs, and that delivers it.
    let capDir = freshDir("t17b")
    let capLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-waitevents-t17b-receiver-\(UUID().uuidString).log")
    let capReceiver = LoopbackReceiver(logFile: capLog) { number in
        guard number == 1 else { return }
        appendSessionWaitEvent(makeSessionWaitEvent(.ended, request: nil, resolution: nil, identity: identity,
                                                    provider: "claude", now: now), dir: capDir)
    }
    _ = writeEventSinkConfig(EventSinkConfig(url: capReceiver.url, secret: "s", createdAt: now), dir: capDir)
    appendSessionWaitEvent(t12Event, dir: capDir)
    var capHandoffs = 0
    _ = deliverPendingEvents(replayDeadLetter: false, dir: capDir, sleeper: { _ in }, rounds: 1, handoff: {
        capHandoffs += 1
        _ = deliverPendingEvents(replayDeadLetter: false, dir: capDir, sleeper: { _ in }, handoff: {})
    })
    expect(capHandoffs == 1, "T17b: reaching the cap with an event past the cursor hands off exactly once")
    expect(capReceiver.received.map(\.event) == ["wait.opened", "session.ended"],
           "T17b: ...and the fresh deliverer sends the leftover (\(capReceiver.received.map(\.event)))")
    let source = (try? String(contentsOfFile: "TallyCLI/EventDelivery.swift", encoding: .utf8)) ?? ""
    expect(source.contains("handoff: () -> Void = spawnDetachedEventDeliverer"),
           "T17b: the default handoff is the existing detached spawn")
    print("T17b receiver log: \(capLog.path)")
    try? FileManager.default.removeItem(at: capDir)

    // T17c: a cursor that cannot be written never moves, so the pass must not hand off (a chain of
    // processes posting the same event forever). The cursor file is a directory here.
    let stuckDir = freshDir("t17c")
    _ = writeEventSinkConfig(EventSinkConfig(url: "https://example.invalid/hook", secret: "s", createdAt: now),
                             dir: stuckDir)
    try? FileManager.default.createDirectory(at: stuckDir.appendingPathComponent("cursor"),
                                             withIntermediateDirectories: true)
    appendSessionWaitEvent(t12Event, dir: stuckDir)
    var stuckSends = 0
    var stuckHandoffs = 0
    _ = deliverPendingEvents(replayDeadLetter: false, dir: stuckDir,
                             sender: { _, _, _ in stuckSends += 1; return (status: 200, error: nil) },
                             sleeper: { _ in }, handoff: { stuckHandoffs += 1 })
    expect(stuckSends > 0 && stuckHandoffs == 0,
           "T17c: an unwritable cursor ends the pass without a handoff (\(stuckSends) sends)")
    try? FileManager.default.removeItem(at: stuckDir)

    // T17d: an appender that never stops cannot pin a pass; the pass hands off once and returns.
    let endlessDir = freshDir("t17d")
    _ = writeEventSinkConfig(EventSinkConfig(url: "https://example.invalid/hook", secret: "s", createdAt: now),
                             dir: endlessDir)
    appendSessionWaitEvent(t12Event, dir: endlessDir)
    var endlessSends = 0
    var endlessHandoffs = 0
    _ = deliverPendingEvents(replayDeadLetter: false, dir: endlessDir,
                             sender: { _, _, _ in
                                 endlessSends += 1
                                 appendSessionWaitEvent(t12Event, dir: endlessDir)
                                 return (status: 200, error: nil)
                             },
                             sleeper: { _ in }, handoff: { endlessHandoffs += 1 })
    expect(endlessSends == deliveryPassRounds * deliveryPassRounds && endlessHandoffs == 1,
           "T17d: an appender that never stops gets \(endlessSends) sends and one handoff, then the pass returns")
    try? FileManager.default.removeItem(at: endlessDir)
}
