import Darwin
import Foundation

/// Only a value actually passed to this child, never a profile or a configuration-home guess.
func codexLaunchEffort(_ args: [String]) -> String? {
    let value = codexTypedConfigOverrides(optionsOnly(args))
        .last(where: { $0.key == "model_reasoning_effort" })?.value
    return value.flatMap { $0.isEmpty ? nil : $0 }
}

/// Refuse an automatic second writer while a monitored Codex generation owns the conversation.
func liveCodexConversations(dir: URL = supervisorStateDir) -> Set<String> {
    Set(liveCodexConversationOwners(dir: dir).map(\.thread))
}

nonisolated(unsafe) private var codexSupervisorSignal: Int32 = 0

/// Carries out a launch `resolveLaunch` decided (LaunchDecision.swift): the handoff supervisor, the
/// Codex monitor, or a plain exec in the environment the decision names.
func executeLaunch(_ provider: Provider, decision: LaunchDecision, account: Snapshot.Account,
                   args: [String], clearedConversation: String?) -> Never {
    let home = account.launchHome!
    switch decision.supervision {
    case .handoff:
        runSupervised(provider, account: account, args: args, follow: decision.follow,
                      clearedConversation: clearedConversation, spendReserve: decision.spendReserve)
    case .monitor:
        runCodexSupervised(provider, account: account, args: args, spendReserve: decision.spendReserve)
    case .none:
        launchProvider(provider, args: args, home: home,
                       env: decision.childEnv == .inherit ? nil : launchEnv(provider, home: home))
    }
}

