import Foundation

// WHICH BUILD MAY ANSWER THE MACHINE'S PICKS. Split from pickerchecks.swift for file size, the way
// pickgracechecks.swift already is.
//
// THE INCIDENT this closes (2026-08-09), because the shape of it is the point: the exclusivity that
// keeps two panels off the screen (`takePickClaim`, asserted in pickerchecks 36c4) is decided by the
// file system, and the file system has no opinion about which of the two copies deserves to win. A
// dev build left running overnight, built before the panel's self-cancelling defect was fixed, took
// every request the installed 0.42.0 was there to answer and cancelled it 147ms later. Winning was
// not an accident either: doing less before claiming is exactly what makes a stale build faster.
//
// So there are two rules about one claim now, and they answer different questions. HOW MANY may
// claim is exclusivity. WHO may claim is this file.
func runPickClaimChecks() {

    // MARK: - 36c5. A build nobody installed does not answer for the machine

    let fresh: TimeInterval = 60
    check("the app somebody installed claims, which is the whole point of the panel",
          pickMayBeClaimed(isUnshipped: false, overridden: false, overrideAge: fresh))
    check("a build nobody installed stands down instead",
          !pickMayBeClaimed(isUnshipped: true, overridden: false, overrideAge: fresh))
    // The escape hatch, for the one person the rule above costs anything: a developer driving the
    // picker end to end has to be able to claim, or the path can only ever be tested by shipping it.
    check("…until the launch asks for it back, which is what the override is for",
          pickMayBeClaimed(isUnshipped: true, overridden: true, overrideAge: fresh))
    check("and the override changes nothing for a build that was claiming anyway",
          pickMayBeClaimed(isUnshipped: false, overridden: true, overrideAge: fresh))

    // MARK: - 36c5b. …and the escape hatch closes itself

    // THE INCIDENT (2026-08-10, twice in one day): the flag was carried by a dev instance started
    // to test one thing and then left running, and it answered real picks for the rest of the day.
    // Nobody closes a window they have stopped thinking about, so the override stops instead.
    let stale = CaptureLaunch.pickClaimOverrideLifetime + 1
    check("an override older than its lifetime is read as a launch that never carried one",
          !pickMayBeClaimed(isUnshipped: true, overridden: true, overrideAge: stale))
    check("…and the last moment of the lifetime still claims, so the bound is not off by a launch",
          pickMayBeClaimed(isUnshipped: true, overridden: true,
                           overrideAge: CaptureLaunch.pickClaimOverrideLifetime))
    // THE SHIPPED BUILD IS UNTOUCHED BY THE CLOCK, which is the half an expiry is easy to break: it
    // never looked at the override to begin with, so no amount of age may stop the installed app
    // from answering the machine's picks.
    check("the installed app answers picks however long it has been running",
          pickMayBeClaimed(isUnshipped: false, overridden: false, overrideAge: stale)
              && pickMayBeClaimed(isUnshipped: false, overridden: true, overrideAge: stale))
    // Long enough to drive the picker by hand, short enough to expire inside an afternoon.
    check("the lifetime is minutes rather than seconds or days",
          CaptureLaunch.pickClaimOverrideLifetime >= 10 * 60
              && CaptureLaunch.pickClaimOverrideLifetime <= 2 * 60 * 60)

    // MARK: - 36c6. And the gate is asked BEFORE the claim, not beside it

    // The controller needs AppKit, so the wiring is carried by the source the way the follow dead
    // end and the self-update fold carry theirs. Run from the repo root (run-supervisor-tests.sh cds
    // there), and a missing file FAILS rather than quietly passing.
    let controller = (try? String(contentsOfFile: "Tally/MenuBar/PickPanelController.swift",
                                  encoding: .utf8)) ?? ""
    check("the panel controller is readable from this suite", !controller.isEmpty)
    check("the controller asks the stand-down question at all",
          controller.contains("guard pickMayBeClaimed(isUnshipped: BuildVariant.isUnshipped,"))
    check("…reading the override from the flag that is classified, not a second spelling of it",
          controller.contains("overridden: CaptureLaunch.carries(CaptureLaunch.pickClaimOverride),"))
    // AND AGEING IT AGAINST THE LAUNCH, which is the wiring the expiry above is worth nothing
    // without: the age has to come from when this build started, not from when it first looked.
    check("…and ageing that override against this launch rather than a stamp taken on demand",
          controller.contains("overrideAge: Self.launchAge())")
              && controller.contains("NSRunningApplication.current.launchDate ?? .distantPast"))

    func at(_ needle: String) -> Int? {
        controller.range(of: needle).map {
            controller.distance(from: controller.startIndex, to: $0.lowerBound)
        }
    }
    // ORDER IS THE INVARIANT, not presence. A gate that runs after the claim has already been
    // written would leave the stale build holding the request it then declines to draw, which is the
    // incident with an extra step: the CLI waits out its deadline instead of falling back.
    if let gate = at("guard pickMayBeClaimed("), let claim = at("takePickClaim(id: request.id") {
        check("…and it is asked before the claim is taken", gate < claim)
    } else {
        check("…and it is asked before the claim is taken", false)
    }

    // The preview path is deliberately on the other side of this: it shows the panel directly and
    // writes no answer, so a build that may not answer a real request can still be looked at.
    // Read as the prefix rather than the whole call: the preview also decides what the panel comes
    // up with circled (`CaptureLaunch.modifierKeys` classifies that flag), and what this is about is
    // that nothing on this path was prompted or claimed.
    check("the dev preview does not come through the gate at all",
          controller.contains("shared.show(request, prompted: false"))

    // MARK: - 36c7. The copies that were ALREADY RUNNING, which no gate of ours can reach

    // THE HOLE THE GATE ABOVE LEAVES, and it is the whole reason this section exists (codex review
    // of c6b580e): the stand-down only binds a build that carries it, and every build this is about
    // is older than it. A Tally started yesterday claims exactly as it always did and cancels in
    // 147ms, with the fix sitting in a binary nobody has relaunched.
    //
    // So the arbitration moves to the requester, which asks for something an older app cannot
    // produce: the seal beside the claim. What that reaches is sessions STARTED since it shipped,
    // and no more than that - a running `mcp-serve` keeps the binary it launched with, so the
    // sessions already talking stay as exposed as they were (`pickClaimSealFile` states the limit,
    // and the checks below are about what the new code does, not about reaching the old).

    let skewDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-seal-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: skewDir) }
    try? FileManager.default.createDirectory(at: skewDir, withIntermediateDirectories: true)

    // What a build from before this change writes: the pid, and nothing beside it.
    try! Data("991\n".utf8).write(to: pickClaimFile(id: "old", dir: skewDir))
    check("an old build's claim still names its holder, exactly as it always did",
          readPickClaim(id: "old", dir: skewDir) == 991)
    check("…but it carries no seal, which is the only thing that separates the two protocols",
          !pickClaimIsSealed(id: "old", owner: 991, dir: skewDir))

    // What this build writes, through the one function that does both.
    check("a claim taken by this build succeeds", takePickClaim(id: "new", owner: 55, dir: skewDir))
    check("…and is sealed by the same process that holds it",
          pickClaimIsSealed(id: "new", owner: 55, dir: skewDir))
    check("…with the claim file itself unchanged, so a CLI that predates the seal reads it as before",
          (try? String(contentsOf: pickClaimFile(id: "new", dir: skewDir), encoding: .utf8)) == "55\n")
    check("a seal is about ONE claimant, so it cannot vouch for whoever holds the claim next",
          !pickClaimIsSealed(id: "new", owner: 56, dir: skewDir))
    try! Data("77\n".utf8).write(to: pickClaimFile(id: "junk", dir: skewDir))
    try! Data("not a pid".utf8).write(to: pickClaimSealFile(id: "junk", dir: skewDir))
    check("and a seal that says nothing usable is no seal, the way an unreadable claim is nobody",
          !pickClaimIsSealed(id: "junk", owner: 77, dir: skewDir))

    // MARK: - 36c8. …and what the wait does about one

    // The incident, driven end to end through the real loop: an old copy holds the request and has
    // already written its cancellation. Before this round the wait read that answer and told the
    // person "nothing was changed"; now the answer is not its to give.
    // The person answers the FORM, which is what has to reach them for any of this to have helped:
    // the reply is loaded before the question is asked, so the run cannot deadlock on a client that
    // only speaks when spoken to (the technique 36e3 states).
    var reached: [SwitchIntent] = []
    let stranger = PickChannelDouble()
    stranger.claims = [991]
    stranger.living = [991]                       // alive, and holding it: not the dead-claim case
    stranger.seals = [false]                      // sealed on no lap, which is what makes it old
    stranger.answers = [PickAnswer.cancelled]     // the 147ms self-cancellation, already on disk
    stranger.elapsed = [0, 0, nativePickClaimSeconds + 0.1]
    let overruled = runPick(
        stranger.channel,
        client: [["jsonrpc": "2.0", "id": "tally-elicit-1",
                  "result": ["action": "accept", "content": ["account": "claude:.claude2"]]]],
        world: pickWorld(applied: { reached.append($0) }))
    check("…the wait treats the request as unclaimed and falls back at the claim deadline",
          overruled.sent.contains { $0["method"] as? String == "elicitation/create" })
    check("an old copy's instant cancellation is not what the person is answered with",
          reached == [.pinAccount("claude:.claude2")]
              && !overruled.decision.contains(mcpNothingChanged))

    // And a current app is untouched by any of it: sealed claim, answer honoured, no form.
    var queued: [SwitchIntent] = []
    let current = PickChannelDouble()
    current.claims = [4242]
    current.seals = [true]
    current.answers = [nil, PickAnswer(value: "claude:.claude2")]
    let landed = runPick(current.channel, world: pickWorld(applied: { queued.append($0) }))
    check("a sealed claim is waited on and its answer is the person's",
          landed.decision.contains("queued the move") && queued == [.pinAccount("claude:.claude2")])
    check("…with no form raised behind its back",
          !landed.sent.contains { $0["method"] as? String == "elicitation/create" })

    // The two ends of the same rule, stated together: what decides is the seal, not the pid, not
    // liveness. An old copy that stays alive for the full five minutes still never holds this wait
    // open past the claim deadline, and it is unsealed on EVERY lap, which is what the extra lap
    // below tells it apart by.
    let patient = PickChannelDouble()
    patient.claims = [991]
    patient.living = [991]
    patient.seals = [false]
    patient.elapsed = [0, 0, nativePickClaimSeconds + 0.1]
    let notHeld = runPick(patient.channel, world: pickWorld())
    check("an unsealed claim cannot hold the wait open, however alive its holder is",
          notHeld.sent.contains { $0["method"] as? String == "elicitation/create" })

    // MARK: - 36c9. The microseconds between taking a claim and sealing it

    // THE INTERLEAVING THIS COSTS IF THE UNSEALED READING IS BELIEVED ON SIGHT (codex review of
    // b621bbc): a current app wins the claim and seals it a moment later, and the claim deadline
    // lands in between. Read once, that is a stranger, and the wait draws the form while the panel
    // is coming up - two surfaces for one question, which is the thing the claim exists to stop.
    // So the unsealed reading has to be seen TWICE IN A ROW before it is acted on. A stale build
    // gives it every lap; this gap gives it once.
    var raced: [SwitchIntent] = []
    let sealingLate = PickChannelDouble()
    sealingLate.claims = [4242]
    sealingLate.living = [4242]
    sealingLate.seals = [false, true]                 // claimed on this lap, sealed on the next
    sealingLate.answers = [nil, nil, PickAnswer(value: "claude:.claude2")]
    // The first reading is the wait's own start; every lap after it is already past the claim
    // deadline, so the very first sighting of the unsealed claim is a deadline sighting.
    sealingLate.elapsed = [0, nativePickClaimSeconds + 0.1]
    let survived = runPick(sealingLate.channel, world: pickWorld(applied: { raced.append($0) }))
    check("a claim sealed one lap after the deadline is still the app's, not a stranger's",
          survived.decision.contains("queued the move") && raced == [.pinAccount("claude:.claude2")])
    check("…so no form is drawn behind a panel that was already on its way up",
          !survived.sent.contains { $0["method"] as? String == "elicitation/create" })
    // And the delay is bought for that case alone: a request nobody has claimed is unambiguous, so
    // it still falls back the moment the claim deadline passes.
    let nobody = PickChannelDouble()
    nobody.claims = [nil]
    nobody.elapsed = [0, 0, nativePickClaimSeconds + 0.1]
    let unclaimed = runPick(nobody.channel, world: pickWorld())
    check("an unclaimed request still falls back the moment its deadline passes",
          unclaimed.sent.contains { $0["method"] as? String == "elicitation/create" })
    check("…on the very lap that saw the deadline, with no extra lap spent on anybody's behalf",
          nobody.laps == 2)
    // CONSECUTIVE, which is the other half of the rule: a lap that finds the claim sealed says the
    // gap closed, so a later unsealed reading is a fresh first sighting rather than the second half
    // of an old one. Told apart by WHICH LAP the wait gives up on, because that is the only thing
    // the two versions of the rule differ in.
    let flickering = PickChannelDouble()
    flickering.claims = [4242]
    flickering.seals = [false, true, false, false]
    flickering.elapsed = [0, nativePickClaimSeconds + 0.1]
    let counted = runPick(flickering.channel, world: pickWorld())
    check("a sealed lap in between starts the extra lap over rather than completing it",
          counted.sent.contains { $0["method"] as? String == "elicitation/create" }
              && flickering.laps == 4)

    // The files the wait leaves behind. Carried by the source because the live channel writes into
    // the user's own `~/.tally/pick`, which no suite may touch: a seal left in the directory would
    // outlive the request it vouches for.
    let nativePick = (try? String(contentsOfFile: "TallyCLI/NativePick.swift", encoding: .utf8)) ?? ""
    check("the native pick source is readable from this suite", !nativePick.isEmpty)
    check("the live channel takes the seal away with the rest of the request",
          nativePick.contains("pickClaimSealFile(id: id)"))
}
