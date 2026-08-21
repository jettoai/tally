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
          !pinYieldsToSpentAccount(appMode: "auto", spent: false))
    check("a pin over one with nothing left yields",
          pinYieldsToSpentAccount(appMode: "auto", spent: true))
    check("but the APP's own pin never does: that mode is the fleet saying Tally never re-picks",
          !pinYieldsToSpentAccount(appMode: "manual", spent: true))
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
    func policies(app: LaunchPolicy, projectAccount: String?, sessionPin: String?,
                  spent: Bool) -> (moving: LaunchPolicy, session: LaunchPolicy) {
        var project = ProjectPolicy()
        project.accountID = projectAccount
        let yields = pinYieldsToSpentAccount(appMode: app.mode, spent: spent)
        let moving = pinReleasedPolicy(effectivePolicy(app, project: project), yielding: yields)
        return (moving, pinReleasedPolicy(sessionPolicy(moving, sessionPin: sessionPin),
                                          yielding: yields))
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
        let spent = state == "spent"

        // A SESSION PIN (`tally account`), the incident's own case.
        let session = policies(app: appAuto, projectAccount: nil, sessionPin: "D", spent: spent)
        check("a session pin on a \(state) account moves \(spent ? "" : "no")where",
              moves(session.session, current: current) == spent)
        check("…and a cap on it hands the session on either way",
              capMoves(session.moving, sessionPin: "D") == .handoff)

        // A PROJECT PROFILE (`tally project set --account`), which three repos on this machine set.
        let project = policies(app: appAuto, projectAccount: "D", sessionPin: nil, spent: spent)
        check("a project pin on a \(state) account moves \(spent ? "" : "no")where",
              moves(project.session, current: current) == spent)
        check("…and its cap \(spent ? "hands the session on" : "waits, as pinning means")",
              capMoves(project.moving, sessionPin: nil) == (spent ? .handoff : .waitPinned))

        // THE APP'S OWN PIN, untouched by any of this: one scope above a single session.
        let fleet = policies(app: appPinned, projectAccount: nil, sessionPin: nil, spent: spent)
        check("the fleet's own pin holds a \(state) account", !moves(fleet.session, current: current))
        check("…and its cap waits, whatever the numbers say",
              capMoves(fleet.moving, sessionPin: nil) == .waitPinned)
    }

    // The two cells the composition above exists to keep honest, stated on their own.
    check("the release reaches a pin folded in AFTER it, which is where a session pin arrives",
          policies(app: appAuto, projectAccount: nil, sessionPin: "D", spent: true).session.mode
              == "auto")
    check("and a session pin over the APP's pin is not released either: that scope is never",
          policies(app: appPinned, projectAccount: nil, sessionPin: "D", spent: true).session.mode
              == "manual")

    // MARK: - 32c. The pin switch stands down with the movers

    // THE HALF THAT WOULD MAKE THIS A RESTART LOOP RATHER THAN A FIX. `applyPinSwitch` drags a
    // running session onto the pinned account whenever the two disagree, asking only whether that
    // account is launchable and never whether it has quota (SessionSwitch.swift). Released, it has
    // to stand down: otherwise the mover carries the session off the spent account and the very next
    // quiet tick carries it back, once per cycle, for as long as the drought lasts.
    let switchDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-drought-\(UUID().uuidString)")
    let pinnedAccounts = [switchAccount("D", label: "Claude 4"), switchAccount("S", label: "Claude 3")]
    func pinSwitchPlan(_ policy: LaunchPolicy) -> RelaunchPlan? {
        var watcher = idleWatcher("drought")
        var plan: RelaunchPlan?
        var state = ManualMoveState(sessionKey: "9191", servedEpoch: 100, dir: switchDir)
        var record: PendingSwitchConsumption?
        var under = policy
        applyManualMoves(plan: &plan, state: &state, record: &record, policy: &under,
                         account: pinnedAccounts[1], providerID: "claude", watcher: &watcher,
                         childAge: 9999, keyboardIdle: { _ in true }, dir: switchDir,
                         request: { _ in nil }, accounts: { pinnedAccounts })
        return plan
    }
    check("a pin the session is off drags it back while the account has something left",
          pinSwitchPlan(policies(app: appAuto, projectAccount: "D", sessionPin: nil,
                                 spent: false).moving)?.target.id == "D")
    check("…and stands down once that account has nothing left",
          pinSwitchPlan(policies(app: appAuto, projectAccount: "D", sessionPin: nil,
                                 spent: true).moving) == nil)
    check("the app's own pin drags it back either way, which is what that scope means",
          pinSwitchPlan(policies(app: appPinned, projectAccount: nil, sessionPin: nil,
                                 spent: true).moving)?.target.id == "D")

    // MARK: - 32d. The reading behind all of it

    let snapshot = Snapshot(version: 2, generatedAt: droughtNow, accounts: [spentNow, sibling])
    func watched(_ current: Snapshot.Account = spentNow, accounts: [Snapshot.Account]? = nil,
                 problem: String? = nil, at moment: Date = droughtNow,
                 into watch: DroughtWatch = DroughtWatch()) -> DroughtWatch {
        var watch = watch
        watch.observe(provider: "claude", account: current, primaryModel: "fable",
                      loaded: (accounts.map { Snapshot(version: 2, generatedAt: droughtNow,
                                                       accounts: $0) } ?? snapshot, problem),
                      now: moment)
        return watch
    }

    let readSpent = watched()
    check("a spent account is read as spent, off the live snapshot rather than the launch's copy",
          readSpent.spent && pinYieldsToSpentAccount(appMode: "auto", spent: readSpent.spent))
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

    // The reading is taken at most once an interval, because the movers refuse a pinned session
    // before they read the snapshot at all and that early refusal is what keeps a 2s poll free.
    var counted = 0
    func countingSnapshot() -> (Snapshot?, String?) {
        counted += 1
        return (snapshot, nil)
    }
    var throttled = DroughtWatch()
    throttled.observe(provider: "claude", account: spentNow, primaryModel: "fable",
                      loaded: countingSnapshot(), now: droughtNow)
    throttled.observe(provider: "claude", account: spentNow, primaryModel: "fable",
                      loaded: countingSnapshot(),
                      now: droughtNow.addingTimeInterval(droughtWatchInterval - 1))
    check("a second tick inside the interval reads nothing at all", counted == 1)
    throttled.observe(provider: "claude", account: spentNow, primaryModel: "fable",
                      loaded: countingSnapshot(),
                      now: droughtNow.addingTimeInterval(droughtWatchInterval))
    check("and the interval is inclusive, like every other in this repo", counted == 2)
    // A session that has just MOVED reads immediately: what the interval bounds is how often ONE
    // account is re-read, and the account under this session is not the one the reading was about.
    throttled.observe(provider: "claude", account: sibling, primaryModel: "fable",
                      loaded: countingSnapshot(),
                      now: droughtNow.addingTimeInterval(droughtWatchInterval + 1))
    check("a handoff is read on the spot rather than waiting out the interval", counted == 3)
    check("…and the account it moved to is not spent, so the release lapses with it",
          !throttled.spent)

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
                              blockers: { ["mode-manual", "agents-working"] }, now: droughtNow)
    check("a spent account nothing can move off leaves one line", first != nil)
    check("naming the session, the supervisor and what kind of record it is",
          first?.contains("session=a97d0856 pid=34133 drought=blocked") == true)
    check("…the account and the window that is the wall, at the reading the gates weigh",
          first?.contains("account=Claude 2 window=fable remaining=0%") == true)
    check("…what refused, in the order the gates bite",
          first?.contains("movers-blocked=mode-manual,agents-working") == true)
    check("…and the one field that can contain a space, last",
          first?.hasSuffix("cwd=/Users/x/work/my project\n") == true)
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
                      draftSuspected: false, carryable: true, fuseAllows: true, now: droughtNow,
                      log: auditLog)
    let written = (try? String(contentsOf: auditLog, encoding: .utf8)) ?? ""
    check("the station writes the line the watch decided",
          written.contains("drought=blocked") && written.contains("mode-manual,agents-working"))
    // A tick that IS moving the session records the move itself, in the same file, one line down.
    var moving = watched()
    let quietLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-drought-quiet-\(UUID().uuidString).log")
    applyDroughtAudit(&moving, relaunchPlanned: true, account: "Claude 2",
                      sessionID: "a97d08561234", pid: "34133", cwd: "/w", steering: true,
                      mode: "auto", blocked: false, agentsWorking: false, isQuiet: true,
                      draftSuspected: false, carryable: true, fuseAllows: true, now: droughtNow,
                      log: quietLog)
    check("and a tick that is moving the session writes nothing",
          !FileManager.default.fileExists(atPath: quietLog.path))
    try? FileManager.default.removeItem(at: auditLog)
    try? FileManager.default.removeItem(at: quietLog)
}
