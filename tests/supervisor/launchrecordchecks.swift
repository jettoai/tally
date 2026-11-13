import Foundation

// THE LAUNCH RECORD (TallyCLI/SessionLaunchRecord.swift) and the three host readings the reboot
// feature needs (Tally/Core/HostHealthReaders.swift: swapUsedBytes, bootTime, pressureLevel).
// Everything points at a temp directory; nothing touches ~/.tally/supervisor-state, and no real
// tmux or claude is started.

func runLaunchRecordChecks() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-launchrecord-\(UUID().uuidString)")
    let alive: (pid_t) -> Bool = { _ in true }
    let dead: (pid_t) -> Bool = { _ in false }

    // MARK: the record

    let env = ["TMUX": "/private/tmp/tmux-501/default,123,0", "TERM_PROGRAM": "ghostty"]
    let record = SessionLaunchRecord.current(provider: "claude", args: ["-w", "line8", "--model", "opus", "do the thing"],
                                             cwd: "/tmp", environment: env, tmuxName: { "baton-line8" })
    check("a launch inside tmux records the tmux session, the terminal, the provider and the arguments",
          record.tmuxSession == "baton-line8" && record.terminal == "ghostty" && record.provider == "claude"
              && record.args == ["-w", "line8", "--model", "opus"])
    check("the directory is recorded as its real path", record.cwd == realpathString("/tmp") && record.cwd.hasPrefix("/private"))

    var asked = false
    let plain = SessionLaunchRecord.current(provider: "codex", args: [], cwd: "/tmp", environment: [:],
                                            tmuxName: { asked = true; return "x" })
    check("outside tmux nothing asks tmux and the name and terminal stay empty",
          !asked && plain.tmuxSession == "" && plain.terminal == "")
    let silent = SessionLaunchRecord.current(provider: "claude", args: [], cwd: "/tmp",
                                             environment: ["TMUX": "x"], tmuxName: { nil })
    check("a tmux that does not answer leaves the name empty", silent.tmuxSession == "")

    record.write(pid: "4242", dir: dir)
    let file = sessionLaunchFile(pid: "4242", dir: dir)
    check("the file is named <pid>.launch", file.lastPathComponent == "4242.launch" && sessionLaunchSuffix == ".launch")
    check("a live supervisor's record reads back whole", SessionLaunchRecord.read(pid: "4242", dir: dir, isLive: alive) == record)
    check("a dead pid's record is not read", SessionLaunchRecord.read(pid: "4242", dir: dir, isLive: dead) == nil)
    check("a pid with no file reads as nothing", SessionLaunchRecord.read(pid: "9999", dir: dir, isLive: alive) == nil)
    let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
    check("the file is owner-only", mode == 0o600)
    // Created 0600, not chmodded afterwards: with the umask wide open the file still comes out 0600,
    // and the write path no longer has a chmod step or a default-mode write to leave a 0644 window.
    let oldMask = umask(0)
    record.write(pid: "4243", dir: dir)
    umask(oldMask)
    let openMode = (try? FileManager.default.attributesOfItem(atPath: sessionLaunchFile(pid: "4243", dir: dir).path)[.posixPermissions] as? Int) ?? 0
    let recordSource = (try? String(contentsOfFile: "TallyCLI/SessionLaunchRecord.swift", encoding: .utf8)) ?? ""
    check("the file is created owner-only even under umask 0, with no write-then-chmod window",
          openMode == 0o600 && recordSource.contains("0o600)") && !recordSource.contains("setAttributes")
              && !recordSource.contains("options: .atomic"))
    check("no temp file is left behind", !FileManager.default.fileExists(atPath: file.path + ".tmp"))

    // No credential can reach the file: a fake secret in every place a launch can carry one.
    let fake = "FAKE-SECRET-123"
    let claudeArgs = ["--mcp-config", "{\"mcpServers\":{\"x\":{\"env\":{\"K\":\"\(fake)\"}}}}", "--settings=\(fake)",
                      "--settings", "{\"env\":{\"T\":\"\(fake)\"}}", "--resume", "sid-1", "--effort=high", "-c", "-p", "say \(fake)"]
    let codexArgs = ["-c", "mcp_servers.x.env.K=\"\(fake)\"", "--config=a=\(fake)", "-ca=\(fake)", "resume", "thread-9",
                     "-m", "gpt-x", "--", "\(fake)"]
    for (index, pair) in [("claude", claudeArgs), ("codex", codexArgs)].enumerated() {
        let pid = String(7000 + index)
        publishSessionLaunch(provider: pair.0, args: pair.1, cwd: "/tmp", pid: pid, resumed: false, dir: dir)
        let raw = (try? String(contentsOf: sessionLaunchFile(pid: pid, dir: dir), encoding: .utf8)) ?? ""
        check("\(pair.0): the file holds no part of a credential, wherever the launch carried it",
              !raw.isEmpty && !raw.contains(fake) && !raw.contains("mcpServers"))
    }
    check("claude keeps what a reopen needs and nothing else",
          safeLaunchArgs(provider: "claude", claudeArgs) == ["--resume", "sid-1", "--effort=high", "-c"])
    check("codex keeps the model and the resumed thread, and drops every -c form and the prompt",
          safeLaunchArgs(provider: "codex", codexArgs) == ["resume", "thread-9", "-m", "gpt-x"])
    check("an option that takes an optional value keeps none that is itself an option",
          safeLaunchArgs(provider: "claude", ["-w", "--mcp-config", "x", "--continue"]) == ["-w", "--continue"])

    // A record from a build that knew fewer fields still decodes only if the missing ones are optional;
    // today's five are all required, so this holds the SHAPE: a damaged file is nil, not a crash.
    try? "{not json".write(to: sessionLaunchFile(pid: "5151", dir: dir), atomically: true, encoding: .utf8)
    check("a damaged file reads as nothing", SessionLaunchRecord.read(pid: "5151", dir: dir, isLive: alive) == nil)

    // No token or account id can be in it: the type has no such field.
    let json = String(data: (try? JSONEncoder().encode(record)) ?? Data(), encoding: .utf8) ?? ""
    check("the record carries exactly cwd, args, tmuxSession, terminal and provider",
          Set(((try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]).keys)
              == ["cwd", "args", "tmuxSession", "terminal", "provider"])

    // MARK: a self-update exec keeps the first image's record

    publishSessionLaunch(provider: "claude", args: ["-w", "first"], cwd: "/tmp", pid: "6001", resumed: false, dir: dir)
    publishSessionLaunch(provider: "claude", args: ["-w", "rewritten", "--resume", "abc"], cwd: "/tmp", pid: "6001",
                         resumed: true, dir: dir)
    check("a resumed image does not overwrite the launch record",
          SessionLaunchRecord.read(pid: "6001", dir: dir, isLive: alive)?.args == ["-w", "first"])
    publishSessionLaunch(provider: "claude", args: ["-w", "late"], cwd: "/tmp", pid: "6002", resumed: true, dir: dir)
    check("a resumed image writes one when the first image left none",
          SessionLaunchRecord.read(pid: "6002", dir: dir, isLive: alive)?.args == ["-w", "late"])
    publishSessionLaunch(provider: "claude", args: ["-w", "again"], cwd: "/tmp", pid: "6001", resumed: false, dir: dir)
    check("a fresh launch under a reused pid replaces the old record",
          SessionLaunchRecord.read(pid: "6001", dir: dir, isLive: alive)?.args == ["-w", "again"])

    // MARK: the sweep and the registry

    check("the sweep suffix list names the file, so a dead supervisor's record is swept with the rest",
          supervisorStateSuffixes.contains(sessionLaunchSuffix) && supervisorStatePid(ofFile: "4242.launch") == 4242)
    let deadPid = deadFixturePid()
    SessionLaunchRecord.current(provider: "claude", args: [], cwd: "/tmp", environment: [:]).write(pid: String(deadPid), dir: dir)
    sweepDeadSupervisorState(dir: dir)
    check("sweeping a dead pid removes its launch record",
          !FileManager.default.fileExists(atPath: sessionLaunchFile(pid: String(deadPid), dir: dir).path))
    check("the launch file is not mistaken for a supervisor in the registry",
          !liveSupervisorPids(dir: dir).contains(4242))

    // MARK: the wiring, pinned off the source (the supervisors cannot be driven from a harness)

    let supervisor = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    let codex = (try? String(contentsOfFile: "TallyCLI/CodexSupervisor.swift", encoding: .utf8)) ?? ""
    check("both supervisors publish a launch record",
          // #623: the Claude supervisor records the typed args only (the axes that follow the profile
          // are dropped, reassertchecks.swift); Codex injects no launch default, so its args are typed.
          supervisor.contains("publishSessionLaunch(provider: provider.id, args: typedLaunchArgs(args, following: follow)")
              && codex.contains("publishSessionLaunch(provider: provider.id, args: args"))
    check("the Claude supervisor publishes it after it marks itself live",
          (supervisor.range(of: "markSupervisorLive(pid: supervisorPID)")?.lowerBound ?? supervisor.endIndex)
              < (supervisor.range(of: "publishSessionLaunch(")?.lowerBound ?? supervisor.startIndex))

    // MARK: running a program under a deadline

    check("a program that answers in time gives its output", runWithTimeout("/bin/echo", ["hi"], timeout: 2) == "hi")
    let began = Date()
    let slow = runWithTimeout("/bin/sleep", ["5"], timeout: 0.3)
    check("a program still running at the deadline gives nothing, and quickly",
          slow == nil && Date().timeIntervalSince(began) < 2)
    check("a program that fails gives nothing", runWithTimeout("/usr/bin/false", [], timeout: 2) == nil)
    check("a program that does not exist gives nothing", runWithTimeout("/nonexistent/tmux", [], timeout: 2) == nil)

    // MARK: the host readings

    let swap = HostHealthReaders.swapUsedBytes()
    check("swap in use reads on this machine, and zero is a number", swap != nil && swap! < (1 << 50))
    let boot = HostHealthReaders.bootTime()
    check("the boot time is in the past and after 2009", boot != nil && boot! < Date() && boot! > Date(timeIntervalSince1970: 1_230_000_000))
    let level = HostHealthReaders.pressureLevel()
    check("the pressure level is 1, 2 or 4", level.map { hostLoadPressureLevels.contains($0) } ?? false)
    // kern.boottime is wall-clock and follows clock corrections (47 s off the uptime clock when this
    // was written), so the agreement is held to an hour, not to the second.
    check("the boot time is no less far back than the uptime clock says, give or take clock corrections",
          boot.map { Date().timeIntervalSince($0) >= ProcessInfo.processInfo.systemUptime - 3600 } ?? false)

    try? FileManager.default.removeItem(at: dir)
}
