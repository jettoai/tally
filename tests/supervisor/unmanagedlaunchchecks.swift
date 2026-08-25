import Foundation

// THE SESSIONS NOBODY SUPERVISES (TallyCLI/UnmanagedLaunch.swift): the record a plain exec leaves
// behind it, who is allowed to fill in the conversation, and the half of the live set it becomes.
//
// THE DEFECT BEHIND IT. `liveConversations` refuses to hand a launch a conversation somebody is
// already writing, and every witness it had was keyed by a SUPERVISOR pid. Four launch paths never
// get one - an exported `CLAUDE_CONFIG_DIR`, an `--account` pin, `--no-handoff`, a denormalized pin
// - so those sessions were invisible to it in both directions, and two writers on one transcript is
// how about three hours of turns were orphaned here on 2026-07-29.

func runUnmanagedLaunchChecks() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-unmanaged-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("records")
    let state = root.appendingPathComponent("supervisors")
    try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    let here = root.appendingPathComponent("cwd")
    try? FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
    let elsewhere = root.appendingPathComponent("other")
    try? FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    // The records carry the RESOLVED path, the way a launch writes it: the temporary directory this
    // suite runs in reaches /private/var by a symlink, so an unresolved comparison would pass here
    // and fail on a real machine (or the other way round, which is worse).
    let hereResolved = realpathString(here.path)

    // THE ONE PROCESS THIS SUITE CAN BE SURE ABOUT IS ITSELF, so it stands in for the exec'd claude:
    // a live pid whose start time can be read from the kernel rather than invented. A pid this
    // machine has certainly not handed out stands in for the session that ended.
    let mine = processStamp(getpid())!
    let deadPID: pid_t = 0x7FFF_FFF0

    // MARK: - The file format

    let record = UnmanagedLaunch(claudeCode: mine, cwd: hereResolved, id: "conv-one")
    writeUnmanagedLaunch(record, dir: dir)
    check("an unmanaged launch record round-trips",
          readUnmanagedLaunch(pid: mine.pid, dir: dir) == record)
    // A launch that started fresh under a home with no Tally status line has nothing to name yet,
    // and that is a record rather than a rejection.
    let unnamed = UnmanagedLaunch(claudeCode: mine, cwd: hereResolved, id: nil)
    check("a record with no conversation yet is still a record",
          parseUnmanagedLaunch(formatUnmanagedLaunch(unnamed), pid: mine.pid) == unnamed)
    check("a record naming something that is not an id reads as unnamed",
          parseUnmanagedLaunch("\(mine.startedAt)\n\(hereResolved)\n../../etc/passwd\n",
                               pid: mine.pid)?.id == nil)
    check("a record with no start time is no record",
          parseUnmanagedLaunch("\n\(hereResolved)\nconv-one\n", pid: mine.pid) == nil)
    check("…and one with no directory is no record either",
          parseUnmanagedLaunch("\(mine.startedAt)\n\n", pid: mine.pid) == nil)

    // MARK: - Which records are live
    //
    // A STAMP AND NOT A NUMBER. A pid names a process only while it is alive; a record left by a
    // session that ended would otherwise start describing whatever process next inherits its number.

    check("a record whose process is running is live",
          liveUnmanagedLaunches(dir: dir).map(\.claudeCode) == [mine])
    writeUnmanagedLaunch(UnmanagedLaunch(claudeCode: ProcessStamp(pid: mine.pid,
                                                                 startedAt: mine.startedAt + 1),
                                         cwd: hereResolved, id: "recycled"), dir: dir)
    check("a record whose pid was recycled is not live",
          liveUnmanagedLaunches(dir: dir).isEmpty)
    writeUnmanagedLaunch(UnmanagedLaunch(claudeCode: ProcessStamp(pid: deadPID, startedAt: 1),
                                         cwd: hereResolved, id: "gone"), dir: dir)
    check("…nor is one whose process is gone",
          !liveUnmanagedLaunches(dir: dir).contains { $0.id == "gone" })

    // The sweep is about the directory not growing forever; nothing depends on it for correctness,
    // which is why it runs at a launch rather than on a timer.
    writeUnmanagedLaunch(record, dir: dir)
    sweepUnmanagedLaunches(dir: dir)
    check("the sweep drops the records of ended sessions",
          !FileManager.default.fileExists(atPath: unmanagedLaunchFile(pid: deadPID, dir: dir).path))
    check("…and keeps the running one",
          readUnmanagedLaunch(pid: mine.pid, dir: dir) == record)

    // MARK: - The live set

    check("an unmanaged session's conversation is live in its own directory",
          unmanagedConversations(in: here.path, dir: dir) == ["conv-one"])
    check("…and in no other directory",
          unmanagedConversations(in: elsewhere.path, dir: dir).isEmpty)
    // Both sides are resolved, which is how the supervisor's own cwd entry is compared: /tmp is a
    // symlink to /private/tmp on this platform and a launch may arrive by either name.
    check("the directory is matched however the launch spelled it",
          unmanagedConversations(in: hereResolved, dir: dir) == ["conv-one"])

    // THE UNION. This is what the whole file is for: `liveConversations` had two witnesses, both
    // keyed by a supervisor pid, and a state directory with no supervisors in it answered "nothing
    // is running here" while an `--account` pinned session wrote away.
    check("liveConversations names an unmanaged session no supervisor can report",
          liveConversations(in: here.path, dir: state, unmanagedDir: dir) == ["conv-one"])
    check("…and still names none in a directory with neither",
          liveConversations(in: elsewhere.path, dir: state, unmanagedDir: dir).isEmpty)

    // MARK: - What a launch registers before it execs
    //
    // `execvp` replaces the image, not the process: the pid AND the start time survive it (measured
    // 2026-08-25, both identical either side), which is what lets the process about to become claude
    // write down exactly which process the session will be.

    let launchDir = root.appendingPathComponent("registered")
    registerUnmanagedLaunch(providerID: "claude", args: ["--resume", "conv-two", "--model", "opus"],
                            cwd: here.path, pid: mine.pid, dir: launchDir)
    check("a launch registers itself under its own stamp",
          readUnmanagedLaunch(pid: mine.pid, dir: launchDir)?.claudeCode == mine)
    check("…naming the conversation it is about to resume",
          readUnmanagedLaunch(pid: mine.pid, dir: launchDir)?.id == "conv-two")
    check("…and the directory it is launching in, resolved",
          readUnmanagedLaunch(pid: mine.pid, dir: launchDir)?.cwd == realpathString(here.path))

    // Registering exports the marker into THIS process, which is what a launch wants and what a
    // suite must not leave behind: every check below passes its own marker, and one left in the
    // environment would answer for a later reader that did not.
    unsetenv(unmanagedLaunchMarker)

    let codexDir = root.appendingPathComponent("codex")
    registerUnmanagedLaunch(providerID: "codex", args: [], cwd: here.path, pid: mine.pid,
                            dir: codexDir)
    check("a codex launch registers nothing",
          !FileManager.default.fileExists(atPath: codexDir.path))

    // THE ID IS READ THE WAY EVERY OTHER FLAG ON THIS TRACK IS READ: from the options only, and
    // never from a word that is itself a flag. Bare `--resume` opens claude's own picker.
    check("the resumed conversation is read off the args",
          resumedConversationID(["--model", "opus", "--resume", "abc-123"]) == "abc-123")
    check("a bare --resume followed by another flag names nothing",
          resumedConversationID(["--resume", "--model"]) == nil)
    check("a dangling --resume names nothing", resumedConversationID(["--resume"]) == nil)
    // Past a bare `--` the same word is part of the user's prompt.
    check("an id in the prompt is not a resume",
          resumedConversationID(["--", "--resume", "abc-123"]) == nil)

    // MARK: - Who may fill the conversation in
    //
    // The marker is inherited by everything the session starts, so it is admitted ONLY when it names
    // the very process that ran this status line - the same addressing rule the supervised report
    // uses, and it is what makes an inherited marker harmless rather than dangerous.

    let reportDir = root.appendingPathComponent("reported")
    writeUnmanagedLaunch(UnmanagedLaunch(claudeCode: mine, cwd: hereResolved, id: nil),
                         dir: reportDir)
    reportUnmanagedConversation(sessionID: "conv-three", claudeCode: mine,
                                marker: String(mine.pid), dir: reportDir)
    check("the status line names the conversation of the session that ran it",
          readUnmanagedLaunch(pid: mine.pid, dir: reportDir)?.id == "conv-three")
    check("…and keeps the directory the launch registered",
          readUnmanagedLaunch(pid: mine.pid, dir: reportDir)?.cwd == hereResolved)

    let other = ProcessStamp(pid: deadPID, startedAt: mine.startedAt)
    reportUnmanagedConversation(sessionID: "not-ours", claudeCode: other,
                                marker: String(mine.pid), dir: reportDir)
    check("an inherited marker naming another process reports nothing",
          readUnmanagedLaunch(pid: mine.pid, dir: reportDir)?.id == "conv-three")
    reportUnmanagedConversation(sessionID: "no-marker", claudeCode: mine, marker: nil,
                                dir: reportDir)
    check("a supervised session, carrying no marker of ours, reports nothing",
          readUnmanagedLaunch(pid: mine.pid, dir: reportDir)?.id == "conv-three")
    // A report about a process the record was not written for: a recycled pid, or a marker that
    // outlived the launch that set it.
    writeUnmanagedLaunch(UnmanagedLaunch(claudeCode: ProcessStamp(pid: mine.pid,
                                                                 startedAt: mine.startedAt - 1),
                                         cwd: hereResolved, id: "older-process"), dir: reportDir)
    reportUnmanagedConversation(sessionID: "conv-four", claudeCode: mine, marker: String(mine.pid),
                                dir: reportDir)
    check("a record written for a different process is not overwritten",
          readUnmanagedLaunch(pid: mine.pid, dir: reportDir)?.id == "older-process")

    // WRITES MUST BE RARE: a render can happen several times a second and the value only changes
    // when the conversation does. Asserted by taking the file away and seeing whether an unchanged
    // render puts it back - the same witness the supervised writers are held to.
    //
    // The file is left in place and marked instead of being taken away: removing it would make the
    // "is there a record at all" guard answer for this check, and the two would be indistinguishable.
    // The padding parses to the same record and is exactly what a rewrite would canonicalise away.
    let padded = "\(mine.startedAt)\n\(hereResolved)\nsteady   \n"
    try? padded.write(to: unmanagedLaunchFile(pid: mine.pid, dir: reportDir), atomically: true,
                      encoding: .utf8)
    reportUnmanagedConversation(sessionID: "steady", claudeCode: mine, marker: String(mine.pid),
                                dir: reportDir)
    check("a render that would say nothing new writes nothing",
          (try? String(contentsOf: unmanagedLaunchFile(pid: mine.pid, dir: reportDir),
                       encoding: .utf8)) == padded)
    reportUnmanagedConversation(sessionID: "moved-on", claudeCode: mine, marker: String(mine.pid),
                                dir: reportDir)
    check("…and one that would say something new writes it",
          readUnmanagedLaunch(pid: mine.pid, dir: reportDir)?.id == "moved-on")

    // MARK: - The launcher end is actually wired
    //
    // Asserted from the source, the way the supervised channel's two ends are: `launchProvider` is a
    // `Never`-returning entry point that execs, so nothing in this suite can call it.

    let launcher = (try? String(contentsOfFile: "TallyCLI/MCPAuthSync.swift", encoding: .utf8)) ?? ""
    check("the launcher source is readable from the suite", !launcher.isEmpty)
    check("every unsupervised launch registers itself",
          launcher.contains("registerUnmanagedLaunch(providerID: provider.id, args: args)"))
    if let registers = launcher.range(of: "registerUnmanagedLaunch("),
       let execs = launcher.range(of: "exec(provider.cli") {
        // BEFORE the exec, which does not return: after it there is no "after".
        check("…before the exec that replaces the process", registers.lowerBound < execs.lowerBound)
    } else {
        check("both the registration and the exec were found in the launcher", false)
    }

    try? FileManager.default.removeItem(at: root)
}
