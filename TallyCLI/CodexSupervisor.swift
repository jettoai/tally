import Darwin
import Foundation

func shouldMonitorCodex(args: [String], stdoutIsTTY: Bool) -> Bool {
    guard stdoutIsTTY, autoHandoffEnabled(args: args) else { return false }
    let options = optionsOnly(args)
    guard !options.contains(where: { ["--help", "-h", "--version", "-V"].contains($0) }) else { return false }
    let command = codexSubcommand(options)
    return command == nil || command == "resume"
}

/// Only a value actually passed to this child, never a profile or a configuration-home guess.
func codexLaunchEffort(_ args: [String]) -> String? {
    let value = codexTypedConfigOverrides(optionsOnly(args))
        .last(where: { $0.key == "model_reasoning_effort" })?.value
    return value.flatMap { $0.isEmpty ? nil : $0 }
}

/// Refuse an automatic second writer while a monitored Codex generation owns the conversation.
func liveCodexConversations(dir: URL = supervisorStateDir) -> Set<String> {
    var sessions: Set<String> = []
    for pid in SessionMonitoring.markedPids(dir: dir) {
        let key = String(pid)
        guard let identity = SessionMonitoring.read(pid: key, dir: dir), identity.provider == "codex",
              let bytes = try? Data(contentsOf: dir.appendingPathComponent(key + ".codex-binding")),
              let binding = try? JSONDecoder().decode(CodexSessionBinding.self, from: bytes),
              binding.nonce == identity.nonce else { continue }
        sessions.insert(binding.sessionID)
    }
    return sessions
}

nonisolated(unsafe) private var codexSupervisorSignal: Int32 = 0

/// A supervised Codex resident with an owned PTY for guarded direct input.
/// No recovery policy runs here: the child exits once and its exit status is preserved.
func runCodexSupervised(_ provider: Provider, account: Snapshot.Account, args: [String]) -> Never {
    guard let home = account.launchHome else { exit(1) }
    let pid = String(getpid())
    let launchedAt = Date()
    var input = SessionInputState(sessionKey: pid)
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
    // The station that reopens the app when a silent update took it away and never brought it back
    // (AppRelaunch.swift), which until 2026-09-22 only ran in `tally claude` sessions. An automatic
    // install lands when the machine has been idle for five minutes, which is precisely when the
    // terminal nobody is at may be running Codex rather than Claude: who is watching and when the
    // update happens are negatively correlated, so a supervisor that does not watch is half the
    // machine's cover gone. Nothing here has to cede to a self-update the way the other loop does,
    // because this one has no self-update station: it never replaces its own process image.
    var appRelaunch = AppRelaunchState()
    var nextAppRelaunchTick = Date.distantPast
    while reaper.isRunning {
        if let terminal, !terminal.pump(timeout: 0.02) {
            if metadata.childStart == SessionMonitoring.generation(child) { kill(child, SIGHUP) }
            break
        }
        reaper.poll()
        if !reaper.isRunning { break }
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
            for event in codexWaits.reconcile(observer: observer, directory: identity.directory, project: identity.project,
                                              worktree: identity.worktree, now: Date()) { appendSessionWaitEvent(event) }
            initializationDraft?.observe(humanInput: terminal?.lastHumanInputAt,
                inputReceipt: observer?.lastInputReceiptAt,
                ready: observer?.canAcceptInput == true && observer?.inputReceiptsAvailable == true)
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
                applyCodexSessionInput(&input, observer: observer, keyboard: keyboard,
                    launchedAt: launchedAt, terminalReady: metadata.inputTTY != nil && terminalReady,
                    startupDraftSuspected: initializationDraft?.suspected == true,
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
            }
            identity.model = observer?.model ?? identity.model
            let state = observer?.state ?? .unknown
            writer.sync(state, reason: state == .unknown ? "Codex session status is not available." : nil,
                        identity: identity, pid: pid)
        }
        if terminal == nil { usleep(250_000) }
    }
    terminal?.drainOutput()
    terminal?.close()
    let status = reaper.wait()
    for event in codexWaits.finish(now: Date()) { appendSessionWaitEvent(event) }
    clearCodexSupervisorState(pid: pid, dir: supervisorStateDir)
    postSessionStateChanged(pid: pid)
    exit(supervisorExitCode(childStatus: status))
}

func clearCodexSupervisorState(pid: String, dir: URL) {
    for suffix in [""] + supervisorStateSuffixes {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(pid + suffix))
    }
}
