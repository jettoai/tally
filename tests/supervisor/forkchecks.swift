import Foundation

// Fork-following. A running claude process can move the conversation to a NEW transcript without
// exiting (`/clear`, a resume that forks): the pinned file stops growing and everything written
// afterwards lands in `<newID>.jsonl`. The supervisor kept watching the dead file, so the next
// relaunch resumed the id from before the move and orphaned every turn since - twice in one
// afternoon (2026-07-26). The marker that tells a fork from a sibling session is inside the file:
// `session_id` (the id the writing process was launched with) against `sessionId` (the file it is
// writing now).

/// One project directory of fixture transcripts, all times relative to a launch 10 minutes ago so
/// the real-clock gates in `followFork` and `isQuiet` answer against it.
struct ForkFixture {
    let dir: URL
    let launchedAt = Date().addingTimeInterval(-600)
    private let iso = ISO8601DateFormatter()

    init(_ label: String) {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-fork-\(label)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A transcript, its birth and its last write given as offsets from launch (negative = before).
    func write(_ name: String, _ lines: [String], born: TimeInterval, wrote: TimeInterval) {
        let url = dir.appendingPathComponent(name)
        try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes(
            [.creationDate: launchedAt.addingTimeInterval(born),
             .modificationDate: launchedAt.addingTimeInterval(wrote)], ofItemAtPath: url.path)
    }

    /// A subagent transcript under `<session>/subagents/`, aged against the real clock like the
    /// idle checks in main.swift (the window it answers to is `subagentIdleSeconds`).
    func subagent(session: String, name: String, age: TimeInterval) {
        let subDir = dir.appendingPathComponent(session).appendingPathComponent("subagents")
        try! FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let url = subDir.appendingPathComponent(name)
        try! "{}".write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    func stamp(_ offset: TimeInterval) -> String {
        iso.string(from: launchedAt.addingTimeInterval(offset))
    }

    /// The real shape of a marker line, trimmed to the fields the watcher reads. `launched` is the
    /// id the process was started with, `own` the file it is writing.
    func marker(own: String, launched: String, at offset: TimeInterval = 60) -> String {
        #"{"isSidechain":false,"type":"assistant","uuid":"u-\#(own)","timestamp":"\#(stamp(offset))","session_id":"\#(launched)","cwd":"/tmp","sessionId":"\#(own)","message":{"model":"claude-fable-5"}}"#
    }

    func capLine(_ offset: TimeInterval) -> String {
        #"{"timestamp":"\#(stamp(offset))","isApiErrorMessage":true,"message":{"content":"You've hit your session limit"}}"#
    }

    func watcher(pinnedTo id: String) -> TranscriptWatcher {
        TranscriptWatcher(projectDir: dir, since: launchedAt, resumeID: id)
    }
}

func runForkChecks() {
    // 1. The central case: the pinned file went quiet because the conversation moved on. The id the
    //    next relaunch resumes has to be the fork's, not the pin's - resuming the pin is exactly
    //    what orphaned the afternoon's turns.
    let moved = ForkFixture("moved")
    moved.write("parent.jsonl", ["{}"], born: -3600, wrote: -30)
    moved.write("fork.jsonl", [#"{"type":"mode","sessionId":"fork"}"#,
                               moved.marker(own: "fork", launched: "parent")], born: 30, wrote: 120)
    var movedWatcher = moved.watcher(pinnedTo: "parent")
    movedWatcher.locateFile()
    let live = movedWatcher.file?.deletingPathExtension().lastPathComponent
    check("relaunch resumes the fork's id, not the stale pin",
          relaunchArgs(["--resume", "parent", "--model", "fable"], sessionID: live, sameAccount: true)
          == ["--resume", "fork", "--model", "fable"])
    check("the watcher rebinds to the fork", movedWatcher.file?.lastPathComponent == "fork.jsonl")
    check("the pin follows too, so a later locate stays on the fork",
          movedWatcher.resumeID == "fork")

    // 2. A sibling session in the same directory is never adopted - the failure mode the pin was
    //    added to prevent. Neither a second tab writing its own conversation, nor one whose tool
    //    output happens to quote our session id (this repo's own transcripts are full of them:
    //    every `tally status` and handoff-log read prints session ids into a transcript).
    let siblings = ForkFixture("siblings")
    siblings.write("parent.jsonl", ["{}"], born: -3600, wrote: -30)
    siblings.write("sibling.jsonl", [siblings.marker(own: "sibling", launched: "sibling")],
                   born: 30, wrote: 120)
    siblings.write("quoting.jsonl", [
        siblings.marker(own: "quoting", launched: "quoting"),
        #"{"type":"user","sessionId":"quoting","toolUseResult":{"stdout":"{\"session_id\":\"parent\"}"}}"#,
    ], born: 40, wrote: 130)
    var siblingWatcher = siblings.watcher(pinnedTo: "parent")
    siblingWatcher.locateFile()
    check("a sibling session never causes a rebind",
          siblingWatcher.file?.lastPathComponent == "parent.jsonl")
    check("a sibling that quotes our id in tool output is not a fork either",
          siblingWatcher.resumeID == "parent")

    // 2b. A transcript that already existed when this child launched cannot be where it moved to,
    //     even carrying the marker (it is the previous child's fork, dead since).
    let older = ForkFixture("older")
    older.write("parent.jsonl", ["{}"], born: -3600, wrote: -30)
    older.write("prior.jsonl", [older.marker(own: "prior", launched: "parent", at: -1200)],
                born: -1800, wrote: -600)
    var olderWatcher = older.watcher(pinnedTo: "parent")
    olderWatcher.locateFile()
    check("a fork from before this launch is not adopted",
          olderWatcher.file?.lastPathComponent == "parent.jsonl")

    // 3. Cap bookkeeping survives the rebind: the offset restarts at the top of the new file (the
    //    parent's byte count means nothing there), while the launch-time guard still filters events
    //    older than this child.
    let capped = ForkFixture("capped")
    capped.write("parent.jsonl", [String(repeating: "{}\n", count: 200)], born: -3600, wrote: -30)
    var cappedWatcher = capped.watcher(pinnedTo: "parent")
    _ = cappedWatcher.sawCapHit()                 // binds the parent, consumes its bytes
    capped.write("fork.jsonl", [capped.capLine(90), capped.marker(own: "fork", launched: "parent")],
                 born: 30, wrote: 120)
    cappedWatcher.followFork(force: true)
    check("the offset restarts at the top of the fork", cappedWatcher.offset == 0)
    check("a cap in the fork is still detected after the rebind", cappedWatcher.sawCapHit())
    let stale = ForkFixture("stale-cap")
    stale.write("parent.jsonl", ["{}"], born: -3600, wrote: -30)
    stale.write("fork.jsonl", [stale.capLine(-90), stale.marker(own: "fork", launched: "parent")],
                born: 30, wrote: 120)
    var staleWatcher = stale.watcher(pinnedTo: "parent")
    staleWatcher.locateFile()
    check("a cap event older than launch is still ignored in the fork", !staleWatcher.sawCapHit())

    // 3b. Quiet follows the rebind: a session whose pinned file died an hour ago but whose fork is
    //     mid-turn is BUSY. Before the rebind the dead file made every non-urgent relaunch (follow
    //     adoption, reload, self-update) think it was free to cut the live turn.
    let busy = ForkFixture("busy")
    busy.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    busy.write("fork.jsonl", [busy.marker(own: "fork", launched: "parent")], born: 30, wrote: 0)
    let fresh = busy.dir.appendingPathComponent("fork.jsonl")
    try! FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fresh.path)
    var busyWatcher = busy.watcher(pinnedTo: "parent")
    check("a mid-turn fork reads as busy once followed", !busyWatcher.isQuiet(60))

    // 4. The subagents directory belongs to the session actually running, and the watcher derives
    //    it from the bound file - so a live subagent under the FORK keeps the session busy, and a
    //    long-finished one under the parent no longer speaks for it.
    let packages = ForkFixture("subagents")
    packages.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    packages.write("fork.jsonl", [packages.marker(own: "fork", launched: "parent")],
                   born: 30, wrote: 120)
    packages.subagent(session: "parent", name: "agent-a1.jsonl", age: 900)
    packages.subagent(session: "fork", name: "agent-a2.jsonl", age: 5)
    var packageWatcher = packages.watcher(pinnedTo: "parent")
    check("a live subagent under the fork keeps the session busy", !packageWatcher.isQuiet(60))
    let finished = ForkFixture("subagents-done")
    finished.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    finished.write("fork.jsonl", [finished.marker(own: "fork", launched: "parent")],
                   born: 30, wrote: 120)
    finished.subagent(session: "parent", name: "agent-a1.jsonl", age: 5)
    finished.subagent(session: "fork", name: "agent-a2.jsonl", age: 900)
    var finishedWatcher = finished.watcher(pinnedTo: "parent")
    check("the abandoned session's subagents no longer speak for it",
          finishedWatcher.isQuiet(60))

    // 5. Two moves in one child's life (two `/clear`s): the newest marked file is the live one, the
    //    earlier fork stopped growing. Only a genuine tie is unorderable, and there the watcher
    //    keeps the pin and says so rather than guessing - guessing is what lost the turns.
    let twice = ForkFixture("twice")
    twice.write("parent.jsonl", ["{}"], born: -3600, wrote: -30)
    twice.write("first.jsonl", [twice.marker(own: "first", launched: "parent")], born: 30, wrote: 100)
    twice.write("second.jsonl", [twice.marker(own: "second", launched: "parent")], born: 120, wrote: 200)
    var twiceWatcher = twice.watcher(pinnedTo: "parent")
    twiceWatcher.locateFile()
    check("two moves in one session follow the newest fork",
          twiceWatcher.file?.lastPathComponent == "second.jsonl")
    let tied = ForkFixture("tied")
    tied.write("parent.jsonl", ["{}"], born: -3600, wrote: -30)
    tied.write("one.jsonl", [tied.marker(own: "one", launched: "parent")], born: 30, wrote: 150)
    tied.write("two.jsonl", [tied.marker(own: "two", launched: "parent")], born: 40, wrote: 150)
    var tiedWatcher = tied.watcher(pinnedTo: "parent")
    tiedWatcher.locateFile()
    check("an unorderable tie keeps the pin", tiedWatcher.file?.lastPathComponent == "parent.jsonl")
    check("and the tie is reported once", tiedWatcher.forkAmbiguityWarned)

    // 5b. The move that the chained key could never see: the SECOND move by the same child, made
    //     after the first was already adopted. Every new transcript carries the id the process was
    //     LAUNCHED with (`parent` here, in all three sibling files of the 2026-07-29 incident), not
    //     the id of the file it moved from, so a watcher joining on the file it is bound to looks
    //     for a marker nothing will ever write. From then on every idle gate measures a dead file
    //     and every relaunch resumes it: that is the three orphaned hours and the cut turn.
    let sequential = ForkFixture("sequential")
    sequential.write("parent.jsonl", ["{}"], born: -3600, wrote: -30)
    sequential.write("fork1.jsonl", [sequential.marker(own: "fork1", launched: "parent")],
                     born: 30, wrote: 100)
    var sequentialWatcher = sequential.watcher(pinnedTo: "parent")
    sequentialWatcher.locateFile(forceForkCheck: true)
    check("the first move is adopted (precondition for the second)",
          sequentialWatcher.file?.lastPathComponent == "fork1.jsonl")
    sequential.write("fork2.jsonl", [sequential.marker(own: "fork2", launched: "parent")],
                     born: 200, wrote: 300)
    sequentialWatcher.locateFile(forceForkCheck: true)
    check("a second move by the same child is followed even after the first was adopted",
          sequentialWatcher.file?.lastPathComponent == "fork2.jsonl")
    let secondLive = sequentialWatcher.file?.deletingPathExtension().lastPathComponent
    check("and the relaunch resumes the second fork, not the one it left",
          relaunchArgs(["--resume", "parent", "--model", "fable"],
                       sessionID: secondLive, sameAccount: true)
          == ["--resume", "fork2", "--model", "fable"])
    // The join key is a constant, so fork1 still carries the same marker as fork2 forever. Nothing
    // but its mtime says it is dead, which is why adoption only ever moves forward in time.
    sequentialWatcher.locateFile(forceForkCheck: true)
    check("the earlier dead fork is never re-adopted once the newest is bound",
          sequentialWatcher.file?.lastPathComponent == "fork2.jsonl")
    check("and the pin stays on the newest too", sequentialWatcher.resumeID == "fork2")

    // 5c. Quiet follows the SECOND move as well (3b, one hop further in): the file the watcher was
    //     rebound to an hour ago is now the dead one, and the turn being cut lives in the newest.
    let busyAgain = ForkFixture("busy-second-move")
    busyAgain.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    busyAgain.write("fork1.jsonl", [busyAgain.marker(own: "fork1", launched: "parent")],
                    born: 30, wrote: 100)
    var busyAgainWatcher = busyAgain.watcher(pinnedTo: "parent")
    busyAgainWatcher.locateFile(forceForkCheck: true)
    busyAgain.write("fork2.jsonl", [busyAgain.marker(own: "fork2", launched: "parent")],
                    born: 200, wrote: 0)
    try! FileManager.default.setAttributes(
        [.modificationDate: Date()],
        ofItemAtPath: busyAgain.dir.appendingPathComponent("fork2.jsonl").path)
    check("a second move mid-turn reads as busy", !busyAgainWatcher.isQuiet(60))

    // 6. The cost gates: a conversation still writing to the bound file is not scanned for at all
    //    (one stat), and once a scan has run it does not run again until the interval passes. The
    //    relaunch path forces its way past both, because there the id has to be right.
    let live2 = ForkFixture("live")
    live2.write("parent.jsonl", ["{}"], born: -3600, wrote: 0)
    live2.write("fork.jsonl", [live2.marker(own: "fork", launched: "parent")], born: 30, wrote: 120)
    // Written a second ago, with the file it moved to written since: the live transcript is always
    // the newest one, and only the cost gate keeps the watcher on the parent below.
    try! FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-1)],
        ofItemAtPath: live2.dir.appendingPathComponent("parent.jsonl").path)
    try! FileManager.default.setAttributes(
        [.modificationDate: Date()],
        ofItemAtPath: live2.dir.appendingPathComponent("fork.jsonl").path)
    var liveWatcher = live2.watcher(pinnedTo: "parent")
    liveWatcher.locateFile()
    check("a file still being written is not scanned for a fork",
          liveWatcher.file?.lastPathComponent == "parent.jsonl")
    liveWatcher.locateFile(forceForkCheck: true)
    check("the relaunch path checks anyway", liveWatcher.file?.lastPathComponent == "fork.jsonl")
    let throttled = ForkFixture("throttled")
    throttled.write("parent.jsonl", ["{}"], born: -3600, wrote: -30)
    var throttledWatcher = throttled.watcher(pinnedTo: "parent")
    throttledWatcher.locateFile()                 // one scan, nothing to find yet
    throttled.write("fork.jsonl", [throttled.marker(own: "fork", launched: "parent")],
                    born: 30, wrote: 120)
    throttledWatcher.locateFile()
    check("a scan does not repeat before its interval",
          throttledWatcher.file?.lastPathComponent == "parent.jsonl")
    throttledWatcher.nextForkScan = .distantPast
    throttledWatcher.locateFile()
    check("and the next scan after the interval finds the fork",
          throttledWatcher.file?.lastPathComponent == "fork.jsonl")

    // 7. A marker aimed at a THIRD session (a sibling that itself forked from someone else) is not
    //    ours, and a line whose `sessionId` is not the file it lives in is not a marker at all.
    let elsewhere = ForkFixture("elsewhere")
    elsewhere.write("parent.jsonl", ["{}"], born: -3600, wrote: -30)
    elsewhere.write("other.jsonl", [elsewhere.marker(own: "other", launched: "unrelated")],
                    born: 30, wrote: 120)
    elsewhere.write("mislabelled.jsonl",
                    [elsewhere.marker(own: "somewhere-else", launched: "parent")],
                    born: 40, wrote: 130)
    var elsewhereWatcher = elsewhere.watcher(pinnedTo: "parent")
    elsewhereWatcher.locateFile()
    check("another session's fork is not ours",
          elsewhereWatcher.file?.lastPathComponent == "parent.jsonl")
}