/// A supervised Codex resident with an owned PTY for guarded direct input.
/// No recovery policy runs here: the child exits once and its exit status is preserved. The one
/// exception is a `tally session clear` that reopens the window, which execs `tally <provider>`.
/// `spendReserve` is the launch's own `--spend-reserve`, carried into a reopen as Codex.
func runCodexSupervised(_ provider: Provider, account: Snapshot.Account, args: [String],
                        spendReserve: Bool = false) -> Never {
    guard let home = account.launchHome else { exit(1) }
    let pid = String(getpid())
    let launchedAt = Date()
    // The automatic hand-offs this window's earlier images made (CodexWall.swift), carried across the exec
    // in the environment and removed here so the Codex child never inherits it.
    var autoFuse = RecoveryFuse(max: codexWallMaxMoves, window: capResumeBudgetWindow,
        recovered: getenv(codexWallFuseEnv).map { decodeRecoveryFuse(String(cString: $0)) } ?? [])
    unsetenv(codexWallFuseEnv)
    var wall = CodexWallWatch()
    var input = SessionInputState(sessionKey: pid)
    // The line a wall move queued for this window, queued here AFTER the state above seeded its served
    // epoch (which would otherwise count it as already served), and removed before the child's environment.
    if let line = codexWallCarriedResume(getenv(codexWallResumeEnv).map { String(cString: $0) }) {
        let queued = (try? writeSessionInputRequest(SessionInputRequest(
            epoch: Int(Date().timeIntervalSince1970 * 1000), text: line), sessionKey: pid)) != nil
        appendSessionInputLine(codexWallAuditLine(pid: pid, result: queued ? "resume-queued" : "resume-failed", move: nil),
                               to: sessionInputLog)
    }
    unsetenv(codexWallResumeEnv)
    var keyboard = KeyboardActivity()
    guard let generation = SessionMonitoring.generation(getpid()) else {
        exec(provider.cli, args: args, env: launchEnv(provider, home: home))
    }
    let version = supervisorBuildVersion()
    var metadata = SessionMonitoring(provider: "codex", supervisorPID: getpid(),
                                     supervisorStart: generation, nonce: UUID().uuidString, home: home)
    let cwd = realpathString(FileManager.default.currentDirectoryPath)
    sweepDeadSupervisorState()
    clearCodexSupervisorState(pid: pid, dir: supervisorStateDir)
    do { try metadata.write(dir: supervisorStateDir) } catch {
        warn("session monitoring could not register; launching without monitoring")
        exec(provider.cli, args: args, env: launchEnv(provider, home: home))
    }
    var environment = supervisedChildEnvironment(provider: provider, home: home,
        supervisorVersion: version, supervisorPID: pid, supervisorStartedAt: String(generation))
    environment["TALLY_CODEX_LAUNCH_NONCE"] = metadata.nonce
    // Inherited Claude markers belong to the outer CLI, not this Codex session.
    environment.removeValue(forKey: "CLAUDECODE")
    environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)
    signal(SIGTERM) { codexSupervisorSignal = $0 }
    signal(SIGHUP) { codexSupervisorSignal = $0 }
    var terminal = CodexInputRelay()
    let initializedArgs = terminal != nil && CodexSessionHooks.installed(home: home,
        root: supervisorStateDir.deletingLastPathComponent()) ? codexResumeInitializationArgs(args) : args
    if initializedArgs != args {
        warn("Initializing resumed Codex for direct send with one native turn (uses subscription quota). No automatic retry.")
    }
    let relayedChild = terminal?.spawn([provider.cli] + initializedArgs, environment: environment)
    if relayedChild == nil { terminal?.close(); terminal = nil }
    var initializationDraft = initializedArgs != args && relayedChild != nil ? CodexResumeDraftGuard() : nil
    guard let child = relayedChild ?? spawnChild([provider.cli] + args, environment: environment) else {
        clearCodexSupervisorState(pid: pid, dir: supervisorStateDir)
        warn("could not launch Codex")
        exit(127)
    }
    var reaper = ChildReaper(pid: child)
    metadata.childPID = child
    metadata.childStart = SessionMonitoring.generation(child)
    if metadata.childStart != nil, (try? metadata.write(dir: supervisorStateDir)) != nil {
        writeSupervisorCwd(cwd, pid: pid)
        writeSupervisorAccount(account.id, pid: pid)
        writeSupervisorChild(child, pid: pid)
        // Publish last. Readers of a malformed/missing metadata file refuse Claude controls.
        try? (SessionMonitoring.presencePrefix + String(generation)).write(
            to: supervisorStateDir.appendingPathComponent(pid), atomically: true, encoding: .utf8)
    }
    var writer = SessionStateWriter()
    var contextWriter = CodexSessionContextWriter()
    let launchModel = launchPrimaryModel(args, providerID: "codex")
    let launchEffort = codexLaunchEffort(args)
    var observer: CodexSessionObserver?
    var codexWaits = CodexWaitTracker(identity: SessionWaitIdentity(key: "codex:\(pid):\(generation)",
        supervisorPid: Int(getpid()), supervisorStartedAt: Int(generation), childPid: Int(child), transcriptSessionId: nil,
        launchNonce: metadata.nonce, account: account.id, directory: cwd, project: nil, worktree: nil))
    var identity = SessionIdentity(accountID: account.id, directory: cwd,
                                   project: URL(fileURLWithPath: cwd).lastPathComponent,
                                   model: launchModel,
                                   childPid: Int(child), supervisorVersion: version)
    var nextTick = Date.distantPast
    /// Throttles the detached delivery spawn to once per 10s, as the Claude loop does.
    var lastDeliverySpawn: Date?
    // The station that reopens the app when a silent update took it away and never brought it back
    // (AppRelaunch.swift), which until 2026-09-22 only ran in `tally claude` sessions. An automatic
    // install lands when the machine has been idle for five minutes, which is precisely when the
    // terminal nobody is at may be running Codex rather than Claude: who is watching and when the
    // update happens are negatively correlated, so a supervisor that does not watch is half the
    // machine's cover gone. Nothing here has to cede to a self-update the way the other loop does,
    // because this one has no self-update station: it never replaces its own process image.
    var appRelaunch = AppRelaunchState()
    var nextAppRelaunchTick = Date.distantPast
    /// Set when a `tally session clear` chose to reopen this window as a provider (ProviderReopen.swift).
    /// The child is sent TERM and the loop keeps pumping until it exits: a Codex child writes its
    /// terminal restore on the way out, and a supervisor blocked in waitpid instead of reading the
    /// PTY leaves it stuck exiting. KILL follows if it is still there after the grace.
    var reopenAs: String?
    var reopenKillAt: Date?
    /// A `tally account <codex account> --session <this pid>` request that was accepted and waits for
    /// a turn boundary (CodexHandoff.swift). `handoffTo` is set once the child was sent TERM for it;
    /// the exec follows the loop, as a reopen's does. A clear and a hand-off are mutually exclusive.
    var handoff: CodexHandoffPlan?
    var handoffTo: CodexHandoffPlan?
    var handoffHeld: String?
    /// What this tick publishes about a launch stuck before its prompt (CodexStartupScreen.swift).
    var screenRecord: CodexStartupScreenRecord?
    while reaper.isRunning {
        if let terminal, !terminal.pump(timeout: 0.02) {
            if metadata.childStart == SessionMonitoring.generation(child) { kill(child, SIGHUP) }
            break
        }
        reaper.poll()
        if !reaper.isRunning { break }
        if let killAt = reopenKillAt, Date() >= killAt {
            if metadata.childStart == SessionMonitoring.generation(child) { kill(child, SIGKILL) }
            reopenKillAt = nil
        }
        if codexSupervisorSignal != 0 {
            if metadata.childStart == SessionMonitoring.generation(child) { kill(child, codexSupervisorSignal) }
            break
        }
        guard Date() >= nextTick else { continue }
        nextTick = Date().addingTimeInterval(0.25)
        autoreleasepool {
            // Every two seconds rather than on this loop's own quarter-second tick, which is the
            // interval the station's readings are written for: it re-reads the bundle's Info.plist
            // and walks the process table, and the app's absence is a state that lasts.
            if Date() >= nextAppRelaunchTick {
                nextAppRelaunchTick = Date().addingTimeInterval(2)
                applyAppRelaunch(&appRelaunch)
            }
            if observer == nil,
               let data = try? Data(contentsOf: supervisorStateDir.appendingPathComponent(pid + ".codex-binding")),
               let binding = try? JSONDecoder().decode(CodexSessionBinding.self, from: data),
               binding.nonce == metadata.nonce {
                observer = CodexSessionObserver(binding: binding, launchedAt: launchedAt)
                if let directory = binding.directory {
                    let git = gitSessionDirectoryIdentity(directory)
                    let project = pickProject(cwd: directory, mainRepo: git.mainRepo, checkout: git.checkout)
                    identity.directory = project.path
                    identity.project = project.name
                    identity.worktree = project.worktree
                    writeSupervisorCwd(directory, pid: pid)
                }
            }
            keyboard.observe(stamp: terminal?.lastHumanInputAt ?? launchedAt)
            let activity = (try? Data(contentsOf: supervisorStateDir.appendingPathComponent(pid + ".codex-activity")))
                .flatMap { try? JSONDecoder().decode(CodexSessionActivity.self, from: $0) }
            observer?.poll(home: home, activity: activity)
            let stall = terminal.flatMap { codexStartupStall(screen: $0.startupScreen, launchedAt: launchedAt,
                                                             bindingLanded: observer != nil, now: Date()) }
            for event in codexWaits.reconcile(observer: observer, directory: identity.directory, project: identity.project,
                                              worktree: identity.worktree, startupScreen: stall, now: Date()) { appendSessionWaitEvent(event) }
            maybeSpawnEventDeliverer(now: Date(), last: &lastDeliverySpawn)
            screenRecord = terminal.flatMap { codexStartupScreenRecord($0.startupScreen, stall: stall) }
            handleStartupChoice(pid: pid, record: screenRecord, relay: terminal, child: child, childStart: metadata.childStart)
            initializationDraft?.observe(humanInput: terminal?.lastHumanInputAt,
                inputReceipt: observer?.lastInputReceiptAt,
                ready: observer?.canAcceptInput == true && observer?.inputReceiptsAvailable == true)
            if handoffTo == nil {
                let busy = reopenAs != nil ? "a clear is already reopening this window"
                    : handoff != nil ? "a hand-off is already queued for this window" : nil
                if let plan = serveCodexHandoff(pid: pid, busy: busy, targetHome: { id in
                    loadSnapshot().0?.accounts.first(where: { $0.id == id && $0.provider == "codex" })?.launchHome
                }, fallbackDirectory: readSupervisorCwd(pid: pid)) { handoff = plan }
                // A usage wall queues its plan in the same `handoff`: the one gate, kill and exec below.
                if reopenAs == nil, observer != nil, handoff == nil || handoff?.wall != nil {
                    let verdict = codexWallPlan(watch: &wall, reading: observer?.rateReading, accountID: account.id,
                        pid: pid, fuse: &autoFuse, reserves: accountReserves(),
                        fallbackDirectory: readSupervisorCwd(pid: pid),
                        readSnapshot: { let (snapshot, problem) = loadSnapshot(); return problem == nil ? snapshot : nil })
                    if handoff == nil, let plan = verdict.plan {
                        handoff = plan
                    } else if handoff?.wall != nil, !verdict.wall {
                        handoff = nil
                        appendSessionInputLine(codexWallAuditLine(pid: pid, result: "dropped", move: nil,
                                                                  held: "wall-cleared"), to: sessionInputLog)
                    }
                    if let held = verdict.held, held != handoffHeld {
                        handoffHeld = held
                        appendSessionInputLine(codexWallAuditLine(pid: pid, result: "held", move: nil, held: held),
                                               to: sessionInputLog)
                    }
                }
                if let plan = handoff, metadata.childStart == SessionMonitoring.generation(child) {
                    let held = codexHandoffGate(
                        turnEnded: observer?.canAcceptInput == true,
                        permissionPending: observer?.pendingPermission != nil,
                        questionPending: observer?.pendingQuestion != nil,
                        draftSuspected: initializationDraft?.suspected == true || codexInputDraftSuspected(
                            lastInput: keyboard.lastStamp, userTurnAt: observer?.lastUserTurnAt, launchedAt: launchedAt),
                        keyboardIdle: keyboard.lastStamp != nil && keyboard.idle(manualMoveIdleSeconds),
                        inputPending: terminal?.inputPending == true,
                        inputQueued: readSessionInputRequest(sessionKey: pid) != nil)
                    if let held {
                        if held != handoffHeld {
                            handoffHeld = held
                            appendSessionInputLine("\(ISO8601DateFormatter().string(from: Date())) pid=\(pid) "
                                + "input=codex-handoff result=held reason=\(held)\n", to: sessionInputLog)
                        }
                    } else if case .ready(let thread, _) = codexHandoffSource(
                        pid: pid, targetHome: plan.targetHome, fallbackDirectory: readSupervisorCwd(pid: pid)),
                        thread == plan.threadID {
                        kill(child, SIGTERM)
                        handoffTo = plan
                        if var move = plan.wall {
                            autoFuse.record()
                            move.resumeLine = codexWallResumeLine(move, turnFailed: observer?.lastTurnFailed == true)
                            handoffTo?.wall = move
                        }
                        reopenKillAt = Date().addingTimeInterval(handoffKillGrace)
                    } else {
                        // The window moved to another conversation while the request waited: carrying
                        // the old one over would not be what was asked.
                        handoff = nil
                        appendSessionInputLine("\(ISO8601DateFormatter().string(from: Date())) pid=\(pid) "
                            + "input=codex-handoff result=dropped reason=conversation-changed\n", to: sessionInputLog)
                    }
                }
            }
            contextWriter.sync(accountID: account.id, launchModel: launchModel,
                               launchEffort: launchEffort, observer: observer, pid: pid)
            if let terminal, let childStart = metadata.childStart {
                let terminalReady = terminal.terminalReady(child: child, startedAt: childStart) && terminal.canSend && !terminal.inputPending
                if observer?.invalidated == true || !terminal.canSend, let previous = metadata.inputTTY {
                    metadata.inputTTY = nil
                    if (try? metadata.write(dir: supervisorStateDir)) == nil { metadata.inputTTY = previous }
                }
                if metadata.inputTTY == nil && terminalReady && observer?.canAcceptInput == true
                    && observer?.inputReceiptsAvailable == true {
                    metadata.inputTTY = terminal.path
                    if (try? metadata.write(dir: supervisorStateDir)) == nil { metadata.inputTTY = nil }
                }
                var submittedText: String?
                var submittedAt = Date()
                let action = applyCodexSessionInput(&input, observer: observer, keyboard: keyboard,
                    launchedAt: launchedAt, terminalReady: metadata.inputTTY != nil && terminalReady,
                    startupDraftSuspected: initializationDraft?.suspected == true,
                    reopen: { handoff != nil ? nil : clearReopenTarget(
                        current: "codex", cwd: identity.directory ?? cwd, spendReserve: spendReserve) },
                    inject: { text in
                        observer?.poll(home: home)
                        guard observer?.canAcceptInput == true,
                              (terminal.lastHumanInputAt ?? launchedAt) == keyboard.lastStamp,
                              !terminal.inputPending else {
                            return .held
                        }
                        // Native JSONL timestamps have millisecond precision.
                        submittedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 * 1000) / 1000)
                        let result = terminal.submit(text, child: child, startedAt: childStart,
                            shouldContinue: { codexSupervisorSignal == 0 })
                        if result == .done {
                            submittedText = text
                            observer?.inputSubmitted()
                        } else if !terminal.canSend {
                            metadata.inputTTY = nil
                            try? metadata.write(dir: supervisorStateDir)
                        }
                        return result
                    }, confirm: {
                        guard let text = submittedText else { return false }
                        let confirmed = awaitCodexInputConfirmation(poll: {
                            guard codexSupervisorSignal == 0, terminal.pump(forwardInput: false) else { return false }
                            observer?.poll(home: home)
                            return observer?.receivedInput(text, after: submittedAt) == true
                        })
                        if !confirmed {
                            terminal.disableDirectSend()
                            metadata.inputTTY = nil
                            try? metadata.write(dir: supervisorStateDir)
                        }
                        return confirmed
                    })
                if let next = action.reopenAs, metadata.childStart == SessionMonitoring.generation(child) {
                    kill(child, SIGTERM)
                    reopenAs = next
                    reopenKillAt = Date().addingTimeInterval(handoffKillGrace)
                }
            }
            identity.model = observer?.model ?? identity.model
            let state = observer?.state ?? .unknown
            writer.sync(state, reason: state == .unknown ? "Codex session status is not available." : nil,
                        startupScreen: screenRecord, identity: identity, pid: pid)
        }
        if terminal == nil { usleep(250_000) }
    }
    terminal?.drainOutput()
    terminal?.close()
    let status = reaper.wait()
    let endReason = SessionEndReason(supervisorSignal: codexSupervisorSignal, childStatus: status)
    for event in codexWaits.finish(now: Date(), reason: endReason) { appendSessionWaitEvent(event) }
    maybeSpawnEventDeliverer(now: Date(), last: &lastDeliverySpawn, force: true)
    clearCodexSupervisorState(pid: pid, dir: supervisorStateDir, keepHandoffReceipt: handoffTo != nil)
    postSessionStateChanged(pid: pid)
    if let handoffTo { execCodexHandoff(handoffTo, spendReserve: spendReserve, autoMoves: autoFuse.carried()) }
    if let reopenAs { execProviderReopen(reopenAs, current: "codex", spendReserve: spendReserve) }
    exit(supervisorExitCode(childStatus: status))
}

