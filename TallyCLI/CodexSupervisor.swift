import Darwin
import Foundation

func shouldMonitorCodex(args: [String], stdoutIsTTY: Bool) -> Bool {
    guard stdoutIsTTY, autoHandoffEnabled(args: args) else { return false }
    let options = optionsOnly(args)
    guard !options.contains(where: { ["--help", "-h", "--version", "-V"].contains($0) }) else { return false }
    let command = codexSubcommand(options)
    return command == nil || command == "resume"
}

nonisolated(unsafe) private var codexSupervisorSignal: Int32 = 0

/// A monitoring resident using the same spawn, environment, reaper and state writer as Claude.
/// No recovery policy runs here: the child exits once and its exit status is preserved.
func runCodexSupervised(_ provider: Provider, account: Snapshot.Account, args: [String]) -> Never {
    guard let home = account.launchHome else { exit(1) }
    let pid = String(getpid())
    let launchedAt = Date()
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
    guard let child = spawnChild([provider.cli] + args, environment: environment) else {
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
    var observer: CodexSessionObserver?
    var identity = SessionIdentity(accountID: account.id, directory: cwd,
                                   project: URL(fileURLWithPath: cwd).lastPathComponent,
                                   model: launchPrimaryModel(args, providerID: "codex"),
                                   childPid: Int(child), supervisorVersion: version)
    while reaper.isRunning {
        reaper.poll()
        if !reaper.isRunning { break }
        if codexSupervisorSignal != 0 {
            if metadata.childStart == SessionMonitoring.generation(child) { kill(child, codexSupervisorSignal) }
            break
        }
        autoreleasepool {
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
            let activity = (try? Data(contentsOf: supervisorStateDir.appendingPathComponent(pid + ".codex-activity")))
                .flatMap { try? JSONDecoder().decode(CodexSessionActivity.self, from: $0) }
            observer?.poll(home: home, activity: activity)
            identity.model = observer?.model ?? identity.model
            let state = observer?.state ?? .unknown
            writer.sync(state, reason: state == .unknown ? "Codex session status is not available." : nil,
                        identity: identity, pid: pid)
        }
        usleep(250_000)
    }
    let status = reaper.wait()
    clearCodexSupervisorState(pid: pid, dir: supervisorStateDir)
    postSessionStateChanged(pid: pid)
    exit(supervisorExitCode(childStatus: status))
}

func clearCodexSupervisorState(pid: String, dir: URL) {
    for suffix in [""] + supervisorStateSuffixes {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(pid + suffix))
    }
}
