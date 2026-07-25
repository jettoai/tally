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

    // MARK: - 20. Relaunch arguments

    // A relaunch resumes the located session id. With no id (nothing written since launch) it depends
    // on where it lands: a MOVE drops --continue so it cannot open an unrelated conversation on the
    // other account, while a SAME-account relaunch keeps it - stripping it there restarted
    // `tally claude --continue` into an empty session instead of the one the user resumed.
    check("a located session is resumed by id",
          relaunchArgs(["--continue", "--model", "fable"], sessionID: "abc", sameAccount: true)
          == ["--resume", "abc", "--model", "fable"])
    check("resuming replaces an older --resume pair",
          relaunchArgs(["--resume", "old", "--model", "fable"], sessionID: "new", sameAccount: false)
          == ["--resume", "new", "--model", "fable"])
    check("a same-account relaunch with no transcript keeps --continue",
          relaunchArgs(["--continue", "--model", "fable"], sessionID: nil, sameAccount: true)
          == ["--continue", "--model", "fable"])
    check("the -c spelling is kept as well",
          relaunchArgs(["-c"], sessionID: nil, sameAccount: true) == ["--continue"])
    check("a move with no transcript drops --continue",
          relaunchArgs(["--continue", "--model", "fable"], sessionID: nil, sameAccount: false)
          == ["--model", "fable"])
    check("nothing is invented when the launch never asked to continue",
          relaunchArgs(["--model", "fable"], sessionID: nil, sameAccount: true) == ["--model", "fable"])
    check("a dangling --resume value is not left behind",
          relaunchArgs(["--resume", "old", "--verbose"], sessionID: nil, sameAccount: true)
          == ["--verbose"])

    // MARK: - 21. A pending cap across a relaunch

    // A capped session with no sibling to take it is quiet by definition, so a reload always
    // restarts it - and the new watcher reads the old cap event as history. Only the reload hands
    // the pending recovery over; every other reason starts the next child clean, as before.
    let capped = PendingCapRecovery(cappedAccountID: "acct-1", cappedAt: launch,
                                    primaryModel: "fable", nextRetry: launch, reason: "waiting")
    check("a reload relaunch carries the pending cap",
          capCarriedAcrossRelaunch(capped, reason: "reload")?.cappedAccountID == "acct-1")
    check("a cap handoff does not (it just moved account)",
          capCarriedAcrossRelaunch(capped, reason: "cap") == nil)
    check("a fallback pairing does not (the situation changed)",
          capCarriedAcrossRelaunch(capped, reason: "fallback") == nil)
    check("a follow adoption does not",
          capCarriedAcrossRelaunch(capped, reason: "follow") == nil)
    check("a pin switch does not",
          capCarriedAcrossRelaunch(capped, reason: "pin") == nil)
    check("a degradation rescue does not",
          capCarriedAcrossRelaunch(capped, reason: "degraded") == nil)
    check("nothing pending stays nothing pending",
          capCarriedAcrossRelaunch(nil, reason: "reload") == nil)

    // MARK: - 23. Supervisor self-update after an app update

    // The gates, in the order they bite. `captured` is the version this supervisor started on and
    // `installed` what the bundle reports NOW (verified live: a running process sees the new value
    // the moment the bundle is replaced under it), so a LATER installed version means the app
    // updated underneath us and this process is running stale logic.
    let clear = { (captured: String?, installed: String?, quiet: Bool, planned: Bool,
                   cap: Bool, uptime: TimeInterval, attempted: String?) in
        selfUpdateTarget(captured: captured, installed: installed, isQuiet: quiet,
                         relaunchPlanned: planned, capPending: cap, uptime: uptime,
                         attempted: attempted)
    }
    check("everything clear upgrades to the installed version",
          clear("0.25.0", "0.26.0", true, false, false, 300, nil) == "0.26.0")
    check("the same version is nothing to do",
          clear("0.26.0", "0.26.0", true, false, false, 300, nil) == nil)
    // Newer, not merely different. The exec is one-way (the child is already gone), and an older
    // build has no `__resupervise`: it would print the usage text, exit, and take the session with
    // it. An older DMG installed over the top, or a Release rebuilt from an earlier checkout, is
    // exactly this case, and a bundle alternating between two versions would exec on every tick.
    check("an older installed build is never exec'd into",
          clear("0.26.0", "0.25.0", true, false, false, 300, nil) == nil)
    check("versions compare by component, not as strings",
          clear("0.9.0", "0.10.0", true, false, false, 300, nil) == "0.10.0")
    check("and not the other way round",
          clear("0.10.0", "0.9.0", true, false, false, 300, nil) == nil)
    check("a longer version string beats its own prefix",
          clear("0.26", "0.26.1", true, false, false, 300, nil) == "0.26.1")
    check("equal after padding is still nothing to do",
          clear("0.26", "0.26.0", true, false, false, 300, nil) == nil)
    check("a version we cannot parse stays put",
          clear("0.25.0", "0.26.0-beta", true, false, false, 300, nil) == nil)
    check("no installed version (mid-install, or no bundle) waits",
          clear("0.25.0", nil, true, false, false, 300, nil) == nil)
    check("a dev build with no captured version never self-updates",
          clear(nil, "0.26.0", true, false, false, 300, nil) == nil)
    check("neither version known does nothing",
          clear(nil, nil, true, false, false, 300, nil) == nil)
    check("a session mid-turn waits",
          clear("0.25.0", "0.26.0", false, false, false, 300, nil) == nil)
    check("a relaunch already planned this tick waits",
          clear("0.25.0", "0.26.0", true, true, false, 300, nil) == nil)
    // A capped session is holding state (which account capped, when to retry) that an exec would
    // drop, and it is quiet by definition, so it would upgrade instantly if this gate were missing.
    check("a pending cap recovery waits",
          clear("0.25.0", "0.26.0", true, false, true, 300, nil) == nil)
    check("a child younger than the loop-safety floor waits",
          clear("0.25.0", "0.26.0", true, false, false, selfUpdateMinUptime - 1, nil) == nil)
    check("exactly at the floor is allowed",
          clear("0.25.0", "0.26.0", true, false, false, selfUpdateMinUptime, nil) == "0.26.0")
    // Loop safety: a bundle that still reports the old version after the exec would otherwise have
    // every generation exec again. The target the last exec aimed for is never attempted twice.
    check("the target a previous exec already tried is not tried again",
          clear("0.25.0", "0.26.0", true, false, false, 300, "0.26.0") == nil)
    check("but a genuinely newer version still upgrades",
          clear("0.25.0", "0.26.1", true, false, false, 300, "0.26.0") == "0.26.1")

    // The argv that carries continuity across the exec: the account is named so the new supervisor
    // cannot re-pick, and the child args (already carrying --resume <session>) ride after the "--".
    check("the exec argv names the account and pins the conversation",
          selfUpdateArgv(binary: "/usr/local/bin/tally", id: "acct-2", label: "Claude 2",
                         home: "/Users/x/.claude2", follow: true,
                         args: ["--resume", "abc", "--model", "fable"])
          == ["/usr/local/bin/tally", resuperviseCommand, "--id", "acct-2", "--label", "Claude 2",
              "--home", "/Users/x/.claude2", "--follow", "--", "--resume", "abc", "--model", "fable"])
    check("an opted-out session stays opted out across the upgrade",
          selfUpdateArgv(binary: "/usr/local/bin/tally", id: "a", label: "A", home: "/h",
                         follow: false, args: []).contains("--no-follow"))
    check("the separator is present even with no child args",
          selfUpdateArgv(binary: "/usr/local/bin/tally", id: "a", label: "A", home: "/h",
                         follow: true, args: []).last == "--")

    // The two halves of that contract are written by DIFFERENT builds, so they are tested as a round
    // trip: what one version writes, the next version's parser must read back unchanged. `dropFirst`
    // removes the binary path and the subcommand, which main.swift consumes before parsing.
    func roundTrip(id: String, label: String, home: String, follow: Bool,
                   args: [String]) -> (id: String, label: String, home: String,
                                       follow: Bool, childArgs: [String]) {
        parseResuperviseArgs(Array(selfUpdateArgv(binary: "/usr/local/bin/tally", id: id,
                                                  label: label, home: home, follow: follow,
                                                  args: args).dropFirst(2)))
    }
    let trip = roundTrip(id: "acct-2", label: "Claude 2", home: "/Users/x/.claude2", follow: true,
                         args: ["--resume", "abc", "--model", "fable"])
    check("the account survives the round trip", trip.id == "acct-2" && trip.label == "Claude 2")
    check("the home survives the round trip", trip.home == "/Users/x/.claude2")
    check("follow survives the round trip", trip.follow)
    check("the child args survive the round trip",
          trip.childArgs == ["--resume", "abc", "--model", "fable"])
    check("--no-follow survives the round trip",
          roundTrip(id: "a", label: "A", home: "/h", follow: false, args: []).follow == false)
    // A label is whatever the previous build wrote, including something that looks like a flag: the
    // value is taken positionally, never re-parsed. An account labelled "--home" must not be able to
    // redirect the session into another config home.
    let flagLabel = roundTrip(id: "a", label: "--home", home: "/real/home", follow: true,
                              args: ["--model", "fable"])
    check("a label that looks like a flag is still a label", flagLabel.label == "--home")
    check("and it does not hijack the home", flagLabel.home == "/real/home")
    check("nor swallow the child args", flagLabel.childArgs == ["--model", "fable"])
    // Malformed input from a build that wrote a different shape: parse what is there, resume with
    // no child args, and let the supervisor's own --home guard decide whether it can run at all.
    check("a missing separator yields no child args",
          parseResuperviseArgs(["--id", "a", "--label", "A", "--home", "/h", "--follow"])
              .childArgs.isEmpty)
    check("but everything before it is still read",
          parseResuperviseArgs(["--id", "a", "--label", "A", "--home", "/h"]).home == "/h")
    check("a trailing separator yields no child args",
          parseResuperviseArgs(["--home", "/h", "--"]).childArgs.isEmpty)
    check("a dangling flag value is empty, not a crash",
          parseResuperviseArgs(["--home"]).home.isEmpty)
    check("follow defaults to on when the flag is absent",
          parseResuperviseArgs(["--home", "/h"]).follow)

    // What the tick actually asks: gates, plus a real executable and a home, all answered before the
    // caller kills anything. Versions are injected so this runs outside a bundle.
    func due(binary: String?, home: String?, attempted: String? = nil)
        -> (target: String, binary: String, home: String)? {
        selfUpdateDue(captured: "0.25.0", attempted: attempted, isQuiet: true,
                      relaunchPlanned: false, capPending: false, uptime: 300, home: home,
                      installed: "0.26.0", binary: binary)
    }
    check("a clear tick with a real binary and a home upgrades",
          due(binary: "/bin/ls", home: "/h")?.target == "0.26.0")
    check("and it hands back the binary and home it checked",
          due(binary: "/bin/ls", home: "/h").map { $0.binary == "/bin/ls" && $0.home == "/h" } == true)
    check("no executable to exec means no upgrade this tick", due(binary: nil, home: "/h") == nil)
    check("no home to pass means no upgrade at all", due(binary: "/bin/ls", home: nil) == nil)
    check("an already-attempted target is still refused here",
          due(binary: "/bin/ls", home: "/h", attempted: "0.26.0") == nil)

    // The exec target is checked for real BEFORE the child is terminated: a bundle caught mid-install
    // costs a skipped tick, never the session's child.
    check("a real executable is accepted", selfUpdateBinary("/bin/ls") == "/bin/ls")
    check("a path with nothing at it is refused", selfUpdateBinary("/nonexistent/tally") == nil)
    check("no path at all is refused", selfUpdateBinary(nil) == nil)
    let plainFile = NSTemporaryDirectory() + "tally-not-executable-\(getpid())"
    FileManager.default.createFile(atPath: plainFile, contents: Data("x".utf8))
    check("a file that is not executable is refused", selfUpdateBinary(plainFile) == nil)
    try? FileManager.default.removeItem(atPath: plainFile)

    // MARK: - 22. The follow dead end must not swallow the tick

    // Structural, because the bug was control flow, not a value: the dead-end path used to
    // `continue`, which skipped every later block in the same tick - the reload request against a
    // session waiting on an unservable model was not even acknowledged. The adoption now leaves via
    // its label. A pure function cannot hold this invariant, so the source carries it: reintroducing
    // a bare `continue` anywhere in the follow block fails here instead of silently starving reload.
    // Run from the repo root (run-supervisor-tests.sh cds there), and a missing file FAILS rather
    // than quietly passing.
    let supervisorSource = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift",
                                        encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the suite", !supervisorSource.isEmpty)
    let followStart = supervisorSource.range(of: "followAdoption: if follow {")
    check("the follow adoption is a labeled block", followStart != nil)
    if let followStart,
       let followEnd = supervisorSource.range(of: "// The session's ACTUAL model degraded",
                                              range: followStart.upperBound ..< supervisorSource.endIndex) {
        let block = String(supervisorSource[followStart.upperBound ..< followEnd.lowerBound])
        check("the dead end leaves the adoption, not the tick",
              block.contains("break followAdoption"))
        check("no bare continue skips the rest of the tick",
              block.range(of: #"(?<![-"])\bcontinue\b"#, options: .regularExpression) == nil)
    } else {
        check("the follow block boundaries were found", false)
    }
}
