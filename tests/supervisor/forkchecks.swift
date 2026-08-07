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

    /// Append to a transcript that already exists, then re-age it - the scan reads only what is new,
    /// so a candidate has to be SCANNED before its first turn lands for the fixture to exercise the
    /// state the hold is for. Writing the whole file up front would test a different thing.
    func append(_ name: String, _ lines: [String], wrote: TimeInterval) {
        let url = dir.appendingPathComponent(name)
        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try! handle.close()
        try! FileManager.default.setAttributes(
            [.modificationDate: launchedAt.addingTimeInterval(wrote)], ofItemAtPath: url.path)
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

    /// What `/clear` leaves on disk before the first real turn, taken from the 2026-08-04 incident
    /// file (10 lines, 17 KB - these are its distinct event types, the attachments repeated): not
    /// one assistant event and not one `session_id` between them.
    func clearedLines(own: String) -> [String] {
        [#"{"type":"mode","sessionId":"\#(own)","mode":"default"}"#,
         #"{"type":"file-history-snapshot","messageId":"m1","sessionId":"\#(own)","snapshot":{}}"#,
         #"{"type":"attachment","sessionId":"\#(own)","attachment":{"type":"file","path":"/tmp/a"}}"#,
         #"{"type":"user","sessionId":"\#(own)","message":{"role":"user","content":"/clear"}}"#,
         #"{"type":"system","subtype":"local_command","sessionId":"\#(own)","content":""}"#,
         #"{"type":"last-prompt","sessionId":"\#(own)","prompt":"/clear"}"#,
         #"{"type":"queue-operation","sessionId":"\#(own)","operation":"clear"}"#]
    }

    /// An attachment whose payload carries `session_id` as a NESTED key. Attachment bodies are
    /// arbitrary JSON (hook output, file snapshots), so this is what a substring test reads as
    /// somebody's launch id; the scan decides on the TOP level, where there is no `session_id` at
    /// all, so a line like this proves nothing in either direction.
    func nestedIDAttachment(own: String, id: String) -> String {
        #"{"type":"attachment","sessionId":"\#(own)","attachment":{"type":"hook","payload":{"session_id":"\#(id)"}}}"#
    }

    /// A candidate that OPENS with a single line bigger than one scan block, with a multi-byte
    /// character straddling the block boundary exactly, and its real turn behind that line. The
    /// first scan steps over the oversized line and leaves the offset inside the character, so the
    /// next block begins on a truncated scalar: decoding that block whole fails, and the turn behind
    /// it is never read again. `head + filler` is one byte short of the boundary, so the three bytes
    /// of the CJK character sit at `forkScanBytes - 1`, `forkScanBytes` and `forkScanBytes + 1`.
    func straddlingLines(own: String) -> [String] {
        let head = #"{"type":"attachment","sessionId":"\#(own)","note":""#
        let filler = String(repeating: "x", count: forkScanBytes - 1 - head.utf8.count)
        return [head + filler + #"中x"}"#, plainTurn(own: own)]
    }

    /// A real turn carrying NO `session_id` at all - the shape of 49 of this machine's 367 recent
    /// transcripts, so "no marker" can never be the test for an unresolved candidate.
    func plainTurn(own: String, at offset: TimeInterval = 60) -> String {
        #"{"isSidechain":false,"type":"assistant","uuid":"u-\#(own)","timestamp":"\#(stamp(offset))","sessionId":"\#(own)","message":{"model":"claude-fable-5"}}"#
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
    // A scan that found nothing does NOT buy quiet for the next one. There used to be a 10s rate
    // limit here, and it was a hole through the hold in section 8: a move landing inside the window
    // was invisible to every gate that asked, while the 5s bar they use was already satisfied. The
    // pass costs 0.83 ms on the largest project directory on this machine (240 transcripts,
    // measured 2026-08-04), so the answer is current instead.
    let repeated = ForkFixture("repeat-scan")
    repeated.write("parent.jsonl", ["{}"], born: -3600, wrote: -30)
    var repeatedWatcher = repeated.watcher(pinnedTo: "parent")
    repeatedWatcher.locateFile()                  // one scan, nothing to find yet
    repeated.write("fork.jsonl", [repeated.marker(own: "fork", launched: "parent")],
                   born: 30, wrote: 120)
    repeatedWatcher.locateFile()
    check("a move made right after an empty scan is seen by the very next one",
          repeatedWatcher.file?.lastPathComponent == "fork.jsonl")

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

    // MARK: - 8. The unresolved candidate: a `/clear` nobody has typed into yet

    // The marker only exists from a session's FIRST REAL TURN, so between the clear and the first
    // prompt the new file proves nothing: not a fork (no marker yet), not a sibling either. The
    // watcher stays bound to the file the conversation left, every idle gate reads that dead file
    // as quiet, and the queued non-urgent relaunch resumes the id from before the clear - the
    // conversation snaps back and the new file is orphaned with the prompt in it (2026-08-04).
    // So while such a candidate exists, quiet is unanswerable and the answer is no.
    let cleared = ForkFixture("cleared")
    cleared.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    cleared.write("cleared.jsonl", cleared.clearedLines(own: "cleared"), born: 30, wrote: 120)
    var clearedWatcher = cleared.watcher(pinnedTo: "parent")
    check("a /clear with no turn in it yet holds every non-urgent relaunch",
          !clearedWatcher.isQuiet(60))
    check("and it is the hold that says so, not the bound file", clearedWatcher.hasUnresolvedFork)
    check("nothing is adopted while the candidate proves nothing",
          clearedWatcher.file?.lastPathComponent == "parent.jsonl")
    // The evidence is read at the TOP level of each line, so an id sitting somewhere inside an
    // attachment payload releases nothing: a substring test would call this file a sibling and let
    // the relaunch through, on a line no session wrote as its own.
    let trap = ForkFixture("cleared-nested-id")
    trap.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    trap.write("trap.jsonl",
               trap.clearedLines(own: "trap")
                   + [trap.nestedIDAttachment(own: "trap", id: "somebody-else")],
               born: 30, wrote: 120)
    var trapWatcher = trap.watcher(pinnedTo: "parent")
    check("a session id nested inside an attachment payload resolves nothing",
          !trapWatcher.isQuiet(60))

    // The ambiguity resolves itself, in whichever direction the first turn goes. Appended AFTER
    // the scans above, because a fixture written whole up front never enters the held state.
    cleared.append("cleared.jsonl", [cleared.marker(own: "cleared", launched: "parent")], wrote: 200)
    check("the first turn stamps our launch id, so the hold ends in an adoption",
          clearedWatcher.isQuiet(60))
    check("and the watcher is now on the file the conversation moved to",
          clearedWatcher.file?.lastPathComponent == "cleared.jsonl")
    check("so the next relaunch resumes the new id",
          relaunchArgs(["--resume", "parent"], sessionID: clearedWatcher.resumeID, sameAccount: true)
          == ["--resume", "cleared"])

    // The other direction: the first turn in that file belongs to somebody else, so it was a
    // sibling all along. The hold ends without an adoption - and it must, or a second tab opened
    // and left idle would defer every non-urgent relaunch for the rest of the session.
    let stranger = ForkFixture("cleared-stranger")
    stranger.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    stranger.write("stranger.jsonl", stranger.clearedLines(own: "stranger"), born: 30, wrote: 120)
    var strangerWatcher = stranger.watcher(pinnedTo: "parent")
    check("the same empty candidate holds to begin with", !strangerWatcher.isQuiet(60))
    stranger.append("stranger.jsonl", [stranger.plainTurn(own: "stranger")], wrote: 200)
    check("a turn that is not ours ends the hold with no adoption", strangerWatcher.isQuiet(60))
    check("and the watcher stays where it was",
          strangerWatcher.file?.lastPathComponent == "parent.jsonl")

    // A sibling that has already written a turn is never held, by either of the two proofs. The
    // second one is the reason the test cannot be "carries no marker": 49 of this machine's 367
    // recent transcripts (2026-08-04) hold real turns and no `session_id` anywhere, so that test
    // would hold on every one of them, forever.
    let stamped = ForkFixture("sibling-stamped")
    stamped.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    stamped.write("sibling.jsonl", [stamped.marker(own: "sibling", launched: "sibling")],
                  born: 30, wrote: 120)
    var stampedWatcher = stamped.watcher(pinnedTo: "parent")
    check("a sibling stamping its own launch id never holds", stampedWatcher.isQuiet(60))
    let unstamped = ForkFixture("sibling-unstamped")
    unstamped.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    unstamped.write("sibling.jsonl", [unstamped.plainTurn(own: "sibling")], born: 30, wrote: 120)
    var unstampedWatcher = unstamped.watcher(pinnedTo: "parent")
    check("nor does a sibling with real turns and no session_id at all",
          unstampedWatcher.isQuiet(60))

    // An empty file OLDER than the bound one cannot be where this conversation went - the process
    // writes to exactly one transcript, so anything it left behind stopped growing. Same rule the
    // adoption itself uses, and without it a stale empty session would hold the supervisor forever.
    let older2 = ForkFixture("cleared-older")
    older2.write("parent.jsonl", ["{}"], born: -3600, wrote: 100)
    older2.write("stale.jsonl", older2.clearedLines(own: "stale"), born: 10, wrote: 20)
    var older2Watcher = older2.watcher(pinnedTo: "parent")
    check("an empty candidate written before the bound file does not hold",
          older2Watcher.isQuiet(60))
    check("and the hold flag says so too", !older2Watcher.hasUnresolvedFork)

    // MARK: - 8b. Every ask gets a current answer, and the execution point asks once more

    // The flag only moves when the fork scan runs, so the scan is not rate-limited: a `/clear` made
    // one poll after a scan that found nothing is seen by the NEXT gate that asks, not up to ten
    // seconds later. That window used to exist, and it was a hole straight through this hold - the
    // 5s bar (pin switch, degradation rescue, fallback profile) is satisfied long before it closes,
    // so the restart went ahead on the id from before the clear.
    //
    // It matters where the answer arrives, not just that it does: every planner commits its
    // bookkeeping AFTER its own quiet gate, so a current answer stops them before there is anything
    // to undo (standdownchecks.swift holds the case that proved it).
    let blind = ForkFixture("current-answer")
    blind.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    var blindWatcher = blind.watcher(pinnedTo: "parent")
    check("a first scan finds nothing to hold on", blindWatcher.isQuiet(5))
    blind.write("cleared.jsonl", blind.clearedLines(own: "cleared"), born: 30, wrote: 120)
    check("a /clear right after that scan is held by the very next ask", !blindWatcher.isQuiet(5))
    check("and the flag is what says so", blindWatcher.hasUnresolvedFork)
    // The execution point asks once more, forced, for the `/clear` that lands in the microseconds
    // between a planner's gate and the kill.
    blindWatcher.locateFile(forceForkCheck: true)
    check("the forced pre-flight sees it too", blindWatcher.hasUnresolvedFork)
    check("and a non-urgent plan stands down on it",
          relaunchHeldByUnresolvedFork(reason: "pin", unresolvedFork: blindWatcher.hasUnresolvedFork))
    check("a cap handoff is never held: an empty session cannot have capped, and the capped "
          + "conversation is the bound file",
          !relaunchHeldByUnresolvedFork(reason: "cap", unresolvedFork: blindWatcher.hasUnresolvedFork))
    check("and nothing is held once the scan is clear",
          !relaunchHeldByUnresolvedFork(reason: "pin", unresolvedFork: false))
    // The rule is only worth anything where the restart happens, and the order there is the point:
    // forced scan, then the question, then the kill. `performHandoff` forces a scan of its own, but
    // it runs AFTER the SIGTERM, which is too late to change its mind.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the suite", !loop.isEmpty)
    if let start = loop.range(of: "if let plan {"),
       let kill = loop.range(of: "performHandoff(to: plan.target",
                             range: start.upperBound ..< loop.endIndex) {
        let preflight = String(loop[start.upperBound ..< kill.lowerBound])
        check("the plan execution point forces its own fork scan",
              preflight.contains("locateFile(forceForkCheck: true)"))
        check("and asks the hold before it terminates anything",
              preflight.contains("relaunchHeldByUnresolvedFork"))
        check("a held plan stands the tick down rather than falling through to the kill",
              preflight.contains("continue"))
    } else {
        check("the plan execution point was found", false)
    }

    // MARK: - 8c. A line bigger than one scan block must not swallow the evidence behind it

    // Stepping over an oversized opening line leaves the offset inside a multi-byte character, so
    // the next block starts on a truncated scalar. Decoding that block as one string fails, and the
    // offset has already moved: the turn sitting behind the big line would never be read again and
    // the hold would never lift, freezing self-update and reload for the life of the session.
    let straddle = ForkFixture("oversized-line")
    straddle.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    straddle.write("huge.jsonl", straddle.straddlingLines(own: "huge"), born: 30, wrote: 120)
    var straddleWatcher = straddle.watcher(pinnedTo: "parent")
    check("a candidate whose first line fills a whole block holds while it is stepped over",
          !straddleWatcher.isQuiet(60))
    check("the next scan reads the turn behind the straddling character and releases the hold",
          straddleWatcher.isQuiet(60))
    check("and the candidate is settled as a sibling, not left unresolved",
          !straddleWatcher.hasUnresolvedFork)

    // Both of this file's messages describe a tick that relaunches NOTHING - a hold, and a scan that
    // refused to guess - so the child is drawing while they are written and the terminal is the one
    // place they may not go (PendingNotice.swift's rule). They are said once each either way, so the
    // log line is the whole record.
    let held = unresolvedForkHoldLine(pid: "4242", cwd: "/Users/x/work/my project",
                                      now: Date(timeIntervalSince1970: 1_800_000_000))
    check("a held restart is recorded with the session it belongs to",
          held.contains(" pid=4242 ") && held.contains(" hold=unresolved-fork "))
    check("…and the directory comes last, where a space in it costs nothing",
          held.hasSuffix(" cwd=/Users/x/work/my project\n"))
    let ambiguous = forkAmbiguityLine(boundID: "abcdefgh12345678",
                                      now: Date(timeIntervalSince1970: 1_800_000_000))
    check("an ambiguous fork records which conversation it stayed on",
          ambiguous.contains(" session=abcdefgh ") && ambiguous.contains(" fork=ambiguous ")
              && ambiguous.contains("action=staying-on-parent"))
    let forkSource = (try? String(contentsOfFile: "TallyCLI/TranscriptFork.swift",
                                  encoding: .utf8)) ?? ""
    check("the fork source is readable from the suite", !forkSource.isEmpty)
    check("and neither message reaches the shared terminal", !forkSource.contains("warn("))
}
