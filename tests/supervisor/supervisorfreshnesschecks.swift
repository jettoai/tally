import Foundation

// WHICH BUILD IS WATCHING EACH SESSION (TallyCLI/SessionState.swift, TallyCLI/SessionStateSync.swift,
// Tally/Stores/SessionRosterFreshness.swift): the one reading on the board that is normally absent.
//
// An app update replaces the binary under every live supervisor at once and none of them takes it
// there and then - each replaces itself at its own next idle moment (SelfUpdate.swift) - so for
// that window a board of eight sessions holds one or two running code that is no longer installed.
// Measured on this machine the day this was written: nine live sessions, one of them still on the
// previous release, and nothing outside its own terminal said so.
//
// THREE THINGS CAN GO WRONG HERE AND ONLY ONE OF THEM IS VISIBLE ON SCREEN:
//
//   - THE FIELD IS NOT WRITTEN AT ALL, which looks exactly like a fleet that is up to date. The
//     whole feature's failure mode is silence, so the wiring is pinned off the source as well as
//     exercised: a call site that stopped passing the version would go on publishing records, and
//     every card would go on drawing nothing.
//   - THE VERSION IS READ FRESH RATHER THAN CAPTURED. `supervisorBuildVersion()` resolves the
//     bundle's plist on every call, so a supervisor asking it AFTER the update reports the build it
//     is about to become - which is precisely the session this is looking for, reporting itself as
//     current. That defect is invisible in every direction: the record is written, the field is
//     populated, and the answer is wrong.
//   - nil IS READ AS OUTDATED. Every supervisor predating the field publishes nil, which is the
//     whole machine on the day this ships, so a comparison that treats "cannot say" as "not equal"
//     raises the badge on every card at once.
//
// AND THE ONE THAT ACTUALLY HAPPENED, which is the first of those three wearing a different face.
// The record's field is written from 0.64.3 onwards and by nothing older, so the first changeover
// after it shipped - four supervisors left on 0.64.2, which is precisely the board this feature
// exists for - drew nothing at all, correctly, on every card. The reading that reaches back is the
// stamp the supervisor puts in its CHILD's environment (`supervisorVersionStamp`), written by every
// build since v0.26, and the record's field is now the fallback behind it. So this file states two
// more things: what that buffer means, and which of the two sources wins.

