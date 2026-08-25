import Foundation

// The session telling its supervisor which conversation it is in (TranscriptIdentity.swift), which
// is what replaces the mtime guess three separate defects grew out of.
//
// Claude Code hands its status-line command a JSON object on every render, carrying `session_id` and
// `transcript_path`. Tally's status line IS that command, so the answer arrives on its own, from the
// process doing the writing. The two sides are asserted separately: what a render publishes (and,
// just as important, when it publishes NOTHING), and what a supervisor does with it.

func runTranscriptIdentityChecks() {
    // MARK: - 35a. The report file

    /// A fixture process: a start time derived from the pid, so every invented process has a
    /// DISTINCT one without any check having to spell it out.
    func syntheticStart(_ pid: pid_t) -> Int64 { Int64(pid) * 1_000 }
    func synthetic(_ pid: pid_t) -> ProcessStamp {
        ProcessStamp(pid: pid, startedAt: syntheticStart(pid))
    }

    check("a report parses into the conversation and the process that drew it",
          parseTranscriptIdentity("fa4677f4-e618\n4242\n4242000\n")
              == TranscriptIdentity(id: "fa4677f4-e618", claudeCode: synthetic(4242)))
    check("no trailing newline is fine",
          parseTranscriptIdentity("conv-1\n99\n99000")?.claudeCode == synthetic(99))
    check("an id with no pid is no report", parseTranscriptIdentity("conv-1\n") == nil)
    check("a pid with no id is no report", parseTranscriptIdentity("\n4242\n4242000") == nil)
    check("a report naming something that cannot be a transcript is no report",
          parseTranscriptIdentity("../../etc/passwd\n4242\n4242000") == nil)
    check("and neither is one whose pid is not a number",
          parseTranscriptIdentity("conv-1\nlater\n4242000") == nil)
    // Zero is not a process anyone can be the child of, and it is what a truncated or half-written
    // second line reads as.
    check("a zero pid is no report", parseTranscriptIdentity("conv-1\n0\n4242000") == nil)
    check("and a start time that is not a number is no report",
          parseTranscriptIdentity("conv-1\n4242\nlater") == nil)
    check("nor is one that is zero", parseTranscriptIdentity("conv-1\n4242\n0") == nil)

    // THE COMPATIBILITY CLAIM, in both directions (parseTranscriptIdentity states why only one of
    // them is free): an older reader keeps its two lines, and this one refuses a report that has
    // only those two rather than inventing the field it is missing.
    check("a report from before the start time existed is no report to this reader",
          parseTranscriptIdentity("conv-1\n4242\n") == nil)
    let roundTrip = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-identity-\(UUID().uuidString)")
    check("a session with no report reads as nil",
          readTranscriptIdentity(pid: "4242", dir: roundTrip) == nil)
    writeTranscriptIdentity(TranscriptIdentity(id: "conv-1", claudeCode: synthetic(77)),
                            pid: "4242", dir: roundTrip)
    let body = (try? String(contentsOf: transcriptIdentityFile(pid: "4242", dir: roundTrip),
                            encoding: .utf8)) ?? ""
    let bodyLines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    check("the conversation and the pid keep the lines an older reader takes them from",
          bodyLines.count > 2 && bodyLines[0] == "conv-1" && bodyLines[1] == "77"
              && bodyLines[2] == "77000")
    check("a written report round-trips",
          readTranscriptIdentity(pid: "4242", dir: roundTrip)
              == TranscriptIdentity(id: "conv-1", claudeCode: synthetic(77)))
    check("and it is addressed to one session only",
          readTranscriptIdentity(pid: "9999", dir: roundTrip) == nil)
    // The document joins the family the state directory sweeps, or a dead session's copy would
    // outlive it and be read by whatever takes the pid next.
    check("the sweep recognises this document as one of ours",
          supervisorStatePid(ofFile: "4242" + transcriptIdentitySuffix) == 4242)
    sweepDeadSupervisorState(dir: roundTrip)
    check("…so a dead supervisor's report is swept",
          readTranscriptIdentity(pid: "4242", dir: roundTrip) == nil)
    try? FileManager.default.removeItem(at: roundTrip)

    // MARK: - 35a2. Which process ran the status line

    // THE PARENT IS THE ANSWER ONLY WHEN NOBODY CUSTOMISED ANYTHING: a user who already had a status
    // line gets ours registered with a `||` in it, which the shell must stay alive to finish, so
    // `getppid()` is that shell (measured 2026-08-08; claudeCodeThatRanUs states the whole rule).
    //
    // The table is injected because these chains cannot be built out of real processes: the point is
    // the SHAPE of an ancestry, and a test that had to spawn a shell to spawn a shell would be
    // asserting the fixture. The real reader is asserted against this process further down.
    func ancestry(_ chain: [(pid_t, pid_t, String)])
        -> (pid_t) -> (parent: pid_t, name: String, startedAt: Int64)? {
        let table = Dictionary(uniqueKeysWithValues: chain.map {
            ($0.0, (parent: $0.1, name: $0.2, startedAt: syntheticStart($0.0)))
        })
        return { table[$0] }
    }
    // Claude Code's own executable name is its version (measured 2026-08-08: `2.1.226`), which is
    // the one thing the walk needs of it - that it is not a shell.
    let plain = ancestry([(700, 600, "2.1.226"), (600, 1, "tally")])
    check("with no wrapper the status line's parent is the answer",
          claudeCodeThatRanUs(from: { 700 }, process: plain) == synthetic(700))
    let wrapped = ancestry([(701, 700, "sh"), (700, 600, "2.1.226"), (600, 1, "tally")])
    check("a wrapped status line reports the Claude Code above the shell that ran it",
          claudeCodeThatRanUs(from: { 701 }, process: wrapped) == synthetic(700))
    check("…and it carries that process's start time, not only its number",
          claudeCodeThatRanUs(from: { 701 }, process: wrapped)?.startedAt == syntheticStart(700))
    let twoShells = ancestry([(702, 701, "bash"), (701, 700, "zsh"), (700, 600, "2.1.226")])
    check("…however many shells stand in between",
          claudeCodeThatRanUs(from: { 702 }, process: twoShells) == synthetic(700))
    // THE WALK STOPS AT THE FIRST NON-SHELL, and that is the safety rather than an optimisation: a
    // bare `claude` started from inside a supervised session has the OUTER Claude Code further up
    // this same chain, and a search that climbed until it matched a supervisor's child would publish
    // the inner conversation onto the outer session. Here the inner one is not a supervisor's child
    // at all, and the walk still stops at it - so the corroboration below refuses, as it must.
    let nestedChain = ancestry([(703, 702, "sh"), (702, 701, "2.1.226"), (701, 700, "zsh"),
                                (700, 600, "2.1.226")])
    check("the walk stops at the process that ran us, not at the first supervised one",
          claudeCodeThatRanUs(from: { 703 }, process: nestedChain) == synthetic(702))
    // Refusals, each publishing nothing rather than guessing.
    var deepChain: [(pid_t, pid_t, String)] = (0..<12).map {
        (pid_t(800 + $0), pid_t(801 + $0), "zsh")
    }
    deepChain.append((812, 1, "2.1.226"))
    let deepShells = ancestry(deepChain)
    check("an ancestry of shells deeper than the limit is no answer",
          claudeCodeThatRanUs(from: { 800 }, process: deepShells) == nil)
    check("…and it is the limit that refuses rather than the chain running out",
          claudeCodeThatRanUs(from: { 800 }, limit: 20, process: deepShells) == synthetic(812))
    let orphaned = ancestry([(704, 1, "sh"), (1, 0, "launchd")])
    check("a shell reparented to launchd is no answer",
          claudeCodeThatRanUs(from: { 704 }, process: orphaned) == nil)
    check("a process that cannot be read is no answer",
          claudeCodeThatRanUs(from: { 999_999 }, process: ancestry([])) == nil)

    // TWO OBSERVATIONS, AND THEY HAVE TO AGREE. A walk is a sequence of separate readings, so a
    // descheduled render can splice the OLD pid onto the NEW process's start time and produce a
    // stamp that is valid for a conversation it knows nothing about (claudeCodeThatRanUs states the
    // race). Both fixtures below reproduce it by changing something BETWEEN the passes, which a
    // static table cannot express - hence readers that answer differently on later calls.
    var passes = 0
    func counting() -> pid_t { passes += 1; return 701 }
    check("a stable ancestry answers, and it took two passes to say so",
          claudeCodeThatRanUs(from: counting, process: wrapped) == synthetic(700) && passes == 2)
    // The parent exits between the passes. The kernel reparents us to launchd the instant it does,
    // so the very reading the splice depends on is the one that gives it away.
    var readings = 0
    func reparented() -> pid_t { readings += 1; return readings == 1 ? 701 : 1 }
    check("an ancestry that lost its Claude Code between the passes is no answer",
          claudeCodeThatRanUs(from: reparented, process: wrapped) == nil)
    // The other half: the pid still reads, but the process wearing it is now the successor.
    var lookups = 0
    func recycling(_ pid: pid_t) -> (parent: pid_t, name: String, startedAt: Int64)? {
        lookups += 1
        switch pid {
        case 701: return (parent: 700, name: "sh", startedAt: syntheticStart(701))
        case 700: return (parent: 600, name: "2.1.226",
                          startedAt: syntheticStart(700) + (lookups > 2 ? 1 : 0))
        default: return nil
        }
    }
    check("a pid that changed hands between the passes is refused rather than spliced",
          claudeCodeThatRanUs(from: { 701 }, process: recycling) == nil)
    // The real reader, against the one process this suite can be certain about.
    check("the kernel reading names this process's own parent",
          processIdentity(getpid())?.parent == getppid())
    check("…and a pid nobody is using reads as nothing", processIdentity(999_999) == nil)
    // THE START TIME IS A FACT ABOUT THE PROCESS, not about the reading: two readings of the same
    // live pid have to agree, or comparing them would refuse this session's own child every tick.
    check("…and a live process's start time is the same on every reading",
          processStamp(getpid()) != nil && processStamp(getpid()) == processStamp(getpid()))
    check("…while this process and its parent do not share one",
          processStamp(getpid())?.startedAt != processStamp(getppid())?.startedAt)
    check("a test binary is not a shell, so the walk stops on it",
          claudeCodeThatRanUs(from: getpid) == processStamp(getpid()))

    // MARK: - 35b. What one render publishes, and when it publishes nothing

    // The addressing is the prompt hooks' own rule (`SessionMarkerTrust.corroborated`), and a status
    // line is in the strongest position to satisfy it: the Claude Code that ran it is the one whose
    // conversation it reports, which is the pid each supervisor publishes about its own child.
    //
    // THE FIXTURE STANDS IN FOR THAT PAIR with two REAL processes, because the witnesses are read
    // from the live process table rather than from anything a test can fake: this process is the
    // "Claude Code", and its own parent is the "supervisor". `readSupervisorChild` demands exactly
    // that relationship (alive, and its parent is the supervisor), so nothing here is stubbed.
    let claudeCodePID = getpid()
    let claudeCode = processStamp(claudeCodePID)!
    let supervisor = String(getppid())
    let writeDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-identity-write-\(UUID().uuidString)")
    let projectCwd = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-identity-cwd-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: projectCwd, withIntermediateDirectories: true)
    markSupervisorLive(pid: supervisor, dir: writeDir)
    writeSupervisorCwd(projectCwd.path, pid: supervisor, dir: writeDir)
    writeSupervisorChild(claudeCodePID, pid: supervisor, dir: writeDir)

    reportTranscriptIdentity(sessionID: "conv-1", cwd: projectCwd.path, claudeCode: claudeCode,
                             marker: supervisor, dir: writeDir)
    check("a render publishes the conversation it drew for",
          readTranscriptIdentity(pid: supervisor, dir: writeDir)
              == TranscriptIdentity(id: "conv-1", claudeCode: claudeCode))

    // WRITES MUST BE RARE: a render can happen several times a second, and the value only changes
    // when the conversation does. A second render saying the same thing must not touch the disk at
    // all, which is asserted the only way it can be - the file does not move.
    let published = transcriptIdentityFile(pid: supervisor, dir: writeDir)
    let ageMark = Date(timeIntervalSince1970: 1_800_000_000)
    try! FileManager.default.setAttributes([.modificationDate: ageMark],
                                           ofItemAtPath: published.path)
    reportTranscriptIdentity(sessionID: "conv-1", cwd: projectCwd.path, claudeCode: claudeCode,
                             marker: supervisor, dir: writeDir)
    let unchanged = (try? FileManager.default.attributesOfItem(atPath: published.path))?[.modificationDate] as? Date
    check("a render that would say the same thing does not write at all", unchanged == ageMark)
    // …and one that has something new to say does.
    reportTranscriptIdentity(sessionID: "conv-2", cwd: projectCwd.path, claudeCode: claudeCode,
                             marker: supervisor, dir: writeDir)
    check("a `/clear` is published on the very next render",
          readTranscriptIdentity(pid: supervisor, dir: writeDir)?.id == "conv-2")

    // THE WRAPPED REGISTRATION, END TO END. This is the one a user with a status line of their own
    // gets, and before the walk above it published NOTHING for them: the shell in between failed the
    // corroboration, silently, with the mtime guess left in place and no symptom anywhere. The
    // ancestry is injected and the supervisor pair is real, so what is asserted is the join between
    // them - and the published stamp being the INJECTED start time is how it is visible that the
    // report carries what the walk found rather than a second, separate reading.
    let throughShell = ancestry([(90001, 90002, "sh"), (90002, claudeCodePID, "zsh"),
                                 (claudeCodePID, pid_t(supervisor) ?? 1, "2.1.226")])
    reportTranscriptIdentity(sessionID: "conv-wrapped", cwd: projectCwd.path,
                             claudeCode: claudeCodeThatRanUs(from: { 90001 }, process: throughShell),
                             marker: supervisor, dir: writeDir)
    check("a status line wrapping the user's own still publishes its conversation",
          readTranscriptIdentity(pid: supervisor, dir: writeDir)
              == TranscriptIdentity(id: "conv-wrapped", claudeCode: synthetic(claudeCodePID)))

    // NOTHING TO TELL, AND NOBODY TO TELL IT TO. An unsupervised `claude` running Tally's status
    // line has no marker, and that is where this path stops - before it touches the disk at all.
    let bare = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-identity-bare-\(UUID().uuidString)")
    reportTranscriptIdentity(sessionID: "conv-1", cwd: projectCwd.path, claudeCode: claudeCode,
                             marker: nil, dir: bare)
    check("an unsupervised session publishes nothing",
          !FileManager.default.fileExists(atPath: bare.path))
    reportTranscriptIdentity(sessionID: nil, cwd: projectCwd.path, claudeCode: claudeCode,
                             marker: supervisor, dir: bare)
    check("a payload with no session id publishes nothing either",
          !FileManager.default.fileExists(atPath: bare.path))
    reportTranscriptIdentity(sessionID: "../../evil", cwd: projectCwd.path,
                             claudeCode: claudeCode, marker: supervisor, dir: bare)
    check("and neither does one naming something that cannot be a transcript",
          !FileManager.default.fileExists(atPath: bare.path))
    // NO ANSWER IS NOT A LICENCE TO GUESS. An ancestry the walk cannot read out ends the render
    // here, one guard earlier than everything below it.
    reportTranscriptIdentity(sessionID: "conv-1", cwd: projectCwd.path,
                             claudeCode: claudeCodeThatRanUs(from: { 90001 }, process: ancestry([])),
                             marker: supervisor, dir: bare)
    check("a render that cannot tell which Claude Code ran it publishes nothing",
          !FileManager.default.fileExists(atPath: bare.path))
    // AND NEITHER IS A CHAIN WITH NOBODY'S CHILD ON IT. The walk answers - it is simply not a
    // process this supervisor is running, so the addressing refuses exactly as it does for a marker
    // inherited from another session.
    let stranger = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-identity-stranger-\(UUID().uuidString)")
    markSupervisorLive(pid: supervisor, dir: stranger)
    writeSupervisorCwd(projectCwd.path, pid: supervisor, dir: stranger)
    writeSupervisorChild(claudeCodePID, pid: supervisor, dir: stranger)
    let strangerChain = ancestry([(90001, 90003, "sh"), (90003, 1, "2.1.226")])
    reportTranscriptIdentity(sessionID: "conv-1", cwd: projectCwd.path,
                             claudeCode: claudeCodeThatRanUs(from: { 90001 }, process: strangerChain),
                             marker: supervisor, dir: stranger)
    check("a render whose ancestry holds no supervisor's child publishes nothing",
          readTranscriptIdentity(pid: supervisor, dir: stranger) == nil)
    try? FileManager.default.removeItem(at: stranger)

    // THE MARKER IS NOT ENOUGH BY ITSELF, which is the whole reason the addressing is shared with
    // the prompt hooks. A `claude` launched from inside another supervised session inherits that
    // session's marker, so a render there would publish onto a conversation it has nothing to do
    // with. Here the marked supervisor is running a DIFFERENT child and is watching a different
    // conversation: both witnesses disagree, so nothing is written.
    let nested = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-identity-nested-\(UUID().uuidString)")
    markSupervisorLive(pid: supervisor, dir: nested)
    writeSupervisorCwd(projectCwd.path, pid: supervisor, dir: nested)
    // A child pid that is alive but is NOT this process, and whose parent is not the supervisor:
    // launchd will do, and it says "this supervisor is running somebody else".
    try! "1".write(to: supervisorChildFile(pid: supervisor, dir: nested), atomically: true,
                   encoding: .utf8)
    writeSessionContext(SupervisedSession(accountID: "A", contextTokens: 1, updatedAt: Date(),
                                          sessionPin: nil, axes: SessionAxes(),
                                          transcript: "somebody-elses-conversation"),
                        pid: supervisor, dir: nested)
    reportTranscriptIdentity(sessionID: "conv-1", cwd: projectCwd.path, claudeCode: claudeCode,
                             marker: supervisor, dir: nested)
    check("an inherited marker does not let a render publish onto another session",
          readTranscriptIdentity(pid: supervisor, dir: nested) == nil)
    try? FileManager.default.removeItem(at: nested)
    try? FileManager.default.removeItem(at: bare)
    try? FileManager.default.removeItem(at: writeDir)
    try? FileManager.default.removeItem(at: projectCwd)

    // MARK: - 35c. What the supervisor does with it

    /// The scene every defect in this family started from: two fresh sessions in one project
    /// directory, ours quiet and the sibling mid-turn, so the mtime heuristic that `bindFile` falls
    /// back to picks the WRONG file. Nothing is resumed, so nothing else can correct it.
    func twoSessions(_ label: String) -> ForkFixture {
        let fixture = ForkFixture(label)
        fixture.write("ours.jsonl", [fixture.marker(own: "ours", launched: "ours")],
                      born: 10, wrote: 100)
        fixture.write("sibling.jsonl", [fixture.marker(own: "sibling", launched: "sibling")],
                      born: 20, wrote: 200)
        return fixture
    }

    let stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-identity-read-\(UUID().uuidString)")
    let child = synthetic(4242)

    /// A watcher for that scene, with whatever report the session has published so far.
    func supervised(_ fixture: ForkFixture, key: String, report: TranscriptIdentity?)
        -> TranscriptWatcher {
        if let report { writeTranscriptIdentity(report, pid: key, dir: stateDir) }
        var watcher = TranscriptWatcher(projectDir: fixture.dir, since: fixture.launchedAt)
        watcher.auditLog = testAuditLog
        adoptReportedTranscript(watcher: &watcher, sessionKey: key, child: child, dir: stateDir)
        return watcher
    }

    // THE POINT OF THE WHOLE FEATURE: the heuristic would take the sibling, and it never gets to.
    let reported = twoSessions("reported")
    var bound = supervised(reported, key: "5001",
                           report: TranscriptIdentity(id: "ours", claudeCode: child))
    check("a reported conversation is bound without the heuristic ever choosing",
          bound.file?.lastPathComponent == "ours.jsonl")
    check("…and the id a relaunch would resume is ours, not the newest file in the directory",
          bound.resumeID == "ours")
    check("…so the binding is a fact rather than a guess, from the first tick",
          bound.boundByEvidence)
    // The join key follows, which is what takes the fifth layer's fuel away: latched from a guessed
    // binding it would name the stranger, and the stranger's own stamped turns would then read as
    // this session's forks.
    check("…and the join key is resolved from it too", bound.launchKey(boundTo: "ours") == "ours")
    bound.locateFile(forceForkCheck: true)
    check("…so the scan does not walk it over to the sibling", bound.file?.lastPathComponent == "ours.jsonl")

    // THE SHORT WINDOW: before the first render there is no report, and the behaviour has to be
    // exactly what it is today, heuristic and all. This is the case the feature deliberately does
    // not cover, so it is asserted rather than assumed.
    let unreported = twoSessions("unreported")
    var guessing = supervised(unreported, key: "5002", report: nil)
    guessing.locateFile()
    check("with nothing reported yet the heuristic still picks the newest file",
          guessing.file?.lastPathComponent == "sibling.jsonl")
    check("…and that binding is still, correctly, a guess", !guessing.boundByEvidence)

    // A report naming a conversation with no transcript here binds nothing: there would be nothing
    // to tail, and a relaunch would resume an id with nothing behind it.
    let missing = twoSessions("missing-file")
    var missingWatcher = supervised(missing, key: "5003",
                                    report: TranscriptIdentity(id: "ghost", claudeCode: child))
    check("a report naming a file that is not here binds nothing", missingWatcher.file == nil)
    missingWatcher.locateFile()
    check("…and the session falls back to exactly what it does today",
          missingWatcher.file?.lastPathComponent == "sibling.jsonl")

    // A report from a Claude Code this supervisor is no longer running is stale by construction: it
    // survives a relaunch that started a FRESH conversation, and binding it would tail a transcript
    // nobody is writing.
    let stale = twoSessions("stale-child")
    let staleWatcher = supervised(stale, key: "5004",
                                  report: TranscriptIdentity(id: "ours",
                                                             claudeCode: synthetic(child.pid + 1)))
    check("a report from a child this supervisor has replaced is ignored", staleWatcher.file == nil)

    // A `/clear` is the case the hold was built for, and the report answers it outright: the new
    // transcript has no turn in it yet, so nothing IN the file can prove whose it is.
    let cleared = twoSessions("cleared")
    var clearedWatcher = supervised(cleared, key: "5005",
                                    report: TranscriptIdentity(id: "ours", claudeCode: child))
    cleared.write("after-clear.jsonl", cleared.clearedLines(own: "after-clear"),
                  born: 300, wrote: 400)
    check("the session is on its conversation before the clear",
          clearedWatcher.file?.lastPathComponent == "ours.jsonl")
    writeTranscriptIdentity(TranscriptIdentity(id: "after-clear", claudeCode: child),
                            pid: "5005", dir: stateDir)
    adoptReportedTranscript(watcher: &clearedWatcher, sessionKey: "5005", child: child,
                            dir: stateDir)
    check("the next render moves it onto the cleared conversation",
          clearedWatcher.file?.lastPathComponent == "after-clear.jsonl"
              && clearedWatcher.resumeID == "after-clear")
    check("…with nothing held open about it any more", !clearedWatcher.hasUnresolvedFork)
    check("…so a relaunch resumes what the user is actually looking at",
          relaunchArgs(["--model", "fable"], sessionID: clearedWatcher.resumeID, sameAccount: true)
              == ["--resume", "after-clear", "--model", "fable"])

    // MARK: - 35d. A report and a request in the same tick

    // The supervisor takes the report FIRST, so by the time a request is read the origin is a fact -
    // and the request is judged against it exactly as the previous rounds decided (only forward,
    // interlock guard intact). A `/tally-account` typed before a `/clear` therefore moves the
    // account without dragging the conversation back to where it was typed.
    let both = twoSessions("report-and-request")
    both.write("after-clear.jsonl", both.clearedLines(own: "after-clear"), born: 300, wrote: 400)
    var bothWatcher = supervised(both, key: "5006",
                                 report: TranscriptIdentity(id: "after-clear",
                                                            claudeCode: child))
    check("the report binds the conversation the user is in now",
          bothWatcher.file?.lastPathComponent == "after-clear.jsonl")
    check("a request naming the conversation it was typed in does not drag the watcher back",
          !adoptRequestedTranscript("ours", watcher: &bothWatcher, sessionKey: "5006"))
    check("…and the request is still about a session that is where the report put it",
          bothWatcher.file?.lastPathComponent == "after-clear.jsonl")
    // The other order of the same pair: a request naming what the report already bound is a no-op
    // rather than a second move.
    check("a request naming the reported conversation moves nothing",
          !adoptRequestedTranscript("after-clear", watcher: &bothWatcher, sessionKey: "5006"))

    // MARK: - 35e. A new child does not inherit the last one's report

    // WHAT THE VOIDING ACTUALLY PROMISES, stated as the state it leaves rather than as a defect it
    // prevents: after a spawn there is no report on file. The fixture hands the reader a stamp it
    // would otherwise ACCEPT, so what is asserted here is the voiding and not the comparison next
    // door.
    let recycled = twoSessions("recycled-pid")
    writeTranscriptIdentity(TranscriptIdentity(id: "ours", claudeCode: child), pid: "5007",
                            dir: stateDir)
    check("the previous child's report is on file",
          readTranscriptIdentity(pid: "5007", dir: stateDir) != nil)
    clearTranscriptIdentity(pid: "5007", dir: stateDir)     // what every spawn does
    check("the spawn leaves no report behind it",
          readTranscriptIdentity(pid: "5007", dir: stateDir) == nil)
    var recycledWatcher = TranscriptWatcher(projectDir: recycled.dir, since: recycled.launchedAt)
    recycledWatcher.auditLog = testAuditLog
    check("…so there is nothing for the new child to adopt",
          !adoptReportedTranscript(watcher: &recycledWatcher, sessionKey: "5007", child: child,
                                   dir: stateDir))
    check("…so a new child starts on nothing rather than on the conversation it replaced",
          recycledWatcher.file == nil)
    // Idempotent: a first launch has no report to void, and the removal is best-effort.
    clearTranscriptIdentity(pid: "5007", dir: stateDir)
    check("voiding a report that is not there is not an error",
          readTranscriptIdentity(pid: "5007", dir: stateDir) == nil)
    writeTranscriptIdentity(TranscriptIdentity(id: "ours", claudeCode: child), pid: "5008",
                            dir: stateDir)
    clearTranscriptIdentity(pid: "5007", dir: stateDir)
    check("…and one session's spawn does not void another session's report",
          readTranscriptIdentity(pid: "5008", dir: stateDir)?.id == "ours")

    // THE WINDOW THE VOIDING CANNOT CLOSE, which the previous round's commit message claimed it did
    // (codex review of 4b4454a): an unlink cannot beat a rename already in flight, so the ended
    // child's report comes back and a reused pid makes it read as the successor's own. Written AFTER
    // the void here, which is a REPRODUCTION of the losing race rather than a hypothetical.
    let ghost = twoSessions("late-write")
    clearTranscriptIdentity(pid: "5009", dir: stateDir)                      // the spawn
    let replaced = ProcessStamp(pid: child.pid, startedAt: child.startedAt)  // the ended child
    let successor = ProcessStamp(pid: child.pid, startedAt: child.startedAt + 1)
    check("the successor took the ended child's pid back", replaced.pid == successor.pid)
    writeTranscriptIdentity(TranscriptIdentity(id: "ours", claudeCode: replaced), pid: "5009",
                            dir: stateDir)                                   // the late rename
    var ghostWatcher = TranscriptWatcher(projectDir: ghost.dir, since: ghost.launchedAt)
    ghostWatcher.auditLog = testAuditLog
    check("a report that landed after the spawn is refused even on a reused pid",
          !adoptReportedTranscript(watcher: &ghostWatcher, sessionKey: "5009", child: successor,
                                   dir: stateDir))
    check("…so the ended conversation does not become the new child's",
          ghostWatcher.file == nil)
    // And the same report IS taken by the child that actually wrote it, or the refusal above would
    // be a refusal of everything rather than of the wrong process.
    var ownWatcher = TranscriptWatcher(projectDir: ghost.dir, since: ghost.launchedAt)
    ownWatcher.auditLog = testAuditLog
    check("…while the child that wrote it is still bound by it",
          adoptReportedTranscript(watcher: &ownWatcher, sessionKey: "5009", child: replaced,
                                  dir: stateDir)
              && ownWatcher.file?.lastPathComponent == "ours.jsonl")
    try? FileManager.default.removeItem(at: stateDir)

    // MARK: - 35f. Both ends are actually wired

    // The two calls that make this a channel rather than a library. Asserted from the sources they
    // live in, because nothing else in this suite can see them: the status line is a `Never`-
    // returning entry point and the supervisor's loop needs a live child to run.
    let statusline = (try? String(contentsOfFile: "TallyCLI/Statusline.swift", encoding: .utf8)) ?? ""
    check("the statusline source is readable from the suite", !statusline.isEmpty)
    check("the status line reports what Claude Code told it",
          statusline.contains("let reportedSession = sessionJSON?[\"session_id\"] as? String")
              && statusline.contains("reportTranscriptIdentity(sessionID: reportedSession"))
    // The unsupervised half of the same job (UnmanagedLaunch.swift), wired from the same render and
    // handed the same walk up the process tree: asking twice would pay for that climb twice on a
    // path that runs on every interaction.
    check("…and tells an unsupervised launch's own record as well",
          statusline.contains("reportUnmanagedConversation(sessionID: reportedSession"))
    check("…off one reading of which Claude Code ran it",
          statusline.contains("let ranBy = claudeCodeThatRanUs()")
              && statusline.contains("claudeCode: ranBy)"))
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the identity checks", !loop.isEmpty)
    if let adopt = loop.range(of: "adoptReportedTranscript("),
       let capScan = loop.range(of: "observeCapHit(") {
        // BEFORE the first gate that reads the watcher, which is what leaves `bindFile` with
        // nothing to do: by the time anything asks, the watcher is already on the right file.
        check("the supervisor takes the report before anything reads the watcher",
              adopt.lowerBound < capScan.lowerBound)
    } else {
        check("both the adoption and the cap scan were found in the loop", false)
    }
    // A PID WOULD COMPILE HERE, and it is what shipped: the reader has to be handed a process.
    check("the supervisor identifies its child by process, not by pid",
          loop.contains("child: processStamp(childPID)"))
    if let void = loop.range(of: "clearTranscriptIdentity(pid: supervisorPID)"),
       let spawn = loop.range(of: "spawnChild(") {
        // THE ORDER IS THE GUARD. Voided after the spawn, the pid the file names could already have
        // been handed to the child that spawn just started, and the removal would be undoing a
        // report that has become true.
        check("a child is spawned only after the last one's report is voided",
              void.lowerBound < spawn.lowerBound)
    } else {
        check("both the voiding and the spawn were found in the loop", false)
    }
}
