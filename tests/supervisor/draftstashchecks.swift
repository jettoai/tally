import Foundation

// THE HALF-WRITTEN PROMPT UNDER A LINE THIS SUPERVISOR TYPES (SessionInputDraft.swift): whether one
// is suspected, what the injection is therefore allowed to do about it, and the exact bytes that
// come out of both answers.
//
// A SUITE OF ITS OWN rather than more rows in sessioninputchecks, on the seam the source has: that
// file is the gate table (may this line be typed at all) and this one is what happens to somebody
// else's text at the moment it is. It also keeps that file's "every served request left a line"
// count honest, which is a real check and not an accounting detail - it is what says no branch here
// writes a log line nobody accounted for.
//
// THE MATRIX IS ENUMERATED, NOT SAMPLED. The母體 is the Phase A measurement matrix
// (docs/plans/reports-20260819/draft-stash-report.md): four session states x suspected or not for
// the guard, and every cause of a keyboard burst that is not a draft for the evidence. A sampled
// version of this table would pass with a rule that only happened to be right about the rows
// somebody thought of, and the row nobody thinks of is A4 - the one where a restore that should not
// have happened pastes a stale kill buffer into a composer somebody left empty on purpose.

func runDraftStashChecks() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-draftstash-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("input.log")
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)
    func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }
    func epoch(_ offset: TimeInterval) -> Int { Int(at(offset).timeIntervalSince1970 * 1000) }

    // MARK: - The keys, and the constants around them

    // NAMED RATHER THAN WRITTEN BARE AT THE CALL SITE, and asserted against the control characters
    // they are: Ctrl-K is 0x0B, Ctrl-U is 0x15 and Ctrl-Y is 0x19, and a transposition of any two of
    // them would stash nothing and paste something on every single line this supervisor types.
    check("the stash keys are Ctrl-K and Ctrl-U, and the restore key is Ctrl-Y",
          sessionInputStashKillByte == 0x0B && sessionInputStashByte == 0x15
              && sessionInputRestoreByte == 0x19)
    // A NUMBER RATHER THAN A LOOP UNTIL EMPTY, because nothing here can see the composer. The kills
    // are per LINE (measured, case A5), so an N-line draft needs 2N-1 rounds and one round is the
    // bug this whole file exists about.
    check("the stash rounds cover a multi-line draft rather than one line",
          sessionInputStashRounds == 12 && sessionInputStashRounds >= 2 * 6 - 1)
    // The restore rides the tail of the same injection, so its pause is charged to the same poll
    // tick: generous against the 30ms and 400ms that were measured green, and small against the
    // stall the byte limit already allows.
    check("the restore waits well past what was measured, and still costs less than the payload",
          sessionInputRestorePause == 0.8
              && sessionInputRestorePause < TimeInterval(sessionInputMaxBytes) * sessionInputByteGap)
    // And the margin that separates "somebody is typing" from the two things that look like it.
    check("the draft grace is well under the quiet bar the keyboard gate already asks for",
          sessionInputDraftGrace == 2 && sessionInputDraftGrace < sessionInputKeyboardQuietSeconds)

    // MARK: - The evidence: is there a draft in there at all

    /// The question, with each fact absent unless the row is about it.
    func suspected(burst: TimeInterval? = nil, turn: TimeInterval? = nil,
                   injected: TimeInterval? = nil) -> Bool {
        sessionInputDraftSuspected(burstAt: burst.map(at), userTurnAt: turn.map(at),
                                   injectedAt: injected.map(at))
    }
    // NOTHING TYPED IS NOT A DRAFT, and it is the commonest row by far: a session nobody has touched
    // since it was launched, and one whose only keyboard stamps were lone ones (terminal chatter
    // arrives alone, `KeyboardActivity` counts only runs).
    check("a terminal with no burst on it holds no suspected draft", !suspected())
    // SOMEBODY TYPED AND NOTHING WAS SENT, which is the case Albert lost a draft to on 2026-08-19.
    check("a burst with no prompt sent since it is a draft", suspected(burst: 100))
    check("…and so is one in a conversation that has not had a prompt yet at all",
          suspected(burst: 100, turn: nil))
    // THEY SENT IT: the burst ENDS in the Return that produced the prompt, so a burst older than the
    // last user turn is the prompt that turn is made of.
    check("a burst the person sent as a prompt is not still sitting in the composer",
          !suspected(burst: 100, turn: 140))
    // THE TWO CLOCKS THAT RECORD THAT ONE MOMENT, which is what the grace is for: the Return is
    // itself a keystroke, so the burst and the transcript event are the same instant read twice and
    // either may land a moment later than the other.
    check("a burst inside the grace after a prompt is that prompt's own Return, not a new draft",
          !suspected(burst: 100.5, turn: 100) && !suspected(burst: 102, turn: 100))
    check("…and the boundary belongs to the draft: past the grace it is somebody typing again",
          suspected(burst: 102.001, turn: 100))
    // THIS SUPERVISOR'S OWN FOOTPRINTS. Injected bytes are read by the child off the same terminal
    // and stamp it exactly as fingers do, so without this the second `/clear` into a session that
    // has produced no user turn since the first would read its own last line as a draft and yank
    // whatever the kill buffer held - which is case A4 arriving through the front door.
    check("a burst this supervisor's own injection left is not a draft",
          !suspected(burst: 100, injected: 100) && !suspected(burst: 101, injected: 100)
              && !suspected(burst: 99, injected: 100))
    check("…while somebody typing after it is one again",
          suspected(burst: 102.001, injected: 100))
    // BOTH CAUSES AT ONCE, in all four combinations: the burst has to be clear of EVERY one of them,
    // so an implementation that checked the newer cause only would pass three of these rows.
    check("a burst has to be clear of every cause, not of the most recent one",
          suspected(burst: 200, turn: 100, injected: 150)
              && !suspected(burst: 120, turn: 100, injected: 150)
              && !suspected(burst: 120, turn: 150, injected: 100)
              && !suspected(burst: 120, turn: 150, injected: 160))

    // MARK: - The guard: what the injection may do about it

    /// Every state the board can publish, so the table below is a table rather than three examples.
    let states: [SupervisedState] = [.idle, .working, .blocked, .unknown]
    for state in states {
        for evidence in [false, true] {
            let guarded = sessionInputDraftGuard(state: state, suspected: evidence)
            // BLOCKED TOUCHES NOTHING: the composer is behind a permission dialog, both keys were
            // measured inert there (case A7), and the draft is already safe - answering the dialog
            // gives the composer back untouched (case A7e).
            let touching = state != .blocked
            check("\(state) with suspected=\(evidence) stashes only where the composer is reachable",
                  guarded.stash == touching)
            // AND THE RESTORE IS THE HALF THAT HAS TO BE EARNED, in every state.
            check("…and restores only where it is reachable AND something says there is a draft",
                  guarded.restore == (touching && evidence))
            check("…and carries the evidence for the account question next door",
                  guarded.suspected == evidence)
        }
    }
    // The value a caller with no reading to offer passes, spelled once and asserted to be inert.
    check("the guard that means `no reading` does nothing at all",
          !SessionInputDraftGuard.none.stash && !SessionInputDraftGuard.none.restore
              && !SessionInputDraftGuard.none.suspected)

    // MARK: - The bytes, in order

    /// The plan, with the intervals at values a check can name.
    func plan(_ text: String, _ guarded: SessionInputDraftGuard) -> [SessionInputStep] {
        sessionInputInjectionPlan(text: text, draft: guarded, gap: 0.03, pause: 0.4,
                                  restorePause: 0.8)
    }
    let pressed = { (steps: [SessionInputStep]) -> [UInt8] in
        steps.compactMap { if case .press(let byte) = $0 { return byte } else { return nil } }
    }
    /// The keys a full stash presses, in order: the one sequence three checks below compare against.
    let stashKeys = Array(repeating: [sessionInputStashKillByte, sessionInputStashByte],
                          count: sessionInputStashRounds).flatMap { $0 }
    // WHAT EVERY INJECTION DID BEFORE THIS EXISTED, asserted whole rather than by its length: this is
    // the shape a session that is not being protected still gets, and the one a blocked session gets.
    check("a landing with no guard types exactly the payload and a Return, as it always did",
          plan("hi", .none) == [.press(0x68), .wait(0.03), .press(0x69), .wait(0.03),
                                .wait(0.4), .press(13)])
    check("…and a blocked session's landing is byte for byte that same line",
          plan("hi", sessionInputDraftGuard(state: .blocked, suspected: true))
              == plan("hi", .none))
    // THE STASH GOES FIRST AND ALL OF IT GOES FIRST: a press that landed after the payload had
    // started would kill the payload itself.
    let stashing = plan("hi", sessionInputDraftGuard(state: .idle, suspected: false))
    check("a stash is the whole of the prefix, one round per line it may have to kill",
          pressed(stashing) == stashKeys + [0x68, 0x69, 13])
    // FORWARD THEN BACKWARD WITHIN EACH ROUND, which is the order the measurement settled: the kill
    // to the end of the line is what takes the part of a draft that a cursor left mid-edit shelters
    // from Ctrl-U, and a payload typed in front of that remnant is the original defect in miniature
    // (measured 2026-08-19: `PAYLOAD three`).
    check("…each round killing forward before it kills back, at the payload's own interval",
          Array(stashing.prefix(4 * sessionInputStashRounds))
              == Array(repeating: [SessionInputStep.press(sessionInputStashKillByte),
                                   SessionInputStep.wait(0.03),
                                   SessionInputStep.press(sessionInputStashByte),
                                   SessionInputStep.wait(0.03)],
                       count: sessionInputStashRounds).flatMap { $0 })
    // THE RESTORE GOES LAST, AFTER THE RETURN, and that order is the whole of why it is safe: the
    // draft comes back into a composer the send has already emptied, so nothing this supervisor
    // typed and nothing the person typed can be joined into one prompt.
    let restoring = plan("hi", sessionInputDraftGuard(state: .idle, suspected: true))
    check("a restore is one press behind the Return, after the pause the redraw needs",
          Array(restoring.suffix(3)) == [.press(13), .wait(0.8),
                                         .press(sessionInputRestoreByte)])
    check("…and it is the only thing that differs from the same line without a draft under it",
          Array(restoring.dropLast(2)) == stashing)
    check("…so nothing pastes anything before the line has been sent",
          pressed(restoring).firstIndex(of: 13)!
              < pressed(restoring).lastIndex(of: sessionInputRestoreByte)!)
    // AN EMPTY SEND IS A REAL REQUEST (pressing Return on a prompt that sits on its default), and it
    // is the row where an off-by-one in the prefix would be invisible: there is no payload to
    // separate the stash from the Return.
    check("an empty send still stashes, still presses Return, and still puts the draft back",
          pressed(plan("", sessionInputDraftGuard(state: .idle, suspected: true)))
              == stashKeys + [13, sessionInputRestoreByte])
    // THE CONTROL BYTES ARE NOT THE CALLER'S BYTES. `sessionInputMaxBytes` bounds what somebody may
    // type into a conversation; these are the supervisor getting its own way in, and counting them
    // against that limit would shorten every line by twelve characters for a reason no caller could
    // see.
    let full = String(repeating: "a", count: sessionInputMaxBytes)
    check("a payload at the byte limit is planned whole, with the stash on top of it",
          pressed(plan(full, sessionInputDraftGuard(state: .idle, suspected: true))).count
              == stashKeys.count + sessionInputMaxBytes + 2)
    // MULTIBYTE TEXT GOES THROUGH AS BYTES, which is what the injection writes: a CJK line is three
    // bytes per character and the plan must carry each of them, in order.
    check("a multibyte payload is planned byte by byte, in order",
          pressed(plan("字", .none)) == Array("字".utf8) + [13])

    // MARK: - What the log says about it afterwards

    /// One tick, with the injection recorded rather than performed. Answers what the writer was
    /// handed, which is the only way to see the guard from outside.
    func tick(_ key: String, text: String = "/clear", state: SupervisedState = .idle,
              suspected: Bool, injection: SessionInputInjection = .done,
              offset: TimeInterval = 1) -> SessionInputDraftGuard? {
        var input = SessionInputState(sessionKey: key, servedEpoch: 0, dir: dir)
        try? writeSessionInputRequest(SessionInputRequest(epoch: epoch(0), text: text),
                                      sessionKey: key, dir: dir)
        var handed: SessionInputDraftGuard?
        applySessionInput(&input, session: state, quiet: .quiet, turnEnded: { false },
                          keyboardIdle: true, relaunchPlanned: false, draftSuspected: suspected,
                          dir: dir, log: log, now: at(offset), agents: { _ in nil },
                          inject: { _, guarded in
                              handed = guarded
                              return injection
                          })
        return handed
    }
    /// Everything written to the log so far, since every check below is about a line appearing in it.
    func written() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    check("the tick hands the writer a guard built from this session's state and its draft reading",
          tick("9501", suspected: true) == sessionInputDraftGuard(state: .idle, suspected: true))
    check("…and the log says the composer was stashed, in presses rather than in anything it read",
          written().contains("pid=9501 input=draft-stashed rounds=\(sessionInputStashRounds)"))
    check("…and that it was put back",
          written().contains("pid=9501 input=draft-restored"))
    // THE ORDINARY LINE, and the one whose log line somebody actually comes looking for: their
    // composer is empty and they want to know where it went. The answer is the kill buffer, and the
    // reason says which road got there.
    _ = tick("9502", suspected: false, offset: 2)
    check("a line with no draft under it still stashes, and says why it put nothing back",
          written().contains("pid=9502 input=draft-stashed")
              && written().contains("pid=9502 input=draft-restore-dropped "
                  + "reason=no-typing-evidence")
              && !written().contains("pid=9502 input=draft-restored"))
    // A BLOCKED SESSION TOUCHED NOTHING, so it says nothing: a stash that never ran is not a draft
    // anybody has to be told about, and a line about it would be the log claiming to have moved text
    // it never went near.
    _ = tick("9503", text: "1", state: .blocked, suspected: true, offset: 3)
    check("a blocked session's line leaves no draft trail, because it touched no composer",
          !written().contains("pid=9503 input=draft-"))
    // AND THE ONE THAT MEANS SOMETHING IS WRONG: the terminal refused a write part-way through, so
    // the stash may have got out and the restore certainly did not.
    _ = tick("9504", suspected: true, injection: .failed(ENXIO), offset: 4)
    check("a refused write leaves the draft stashed and says the write is why it stayed there",
          written().contains("pid=9504 input=draft-stashed")
              && written().contains("pid=9504 input=draft-restore-dropped reason=write-failed")
              && !written().contains("pid=9504 input=draft-restored"))
    // ORDER, because these lines are read as a story: what was typed, and then what became of what
    // was already there.
    check("the draft lines come after the line saying what was typed",
          written().range(of: "pid=9501 input=submitted").map { served in
              written().range(of: "pid=9501 input=draft-stashed")
                  .map { served.upperBound < $0.lowerBound } ?? false
          } ?? false)
    // THE REASONS ARE A CLOSED SET, named once so the line builder and anything grepping for them
    // cannot drift apart.
    check("the two reasons a restore is dropped are the two this build can produce",
          sessionInputDraftDropReasonNoTyping == "no-typing-evidence"
              && sessionInputDraftDropReasonWriteFailed == "write-failed")
    // A move types nothing, so there is nothing to say about a composer it never reached. Asserted
    // through the tick that moves rather than in the abstract, since the branch that could get this
    // wrong is the one that logs before checking what happened.
    var moving = SessionInputState(sessionKey: "9505", servedEpoch: 0, dir: dir)
    try? writeSessionInputRequest(SessionInputRequest(epoch: epoch(0), text: windowClearCommand,
                                                      waitSeconds: 6, intent: sessionClearIntent),
                                  sessionKey: "9505", dir: dir)
    let target = Snapshot.Account(id: "B", provider: "claude", label: "Claude 2",
                                  launchHome: "/tmp/B", sessionRemaining: 80, weeklyRemaining: 80,
                                  modelRemaining: 80, sessionResetsAt: nil, weeklyResetsAt: nil,
                                  modelResetsAt: nil, modelWindowName: nil,
                                  resetCreditsAvailable: nil, isStale: false, error: nil)
    let move = applySessionInput(&moving, session: .idle, quiet: .quiet, turnEnded: { false },
                                 keyboardIdle: true, relaunchPlanned: false, draftSuspected: false,
                                 dir: dir, log: log, now: at(5), agents: { _ in nil },
                                 clearBoundary: { target }) { _, _ in .done }
    check("a clear answered by moving the session says nothing about drafts, having typed nothing",
          move.moveTo == target && !written().contains("pid=9505 input=draft-"))

    // MARK: - The wiring no value can be asked about

    // READ OFF THE SOURCE, the technique every station in this suite family uses for a `while true`
    // inside a process that spawns children. It is here because everything above would stay green
    // against a poll loop that passed `false`: the reading is taken in the loop, from facts only the
    // loop holds, and nothing it returns says which value went in.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the draft checks", !loop.isEmpty)
    check("the reading is taken from the keyboard, the transcript and this supervisor's own line",
          loop.contains("sessionInputDraftSuspected(burstAt: keyboard.lastBurstAt,")
              && loop.contains("userTurnAt: watcher.lastUserTurnAt,")
              && loop.contains("injectedAt: lastComposerWrite)"))
    // BOTH WRITERS INTO THAT COMPOSER GET IT, which is the half that is easy to leave half done: the
    // requested line and the advisory knock type through the same door, and a draft is destroyed by
    // whichever of them was not told (QuotaKnock.swift).
    if let request = loop.range(of: "let action = applySessionInput("),
       let arm = loop.range(of: "windowRepick.arm(typed: action.typed,",
                            range: request.upperBound ..< loop.endIndex),
       let knock = loop.range(of: "applyQuotaKnock(", range: arm.upperBound ..< loop.endIndex),
       let afterKnock = loop.range(of: "quarantine: quarantine)",
                                   range: knock.upperBound ..< loop.endIndex) {
        check("the requested line is typed under this tick's own draft reading",
              loop[request.upperBound ..< arm.lowerBound].contains("draftSuspected: draftSuspected"))
        check("…and so is the one nobody asked for",
              loop[knock.upperBound ..< afterKnock.upperBound]
                  .contains("draftSuspected: draftSuspected"))
    } else {
        check("both writers into the composer are handed this tick's draft reading", false)
    }
    // AND EACH OF THEM WRITES DOWN THAT IT TYPED, or the next tick reads its own footprints on that
    // terminal as somebody's draft and yanks a stale kill buffer into their composer.
    check("both writers record when they typed, which is what the next reading discounts",
          loop.contains("if action.typed != nil { lastComposerWrite = Date() }")
              && loop.contains("if knocked != nil { lastComposerWrite = Date() }"))

    // MARK: - The writer, as far as one can be driven without a terminal

    // The failure arm, which is all this process can reach (sessioninputchecks states why). What it
    // proves here is that the guard reaches the ioctl at all: a stash press is attempted first, so
    // the write fails on the STASH rather than on the payload - and both are the same errno, so what
    // separates them is that this call returns before any payload byte could have been written.
    check("a guarded write on a target that is not a terminal fails rather than pretending",
          injectSessionInput("hi", draft: sessionInputDraftGuard(state: .idle, suspected: true),
                             tty: "/dev/null", gap: 0, pause: 0, restorePause: 0) != .done)
}
