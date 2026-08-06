import Foundation

// Which session a `tally switch` is addressed to, and whether anything will read it: the
// environment marker, the directory registry behind the fallback, the supervisor-build
// check, and the child environment the whole feature is addressed through. Split from
// switchchecks.swift for file size; the fixtures it uses are shared from there.

func runSwitchSessionChecks() {
    // MARK: - 31d. Which session is asking

    // The environment marker names the session the command was RUN IN, which is the main path: the
    // agent's own shell inherits it from the child. The directory can only ever name candidates.
    check("the session marker wins, even where several sessions run",
          sessionLookup(envPid: "100", here: ["200", "300"]) == .session("100"))
    check("one session in this directory needs no marker",
          sessionLookup(envPid: nil, here: ["200"]) == .session("200"))
    check("several sessions and no marker is ambiguous, and says which",
          sessionLookup(envPid: nil, here: ["200", "300"]) == .ambiguous(["200", "300"]))
    check("nothing supervised here is its own answer",
          sessionLookup(envPid: nil, here: []) == .none)

    // MARK: - 31e. The directory a session runs in

    let cwdDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-switch-cwd-\(UUID().uuidString)")
    let here = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-switch-here-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
    let mePid = String(getpid())
    markSupervisorLive(pid: mePid, dir: cwdDir)
    writeSupervisorCwd(here.path, pid: mePid, dir: cwdDir)
    // Fully resolved on the way in, because /tmp is a symlink to /private/tmp and the CLI resolves
    // its own cwd the same way: two spellings of one directory must not read as two directories.
    check("the published directory is the resolved one",
          readSupervisorCwd(pid: mePid, dir: cwdDir) == realpathString(here.path))
    check("a session in this directory is found",
          supervisorsInDirectory(here.path, dir: cwdDir) == [mePid])
    check("a session in another directory is not",
          supervisorsInDirectory(NSTemporaryDirectory(), dir: cwdDir).isEmpty)
    markSupervisorLive(pid: "99999", dir: cwdDir)
    writeSupervisorCwd(here.path, pid: "99999", dir: cwdDir)
    check("a dead supervisor's directory entry does not add a session",
          supervisorsInDirectory(here.path, dir: cwdDir) == [mePid])
    // The document has to be on the swept track, or a dead session's directory entry outlives it
    // and the next process to inherit that pid answers for a directory it never ran in.
    check("the state sweep knows this document belongs to a pid",
          supervisorStatePid(ofFile: "99999\(supervisorCwdSuffix)") == 99999)
    sweepDeadSupervisorState(dir: cwdDir)
    check("so a dead session's directory entry is reaped",
          readSupervisorCwd(pid: "99999", dir: cwdDir) == nil)
    check("and a live one's is kept", readSupervisorCwd(pid: mePid, dir: cwdDir) != nil)
    try? FileManager.default.removeItem(at: cwdDir)
    try? FileManager.default.removeItem(at: here)

    // MARK: - 31h. The bar the switch waits on

    check("a switch settles for the short quiet gap, not the 120s left-alone bar",
          manualMoveIdleSeconds == reloadNowIdleSeconds && manualMoveIdleSeconds < followIdleSeconds)

    // MARK: - 31i. Will anything read the request?

    // The failure this answers is the silent one: a supervisor from a build without this feature
    // registers and stamps its pid exactly like a current one, so a request written for it would be
    // read by nobody while the command reported success.
    check("a supervisor on the installed build reads the request",
          switchHonourability(supervisorVersion: "0.37.0", installedVersion: "0.37.0")
              == .honoured)
    check("another build reads it after replacing itself",
          switchHonourability(supervisorVersion: "0.36.1", installedVersion: "0.37.0")
              == .afterSelfUpdate)
    check("a supervisor with no version stamp never will",
          switchHonourability(supervisorVersion: nil, installedVersion: "0.37.0") == .tooOld)
    check("a CLI outside any bundle cannot compare, and does not invent a problem",
          switchHonourability(supervisorVersion: "0.36.1", installedVersion: nil) == .honoured)

    // MARK: - 31j. The marker the whole feature is addressed by

    // The child env is where `tally switch` finds its session: the supervisor stamps its own pid,
    // and every process the child spawns (the agent's shell included) inherits it.
    let childEnv = supervisedChildEnvironment(
        provider: providers[0], home: "/tmp/A", supervisorVersion: "9.9.9", supervisorPID: "4242",
        relaunch: false, base: ["PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/tmp/stale"])
    check("the child carries the supervisor pid a switch addresses",
          childEnv["TALLY_SUPERVISOR_PID"] == "4242")
    check("and the Tally marker the status line reads", childEnv["TALLY_LAUNCHED"] == "1")
    check("and the build stamp behind the supervision note",
          childEnv["TALLY_SUPERVISOR_VERSION"] == "9.9.9")
    check("the account's own home replaces whatever was exported into this process",
          childEnv["CLAUDE_CONFIG_DIR"] == "/tmp/A")
    check("the rest of the environment is passed through", childEnv["PATH"] == "/usr/bin")
    check("a first launch keeps Claude Code's own resume prompt",
          childEnv[resumeTokenThresholdEnvKey] == nil)
    // A switch relaunch resumes by id with nobody at the keyboard, so it must not stop at that
    // prompt - the same suppression every other relaunch gets, carried by the same assembly.
    let relaunchEnv = supervisedChildEnvironment(
        provider: providers[0], home: "/tmp/A", supervisorVersion: nil, supervisorPID: "4242",
        relaunch: true, base: [:])
    check("a relaunch suppresses it",
          relaunchEnv[resumeTokenThresholdEnvKey] == resumePromptDisabledThreshold)
    check("and a supervisor with no version stamps none",
          relaunchEnv["TALLY_SUPERVISOR_VERSION"] == nil)
}