func runSupervisorFreshnessChecks() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-freshness-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)

    // MARK: the field on the record

    let stamped = SessionStateRecord(state: "idle", since: t0, updatedAt: t0,
                                     accountID: "claude:.claude", project: "tally",
                                     supervisorVersion: "0.64.1")
    writeSessionState(stamped, pid: "9301", dir: dir)
    check("a published build round-trips with the rest of the record",
          readSessionState(pid: "9301", dir: dir) == stamped
              && readSessionState(pid: "9301", dir: dir)?.supervisorVersion == "0.64.1")

    // ADDITIVE-ONLY, which is the rule the whole file is under and the one this field is most
    // exposed to: every supervisor running when this ships wrote its record without the key, and a
    // decoder that rejected those would drop those sessions off the board entirely - the update
    // window being exactly when the board is worth looking at.
    let old = dir.appendingPathComponent("9302" + sessionStateSuffix)
    try? Data(#"{"state":"working","since":"2026-08-23T10:00:00Z","updatedAt":"2026-08-23T10:00:00Z"}"#
        .utf8).write(to: old)
    check("a record written before the field existed still decodes",
          readSessionState(pid: "9302", dir: dir)?.supervised == .working)
    check("…and says it cannot compare, rather than saying anything about a version",
          readSessionState(pid: "9302", dir: dir)?.supervisorVersion == nil)

    // MARK: a tick publishes what it was handed

    let project = dir.appendingPathComponent("project")
    try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let transcript = project.appendingPathComponent("conversation.jsonl")
    try? Data("{}\n".utf8).write(to: transcript)

    /// One tick over that conversation, published under `pid` with whatever build is handed in.
    func tick(_ pid: String, version: String?) -> SessionStateRecord? {
        var writer = SessionStateWriter()
        var watcher = TranscriptWatcher(projectDir: project, file: transcript, since: t0)
        syncSessionState(&writer, pid: pid,
                         project: PickProject(name: "tally", path: project.path),
                         accountID: "claude:.claude", childPid: nil, model: nil,
                         supervisorVersion: version, watcher: &watcher,
                         keyboardBurstAt: nil, dir: dir, now: Date())
        return readSessionState(pid: pid, dir: dir)
    }
    check("a tick publishes the build it was handed", tick("9303", version: "0.64.1")?
        .supervisorVersion == "0.64.1")
    check("…and publishes nothing when it was handed nothing",
          tick("9304", version: nil)?.supervisorVersion == nil)

    // MARK: what the board does with it

    // THE THREE ANSWERS, and the first two are the ones that have to be nothing. A supervisor from
    // before the field and a supervisor on this very build are different sessions with the same
    // reading: there is nothing to say about either.
    check("a session that published no build has nothing said about it",
          outdatedSupervisorBuild(nil, installed: "0.64.2") == nil)
    check("…as does one running the build that is installed",
          outdatedSupervisorBuild("0.64.2", installed: "0.64.2") == nil)
    // AND WHEN THE APP ITSELF CANNOT SAY. A bundle with no marketing version compares against
    // nothing, and answering "outdated" there would put the badge on every card on the machine.
    check("…and one compared against a bundle that names no version of its own",
          outdatedSupervisorBuild("0.64.1", installed: nil) == nil)
    check("a session on another build is named, and named by ITS version rather than the app's",
          outdatedSupervisorBuild("0.64.1", installed: "0.64.2") == "0.64.1")

    let behind = SessionRosterStore.SessionRow(id: "9401", record: stamped)
    let current = SessionRosterStore.SessionRow(
        id: "9402", record: SessionStateRecord(state: "idle", since: t0, updatedAt: t0,
                                               supervisorVersion: BuildVariant.version))
    let silent = SessionRosterStore.SessionRow(
        id: "9403", record: SessionStateRecord(state: "idle", since: t0, updatedAt: t0))
    check("the row hands its published build to that reading",
          behind.supervisorVersion == "0.64.1" && silent.supervisorVersion == nil)
    // In this harness `Bundle.main` is the test binary, which carries no marketing version - so the
    // installed side is nil and NOTHING is outdated. That is the assertion worth having here: the
    // one direction a badge must never appear in is "we could not tell".
    check("a harness with no bundle version around it raises no badge on any of them",
          [behind, current, silent].allSatisfy { $0.outdatedSupervisorVersion == nil })

    // MARK: the reading that reaches back

    /// A `KERN_PROCARGS2` buffer, assembled the way the kernel lays one out: the argument count,
    /// the path the program was executed from, the padding that follows it, then that many
    /// arguments and the environment after them.
    func procargs(_ path: String, argv: [String], env: [String]) -> Data {
        var data = withUnsafeBytes(of: Int32(argv.count)) { Data($0) }
        data.append(contentsOf: Array(path.utf8) + [0, 0, 0])
        for field in argv + env { data.append(contentsOf: Array(field.utf8) + [0]) }
        return data
    }
    let key = supervisorVersionEnvKey
    check("a stamp is read out of the environment half of the buffer",
          parseSupervisorVersion(procargs: procargs(
              "/usr/local/bin/claude", argv: ["claude", "--resume"],
              env: ["PATH=/usr/bin", "\(key)=0.64.2", "TALLY_LAUNCHED=1"])) == "0.64.2")
    check("…and a child spawned by a supervisor too old to stamp one says nothing",
          parseSupervisorVersion(procargs: procargs(
              "/usr/local/bin/claude", argv: ["claude"],
              env: ["PATH=/usr/bin", "TALLY_LAUNCHED=1"])) == nil)
    // THE ARGUMENT COUNT IS WHAT SEPARATES THE TWO HALVES. Arguments and environment entries are
    // the same shape of string in one run - `env VAR=value cmd` is literally an argument spelled
    // like an environment entry - so a scan that skipped the walk would read a command line as an
    // environment. The argument here is written the way `env` takes one for exactly that reason: a
    // fixture that merely MENTIONED the variable would be green under either implementation, which
    // is what the first draft of this check was.
    check("…and an argument spelled like an environment entry is not a stamp",
          parseSupervisorVersion(procargs: procargs(
              "/usr/bin/env", argv: ["env", "\(key)=1.2.3", "sleep", "30"],
              env: ["PATH=/usr/bin"])) == nil)
    check("…nor is a name exported with nothing behind it",
          parseSupervisorVersion(procargs: procargs("/bin/sh", argv: ["sh"],
                                                    env: ["\(key)="])) == nil)
    check("…and a buffer too short to hold a count says nothing rather than reading past itself",
          parseSupervisorVersion(procargs: Data([1, 2])) == nil)

    // OFF A REAL PROCESS, because every check above states what a buffer MEANS and none of them
    // states that the kernel writes one this shape - which is the whole of what stands between this
    // reading and the silence it was written to end.
    //
    // A COPY OF `/bin/sleep` RATHER THAN `/bin/sleep`, and the copying is the finding: macOS
    // withholds the environment half of the buffer for a PLATFORM BINARY, so a system tool comes
    // back with its arguments and nothing after them (`ps -E` is refused the same way). Measured
    // here: 34 bytes for /bin/sleep against 724 for a copy of the same executable launched with the
    // same environment. It costs this suite a file and it costs the feature nothing - the process
    // this actually reads is Claude Code, which no version of macOS protects - and the failure it
    // would have caused is silence rather than a wrong reading, which is what the badge treats
    // every unreadable process as.
    let sleeperDir = dir.appendingPathComponent("sleeper")
    try? FileManager.default.createDirectory(at: sleeperDir, withIntermediateDirectories: true)
    let sleeper = sleeperDir.appendingPathComponent("sleeper")
    try? FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleeper)
    func launch(_ executable: URL, _ environment: [String: String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        process.environment = environment
        try? process.run()
        return process
    }
    let stampedChild = launch(sleeper, ["PATH": "/usr/bin:/bin", key: "9.9.9"])
    let bareChild = launch(sleeper, ["PATH": "/usr/bin:/bin"])
    let protectedChild = launch(URL(fileURLWithPath: "/bin/sleep"),
                                ["PATH": "/usr/bin:/bin", key: "9.9.9"])
    check("the stamp is read off a live process this suite launched",
          supervisorVersionStamp(ofProcess: Int(stampedChild.processIdentifier)) == "9.9.9")
    check("…and a live process launched without one is silent rather than wrong",
          supervisorVersionStamp(ofProcess: Int(bareChild.processIdentifier)) == nil)
    check("…as is one whose environment the system withholds, stamp or no stamp",
          supervisorVersionStamp(ofProcess: Int(protectedChild.processIdentifier)) == nil)
    check("…and a pid nothing is running under is silent too",
          supervisorVersionStamp(ofProcess: 0) == nil)
    for child in [stampedChild, bareChild, protectedChild] { child.terminate() }

    // THE TWO ENDS OF THE CONTRACT, asked of the writer and read back with the reader's own key: a
    // renamed variable would leave the board silent for ever, on a machine where every supervisor
    // is stamping its build correctly.
    check("the key this reads is the one the supervisor's spawn writes",
          supervisedChildEnvironment(provider: providers[0], home: "/tmp/A",
                                     supervisorVersion: "9.9.9", supervisorPID: "1",
                                     base: [:])[key] == "9.9.9")

    // MARK: which of the two sources the card believes

    /// What the badge would say about a row, on a machine with 0.64.3 installed.
    func badge(stamp: String?, published: String?) -> String? {
        let row = SessionRosterStore.SessionRow(
            id: "9500", record: published.map {
                SessionStateRecord(state: "idle", since: t0, updatedAt: t0, supervisorVersion: $0)
            }, childSupervisorVersion: stamp)
        return outdatedSupervisorBuild(row.supervisorVersion, installed: "0.64.3")
    }
    // THE CASE THE FIELD ALONE CANNOT ANSWER, and the one this whole reading is for: a supervisor
    // from before the field publishes no version at all, and its child carries the stamp.
    check("a session whose supervisor predates the record's field is named by its child's stamp",
          badge(stamp: "0.64.2", published: nil) == "0.64.2")
    check("…while a session whose child is gone is still named by what it published",
          badge(stamp: nil, published: "0.64.1") == "0.64.1")
    check("…and one that says neither is still not accused of anything",
          badge(stamp: nil, published: nil) == nil)
    // THE ORDER ITSELF, which the three checks above cannot state: each of them has exactly one
    // source to answer from, so all three stay green under either precedence. Both sources are one
    // supervisor's own captured version and a machine should never see them differ - which is
    // precisely why the order has to be asserted rather than observed, and why it is asserted in
    // the direction that reaches the older builds.
    check("the child's stamp outranks the record's field when they disagree",
          badge(stamp: "0.64.2", published: "0.64.3") == "0.64.2")

    // MARK: the wiring, off the source

    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    let sync = (try? String(contentsOfFile: "TallyCLI/SessionStateSync.swift",
                            encoding: .utf8)) ?? ""
    let card = (try? String(contentsOfFile: "Tally/Views/SessionCardView.swift",
                            encoding: .utf8)) ?? ""
    let board = (try? String(contentsOfFile: "Tally/Views/SessionBoardView.swift",
                             encoding: .utf8)) ?? ""
    check("the sources this suite reads are readable from it",
          !loop.isEmpty && !sync.isEmpty && !card.isEmpty && !board.isEmpty)

    /// The source with its comment lines taken out: every rule below is also EXPLAINED in prose
    /// beside the code, and a check that cannot tell the two apart would be green for the sentence.
    func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
    let loopCode = code(loop), syncCode = code(sync)

    /// THE BOARD PUBLISH ALONE, cut out of the tick rather than searched for across the whole file:
    /// the same `let` is handed to the child's environment two hundred lines up, under the same
    /// argument label (`launchEnvironment`), so a check run over the file would be green for that
    /// call even if this one had stopped passing anything at all.
    let publish = loopCode.components(separatedBy: "let board = syncSessionState(")
        .dropFirst().first?.components(separatedBy: "keyboardBurstAt:").first ?? ""
    check("the harness really cut out the board publish", !publish.isEmpty)
    check("the supervisor captures its build once, at startup",
          loopCode.contains("let supervisorVersion = supervisorBuildVersion()"))
    check("…and the board publish is handed THAT value",
          publish.contains("supervisorVersion: supervisorVersion,"))
    // THE DEFECT THIS PINS, and the only one of the three that leaves everything looking right: a
    // fresh read here reports the build that has just been installed under this supervisor, so the
    // one session running stale logic is the one card that says it is current.
    check("…rather than a build read fresh at the moment of the write",
          !publish.contains("supervisorBuildVersion()")
              && !syncCode.contains("supervisorBuildVersion()"))
    // NO DEFAULT ON THE PARAMETER, which is what makes the check above mean anything: a defaulted
    // nil would let a call site drop the field entirely and still compile, and the symptom would be
    // a board that never raises the badge - indistinguishable from a fleet that is up to date.
    check("the publish takes the build as an argument nothing can forget to pass",
          syncCode.contains("supervisorVersion: String?,")
              && !syncCode.contains("supervisorVersion: String? = "))
    check("…and carries it onto the record it writes",
          syncCode.contains("supervisorVersion: identity.supervisorVersion"))

    // EXCEPTION-ONLY ON BOTH SURFACES, which is the whole design: a resident version on every card
    // would spend a segment of the identity line for a reading that is worth acting on for minutes
    // a week, and a resident "0 updating" would spend a summary slot on the uninteresting answer.
    check("the card draws the badge only when there is a version to name",
          code(card).contains("if let outdated = row.outdatedSupervisorVersion {"))
    check("…in the sentence that says the update is already under way",
          card.contains(#"L("%@ → updates when idle")"#))
    check("the summary counts them only when there are any",
          code(board).contains("if roster.updatingCount > 0 {"))
}
