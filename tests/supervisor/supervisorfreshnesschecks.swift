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
