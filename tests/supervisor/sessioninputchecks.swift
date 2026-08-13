import Foundation

// `tally session send`: the channel (SessionInputRequest.swift), the gate table and the tick that
// serves one (SessionInput.swift), and the command's grammar and wording (SessionInputCommand.swift).
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

    // MARK: - The command's grammar

    check("one word is the text", sessionSendIntent(["hello"])
              == SessionSendIntent(text: "hello", session: nil))
    check("--session names another one", sessionSendIntent(["--session", "412", "hi"])
              == SessionSendIntent(text: "hi", session: "412"))
    // NO TEXT IS A REQUEST IN ITS OWN RIGHT: press Return, type nothing, which is how a prompt
    // sitting on its default gets answered. It used to be spelled `--submit` with no text; the
    // absence of an argument is what means it now.
    check("no text at all presses Return and types nothing",
          sessionSendIntent([]) == SessionSendIntent(text: "", session: nil))
    check("…and it can be aimed at another session too",
          sessionSendIntent(["--session", "412"]) == SessionSendIntent(text: "", session: "412"))
    // THE FLAG THAT USED TO SAY "AND SEND IT" IS NOT A FLAG ANY MORE, so it is content or an error
    // like any other unknown word, and never a silently accepted no-op that makes a caller believe
    // it asked for something.
    check("--submit is no longer a flag this command knows",
          sessionSendIntent(["hello", "--submit"]) == nil && sessionSendIntent(["--submit"]) == nil)
    // Two bare words differ from one by exactly the whitespace the shell ate, and there is no
    // reading that is safe to guess at.
    check("two words are a usage error rather than a join",
          sessionSendIntent(["hello", "there"]) == nil)
    check("a flag this command does not know is not content",
          sessionSendIntent(["--force"]) == nil && sessionSendIntent(["-x", "hi"]) == nil)
    check("--session without a value, or twice, is a usage error",
          sessionSendIntent(["--session"]) == nil
              && sessionSendIntent(["--session", "1", "--session", "2", "hi"]) == nil)
    // `--` is what makes text that looks like a flag sendable at all.
    check("-- ends the flags, so a dash can be sent",
          sessionSendIntent(["--", "--submit"]) == SessionSendIntent(text: "--submit", session: nil)
              && sessionSendIntent(["--session", "9", "--", "--help"])
              == SessionSendIntent(text: "--help", session: "9"))

    check("the command refuses an over-long line before anything is written",
          sessionSendProblem(SessionSendIntent(text: atLimit + "a", session: nil))?
              .contains("201 bytes") == true)
    check("…and says nothing about one that fits",
          sessionSendProblem(SessionSendIntent(text: atLimit, session: nil)) == nil)
    // An empty line is no longer a problem to report: it is the Return-only request.
    check("…nor about an empty one, which is the Return-only request",
          sessionSendProblem(SessionSendIntent(text: "", session: nil)) == nil)

    // The one line a namespace with one verb in it says, and the verb it names.
    check("the usage text documents the verb that exists",
          sessionSendUsage.contains("tally session send [<text>] [--session <pid>]")
              && !sessionSendUsage.contains("--submit")
              && sessionUsage == "usage: tally session send [<text>] [--session <pid>]")

    // MARK: - One send at a time at one address

    // One address holds one send, so a second one written while the first is still in flight lands
    // ON it: the first caller then waits for something that exists nowhere, is told nobody answered,
    // and nothing on either end records that an instruction was dropped (codex review of 18b3174).
    // So the second caller is refused instead.
    let busyKey = "9301"
    let occupant = request("first")
    check("an address with nothing at it is free",
          sessionInputOccupant(sessionKey: busyKey, dir: dir, now: t0.addingTimeInterval(1)) == nil)
    try? writeSessionInputRequest(occupant, sessionKey: busyKey, dir: dir)
    check("…a request still inside its life occupies it",
          sessionInputOccupant(sessionKey: busyKey, dir: dir, now: t0.addingTimeInterval(1))
              == .request(occupant))
    // A husk does NOT occupy it: the supervisor refuses it the next time it looks, and treating it
    // as an occupant would take the address away for two minutes over a caller killed mid-wait.
    check("…and one past its life does not",
          sessionInputOccupant(sessionKey: busyKey, dir: dir,
                               now: t0.addingTimeInterval(sessionInputTTL + 1)) == nil)
    let busy = sessionInputBusyRefusal(.request(occupant), sessionKey: busyKey,
                                       now: t0.addingTimeInterval(20))
    check("the second caller is told nothing was queued, and how long the first one has left",
          busy.contains(busyKey) && busy.contains("nothing was queued")
              && busy.contains("\(Int(sessionInputTTL) - 20)s"))
    // TELLABLE APART FROM A GATE REFUSAL, which is the point of wording it separately: those mean
    // "the session was busy or silent, this may work later", and this one means "your text was
    // never queued at all, because something else is already using this address".
    check("…and it does not read like one of the gate's refusals",
          !busy.contains("never reached a moment") && !busy.contains("never reported"))
    clearSessionInputRequest(sessionKey: busyKey, dir: dir)

    // THE OTHER HALF OF A SEND'S LIFE, which is the state this check used to be blind to: the
    // supervisor writes the answer and then unlinks the request, so between two of the first
    // caller's 250ms polls the address holds an answer and NO request. Reading that as empty is
    // what let the next caller delete a delivery report for text that was already typed, leaving
    // the first caller to time out and reasonably send the same line again (codex review of
    // 3c37831).
    let servedAnswer = SessionInputResult(epoch: epoch(0), outcome: "submitted", detail: nil)
    writeSessionInputResult(servedAnswer, sessionKey: busyKey, dir: dir)
    check("an answer nobody has collected yet occupies the address, with no request in sight",
          readSessionInputRequest(sessionKey: busyKey, dir: dir) == nil
              && sessionInputOccupant(sessionKey: busyKey, dir: dir,
                                      now: t0.addingTimeInterval(1)) == .answer(servedAnswer))
    // AND IT IS LIVE FOR THE CALLER'S WAIT, NOT THE REQUEST'S TTL. The two differ by 30 seconds and
    // the difference is not academic: a `refused-expired` answer is written when the request has
    // just passed the TTL, so under the TTL it would be a husk at birth - deletable out from under
    // a caller who is still polling for exactly it.
    check("…and it is still there past the request's own TTL, because the caller waits longer",
          sessionInputOccupant(sessionKey: busyKey, dir: dir,
                               now: t0.addingTimeInterval(sessionInputTTL + 5))
              == .answer(servedAnswer))
    check("…while past the longest wait anybody makes it is a husk like any other",
          sessionInputOccupant(sessionKey: busyKey, dir: dir,
                               now: t0.addingTimeInterval(sessionInputWaitSeconds + 1)) == nil)
    // A REQUEST OUTRANKS AN ANSWER when both are there (a newer send served while an older answer
    // sits uncollected): what the caller is told should name the thing that has not happened yet.
    try? writeSessionInputRequest(request("second", at: 1), sessionKey: busyKey, dir: dir)
    check("…and a request present alongside an answer is what the address is said to hold",
          sessionInputOccupant(sessionKey: busyKey, dir: dir, now: t0.addingTimeInterval(2))
              == .request(request("second", at: 1)))
    clearSessionInputRequest(sessionKey: busyKey, dir: dir)
    let uncollected = sessionInputBusyRefusal(.answer(servedAnswer), sessionKey: busyKey,
                                              now: t0.addingTimeInterval(20))
    // The two wordings differ because what the caller should do differs: one is "wait, it will be
    // served or expire", the other is "somebody's delivery report is sitting here and the text is
    // already in the session".
    check("an uncollected answer is refused in its own words, naming the outcome and the wait left",
          uncollected.contains(busyKey) && uncollected.contains("nothing was queued")
              && uncollected.contains("submitted")
              && uncollected.contains("\(Int(sessionInputWaitSeconds) - 20)s")
              && uncollected != busy)
    check("…and it does not read like one of the gate's refusals either",
          !uncollected.contains("never reached a moment") && !uncollected.contains("never reported"))
    clearSessionInputResult(sessionKey: busyKey, dir: dir)

    // MARK: - Which pid --session may name

    // Liveness alone says a process is there and nothing about what it is, so `--session <any live
    // pid>` used to write a file holding somebody's text to an address nothing would ever read.
    // The registry a supervisor writes itself into (`markSupervisorLive`) is what tells them apart.
    let registry = dir.appendingPathComponent("registry")
    try? FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    let ownPid = String(getpid())
    check("a live process with no presence entry is not a session to type into",
          namedSession(ownPid, dir: registry) == .notSupervised)
    try? "".write(to: registry.appendingPathComponent(ownPid), atomically: true, encoding: .utf8)
    check("…and the same pid once it is registered is one",
          namedSession(ownPid, dir: registry) == .session(ownPid))
    check("a pid nothing is running under is neither",
          namedSession(deadPid, dir: registry) == .notRunning)
    check("…nor is a word that is not a pid at all",
          namedSession("session-9301", dir: registry) == .notRunning)
    // Normalised through the pid, so a padded number addresses the same file the bare one does.
    check("--session 0<pid> addresses the same session <pid> does",
          namedSession("0" + ownPid, dir: registry) == .session(ownPid))
    // The registry is asked for THIS machine's supervisors rather than reimplemented: an entry
    // under a dead pid is not one, whatever the file says.
    try? "".write(to: registry.appendingPathComponent(deadPid), atomically: true, encoding: .utf8)
    check("…and an entry left behind by a dead supervisor names nothing",
          namedSession(deadPid, dir: registry) == .notRunning)

    // MARK: - What the caller is told, and what it exits on

    check("the four exit codes are kept apart",
          sessionInputExitCode(nil) == 4
              && sessionInputExitCode(SessionInputResult(epoch: 1, outcome: "submitted",
                                                         detail: nil)) == 0
              && sessionInputExitCode(SessionInputResult(epoch: 1, outcome: "refused-expired",
                                                         detail: nil)) == 3
              && sessionInputExitCode(SessionInputResult(epoch: 1, outcome: "failed-tty",
                                                         detail: nil)) == 3)
    // An outcome this build has never heard of exits as a refusal AND is reported verbatim: the word
    // is the only information a CLI behind its supervisor has.
    check("an unfamiliar outcome exits as a refusal and is quoted back",
          sessionInputExitCode(future) == 3
              && sessionInputMessage(future, sessionKey: "9").contains("\"refused-something-new\""))
    for outcome in [SessionInputOutcome.submitted, .refusedTooLong, .refusedNotReporting,
                    .refusedExpired, .failedTTY] {
        let message = sessionInputMessage(SessionInputResult(epoch: 1, outcome: outcome.rawValue,
                                                             detail: "why"),
                                          sessionKey: "9208")
        check("`\(outcome.rawValue)` is worded for the caller, and carries the detail",
              !message.isEmpty && message.contains("(why)"))
    }
    check("the delivered wording names the session that got the text, and says it was sent",
          sessionInputMessage(SessionInputResult(epoch: 1, outcome: "submitted", detail: nil),
                              sessionKey: "9208").contains("sent to session 9208"))
    // A word from a build that still had the composer-only outcome is reported verbatim rather than
    // read as a delivery: this build cannot produce it, and guessing what somebody else meant by it
    // is how a caller is told a line landed when it is sitting in a composer.
    check("…and a build's leftover `injected` is quoted back rather than believed",
          sessionInputMessage(SessionInputResult(epoch: 1, outcome: "injected", detail: nil),
                              sessionKey: "9").contains("\"injected\"")
              && sessionInputExitCode(SessionInputResult(epoch: 1, outcome: "injected",
                                                         detail: nil)) == 3)

    // MARK: - The wait

    var clock = t0
    var slept = 0
    var husk: SessionInputResult? = SessionInputResult(epoch: 7, outcome: "submitted", detail: nil)
    let waited = awaitSessionInputResult(
        sessionKey: "9209", epoch: 8, timeout: 1, interval: 0.25, now: { clock },
        sleep: { slept += 1; clock = clock.addingTimeInterval($0) },
        read: { _ in husk })
    // MATCHED ON THE EPOCH, which is the whole reason an answer carries one: a husk from an earlier
    // request can still be at that path, and reading it as this one's would report a delivery that
    // never happened.
    check("an answer to somebody else's request is not this one's", waited == nil && slept == 4)
    clock = t0
    slept = 0
    husk = nil
    let arrived = awaitSessionInputResult(
        sessionKey: "9209", epoch: 8, timeout: 10, interval: 0.25, now: { clock },
        sleep: { _ in
            slept += 1
            if slept == 3 { husk = SessionInputResult(epoch: 8, outcome: "submitted", detail: nil) }
        },
        read: { _ in husk })
    check("…and the one that is arrives as soon as it is written",
          arrived?.outcome == "submitted" && slept == 3)
    check("the wait outlasts the request's own life, or it would time out on answers about to come",
          sessionInputWaitSeconds > sessionInputTTL)

    // MARK: - The tick's own reading is what the gate sees

    // `applySessionInput` is handed the state THIS tick decided rather than the file's, which is
    // what makes the moment a turn ends usable at all - so the publisher has to hand it back.
    let statedir = dir.appendingPathComponent("state")
    try? FileManager.default.createDirectory(at: statedir, withIntermediateDirectories: true)
    let transcript = statedir.appendingPathComponent("session.jsonl")
    try? "{}".write(to: transcript, atomically: true, encoding: .utf8)
    var watcher = TranscriptWatcher(projectDir: statedir, file: transcript, since: t0)
    var writer = SessionStateWriter()
    let published = syncSessionState(&writer, pid: "9210",
                                     project: PickProject(name: "p", path: statedir.path),
                                     accountID: "claude:.claude", childPid: nil, model: nil,
                                     watcher: &watcher, keyboardBurstAt: nil, dir: statedir,
                                     now: Date().addingTimeInterval(sessionStateQuietSeconds + 5))
    check("the state a tick publishes is the state it hands the input gate",
          published == readSessionState(pid: "9210", dir: statedir)?.supervised)


    // MARK: - Two things no value can be asked about: the wiring, and the shape of the write

    // BOTH OF THESE SURVIVED MUTATION as ordinary assertions, which is why they are read off the
    // source. The first lives in a `while true` inside a process that spawns children, so nothing
    // links it into a harness; the second is a difference in a TRANSIENT state (measured: the shape
    // this refuses leaves the destination existing and EMPTY between two calls) that no reader can
    // observe after the fact. `tests/statusline` reads main.swift the same way and for the same
    // reason: a surface no unit can reach is still a surface that can rot.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the poll loop was really read", loop.contains("applySessionInput("))
    if let planners = loop.range(of: "applySessionDirectives("),
       let input = loop.range(of: "applySessionInput("),
       let execution = loop.range(of: "\n            if let plan {") {
        // AFTER the planners, or `plan` is read before anything has decided it; BEFORE the
        // execution, because that block is what terminates the child, and typing into a child that
        // is already gone is the other half of the same defect.
        check("the input gate is consulted after the planners decide and before the child goes",
              planners.lowerBound < input.lowerBound && input.lowerBound < execution.lowerBound)
        // READ OFF THIS CALL rather than off the whole file, which is not a detail: `selfUpdateDue`
        // takes an argument of the same name a hundred lines up, so a file-wide search for the
        // words is satisfied by somebody else's call and says nothing about this one. Caught by
        // mutation - passing a constant here survived until the search was narrowed.
        let call = String(loop[input.lowerBound ..< execution.lowerBound])
        // ONE ANSWER, TWO READERS. `plan != nil` is the wiring this had first and it is the defect:
        // it reads a stood-down tick as a relaunch. What the gate must be handed is the value the
        // execution block itself branches on, so the two can never disagree about whether this
        // child is being replaced.
        check("…and it is handed the hold-aware answer rather than the bare plan",
              call.contains("relaunchPlanned: replacingChild")
                  && !call.contains("relaunchPlanned: plan != nil"))
        // That value comes from the one ask, which is a line ABOVE the call and so outside the
        // slice: a search for it has to be made against the file.
        check("…and that answer is the tick's own forced ask",
              loop.contains("let replacingChild = relaunchIsHappening(plan: plan, "
                  + "watcher: &watcher)"))
        check("…which is the same value the relaunch itself branches on",
              loop.contains("if !replacingChild {")
                  // and the old duplicate ask is gone, or the two could drift apart again
                  && !loop.contains("if relaunchHeldByUnresolvedFork("))
    } else {
        check("the input gate is consulted after the planners decide and before the child goes",
              false)
        check("…and it is handed THIS tick's plan rather than a constant", false)
    }

    // THE COMMAND'S ORDER OF BUSINESS, read off the source for the same reason as the loop above:
    // `runSessionSend` waits up to 150 seconds on a supervisor, so nothing links it into a harness,
    // and both of these defects are matters of WHEN it asks rather than of any value it returns.
    let command = (try? String(contentsOfFile: "TallyCLI/SessionInputCommand.swift",
                               encoding: .utf8)) ?? ""
    check("the command was really read", command.contains("func runSessionSend("))
    if let start = command.range(of: "func runSessionSend("),
       let occupied = command.range(of: "sessionInputOccupant(sessionKey: sessionKey)",
                                    range: start.upperBound ..< command.endIndex),
       let cleared = command.range(of: "clearSessionInputResult(sessionKey: sessionKey)",
                                   range: start.upperBound ..< command.endIndex),
       let written = command.range(of: "try writeSessionInputRequest(",
                                   range: start.upperBound ..< command.endIndex) {
        check("the command asks whether the address is occupied before it writes to it",
              occupied.lowerBound < written.lowerBound)
        // BEFORE THE CLEAR TOO, which is not an ordering detail: that answer file may be the one
        // the other caller is polling for right now, so taking it away on the way to being refused
        // would turn its delivery into a timeout.
        check("…and before it takes away an answer that may be the other caller's",
              occupied.lowerBound < cleared.lowerBound)
    } else {
        check("the command asks whether the address is occupied before it writes to it", false)
        check("…and before it takes away an answer that may be the other caller's", false)
    }
    if let named = command.range(of: "if let named = intent.session {"),
       let end = command.range(of: "\n    } else {", range: named.upperBound ..< command.endIndex) {
        let branch = String(command[named.upperBound ..< end.lowerBound])
        // READ OFF THE BRANCH rather than the file: `supervisorAlive` is a perfectly good question
        // elsewhere in this command (the marker's own liveness), so a file-wide search would be
        // satisfied by somebody else's call and say nothing about this one.
        check("a pid named on the command line is judged by the registry, not by liveness alone",
              branch.contains("namedSession(named)") && !branch.contains("supervisorAlive("))
        // Both refusals, so a live stranger is never folded back into "nothing is running there".
        check("…and the two ways it can name nothing are answered apart",
              branch.contains("case .notRunning:") && branch.contains("case .notSupervised:"))
    } else {
        check("a pid named on the command line is judged by the registry, not by liveness alone",
              false)
        check("…and the two ways it can name nothing are answered apart", false)
    }

    // THE VERB THE NAMESPACE ANSWERS. Read off the source rather than called, because calling it
    // is the one thing this suite must never do: `runSession` resolves the session it is running
    // INSIDE, so a check that ran it on a developer's machine would write a request into their own
    // live conversation and wait two and a half minutes for it to be typed.
    check("the namespace answers `send`, and the name it shipped under is gone",
          command.contains("case \"send\":\n        return runSessionSend(")
              && !command.contains("case \"type\":"))

    let channel = (try? String(contentsOfFile: "TallyCLI/SessionInputRequest.swift",
                               encoding: .utf8)) ?? ""
    if let start = channel.range(of: "func writeSessionInputPrivately"),
       let end = channel.range(of: "\n}\n", range: start.upperBound ..< channel.endIndex) {
        let body = String(channel[start.upperBound ..< end.lowerBound])
        // The destination is only ever REACHED BY A RENAME. Creating it, truncating it or writing
        // to it in place all pass a mode check afterwards and all destroy the live request while
        // they run: a supervisor polling in that window reads an empty file, which parses as no
        // request at all.
        check("the private write reaches the destination only by renaming a finished file over it",
              body.contains("rename(temp.path, file.path)")
                  && !body.contains("createFile(atPath: file.path")
                  && !body.contains("data.write(to: file"))
        // And the mode is on the TEMPORARY, since a rename carries the mode of the inode it moves,
        // never the mode of what it replaces (measured on this machine, 2026-08-13).
        // THE MODE IS AN ARGUMENT OF THE CREATING CALL, which is what `FileManager.createFile`
        // cannot promise: it creates under the umask and applies the attributes afterwards, so a
        // file holding the whole of somebody's line exists at 0644 for a moment and every
        // measurement taken after the fact still reads 0600 (codex review of 1615990). This is a
        // shape check because the window it refuses can only be caught by watching another process
        // mid-syscall; what CAN be measured is below, and the two together are the claim.
        check("…and the temporary is born at that mode rather than chmod'd into it",
              body.contains("open(temp.path, O_WRONLY | O_CREAT | O_EXCL, "
                  + "mode_t(sessionInputFileMode))")
                  && !body.contains("createFile("))
        // The write loop advances by what the kernel took. A short write is not reachable from
        // here - the payload is bounded at a couple of hundred bytes, far under any regime that
        // produces one on a regular file - so this is pinned by shape rather than by value, and
        // said out loud rather than left looking like a covered case.
        check("…and the write loop advances by what was actually written",
              body.contains("offset += written"))
        // SAME KIND OF PIN, same honesty: a filesystem may hold a write error back until the
        // descriptor is closed, and this suite cannot make that happen - it needs a filesystem
        // that defers (a network mount), which a temp directory is not. What can be pinned is that
        // the answer is taken at all, and that the descriptor is closed exactly once whatever it
        // says, since it is deallocated even on failure.
        check("…and the close is judged rather than assumed",
              body.contains("let closeFailure = close(handle) == 0 ? nil : errno")
                  && body.contains("failure ?? closeFailure")
                  && body.components(separatedBy: "close(handle)").count == 2)
    } else {
        check("the private write reaches the destination only by renaming a finished file over it",
              false)
        check("…and the temporary is born at that mode rather than chmod'd into it", false)
    }
    // The measurable half of that claim: the two mechanisms, asked the same question under a
    // KNOWN umask rather than whatever this machine runs. That is the whole point of the second
    // check - it demonstrates that the umask leaks into a creation mode - and reading the ambient
    // one made it an assertion about the environment instead: on a contributor or a CI runner at
    // 077, `createFile` produces 0600 by itself and a perfectly correct implementation goes red
    // (codex review of 80499b3).
    // A mode passed to `open` is filtered by the umask like any other, so it is asked under two
    // that could not be more different: one that clears nothing this mode sets, and one that
    // clears everything for group and other. 0600 survives both, which is the property the
    // implementation rests on.
    for mask: mode_t in [0o022, 0o077] {
        let octal = String(mask, radix: 8)
        let birth = dir.appendingPathComponent("birth-\(octal)")
        let born = underUmask(mask) {
            open(birth.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(sessionInputFileMode))
        }
        check("a file opened with the mode is that mode from the instant it exists (umask \(octal))",
              born >= 0 && mode(birth) == sessionInputFileMode)
        if born >= 0 { close(born) }
        check("…and O_EXCL makes a name collision an error rather than an overwrite (umask \(octal))",
              open(birth.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(sessionInputFileMode)) < 0
                  && errno == EEXIST)
    }
    // And the control, under a pinned umask so the number it produces is a fact rather than a
    // reading of this machine: 0666 with 022 taken out of it is 0644, which is the window.
    let umasked = dir.appendingPathComponent("umasked")
    let made = underUmask(0o022) {
        FileManager.default.createFile(atPath: umasked.path, contents: Data("x".utf8),
                                       attributes: nil)
    }
    check("…while a file created without a mode takes the umask's, which is what the window is",
          made && mode(umasked) == 0o644 && mode(umasked) != sessionInputFileMode)

    try? FileManager.default.removeItem(at: dir)
}
