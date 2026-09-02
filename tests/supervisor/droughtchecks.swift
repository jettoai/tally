import Foundation

// WHAT A PIN IS WORTH ONCE THE ACCOUNT UNDER IT IS EMPTY (TallyCLI/DroughtWatch.swift), and the one
// audit line a drought nobody could move a session out of leaves behind.
//
// THE INCIDENT (2026-08-21, session a97d0856). A session put on an account by hand sat on one whose
// flagship window had read 0% for eighty-one minutes. All four preventive movers refuse a pinned
// session on their FIRST gate, so none of them ever looked at the numbers; the only mechanism left
// was the cap handoff, which needs a turn that has already hit the wall. The session lost a turn to
// a 429 and was moved 1.4 seconds later. Three projects on this machine pin an account through
// `tally project set --account`, and a session in one of those could not even be rescued by a cap
// (`capRecoveryAction` answered `.waitPinned`).
//
// THE GRID IS THE POINT of this file rather than any single case: three pin scopes by three account
// states. What the release must be is exactly one cell wide - the account SPENT, under a pin the
// user set at the session or project scope - and asserting the other eight is what says so.

func runDroughtChecks() {
    let droughtNow = Date(timeIntervalSince1970: 1_800_000_000)

    /// One account, varied only in how much of the flagship window is left. `modelWindowName` is
    /// "fable" and the sessions here run fable, so that window is the one that binds.
    func droughtAccount(_ id: String, model: Double, label: String? = nil) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: label ?? id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: model,
                         sessionResetsAt: droughtNow.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: droughtNow.addingTimeInterval(100 * 3600),
                         modelResetsAt: droughtNow.addingTimeInterval(100 * 3600),
                         modelWindowName: "fable", resetCreditsAvailable: nil, isStale: false,
                         error: nil, refreshedAt: droughtNow)
    }

    // The three states an account under a session can be in, by the two gates that name them.
    let comfortable = droughtAccount("D", model: 60)
    let dying = droughtAccount("D", model: 3)      // under the 5% line, but not at the wall
    let spentNow = droughtAccount("D", model: 0)   // nothing left at all
    let sibling = droughtAccount("S", model: 80, label: "Claude 3")
    check("the three states are the two gates this repo already draws", {
        let primary = "fable"
        return accountIsComfortable(comfortable, primaryModel: primary, now: droughtNow)
            && !accountIsComfortable(dying, primaryModel: primary, now: droughtNow)
            && !accountIsSpent(dying, primaryModel: primary, now: droughtNow)
            && accountIsSpent(spentNow, primaryModel: primary, now: droughtNow)
    }())

    // MARK: - 32a. The rule, on its own

    check("a pin over an account with something left is untouched",
          !pinYieldsToSpentAccount(appMode: "auto", pinnedSpent: false))
    check("a pin over one with nothing left yields",
          pinYieldsToSpentAccount(appMode: "auto", pinnedSpent: true))
    check("but the APP's own pin never does: that mode is the fleet saying Tally never re-picks",
          !pinYieldsToSpentAccount(appMode: "manual", pinnedSpent: true))
    var pinned = LaunchPolicy()
    pinned.mode = "manual"
    pinned.pinnedAccountID = "D"
    check("releasing one reads as automatic selection",
          pinReleasedPolicy(pinned, yielding: true).mode == "auto")
    check("…and leaves the account it named on the record, because the release is meant to lapse",
          pinReleasedPolicy(pinned, yielding: true).pinnedAccountID == "D")
    check("a policy that was never pinned is handed back exactly as it came", {
        var auto = LaunchPolicy()
        auto.mode = "auto"
        let released = pinReleasedPolicy(auto, yielding: true)
        return released.mode == "auto" && released.pinnedAccountID == nil
    }())
    check("and nothing moves while the account still has something in it",
          pinReleasedPolicy(pinned, yielding: false).mode == "manual")

    // MARK: - 32b. The grid: three scopes by three account states

    /// The tick's own composition, in the order Supervisor.swift performs it: the app's policy, the
    /// project's over it, the release, this session's pin over that, and the release again (a
    /// session pin is folded in AFTER the first one and lands as a fresh `manual`).
    ///
    /// Mirrored here rather than driven through `runSupervised`, which spawns a child: what this
    /// keeps honest is the ORDER, and the two things a drifted copy of it could get wrong - a
    /// release that misses the session pin, and one that reaches the app's - are the two cases
    /// asserted below.
    /// DRIVEN BY A SNAPSHOT RATHER THAN BY A BOOL, which is what stops this grid from asserting
    /// states production cannot reach. The earlier version took `spent:` as a literal, and one of
    /// its cells handed `true` while the session sat on a healthy account - a pairing that could
    /// not occur while the release was keyed on the account UNDER the session, so the assertion
    /// built on it read as proof that the restart loop was closed when it was proof of nothing
    /// (codex review of 7404128). Here the release comes out of a real `DroughtWatch` reading over
    /// a real fleet, so a cell that cannot happen cannot be written.
    ///
    /// `sittingOn` is where the session is; the account the pin NAMES is derived the way the tick
    /// derives it, innermost scope first.
    func policies(app: LaunchPolicy, projectAccount: String?, sessionPin: String?,
                  sittingOn current: Snapshot.Account, fleet accounts: [Snapshot.Account]? = nil)
        -> (moving: LaunchPolicy, session: LaunchPolicy, yields: Bool) {
        var project = ProjectPolicy()
        project.accountID = projectAccount
        let declared: LaunchPolicy = effectivePolicy(app, project: project)
        let rows: [Snapshot.Account] = accounts ?? [current, sibling]
        let reading: (Snapshot?, String?)
            = (Snapshot(version: 2, generatedAt: droughtNow, accounts: rows), nil)
        var watch = DroughtWatch()
        watch.observe(provider: "claude", account: current, primaryModel: "fable",
                      pinned: sessionPolicy(declared, sessionPin: sessionPin).pinnedAccountID,
                      loaded: reading, now: droughtNow)
        let yields: Bool = pinYieldsToSpentAccount(appMode: app.mode,
                                                   pinnedSpent: watch.pinnedSpent)
        let moving: LaunchPolicy = pinReleasedPolicy(declared, yielding: yields)
        return (moving, pinReleasedPolicy(sessionPolicy(moving, sessionPin: sessionPin),
                                          yielding: yields), yields)
    }

    /// Whether the preventive movers would carry this session off, asked through the two that share
    /// one gate list: the idle rebalance and the turn-boundary move. Everything but `mode` is held
    /// wide open, so what varies across the grid is the pin and the account.
    func moves(_ session: LaunchPolicy, current: Snapshot.Account) -> Bool {
        let rebalance = rebalanceTarget(
            steering: true, mode: session.mode, blocked: false, agentsWorking: false, isQuiet: true,
            carryable: true, fuseAllows: true, current: current, candidates: [sibling],
            primaryModel: "fable", now: droughtNow)
        let boundary = turnBoundaryTarget(
            steering: true, mode: session.mode, blocked: false, keyboardIdle: true,
            draftSuspected: false, carryable: true, fuseAllows: true, agentsIdle: true,
            turnEnded: true, toolCallOpen: false, current: current, candidates: [sibling],
            primaryModel: "fable", now: droughtNow)
        // The two must never disagree about a pin: they share this gate and this account.
        check("the two claim-sharing movers agree about \(session.mode) on \(current.modelRemaining ?? -1)%",
              (rebalance == nil) == (boundary == nil))
        return rebalance != nil
    }

    /// And whether a cap could hand the session on, which is the second half of every cell: the
    /// reading the handoff is judged by comes from the FLEET's policy (`capReading`), never the
    /// session's.
    func capMoves(_ moving: LaunchPolicy, sessionPin: String?) -> CapAction {
        let reading = capReading(fleet: moving, sessionPin: sessionPin, candidates: [sibling])
        return capRecoveryAction(steering: true, mode: reading.mode, fuseAllows: true,
                                 snapshotStale: false, hasTarget: true)
    }

    var appAuto = LaunchPolicy()
    appAuto.mode = "auto"
    var appPinned = LaunchPolicy()
    appPinned.mode = "manual"
    appPinned.pinnedAccountID = "D"

    for (state, current) in [("comfortable", comfortable), ("dying", dying), ("spent", spentNow)] {
        // The EXPECTATION, no longer also the input: what varies across the grid is the fleet the
        // reading is taken over, and this is what the reading has to come out as.
        let spent = state == "spent"

        // A SESSION PIN (`tally account`), the incident's own case.
        let session = policies(app: appAuto, projectAccount: nil, sessionPin: "D",
                               sittingOn: current)
        check("a session pin on a \(state) account moves \(spent ? "" : "no")where",
              moves(session.session, current: current) == spent)
        check("…and a cap on it hands the session on either way",
              capMoves(session.moving, sessionPin: "D") == .handoff)

        // A PROJECT PROFILE (`tally project set --account`), which three repos on this machine set.
        let project = policies(app: appAuto, projectAccount: "D", sessionPin: nil,
                               sittingOn: current)
        check("a project pin on a \(state) account moves \(spent ? "" : "no")where",
              moves(project.session, current: current) == spent)
        check("…and its cap \(spent ? "hands the session on" : "waits, as pinning means")",
              capMoves(project.moving, sessionPin: nil) == (spent ? .handoff : .waitPinned))

        // THE APP'S OWN PIN, untouched by any of this: one scope above a single session.
        let fleet = policies(app: appPinned, projectAccount: nil, sessionPin: nil,
                             sittingOn: current)
        check("the fleet's own pin holds a \(state) account", !moves(fleet.session, current: current))
        check("…and its cap waits, whatever the numbers say",
              capMoves(fleet.moving, sessionPin: nil) == .waitPinned)
    }

    // The two cells the composition above exists to keep honest, stated on their own.
    check("the release reaches a pin folded in AFTER it, which is where a session pin arrives",
          policies(app: appAuto, projectAccount: nil, sessionPin: "D",
                   sittingOn: spentNow).session.mode == "auto")
    check("and a session pin over the APP's pin is not released either: that scope is never",
          policies(app: appPinned, projectAccount: nil, sessionPin: "D",
                   sittingOn: spentNow).session.mode == "manual")

    // MARK: - 32c. The pin switch stands down with the movers, and STAYS down after the move

    // THE HALF THAT WOULD MAKE THIS A RESTART LOOP RATHER THAN A FIX. `applyPinSwitch` drags a
    // running session onto the pinned account whenever the two disagree, asking only whether that
    // account is launchable and never whether it has quota (SessionSwitch.swift). Released, it has
    // to stand down: otherwise the mover carries the session off the spent account and the very next
    // quiet tick carries it back, once per cycle, for as long as the drought lasts.
    //
    // EVERY CASE HERE HAS THE SESSION ON S, because that is the only position in which this mover
    // does anything at all (its third guard is `pinnedID != account.id`). Which is also why the
    // account the release is judged on cannot be the one under the session: on this path there is
    // always a healthy account under the session and an empty one named by the pin.
    let switchDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-drought-\(UUID().uuidString)")
    let pinnedAccounts = [switchAccount("D", label: "Claude 4"), switchAccount("S", label: "Claude 3")]
    /// The pin switch on a tick where the session sits on S and something pins D.
    ///
    /// `fleet` IS PART OF THE QUESTION NOW, and it was not before: this mover plays on the movers'
    /// shared field (`liveMoveField`), so what D's own row says decides as much as the policy does.
    /// The default is the pair of healthy rows the policy-only cases want; the cells about a spent
    /// or quarantined D hand it the fleet those cells are about.
    ///
    /// It hands back the WAIT as well as the plan, because a pin that does not move the session is
    /// only half a reading: the other half is whether the person watching was told why.
    func pinSwitchTick(_ policy: LaunchPolicy, fleet: [Snapshot.Account] = pinnedAccounts,
                       quarantine: [String: (model: String?, until: Date)] = [:],
                       reading: ((Snapshot?, String?))? = nil)
        -> (plan: RelaunchPlan?, waiting: PendingBadge?) {
        var watcher = idleWatcher("drought")
        var plan: RelaunchPlan?
        var state = ManualMoveState(sessionKey: "9191", servedEpoch: 100, dir: switchDir)
        var record: PendingSwitchConsumption?
        var under = policy
        applyManualMoves(plan: &plan, state: &state, record: &record, policy: &under,
                         account: fleet[1], providerID: "claude", primaryModel: "fable",
                         quarantine: quarantine, watcher: &watcher,
                         childAge: 9999, keyboardIdle: { _ in true }, dir: switchDir,
                         request: { _ in nil }, accounts: { fleet },
                         loaded: { reading ?? switchFleetReading(fleet) },
                         quarantineIn: switchQuarantineDir)
        return (plan, state.waiting)
    }
    func pinSwitchPlan(_ policy: LaunchPolicy, fleet: [Snapshot.Account] = pinnedAccounts,
                       quarantine: [String: (model: String?, until: Date)] = [:]) -> RelaunchPlan? {
        pinSwitchTick(policy, fleet: fleet, quarantine: quarantine).plan
    }
    /// The tick as it stands just after a preventive mover acted: the session is on S, a project
    /// profile names D, and `pinned` is the row D has in the fleet at that moment.
    func afterTheMove(pinnedRow: Snapshot.Account, app: LaunchPolicy = appAuto,
                      projectAccount: String? = "D")
        -> (moving: LaunchPolicy, session: LaunchPolicy, yields: Bool) {
        policies(app: app, projectAccount: projectAccount, sessionPin: nil, sittingOn: sibling,
                 fleet: [pinnedRow, sibling])
    }
    let healthyFleet: [Snapshot.Account] = [comfortable, sibling]
    let spentFleet: [Snapshot.Account] = [spentNow, sibling]
    check("a pin the session is off drags it back while the account IT NAMES has something left",
          pinSwitchPlan(afterTheMove(pinnedRow: comfortable).moving,
                        fleet: healthyFleet)?.target.id == "D")
    // THE CELL THE RESTART LOOP LIVES IN, and the one this check could not reach before: judged on
    // the account UNDER the session it reads "nothing to release" - S is healthy, it always is
    // here - the pin switch is handed an unreleased policy and drags the session back into the same
    // wall the mover just carried it out of.
    check("…and stands down for as long as the account it names has nothing, session moved or not",
          pinSwitchPlan(afterTheMove(pinnedRow: spentNow).moving, fleet: spentFleet) == nil)
    // …and the release really is what is standing there. The reading behind it, taken over the
    // same fleet, is asserted in full one section down (`carried`).
    check("…which is the release, standing on a tick where the session's own account is healthy",
          afterTheMove(pinnedRow: spentNow).yields)

    // MARK: - 32c-2. AND THE MOVER'S OWN FIELD, which is the half the release cannot cover

    // THE ASSERTION THIS REPLACES SAID THE OPPOSITE: "the app's own pin drags it back either way,
    // which is what that scope means". It was true of the old resolver and it is the shape of the
    // 2026-09-01 incident. A fleet pin is never RELEASED - that part is unchanged and asserted just
    // above - but the pin switch is a proactive mover and now plays on the field every proactive
    // mover plays on (`liveMoveField`), so it waits for the account it names to be one a move may
    // go to at all. Deferred, never broken: the cell below shows the same pin taking the session
    // home the moment that account can serve again.
    //
    // What the old behaviour cost is worse than the wait: every preventive mover refuses a
    // fleet-pinned session on `mode == "manual"` and the cap handoff answers `.waitPinned` for one,
    // so a session dragged onto a spent account under a fleet pin has nothing left that can move it
    // until the window resets.
    check("a fleet pin does not drag the session onto an account with nothing left either",
          pinSwitchPlan(afterTheMove(pinnedRow: spentNow, app: appPinned,
                                     projectAccount: nil).moving, fleet: spentFleet) == nil)
    check("…and takes it home the moment that account can serve again, pin never touched",
          pinSwitchPlan(afterTheMove(pinnedRow: comfortable, app: appPinned,
                                     projectAccount: nil).moving,
                        fleet: healthyFleet)?.target.id == "D")
    // THE CELL THE OWNER HIT (handoff.log 2026-09-01: cap-handoff at 04:20:55, `reason=pin` back at
    // 04:21:29, cap again at 04:22:45, back again at 04:23:20). The cap handoff quarantines the
    // account whose wall this session just hit and carries the session to a sibling; the quarantine
    // is the only record that D is unusable RIGHT NOW, because D's published percentages can still
    // read healthy - here D is `comfortable`, exactly as it was that morning.
    check("a pin naming the account the cap handoff just walked out of waits for the quarantine",
          pinSwitchPlan(afterTheMove(pinnedRow: comfortable, app: appPinned,
                                     projectAccount: nil).moving, fleet: healthyFleet,
                        quarantine: ["D": (model: "fable",
                                           until: Date().addingTimeInterval(600))]) == nil)
    // …and only for the window it names: a quarantine on the fable window says nothing about a
    // session running sonnet, which is `quarantineBlocks`' own rule and the reason this is a wait
    // rather than a divorce.
    check("…and a quarantine that has expired stops saying anything at all",
          pinSwitchPlan(afterTheMove(pinnedRow: comfortable, app: appPinned,
                                     projectAccount: nil).moving, fleet: healthyFleet,
                        quarantine: ["D": (model: "fable",
                                           until: Date().addingTimeInterval(-1))])?.target.id == "D")
    // A SNAPSHOT THAT CANNOT ANSWER IS NOT A REASON TO MOVE, which is the same sentence the release
    // makes about its own missing data (`observe`) and which this station used to contradict: the
    // old resolver read the accounts out of a STALE document, because `loadSnapshot` hands back the
    // snapshot beside the problem rather than instead of it.
    check("a snapshot too old to trust holds the pin switch exactly as it holds every other mover", {
        var watcher = idleWatcher("drought-stale")
        var plan: RelaunchPlan?
        var state = ManualMoveState(sessionKey: "9292", servedEpoch: 100, dir: switchDir)
        var record: PendingSwitchConsumption?
        var under = afterTheMove(pinnedRow: comfortable, app: appPinned,
                                 projectAccount: nil).moving
        applyManualMoves(plan: &plan, state: &state, record: &record, policy: &under,
                         account: sibling, providerID: "claude", primaryModel: "fable",
                         watcher: &watcher, childAge: 9999, keyboardIdle: { _ in true },
                         dir: switchDir, request: { _ in nil }, accounts: { healthyFleet },
                         loaded: {
                             switchFleetReading(healthyFleet,
                                                generatedAt: Date().addingTimeInterval(
                                                    -(snapshotMaxAge + 60)))
                         },
                         quarantineIn: switchQuarantineDir)
        return plan == nil
    }())

    // MARK: - 32c-3. AND THE WAIT IS SAID OUT LOUD, which for a long time it was not

    // ONLY ONE OF THE THREE CELLS ENDS ON A CLOCK. A quarantine expires on its TTL; a snapshot
    // nothing can read and an account with nothing left last as long as they last, and under a
    // FLEET pin nothing else is going to move the session meanwhile (every preventive mover stands
    // down on `mode == "manual"`, the cap handoff answers `.waitPinned`, and this station is the
    // one left). Both surfaces draw such a session as pinned to the account it is not on
    // (SessionPinScope.swift), and until this existed the status line said nothing about why: a
    // typed `tally switch` held by the same fleet has had its own badge all along.
    let spentWait = pinSwitchTick(afterTheMove(pinnedRow: spentNow, app: appPinned,
                                               projectAccount: nil).moving, fleet: spentFleet)
    check("a fleet pin held by an empty account says so rather than waiting in silence",
          spentWait.plan == nil && spentWait.waiting?.badge == "pin: nothing left")
    check("…and names the account the session is staying on meanwhile",
          spentWait.waiting?.detail?.contains(sibling.label) == true)
    // TOLD APART FROM THE ONE THAT EXPIRES, which is the whole reason these are separate badges: a
    // reader who cannot tell them apart cannot tell "a few minutes" from "until the window resets".
    let cappedWait = pinSwitchTick(afterTheMove(pinnedRow: comfortable, app: appPinned,
                                                projectAccount: nil).moving, fleet: healthyFleet,
                                   quarantine: ["D": (model: "fable",
                                                      until: Date().addingTimeInterval(600))])
    check("a pin waiting on a quarantine reads as the wall it is, not as an empty account",
          cappedWait.plan == nil && cappedWait.waiting?.badge == "pin: just capped")
    // And the two cells where the fleet cannot answer at all, which are one reading apart: a
    // document too old to trust says nothing about ANY account, while a fresh one that simply does
    // not list the pinned account says something quite specific about that one.
    let staleWait = pinSwitchTick(afterTheMove(pinnedRow: comfortable, app: appPinned,
                                               projectAccount: nil).moving, fleet: healthyFleet,
                                  reading: switchFleetReading(
                                      healthyFleet,
                                      generatedAt: Date().addingTimeInterval(-(snapshotMaxAge + 60))))
    check("a snapshot too old to judge on says that, rather than blaming the account",
          staleWait.plan == nil && staleWait.waiting?.badge == "pin: no snapshot")
    let unlistedWait = pinSwitchTick(afterTheMove(pinnedRow: comfortable, app: appPinned,
                                                  projectAccount: nil).moving,
                                     fleet: [comfortable, sibling],
                                     reading: switchFleetReading([sibling]))
    check("a pinned account the fleet has stopped listing is a wait of its own kind",
          unlistedWait.plan == nil && unlistedWait.waiting?.badge == "pin: not listed")
    // The badge is a STATE, never a moment: the same rule both other waiting axes are held to
    // (`promisesAMoment`, switchchecks.swift), because the term that lifts a wait is not the term
    // that raised it.
    check("and none of the four promises a moment",
          [PinSwitchWait.unreadable, .unlisted, .spent, .quarantined].allSatisfy {
              !promisesAMoment(pinSwitchWaitBadge($0, pinned: "Claude 4", staying: "Claude 3").badge)
          })
    // AND IT NEVER SPEAKS OVER A TYPED INSTRUCTION. `tally switch` is the more specific news about
    // the same fleet, and this row holds one badge (PendingNotice.swift).
    check("a pin wait does not displace the badge a `tally switch` just raised", {
        var watcher = idleWatcher("drought-both")
        var plan: RelaunchPlan?
        var state = ManualMoveState(sessionKey: "9393", servedEpoch: 100, dir: switchDir)
        var record: PendingSwitchConsumption?
        var under = afterTheMove(pinnedRow: spentNow, app: appPinned, projectAccount: nil).moving
        applyManualMoves(plan: &plan, state: &state, record: &record, policy: &under,
                         account: sibling, providerID: "claude", primaryModel: "fable",
                         watcher: &watcher, childAge: 9999, keyboardIdle: { _ in true },
                         dir: switchDir,
                         request: { _ in SwitchRequest(epoch: 101, accountID: "nobody") },
                         accounts: { spentFleet }, homeOnDisk: { _, _ in true },
                         loaded: { switchFleetReading(spentFleet) },
                         quarantineIn: switchQuarantineDir)
        return state.waiting?.badge == switchWaitBadge(.unlisted, staying: sibling.label)?.badge
    }())

    // MARK: - 32d. The reading behind all of it

    let snapshot = Snapshot(version: 2, generatedAt: droughtNow, accounts: [spentNow, sibling])
    func watched(_ current: Snapshot.Account = spentNow, pinned: String? = nil,
                 accounts: [Snapshot.Account]? = nil,
                 problem: String? = nil, at moment: Date = droughtNow,
                 into watch: DroughtWatch = DroughtWatch()) -> DroughtWatch {
        var watch = watch
        watch.observe(provider: "claude", account: current, primaryModel: "fable", pinned: pinned,
                      loaded: (accounts.map { Snapshot(version: 2, generatedAt: droughtNow,
                                                       accounts: $0) } ?? snapshot, problem),
                      now: moment)
        return watch
    }

    let readSpent = watched(pinned: "D")
    check("a spent account is read as spent, off the live snapshot rather than the launch's copy",
          readSpent.spent)
    check("…and a pin naming that account yields, which is the release",
          readSpent.pinnedSpent
              && pinYieldsToSpentAccount(appMode: "auto", pinnedSpent: readSpent.pinnedSpent))
    check("…with the window that binds it named for the audit line",
          readSpent.window == "fable" && readSpent.remaining == 0)
    check("…and whether there is anywhere to move to at all", readSpent.hasTarget)
    check("an account with something left releases nothing",
          !watched(comfortable, accounts: [comfortable, sibling]).spent)
    // A snapshot that cannot answer is not evidence that a pin should be released: too old to
    // trust, unreadable, or simply not naming this account are the same answer.
    check("a snapshot too stale to trust releases nothing",
          !watched(problem: "snapshot is 9m old").spent)
    check("nor one that does not name this account", !watched(accounts: [sibling]).spent)
    check("and nowhere comfortable to go is read as such",
          !watched(accounts: [spentNow, droughtAccount("S", model: 1)]).hasTarget)

    // THE TWO ROWS, and the moment they come apart: a mover has carried the session onto S while
    // the pin still names the empty D. One reading, two answers, and neither may be the other.
    let carried = watched(sibling, pinned: "D", accounts: [spentNow, sibling])
    check("a session carried onto a healthy account is not itself in a drought", !carried.spent)
    check("…while the pin standing over it still names an empty one, so the release holds",
          carried.pinnedSpent)
    check("…and the two accounts are remembered apart rather than assumed equal",
          carried.accountID == "S" && carried.pinnedID == "D")
    check("nothing pinned releases nothing, because there is nothing to release",
          !watched(spentNow, pinned: nil).pinnedSpent)
    check("a pin naming an account this fleet no longer has releases nothing either",
          !watched(spentNow, pinned: "gone").pinnedSpent)
    check("nor does a snapshot too stale to trust, which is the rule the reading above follows",
          !watched(spentNow, pinned: "D", problem: "snapshot is 9m old").pinnedSpent)

    // The reading is taken at most once an interval, because the movers refuse a pinned session
    // before they read the snapshot at all and that early refusal is what keeps a 2s poll free.
    var counted = 0
    func countingSnapshot() -> (Snapshot?, String?) {
        counted += 1
        return (snapshot, nil)
    }
    var throttled = DroughtWatch()
    throttled.observe(provider: "claude", account: spentNow, primaryModel: "fable", pinned: "D",
                      loaded: countingSnapshot(), now: droughtNow)
    throttled.observe(provider: "claude", account: spentNow, primaryModel: "fable", pinned: "D",
                      loaded: countingSnapshot(),
                      now: droughtNow.addingTimeInterval(droughtWatchInterval - 1))
    check("a second tick inside the interval reads nothing at all", counted == 1)
    throttled.observe(provider: "claude", account: spentNow, primaryModel: "fable", pinned: "D",
                      loaded: countingSnapshot(),
                      now: droughtNow.addingTimeInterval(droughtWatchInterval))
    check("and the interval is inclusive, like every other in this repo", counted == 2)
    // A session that has just MOVED reads immediately: what the interval bounds is how often ONE
    // PAIR of accounts is re-read, and the account under this session is not the one the reading
    // was about.
    throttled.observe(provider: "claude", account: sibling, primaryModel: "fable", pinned: "D",
                      loaded: countingSnapshot(),
                      now: droughtNow.addingTimeInterval(droughtWatchInterval + 1))
    check("a handoff is read on the spot rather than waiting out the interval", counted == 3)
    // THE PAIR OF ASSERTIONS THIS BLOCK USED TO GET WRONG. It said "the account it moved to is not
    // spent, so the release lapses with it" - each half true, and together they wrote the restart
    // loop down as the intended behaviour: the check one section up says the pin switch stands
    // down while the release stands, and this one said the release stops standing the moment a
    // mover acts. The contract now: the move ends the DROUGHT this session is in, and changes
    // nothing about the pin standing over it.
    check("…and the account it moved to is not in a drought, so no line is owed there",
          !throttled.spent)
    check("…while the release stays keyed on the account the PIN names, which is still empty",
          throttled.pinnedSpent)
    // The other half of the key: moving the PIN moves the row the release is read from, so it is
    // read on the spot too, one second into an interval that has just been paid for.
    throttled.observe(provider: "claude", account: sibling, primaryModel: "fable", pinned: "S",
                      loaded: countingSnapshot(),
                      now: droughtNow.addingTimeInterval(droughtWatchInterval + 2))
    check("a pin moved to another account is read on the spot as well", counted == 4)
    check("…and a pin that now names the healthy account releases nothing", !throttled.pinnedSpent)

    // MARK: - 32e. The line a blocked drought leaves

    check("nothing is written while the account still has something in it", {
        var watch = watched(comfortable, accounts: [comfortable, sibling])
        return watch.audit(account: "Claude 4", sessionID: "abcdefgh1234", pid: "77", cwd: "/w",
                           blockers: { ["mode-manual"] }, now: droughtNow) == nil
    }())
    check("nor when nothing is refusing: that drought is about to end and the move writes its own", {
        var watch = watched()
        return watch.audit(account: "Claude 4", sessionID: "abcdefgh1234", pid: "77", cwd: "/w",
                           blockers: { [] }, now: droughtNow) == nil
    }())
    var blocked = watched()
    let first = blocked.audit(account: "Claude 2", sessionID: "a97d08561234", pid: "34133",
                              cwd: "/Users/x/work/my project",
                              burstAt: droughtNow.addingTimeInterval(-671.4),
                              blockers: { ["mode-manual", "agents-working"] }, now: droughtNow)
    check("a spent account nothing can move off leaves one line", first != nil)
    check("naming the session, the supervisor and what kind of record it is",
          first?.contains("session=a97d0856 pid=34133 drought=blocked") == true)
    check("…the account and the window that is the wall, at the reading the gates weigh",
          first?.contains("account=Claude 2 window=fable remaining=0%") == true)
    check("…what refused, in the order the gates bite",
          first?.contains("movers-blocked=mode-manual,agents-working") == true)
    // HOW OLD THE DRAFT EVIDENCE WAS (2026-09-02), which is the one blocker this line used to name
    // without being able to explain: `draft-suspected` on a keyboard nobody has touched for eleven
    // minutes and `draft-suspected` on somebody mid-sentence are the same word and different
    // situations, and reconstructing which one it was cost an inference from the ABSENCE of
    // `session-busy` in the same field.
    check("…how old the draft evidence was, in whole seconds and beside what it explains",
          first?.contains("movers-blocked=mode-manual,agents-working burst-age=671 ") == true)
    check("…and the one field that can contain a space, last",
          first?.hasSuffix("cwd=/Users/x/work/my project\n") == true)
    // A TERMINAL WITH NO BURST ON IT SAYS SO rather than reporting an age nobody measured, which is
    // the shape a session nobody has typed in has: `unknown` is already spoken for by a reading
    // that failed, and this is a reading that succeeded and found nothing.
    var unstamped = watched()
    check("a terminal carrying no burst at all says none rather than a number",
          unstamped.audit(account: "Claude 2", sessionID: "a97d08561234", pid: "34133", cwd: "/w",
                          blockers: { ["no-target"] }, now: droughtNow)?
              .contains("movers-blocked=no-target burst-age=none cwd=/w\n") == true)
    check("and it is once per drought, however long the drought lasts",
          blocked.audit(account: "Claude 2", sessionID: "a97d08561234", pid: "34133", cwd: "/w",
                        blockers: { ["mode-manual"] },
                        now: droughtNow.addingTimeInterval(3600)) == nil)
    // A reported reset time drifts by a minute between polls without the window having moved
    // (Rebalance.swift), so the same drought is matched by nearness rather than by equality.
    var drifted = watched(at: droughtNow.addingTimeInterval(droughtWatchInterval), into: blocked)
    check("a reset time that drifted a minute is still the drought already written down",
          drifted.audit(account: "Claude 2", sessionID: "a97d08561234", pid: "34133", cwd: "/w",
                        blockers: { ["mode-manual"] },
                        now: droughtNow.addingTimeInterval(60)) == nil)
    // …and the account moving IS a new drought, because everything the last one recorded was about
    // an account this session has left.
    var moved = DroughtWatch()
    moved.observe(provider: "claude", account: spentNow, primaryModel: "fable",
                  loaded: (snapshot, nil), now: droughtNow)
    _ = moved.audit(account: "Claude 2", sessionID: "a97d08561234", pid: "34133", cwd: "/w",
                    blockers: { ["mode-manual"] }, now: droughtNow)
    let elsewhere = droughtAccount("E", model: 0, label: "Claude 5")
    moved.observe(provider: "claude", account: elsewhere, primaryModel: "fable",
                  loaded: (Snapshot(version: 2, generatedAt: droughtNow,
                                    accounts: [elsewhere, sibling]), nil),
                  now: droughtNow.addingTimeInterval(1))
    check("a different account is a different drought and is written down again",
          moved.audit(account: "Claude 5", sessionID: "a97d08561234", pid: "34133", cwd: "/w",
                      blockers: { ["agents-working"] },
                      now: droughtNow.addingTimeInterval(2)) != nil)

    // MARK: - 32f. What the blockers are named after

    check("nothing refusing is named as nothing",
          droughtBlockers(steering: true, mode: "auto", blocked: false, agentsWorking: false,
                          isQuiet: true, draftSuspected: false, carryable: true, fuseAllows: true,
                          hasTarget: true).isEmpty)
    check("and every gate the movers hold has a name, in the order they bite",
          droughtBlockers(steering: false, mode: "manual", blocked: true, agentsWorking: true,
                          isQuiet: false, draftSuspected: true, carryable: false, fuseAllows: false,
                          hasTarget: false)
              == ["steering-off", "mode-manual", "waiting-on-person", "agents-working",
                  "session-busy", "draft-suspected", "not-carryable", "fuse-spent", "no-target"])
    // The incident's own reading: a pin the release does not reach (the app's), and a fan-out the
    // turn-boundary mover was waiting on.
    check("the incident's own shape is two names",
          droughtBlockers(steering: true, mode: "manual", blocked: false, agentsWorking: true,
                          isQuiet: true, draftSuspected: false, carryable: true, fuseAllows: true,
                          hasTarget: true) == ["mode-manual", "agents-working"])

    // MARK: - 32g. The station, end to end

    let auditLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-drought-audit-\(UUID().uuidString).log")
    var station = watched()
    applyDroughtAudit(&station, relaunchPlanned: false, account: "Claude 2",
                      sessionID: "a97d08561234", pid: "34133", cwd: "/w", steering: true,
                      mode: "manual", blocked: false, agentsWorking: true, isQuiet: true,
                      draftSuspected: false, burstAt: droughtNow.addingTimeInterval(-90),
                      carryable: true, fuseAllows: true, now: droughtNow,
                      log: auditLog)
    let written = (try? String(contentsOf: auditLog, encoding: .utf8)) ?? ""
    check("the station writes the line the watch decided",
          written.contains("drought=blocked") && written.contains("mode-manual,agents-working"))
    check("…carrying the burst it was handed, aged against the clock the line is dated by",
          written.contains("burst-age=90 cwd=/w"))
    // A tick that IS moving the session records the move itself, in the same file, one line down.
    var moving = watched()
    let quietLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-drought-quiet-\(UUID().uuidString).log")
    applyDroughtAudit(&moving, relaunchPlanned: true, account: "Claude 2",
                      sessionID: "a97d08561234", pid: "34133", cwd: "/w", steering: true,
                      mode: "auto", blocked: false, agentsWorking: false, isQuiet: true,
                      draftSuspected: false, burstAt: nil, carryable: true, fuseAllows: true,
                      now: droughtNow, log: quietLog)
    check("and a tick that is moving the session writes nothing",
          !FileManager.default.fileExists(atPath: quietLog.path))
    try? FileManager.default.removeItem(at: auditLog)
    try? FileManager.default.removeItem(at: quietLog)

    // MARK: - 32h. The restart loop this keying exists to prevent

    // THE INCIDENT'S SIBLING CASE, RUN FORWARD. A project profile pins D, D is empty, and a
    // preventive mover has carried the session to healthy S. From that instant the release and the
    // audit are about different rows. Keyed on the row under the session, the release lapses on the
    // very next reading, the pin switch drags the session back into the same wall, the release
    // stands again, a mover carries it off again - three times, and then the RecoveryFuse is empty.
    // That fuse is SHARED with the cap handoff (`applyCapHandoff(fuseAllows:)`), so for the rest of
    // that ten minute window the one mechanism that worked before this feature existed is refused
    // too, on a machine where three repos pin an account.
    //
    // Ten ticks rather than one, because one tick cannot tell a release that holds from a release
    // that happens to be true at the moment it is asked.
    var loopWatch = DroughtWatch()
    var loopProject = ProjectPolicy()
    loopProject.accountID = "D"
    let loopFleet = effectivePolicy(appAuto, project: loopProject)
    let emptyPin: [Snapshot.Account] = [spentNow, sibling]
    let refilledPin: [Snapshot.Account] = [comfortable, sibling]
    var draggedBack = 0
    var released = 0
    for step in 0 ..< 10 {
        let elapsed: TimeInterval = Double(step) * droughtWatchInterval
        let moment: Date = droughtNow.addingTimeInterval(elapsed)
        let reading: (Snapshot?, String?)
            = (Snapshot(version: 2, generatedAt: moment, accounts: emptyPin), nil)
        loopWatch.observe(provider: "claude", account: sibling, primaryModel: "fable", pinned: "D",
                          loaded: reading, now: moment)
        let yields: Bool = pinYieldsToSpentAccount(appMode: appAuto.mode,
                                                   pinnedSpent: loopWatch.pinnedSpent)
        if yields { released += 1 }
        let dragged: RelaunchPlan? = pinSwitchPlan(pinReleasedPolicy(loopFleet, yielding: yields),
                                                   fleet: emptyPin)
        if dragged != nil { draggedBack += 1 }
    }
    check("ten ticks on the account a mover carried it to, and the pin drags it back on none",
          draggedBack == 0)
    check("…because the release stands on every one of them rather than only the first",
          released == 10)
    // AND THE WAY OUT, which is what makes this a release rather than a divorce: the pin is a
    // standing instruction, and it takes the session home the moment its account has something in
    // it again. Nothing expires and nothing is remembered - the next reading simply says so.
    let refilledReading: (Snapshot?, String?)
        = (Snapshot(version: 2, generatedAt: droughtNow, accounts: refilledPin), nil)
    loopWatch.observe(provider: "claude", account: sibling, primaryModel: "fable", pinned: "D",
                      loaded: refilledReading,
                      now: droughtNow.addingTimeInterval(10 * droughtWatchInterval))
    let refilled: Bool = pinYieldsToSpentAccount(appMode: appAuto.mode,
                                                 pinnedSpent: loopWatch.pinnedSpent)
    check("and when that account refills the release lapses on its own",
          !loopWatch.pinnedSpent && !refilled)
    check("…which is the standing instruction taking the session home again",
          pinSwitchPlan(pinReleasedPolicy(loopFleet, yielding: refilled),
                        fleet: refilledPin)?.target.id == "D")
}
