import Foundation

// `tally session send`: the channel (SessionInputRequest.swift), and the gate table and the tick
// that serve one (SessionInput.swift). THE COMMAND that asks for one is next door
// (sessionsendchecks.swift), split off along the same seam the source is: this side is what a
// supervisor does about a request, that side is what a caller may ask for and what it is told.
//
// Everything here is pure or pointed at a temp directory, like every other suite in this family:
// nothing touches `~/.tally/input`, and every path that logs is given a sink of its own, so a
// machine with live sessions on it can run this without one of them being typed into.
//
// WHAT IS NOT COVERED HERE, said out loud rather than left to be assumed: the terminal write
// itself. `injectSessionInput` is exercised only for its failure arm (a path that is not a terminal),
// because a success needs a controlling terminal this process does not have and cannot make without
// becoming the thing it is testing. The success path was proved by the spike the feature was built
// on (SessionInput.swift carries its measurements) and end-to-end by hand; what the suite pins is
// everything that DECIDES whether that write happens.

/// A target for the relaunch plans below. Only its existence matters here: what is under test is
/// whether a plan is STOOD DOWN, which the reason and the fork decide and the account never touches.
private let sessionInputAccount = Snapshot.Account(
    id: "A", provider: "claude", label: "A", launchHome: "/tmp/A", sessionRemaining: 90,
    weeklyRemaining: 90, modelRemaining: 90, sessionResetsAt: nil, weeklyResetsAt: nil,
    modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
    error: nil)