/// A hand-off exit keeps its receipt: the asker polls for it after this window is gone and removes it
/// itself once read (a later orphan sweep still clears one nobody read).
func clearCodexSupervisorState(pid: String, dir: URL, keepHandoffReceipt: Bool = false) {
    for suffix in [""] + supervisorStateSuffixes where !(keepHandoffReceipt && suffix == codexHandoffReceiptSuffix) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(pid + suffix))
    }
}

/// Serves one pending `tally session skip-update` request (CodexStartupChoice.swift): decided against
/// what this tick publishes, typed into this child's PTY only, receipted either way. `sent` is the
/// background update Tally runs once Skip is typed, injectable so a fixture types without spawning.
@discardableResult
func handleStartupChoice(pid: String, record: CodexStartupScreenRecord?, relay: CodexInputRelay?,
                         child: Int32, childStart: Int64?, dir: URL = supervisorStateDir, now: Date = Date(),
                         sent: () -> Void = { spawnDetachedTally(["codex-update", "--trigger", "skip"]) }) -> String? {
    let url = dir.appendingPathComponent(pid + startupChoiceSuffix)
    guard let data = try? Data(contentsOf: url) else { return nil }
    try? FileManager.default.removeItem(at: url)
    guard let request = try? startupChoiceDecoder().decode(StartupChoiceRequest.self, from: data) else { return nil }
    var decision = decideStartupChoice(request, record: record, humanInputAt: relay?.lastHumanInputAt, now: now)
    if let keys = decision.keys {
        if let relay, let childStart, relay.sendKeys(keys, child: child, startedAt: childStart) {
            if record?.title == CodexStartupScreen.updateMenuMarker { sent() }   // the announcement's answer updates nothing
        } else {
            decision.result = "write-failed"
        }
    }
    writeStartupChoiceReceipt(StartupChoiceReceipt(nonce: request.nonce, result: decision.result), pid: pid, dir: dir)
    return decision.result
}

