import Foundation

// What a relaunch carries: the args it resumes with, the pending cap it hands over, the self-update
// exec's gates and argv, and the tick's control flow around the follow dead end. Split out of
// reloadchecks.swift for file size and called in place from `runReloadChecks`, so the assertion
// order and the output are unchanged. The tick fixtures these borrow travel as parameters rather
// than moving, because 19f3 (which builds them) stays behind.

func runRelaunchChecks(account tickAccount: Snapshot.Account,
                       watcher tickWatcher: inout TranscriptWatcher, t0 tickT0: Date) {
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
                                    primaryModel: "fable", recoveryResetsAt: nil,
                                    nextRetry: launch, reason: "waiting")
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
                   recoveries: [Date] = [], pinOverride: String? = nil,
                   args: [String]) -> (id: String, label: String, home: String, follow: Bool,
                                       recoveries: [Date], pinOverride: String?,
                                       childArgs: [String]) {
        parseResuperviseArgs(Array(selfUpdateArgv(binary: "/usr/local/bin/tally", id: id,
                                                  label: label, home: home, follow: follow,
                                                  recoveries: recoveries, pinOverride: pinOverride,
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

    // The pin a `tally switch` took this session off rides across the same way the fuse does, and
    // for the same reason: it is a promise about the SESSION, held in memory only, and a new image
    // that started without it would hand the conversation straight back to the pin its user had
    // just moved it away from - minutes later, for no reason they could see (SessionSwitch.swift).
    let overridden = roundTrip(id: "a", label: "A", home: "/h", follow: true,
                               pinOverride: "acct-pinned", args: ["--resume", "abc"])
    check("an overridden pin survives the round trip", overridden.pinOverride == "acct-pinned")
    check("and does not disturb what rode with it",
          overridden.home == "/h" && overridden.childArgs == ["--resume", "abc"])
    check("the flag is only written when there is an override",
          !selfUpdateArgv(binary: "/usr/local/bin/tally", id: "a", label: "A", home: "/h",
                          follow: true, args: []).contains(resupervisePinOverrideFlag))
    check("a session that never overrode a pin reads back as none",
          roundTrip(id: "a", label: "A", home: "/h", follow: true, args: []).pinOverride == nil)
    // The contract is between BUILDS: an older one never writes this flag, and the parser has to
    // keep meaning "no override" when it is absent rather than inventing one.
    check("an argv from a build predating the flag parses as no override",
          parseResuperviseArgs(["--id", "a", "--label", "A", "--home", "/h", "--follow",
                                "--", "--resume", "abc"]).pinOverride == nil)
    check("and everything that build DID write still arrives",
          parseResuperviseArgs(["--id", "a", "--label", "A", "--home", "/h", "--follow",
                                "--", "--resume", "abc"]).childArgs == ["--resume", "abc"])
    // An empty value is a disagreement about the format, not an override of "": read it the way a
    // build that never wrote the flag would be read.
    check("an empty override value is no override",
          parseResuperviseArgs(["--home", "/h", resupervisePinOverrideFlag, ""]).pinOverride == nil)
    // Positional, like the label: an override that looks like a flag cannot redirect anything.
    let flagOverride = roundTrip(id: "a", label: "A", home: "/real/home", follow: true,
                                 pinOverride: "--home", args: [])
    check("an override that looks like a flag is still an override",
          flagOverride.pinOverride == "--home" && flagOverride.home == "/real/home")
    // Both optional flags at once, since they are written in sequence and a run-on would eat one.
    let both = roundTrip(id: "a", label: "A", home: "/h", follow: true,
                         recoveries: [Date(timeIntervalSince1970: 1_800_000_000)],
                         pinOverride: "acct-pinned", args: ["--resume", "abc"])
    check("the fuse and the override ride together",
          both.recoveries == [Date(timeIntervalSince1970: 1_800_000_000)]
              && both.pinOverride == "acct-pinned" && both.childArgs == ["--resume", "abc"])

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
    // MARK: - 23b. The recovery fuse survives the self-update exec

    // "At most 3 automatic recoveries in 10 minutes" is a promise about the SESSION, and the exec
    // replaces the process. Reachable in one sitting before this carry existed: two recoveries
    // spent, the account not capped at that instant (nothing gates the upgrade), the app updates,
    // the fuse resets, and the same conversation can be restarted three more times.
    let fuseT0 = Date(timeIntervalSince1970: 1_800_000_000)
    var spentFuse = RecoveryFuse(max: 3, window: 600)
    for _ in 0 ..< 3 { _ = spentFuse.allows(now: fuseT0); spentFuse.record(now: fuseT0) }
    check("a fuse with 3 recoveries in the window refuses a fourth", !spentFuse.allows(now: fuseT0))
    let carriedTrip = roundTrip(id: "a", label: "A", home: "/h", follow: true,
                                recoveries: spentFuse.carried(now: fuseT0),
                                args: ["--resume", "abc"])
    check("the argv round trip carries the recorded recoveries",
          carriedTrip.recoveries == [fuseT0, fuseT0, fuseT0])
    check("carrying the fuse does not disturb the rest of the contract",
          carriedTrip.home == "/h" && carriedTrip.follow
              && carriedTrip.childArgs == ["--resume", "abc"])
    var afterExec = RecoveryFuse(max: 3, window: 600, recovered: carriedTrip.recoveries,
                                 now: fuseT0)
    check("a fuse with 3 recent recoveries still refuses after the round trip",
          !afterExec.allows(now: fuseT0))
    // Absolute times, not durations: the exec takes real time (longer on a disk mid-install), and
    // a duration re-based on arrival would hand the session a window that starts over.
    var afterSlowExec = RecoveryFuse(max: 3, window: 600, recovered: carriedTrip.recoveries,
                                     now: fuseT0.addingTimeInterval(601))
    check("recoveries that aged out during a slow exec do not extend the window",
          afterSlowExec.allows(now: fuseT0.addingTimeInterval(601)))

    // Pruned before encoding: an entry past the window is dead weight the other side would drop
    // anyway, and shipping it invites reading the list as a count rather than as times.
    var staleFuse = RecoveryFuse(max: 3, window: 600)
    staleFuse.record(now: fuseT0)                                  // expired by the time we encode
    staleFuse.record(now: fuseT0.addingTimeInterval(400))          // still inside the window
    let pruned = staleFuse.carried(now: fuseT0.addingTimeInterval(700))
    check("entries older than the window do not survive the encoding",
          pruned == [fuseT0.addingTimeInterval(400)])
    check("and the flag value carries only the live one",
          encodeRecoveryFuse(pruned) == String(fuseT0.addingTimeInterval(400).timeIntervalSince1970))

    // A supervisor started normally is unchanged: no flag written, none read, a fresh fuse.
    check("an empty fuse writes no flag at all",
          !selfUpdateArgv(binary: "/usr/local/bin/tally", id: "a", label: "A", home: "/h",
                          follow: true, args: []).contains(resuperviseFuseFlag))
    check("a supervisor started without __resupervise begins with an empty fuse",
          roundTrip(id: "a", label: "A", home: "/h", follow: true, args: []).recoveries.isEmpty)
    var freshFuse = RecoveryFuse(max: 3, window: 600, recovered: [], now: fuseT0)
    check("and that fuse still allows its full budget", freshFuse.allows(now: fuseT0))

    // Written by a DIFFERENT build, so an unreadable value is a disagreement about the format, not
    // something to half-believe: degrade to a fresh fuse rather than to an arbitrary count.
    check("a malformed fuse argument degrades to an empty fuse",
          parseResuperviseArgs(["--home", "/h", resuperviseFuseFlag, "not-a-time"])
              .recoveries.isEmpty)
    check("one bad field discards the whole value",
          decodeRecoveryFuse("1800000000,,1800000001").isEmpty)
    check("a non-finite field is not a time either", decodeRecoveryFuse("inf").isEmpty)
    check("an empty value is simply no recoveries", decodeRecoveryFuse("").isEmpty)
    check("a dangling fuse flag is empty, not a crash",
          parseResuperviseArgs(["--home", "/h", resuperviseFuseFlag]).recoveries.isEmpty)
    check("and it does not swallow the home",
          parseResuperviseArgs([resuperviseFuseFlag, "1800000000", "--home", "/h"]).home == "/h")

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
    // The adoption is now a function of its own (FollowAdoption.swift), which makes the same
    // invariant structural instead of conventional: abandoning it is a plain `return`, and a
    // `continue` that would skip the rest of the tick cannot compile outside a loop at all. The
    // check follows the code, and gains the half the label could never express - that the tick
    // really does go on to handle the reload after the adoption gives up.
    let followSource = (try? String(contentsOfFile: "TallyCLI/FollowAdoption.swift",
                                    encoding: .utf8)) ?? ""
    check("the follow adoption source is readable from the suite", !followSource.isEmpty)
    check("the dead end leaves the adoption, not the tick",
          followSource.contains("state.deadEnd = true") && followSource.contains("return"))
    check("no bare continue skips the rest of the tick",
          followSource.range(of: #"(?<![-"])\bcontinue\b"#, options: .regularExpression) == nil)
    if let followCall = supervisorSource.range(of: "applyFollowAdoption("),
       let reloadCall = supervisorSource.range(of: "applyReloadRequest(") {
        check("and a reload request is still handled after it, dead end or not",
              followCall.lowerBound < reloadCall.lowerBound)
    } else {
        check("both calls were found in the tick", false)
    }

    // The fuse carry is only real if the loop is wired to both ends of it, and neither end can be
    // reached without spawning a child, so the source carries the invariant (as above).
    check("the loop seeds its fuse from the carried recoveries",
          supervisorSource.contains("RecoveryFuse(recovered: recoveries)"))
    check("and hands the live fuse to the exec",
          supervisorSource.contains("recoveries: fuse.carried()"))

    // The account re-pick a reload restart carries for free (reloadrepickchecks.swift).
    runReloadRepickChecks(account: tickAccount, watcher: &tickWatcher, t0: tickT0)
}
