import Foundation

// ONE RULE, TWO EXITS: a conversation only ever moves FORWARD, and neither the scan nor a request may
// bind the watcher to a transcript written no later than the one it is already on.
//
// Split from requesttranscriptchecks.swift for file size, the way switchrequestchecks.swift is split
// from switchchecks.swift; the fixtures it leans on (`switchAccount`, `ForkFixture`) are shared from
// there and from forkchecks.swift.
//
// THE REGRESSION THIS FILE EXISTS FOR (cross-model review of 7d871a6, reproduced). The scan has
// always refused a candidate written no later than the file it is bound to, and says why: the
// process writes to exactly one transcript, so everything it left behind stopped growing. The
// request path did not, and one tick runs BOTH stations against BOTH request files:
//
//   /clear -> first, `/tally-model` (hook, no turn) -> model request names `first`
//   /clear -> second, `/tally-account` (hook, no turn) -> switch request names `second`
//
// The account station runs first and adopted `second`; the model station then dragged the watcher
// back to `first`, the execution point's forced scan saw `second` unresolved and newer, and the whole
// tick stood down. Nothing is consumed on a stand-down, so the next tick repeated it: two commands
// that never happen, for ever - the very symptom the request field was added to fix, reached through
// a different door.

func runRequestForwardChecks() {
    let onA = switchAccount("A")
    let toB = switchAccount("B", label: "Claude 2")
    var fleetPolicy = LaunchPolicy()
    fleetPolicy.mode = "auto"
    var fleetDefault = LaunchPolicy()
    fleetDefault.model = "fable"
    fleetDefault.effort = "high"
    let launched = ["--model", "fable", "--effort", "high"]
    let tickDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-request-forward-\(UUID().uuidString)")

    /// A session that has cleared TWICE with a hook-answered command after each: bound to the file
    /// both clears left behind, with two unresolvable candidates newer than it.
    func twiceCleared(_ label: String) -> (fixture: ForkFixture, watcher: TranscriptWatcher) {
        let fixture = ForkFixture(label)
        fixture.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
        fixture.write("first.jsonl", fixture.clearedLines(own: "first"), born: 30, wrote: 100)
        fixture.write("second.jsonl", fixture.clearedLines(own: "second"), born: 40, wrote: 200)
        return (fixture, fixture.watcher(pinnedTo: "parent"))
    }

    var (_, twice) = twiceCleared("monotonic")
    check("the newer of two clears is adopted",
          adoptRequestedTranscript("second", watcher: &twice, sessionKey: "4242"))
    check("and the older one is then refused, whoever names it",
          !adoptRequestedTranscript("first", watcher: &twice, sessionKey: "4242"))
    check("…so the watcher stays on the conversation that is still being written",
          twice.file?.lastPathComponent == "second.jsonl" && twice.resumeID == "second")
    // The rule is "newer than what is BOUND", not "the newest in the directory", which is the same
    // shape the scan has: a request naming a superseded clear still moves the watcher forward, and
    // the hold then keeps that from being acted on until the newest one resolves (asserted below).
    var (_, superseded) = twiceCleared("superseded")
    check("a superseded clear is still forward motion from the file before it",
          adoptRequestedTranscript("first", watcher: &superseded, sessionKey: "4242"))
    // A TIE IS NOT FORWARD MOTION, which is where the comparison being strict is decided. The scan
    // refuses to order two candidates written at the same moment and keeps its pin rather than
    // guessing (`forkAmbiguityWarned`, TranscriptFork.swift), because guessing is what orphaned the
    // turns in the first place; one measure, one boundary.
    let tied = ForkFixture("request-tied")
    tied.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    tied.write("tie.jsonl", tied.clearedLines(own: "tie"), born: 30, wrote: 100)
    let tieMoment = Date().addingTimeInterval(-300)
    for name in ["parent.jsonl", "tie.jsonl"] {
        try! FileManager.default.setAttributes(
            [.modificationDate: tieMoment],
            ofItemAtPath: tied.dir.appendingPathComponent(name).path)
    }
    var tiedWatcher = tied.watcher(pinnedTo: "parent")
    tiedWatcher.locateFile()
    check("a candidate written at the same moment as the bound file is not forward motion",
          !adoptRequestedTranscript("tie", watcher: &tiedWatcher, sessionKey: "4242"))
    check("…so the watcher keeps the file it can still order itself against",
          tiedWatcher.file?.lastPathComponent == "parent.jsonl")
    // A BOUND FILE THAT HAS VANISHED orders nothing, and refusing to move on that would strand the
    // session on a path that no longer exists: a missing file reads as QUIET (`isBoundFileQuiet`
    // returns true when it cannot stat one), so the next relaunch would resume an id with nothing
    // behind it. The scan answers the same way from the same expression - an unreadable mtime is
    // `.distantPast`, so everything is forward of it - and this is the half of that parity a
    // conservative-looking `guard let` would quietly break.
    let vanished = ForkFixture("request-vanished-bound")
    vanished.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    vanished.write("live.jsonl", vanished.clearedLines(own: "live"), born: 30, wrote: 100)
    var vanishedWatcher = vanished.watcher(pinnedTo: "parent")
    vanishedWatcher.locateFile()
    try! FileManager.default.removeItem(at: vanished.dir.appendingPathComponent("parent.jsonl"))
    check("a bound file that has vanished does not block the move",
          adoptRequestedTranscript("live", watcher: &vanishedWatcher, sessionKey: "4242"))
    check("…so the watcher lands on the conversation that is actually there",
          vanishedWatcher.file?.lastPathComponent == "live.jsonl")

    // The order the two stations run in is a RULE rather than an arrangement, and this section's
    // whole-tick fixture below depends on it, so it is read off the source that owns it rather than
    // assumed.
    let directives = (try? String(contentsOfFile: "TallyCLI/SessionDirectives.swift",
                                  encoding: .utf8)) ?? ""
    check("the directives source is readable from the suite", !directives.isEmpty)
    if let accountStation = directives.range(of: "applyManualMoves("),
       let modelStation = directives.range(of: "applySessionModel(") {
        check("the account station really runs before the model station on one tick",
              accountStation.lowerBound < modelStation.lowerBound)
    } else {
        check("both stations were found in the directives source", false)
    }

    // The whole tick, in that order, against real request files so the consumption is real too.
    let (_, live) = twiceCleared("two-clears-one-tick")
    var liveWatcher = live
    // TWO DIRECTORIES, because that is what the product has: both request files are named for the
    // supervisor pid, and only the directory tells a switch from a model change (`switchRequestDir`
    // against `modelRequestDir`). Pointing this fixture at one directory made the second write
    // clobber the first, and the tick under test then had no model request at all - a green-looking
    // way to assert nothing.
    let raceRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-two-clears-\(UUID().uuidString)")
    let raceDir = raceRoot.appendingPathComponent("switch")
    let raceModelDir = raceRoot.appendingPathComponent("model")
    let asked = Date(timeIntervalSince1970: 1_800_000_000)
    try! writeModelRequest(model: "opus", effort: "xhigh", sessionKey: "4242",
                           transcriptID: "first", now: asked, dir: raceModelDir)
    try! writeSwitchRequest(accountID: "B", sessionKey: "4242", transcriptID: "second",
                            now: asked, dir: raceDir)
    var raceMoves = ManualMoveState(sessionKey: "4242", servedEpoch: 100, dir: raceDir)
    var raceModel = SessionModelState(sessionKey: "4242", servedEpoch: 100, dir: raceModelDir)
    var raceFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "high"])

    /// One whole tick of both stations, in the order `applySessionDirectives` runs them.
    func directiveTick() -> (plan: RelaunchPlan?, switchRecord: PendingSwitchConsumption?,
                             modelRecord: PendingModelConsumption?) {
        var plan: RelaunchPlan?
        var switchRecord: PendingSwitchConsumption?
        var modelRecord: PendingModelConsumption?
        var under = fleetPolicy
        applyManualMoves(plan: &plan, state: &raceMoves, record: &switchRecord, policy: &under,
                         account: onA, providerID: "claude", watcher: &liveWatcher, childAge: 9999,
                         keyboardIdle: { _ in true }, dir: raceDir,
                         request: { readSwitchRequest(sessionKey: $0, dir: raceDir) },
                         accounts: { [onA, toB] }, homeOnDisk: { _, _ in false })
        var planning = TickPlan(plan)
        applySessionModel(plan: &planning, state: &raceModel, record: &modelRecord,
                          follow: &raceFollow, policy: fleetDefault, account: onA,
                          providerID: "claude", launchArgs: launched,
                          accountPinned: raceMoves.sessionPin != nil || under.mode == "manual",
                          quarantine: [:], watcher: &liveWatcher, childAge: 9999,
                          keyboardIdle: { _ in true }, dir: raceModelDir,
                          request: readModelRequest(sessionKey: "4242", dir: raceModelDir),
                          snapshot: { (Snapshot(version: 2, generatedAt: Date(), accounts: [onA]),
                                       String?.none) })
        return (planning.plan, switchRecord, modelRecord)
    }

    let race = directiveTick()
    check("the account named by the newer request is planned",
          race.plan?.target.id == "B" && race.plan?.reason == "switch")
    check("…with the pair from the older request folded onto the same restart",
          race.plan?.model == "opus" && race.plan?.effort == "xhigh")
    check("THE FIX: the second station cannot drag the watcher back to the earlier clear",
          liveWatcher.file?.lastPathComponent == "second.jsonl"
              && liveWatcher.resumeID == "second")
    // THE ASSERTION THAT ENCODES THE LOOP. The execution point re-scans, forced, and stands the
    // tick down if anything newer than the bound file is still unresolvable. Bound to the earlier
    // clear, `second` is exactly that, so the relaunch is cancelled - and because nothing is
    // consumed on a stand-down, the next tick does it all again.
    liveWatcher.locateFile(forceForkCheck: true)
    check("…so the execution point does not stand the whole tick down",
          !relaunchHeldByUnresolvedFork(reason: race.plan?.reason ?? "switch",
                                        unresolvedFork: liveWatcher.hasUnresolvedFork))
    check("…which is what lets both requests be consumed rather than replayed for ever",
          race.switchRecord != nil && race.modelRecord != nil)
    race.switchRecord?.commit(&raceMoves)
    race.modelRecord?.commit(&raceModel)
    check("the account instruction is served and its pin recorded",
          raceMoves.servedEpoch == 1_800_000_000_000 && raceMoves.sessionPin == "B")
    check("…and so is the pair, on the same restart",
          raceModel.servedEpoch == 1_800_000_000_000
              && raceModel.pin == SessionModelPin(model: "opus", effort: "xhigh"))
    check("…with both request files gone, so nothing is replayed",
          readSwitchRequest(sessionKey: "4242", dir: raceDir) == nil
              && readModelRequest(sessionKey: "4242", dir: raceModelDir) == nil)
    let settled = directiveTick()
    check("and the tick after it plans nothing at all", settled.plan == nil)
    try? FileManager.default.removeItem(at: raceRoot)

    // WHAT HAPPENS TO A REQUEST WHOSE CONVERSATION HAS BEEN SUPERSEDED, which is the question the
    // rule above raises: the watcher moves forward onto the file that request named, and the newest
    // clear is STILL unresolvable, so the hold does what it has always done and the request waits.
    // That wait is the hold's documented cost rather than a deadlock of its own, and this asserts
    // both halves of why: nothing loops meanwhile, and the first turn the user types releases it
    // onto the conversation they are actually in.
    let (waiting, held) = twiceCleared("superseded-request")
    var heldWatcher = held
    var heldState = SessionModelState(sessionKey: "5502", servedEpoch: 100, dir: tickDir)
    var heldFollow = FollowState(launchArgs: launched)

    func heldTick() -> RelaunchPlan? {
        var planning = TickPlan(nil)
        var record: PendingModelConsumption?
        applySessionModel(plan: &planning, state: &heldState, record: &record, follow: &heldFollow,
                          policy: fleetDefault, account: onA, providerID: "claude",
                          launchArgs: launched, accountPinned: false, quarantine: [:],
                          watcher: &heldWatcher, childAge: 9999, keyboardIdle: { _ in true },
                          dir: tickDir,
                          request: ModelRequest(epoch: 200, model: "opus", effort: "xhigh",
                                                transcriptID: "first"),
                          snapshot: { (Snapshot(version: 2, generatedAt: Date(), accounts: [onA]),
                                       String?.none) })
        record?.commit(&heldState)
        return planning.plan
    }

    check("a request naming a superseded clear plans nothing while the newest one is unreadable",
          heldTick() == nil)
    check("…it waits, visibly, rather than being lost",
          heldState.waiting?.badge == sessionModelWaitingBadge && heldState.servedEpoch == 100)
    check("…and the wait is the hold's, not a watcher that keeps moving",
          heldWatcher.file?.lastPathComponent == "first.jsonl" && heldWatcher.hasUnresolvedFork)
    check("…and the tick after that does exactly the same thing, stably", heldTick() == nil)
    // The one thing that resolves it is the one thing these commands cannot spend: a turn. When the
    // user types in the conversation they are actually in, its first event stamps this child's
    // launch id, the scan adopts it, the hold lifts, and the instruction lands there.
    waiting.append("second.jsonl", [waiting.marker(own: "second", launched: "parent")], wrote: 300)
    let released = heldTick()
    check("the user's next turn in the live conversation releases the wait",
          released?.model == "opus" && released?.effort == "xhigh")
    check("…and the instruction lands on the conversation they are actually in",
          heldWatcher.resumeID == "second" && heldState.servedEpoch == 200)
    try? FileManager.default.removeItem(at: tickDir)
}
