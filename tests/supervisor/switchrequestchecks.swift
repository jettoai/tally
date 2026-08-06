import Foundation

// The addressing half of `tally switch` (SwitchRequest.swift): the request file's format,
// what it round-trips through a real directory, what a fresh supervisor starts out having
// served, and which account a session is judged to be on. Split from switchchecks.swift for
// file size; the fixtures it uses are shared from there.

func runSwitchRequestChecks() {
    // MARK: - 31a. The request format

    // Two lines: the stamp, then the account id the CLI resolved against the live fleet. Anything
    // else is no request at all - a half-written file must never read as a switch to nowhere.
    check("a request parses into stamp and account",
          parseSwitchRequest("1800000000123\nacct-2\n")
              == SwitchRequest(epoch: 1_800_000_000_123, accountID: "acct-2"))
    check("a request with no trailing newline parses",
          parseSwitchRequest("1800000000123\nacct-2")
              == SwitchRequest(epoch: 1_800_000_000_123, accountID: "acct-2"))
    check("surrounding whitespace is tolerated",
          parseSwitchRequest(" 1800000000123 \n acct-2 ")
              == SwitchRequest(epoch: 1_800_000_000_123, accountID: "acct-2"))
    check("an id with a slash survives", parseSwitchRequest("1\nwith/slash")?.accountID
              == "with/slash")
    check("an empty body is no request", parseSwitchRequest("") == nil)
    check("a stamp with no account is no request", parseSwitchRequest("1800000000123\n") == nil)
    check("a blank account line is no request", parseSwitchRequest("1800000000123\n\n") == nil)
    check("an account with no stamp is no request", parseSwitchRequest("\nacct-2\n") == nil)
    check("a garbage body is no request", parseSwitchRequest("switch please\nacct-2") == nil)

    // MARK: - 31b. The file: round trip, resolution, cleanup

    let switchDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-switch-file-\(UUID().uuidString)")
    check("a session with no request reads as nil",
          readSwitchRequest(sessionKey: "4242", dir: switchDir) == nil)
    try! writeSwitchRequest(accountID: "acct-2", sessionKey: "4242",
                            now: Date(timeIntervalSince1970: 1_800_000_000.5), dir: switchDir)
    check("a written request round-trips",
          readSwitchRequest(sessionKey: "4242", dir: switchDir)
              == SwitchRequest(epoch: 1_800_000_000_500, accountID: "acct-2"))
    // Milliseconds, not seconds: "switch to A" then, on seeing the wrong one, "switch to B" is a
    // real sequence, and at second resolution the second request reads as already served and
    // disappears without a word.
    try! writeSwitchRequest(accountID: "acct-3", sessionKey: "4242",
                            now: Date(timeIntervalSince1970: 1_800_000_000.9), dir: switchDir)
    check("two requests inside one second are distinguishable",
          readSwitchRequest(sessionKey: "4242", dir: switchDir)?.epoch == 1_800_000_000_900)
    check("the newer request replaces the older, and names its own account",
          readSwitchRequest(sessionKey: "4242", dir: switchDir)?.accountID == "acct-3")
    // Addressed: one session's request is invisible to another.
    check("a request is addressed to one session only",
          readSwitchRequest(sessionKey: "9999", dir: switchDir) == nil)
    clearSwitchRequest(sessionKey: "4242", dir: switchDir)
    check("a served request is unlinked",
          readSwitchRequest(sessionKey: "4242", dir: switchDir) == nil)

    // A session can exit with a request still queued behind a turn that never ended, and pids come
    // round again: the sweep is what stops that file from moving somebody else's session.
    try! writeSwitchRequest(accountID: "acct-2", sessionKey: "99999", dir: switchDir)
    try! writeSwitchRequest(accountID: "acct-2", sessionKey: String(getpid()), dir: switchDir)
    try! "notes".write(to: switchDir.appendingPathComponent("notes.txt"), atomically: true,
                       encoding: .utf8)
    sweepDeadSwitchRequests(dir: switchDir)
    check("a request for a dead session is swept",
          readSwitchRequest(sessionKey: "99999", dir: switchDir) == nil)
    check("a live session's request survives the sweep",
          readSwitchRequest(sessionKey: String(getpid()), dir: switchDir) != nil)
    check("a file that is not named for a pid is left alone",
          FileManager.default.fileExists(atPath: switchDir.appendingPathComponent("notes.txt").path))
    try? FileManager.default.removeItem(at: switchDir)

    // MARK: - 31b2. What a supervisor starts out having served

    // A fresh supervisor seeds itself from whatever is addressed to its pid, because pids come
    // round: the request it finds at startup belongs to the session that held the pid before.
    let seedDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-switch-seed-\(UUID().uuidString)")
    try! writeSwitchRequest(accountID: "acct-2", sessionKey: "4242",
                            now: Date(timeIntervalSince1970: 1_800_000_000), dir: seedDir)
    check("a new supervisor treats a request it did not ask for as served",
          ManualMoveState(sessionKey: "4242", dir: seedDir).servedEpoch == 1_800_000_000_000)
    check("and one with nothing addressed to it starts at zero",
          ManualMoveState(sessionKey: "9999", dir: seedDir).servedEpoch == 0)
    // The exception: a self-update exec keeps the pid and IS the same session, so the file it finds
    // is a request made seconds ago by the conversation it is taking over. Seeding there would eat
    // it silently - the one outcome this feature must never produce.
    check("a self-update taking the session over does not swallow a pending request",
          ManualMoveState(sessionKey: "4242", servedEpoch: 0, dir: seedDir).servedEpoch == 0)
    let loopSource = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the switch checks", !loopSource.isEmpty)
    check("and the loop really makes that distinction",
          loopSource.contains("ManualMoveState(sessionKey: supervisorPID, servedEpoch: "
                              + "resumed ? 0 : nil,"))
    // The other half of the same promise: the override rides the exec rather than being re-derived.
    check("and it hands the overridden pin across the self-update exec",
          loopSource.contains("pinOverride: manualMoves.overriddenPin"))
    try? FileManager.default.removeItem(at: seedDir)

    // MARK: - 31b3. Which account the session being moved is actually on

    // "already on X" has to be asked of the SESSION, not of the shell asking. Through the directory
    // fallback that shell is somebody else's terminal, and its `CLAUDE_CONFIG_DIR` describes
    // whatever launched IT - usually nothing, which reads as the default home and would announce
    // "already on <the default account>" for a session running somewhere else entirely.
    let ctxDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-switch-ctx-\(UUID().uuidString)")
    let claude = providers[0]
    let defaultHomeAccount = switchAccount("D1", home: defaultHome(claude))
    let otherHomeAccount = switchAccount("H2", home: "/tmp/home2")
    let fleetHomes = [defaultHomeAccount, otherHomeAccount]
    writeSessionContext(SupervisedSession(accountID: "H2", contextTokens: 5_000, updatedAt: Date()),
                        pid: "4242", dir: ctxDir)
    // Outside the session there is no session environment to read, so the published file is the
    // only evidence there is.
    check("a shell in the project directory reads the published account",
          sessionAccountID(sessionKey: "4242", isThisSession: false, provider: claude,
                           accounts: fleetHomes, dir: ctxDir, environment: [:]) == "H2")
    check("and nothing at all when that session has published nothing",
          sessionAccountID(sessionKey: "9999", isThisSession: false, provider: claude,
                           accounts: fleetHomes, dir: ctxDir,
                           environment: [claude.envKey: "/tmp/home2"]) == nil)
    // INSIDE the session there are two witnesses and each is stale in a way the other is not, so
    // they have to AGREE. The file lags the seconds after a handoff; the environment lags forever
    // in any shell OLDER than the handoff (a long-lived background process keeps the pre-move
    // `CLAUDE_CONFIG_DIR` while the supervisor pid it also carries stays live). Either one alone
    // would answer "already on it" for a session that has since moved, and drop a deliberate
    // switch back as a no-op.
    check("inside the session, two witnesses that disagree decide nothing",
          sessionAccountID(sessionKey: "4242", isThisSession: true, provider: claude,
                           accounts: fleetHomes, dir: ctxDir,
                           environment: [claude.envKey: defaultHome(claude)]) == nil)
    check("and two that agree answer",
          sessionAccountID(sessionKey: "4242", isThisSession: true, provider: claude,
                           accounts: fleetHomes, dir: ctxDir,
                           environment: [claude.envKey: "/tmp/home2"]) == "H2")
    check("a session with nothing published still answers from its own environment",
          sessionAccountID(sessionKey: "9999", isThisSession: true, provider: claude,
                           accounts: fleetHomes, dir: ctxDir,
                           environment: [claude.envKey: "/tmp/home2"]) == "H2")
    check("an unset config home reads as the provider's default home",
          sessionAccountID(sessionKey: "9999", isThisSession: true, provider: claude,
                           accounts: fleetHomes, dir: ctxDir, environment: [:]) == "D1")
    check("and an unknown home names no account",
          sessionAccountID(sessionKey: "9999", isThisSession: true, provider: claude,
                           accounts: fleetHomes, dir: ctxDir,
                           environment: [claude.envKey: "/tmp/nobody"]) == nil)
    // The supervisor narrows the fallback's staleness window by republishing at the relaunch
    // itself, rather than waiting for a tick that has a token figure to report.
    var moved = SessionContextWriter()
    moved.sync(tokens: 12_000, accountID: "H2", pin: nil, pid: "5150", dir: ctxDir)
    moved.accountChanged(to: "D1", pin: nil, pid: "5150", dir: ctxDir)
    check("a handoff republishes the conversation under the account it moved to",
          readSessionContext(pid: "5150", dir: ctxDir)?.accountID == "D1")
    check("carrying the reading it already had, since the conversation is the same one",
          readSessionContext(pid: "5150", dir: ctxDir)?.contextTokens == 12_000)
    var neverPublished = SessionContextWriter()
    neverPublished.accountChanged(to: "D1", pin: nil, pid: "5151", dir: ctxDir)
    check("a session that never published a reading invents nothing",
          readSessionContext(pid: "5151", dir: ctxDir) == nil)
    try? FileManager.default.removeItem(at: ctxDir)

}
