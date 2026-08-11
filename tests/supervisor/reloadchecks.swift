import Foundation

// The `tally reload` half of the supervisor assertions, split out of main.swift for file size.
// Top-level statements can only live in main.swift, so these run as one function it calls; the
// harness (`check`, `failures`) is shared from there.

func runReloadChecks() {
    // MARK: - 19. `tally reload`

    // 19a. The request file format: a unix timestamp on line 1, an optional "now" marker on line 2.
    // Anything unparseable is nil (no request), never epoch 0 - a truncated write must not read as an
    // ancient reload that every supervisor would then ignore forever.
    check("a plain stamp parses", parseReloadRequest("1800000000\n") == ReloadRequest(epoch: 1_800_000_000, immediate: false))
    check("a stamp with no trailing newline parses",
          parseReloadRequest("1800000000") == ReloadRequest(epoch: 1_800_000_000, immediate: false))
    check("the now marker parses",
          parseReloadRequest("1800000000\nnow\n") == ReloadRequest(epoch: 1_800_000_000, immediate: true))
    check("surrounding whitespace is tolerated",
          parseReloadRequest(" 1800000000 \n now ") == ReloadRequest(epoch: 1_800_000_000, immediate: true))
    check("an empty body is no request", parseReloadRequest("") == nil)
    check("a garbage body is no request", parseReloadRequest("reload please\n") == nil)
    check("a marker with no stamp is no request", parseReloadRequest("\nnow\n") == nil)

    // 19b. Write -> read roundtrip through a real file (a missing file is simply no request).
    let reloadDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-reload-\(UUID().uuidString)")
    let reloadPath = reloadDir.appendingPathComponent("reload")
    let reloadAt = Date(timeIntervalSince1970: 1_800_000_042)
    check("a request that was never made reads as nil", readReloadRequest(from: reloadPath) == nil)
    try! writeReloadRequest(reloadAt, immediate: false, to: reloadPath)
    check("a written request round-trips",
          readReloadRequest(from: reloadPath) == ReloadRequest(epoch: 1_800_000_042, immediate: false))
    try! writeReloadRequest(reloadAt, immediate: true, to: reloadPath)
    check("--now round-trips",
          readReloadRequest(from: reloadPath) == ReloadRequest(epoch: 1_800_000_042, immediate: true))
    try? FileManager.default.removeItem(at: reloadDir)

    // 19c. The quiet bar: a plain request waits for the same "left alone" bar a follow adoption uses;
    // --now settles for the streaming check.
    check("a plain reload waits for the follow idle bar", reloadIdleBar(immediate: false) == followIdleSeconds)
    check("--now uses the short quiet bar", reloadIdleBar(immediate: true) == reloadNowIdleSeconds)
    check("the short bar is genuinely shorter", reloadNowIdleSeconds < followIdleSeconds)

    // 19d. The tick decision: only a strictly newer stamp acts, a planned relaunch absorbs the request
    // instead of queueing a second one, a busy session waits, and recording the stamp stops it firing
    // again on every following tick.
    check("no request does nothing",
          reloadDecision(captured: 100, requested: nil, relaunchPlanned: false, isQuiet: true) == .none)
    check("the same stamp does not re-fire",
          reloadDecision(captured: 100, requested: 100, relaunchPlanned: false, isQuiet: true) == .none)
    check("an older stamp is ignored",
          reloadDecision(captured: 100, requested: 99, relaunchPlanned: false, isQuiet: true) == .none)
    check("a newer stamp on an idle session relaunches",
          reloadDecision(captured: 100, requested: 101, relaunchPlanned: false, isQuiet: true) == .relaunch)
    check("a newer stamp on a busy session queues",
          reloadDecision(captured: 100, requested: 101, relaunchPlanned: false, isQuiet: false) == .queued)
    check("a relaunch already planned absorbs the request",
          reloadDecision(captured: 100, requested: 101, relaunchPlanned: true, isQuiet: true) == .fold)
    check("a plan absorbs it even mid-turn (the child restarts anyway)",
          reloadDecision(captured: 100, requested: 101, relaunchPlanned: true, isQuiet: false) == .fold)
    // What the supervisor does after acting: it records the stamp it just served.
    let served = 101
    check("a served request does not repeat",
          reloadDecision(captured: served, requested: 101, relaunchPlanned: false, isQuiet: true) == .none)
    check("but a later request still fires",
          reloadDecision(captured: served, requested: 102, relaunchPlanned: false, isQuiet: true) == .relaunch)

    // 19e. The live-supervisor registry behind both surfaces (the CLI's report line and the Settings
    // row's count): one file per supervisor pid, dead pids and non-pid files ignored (the same liveness
    // probe the drift badge uses). `dir` is injectable so this runs against fake state files.
    let countDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-reload-count-\(UUID().uuidString)")
    check("a missing registry lists no pids, rather than crashing",
          liveSupervisorPids(dir: countDir).isEmpty)
    markSupervisorLive(pid: String(getpid()), dir: countDir)
    markSupervisorLive(pid: "99999", dir: countDir)
    try! "notes".write(to: countDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    check("only live pids are listed: this process, not the impossible one",
          liveSupervisorPids(dir: countDir) == [getpid()])
    try? FileManager.default.removeItem(at: countDir)

    // 19f. The idle gate a request is held to. A missing transcript reads as quiet (there is no mtime
    // to inspect), so a session opened moments ago - the first prompt still being typed into it - would
    // be restarted the instant a request landed. Until a transcript exists the child's own age carries
    // the same bar.
    check("a quiet transcript passes the gate",
          reloadQuiet(transcriptQuiet: true, hasTranscript: true, childAge: 1, bar: 120))
    check("a busy transcript fails it whatever the age",
          !reloadQuiet(transcriptQuiet: false, hasTranscript: true, childAge: 9999, bar: 120))
    check("a session with no transcript yet is NOT idle just because the file is missing",
          !reloadQuiet(transcriptQuiet: true, hasTranscript: false, childAge: 3, bar: 120))
    check("a session with no transcript that has been up past the bar is idle",
          reloadQuiet(transcriptQuiet: true, hasTranscript: false, childAge: 121, bar: 120))
    check("--now shortens that wait too",
          reloadQuiet(transcriptQuiet: true, hasTranscript: false, childAge: 6, bar: 5))
    check("a busy session with no transcript never passes, however long it has been up",
          !reloadQuiet(transcriptQuiet: false, hasTranscript: false, childAge: 9999, bar: 120))
    check("--now's bar is the one reloadIdleBar hands out",
          reloadQuiet(transcriptQuiet: true, hasTranscript: false, childAge: 6,
                      bar: reloadIdleBar(immediate: true)))

    // MARK: - 19f2. A request that stays queued says so a second time

    // A queued request raises a badge once and then holds it unchanged for as long as it waits,
    // which is right for the minute a real turn takes and a lie for the rest: when the keyboard gate
    // could not open at all (2026-07-28), "reload at idle" was the last word a session ever said
    // about a reload it never performed. So the badge escalates once, at five minutes.
    var wait = ReloadWait()
    let waitT0 = Date(timeIntervalSince1970: 1_800_000_000)
    check("the tick a request is first held back raises the badge",
          reloadWaitNote(state: &wait, epoch: 7, now: waitT0) == .queued)
    check("the ticks after it leave it alone",
          reloadWaitNote(state: &wait, epoch: 7, now: waitT0.addingTimeInterval(2)) == .silent)
    check("still silent a second short of the line",
          reloadWaitNote(state: &wait, epoch: 7,
                         now: waitT0.addingTimeInterval(reloadStillWaitingAfter - 1)) == .silent)
    check("crossing it escalates once",
          reloadWaitNote(state: &wait, epoch: 7,
                         now: waitT0.addingTimeInterval(reloadStillWaitingAfter)) == .stillWaiting)
    check("and never again, however long the wait then runs",
          reloadWaitNote(state: &wait, epoch: 7, now: waitT0.addingTimeInterval(3600)) == .silent)
    // A second `tally reload` is a new request: its own first note, its own line, timed from when
    // IT was queued rather than from the one before it.
    check("a newer stamp raises its own badge again",
          reloadWaitNote(state: &wait, epoch: 8, now: waitT0.addingTimeInterval(3600)) == .queued)
    check("and is not treated as already reminded",
          reloadWaitNote(state: &wait, epoch: 8,
                         now: waitT0.addingTimeInterval(3600 + reloadStillWaitingAfter))
              == .stillWaiting)

    // What the escalated badge names: the gate that actually decided, read in the order
    // `reloadQuiet` reads them, so a session held by two of them is described by the first to say
    // no. Two lengths from one function, because the status line has a few characters and the
    // notice file's detail has a sentence, and they must never come to describe different gates.
    let writingReason = reloadWaitReason(transcriptQuiet: false, keyboardQuiet: false,
                                         hasTranscript: true, childAge: 9999, bar: 120)
    check("a session still writing is named first", writingReason.short == "session busy")
    check("and at length for the detail line",
          writingReason.full == "session or a subagent still writing")
    let keyboardReason = reloadWaitReason(transcriptQuiet: true, keyboardQuiet: false,
                                          hasTranscript: true, childAge: 9999, bar: 120)
    check("a quiet session held only by the keyboard names the keyboard",
          keyboardReason.short == "keyboard" && keyboardReason.full == "keyboard active")
    let youngReason = reloadWaitReason(transcriptQuiet: true, keyboardQuiet: true,
                                       hasTranscript: false, childAge: 3, bar: 120)
    check("a session too young to have written a transcript says that",
          youngReason.short == "starting up" && youngReason.full == "no transcript yet")
    // THE SHARED CLAUSE NAMES ALL OF WHAT THAT ARM MIGHT BE, which is the rule `QuietGate.transcript`
    // states about itself: one Bool covers a live turn, an unanswered tool call, an unresolved fork
    // and a subagent still writing (`TranscriptWatcher.isQuiet`), and a fork nobody has typed into
    // has no turn running at all - so a clause that named a turn was telling a person about
    // something that is not there (codex review of fe4462d). Vague on purpose, exactly as the reload
    // axis's own full form above is.
    check("the shared clause for that arm claims no particular one of them",
          quietGateHolding(.transcript) == "this session or a subagent is still writing")
    check("…and the other three arms still say what they are",
          quietGateHolding(.keyboard).contains("prompt")
              && quietGateHolding(.startup).contains("no turn yet")
              && quietGateHolding(.unknown).contains("in use"))
    // The short form has to survive being pasted into "reload waiting (...)" on a line that already
    // carries the quota meters.
    for reason in [writingReason, keyboardReason, youngReason] {
        check("the badge for \"\(reason.full)\" fits a status line",
              "reload waiting (\(reason.short))".count <= 32)
    }

    // MARK: - 19f3. The same thing through the tick itself

    // The keyboard is injected, so this runs on a machine with no terminal; the request is too, so
    // it touches no real ~/.tally. What is exercised here and nowhere else: that the answer the
    // supervisor's tracker gives really is what holds the request back, and that the stamp survives
    // being held so the reload still happens when the session frees up.
    let tickDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-reload-tick-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: tickDir, withIntermediateDirectories: true)
    let tickFile = tickDir.appendingPathComponent("session.jsonl")
    try! "{}".write(to: tickFile, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9999)],
                                           ofItemAtPath: tickFile.path)
    var tickWatcher = TranscriptWatcher(projectDir: tickDir, file: tickFile, since: launch)
    let tickAccount = Snapshot.Account(
        id: "A", provider: "claude", label: "A", launchHome: "/tmp/A", sessionRemaining: 90,
        weeklyRemaining: 90, modelRemaining: 90, sessionResetsAt: nil, weeklyResetsAt: nil,
        modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
        error: nil)
    let tickRequest = ReloadRequest(epoch: 101, immediate: false)
    var tickPlan: RelaunchPlan?
    var tickEpoch = 100
    var tickNotice = ReloadWait()
    let tickT0 = Date(timeIntervalSince1970: 1_800_000_000)
    func tick(keyboardIdle: @escaping (TimeInterval) -> Bool, at moment: Date) {
        applyReloadRequest(plan: &tickPlan, epoch: &tickEpoch, notice: &tickNotice,
                           account: tickAccount, watcher: &tickWatcher, childAge: 9999,
                           keyboardIdle: keyboardIdle, request: tickRequest, now: moment)
    }
    tick(keyboardIdle: { _ in false }, at: tickT0)
    check("a busy keyboard queues the request rather than relaunching", tickPlan == nil)
    check("and leaves the stamp unconsumed, so it can still fire later", tickEpoch == 100)
    check("the wait is being timed from this tick",
          tickNotice.epoch == 101 && tickNotice.since == tickT0)
    check("with no reminder given yet", !tickNotice.reminded)
    check("and a badge saying what is waiting",
          tickNotice.pending == PendingBadge("reload at idle"))
    tick(keyboardIdle: { _ in false }, at: tickT0.addingTimeInterval(2))
    check("a tick two seconds later adds nothing", !tickNotice.reminded)
    tick(keyboardIdle: { _ in false }, at: tickT0.addingTimeInterval(reloadStillWaitingAfter))
    check("five minutes in, the reminder has been given", tickNotice.reminded)
    check("and the badge has escalated to name the gate",
          tickNotice.pending?.badge == "reload waiting (keyboard)")
    check("with the full reason kept as the detail",
          tickNotice.pending?.detail?.contains("keyboard active") == true)
    check("and the request is still only queued", tickPlan == nil && tickEpoch == 100)
    tick(keyboardIdle: { _ in true }, at: tickT0.addingTimeInterval(reloadStillWaitingAfter + 2))
    check("once the keyboard goes still the queued request lands", tickPlan != nil)
    check("and the stamp is consumed so it fires exactly once", tickEpoch == 101)
    // The wait is over, so nothing may be left claiming otherwise: the badge outliving the thing it
    // describes is exactly the failure the status line has to avoid.
    check("the badge goes with it", tickNotice.pending == nil && tickNotice.epoch == nil)
    // A request file deleted out from under a queued wait is the other way the wait can end.
    var orphaned = ReloadWait(epoch: 5, since: tickT0, reminded: false,
                              pending: PendingBadge("reload at idle"))
    var orphanPlan: RelaunchPlan?
    var orphanEpoch = 4
    applyReloadRequest(plan: &orphanPlan, epoch: &orphanEpoch, notice: &orphaned,
                       account: tickAccount, watcher: &tickWatcher, childAge: 9999,
                       keyboardIdle: { _ in false }, request: nil, now: tickT0)
    check("a request that no longer exists takes its badge down too", orphaned.pending == nil)
    try? FileManager.default.removeItem(at: tickDir)

    // MARK: - 19g. Sessions from a build that cannot reload

    // A supervisor started before this feature registers nothing and polls no request file, so the
    // registry reads zero while sessions are plainly running (five of them, live, 2026-07-25). The
    // count stays honest - none of those will restart - and the probe exists so the MESSAGE can be.
    let probeNow = Date(timeIntervalSince1970: 1_800_000_000)
    func proc(_ pid: pid_t, _ name: String, age: TimeInterval, ppid: pid_t = 1) -> RunningProcess {
        RunningProcess(pid: pid, ppid: ppid, name: name,
                       startedAt: probeNow.addingTimeInterval(-age))
    }
    // Children carry the names the real ones report (measured 2026-07-25): a claude child is named
    // for its version, a homebrew codex for its build triple. They are here so each rejection below
    // is tested by the predicate it is about, not incidentally by the missing child.
    let scan = [
        proc(100, "tally", age: 3600),      // a session from an older build
        proc(1000, "2.1.220", age: 3590, ppid: 100),
        proc(101, "tally", age: 120),       // another
        proc(1001, "codex-aarch64-apple-darwin", age: 110, ppid: 101),
        proc(102, "tally", age: 2),         // the status line shelling out: far too young
        proc(1002, "sh", age: 1, ppid: 102),
        proc(103, "claude", age: 3600),     // a child, not a supervisor
        proc(104, "tallyx", age: 3600),     // a near miss on the name
        proc(1004, "2.1.220", age: 3590, ppid: 104),
        proc(105, "tally", age: 7200),      // registered: a current build, already counted
        proc(1005, "2.1.220", age: 7100, ppid: 105),
        proc(106, "tally", age: 7200),      // this process itself
        proc(1006, "2.1.220", age: 7100, ppid: 106),
    ]
    let legacy = legacySupervisorPids(scan, excluding: [105, 106], now: probeNow)
    check("older supervisors are found", legacy.contains(100) && legacy.contains(101))
    check("a passing statusline call is not a session", !legacy.contains(102))
    check("the claude child is not a supervisor", !legacy.contains(103))
    check("a name that merely starts with tally is not ours", !legacy.contains(104))
    check("a registered supervisor is not counted twice", !legacy.contains(105))
    check("this process and its ancestors are excluded", !legacy.contains(106))
    check("so the probe reports exactly the two", legacy.count == 2)
    check("the age floor is inclusive at its edge",
          legacySupervisorPids([proc(200, "tally", age: legacySupervisorMinAge),
                                proc(2000, "2.1.220", age: 1, ppid: 200)],
                               excluding: [], now: probeNow) == [200])
    check("and rejects one second under it",
          legacySupervisorPids([proc(201, "tally", age: legacySupervisorMinAge - 1),
                                proc(2001, "2.1.220", age: 1, ppid: 201)],
                               excluding: [], now: probeNow).isEmpty)

    // What makes a `tally` a supervisor is the child it parents. `tally worktree` and the worktree
    // picker sit in a raw-mode read for as long as the user takes to choose, far past the age
    // floor, so without this they would be reported as sessions needing a restart while they
    // supervise nothing.
    //
    // The child is matched structurally, never by name: the claude child renames itself to its
    // version and so is called something new every release, and a homebrew codex reports its build
    // triple. Requiring a child called "claude" or "codex" would have counted none of the eight
    // supervisors running when this was measured (2026-07-25), so both spellings appear below.
    check("a tally waiting on a menu, parenting nothing, is not a session",
          legacySupervisorPids([proc(300, "tally", age: 600)],
                               excluding: [], now: probeNow).isEmpty)
    check("the same process once it has launched a child named for its version is",
          legacySupervisorPids([proc(300, "tally", age: 600),
                                proc(3000, "2.1.220", age: 5, ppid: 300)],
                               excluding: [], now: probeNow) == [300])
    check("and a codex child named for its build triple counts the same",
          legacySupervisorPids([proc(303, "tally", age: 600),
                                proc(3003, "codex-aarch64-apple-darwin", age: 5, ppid: 303)],
                               excluding: [], now: probeNow) == [303])
    // The pairing is to THIS pid. Another supervisor's child elsewhere in the scan says nothing
    // about a tally that has none of its own.
    check("someone else's child does not promote an idle tally",
          legacySupervisorPids([proc(301, "tally", age: 600),
                                proc(3001, "2.1.220", age: 5, ppid: 999)],
                               excluding: [], now: probeNow).isEmpty)

    // The bound on the pid scan that feeds all of the above. `proc_listallpids` returns a COUNT of
    // pids from its second call, not the byte count its argument is given in, so reading it as
    // bytes inspected a quarter of the machine and hid any supervisor past that point (measured
    // 2026-07-25: 1010 pids returned against `ps -A`'s 1011 lines, where the byte reading stopped
    // at 252).
    check("the returned value is a pid count, not a byte count",
          scannedPidCount(1010, capacity: 1029) == 1010)
    check("exactly filling the buffer is not clamped away",
          scannedPidCount(1029, capacity: 1029) == 1029)
    // Processes launched between the sizing call and the fill can push the count past the buffer,
    // which would be a read out of bounds rather than a miscount.
    check("a count past the buffer is clamped to it", scannedPidCount(1200, capacity: 1029) == 1029)
    check("no pids is no scan", scannedPidCount(0, capacity: 1029) == 0)
    check("an error from libproc is no scan", scannedPidCount(-1, capacity: 1029) == 0)
    check("an empty buffer is never indexed", scannedPidCount(10, capacity: 0) == 0)

    // The three-way answer every surface reads. A registered session outranks a legacy one: it will
    // really restart, so that is the news.
    check("registered sessions are the ordinary case", reloadReadiness(live: 3, legacy: 0) == .ready(3))
    check("registered wins over legacy on a mixed machine",
          reloadReadiness(live: 1, legacy: 4) == .ready(1))
    check("nothing running is nothing running",
          reloadReadiness(live: 0, legacy: 0) == .nothingRunning)
    check("legacy only is its own state, with its own count",
          reloadReadiness(live: 0, legacy: 5) == .legacyOnly(5))

    // The sentence that state produces: what is true, then the one action. Singular and plural, and
    // the same text everywhere (the app passes L, the CLI takes the English as written).
    check("the legacy notice counts the sessions", reloadLegacyNotice(5).hasPrefix("5 sessions are running"))
    check("it says they cannot reload yet", reloadLegacyNotice(5).contains("cannot reload yet"))
    check("and its second sentence is the action",
          reloadLegacyNotice(5).contains("Restart each one once (exit, then launch again)"))
    check("one session reads as one", reloadLegacyNotice(1).hasPrefix("1 session is running"))
    check("with the singular action", reloadLegacyNotice(1).contains("Restart it once"))
    check("localization is applied to the whole sentence, not a fragment",
          reloadLegacyNotice(2, localize: { _ in "translated %d" }) == "translated 2")

    // What a relaunch carries: args, pending cap, self-update, control flow (relaunchchecks.swift).
    runRelaunchChecks(account: tickAccount, watcher: &tickWatcher, t0: tickT0)
    // And the half of a relaunch that is about the args rather than the account: no positional, so
    // no prompt is re-submitted (positionalchecks.swift).
    runPositionalChecks(account: tickAccount)
}
