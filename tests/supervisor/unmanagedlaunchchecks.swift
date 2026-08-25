import Foundation

// THE SESSIONS NOBODY SUPERVISES (TallyCLI/UnmanagedLaunch.swift): the record a plain exec leaves
// behind it, who is allowed to fill in the conversation, and the half of the live set it becomes.
//
// THE DEFECT BEHIND IT. `liveConversations` refuses to hand a launch a conversation somebody is
// already writing, and every witness it had was keyed by a SUPERVISOR pid. A session with no
// supervisor was therefore invisible to it in both directions, and two writers on one transcript is
// how about three hours of turns were orphaned here on 2026-07-29.
//
// WHICH SESSIONS THOSE ARE IS NOT A LIST OF LAUNCH PATHS, and the fixtures below are written that
// way on purpose. The first version of this channel enumerated the paths inside the CLI that exec
// `claude` outright and called that the whole of it, which is a claim about EVERY launch made by
// counting only the launches it could see: `claude` also starts from the PATH shim, which execs the
// real binary without entering this program at all, and from somebody typing `claude` on a machine
// with no shim. So the answer is asked where the session answers for itself, the status line, and
// the process that ran it is the process writing the transcript. Nothing here asserts anything
// about how a session was started, because that is the premise the source rejects.

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
          parseUnmanagedLaunch(
              "\(unmanagedLaunchFormat)\n\(mine.startedAt)\n../../etc/passwd\n\(hereResolved)\n",
              pid: mine.pid) == UnmanagedLaunch(claudeCode: mine, cwd: hereResolved, id: nil))
    check("a record with no start time is no record",
          parseUnmanagedLaunch("\(unmanagedLaunchFormat)\n\nconv-one\n\(hereResolved)\n",
                               pid: mine.pid) == nil)
    check("…and one with no directory is no record either",
          parseUnmanagedLaunch("\(unmanagedLaunchFormat)\n\(mine.startedAt)\nconv-one\n\n",
                               pid: mine.pid) == nil)

    // MARK: - The format tag, and the two directions of reading across a layout change
    //
    // THE LAYOUT ALREADY CHANGED ONCE UNDER READERS THAT COULD NOT TELL: the conversation and the
    // directory swapped places, and neither direction of that swap is a parse failure on its own. A
    // reader of the current layout takes an OLD record's path as the conversation, does not
    // recognise it as one, and reports the session as unnamed - so it drops out of the live set and
    // the next launch here may resume the transcript it is writing, which is the Critical this whole
    // file exists to prevent, arriving through the reader (codex review of ea8816e). The tag on line
    // 1 is what makes both directions refuse instead.
    //
    // ASSERTED AS THE WHOLE RECORD, not as `?.id`: this fixture is exactly the shape the old layout
    // wrote, and a reader that mangled only the directory would satisfy an id-only assertion while
    // filing the session under a directory nothing will ever ask about.
    check("a record in the layout before the tag is no record",
          parseUnmanagedLaunch("\(mine.startedAt)\n\(hereResolved)\nconv-abc\n", pid: mine.pid)
              == nil)
    check("…and neither is the current layout with the tag missing",
          parseUnmanagedLaunch("\(mine.startedAt)\nconv-abc\n\(hereResolved)\n", pid: mine.pid)
              == nil)
    check("…nor a tag this build does not know",
          parseUnmanagedLaunch("tally-unmanaged-9\n\(mine.startedAt)\nconv-abc\n\(hereResolved)\n",
                               pid: mine.pid) == nil)
    // THE OTHER DIRECTION, which no assertion here can run because that reader is in a build that
    // has shipped: a reader from before the tag reads line 1 as an `Int64` start time. So what makes
    // it refuse a record written today is that line 1 cannot BE one, and that is a property of the
    // bytes this writer emits rather than of any code in this tree.
    check("every record written today names its format on line 1",
          formatUnmanagedLaunch(record).hasPrefix("\(unmanagedLaunchFormat)\n"))
    check("…and that line is not a number, so a reader from before it refuses the record",
          Int64(unmanagedLaunchFormat) == nil)

    // THE DIRECTORY IS ABSOLUTE OR THE RECORD IS CORRUPT. Every path written here went through
    // `realpathString`, so a value that does not start with a separator did not come from this
    // program - the id line of some other layout, or a half-written file. Opaque does not mean
    // unconstrained.
    check("a record whose directory is not an absolute path is no record",
          parseUnmanagedLaunch("\(unmanagedLaunchFormat)\n\(mine.startedAt)\nconv-abc\nconv-def\n",
                               pid: mine.pid) == nil)
    check("…including one that is merely relative",
          parseUnmanagedLaunch("\(unmanagedLaunchFormat)\n\(mine.startedAt)\nconv-abc\n../repo\n",
                               pid: mine.pid) == nil)

    // THE PATH IS BYTES, NOT A FIELD TO TIDY. Every line used to be trimmed, so a directory whose
    // name ends in a space came back as a DIFFERENT directory and the session in it stayed invisible
    // to the live set - the failure the record exists to prevent, arriving through the reader. A
    // newline is the same class, which is why the path is written last and read as everything after
    // the id rather than as one line among three.
    // Named rather than derived from the path, so an assertion that goes red is greppable and does
    // not change its own name with the temporary directory it ran in.
    //
    // THE WHITESPACE IS INSIDE THE PATH, not in front of it: the leading-space case used to be a
    // space before the separator, which is a RELATIVE path and no longer a record at all now that
    // the reader requires an absolute one. What it was actually asserting - that the reader does not
    // trim the path the way it trims the two constrained fields - is unchanged by moving the space
    // one character to the right, where a real directory whose name begins with a space puts it.
    for (shape, odd) in [("a trailing space", "\(hereResolved)/project "),
                         ("an interior tab", "\(hereResolved)/tab\tstop"),
                         ("an embedded newline", "\(hereResolved)/two\nlines"),
                         ("a leading space in its last component", "\(hereResolved)/ leading")] {
        let awkward = UnmanagedLaunch(claudeCode: mine, cwd: odd, id: "conv-odd")
        check("a directory name with \(shape) round-trips exactly",
              parseUnmanagedLaunch(formatUnmanagedLaunch(awkward), pid: mine.pid) == awkward)
        writeUnmanagedLaunch(awkward, dir: dir)
        check("…and the live set finds the session in a directory with \(shape)",
              unmanagedConversations(in: odd, dir: dir) == ["conv-odd"])
    }
    try? FileManager.default.removeItem(at: unmanagedLaunchFile(pid: mine.pid, dir: dir))
    writeUnmanagedLaunch(record, dir: dir)

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

    // MARK: - A session recording itself, whatever launched it
    //
    // THE ENUMERATION THAT WAS WRONG. The first version of this channel was keyed on an environment
    // marker the launcher exported, so it could only ever describe the sessions the launcher started
    // - while `claude` also starts from the PATH shim, which execs the real binary without entering
    // this program at all, and from somebody typing `claude` on a machine with no shim. Addressing
    // is by ANCESTRY now: the process that ran this status line is the process writing the
    // transcript, which is true however the session began.

    let reportDir = root.appendingPathComponent("reported")
    adoptUnmanagedConversation(sessionID: "conv-shim", cwd: here.path, claudeCode: mine,
                               dir: reportDir)
    check("a session nothing launched through Tally records itself",
          readUnmanagedLaunch(pid: mine.pid, dir: reportDir)
              == UnmanagedLaunch(claudeCode: mine, cwd: hereResolved, id: "conv-shim"))
    check("…and the live set can see it",
          unmanagedConversations(in: here.path, dir: reportDir) == ["conv-shim"])

    // A LAUNCH'S OWN RECORD KEEPS ITS DIRECTORY. The launch directory is what the transcript is
    // filed under; the one a render reports moves with a `cd`.
    let keptDir = root.appendingPathComponent("kept")
    writeUnmanagedLaunch(UnmanagedLaunch(claudeCode: mine, cwd: hereResolved, id: nil), dir: keptDir)
    adoptUnmanagedConversation(sessionID: "conv-three", cwd: elsewhere.path, claudeCode: mine,
                               dir: keptDir)
    check("a render names the conversation on the record the launch left",
          readUnmanagedLaunch(pid: mine.pid, dir: keptDir)?.id == "conv-three")
    check("…without moving the directory that record was written for",
          readUnmanagedLaunch(pid: mine.pid, dir: keptDir)?.cwd == hereResolved)

    // A record under OUR pid naming another process is a dead session's leftover, not somebody
    // else's: this pid is ours right now, so it is overwritten rather than protected.
    writeUnmanagedLaunch(UnmanagedLaunch(claudeCode: ProcessStamp(pid: mine.pid,
                                                                 startedAt: mine.startedAt - 1),
                                         cwd: elsewhere.path, id: "ended"), dir: keptDir)
    adoptUnmanagedConversation(sessionID: "conv-four", cwd: here.path, claudeCode: mine,
                               dir: keptDir)
    check("a record left by an ended session on the same pid is replaced",
          readUnmanagedLaunch(pid: mine.pid, dir: keptDir)
              == UnmanagedLaunch(claudeCode: mine, cwd: hereResolved, id: "conv-four"))

    // Nothing to say, or nothing that can be a transcript, touches no disk at all.
    let silent = root.appendingPathComponent("silent")
    adoptUnmanagedConversation(sessionID: nil, cwd: here.path, claudeCode: mine, dir: silent)
    adoptUnmanagedConversation(sessionID: "../../evil", cwd: here.path, claudeCode: mine,
                               dir: silent)
    adoptUnmanagedConversation(sessionID: "conv-five", cwd: here.path, claudeCode: nil, dir: silent)
    check("a render with nothing usable to say writes nothing",
          !FileManager.default.fileExists(atPath: silent.path))

    // WRITES MUST BE RARE: a render can happen several times a second and the value only changes
    // when the conversation does.
    //
    // The file is left in place and marked instead of being taken away: removing it would make the
    // "is there a record at all" guard answer for this check, and the two would be indistinguishable.
    // The padding parses to the same record and is exactly what a rewrite would canonicalise away.
    let padded = "\(unmanagedLaunchFormat)\n\(mine.startedAt)\nsteady   \n\(hereResolved)\n"
    try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
    try? padded.write(to: unmanagedLaunchFile(pid: mine.pid, dir: reportDir), atomically: true,
                      encoding: .utf8)
    adoptUnmanagedConversation(sessionID: "steady", cwd: here.path, claudeCode: mine, dir: reportDir)
    check("a render that would say nothing new writes nothing",
          (try? String(contentsOf: unmanagedLaunchFile(pid: mine.pid, dir: reportDir),
                       encoding: .utf8)) == padded)
    adoptUnmanagedConversation(sessionID: "moved-on", cwd: here.path, claudeCode: mine,
                               dir: reportDir)
    check("…and one that would say something new writes it",
          readUnmanagedLaunch(pid: mine.pid, dir: reportDir)?.id == "moved-on")

    // CREATING A RECORD SWEEPS, which is once per session rather than once per render, and is what
    // bounds this directory on a machine that never launches through Tally at all.
    let sweptDir = root.appendingPathComponent("swept")
    writeUnmanagedLaunch(UnmanagedLaunch(claudeCode: ProcessStamp(pid: deadPID, startedAt: 1),
                                         cwd: hereResolved, id: "long-gone"), dir: sweptDir)
    adoptUnmanagedConversation(sessionID: "conv-new", cwd: here.path, claudeCode: mine,
                               dir: sweptDir)
    check("a session recording itself for the first time sweeps the dead",
          !FileManager.default.fileExists(atPath:
              unmanagedLaunchFile(pid: deadPID, dir: sweptDir).path))

    // MARK: - Only where no supervisor is watching
    //
    // The two channels composed (`publishConversationIdentity`), which is the rule the status line
    // runs and the reason it is a function rather than two calls at a `Never`-returning entry point.
    // Over-naming would be harmless - the live set is a union of ids - so this is about the directory
    // staying tidy, and about a supervised session having exactly one witness track.

    let bothState = root.appendingPathComponent("supervisors-both")
    let bothUnmanaged = root.appendingPathComponent("unmanaged-both")
    let marker = String(mine.pid)
    // The cheap supervised shape: the marker's own report already says exactly this, so the
    // supervised half answers "owned" without needing the corroboration walk.
    writeTranscriptIdentity(TranscriptIdentity(id: "conv-sup", claudeCode: mine), pid: marker,
                            dir: bothState)
    publishConversationIdentity(sessionID: "conv-sup", cwd: here.path, claudeCode: mine,
                                marker: marker, dir: bothState, unmanagedDir: bothUnmanaged)
    check("a supervised session records nothing in the unsupervised directory",
          !FileManager.default.fileExists(atPath: bothUnmanaged.path))
    // No marker at all: the shim, or a hand-typed `claude`.
    publishConversationIdentity(sessionID: "conv-bare", cwd: here.path, claudeCode: mine,
                                marker: nil, dir: bothState, unmanagedDir: bothUnmanaged)
    check("a session with no supervisor to tell records itself",
          readUnmanagedLaunch(pid: mine.pid, dir: bothUnmanaged)?.id == "conv-bare")
    // A marker INHERITED from the session this one was started inside: live, but it addresses a
    // supervisor whose child is somebody else, so the corroboration refuses and this session is
    // unsupervised after all.
    let inheritedUnmanaged = root.appendingPathComponent("unmanaged-inherited")
    let inheritedState = root.appendingPathComponent("supervisors-inherited")
    markSupervisorLive(pid: marker, dir: inheritedState)
    writeSupervisorCwd(here.path, pid: marker, dir: inheritedState)
    // A REAL CHILD OF THIS PROCESS, because that is the only pid `readSupervisorChild` will admit:
    // it requires the process to be running AND to be the parent's own child, so a dead pid or a
    // stranger's reads back as "cannot say" - the one answer that would let the marker through, and
    // would make this check assert the opposite of what it says.
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    let spawned = (try? sleeper.run()) != nil
    check("the inherited-marker fixture has a live child of its own to name", spawned)
    writeSupervisorChild(sleeper.processIdentifier, pid: marker, dir: inheritedState)
    check("…which the addressing can actually read back",
          readSupervisorChild(pid: marker, dir: inheritedState)
              == Int(sleeper.processIdentifier))
    publishConversationIdentity(sessionID: "conv-inner", cwd: here.path, claudeCode: mine,
                                marker: marker, dir: inheritedState,
                                unmanagedDir: inheritedUnmanaged)
    check("a session carrying another session's marker records itself",
          readUnmanagedLaunch(pid: mine.pid, dir: inheritedUnmanaged)?.id == "conv-inner")
    check("…and publishes nothing onto that other session's supervisor",
          readTranscriptIdentity(pid: marker, dir: inheritedState) == nil)
    sleeper.terminate()

    // MARK: - The launcher end is actually wired
    //
    // Asserted from the source, the way the supervised channel's two ends are: `launchProvider` is a
    // `Never`-returning entry point that execs, so nothing in this suite can call it. It is no longer
    // the only way a session is recorded, and it is still the only one that covers the window before
    // the first render.

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
