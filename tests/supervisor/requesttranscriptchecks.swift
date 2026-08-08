import Foundation

// The request that names its own conversation (RequestTranscript.swift), and the deadlock it exists
// to end.
//
// THE INCIDENT (2026-08-08). A supervised session was `/clear`ed and then asked to move accounts with
// `/tally-account`. The CLI wrote the request correctly and the hook reported "it moves when the
// current turn ends"; the session never moved, and it exited with the request still on disk. The
// chain: `/clear` starts a transcript that carries no assistant event and no `session_id`, so the
// fork scan can prove it neither a fork nor a sibling; that unresolved candidate holds `isQuiet`
// false so no non-urgent relaunch resumes an id the conversation may have left; and the ONLY thing
// that could have resolved it - a turn - is exactly what these hook-answered commands are built never
// to spend. Stable, not a race: `/clear` followed only by `/tally-*` reproduces it every time.
//
// The fix does not touch the hold. It gives the request the one witness the scan does not have:
// Claude Code's own id for the conversation the prompt was typed into.

func runRequestTranscriptChecks() {
    // MARK: - 34a. What may be carried, and what a hostile value comes to

    // The value is turned into a path inside the watcher's project directory, so the shape is a
    // security bound rather than a tidiness one. Claude Code's ids are UUIDs; anything that could
    // name a file elsewhere is not one.
    check("a uuid-shaped id is usable",
          isTranscriptSessionID("fa4677f4-e618-41c7-8443-43aa27f062ea"))
    check("an underscore is too", isTranscriptSessionID("agent_42"))
    check("an empty id names nothing", !isTranscriptSessionID(""))
    check("a path separator is refused", !isTranscriptSessionID("../../etc/passwd"))
    check("so is a bare dot segment", !isTranscriptSessionID(".."))
    check("and a dotted name, which is how an extension would be smuggled in",
          !isTranscriptSessionID("id.jsonl"))
    check("a run of a thousand characters is not an id either",
          !isTranscriptSessionID(String(repeating: "a", count: 1_000)))

    // Only the surfaces that were TOLD have one. A hook and the MCP picker are handed the id by
    // Claude Code; a person's shell descends from the session and is handed nothing, so it says
    // "cannot say" rather than guessing - and the supervisor is left with exactly the fork scan it
    // has always had.
    check("a hook's payload carries the conversation it came from",
          SessionMarkerTrust.corroborated(PromptOrigin(marker: "4242", promptSession: "conv-1",
                                                       claudeCodePID: 99)).promptTranscriptID
              == "conv-1")
    check("a shell inside the session carries none",
          SessionMarkerTrust.trusted("4242").promptTranscriptID == nil)
    check("a payload with no session id carries none either",
          SessionMarkerTrust.corroborated(PromptOrigin(marker: "4242", promptSession: nil,
                                                       claudeCodePID: 99)).promptTranscriptID == nil)
    check("and an unusable one is dropped rather than passed on",
          SessionMarkerTrust.corroborated(PromptOrigin(marker: "4242", promptSession: "../evil",
                                                       claudeCodePID: 99)).promptTranscriptID == nil)

    // MARK: - 34b. The format, in both directions at once

    // THE COMPATIBILITY CLAIM, asserted rather than asserted-to-have-been-considered. A supervisor
    // replaces itself with the installed build at the next idle moment, so until it does, an OLD
    // supervisor is reading files a NEW CLI wrote. The field is APPENDED: every line an older reader
    // knows keeps its position, and the line it has never heard of sits after them where its own
    // parse ignores it.
    check("a request written before this field existed parses exactly as it did",
          parseSwitchRequest("1800000000123\nacct-2\n")
              == SwitchRequest(epoch: 1_800_000_000_123, accountID: "acct-2"))
    check("and one carrying it parses into the same two fields plus the conversation",
          parseSwitchRequest("1800000000123\nacct-2\nconv-1\n")
              == SwitchRequest(epoch: 1_800_000_000_123, accountID: "acct-2",
                               transcriptID: "conv-1"))
    check("an empty third line is no conversation, not an empty one",
          parseSwitchRequest("1800000000123\nacct-2\n\n")?.transcriptID == nil)
    // An unusable id is dropped WITHOUT taking the request with it: it says nothing about the
    // account, which is the instruction the user actually gave.
    check("an unusable conversation id leaves a perfectly good switch request",
          parseSwitchRequest("1800000000123\nacct-2\n../../etc/passwd\n")
              == SwitchRequest(epoch: 1_800_000_000_123, accountID: "acct-2"))
    let switchDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-request-transcript-\(UUID().uuidString)")
    try! writeSwitchRequest(accountID: "acct-2", sessionKey: "4242", transcriptID: "conv-1",
                            now: Date(timeIntervalSince1970: 1_800_000_000), dir: switchDir)
    let switchBody = (try? String(contentsOf: switchRequestFile(sessionKey: "4242", dir: switchDir),
                                  encoding: .utf8)) ?? ""
    let switchLines = switchBody.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    check("the stamp and the account keep the lines an older reader takes them from",
          switchLines.count > 2 && switchLines[0] == "1800000000000"
              && switchLines[1] == "acct-2" && switchLines[2] == "conv-1")
    // The same body truncated to what a build without this field would have read: an old parser read
    // lines 1 and 2 and stopped, so this is that reader's answer, and it is the right one.
    check("…so the fields an old supervisor reads are unchanged by the addition",
          parseSwitchRequest(switchLines.prefix(2).joined(separator: "\n"))
              == SwitchRequest(epoch: 1_800_000_000_000, accountID: "acct-2"))
    // THE VALUE IS UNTRUSTED WHERE IT IS WRITTEN TOO, and the failure there is not a bad field but a
    // SHIFTED FILE: an id carrying a newline would not land in the third line, it would BE a fourth
    // one, and every field a reader takes positionally after it moves down by one. The switch file
    // has nothing after it today; the model file has, which is why both are asserted.
    try! writeSwitchRequest(accountID: "acct-2", sessionKey: "6161",
                            transcriptID: "conv-1\nacct-hijacked",
                            now: Date(timeIntervalSince1970: 1_800_000_000), dir: switchDir)
    let hostile = ((try? String(contentsOf: switchRequestFile(sessionKey: "6161", dir: switchDir),
                                encoding: .utf8)) ?? "")
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    check("an id carrying a newline never becomes a line of its own",
          hostile.count == 4 && hostile[2].isEmpty)
    check("…and the request it rides on is still the one that was asked for",
          readSwitchRequest(sessionKey: "6161", dir: switchDir)
              == SwitchRequest(epoch: 1_800_000_000_000, accountID: "acct-2"))
    check("a request written with nothing to say carries no conversation",
          readSwitchRequest(sessionKey: "9999", dir: switchDir) == nil)
    try! writeSwitchRequest(accountID: "acct-2", sessionKey: "5150", dir: switchDir)
    check("…and round-trips as the request it always was",
          readSwitchRequest(sessionKey: "5150", dir: switchDir)?.transcriptID == nil)
    try? FileManager.default.removeItem(at: switchDir)

    // The model axis says the same thing one line further down, because its effort already sits on
    // line 3. Getting this wrong in the obvious way - inserting rather than appending - would make an
    // older supervisor read the conversation id as the effort and kill its child on every tick
    // (`claude --effort conv-1` exits immediately), which is why the position is asserted.
    check("a model request written before this field existed parses as it did",
          parseModelRequest("1800000000123\nopus\nxhigh\n")
              == ModelRequest(epoch: 1_800_000_000_123, model: "opus", effort: "xhigh"))
    check("and one carrying it keeps the effort exactly where it was",
          parseModelRequest("1800000000123\nopus\nxhigh\nconv-1\n")
              == ModelRequest(epoch: 1_800_000_000_123, model: "opus", effort: "xhigh",
                              transcriptID: "conv-1"))
    check("an unnamed effort still means the effort axis is left alone",
          parseModelRequest("1800000000123\nopus\n\nconv-1\n")
              == ModelRequest(epoch: 1_800_000_000_123, model: "opus", effort: nil,
                              transcriptID: "conv-1"))
    check("and an unusable conversation id leaves the pair intact",
          parseModelRequest("1800000000123\nopus\nxhigh\n../evil\n")
              == ModelRequest(epoch: 1_800_000_000_123, model: "opus", effort: "xhigh"))
    let modelDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-request-model-\(UUID().uuidString)")
    try! writeModelRequest(model: "opus", effort: "xhigh", sessionKey: "4242",
                           transcriptID: "conv-1",
                           now: Date(timeIntervalSince1970: 1_800_000_000), dir: modelDir)
    let modelLines = ((try? String(contentsOf: modelRequestFile(sessionKey: "4242", dir: modelDir),
                                   encoding: .utf8)) ?? "")
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    check("the model file appends too, leaving the first three lines where they were",
          modelLines.count > 3 && modelLines[0] == "1800000000000" && modelLines[1] == "opus"
              && modelLines[2] == "xhigh" && modelLines[3] == "conv-1")
    check("…so an older supervisor still reads the pair it was given",
          parseModelRequest(modelLines.prefix(3).joined(separator: "\n"))
              == ModelRequest(epoch: 1_800_000_000_000, model: "opus", effort: "xhigh"))
    try! writeModelRequest(model: "opus", effort: "xhigh", sessionKey: "6161",
                           transcriptID: "conv-1\nsomething-else",
                           now: Date(timeIntervalSince1970: 1_800_000_000), dir: modelDir)
    let hostileModel = ((try? String(contentsOf: modelRequestFile(sessionKey: "6161", dir: modelDir),
                                     encoding: .utf8)) ?? "")
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    check("an id carrying a newline gains the model file no lines either",
          hostileModel.count == 5 && hostileModel[3].isEmpty)
    check("…so the pair the user asked for is what a supervisor still reads",
          readModelRequest(sessionKey: "6161", dir: modelDir)
              == ModelRequest(epoch: 1_800_000_000_000, model: "opus", effort: "xhigh"))
    try? FileManager.default.removeItem(at: modelDir)

    // MARK: - 34c. The adoption itself: the four ways it refuses

    /// A session whose conversation has moved to a `/clear` nobody has typed into: the bound file is
    /// long quiet, the new one proves nothing, and the hold is in force. The state every check below
    /// starts from, because it is the state the incident happened in.
    func heldSession(_ label: String) -> TranscriptWatcher {
        let fixture = ForkFixture(label)
        fixture.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
        fixture.write("cleared.jsonl", fixture.clearedLines(own: "cleared"), born: 30, wrote: 120)
        var watcher = fixture.watcher(pinnedTo: "parent")
        check("the hold is in force before \(label) begins",
              !watcher.isQuiet(manualMoveIdleSeconds) && watcher.hasUnresolvedFork)
        return watcher
    }

    // The reset both ways in share (`moveTo`, TranscriptFork.swift), asked directly, because neither
    // caller can see the whole of it: the fork scan and the adoption below BOTH resolve the join key
    // on their way in (one to find candidates, the other to weigh the evidence), so the latch inside
    // the move is a no-op from either and a mutation of its ORDER survived the rest of this file.
    // The day a third caller does not ask first is the day the order decides, and what it decides is
    // the 2026-07-29 incident: a key latched onto the file just adopted makes every later move by
    // the same child invisible, and the relaunch resumes a conversation that stopped growing hours
    // ago.
    let moving = ForkFixture("move-latches-key")
    moving.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    moving.write("cleared.jsonl", moving.clearedLines(own: "cleared"), born: 30, wrote: 120)
    var mover = TranscriptWatcher(projectDir: moving.dir,
                                  file: moving.dir.appendingPathComponent("parent.jsonl"),
                                  since: moving.launchedAt, resumeID: "parent")
    mover.moveTo(moving.dir.appendingPathComponent("cleared.jsonl"))
    check("a move resolves the join key against the file it is LEAVING", mover.launchID == "parent")
    check("…and the resume id against the one it arrives at", mover.resumeID == "cleared")
    check("…with the cap offset back at the top of it", mover.offset == 0)

    var adopting = heldSession("adoption")
    check("a request naming the conversation it came from moves the watcher onto it",
          adoptRequestedTranscript("cleared", watcher: &adopting, sessionKey: "4242"))
    check("…so the id the next relaunch resumes is the one after the clear",
          adopting.file?.lastPathComponent == "cleared.jsonl" && adopting.resumeID == "cleared")
    check("…and the hold is gone, because the thing it could not tell apart has been named",
          !adopting.hasUnresolvedFork)
    check("…which is what lets the session read quiet again", adopting.isQuiet(manualMoveIdleSeconds))
    // The join key is the id this CHILD was launched with and never moves with an adoption; latching
    // it after the move would make the next `/clear` invisible for the rest of the child's life
    // (TranscriptFork.swift, the 2026-07-29 incident).
    check("…while the fork join key still names the launch, not the file just adopted",
          adopting.launchID == "parent")
    check("asking again once it is bound changes nothing",
          !adoptRequestedTranscript("cleared", watcher: &adopting, sessionKey: "4242"))

    // REFUSAL 1: nothing was carried. A request from a person's own shell has no such report, and
    // must behave exactly as it did before this existed.
    var unnamed = heldSession("no-conversation")
    check("a request carrying nothing adopts nothing",
          !adoptRequestedTranscript(nil, watcher: &unnamed, sessionKey: "4242"))
    check("…and the hold stands, which is the behaviour that protects a move nobody can see yet",
          !unnamed.isQuiet(manualMoveIdleSeconds) && unnamed.hasUnresolvedFork)
    check("…on the file it was already bound to", unnamed.file?.lastPathComponent == "parent.jsonl")

    // REFUSAL 2: a name with no file behind it (a conversation removed, a payload from a shape
    // nobody here has measured). Nothing to bind, nothing to crash on, and today's behaviour stands.
    var ghost = heldSession("no-such-file")
    check("a conversation this directory does not hold is not adopted",
          !adoptRequestedTranscript("ghost", watcher: &ghost, sessionKey: "4242"))
    check("…and the session is exactly as it was",
          ghost.file?.lastPathComponent == "parent.jsonl" && ghost.hasUnresolvedFork)

    // REFUSAL 3: a file another live supervisor says it is watching. Binding to it would point every
    // later reading - quiet, cap detection, and the id the next relaunch resumes - at somebody else's
    // live conversation.
    let stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-request-state-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    // A presence entry for a pid that really is alive (this process), which is what makes it a live
    // supervisor to `liveSupervisorPids`, plus the conversation it publishes as the one it watches.
    let neighbour = String(getpid())
    try! "".write(to: stateDir.appendingPathComponent(neighbour), atomically: true, encoding: .utf8)
    writeSessionContext(SupervisedSession(accountID: "A", contextTokens: 1, updatedAt: Date(),
                                          sessionPin: nil, axes: SessionAxes(),
                                          transcript: "cleared"),
                        pid: neighbour, dir: stateDir)
    var taken = heldSession("watched-elsewhere")
    check("a conversation another live supervisor is watching is never taken over",
          !adoptRequestedTranscript("cleared", watcher: &taken, sessionKey: "4242", dir: stateDir))
    check("…and that session is left on its own file",
          taken.file?.lastPathComponent == "parent.jsonl" && taken.hasUnresolvedFork)
    // The mirror, which is the reason the reading is asked of OTHER supervisors only: this
    // supervisor's own published id is the stale one by construction - it names the file the
    // conversation has left, which is the whole situation being repaired.
    var ourOwn = heldSession("watched-by-us")
    check("our own published reading never refuses our own request",
          adoptRequestedTranscript("cleared", watcher: &ourOwn, sessionKey: neighbour,
                                   dir: stateDir))
    try? FileManager.default.removeItem(at: stateDir)

    // REFUSAL 4: the file itself proves it belongs to another conversation. An assistant turn this
    // child never took, or somebody else's launch id, is evidence IN the file, and it outranks a
    // report about where a prompt was typed.
    let strangers = ForkFixture("request-stranger")
    strangers.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    strangers.write("stranger.jsonl", [strangers.marker(own: "stranger", launched: "stranger")],
                    born: 30, wrote: 120)
    var stranger = strangers.watcher(pinnedTo: "parent")
    stranger.locateFile()
    check("a request naming a conversation with somebody else's turns in it is refused",
          !adoptRequestedTranscript("stranger", watcher: &stranger, sessionKey: "4242"))
    check("…leaving the watcher where it was", stranger.file?.lastPathComponent == "parent.jsonl")
    // The other half of the same rule: a candidate the scan can already prove is THIS
    // conversation's own move is not refused by the evidence check. The bound file is written a
    // second ago here, so the scan's cost gate has not looked yet and the request is what settles
    // it - a poll early, which is the whole point of naming it.
    let ours = ForkFixture("request-own-fork")
    ours.write("parent.jsonl", ["{}"], born: -3600, wrote: 0)
    ours.write("fork.jsonl", [ours.marker(own: "fork", launched: "parent")], born: 30, wrote: 120)
    // BOTH inside the scan's 5s cost window, and the fork the later of the two: the gate keeps the
    // scan from moving anything, while the move itself is still forward in time (a candidate written
    // BEFORE the bound file is refused, and rightly - requestforwardchecks.swift).
    try! FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-4)],
        ofItemAtPath: ours.dir.appendingPathComponent("parent.jsonl").path)
    try! FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-2)],
        ofItemAtPath: ours.dir.appendingPathComponent("fork.jsonl").path)
    var ownFork = ours.watcher(pinnedTo: "parent")
    ownFork.locateFile()
    check("the scan's cost gate has not moved it yet",
          ownFork.file?.lastPathComponent == "parent.jsonl")
    check("a candidate proven to be this conversation's own move is adopted by name",
          adoptRequestedTranscript("fork", watcher: &ownFork, sessionKey: "4242")
              && ownFork.file?.lastPathComponent == "fork.jsonl")

    // A transcript older than this child cannot be where it moved to, whatever a request says: the
    // fork scan's own rule (`scanCandidates`), and without it a request could resume a conversation
    // from before the launch and replace the one on screen.
    let ancient = ForkFixture("request-ancient")
    ancient.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    ancient.write("prior.jsonl", ancient.clearedLines(own: "prior"), born: -1800, wrote: -600)
    var ancientWatcher = ancient.watcher(pinnedTo: "parent")
    ancientWatcher.locateFile()
    check("a conversation that predates this child is not adopted by name either",
          !adoptRequestedTranscript("prior", watcher: &ancientWatcher, sessionKey: "4242"))

    // MARK: - 34d. Through a whole tick, on both axes

    // The incident itself, end to end: the same held session, the same request, decided twice - once
    // as the request was written before this change (nothing carried) and once as it is written now.
    // The ONLY difference between the two ticks is the field, which is what makes this a regression
    // for the defect rather than for the fix.
    let onA = switchAccount("A")
    let toB = switchAccount("B", label: "Claude 2")
    let tickDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-request-tick-\(UUID().uuidString)")
    var moves = ManualMoveState(sessionKey: "4242", servedEpoch: 100)
    var fleetPolicy = LaunchPolicy()
    fleetPolicy.mode = "auto"
    var session = heldSession("switch-tick")

    func switchTick(_ request: SwitchRequest) -> RelaunchPlan? {
        var plan: RelaunchPlan?
        var record: PendingSwitchConsumption?
        var under = fleetPolicy
        applyManualMoves(plan: &plan, state: &moves, record: &record, policy: &under,
                         account: onA, providerID: "claude", watcher: &session, childAge: 9999,
                         keyboardIdle: { _ in true }, dir: tickDir, request: { _ in request },
                         accounts: { [onA, toB] }, homeOnDisk: { _, _ in false })
        return plan
    }

    let blind = switchTick(SwitchRequest(epoch: 200, accountID: "B"))
    check("THE DEFECT: a `/tally-account` after a `/clear` is queued and never carried out",
          blind == nil)
    check("…with nothing on the status line to say so, because a queued move raises no badge",
          moves.waiting == nil && moves.servedEpoch == 100)
    let named = switchTick(SwitchRequest(epoch: 200, accountID: "B", transcriptID: "cleared"))
    check("THE FIX: the same request, naming the conversation it came from, moves the session",
          named?.target.id == "B" && named?.reason == "switch")
    check("…resuming the conversation the clear started, not the one before it",
          session.resumeID == "cleared")

    // The model axis hangs in exactly the same way through exactly the same gate, so it is closed in
    // the same change: `/tally-model` after a `/clear` is answered by the same hook and writes no
    // turn either. Only fixing the account half would leave the identical hole one file away.
    var modelSession = heldSession("model-tick")
    var modelState = SessionModelState(sessionKey: "5501", servedEpoch: 100, dir: tickDir)
    var follow = FollowState(launchArgs: ["--model", "fable", "--effort", "high"])
    var fleetDefault = LaunchPolicy()
    fleetDefault.model = "fable"
    fleetDefault.effort = "high"

    func modelTick(_ request: ModelRequest) -> RelaunchPlan? {
        var planning = TickPlan(nil)
        var record: PendingModelConsumption?
        applySessionModel(plan: &planning, state: &modelState, record: &record, follow: &follow,
                          policy: fleetDefault, account: onA, providerID: "claude",
                          launchArgs: ["--model", "fable", "--effort", "high"],
                          accountPinned: false, quarantine: [:], watcher: &modelSession,
                          childAge: 9999, keyboardIdle: { _ in true }, dir: tickDir,
                          request: request,
                          snapshot: { (Snapshot(version: 2, generatedAt: Date(), accounts: [onA]),
                                       String?.none) })
        return planning.plan
    }

    let modelBlind = modelTick(ModelRequest(epoch: 200, model: "opus", effort: "xhigh"))
    check("THE SAME DEFECT one axis over: a `/tally-model` after a `/clear` never takes effect",
          modelBlind == nil)
    check("…and sits behind a turn-end that will not come",
          modelState.waiting?.badge == sessionModelWaitingBadge && modelState.servedEpoch == 100)
    let modelNamed = modelTick(ModelRequest(epoch: 200, model: "opus", effort: "xhigh",
                                            transcriptID: "cleared"))
    check("THE SAME FIX: naming the conversation lets the pair take effect",
          modelNamed?.model == "opus" && modelNamed?.effort == "xhigh")
    check("…on the conversation the clear started",
          modelSession.resumeID == "cleared" && modelState.waiting == nil)
    try? FileManager.default.removeItem(at: tickDir)
}
