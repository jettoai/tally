import Foundation

// The idle rebalance, split out for file size. Top-level statements can only live in main.swift, so
// these run as one function it calls; the harness (`check`, `failures`) and the fixed `launch` date
// are shared from there.
//
// The behaviour under test: the smart pick used to apply at launch and at cap handoff only, so a
// session placed well an hour ago rode its account all the way down (five sessions on an account
// whose flagship window was spent while a sibling held 77%, 2026-07-26). A session that is idle now
// makes the same move the cap handoff would make later, before the wall rather than after it.

func runRebalanceChecks() {
    // MARK: - 26. Which sessions move, and where to

    /// An account whose flagship window is the interesting one: session and weekly stay healthy, so
    /// `model` alone decides whether the account reads as dying for a fable session.
    func acct(_ id: String, model: Double, modelResetHours: Double = 100,
              provider: String = "claude", stale: Bool = false,
              error: String? = nil) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: provider, label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: model,
                         sessionResetsAt: launch.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: launch.addingTimeInterval(100 * 3600),
                         modelResetsAt: launch.addingTimeInterval(modelResetHours * 3600),
                         modelWindowName: "fable", resetCreditsAvailable: nil,
                         isStale: stale, error: error)
    }
    let dying = acct("A", model: 3)          // under the nearly-dry line, hours from resetting
    let healthy = acct("B", model: 77)
    let alsoDry = acct("C", model: 2)
    let primary = "fable"

    func target(mode: String = "auto", steering: Bool = true, blocked: Bool = false,
                agentsWorking: Bool = false,
                isQuiet: Bool = true, carryable: Bool = true,
                fuseAllows: Bool = true, current: Snapshot.Account = dying,
                candidates: [Snapshot.Account] = [healthy],
                claim: () -> Bool = { true }) -> Snapshot.Account? {
        rebalanceTarget(steering: steering, mode: mode, blocked: blocked,
                        agentsWorking: agentsWorking, isQuiet: isQuiet, carryable: carryable,
                        fuseAllows: fuseAllows, current: current, candidates: candidates,
                        primaryModel: primary, now: launch, claim: claim)
    }

    // The move this whole feature exists for.
    check("a dying account with a comfortable sibling moves at idle", target()?.id == "B")
    check("and it picks the healthiest sibling, not merely an eligible one",
          target(candidates: [alsoDry, healthy])?.id == "B")

    // Nothing to prevent: the session stays where it is.
    check("a comfortable account is left alone", target(current: acct("A", model: 40)) == nil)
    check("an account exactly on the nearly-dry line is dry enough to move",
          target(current: acct("A", model: nearlyDryPercent))?.id == "B")
    check("a hair above the line is not", target(current: acct("A", model: nearlyDryPercent + 0.1))
          == nil)
    // The comfort gate's imminent-reset exemption carries in for free: a window minutes from
    // refilling is a full window, and restarting a session to escape it would be pure churn.
    check("a spent window about to reset is not a dying account",
          target(current: acct("A", model: 3, modelResetHours: 0.1)) == nil)

    // Nowhere better to be. The handoff policy answers the same way (`requiringComfortable` keeps
    // nothing), and a proactive move to an equally spent account is churn for its own sake.
    check("no comfortable sibling means stay put", target(candidates: [alsoDry]) == nil)
    check("no sibling at all means stay put", target(candidates: []) == nil)

    // WAITING ON A PERSON IS NOT IDLENESS, however still the transcript is (2026-08-20). A session
    // stopped on a permission request, a plan approval or a question writes nothing, so the 120s bar
    // arrives by definition - and the relaunch would answer that prompt by destroying it, leaving no
    // trace for whoever was about to decide. The same row `tally session clear` has held since it
    // shipped (`sessionClearMovesAccounts`), and the turn-boundary mover holds too; this was the one
    // preventive mover still deciding otherwise.
    check("a session waiting on a person is not rebalanced", target(blocked: true) == nil)
    check("…and the same session is, once it is not", target(blocked: false)?.id == "B")

    // WHICH KIND OF WAIT, asked through the real classification rather than a literal Bool. The
    // board's word `blocked` is one answer to two situations and only one of them is a person
    // (SessionStateSync.swift); this mover waits 120 seconds for silence, and the soft one is fired
    // about sixty seconds INTO that silence, so reading the word turned the rebalance off outright
    // on every machine with the notification hook installed (codex review of e52a436).
    func waitingTick(_ type: String?) -> SessionTick {
        let wait = userWait(notificationType: type)
        return SessionTick(state: supervisedSessionState(wait: wait, hasTranscript: true,
                                                         quiet: true),
                           quiet: .quiet, wait: wait)
    }
    let idlePrompt = waitingTick("idle_prompt")
    let permission = waitingTick("permission_prompt")
    check("the board calls a quiet session with an idle prompt blocked, which is the trap",
          idlePrompt.state == .blocked)
    check("…but nobody is being waited for there", !idlePrompt.waitingOnPerson)
    check("…while a permission prompt is somebody being waited for", permission.waitingOnPerson)
    check("so a session carrying only an idle prompt is rebalanced",
          target(blocked: idlePrompt.waitingOnPerson)?.id == "B")
    check("…and one holding a permission prompt is not",
          target(blocked: permission.waitingOnPerson) == nil)
    // FAIL-OPEN TO HARD is what makes the narrowing safe: a notice with no type, and a type this
    // build has never heard of, both still stop the move.
    check("an untyped notice still stops it", waitingTick(nil).waitingOnPerson)
    check("…and so does one this build has never heard of",
          waitingTick("some_future_prompt").waitingOnPerson)
    check("exactly one notification type is soft, which is the whole of what was narrowed",
          softWaitNotificationTypes == ["idle_prompt"])

    // AND THROUGH THE REAL PUBLISHER, because everything above builds a `SessionTick` by hand and
    // therefore says nothing about the one place that fills the field in. A mutant that re-derived
    // `wait` from the word inside `syncSessionState` survived the whole suite until this existed
    // (2026-08-21): the movers would have read a hard wait for every idle session, which is the
    // regression this narrowing repaired, arriving through the publisher instead of the caller.
    let stateDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-rebalance-wait-\(UUID().uuidString)")
    let projectDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-rebalance-wait-tx-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: stateDir)
        try? FileManager.default.removeItem(at: projectDir)
    }
    /// One tick of the real publisher for a session holding a notice of `type`.
    ///
    /// The transcript is backdated two minutes so the quiet reading is the one the soft wait needs
    /// to reach `blocked` at all (`supervisedSessionState` only lets a soft wait upgrade silence),
    /// and the notice is stamped NOW so nothing in the file can read as an answer to it.
    func published(_ type: String) -> SessionTick {
        let pid = "rb-\(type)"
        let file = projectDir.appendingPathComponent("\(pid).jsonl")
        let line = "{\"type\":\"assistant\",\"isSidechain\":false,"
            + "\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}"
        try? line.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: file.path)
        writeUserNotice(UserNotice(message: "", at: Date(), type: type), pid: pid, dir: stateDir)
        var watcher = TranscriptWatcher(projectDir: projectDir,
                                        since: Date().addingTimeInterval(-600), resumeID: pid)
        var writer = SessionStateWriter()
        return syncSessionState(&writer, pid: pid,
                                project: PickProject(name: "p", path: projectDir.path),
                                accountID: "claude:.claude", childPid: nil, model: nil,
                                watcher: &watcher, keyboardBurstAt: nil, dir: stateDir)
    }
    let publishedIdle = published("idle_prompt")
    let publishedPermission = published("permission_prompt")
    check("the publisher still draws an idle session with an idle prompt as blocked",
          publishedIdle.state == .blocked)
    check("…and hands the movers the soft wait it actually decided",
          publishedIdle.wait == .soft && !publishedIdle.waitingOnPerson)
    check("…so that session is rebalanced off a dying account",
          target(blocked: publishedIdle.waitingOnPerson)?.id == "B")
    check("a permission prompt comes back from the same publisher as a hard wait",
          publishedPermission.wait == .hard && publishedPermission.waitingOnPerson)
    check("…and that session is left where it stands",
          target(blocked: publishedPermission.waitingOnPerson) == nil)

    // THE ROLL CALL, WHICH OUTRANKS THE MTIME BESIDE IT (2026-08-21). `isQuiet` decides dispatched
    // work is over after `subagentIdleSeconds` of nothing being written under `subagents/`, and a
    // subagent sitting inside ONE long tool call writes nothing for the whole of it - so ten minutes
    // into an eight-minute build plus a package, the inference says the fan-out ended while Claude
    // Code's own roll call still names it. Restarting there is the 2026-07-25 incident.
    //
    // THE THREE CASES THIS COMMIT IS ABOUT, in the order they were asked for:
    // 1. current-generation roster naming a worker, disk silent past the window: NOT moved.
    check("a session whose Claude Code names a live worker is not rebalanced, mtime notwithstanding",
          target(agentsWorking: true, isQuiet: true) == nil)
    check("…and the same session with nobody named is", target(agentsWorking: false)?.id == "B")
    // 2. previous-generation roster: filtered out upstream, so this mover sees no claim at all and
    //    behaves exactly as it always did. The filter itself is asserted in the turn-boundary
    //    checks; what belongs here is that a dropped roster votes false.
    check("a roster the generation filter dropped casts no vote", !rosterReportsWorking(nil))
    check("…so that session is rebalanced on the evidence this mover always had",
          target(agentsWorking: rosterReportsWorking(nil))?.id == "B")
    // 3. no usable roster at all: the mtime is still the only witness, unchanged.
    check("with no roster the mtime still decides, and a busy one still refuses",
          target(agentsWorking: false, isQuiet: false) == nil)
    check("…while a quiet one still moves", target(agentsWorking: false, isQuiet: true)?.id == "B")

    // A pin is a statement about WHERE the session runs, so quota reasoning never overrides it. The
    // cap handoff already refuses to move a pinned session (`CapAction.waitPinned`); a convenience
    // must not do what a repair will not.
    check("a pinned session is never rebalanced", target(mode: "manual") == nil)

    // Non-urgent by construction: this is a convenience, so it may never cost a keystroke or cut a
    // turn. The bar is the full "left alone" one (transcript, subagents, open tool call, keyboard).
    check("a session in use is not moved", target(isQuiet: false) == nil)

    // A conversation that cannot be CARRIED is not moved either, however dry the account. Crossing
    // accounts strips `--continue` on purpose (it names a different conversation over there), so a
    // session told to resume something, before its transcript is bound, has no id to resume and
    // would come back blank. Reachable because an unbound watcher reports itself QUIET
    // (`isBoundFileQuiet` returns true with no file), so the idle bar above says yes to exactly the
    // session that cannot survive the move.
    check("a session whose conversation cannot be carried is not moved",
          target(carryable: false) == nil)
    check("and carrying is the only thing that changed the answer",
          target(isQuiet: true, carryable: true)?.id == "B")

    // What "carryable" means, which is the half that took two goes to get right: the FIRST answer
    // was "the transcript is bound", and that stranded every brand new session on a dying account -
    // a launch that never asked to resume anything has nothing to lose by moving, because
    // `relaunchArgs` hands the move exactly the args a fresh start would have got anyway.
    check("a launch that never asked to resume is carried by definition",
          carryableSession(launchArgs: ["--model", "fable"], sessionLocated: false))
    check("a launch asking to continue is not, until its transcript is bound",
          !carryableSession(launchArgs: ["--continue", "--model", "fable"], sessionLocated: false))
    check("and is once it is", carryableSession(launchArgs: ["--continue"], sessionLocated: true))
    check("the short spelling counts too",
          !carryableSession(launchArgs: ["-c"], sessionLocated: false))
    // `--resume <id>` is the shape every relaunch after the first move carries, so it must count:
    // its id is only good on a home the transcript has been shared to, and the binding is the proof.
    check("a resumed session needs its binding as much as a continued one",
          !carryableSession(launchArgs: ["--resume", "abc"], sessionLocated: false))
    check("and the -r spelling as well",
          !carryableSession(launchArgs: ["-r", "abc"], sessionLocated: false))
    // A one-shot `-p` run is the third class, and the one that reads backwards: it has no
    // conversation to lose, and is still the one launch that must NEVER move. Moving it kills a
    // command mid-flight and runs it again over there, so its tools and its external writes happen
    // twice - unrecoverable in a way no relaunch flag can undo.
    check("a print run is never moved, however new it looks",
          !carryableSession(launchArgs: ["-p", "hello"], sessionLocated: false))
    // And crucially not once its transcript binds either: `-p` DOES write one (241 sit in each
    // account's probe directory, which is why ClaudeUsageCLI prunes them), so a rule that asked only
    // "is it located" would wave the print run straight through.
    check("and not once it has written a transcript, which is the trap",
          !carryableSession(launchArgs: ["-p", "hello"], sessionLocated: true))
    check("the long spelling too", !carryableSession(launchArgs: ["--print"], sessionLocated: true))
    // The two halves partition the shared set, so a flag added there cannot fall between them.
    check("the flag halves partition the shared session set",
          printFlags.union(resumeFlags) == sessionFlags && printFlags.isDisjoint(with: resumeFlags))

    // MARK: - 26a2. Which launches get a supervisor at all

    // The entry gate, and the reason the print class above is now belt AND braces: a one-shot run
    // gets no supervisor, so none of the movers can reach it. Every supervisor action restarts the
    // child, which a conversation survives (resumed by id) and a command does not - it simply runs
    // again, tool calls and external writes included. The movers each had to learn that separately,
    // which is the tell that the question belonged at the door.
    check("an ordinary interactive launch is supervised",
          shouldSupervise(args: ["--model", "fable"], stdoutIsTTY: true))
    check("a --print run is not", !shouldSupervise(args: ["--print", "hi"], stdoutIsTTY: true))
    check("nor the short spelling", !shouldSupervise(args: ["-p", "hi"], stdoutIsTTY: true))
    // claude enters print mode implicitly when stdout is not a terminal, so `tally claude '...' |
    // tee out` is a one-shot run carrying no flag that says so. Reading the terminal is how the CLI
    // itself decides, so it is how this decides.
    check("a piped launch is not supervised even with no print flag",
          !shouldSupervise(args: ["--model", "fable"], stdoutIsTTY: false))
    check("and a piped print run is doubly not", !shouldSupervise(args: ["-p"], stdoutIsTTY: false))
    // The existing opt-out still wins on its own, ahead of any of this.
    check("--no-handoff still opts out of an interactive launch",
          !shouldSupervise(args: ["--no-handoff"], stdoutIsTTY: true))
    // A conversation flag is the opposite case: resuming is exactly what supervision is for.
    check("a resumed conversation on a terminal is supervised",
          shouldSupervise(args: ["--continue"], stdoutIsTTY: true))
    // Everything after a bare `--` is the PROMPT, not options: claude parses `[options] [command]
    // [prompt]` the POSIX way, so `tally claude -- --print summarise` is an interactive session
    // whose prompt starts with the word `--print`. Every question Tally asks about a launch has to
    // stop where the CLI stops, or Tally reads the user's prompt as an instruction about itself.
    check("a print flag after the end-of-options marker is a prompt word",
          shouldSupervise(args: ["--", "--print", "summarise"], stdoutIsTTY: true))
    check("while the same flag before it still means one-shot",
          !shouldSupervise(args: ["--print", "--", "summarise"], stdoutIsTTY: true))
    check("an opt-out after the marker is not an opt-out",
          autoHandoffEnabled(args: ["--", "--no-handoff"]))
    check("and before it still is", !autoHandoffEnabled(args: ["--no-handoff", "--"]))
    check("the follow opt-out reads the same boundary",
          autoFollowEnabled(args: ["--", "--no-follow"]))
    // The carry classification too: a prompt mentioning `--continue` must not make a brand new
    // session look like a resumed one it has to protect.
    check("a resume flag after the marker does not make a session look resumed",
          carryableSession(launchArgs: ["--", "--continue"], sessionLocated: false))
    check("nor a print flag make it unmovable",
          carryableSession(launchArgs: ["--", "-p"], sessionLocated: false))
    // The slice itself, including the case that has no marker at all.
    check("with no marker the whole vector is options",
          optionsOnly(["--model", "fable"]) == ["--model", "fable"])
    check("the marker itself is not kept", optionsOnly(["-c", "--", "-p"]) == ["-c"])
    check("a leading marker leaves nothing to read", optionsOnly(["--", "-p"]).isEmpty)

    // The gate is only worth anything if the launcher asks it, and the TTY half is the half that
    // can be quietly dropped (the flag half looks complete on its own), so the source carries it.
    let launcher = (try? String(contentsOfFile: "TallyCLI/main.swift", encoding: .utf8)) ?? ""
    check("the launcher source is readable from these checks", !launcher.isEmpty)
    check("the launcher decides supervision through the gate",
          launcher.contains("shouldSupervise(args: passthrough"))
    check("and answers the terminal question from the real terminal",
          launcher.contains("let stdoutIsTTY = isatty(STDOUT_FILENO) == 1"))
    // The pipe is the one reason for refusing that the user cannot see in what they typed, so it is
    // the one that says so - on stderr, where it cannot land in the output being piped.
    check("the launcher says so when the pipe is what refused",
          launcher.contains("not supervised: stdout is not a terminal"))
    // ...and only for the provider that would have had a supervisor: both `runSupervised` calls are
    // behind `provider.id == "claude"`, so a piped `tally codex` never lost anything to be told
    // about. The notice and the supervision have to agree about who they are for.
    check("and only for the provider a supervisor was on offer for",
          launcher.contains("if provider.id == \"claude\", !wantsHandoff, !stdoutIsTTY"))
    check("and says it through the stderr writer",
          launcher.contains("warn(\"not supervised: stdout is not a terminal"))

    // MARK: - 26b. The two guardrails

    // The recovery fuse, shared with cap recoveries: a session already moved three times in ten
    // minutes has a systemic problem that a fourth move will not cure.
    let fuseT0 = launch
    var fuse = RecoveryFuse(max: 3, window: 600)
    check("a fresh fuse lets a rebalance through", target(fuseAllows: fuse.allows(now: fuseT0))?.id
          == "B")
    for _ in 0 ..< 2 { _ = fuse.allows(now: fuseT0); fuse.record(now: fuseT0) }
    check("two automatic moves spent still leaves room",
          target(fuseAllows: fuse.allows(now: fuseT0))?.id == "B")
    fuse.record(now: fuseT0)
    check("the fourth automatic move is refused", target(fuseAllows: fuse.allows(now: fuseT0)) == nil)
    check("and the fuse itself is what refuses it", !fuse.allows(now: fuseT0))
    check("once the window has passed it is allowed again",
          target(fuseAllows: fuse.allows(now: fuseT0.addingTimeInterval(601)))?.id == "B")

    // One move per account per window cycle, shared across supervisors: without it the five sessions
    // on one dying account all read the same picture on the same tick and stampede onto the one
    // healthy sibling.
    check("an account whose cycle another supervisor holds is left alone",
          target(claim: { false }) == nil)

    // The claim is the one gate with a side effect, so it is asked LAST. A tick that was never going
    // to move must not spend this account's one move of the cycle and leave it stuck until the
    // window resets.
    func claimAsked(mode: String = "auto", isQuiet: Bool = true, carryable: Bool = true,
                    fuseAllows: Bool = true, current: Snapshot.Account = dying,
                    candidates: [Snapshot.Account] = [healthy]) -> Bool {
        var asked = false
        _ = target(mode: mode, isQuiet: isQuiet, carryable: carryable,
                   fuseAllows: fuseAllows, current: current,
                   candidates: candidates, claim: { asked = true; return true })
        return asked
    }
    check("a move that happens claims the cycle", claimAsked())
    check("a pinned session does not spend the cycle", !claimAsked(mode: "manual"))
    check("a session in use does not spend the cycle", !claimAsked(isQuiet: false))
    // The account is left free to make this same move later, once there is a conversation to bring.
    check("a session with nothing to carry does not spend it either",
          !claimAsked(carryable: false))
    check("a spent fuse does not spend the cycle", !claimAsked(fuseAllows: false))
    check("a comfortable account does not spend the cycle",
          !claimAsked(current: acct("A", model: 40)))
    check("and neither does having nowhere better to go", !claimAsked(candidates: [alsoDry]))

    // MARK: - 26b2. The claim's one exemption: an account that is already spent

    // WHY IT EXISTS (2026-08-20). Every refusal in Rebalance.swift is justified by one sentence -
    // not moving costs at worst the cap handoff doing it later - and a cap handoff needs a turn to
    // hit a wall. An IDLE session has no turn, so on an empty account that sentence is false and
    // the refusal costs the rest of the window instead: one session took Claude 4's claim for the
    // drought at 12:41Z, a reload re-placed three sessions back onto it at 13:31Z because the
    // repick could not have that claim, seven ended up sharing it at 0%, and every rebalance after
    // that was refused until the window reset at 13:59Z.
    let spent = acct("A", model: 0)
    check("an account with no effective remaining at all is spent",
          accountIsSpent(spent, primaryModel: primary, now: launch))
    check("…and a session leaves it even while another supervisor holds the drought's claim",
          target(current: spent, claim: { false })?.id == "B")
    // AND IT NEVER ASKS, which is what keeps the exemption off the disk altogether: nothing is
    // written, nothing is read, and no marker is left for a sibling supervisor to misread.
    var spentAsked = false
    _ = target(current: spent, claim: { spentAsked = true; return true })
    check("…without asking for the claim at all", !spentAsked)

    // THE RED LINE, and the reason the exemption is keyed on zero rather than on the dry line: the
    // 2026-08-02 double move this claim was tightened for ran on a 1% window, and an account at 1%
    // can still serve the turn that summons the cap handoff.
    check("a 1% account still loses to a claim another supervisor holds",
          target(current: acct("A", model: 1), claim: { false }) == nil)
    check("…and so does one exactly on the nearly-dry line",
          target(current: acct("A", model: nearlyDryPercent), claim: { false }) == nil)
    check("…while both still move when the claim is theirs to take",
          target(current: acct("A", model: 1))?.id == "B"
              && target(current: acct("A", model: nearlyDryPercent))?.id == "B")
    check("neither of them is spent by the gate's own scale",
          !accountIsSpent(acct("A", model: 1), primaryModel: primary, now: launch)
              && !accountIsSpent(acct("A", model: nearlyDryPercent), primaryModel: primary,
                                 now: launch))

    // THE IMMINENT-RESET EXEMPTION CARRIES IN FOR FREE, because the scale is the comfort gate's
    // own: 0% resetting in six minutes is a FULL window there, so such an account is neither dying
    // nor spent and nothing moves. That is what stops this from firing on a window about to refill.
    let refilling = acct("A", model: 0, modelResetHours: 0.1)
    check("a spent window minutes from resetting is not a spent account",
          !accountIsSpent(refilling, primaryModel: primary, now: launch))
    check("…so that session stays put, claim or no claim",
          target(current: refilling, claim: { false }) == nil && target(current: refilling) == nil)

    // THE OTHER GUARDRAILS ARE UNTOUCHED. The exemption suspends the claim and nothing else, so
    // every gate that was a hard wall before is one still.
    check("a spent account with a spent fuse moves nobody",
          target(fuseAllows: false, current: spent, claim: { false }) == nil)
    check("…nor one whose siblings are all dry too",
          target(current: spent, candidates: [alsoDry], claim: { false }) == nil)
    check("…nor one with no sibling at all",
          target(current: spent, candidates: [], claim: { false }) == nil)
    check("…nor a pinned session",
          target(mode: "manual", current: spent, claim: { false }) == nil)
    check("…nor one waiting on a person",
          target(blocked: true, current: spent, claim: { false }) == nil)
    check("…nor one whose Claude Code names a live worker",
          target(agentsWorking: true, current: spent, claim: { false }) == nil)
    check("…nor one that is in use",
          target(isQuiet: false, current: spent, claim: { false }) == nil)
    check("…nor one whose conversation cannot be carried",
          target(carryable: false, current: spent, claim: { false }) == nil)
    // OBSERVE ONLY OUTRANKS IT, which is the gate that is not about this session at all: a fleet
    // told never to steer is not overruled by an account being empty (AutoSteering.swift).
    check("…and an observe-only fleet moves nothing off a spent account",
          target(steering: false, current: spent, claim: { false }) == nil)

    // THE BINDING WINDOW IS WHAT IS ASKED, not one particular window: an account emptied by its
    // SESSION window is spent however healthy the rest of it reads.
    var sessionSpent = acct("A", model: 90)
    sessionSpent.sessionRemaining = 0
    check("an account emptied by its session window is spent too",
          accountIsSpent(sessionSpent, primaryModel: primary, now: launch))
    check("…and is exempted on the same terms",
          target(current: sessionSpent, claim: { false })?.id == "B")
    // Missing data is not an exemption: an account that reports no counted windows is not spent,
    // and a move made on evidence nobody has is the thing every refusal here exists to prevent.
    var blankAccount = acct("A", model: 3)
    (blankAccount.sessionRemaining, blankAccount.weeklyRemaining, blankAccount.modelRemaining)
        = (nil, nil, nil)
    check("an account reporting no windows at all is not spent",
          !accountIsSpent(blankAccount, primaryModel: primary, now: launch))

    // A STALE OR ERRORED ZERO IS THAT SAME MISSING DATA, and it is the shape of it that reaches
    // this gate in the field: a failed refresh keeps the last good numbers behind a flag, leaving a
    // remembered zero while the snapshot around it stays fresh on some other account's activity.
    // Every idle supervisor on that account holds that same memory on the same tick, so exempting
    // it hands them one sibling all at once, which is precisely the stampede the claim was written
    // to stop (codex review of 54eebaa, P2).
    let staleSpent = acct("A", model: 0, stale: true)
    let erroredSpent = acct("A", model: 0, error: "boom")
    check("a spent account whose reading is stale is not spent",
          !accountIsSpent(staleSpent, primaryModel: primary, now: launch))
    check("…nor one whose last refresh errored",
          !accountIsSpent(erroredSpent, primaryModel: primary, now: launch))
    check("…while the same numbers freshly read are spent, which is the behaviour being kept",
          accountIsSpent(acct("A", model: 0), primaryModel: primary, now: launch))
    // So the claim governs them again: what the flag suspends is the exemption, not the move.
    check("a stale spent account loses to a claim another supervisor holds",
          target(current: staleSpent, claim: { false }) == nil)
    check("…and so does an errored one", target(current: erroredSpent, claim: { false }) == nil)
    check("…while both still move when the claim is theirs to take",
          target(current: staleSpent)?.id == "B" && target(current: erroredSpent)?.id == "B")

    // MARK: - 26c. The cycle key

    // Derived from the BINDING window's reset time, in whole seconds: the same derivation the app's
    // per-cycle dedup uses (DryPoolLogic.resetKey, via ResetHintLogic), so a record survives
    // sub-second jitter in a reported reset without reading as a new cycle, and re-arms by itself
    // when the window that made the account dry actually refills.
    let modelResetsAt = launch.addingTimeInterval(100 * 3600)
    check("the key names the binding window's reset",
          rebalanceCycleKey(dying, primaryModel: primary, now: launch)
          == String(Int(modelResetsAt.timeIntervalSince1970.rounded())))
    check("sub-second jitter is not a new cycle",
          rebalanceCycleKey(acct("A", model: 3, modelResetHours: 100 + 0.4 / 3600),
                            primaryModel: primary, now: launch)
          == rebalanceCycleKey(dying, primaryModel: primary, now: launch))
    // The binding window is the emptiest one, not a fixed one: an account whose SESSION window is
    // the spent one is bound by that reset, and that is the cycle its record belongs to.
    var sessionBound = acct("A", model: 90)
    sessionBound.sessionRemaining = 2
    check("a session-bound account keys off the session reset",
          rebalanceCycleKey(sessionBound, primaryModel: primary, now: launch)
          == String(Int(launch.addingTimeInterval(4 * 3600).timeIntervalSince1970.rounded())))
    // The binding window is the emptiest one the COMFORT GATE sees, which is not always the emptiest
    // raw number: the gate counts a window resetting within ten minutes as already refilled
    // (`imminentResetGrace`). A session at 3% resetting in five minutes under a weekly at 4% is a
    // weekly drought, and the weekly's reset is the one that ends it. Keying off the session would
    // expire the claim five minutes later and move the same session a second time, mid-drought.
    var driedByWeekly = acct("A", model: 90, modelResetHours: 50)
    (driedByWeekly.sessionRemaining, driedByWeekly.weeklyRemaining) = (3, 4)
    driedByWeekly.sessionResetsAt = launch.addingTimeInterval(5 * 60)
    let weeklyCycle = String(Int(launch.addingTimeInterval(100 * 3600).timeIntervalSince1970
                                 .rounded()))
    check("a window minutes from resetting does not bind the cycle key",
          rebalanceCycleKey(driedByWeekly, primaryModel: primary, now: launch) == weeklyCycle)
    // And the drought outlives that refill: five minutes on, the session window is full again and
    // the account is still bound by the same weekly, so it is still the same cycle.
    var afterSessionRefill = driedByWeekly
    afterSessionRefill.sessionRemaining = 100
    afterSessionRefill.sessionResetsAt = launch.addingTimeInterval(5 * 3600)
    check("and the cycle is unchanged once that window actually refills",
          rebalanceCycleKey(afterSessionRefill, primaryModel: primary,
                            now: launch.addingTimeInterval(6 * 60)) == weeklyCycle)
    // Which is the whole point, stated as the claim sees it: one unbroken drought is one cycle, so
    // the claim taken at the start of it still holds at the end and the session is moved once.
    check("one drought is one cycle from end to end",
          rebalanceCycleKey(driedByWeekly, primaryModel: primary, now: launch)
          == rebalanceCycleKey(afterSessionRefill, primaryModel: primary,
                               now: launch.addingTimeInterval(6 * 60)))

    // With no cycle to name there is nothing to claim, and an unclaimed rebalance is the stampede
    // the claim exists to prevent, so both of these mean "do not move".
    var noReset = acct("A", model: 3)
    noReset.modelResetsAt = nil
    check("a binding window with no known reset has no cycle",
          rebalanceCycleKey(noReset, primaryModel: primary, now: launch) == nil)
    var noWindows = acct("A", model: 3)
    (noWindows.sessionRemaining, noWindows.weeklyRemaining, noWindows.modelRemaining) = (nil, nil, nil)
    check("an account reporting no windows has no cycle",
          rebalanceCycleKey(noWindows, primaryModel: primary, now: launch) == nil)

    // 26d, 26d-jitter, 26d-blind and 26d-lock live in rebalanceclaimchecks.swift, and run from here
    // on the weekly drought built just above.
    runRebalanceClaimChecks(primaryModel: primary, weeklyCycle: weeklyCycle,
                            afterSessionRefill: afterSessionRefill)

    // MARK: - 26e. One tick's decision against the live picture

    // An answer here TAKES the cycle's claim, so each check that expects a move gets its own
    // directory rather than inheriting the claim the previous one made. The claim's own behaviour
    // on this path is asserted below, against one shared directory on purpose.
    var scratchDirs: [URL] = []
    func snapshot(_ accounts: [Snapshot.Account]) -> Snapshot {
        Snapshot(version: 2, generatedAt: launch, accounts: accounts)
    }
    func move(_ accounts: [Snapshot.Account], problem: String? = nil, mode: String = "auto",
              steering: Bool = true, blocked: Bool = false, agentsWorking: Bool = false,
              isQuiet: Bool = true, carryable: Bool = true, fuseAllows: Bool = true,
              quarantine: [String: (model: String?, until: Date)] = [:],
              on: Snapshot.Account = dying, dir: URL? = nil) -> Snapshot.Account? {
        var target = dir
        if target == nil {
            let fresh = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tally-rebalance-move-\(UUID().uuidString)")
            scratchDirs.append(fresh)
            target = fresh
        }
        return rebalanceMove(provider: "claude", account: on, primaryModel: primary, mode: mode,
                             steering: steering, blocked: blocked, agentsWorking: agentsWorking,
                             isQuiet: isQuiet, carryable: carryable,
                             fuseAllows: fuseAllows, quarantine: quarantine,
                             loaded: (snapshot(accounts), problem), now: launch, dir: target!)
    }
    check("a tick with a dying account and a healthy sibling answers with the sibling",
          move([dying, healthy])?.id == "B")
    // And the blocked gate above reaches the whole move, not just the pure decision: it is one of
    // the cheap terms, so a session waiting on a person never even reads the snapshot.
    check("a session waiting on a person is refused by the whole move too",
          move([dying, healthy], blocked: true) == nil)
    // Same for the roll call, and for the same reason: it is one of the cheap terms, so a session
    // whose Claude Code names a worker never even reads the snapshot.
    check("a session whose Claude Code names a live worker is refused by the whole move too",
          move([dying, healthy], agentsWorking: true) == nil)
    // Answering IS claiming, so a sibling supervisor asking the same question a moment later is
    // refused. There is no window between deciding to move and recording it for a second supervisor
    // to decide the same move in, and no caller left holding a record it could forget to write.
    let moveDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-move-\(UUID().uuidString)")
    check("the first supervisor to ask moves", move([dying, healthy], dir: moveDir)?.id == "B")
    check("and the second is refused, on the live path too",
          move([dying, healthy], dir: moveDir) == nil)
    check("the claim it took is the one the cycle key names",
          claimExists(dying.id, cycle: rebalanceCycleKey(dying, primaryModel: primary,
                                                         now: launch)!, in: moveDir))
    // The account the loop carries was fixed at LAUNCH, and after a self-update exec it has no
    // quota fields at all, so the numbers have to come from the snapshot. This is that case: the
    // struct passed in claims nothing, and the snapshot's copy of it is what is dying.
    let carried = Snapshot.Account(id: "A", provider: "claude", label: "A", launchHome: "/tmp/A",
                                   sessionRemaining: nil, weeklyRemaining: nil, modelRemaining: nil,
                                   sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                                   modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
                                   error: nil)
    check("the live snapshot decides, not the account struct the session was launched with",
          move([dying, healthy], on: carried)?.id == "B")
    // A snapshot too old to trust answers nothing, exactly as the cap handoff refuses to pick a
    // target on stale numbers.
    check("a stale snapshot moves nobody", move([dying, healthy], problem: "snapshot is 40m old")
          == nil)
    check("an account missing from the snapshot moves nobody",
          move([healthy], on: dying) == nil)
    check("a quarantined sibling is not a target",
          move([dying, healthy],
               quarantine: ["B": (model: primary, until: launch.addingTimeInterval(600))]) == nil)
    check("a sibling on another provider is not a target",
          move([dying, acct("codex-1", model: 77, provider: "codex")]) == nil)
    check("an errored sibling is not a target", move([dying, acct("B", model: 77, error: "boom")])
          == nil)
    check("a stale-flagged sibling is not a target", move([dying, acct("B", model: 77, stale: true)])
          == nil)
    check("a pinned session still moves nobody here", move([dying, healthy], mode: "manual") == nil)
    check("a session in use still moves nobody here", move([dying, healthy], isQuiet: false) == nil)
    check("a spent fuse still moves nobody here", move([dying, healthy], fuseAllows: false) == nil)
    check("and a session with no transcript to carry moves nobody here",
          move([dying, healthy], carryable: false) == nil)
    // Nor did any of them READ anything. This is the tick almost every tick is - a session that is
    // pinned, busy, out of fuse, or not carrying a conversation - and it used to read and decode
    // `~/.tally/snapshot.json` regardless, because a plain default argument is evaluated at the call
    // site before the function is even entered (review, 2026-08-06). `@autoclosure` plus the cheap
    // gates first means the file is only opened by a tick that could actually move this session.
    var snapshotReads = 0
    func countedSnapshot(_ accounts: [Snapshot.Account]) -> (Snapshot?, String?) {
        snapshotReads += 1
        return (snapshot(accounts), nil)
    }
    func lazyMove(mode: String = "auto", steering: Bool = true, blocked: Bool = false,
                  agentsWorking: Bool = false,
                  isQuiet: Bool = true, carryable: Bool = true,
                  fuseAllows: Bool = true) -> Snapshot.Account? {
        let fresh = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tally-rebalance-lazy-\(UUID().uuidString)")
        scratchDirs.append(fresh)
        return rebalanceMove(provider: "claude", account: dying, primaryModel: primary, mode: mode,
                             steering: steering, blocked: blocked, agentsWorking: agentsWorking,
                             isQuiet: isQuiet, carryable: carryable,
                             fuseAllows: fuseAllows,
                             loaded: countedSnapshot([dying, healthy]), now: launch, dir: fresh)
    }
    _ = lazyMove(mode: "manual")
    _ = lazyMove(isQuiet: false)
    _ = lazyMove(carryable: false)
    _ = lazyMove(fuseAllows: false)
    check("a tick that cannot move this session reads no snapshot at all", snapshotReads == 0)
    check("and the tick that can, reads it once and moves", lazyMove()?.id == "B")
    check("…exactly once", snapshotReads == 1)

    // None of those refusals spent the cycle: an account that was pinned, busy, out of fuse or not
    // yet carrying a conversation when the tick ran is still free to move the moment those clear.
    let sparedDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-move-\(UUID().uuidString)")
    _ = move([dying, healthy], mode: "manual", dir: sparedDir)
    _ = move([dying, healthy], isQuiet: false, dir: sparedDir)
    _ = move([dying, healthy], carryable: false, dir: sparedDir)
    _ = move([dying, healthy], fuseAllows: false, dir: sparedDir)
    _ = move([dying, alsoDry], dir: sparedDir)
    check("a tick that refused to move leaves the cycle's claim untaken",
          move([dying, healthy], dir: sparedDir)?.id == "B")

    // THE EXEMPTION ON THE LIVE PATH, and its accepted cost written down as a test rather than as a
    // hope. Two idle sessions leave one spent account against ONE shared claim directory - the
    // second is exactly the session the claim would have refused - and both land on the same
    // sibling, because they read the same snapshot. That concentration is accepted deliberately:
    // a 95% sibling is strictly better than a 0% account, and it cannot chain, because the sibling
    // is not spent and the ordinary claim governs whatever happens there next.
    let spentDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-move-\(UUID().uuidString)")
    let spentLive = acct("A", model: 0)
    // A field with TWO comfortable siblings in it, so "they both chose B" is a statement about the
    // ordering rather than about there being nowhere else to go.
    let secondBest = acct("D", model: 40)
    let field = [spentLive, healthy, secondBest]
    check("a session on a spent account has more than one comfortable sibling to choose from",
          accountIsComfortable(secondBest, primaryModel: primary, now: launch))
    check("…the first one leaves, to the best of them",
          move(field, on: spentLive, dir: spentDir)?.id == "B")
    check("…and so does the second, which the claim would have stranded",
          move(field, on: spentLive, dir: spentDir)?.id == "B")
    check("…having recorded no claim for that drought at all",
          !claimExists(spentLive.id, cycle: rebalanceCycleKey(spentLive, primaryModel: primary,
                                                              now: launch)!, in: spentDir))
    check("the sibling they land on is not itself spent",
          !accountIsSpent(healthy, primaryModel: primary, now: launch))
    check("…so nothing moves off it again and the exemption cannot oscillate",
          move([spentLive, healthy], on: healthy, dir: spentDir) == nil)
    // A SPENT ACCOUNT WITH NO REPORTED RESET IS MOVED OFF TOO, which is the other half of not
    // asking for the claim: with no cycle to name there is nothing to claim, and that used to end
    // the decision before the gates were reached. It still refuses an ORDINARY move, exactly as it
    // always did; what it may not do is strand a session on an empty account for want of a reset
    // time to key a record on.
    var spentNoReset = acct("A", model: 0)
    spentNoReset.modelResetsAt = nil
    check("a spent account whose binding window names no reset has no cycle to claim",
          rebalanceCycleKey(spentNoReset, primaryModel: primary, now: launch) == nil)
    check("…and is spent all the same", accountIsSpent(spentNoReset, primaryModel: primary,
                                                       now: launch))
    check("…so the session leaves it", move([spentNoReset, healthy], on: spentNoReset,
                                            dir: spentDir)?.id == "B")
    var dyingNoReset = acct("A", model: 3)
    dyingNoReset.modelResetsAt = nil
    check("while a merely dying account with no reset still moves nobody",
          move([dyingNoReset, healthy], on: dyingNoReset, dir: spentDir) == nil)
    // And observe-only reaches the whole move, not only the pure decision, leaving nothing behind.
    let spentOffDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-move-\(UUID().uuidString)")
    check("an observe-only fleet moves nobody off a spent account here either",
          move([spentLive, healthy], steering: false, on: spentLive, dir: spentOffDir) == nil)
    check("…and writes nothing while refusing",
          ((try? FileManager.default.contentsOfDirectory(atPath: spentOffDir.path)) ?? []).isEmpty)
    try? FileManager.default.removeItem(at: spentDir)
    try? FileManager.default.removeItem(at: spentOffDir)

    // The incident end to end, on the path that produced it. An account whose SESSION window is the
    // spent one keys off that window's reset, and that reset is reported to the minute: the same 1%
    // window read 06:39 on one poll and 06:40 on the next, and Claude 2 handed out a second move ten
    // minutes after the first (2026-08-02). One drought is one move, however the clock is reported.
    let driftDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-rebalance-move-\(UUID().uuidString)")
    var driedSession = acct("A", model: 90)
    driedSession.sessionRemaining = 1
    check("the first tick on a spent session window moves",
          move([driedSession, healthy], on: driedSession, dir: driftDir)?.id == "B")
    var slipped = driedSession
    slipped.sessionResetsAt = driedSession.sessionResetsAt!.addingTimeInterval(60)
    check("and the same window reported a minute later does not move a second session",
          move([slipped, healthy], on: slipped, dir: driftDir) == nil)
    // What must still get through: the window really did reset, five hours on, and was drained
    // again. That is a new drought and it gets its own move.
    var nextWindow = driedSession
    nextWindow.sessionResetsAt = driedSession.sessionResetsAt!.addingTimeInterval(5 * 3600)
    check("but a window that actually reset and drained again is moved once more",
          move([nextWindow, healthy], on: nextWindow, dir: driftDir)?.id == "B")
    try? FileManager.default.removeItem(at: driftDir)
    for dir in scratchDirs + [moveDir, sparedDir] {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 26f. The loop wiring

    // The decision is reachable in a test; its placement in the tick is not, so the source carries
    // it (the technique the follow dead end, the fuse carry, and the self-update fold all use).
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the rebalance checks", !loop.isEmpty)
    func at(_ needle: String) -> Int? {
        loop.range(of: needle).map { loop.distance(from: loop.startIndex, to: $0.lowerBound) }
    }
    check("the tick asks for a proactive move", loop.contains("applyProactiveMoves("))
    // The decision itself moved out of the loop when a SECOND preventive mover joined it (the
    // window repick), so what the loop now shows is the call; the rest is read off the station.
    // Same question, same answers, one file further out - the move the fallback profile already
    // made when its rule left this file.
    let station = (try? String(contentsOfFile: "TallyCLI/WindowRepick.swift", encoding: .utf8)) ?? ""
    check("the preventive station is readable from the rebalance checks", !station.isEmpty)
    check("it only runs when nothing else is already relaunching",
          station.contains("guard plan == nil else { return }"))
    check("it waits for the full left-alone bar, transcript and keyboard alike",
          station.contains("watcher.isQuiet(followIdleSeconds) && keyboardIdle(followIdleSeconds)"))
    check("the move counts against the recovery fuse",
          station.contains("RelaunchPlan(target: moveTo, reason: \"rebalance\", countsFuse: true)"))
    // The cycle is claimed inside the decision, so neither the loop nor the station has anything to
    // record and no way to forget: a target it never got is a cycle it never took.
    check("nothing outside the decision keeps a rebalance record",
          !loop.contains("recordRebalance(") && !station.contains("recordRebalance("))
    check("the user is told what is happening and why",
          station.contains("nearly dry, moving to") && station.contains("before the wall"))
    // Placement: last of the account moves (every other one is repairing something), and it goes
    // through the shared plan, which is what makes a pending self-update fold into its restart.
    // The fallback marker is the CALL to the fallback profile: the rule itself moved to
    // ModelDegradation.swift, and what this asserts is where it sits in the tick, which is the
    // call site. Same question, same answer, one file further out.
    if let rebalance = at("// The two PREVENTIVE movers"), let fallback = at("applyFallbackProfile("),
       let selfUpdate = at("// The app updated under this supervisor"),
       let execution = at("// Execute the tick's one relaunch") {
        check("the rebalance is considered after every repair path", fallback < rebalance)
        check("and before the self-update, so a pending upgrade folds into its restart",
              rebalance < selfUpdate)
        check("it plans a relaunch rather than performing one", rebalance < execution)
    } else {
        // A missing marker is the block being gone, which is a failure to report rather than a
        // crash: these run against whatever the source says, including a source that lost the block.
        check("the rebalance block and its neighbours were found in the tick", false)
    }
}