/// Replaces this process with the launch on the target account, in the conversation's directory.
/// The old child is already gone and its state swept; on a failed exec the window has ended, so the
/// way to carry on by hand is printed (a path and an id, nothing secret).
func execCodexHandoff(_ plan: CodexHandoffPlan, spendReserve: Bool, autoMoves: [Date] = []) -> Never {
    if let binary = selfUpdateBinary() {
        if let move = plan.wall {
            warn(codexWallNotice(move))
            appendSessionInputLine(codexWallAuditLine(pid: String(getpid()), result: "moved", move: move),
                                   to: sessionInputLog)
            logHandoff(sessionID: plan.threadID, from: move.fromID, to: move.toID, reason: "cap",
                       pid: String(getpid()), cwd: plan.directory)
            if let line = move.resumeLine { setenv(codexWallResumeEnv, line, 1) }
        } else {
            warn("moving this Codex conversation to \(URL(fileURLWithPath: plan.targetHome).lastPathComponent)")
        }
        if !autoMoves.isEmpty { setenv(codexWallFuseEnv, encodeRecoveryFuse(autoMoves), 1) }
        _ = FileManager.default.changeCurrentDirectoryPath(plan.directory)
        var argv: [UnsafeMutablePointer<CChar>?] = codexHandoffArgv(
            targetHome: plan.targetHome, threadID: plan.threadID,
            spendReserve: spendReserve || plan.spendReserve).map { strdup($0) } + [nil]
        execv(binary, &argv)
    }
    warn("could not move this window; resume it with: CODEX_HOME=\(plan.targetHome) codex resume \(plan.threadID)")
    exit(1)
}