func runSessionInputChecks() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-sessioninput-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("input.log")
    // LAID DOWN AT 0644 BEFORE ANYTHING RUNS, which is what makes the mode checks below a test of
    // convergence rather than of creation: the file that matters is the one an earlier build already
    // left on a machine, and a permission applied only at creation would never reach it.
    FileManager.default.createFile(atPath: log.path, contents: nil,
                                   attributes: [.posixPermissions: 0o644])

    let t0 = Date(timeIntervalSince1970: 1_786_571_200)
    /// The stamp a request written at `offset` seconds from t0 carries.
    func epoch(_ offset: TimeInterval) -> Int { Int((t0.addingTimeInterval(offset)).timeIntervalSince1970 * 1000) }
    func request(_ text: String, at offset: TimeInterval = 0) -> SessionInputRequest {
        SessionInputRequest(epoch: epoch(offset), text: text)
    }

    // MARK: - The format on disk

    // THE REASON THIS CHANNEL IS JSON AND ITS NEIGHBOURS ARE NOT: the payload is arbitrary text a
    // caller typed, so a newline in it would end the record under the line-per-field reader every
    // other request file here uses.
    let awkward = request("line one\nline two\t\"quoted\" 中文 🙂")
    check("a request survives a round trip through the channel",
          sessionInputData(awkward).flatMap { parseSessionInput($0) as SessionInputRequest? }
              == awkward)
    let answer = SessionInputResult(epoch: awkward.epoch, outcome: "submitted", detail: nil)
    check("…and so does an answer",
          sessionInputData(answer).flatMap { parseSessionInput($0) as SessionInputResult? }
              == answer)
    check("a truncated write is no request at all, rather than half of one",
          (parseSessionInput(Data("{\"epoch\":123,\"te".utf8)) as SessionInputRequest?) == nil)
    // A word from a newer supervisor decodes rather than being rejected, and reads as NOT delivered:
    // a caller deciding whether to retry must never read "I have not heard of that" as "it landed".
    let future = SessionInputResult(epoch: 1, outcome: "refused-something-new", detail: "why")
    check("an outcome this build has never heard of still decodes",
          sessionInputData(future).flatMap { parseSessionInput($0) as SessionInputResult? }
              == future)
    check("…and is not read as delivered", !future.delivered && future.resolved == nil)
    // ONE WORD MEANS IT LANDED, because there is now one way for it to: typing and sending are a
    // single act, so the outcome that used to mean "typed, and sitting in the composer" describes
    // nothing this build can do and is gone from the vocabulary rather than left as a word a caller
    // could still be handed.
    check("the one outcome that is delivered is the one that means it was sent",
          SessionInputOutcome.submitted.delivered
              && !SessionInputOutcome.refusedExpired.delivered
              && !SessionInputOutcome.refusedNotReporting.delivered
              && !SessionInputOutcome.refusedTooLong.delivered
              && !SessionInputOutcome.failedTTY.delivered)
    check("…and the composer-only outcome is not a word this build knows at all",
          SessionInputOutcome(rawValue: "injected") == nil)

    // MARK: - The gate table

    /// The decision for one request, with everything else at its permissive setting.
    func decide(_ pending: SessionInputRequest?, served: Int = 0, state: SupervisedState = .idle,
                keyboardIdle: Bool = true, relaunchPlanned: Bool = false,
                at offset: TimeInterval = 1) -> SessionInputDecision {
        sessionInputDecision(request: pending, servedEpoch: served, state: state,
                             keyboardIdle: keyboardIdle, relaunchPlanned: relaunchPlanned,
                             now: t0.addingTimeInterval(offset))
    }
    check("nothing pending, nothing to do", decide(nil) == .ignore)
    check("a request this supervisor already served is not served again",
          decide(request("hi"), served: epoch(0)) == .ignore
              && decide(request("hi"), served: epoch(1)) == .ignore)
    check("…and a newer one is", decide(request("hi", at: 2), served: epoch(0), at: 3)
              == .inject(request("hi", at: 2)))

    // The two states that may be typed into.
    check("a session waiting on its user is typed into",
          decide(request("y"), state: .blocked) == .inject(request("y")))
    check("…and so is an idle one", decide(request("y"), state: .idle) == .inject(request("y")))
    // THE DECISION THIS FEATURE TURNS ON. The ordinary caller is an agent inside the conversation
    // running this as a tool call, so at the instant its request lands the session is `working` by
    // construction: refusing on sight would mean the feature never fires on its main path.
    check("a working session is waited for, not refused", decide(request("y"), state: .working)
              == .wait)
    check("…as is one that has not said what it is doing yet",
          decide(request("y"), state: .unknown) == .wait)
    check("somebody typing in that terminal is waited for too",
          decide(request("y"), state: .idle, keyboardIdle: false) == .wait)
    // THE GATE THE STATE CANNOT SHOW: this tick has already decided to terminate the child, and an
    // idle session is precisely what those planners were waiting for - so the reading that looks
    // most ready is the one that must not be typed into (codex review of 18b3174).
    check("a child this tick is about to terminate is not typed into",
          decide(request("y"), state: .idle, relaunchPlanned: true) == .wait
              && decide(request("y"), state: .blocked, relaunchPlanned: true) == .wait)
    // The TTL keeps running through it, deliberately: whether that line still belongs in a
    // conversation whose child has been replaced is the caller's judgement, not this gate's.
    check("…and a request that expires during a relaunch is still refused, not held for ever",
          decide(request("y"), state: .idle, relaunchPlanned: true, at: sessionInputTTL + 1)
              == .refuse(.refusedExpired, "still idle after 120s"))

    // MARK: - What ends the wait

    check("a request that never reached an injectable moment is refused, not left",
          decide(request("y"), state: .working, at: sessionInputTTL + 1)
              == .refuse(.refusedExpired, "still working after 120s"))
    // A session that cannot report what it is doing would never have become injectable by waiting,
    // and its refusal says so rather than blaming the clock.
    check("…and one that never reported anything is refused in its own words",
          decide(request("y"), state: .unknown, at: sessionInputTTL + 1)
              == .refuse(.refusedNotReporting,
                         "this session reported nothing about itself for 120s"))
    // EXPIRY IS JUDGED BEFORE THE STATE GATES, which is the only order that can ever fire: those
    // gates are the reason a request waits at all. So an expired request is refused even at a moment
    // it could otherwise have been typed at.
    check("an expired request is refused even when the session is ready for it",
          decide(request("y"), state: .idle, at: sessionInputTTL + 1)
              == .refuse(.refusedExpired, "still idle after 120s"))
    check("the TTL boundary belongs to the request: exactly its life is still live",
          !sessionInputExpired(epoch: epoch(0), now: t0.addingTimeInterval(sessionInputTTL))
              && sessionInputExpired(epoch: epoch(0),
                                     now: t0.addingTimeInterval(sessionInputTTL + 0.001)))

    // MARK: - The limit, in bytes

    // The command checks this too, but this directory is writable by anything running as this user,
    // and the poll loop's worst-case stall is what the bound protects (SessionInput.swift).
    let atLimit = String(repeating: "a", count: sessionInputMaxBytes)
    check("a request at the limit is typed", decide(request(atLimit)) == .inject(request(atLimit)))
    check("…and one byte past it is refused",
          decide(request(atLimit + "a")) == .refuse(.refusedTooLong, "201 bytes, limit 200"))
    // BYTES, NOT CHARACTERS, which is the whole reason the limit is stated in bytes: 100 CJK
    // characters are 300 bytes and cost three times the injection a Latin line of the same length
    // does. A character-counting limit would pass this.
    let cjk = String(repeating: "字", count: 100)
    check("the limit counts UTF-8 bytes rather than characters",
          cjk.count == 100 && cjk.utf8.count == 300
              && decide(request(cjk)) == .refuse(.refusedTooLong, "300 bytes, limit 200"))
    check("…and a multibyte line that fits is typed",
          decide(request(String(repeating: "字", count: 66)))
              == .inject(request(String(repeating: "字", count: 66))))

    // MARK: - The ioctl this rests on

    // `_IOW('t', 114, char)`: IOC_IN, then sizeof(char) in the parameter field, the group letter and
    // the number. Asserted against the expansion rather than taken on faith, because TIOCSTI is a
    // legacy interface (Linux 6.2 removed it outright) and the day this platform retires it, a test
    // naming the number fails more clearly than an ioctl that quietly returns EINVAL.
    let computed = UInt(0x8000_0000) | (UInt(MemoryLayout<CChar>.size & 0x1fff) << 16)
        | (UInt(UInt8(ascii: "t")) << 8) | 114
    check("the injection ioctl is _IOW('t', 114, char)",
          sessionInputInjectRequest == computed && sessionInputInjectRequest == 0x8001_7472)
    check("Return is CR, which is what a terminal sends", sessionInputReturnByte == 13)
    // The failure arm of the writer, on a path that is not a terminal: the errno differs by
    // platform, so what is pinned is that it fails rather than reporting success.
    check("a target that is not a terminal fails rather than pretending",
          injectSessionInput("a", tty: "/dev/null", gap: 0, pause: 0) != .done)
    check("…and so does one that cannot be opened at all",
          injectSessionInput("a", tty: dir.appendingPathComponent("nope").path,
                             gap: 0, pause: 0) != .done)
    // RETURN IS PRESSED EVEN WITH NOTHING TO TYPE, which this arm can prove without a terminal: an
    // empty send performs exactly one ioctl, the Return, so a writer that skipped it would have
    // nothing left to fail at and would answer `.done` on a target that is not a terminal at all.
    check("an empty send still presses Return, which is the whole of that request",
          injectSessionInput("", tty: "/dev/null", gap: 0, pause: 0) != .done)

    // MARK: - The tick

    /// One tick against a session key of its own, with the injection recorded rather than performed.
    /// Returns what was typed, so a check can assert both the outcome and the bytes. One value per
    /// injection rather than a pair: whether Return follows is no longer a question anybody asks.
    func tick(state: SupervisedState, keyboardIdle: Bool = true, relaunchPlanned: Bool = false,
              at offset: TimeInterval = 1, input: inout SessionInputState,
              inject: @escaping (String) -> SessionInputInjection = { _ in .done }) -> [String] {
        var typed: [String] = []
        applySessionInput(&input, session: state, keyboardIdle: keyboardIdle,
                          relaunchPlanned: relaunchPlanned, dir: dir, log: log,
                          now: t0.addingTimeInterval(offset)) { text in
            typed.append(text)
            return inject(text)
        }
        return typed
    }

    var served = SessionInputState(sessionKey: "9201", servedEpoch: 0)
    try? writeSessionInputRequest(request("/help"), sessionKey: "9201", dir: dir)
    var typed = tick(state: .blocked, input: &served)
    check("a blocked session is typed into, exactly what was asked",
          typed == ["/help"])
    check("…the answer names the request it answers",
          readSessionInputResult(sessionKey: "9201", dir: dir)
              == SessionInputResult(epoch: epoch(0), outcome: "submitted", detail: nil))
    check("…the request is taken away once it is served",
          readSessionInputRequest(sessionKey: "9201", dir: dir) == nil)
    check("…and the stamp is remembered", served.servedEpoch == epoch(0))
    // Idempotence from the other side: the same request put back is not served twice, which is what
    // the stamp is for (the file is unlinked, but a supervisor mid-write could still read one).
    try? writeSessionInputRequest(request("/help"), sessionKey: "9201", dir: dir)
    check("the same request written again is not typed a second time",
          tick(state: .blocked, input: &served).isEmpty)
    clearSessionInputRequest(sessionKey: "9201", dir: dir)

    // A tick that waits writes NOTHING: no answer, and the request stays exactly where it is, so the
    // next tick decides again from scratch.
    var waiting = SessionInputState(sessionKey: "9202", servedEpoch: 0)
    try? writeSessionInputRequest(request("hello"), sessionKey: "9202", dir: dir)
    check("a working session is not typed into",
          tick(state: .working, input: &waiting).isEmpty)
    check("…and nothing is answered while it waits",
          readSessionInputResult(sessionKey: "9202", dir: dir) == nil
              && readSessionInputRequest(sessionKey: "9202", dir: dir) != nil
              && waiting.servedEpoch == 0)
    // Then the turn ends, and the same request lands - which is the whole promise of waiting rather
    // than refusing.
    typed = tick(state: .idle, at: 5, input: &waiting)
    check("the turn ends and the waiting request is typed then",
          typed == ["hello"]
              && readSessionInputResult(sessionKey: "9202", dir: dir)?.outcome == "submitted")

    // …and through the tick, where what matters is that a wait writes NOTHING: no bytes, no answer
    // for the caller to read as success, and a request left exactly where it was for the next tick.
    var planned = SessionInputState(sessionKey: "9208", servedEpoch: 0)
    try? writeSessionInputRequest(request("during-relaunch"), sessionKey: "9208", dir: dir)
    check("a tick with a relaunch planned types nothing, even into an idle session",
          tick(state: .idle, relaunchPlanned: true, input: &planned).isEmpty)
    check("…and answers nothing, so the caller is never told a lost line was delivered",
          readSessionInputResult(sessionKey: "9208", dir: dir) == nil
              && readSessionInputRequest(sessionKey: "9208", dir: dir)
              == request("during-relaunch")
              && planned.servedEpoch == 0)
    typed = tick(state: .idle, at: 5, input: &planned)
    check("…and the next tick, against the new child, types it",
          typed == ["during-relaunch"]
              && readSessionInputResult(sessionKey: "9208", dir: dir)?.outcome == "submitted")

    // A PLANNED RELAUNCH IS NOT A RELAUNCH, and the difference is the whole of this gate. The fork
    // hold can stand a plan down and leave the child running, and a gate wired to "is there a plan"
    // then refuses to type for as long as the fork stays unresolved - while the thing that RESOLVES
    // a fork is a new turn, which is exactly what the pending line was going to start. The two
    // cases are asserted side by side because that is the distinction the wiring got wrong
    // (codex review of 1615990).
    let forked = ForkFixture("session-input-hold")
    forked.write("parent.jsonl", ["{}"], born: -3600, wrote: -580)
    var forkedWatcher = forked.watcher(pinnedTo: "parent")
    check("the fork fixture starts with nothing to hold on", forkedWatcher.isQuiet(5))
    forked.write("cleared.jsonl", forked.clearedLines(own: "cleared"), born: 30, wrote: 120)
    let held = relaunchIsHappening(plan: RelaunchPlan(target: sessionInputAccount, reason: "reload",
                                                      countsFuse: false),
                                   watcher: &forkedWatcher)
    check("a plan an unresolved fork stands down is not a relaunch this tick",
          !held && forkedWatcher.hasUnresolvedFork)
    // …and a cap is never held, so THAT plan really does replace the child.
    var capWatcher = forkedWatcher
    check("…while a cap handoff, which no fork holds, is one",
          relaunchIsHappening(plan: RelaunchPlan(target: sessionInputAccount, reason: "cap",
                                                 countsFuse: true), watcher: &capWatcher))
    check("…and a tick with no plan at all is not one either",
          !relaunchIsHappening(plan: nil, watcher: &capWatcher))
    // The behaviour that closes the loop: the stood-down tick types, so the turn that resolves the
    // fork can start.
    var stoodDown = SessionInputState(sessionKey: "9209", servedEpoch: 0)
    try? writeSessionInputRequest(request("resolve-the-fork"), sessionKey: "9209", dir: dir)
    typed = tick(state: .idle, relaunchPlanned: held, input: &stoodDown)
    check("a tick whose relaunch stood down types the line that would end the hold",
          typed == ["resolve-the-fork"]
              && readSessionInputResult(sessionKey: "9209", dir: dir)?.outcome == "submitted")

    // Expiry, through the tick rather than the pure function, so the consuming half is covered too.
    var expired = SessionInputState(sessionKey: "9203", servedEpoch: 0)
    try? writeSessionInputRequest(request("late"), sessionKey: "9203", dir: dir)
    check("a request that expired while the session worked is not typed",
          tick(state: .working, at: sessionInputTTL + 5, input: &expired).isEmpty)
    check("…it is answered with a refusal and taken away",
          readSessionInputResult(sessionKey: "9203", dir: dir)?.outcome == "refused-expired"
              && readSessionInputRequest(sessionKey: "9203", dir: dir) == nil)

    // A terminal that refused the write is reported as such, with the errno, and the request is
    // consumed: retrying it on the next tick would spend the same six seconds on the same failure.
    var broken = SessionInputState(sessionKey: "9204", servedEpoch: 0)
    try? writeSessionInputRequest(request("x"), sessionKey: "9204", dir: dir)
    _ = tick(state: .idle, input: &broken, inject: { _ in .failed(ENXIO) })
    let failure = readSessionInputResult(sessionKey: "9204", dir: dir)
    check("a terminal that refused the write says so, with the errno",
          failure?.outcome == "failed-tty" && failure?.detail?.contains("errno \(ENXIO)") == true
              && readSessionInputRequest(sessionKey: "9204", dir: dir) == nil)

    // THE RACE THE CONSUMPTION GUARD EXISTS FOR: injection takes seconds, and a second `tally
    // session send` written in that window is a newer stamp at the same path. Unlinking
    // unconditionally would delete an instruction nobody has carried out.
    var raced = SessionInputState(sessionKey: "9205", servedEpoch: 0)
    try? writeSessionInputRequest(request("first"), sessionKey: "9205", dir: dir)
    _ = tick(state: .idle, input: &raced, inject: { _ in
        try? writeSessionInputRequest(request("second", at: 2), sessionKey: "9205", dir: dir)
        return .done
    })
    check("a request written while the first was being typed is left for the next tick",
          readSessionInputRequest(sessionKey: "9205", dir: dir) == request("second", at: 2))
    check("…and the answer that was written is the one that was served",
          readSessionInputResult(sessionKey: "9205", dir: dir)?.epoch == epoch(0))
    typed = tick(state: .idle, at: 3, input: &raced)
    check("…which the next tick then serves", typed == ["second"])

    // The seed: a request addressed to a pid that has come round again is not typed into whoever got
    // it next. `servedEpoch` defaults to whatever is pending at start-up.
    try? writeSessionInputRequest(request("stranger"), sessionKey: "9206", dir: dir)
    var reused = SessionInputState(sessionKey: "9206", dir: dir)
    check("a request left by a session that exited is seeded away, not replayed",
          reused.servedEpoch == epoch(0)
              && tick(state: .idle, input: &reused).isEmpty)
    // …and the self-update path, which keeps the pid and IS the same session, opts out of that seed.
    try? writeSessionInputRequest(request("mine", at: 1), sessionKey: "9207", dir: dir)
    var resumed = SessionInputState(sessionKey: "9207", servedEpoch: 0, dir: dir)
    check("a request written just before a self-update is still served afterwards",
          tick(state: .idle, at: 2, input: &resumed).count == 1)

    // MARK: - When the answer cannot be written

    // The receipt is the only thing the caller is blocked on, so a write that fails and says nothing
    // leaves it waiting out its whole timeout for an answer that is not coming - AFTER the text has
    // been typed. It then reports "nobody answered", and a caller that acts on that by sending the
    // line again has typed it into that conversation twice (codex review of 18b3174).
    //
    // The failure is made by putting a directory where the answer goes, so the rename cannot land:
    // what an unwritable directory or a full disk look like from here, without needing either.
    let lostLog = dir.appendingPathComponent("lost.log")
    let lostKey = "9211"
    try? FileManager.default.createDirectory(at: sessionInputResultFile(sessionKey: lostKey,
                                                                       dir: dir),
                                             withIntermediateDirectories: true)
    check("a published answer reports no failure",
          writeSessionInputResult(SessionInputResult(epoch: 1, outcome: "submitted", detail: nil),
                                  sessionKey: "9212", dir: dir) == nil)
    check("…and one that cannot be written says why rather than merely failing",
          writeSessionInputResult(SessionInputResult(epoch: 1, outcome: "submitted", detail: nil),
                                  sessionKey: lostKey, dir: dir) != nil)
    clearSessionInputResult(sessionKey: "9212", dir: dir)
    var lost = SessionInputState(sessionKey: lostKey, servedEpoch: 0)
    try? writeSessionInputRequest(request("/clear"), sessionKey: lostKey, dir: dir)
    var lostTyped: [String] = []
    applySessionInput(&lost, session: .idle, keyboardIdle: true, relaunchPlanned: false, dir: dir,
                      log: lostLog, now: t0.addingTimeInterval(1)) { text in
        lostTyped.append(text)
        return .done
    }
    check("the text is typed even though the answer cannot be published",
          lostTyped == ["/clear"])
    let lostWritten = (try? String(contentsOf: lostLog, encoding: .utf8)) ?? ""
    check("…and the lost answer leaves a line, so a session typed into twice can be explained",
          lostWritten.contains("pid=\(lostKey) input=receipt-lost")
              && lostWritten.contains("served=submitted")
              && lostWritten.contains("epoch=\(epoch(0))"))
    check("…beside the line saying what was typed, in that order",
          lostWritten.range(of: "pid=\(lostKey) input=submitted").map { typedLine in
              lostWritten.range(of: "input=receipt-lost").map { typedLine.upperBound < $0.lowerBound }
                  ?? false
          } ?? false)
    // AND THE STAMP MOVED ANYWAY, which is the half that decides whether this failure costs a wait
    // or a duplicated line: the bytes are on the terminal, so a tick that decided the same request
    // again would type it a second time.
    check("…the stamp records what was served, whatever became of the answer",
          lost.servedEpoch == epoch(0)
              && readSessionInputRequest(sessionKey: lostKey, dir: dir) == nil)
    try? writeSessionInputRequest(request("/clear"), sessionKey: lostKey, dir: dir)
    var lostAgain: [String] = []
    applySessionInput(&lost, session: .idle, keyboardIdle: true, relaunchPlanned: false, dir: dir,
                      log: lostLog, now: t0.addingTimeInterval(2)) { text in
        lostAgain.append(text)
        return .done
    }
    check("…so the same request put back is still not typed a second time", lostAgain.isEmpty)

    // MARK: - The audit line

    let written = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    check("every served request left a line", written.components(separatedBy: "\n")
              .filter { $0.contains("input=") }.count == 9)
    check("…naming the session, the outcome and the text",
          written.contains("pid=9201 input=submitted bytes=5 text=/help"))
    // NO `submit` COLUMN. It read `yes` on every line ever written once typing and sending became
    // one act, and a field that cannot vary answers nothing anybody greps a log for.
    check("…and nothing in it says whether Return was pressed, which is never in question",
          !written.contains("submit="))
    check("…and a refusal is recorded as loudly as a delivery",
          written.contains("pid=9203 input=refused-expired"))
    // The text is the one field that can contain a space, so it goes last; control bytes are
    // replaced rather than written through, because a log nobody can `cat` safely is not a log.
    let noisy = sessionInputLogLine(pid: "1", outcome: "submitted", text: "a\nb\u{1B}[2Jc",
                                    now: t0)
    check("a control byte in the text cannot reach the log",
          noisy.hasSuffix("text=a·b·[2Jc\n") && noisy.components(separatedBy: "\n").count == 2)
    check("…and a long line is truncated to what a reader needs",
          sessionInputLogLine(pid: "1", outcome: "submitted",
                              text: String(repeating: "x", count: 120), now: t0)
              .hasSuffix("bytes=120 text=\(String(repeating: "x", count: 40))\n"))

    // MARK: - …and nobody else on this machine may read it

    /// Run `body` with the process umask pinned, and put the old one back whatever happens.
    ///
    /// Several checks below are about a mode that a umask could FILTER, and reading the ambient one
    /// makes them assertions about the machine rather than about the code (codex review of
    /// 80499b3). Pinning is also what makes them discriminating: under a strict umask a wrong mode
    /// argument is trimmed into looking right, so the value alone proves nothing.
    func underUmask<Result>(_ mask: mode_t, _ body: () -> Result) -> Result {
        let previous = umask(mask)
        defer { umask(previous) }
        return body()
    }

    /// The mode a path is at, or nil when there is nothing there.
    func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }
    // THE CONVERGENCE, through the live path: the fixture above was laid down at 0644, and the ticks
    // that have run since are what had to bring it in. This is the case a mode set only at creation
    // would miss entirely, and it is the case every machine that ran an earlier build is in.
    check("a log an earlier build left world-readable is brought in to 0600 by the tick",
          mode(log) == 0o600)
    check("…without losing what was already in it", written.contains("input=submitted"))
    // Unlike everything else under ~/.tally, and on purpose: those files record events ABOUT the
    // work (accounts, quota, moves), this one records the work - text typed into a live
    // conversation. A check rather than only a comment, because "make it consistent with its
    // neighbours" is exactly the tidy-up this has to survive.
    check("…and the mode this log is kept at is not the 0644 its neighbours use",
          sessionInputLogMode == 0o600)
    // A log that does not exist yet is CREATED closed, rather than created open and chmod'd after
    // its first line is already on disk.
    let fresh = dir.appendingPathComponent("fresh/input.log")
    appendSessionInputLine("first line\n", to: fresh)
    check("a log created by this build is closed from its first byte",
          mode(fresh) == 0o600
              && (try? String(contentsOf: fresh, encoding: .utf8)) == "first line\n")
    // And an append onto a file somebody has since opened up closes it again, rather than trusting
    // the mode it was created with to still hold.
    try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: fresh.path)
    appendSessionInputLine("second line\n", to: fresh)
    check("…and one reopened behind our back is closed again on the next line",
          mode(fresh) == 0o600
              && (try? String(contentsOf: fresh, encoding: .utf8)) == "first line\nsecond line\n")

    // MARK: - …and neither may the requests, which hold the text UNtruncated

    // THE SAME DECISION AS THE LOG, and it has to be or the feature contradicts itself: the log
    // keeps 40 characters with the control bytes replaced, a request file holds the whole line
    // verbatim for as long as the TTL. A 0600 log beside a 0644 request would be a lock on the
    // window and none on the door (codex review of 18b3174).
    let closed = dir.appendingPathComponent("closed-input")
    try? writeSessionInputRequest(request("secret text"), sessionKey: "9301", dir: closed)
    check("the directory a request lands in is created 0700", mode(closed) == 0o700)
    check("…the request itself 0600", mode(sessionInputFile(sessionKey: "9301", dir: closed))
              == 0o600)
    // AND UNDER A UMASK THAT CANNOT FABRICATE THAT ANSWER, which is what makes the line above
    // evidence rather than a coincidence. A machine at 077 trims any wider request down to 0600 by
    // itself, so an implementation that asked for the wrong mode would read as correct there and
    // only there; at 022 a wrong argument comes out 0644. Caught by mutation: the production mode
    // constant could be replaced with 0666 and every other check here still passed, on a 077 run.
    let pinned = dir.appendingPathComponent("pinned-umask")
    underUmask(0o022) {
        try? writeSessionInputRequest(request("under a known umask"), sessionKey: "9303",
                                      dir: pinned)
    }
    check("…and it is the mode this code asks for, not one a strict umask trimmed into shape",
          mode(sessionInputFile(sessionKey: "9303", dir: pinned)) == 0o600
              && mode(pinned) == 0o700)
    writeSessionInputResult(SessionInputResult(epoch: 1, outcome: "submitted", detail: nil),
                            sessionKey: "9301", dir: closed)
    check("…and the answer beside it, which quotes nothing but is addressed the same way",
          mode(sessionInputResultFile(sessionKey: "9301", dir: closed)) == 0o600)
    // ATOMIC AND PRIVATE AT ONCE: `.atomic` renames a temporary over the destination and a rename
    // carries the TEMPORARY's mode, so a destination pre-created at 0600 proves nothing. The check
    // that separates the two is a write over an existing file: the mode that survives is the one
    // the new inode was made with.
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: sessionInputFile(sessionKey: "9301", dir: closed).path)
    try? writeSessionInputRequest(request("second", at: 2), sessionKey: "9301", dir: closed)
    check("a request written over a world-readable one is closed, not left as it found it",
          mode(sessionInputFile(sessionKey: "9301", dir: closed)) == 0o600)
    check("…and the write is still atomic, so the content is whole",
          readSessionInputRequest(sessionKey: "9301", dir: closed) == request("second", at: 2))
    // A directory an earlier build left at 0755 is brought in, for the reason the log's is: a mode
    // applied only at creation never reaches the machines that already ran.
    try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                           ofItemAtPath: closed.path)
    try? writeSessionInputRequest(request("third", at: 3), sessionKey: "9301", dir: closed)
    check("a directory an earlier build left listable is brought in to 0700", mode(closed) == 0o700)
    // Nothing of ours is left behind by the rename: a temporary that outlived its write would be a
    // second copy of the text sitting in the directory under a name nothing sweeps.
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: closed.path))?
        .filter { $0.hasPrefix(".") } ?? []
    check("the temporary the atomic write used does not survive it", leftovers.isEmpty)
    // A directory that cannot be narrowed does not stop the write, but it does not pass in silence
    // either: the difference between "narrowed" and "could not be narrowed" has to exist somewhere
    // a person can read it.
    // AND THE WIRING, not just the sentence: a directory made to refuse a chmod, deterministically
    // and reversibly. UF_IMMUTABLE is settable by the owner and blocks chmod (measured on this
    // machine, 2026-08-13), which is the only way a process can make its OWN directory refuse.
    // Without this the line builder was asserted and nothing checked that anything ever called it.
    let stubborn = dir.appendingPathComponent("stubborn")
    try? FileManager.default.createDirectory(at: stubborn, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o755])
    let stubbornLog = dir.appendingPathComponent("stubborn.log")
    check("the immutable flag really took", chflags(stubborn.path, UInt32(UF_IMMUTABLE)) == 0)
    try? makeSessionInputDirectory(stubborn, log: stubbornLog)
    check("a directory that cannot be narrowed is recorded rather than passed over in silence",
          ((try? String(contentsOf: stubbornLog, encoding: .utf8)) ?? "")
              .contains("input=directory-mode"))
    check("…and it really was refused, so the check is about a failure that happened",
          mode(stubborn) == 0o755)
    chflags(stubborn.path, 0)
    check("a chmod that fails leaves a line naming the directory and the reason",
          sessionInputDirectoryModeLine(dir: URL(fileURLWithPath: "/x/input"),
                                        failure: sessionInputPOSIXError(EPERM), now: t0)
              .contains("input=directory-mode wanted=700")
              && sessionInputDirectoryModeLine(dir: URL(fileURLWithPath: "/x/input"),
                                               failure: sessionInputPOSIXError(EPERM), now: t0)
              .hasSuffix("dir=/x/input\n"))
    check("…and the mode it wanted is the one it is kept at, not a second copy of the number",
          sessionInputDirectoryModeLine(dir: dir, failure: sessionInputPOSIXError(EPERM), now: t0)
              .contains("wanted=\(String(sessionInputDirMode, radix: 8))"))
    check("…and the modes are named once, not typed twice",
          sessionInputFileMode == 0o600 && sessionInputDirMode == 0o700
              && sessionInputFileMode == sessionInputLogMode)

    // MARK: - The two sweeps, and the division between them

    // A pid the OS cannot be running: `supervisorAlive` is asked rather than assumed, so this check
    // cannot quietly become a test of nothing on a machine with a huge pid space.
    let deadPid = "999999"
    check("the fixture's dead pid really is dead", !supervisorAlive(pid_t(deadPid)!))
    let livePid = String(getpid())
    for pid in [deadPid, livePid] {
        try? writeSessionInputRequest(request("x"), sessionKey: pid, dir: dir)
        writeSessionInputResult(SessionInputResult(epoch: 1, outcome: "submitted", detail: nil),
                                sessionKey: pid, dir: dir)
    }
    sweepDeadSessionInputResults(dir: dir)
    check("an answer nobody came back for is swept once its session is gone",
          readSessionInputResult(sessionKey: deadPid, dir: dir) == nil)
    check("…and a live session's is left alone",
          readSessionInputResult(sessionKey: livePid, dir: dir) != nil)
    // THE DIVISION: the shared sweep reads a file name as a pid outright, so it owns the bare names
    // and this one owns the suffixed neighbours. Asserted from both sides, because the failure is a
    // sweep quietly reaching into names it never agreed to read.
    check("the answers are not the shared sweep's to remove",
          readSessionInputRequest(sessionKey: deadPid, dir: dir) != nil)
    sweepDeadSessionRequests(dir: dir)
    check("…and the requests are",
          readSessionInputRequest(sessionKey: deadPid, dir: dir) == nil
              && readSessionInputRequest(sessionKey: livePid, dir: dir) != nil)
    check("…while the live answer survives both", readSessionInputResult(sessionKey: livePid,
                                                                        dir: dir) != nil)
    clearSessionInputRequest(sessionKey: livePid, dir: dir)
    clearSessionInputResult(sessionKey: livePid, dir: dir)
}
