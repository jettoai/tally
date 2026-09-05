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
// THE MATRIX IS ENUMERATED, NOT SAMPLED. The population is the Phase A measurement matrix
// (docs/plans/reports-20260819/draft-stash-report.md): four session states x suspected or not for
// the guard, and every cause of a keyboard burst that is not a draft for the evidence. A sampled
// version of this table would pass with a rule that only happened to be right about the rows
// somebody thought of.
//
// AND THE CONTRACT THIS FILE HOLDS SINCE 2026-08-20: no plan this supervisor builds ever presses
// Ctrl-Y. The automatic restore was removed after it fired twice in one day on composers nobody had
// typed into (SessionInputDraft.swift carries the incident and the reason the evidence channel
// cannot carry that decision). The rows below assert the absence rather than the old behaviour,
// because the defect it protects against is a byte appearing in a sequence rather than a value
// coming out wrong: the payload and the log lines look identical either way.

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
    // they are: Ctrl-K is 0x0B and Ctrl-U is 0x15, and a transposition of the two would stash a
    // one-line draft and leave every multi-line one where it was.
    check("the stash keys are Ctrl-K and Ctrl-U",
          sessionInputStashKillByte == 0x0B && sessionInputStashByte == 0x15)
    // A NUMBER RATHER THAN A LOOP UNTIL EMPTY, because nothing here can see the composer. The kills
    // are per LINE (measured, case A5), so an N-line draft needs 2N-1 rounds and one round is the
    // bug this whole file exists about.
    check("the stash rounds cover a multi-line draft rather than one line",
          sessionInputStashRounds == 12 && sessionInputStashRounds >= 2 * 6 - 1)
    // And the margin that separates "somebody is typing" from the two things that look like it.
    check("the draft grace is well under the quiet bar the keyboard gate already asks for",
          sessionInputDraftGrace == 2 && sessionInputDraftGrace < sessionInputKeyboardQuietSeconds)
    // AND THE LIFE, WHICH IS THE OTHER END OF THE SAME EVIDENCE (2026-09-02). It has to be LONGER
    // than the bar the preventive movers judge a terminal quiet by, and the reason is NOT that the
    // two answers contradict one another: a composer holds text long after the fingers stop, which
    // is the whole of why this reading exists beside the keyboard gate. It is that a life shorter
    // than that bar would make this answer dead code - every burst young enough to count as a draft
    // would also be young enough to fail `keyboard.idle(followIdleSeconds)` one gate earlier, and
    // nothing would ever be decided here.
    check("the draft evidence has a life, and one longer than the movers' own quiet bar",
          sessionInputDraftLife == 900 && sessionInputDraftLife > followIdleSeconds)

    // MARK: - The evidence: is there a draft in there at all

    /// The question, with each fact absent unless the row is about it.
    ///
    /// `now` IS A ROW OF THE TABLE rather than a default, since 2026-09-02: this answer is about how
    /// old the burst is, so a row that let the clock default would assert something about the moment
    /// the suite happened to run.
    func suspected(burst: TimeInterval? = nil, turn: TimeInterval? = nil,
                   injected: TimeInterval? = nil, now: TimeInterval = 300) -> Bool {
        sessionInputDraftSuspected(burstAt: burst.map(at), userTurnAt: turn.map(at),
                                   injectedAt: injected.map(at), now: at(now))
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
    // and stamp it exactly as fingers do, so without this every line this supervisor types would
    // leave the session looking drafty to the next tick, and the preventive account move would be
    // declined for the rest of that session's life.
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

    // MARK: - …and whether that burst is still about the present

    // THE LATCH THIS BOUND ENDED (2026-09-02; SessionInputDraft.swift carries the log lines). Every
    // input above only moves forward, so a `true` here could be taken back by a newer prompt or a
    // newer injection and by nothing else - and in a session nobody is in, neither of those ever
    // arrives, because a prompt needs the person this answer claims is there and an injection needs
    // a station that is standing down on this very answer. Two sessions on this machine sat on
    // accounts reading 0% for 59 and 37 minutes with `movers-blocked=draft-suspected` as the only
    // name in the line.
    check("a burst one second inside its life is still a draft",
          suspected(burst: 100, now: 100 + sessionInputDraftLife - 1))
    check("…and the boundary belongs to the expiry: at its life it is evidence about the past",
          !suspected(burst: 100, now: 100 + sessionInputDraftLife))
    check("…however clear of every other cause that burst was",
          !suspected(burst: 100, turn: 10, injected: 20,
                     now: 100 + sessionInputDraftLife + 3600))
    // THE WHOLE RANGE RATHER THAN ITS TWO ENDS, because what this file could not say before is that
    // the answer is bounded AT ALL, and two boundary rows are also what an implementation with the
    // comparison inverted somewhere in the middle would pass. Every five seconds from the burst
    // itself to a minute past its life, the answer has to be exactly "is this burst younger than
    // its life".
    var ages = 0
    var wrongAges: [TimeInterval] = []
    for step in 0 ... Int((sessionInputDraftLife + 60) / 5) {
        let age = Double(step) * 5
        ages += 1
        if suspected(burst: 1000, now: 1000 + age) != (age < sessionInputDraftLife) {
            wrongAges.append(age)
        }
    }
    // THE COUNT IS PART OF THE ASSERTION rather than bookkeeping: a loop that ran no rows leaves
    // `wrongAges` empty too, and would report this whole property as proved.
    check("every burst age answers exactly `younger than its life`, with no row exempt",
          wrongAges.isEmpty && ages == Int((sessionInputDraftLife + 60) / 5) + 1)
    // WHAT THE MOVERS ARE HANDED AN HOUR LATER, stated at the seam they read it through: the three
    // preventive movers and the automatic resume after a wall all take this Bool, and until the
    // bound existed an hour changed nothing about it.
    check("an hour after that burst, the reading every mover is handed is false",
          !suspected(burst: 100, now: 100 + 3600))

    // THE SAME EVIDENCE A SECOND TIME, WITH A DIFFERENT CAUSE BEHIND IT, across the boundary where
    // the two lifetimes meet: `KeyboardActivity` is rebuilt with the child (Supervisor.swift), so a
    // burst that expired, released a preventive move and got the session restarted is followed by a
    // NEW burst as the new child reads its terminal. Same shape, different cause (a TUI handing
    // over rather than fingers), and both halves of the obvious wrong answer are asserted against:
    // the new burst inheriting the old one's expiry, and the old one's release carrying over so
    // that the new child's composer is never protected at all.
    let personTyped: TimeInterval = 1000
    check("the burst that expired stopped protecting anything",
          !suspected(burst: personTyped, now: personTyped + sessionInputDraftLife))
    var afterRelaunch = KeyboardActivity()
    check("a relaunched child starts with no burst at all, so nothing is inherited",
          afterRelaunch.lastBurstAt == nil)
    let handover = personTyped + sessionInputDraftLife + 3
    afterRelaunch.observe(stamp: at(handover - 0.2))
    afterRelaunch.observe(stamp: at(handover))
    check("…and the burst its handover writes is protected on its own life rather than the old one",
          afterRelaunch.lastBurstAt == at(handover)
              && suspected(burst: handover, now: handover + 5)
              && !suspected(burst: handover, now: handover + sessionInputDraftLife))

    // MARK: - The guard: what the injection may do about it

    // BOTH ANSWERS THE QUESTION HAS, which is the whole of the table since 2026-09-05: the guard
    // no longer reads a board state at all, because the board's `blocked` covers a soft wait too
    // (the rows through the writer, further down, are where that distinction is asserted).
    for onDialog in [false, true] {
        for evidence in [false, true] {
            let guarded = sessionInputDraftGuard(dialog: onDialog, suspected: evidence)
            // A DIALOG TOUCHES NOTHING: the composer is behind a permission request or a plan
            // approval, both keys were measured inert there (case A7), and the draft is already
            // safe - answering the dialog gives the composer back untouched (case A7e).
            check("dialog=\(onDialog) with suspected=\(evidence) stashes only where the composer "
                      + "is reachable", guarded.stash == !onDialog)
            // AND THE EVIDENCE CHANGES NOTHING ABOUT WHAT IS TYPED, on either row: it is read by
            // the account question alone since 2026-08-20, and the row that used to differ here is
            // the restore this build no longer performs.
            check("…and what it types does not depend on whether a draft is suspected",
                  sessionInputInjectionPlan(text: "hi", draft: guarded)
                      == sessionInputInjectionPlan(
                          text: "hi", draft: sessionInputDraftGuard(dialog: onDialog,
                                                                   suspected: !evidence)))
            check("…and carries the evidence for the account question next door",
                  guarded.suspected == evidence)
        }
    }
    // The value a caller with no reading to offer passes, spelled once and asserted to be inert.
    check("the guard that means `no reading` does nothing at all",
          !SessionInputDraftGuard.none.stash && !SessionInputDraftGuard.none.suspected)

    // MARK: - The bytes, in order

    /// The plan, with the intervals at values a check can name.
    func plan(_ text: String, _ guarded: SessionInputDraftGuard) -> [SessionInputStep] {
        sessionInputInjectionPlan(text: text, draft: guarded, gap: 0.03, pause: 0.4)
    }
    let pressed = { (steps: [SessionInputStep]) -> [UInt8] in
        steps.compactMap { if case .press(let byte) = $0 { return byte } else { return nil } }
    }
    let waits = { (steps: [SessionInputStep]) -> [TimeInterval] in
        steps.compactMap { if case .wait(let seconds) = $0 { return seconds } else { return nil } }
    }
    /// The keys a full stash presses, in order: the one sequence three checks below compare against.
    let stashKeys = Array(repeating: [sessionInputStashKillByte, sessionInputStashByte],
                          count: sessionInputStashRounds).flatMap { $0 }
    /// The payload as it goes on the wire when the composer is what the line reaches: wrapped in the
    /// markers a terminal puts around a paste.
    func pasted(_ bytes: [UInt8]) -> [UInt8] {
        sessionInputPasteStart + bytes + sessionInputPasteEnd
    }
    /// …and as it goes when it is not: one key at a time, at the interval a composer redraws at.
    func typedOut(_ bytes: [UInt8]) -> [SessionInputStep] {
        bytes.flatMap { [SessionInputStep.press($0), .wait(0.03)] }
    }
    /// The guard a session waiting on a person gets: a permission request, a plan approval, an
    /// open question, with the composer behind it.
    let dialog = sessionInputDraftGuard(dialog: true, suspected: true)
    // WHAT A LINE THAT IS NOT REACHING A COMPOSER DOES, asserted whole rather than by its length:
    // this is the shape a dialog answer takes, and the one a caller with no reading to offer gets.
    check("a landing with no guard types the payload one key at a time, which is where an answer "
              + "nobody vouched for belongs",
          plan("hi", .none) == typedOut([0x68, 0x69]) + [.wait(0.4), .press(13)])
    check("…and a dialog answer's landing is byte for byte that same line",
          plan("hi", dialog) == plan("hi", .none))
    // A DIALOG IS NEVER HANDED A PASTE, and this is the authorisation boundary of 2026-09-05 stated
    // as bytes. A chooser reads KEYS: an answer delivered as one paste event is dropped by the
    // dialog layer, and the Return behind it then activates whatever was highlighted, which is the
    // FIRST option. Measured twice on a real Bash permission dialog: a pasted `4` (No) ran the
    // command, the same `4` typed refused it. So the rows below are about the one shape of request
    // that can say no, and they are asserted by the escape byte rather than by the marker sequence,
    // so half a marker creeping in is caught too.
    check("no answer to a dialog carries a paste marker, whatever the evidence says",
          !pressed(plan("4", dialog)).contains(0x1B)
              && !pressed(plan("4", .none)).contains(0x1B)
              && !pressed(plan("no", sessionInputDraftGuard(dialog: true, suspected: false)))
                  .contains(0x1B))
    // AND IT IS TYPED AT THE INTERVAL A CHOOSER REDRAWS AT, which is the other half of the same
    // rule: markers absent is not enough if the bytes arrive with nothing between them, since what
    // a menu has to keep up with is exactly what the interval was measured for.
    check("…and its bytes are spaced by the composer's own interval, one wait per key",
          waits(plan("4", dialog)) == [0.03, 0.4]
              && waits(plan("no", dialog)) == [0.03, 0.03, 0.4])
    // AND A COMPOSER STILL GETS THE PASTE, which is the row that says this fix did not undo the
    // change it is a correction to.
    check("…while a session whose composer is the target still gets one paste",
          pressed(plan("hi", sessionInputDraftGuard(dialog: false, suspected: false)))
              .contains(sessionInputPasteStart[0]))
    // THE STASH GOES FIRST AND ALL OF IT GOES FIRST: a press that landed after the payload had
    // started would kill the payload itself.
    let stashing = plan("hi", sessionInputDraftGuard(dialog: false, suspected: false))
    check("a stash is the whole of the prefix, one round per line it may have to kill",
          pressed(stashing) == stashKeys + pasted([0x68, 0x69]) + [13])
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
    // THE RETURN IS THE LAST THING IN EVERY PLAN, which is the 2026-08-20 contract stated as bytes.
    // A tail that put the draft back used to hang off `suspected`, and this is the row that would
    // catch it coming back: the sequence for a session that may hold a draft is the sequence for one
    // that certainly does not, byte for byte and pause for pause.
    let drafting = plan("hi", sessionInputDraftGuard(dialog: false, suspected: true))
    check("a line typed over a suspected draft is byte for byte the line typed over nothing",
          drafting == stashing)
    check("…and every plan ends at the Return, with nothing pressed behind it",
          drafting.last == .press(sessionInputReturnByte)
              && plan("hi", .none).last == .press(sessionInputReturnByte)
              && plan("a\rb", .none).last == .press(sessionInputReturnByte))
    // THE BYTE THE REMOVED RESTORE WAS, asserted absent by its value rather than by its name: the
    // constant is gone, so a build that brought the paste back would have to write 0x19 somewhere,
    // and this is where that would be caught. Ctrl-Y in a payload the caller chose is still the
    // caller's business, so what is asserted is the plans this supervisor builds for itself.
    check("no plan presses Ctrl-Y, whatever the evidence says",
          !pressed(drafting).contains(0x19) && !pressed(stashing).contains(0x19)
              && !pressed(plan("", sessionInputDraftGuard(dialog: false, suspected: true)))
                  .contains(0x19))
    // AN EMPTY SEND IS A REAL REQUEST (pressing Return on a prompt that sits on its default), and it
    // is the row where an off-by-one in the prefix would be invisible: there is no payload to
    // separate the stash from the Return.
    check("an empty send still stashes and still presses Return",
          pressed(plan("", sessionInputDraftGuard(dialog: false, suspected: true)))
              == stashKeys + [13])
    // AND IT IS NOT WRAPPED, which is the row the marker pair has to be asked about separately: an
    // empty paste is two escape sequences asking a composer to do nothing, and a composer that
    // answered them with anything at all would answer a request whose whole content is the Return.
    // Asserted by the escape byte rather than by the sequence, so a half-written pair is caught too.
    check("…and nothing is pasted around a payload that is not there",
          !pressed(plan("", sessionInputDraftGuard(dialog: false, suspected: true))).contains(0x1B)
              && !pressed(plan("", .none)).contains(0x1B))
    // THE MARKERS ARE THE PAYLOAD'S OWN BRACKET, asserted as a position rather than as membership:
    // a plan that opened the paste before the stash, or closed it after the Return, would still
    // contain both sequences.
    check("the paste opens immediately before the payload and closes immediately after it",
          Array(pressed(stashing).dropFirst(stashKeys.count))
              == pasted([0x68, 0x69]) + [sessionInputReturnByte])
    /// A payload at the channel's own limit, which two rows below ask different questions of.
    let full = String(repeating: "a", count: sessionInputMaxBytes)
    // NO WAIT INSIDE THE PAYLOAD, which is the whole of this change stated as a count: the waits a
    // plan carries are the stash's own intervals and the submit pause, and nothing else. A payload
    // of any length adds none of them, which is what makes the poll loop's stall independent of how
    // long a caller's line is (SessionInput.swift's header carries that trade).
    let stashWaits = Array(repeating: 0.03, count: 2 * sessionInputStashRounds)
    check("a payload of any length adds no waits, so only the stash and the submit pause remain",
          waits(plan("hi", sessionInputDraftGuard(dialog: false, suspected: false)))
              == stashWaits + [0.4]
              && waits(plan(full, sessionInputDraftGuard(dialog: false, suspected: true)))
                  == stashWaits + [0.4])
    // THE CONTROL BYTES ARE NOT THE CALLER'S BYTES. `sessionInputMaxBytes` bounds what somebody may
    // type into a conversation; these are the supervisor getting its own way in, and counting them
    // against that limit would shorten every line by twelve characters for a reason no caller could
    // see.
    check("a payload at the byte limit is planned whole, with the stash on top of it",
          pressed(plan(full, sessionInputDraftGuard(dialog: false, suspected: true))).count
              == stashKeys.count + sessionInputPasteStart.count + sessionInputMaxBytes
                  + sessionInputPasteEnd.count + 1)
    // MULTIBYTE TEXT GOES THROUGH AS BYTES, which is what the injection writes: a CJK line is three
    // bytes per character and the plan must carry each of them, in order.
    check("a multibyte payload is planned byte by byte, in order",
          pressed(plan("字", sessionInputDraftGuard(dialog: false, suspected: false)))
              == stashKeys + pasted(Array("字".utf8)) + [13]
              && pressed(plan("字", .none)) == Array("字".utf8) + [13])

    // MARK: - What the log says about it afterwards

    /// One tick, with the injection recorded rather than performed. Answers what the writer was
    /// handed, which is the only way to see the guard from outside.
    func serve(_ key: String, text: String = "/clear", state: SupervisedState = .idle,
               waitingOnPerson: Bool = false,
               suspected: Bool, injection: SessionInputInjection = .done,
               agents: Int? = nil,
               offset: TimeInterval = 1) -> (guarded: SessionInputDraftGuard?,
                                             action: SessionInputAction) {
        var input = SessionInputState(sessionKey: key, servedEpoch: 0, dir: dir)
        try? writeSessionInputRequest(SessionInputRequest(epoch: epoch(0), text: text),
                                      sessionKey: key, dir: dir)
        var handed: SessionInputDraftGuard?
        let action = applySessionInput(
            &input, session: state, quiet: .quiet, turnEnded: { false },
            keyboardIdle: true, relaunchPlanned: false, draftSuspected: suspected,
            waitingOnPerson: waitingOnPerson,
            dir: dir, log: log, now: at(offset), agents: { _ in agents },
            inject: { _, guarded in
                handed = guarded
                return injection
            })
        return (handed, action)
    }
    /// The guard alone, for the checks that are only about what the writer was handed.
    func tick(_ key: String, text: String = "/clear", state: SupervisedState = .idle,
              waitingOnPerson: Bool = false,
              suspected: Bool, injection: SessionInputInjection = .done,
              offset: TimeInterval = 1) -> SessionInputDraftGuard? {
        serve(key, text: text, state: state, waitingOnPerson: waitingOnPerson,
              suspected: suspected, injection: injection, offset: offset).guarded
    }
    /// Everything written to the log so far, since every check below is about a line appearing in it.
    func written() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    check("the tick hands the writer a guard built from its hard-wait and draft readings",
          tick("9501", suspected: true) == sessionInputDraftGuard(dialog: false, suspected: true))
    check("…and the log says the composer was stashed, in presses rather than in anything it read",
          written().contains("pid=9501 input=draft-stashed rounds=\(sessionInputStashRounds)"))
    // AND IT SAYS NOTHING ABOUT PUTTING IT BACK, because nothing does. Both of the lines that used
    // to follow the stash are asserted absent here rather than merely dropped from the suite: a
    // build that restored a draft again would write `draft-restored`, and this is the row that reads
    // it.
    check("…and nothing in the log claims the draft went back into the composer",
          !written().contains("input=draft-restored")
              && !written().contains("input=draft-restore-dropped"))
    // THE ORDINARY LINE, and the one whose log line somebody actually comes looking for: their
    // composer is empty and they want to know where it went. The answer is the kill buffer, and this
    // one line is the whole of what the log says about it.
    _ = tick("9502", suspected: false, offset: 2)
    check("a line with no draft suspected under it stashes exactly as one with a draft does",
          written().contains("pid=9502 input=draft-stashed rounds=\(sessionInputStashRounds)"))
    // A SESSION ON A DIALOG TOUCHED NOTHING, so it says nothing: a stash that never ran is not a
    // draft anybody has to be told about, and a line about it would be the log claiming to have
    // moved text it never went near.
    _ = tick("9503", text: "1", state: .blocked, waitingOnPerson: true, suspected: true, offset: 3)
    check("a dialog answer leaves no draft trail, because it touched no composer",
          !written().contains("pid=9503 input=draft-"))
    // AND A SOFT WAIT IS NOT A DIALOG, which is the 2026-09-05 correction and the reason these two
    // rows sit side by side on the SAME board state. Claude Code fires `idle_prompt` about sixty
    // seconds after it stops speaking and `supervisedSessionState` folds that soft wait into
    // `blocked`, so on any machine with the notification hook installed an ordinary idle session
    // arrives here looking exactly like a permission dialog. Its composer is in front of it, and
    // the reading that tells them apart is `SessionTick.waitingOnPerson` rather than the state.
    check("a session blocked by a soft wait is still a composer: stashed, and pasted into",
          tick("9520", state: .blocked, waitingOnPerson: false, suspected: true, offset: 20)
              == sessionInputDraftGuard(dialog: false, suspected: true))
    check("…and its composer's stash is in the log, which a dialog answer never leaves",
          written().contains("pid=9520 input=draft-stashed rounds=\(sessionInputStashRounds)"))
    check("…while the hard wait beside it gets the dialog's guard, off the same board state",
          tick("9521", text: "1", state: .blocked, waitingOnPerson: true, suspected: true,
               offset: 21) == sessionInputDraftGuard(dialog: true, suspected: true))
    // AND WHAT THAT IS WORTH IS THE STALL IT ENDS, stated as bytes rather than as a feeling: the
    // line a soft-waiting session gets is one paste with no wait inside it, and the line it used to
    // get is the dialog's, one key every `sessionInputByteGap` with the poll loop stopped for all
    // of them (six seconds at this channel's own byte limit).
    check("…so the soft wait's payload goes as one paste, and only the hard wait's key by key",
          pressed(plan("hi", sessionInputDraftGuard(dialog: false, suspected: true)))
              .contains(sessionInputPasteStart[0])
              && !pressed(plan("hi", sessionInputDraftGuard(dialog: true, suspected: true)))
                  .contains(0x1B))
    // AND THE ONE THAT MEANS SOMETHING IS WRONG: the terminal refused a write part-way through, so
    // the stash may have got out. The line is still written, because the draft may be in that kill
    // buffer; what went wrong is on the served line beside it, under its errno.
    _ = tick("9504", suspected: true, injection: .failed(ENXIO), offset: 4)
    check("a refused write still says the composer may have been stashed",
          written().contains("pid=9504 input=draft-stashed")
              && written().contains("pid=9504 input=failed-tty"))

    // MARK: - A write that sent nothing is the only failure there is

    // WHAT THIS SECTION USED TO GUARD (codex review of 1f69cf9): a Ctrl-Y refused AFTER the Return
    // was a DELIVERY, and reporting it as a failure had a caller send the same line into the same
    // conversation again. That answer is gone with the restore that produced it (2026-08-20), so
    // what is asserted now is that the two remaining answers still divide where they always did.
    check("the two answers an injection can give divide on whether the line was sent",
          SessionInputInjection.done.sent && !SessionInputInjection.failed(ENXIO).sent)
    let delivered = serve("9506", suspected: true, agents: 2, offset: 6)
    check("a line the terminal took is served as what it is: submitted",
          readSessionInputResult(sessionKey: "9506", dir: dir)?.outcome == "submitted")
    check("…and hands the typed line back, which is what the window repick reads",
          delivered.action.typed == "/clear" && delivered.action.moveTo == nil)
    check("…and counts what the /clear ended",
          written().contains("pid=9506 input=agents-killed count=2")
              && readSessionInputResult(sessionKey: "9506", dir: dir)?.detail
              == "killed 2 live agents")
    // AND A REFUSED WRITE IS THE OTHER SIDE OF IT: nothing was sent, so nothing is typed back to the
    // caller and nothing is claimed about agents it did not end. The two are asserted side by side
    // because the whole of the classification is the difference between them.
    let refusedSend = serve("9507", suspected: true, injection: .failed(ENXIO), agents: 2,
                            offset: 7)
    check("a write the terminal refused sent nothing, and says so",
          readSessionInputResult(sessionKey: "9507", dir: dir)?.outcome == "failed-tty"
              && refusedSend.action.typed == nil
              && !written().contains("pid=9507 input=agents-killed"))
    // The landing carries the same rule, since that is where the roster reading is normalised.
    check("a landing reports the agents its line ended only where the line was sent",
          SessionInputLanding.typed(.failed(ENXIO), agents: 3).agents == nil
              && SessionInputLanding.typed(.done, agents: 3).agents == 3)


    // MARK: - A window repick is a relaunch, and a relaunch ends the draft

    // THE DEFECT THIS SECTION EXISTS FOR (codex review of 002c176): the window repick arms on a
    // `/clear` that reached the composer and, a minute later, RESTARTS the child onto a healthier
    // account. The child is where the composer and its kill buffer live, so a clear typed into a
    // session that may be holding a draft closed the window and then took the draft with it - the
    // only copy, since a stash lives in the kill buffer of the process the repick kills.
    //
    // THE MATRIX IS THE ROWS THAT DIFFER, and the last column of each is the same line: what was
    // DELIVERED never changes here, only what may be done to the child afterwards.
    let armAfterClean = serve("9508", suspected: true, offset: 8)
    check("a clear typed into a session that may hold a draft is delivered, and cancels the repick",
          armAfterClean.action.typed == "/clear" && armAfterClean.action.repick == .cancel)
    // AND THE STASH IS EXACTLY WHY, which is the half a narrower fix would have left open: that
    // clear moved the draft into the child's kill buffer, its owner has walked away, and the
    // repick's own bar is five seconds of quiet - so a relaunch a minute later ends the one copy of
    // it that exists anywhere.
    check("…having stashed the draft into the kill buffer the relaunch would end",
          armAfterClean.guarded?.stash == true)
    // A WRITE THE TERMINAL REFUSED CLOSED NO WINDOW, so it neither arms nor cancels: the standing
    // arm beside it is waiting for a conversation id to change, and this line never reached the
    // conversation at all.
    let armAfterRefused = serve("9509", suspected: true, injection: .failed(ENXIO), offset: 9)
    check("a clear the terminal refused leaves the repick exactly as it found it",
          armAfterRefused.action.typed == nil && armAfterRefused.action.repick == .untouched)
    // A SESSION ON A DIALOG STASHES NOTHING and is the one row where the guard's two fields
    // disagree: its draft is in the composer behind the dialog rather than in a kill buffer, and a
    // SIGTERM ends it just the same. This is why the rule keys on `suspected` and not on whether a
    // stash ran. It is a HARD wait rather than a `blocked` board state, since 2026-09-05: the soft
    // one folds into the same state and leaves a composer that is stashed like any other.
    let armWhileBlocked = serve("9510", text: windowClearCommand, state: .blocked,
                                waitingOnPerson: true, suspected: true, offset: 10)
    check("a session on a dialog that may hold a draft cancels too, having stashed nothing",
          armWhileBlocked.guarded?.stash == false && armWhileBlocked.action.typed == "/clear"
              && armWhileBlocked.action.repick == .cancel)
    // AND THE ORDINARY CLEAR IS UNTOUCHED: nothing suspected, so the repick gets its line and the
    // preventive move this whole feature family exists for still happens.
    let armOrdinary = serve("9511", suspected: false, offset: 11)
    check("a clear with no draft under it arms the repick exactly as it always did",
          armOrdinary.action.typed == "/clear" && armOrdinary.action.repick == .arm("/clear"))
    // …and the arm really is what that value drives, asserted through the repick's own state rather
    // than only through the field: nil arms nothing, the line arms it.
    var armed = WindowRepickState()
    armed.apply(armOrdinary.action.repick, transcript: "before")
    var unarmed = WindowRepickState()
    unarmed.apply(armAfterClean.action.repick, transcript: "before")
    check("the repick is armed by the one and left idle by the other",
          windowRepickReadiness(armed, transcript: "after") != .idle
              && windowRepickReadiness(unarmed, transcript: "after") == .idle)

    // THE ARM THAT WAS ALREADY STANDING, which is the half "do not arm" could not reach (codex
    // review of e5bfd13). A clear that landed a moment ago with nothing suspected leaves an arm up
    // for a minute; it fires when Claude Code reports a different conversation. If the NEXT clear
    // carries a draft, it produces exactly that report - so a signal that merely declined to arm
    // would let the old arm relaunch the child holding the draft. The fixture is the real sequence:
    // arm from the clean clear, then apply what the drafting clear said.
    var standing = WindowRepickState()
    standing.apply(armOrdinary.action.repick, transcript: "before")
    check("the fixture really is armed before the second clear lands",
          windowRepickReadiness(standing, transcript: "after") == .landed)
    standing.apply(armAfterClean.action.repick, transcript: "after")
    check("a clear carrying a draft cancels the arm an earlier clear left standing",
          windowRepickReadiness(standing, transcript: "later") == .idle
              && standing == WindowRepickState())
    // AND AN ORDINARY SEND DOES NOT, which is the boundary of the cancellation: what makes a clear
    // entitled to cancel is that it IS the window-close the standing arm waits for. A prompt changes
    // no conversation id, so it cannot fire that arm, and disarming on it would drop a preventive
    // move for a reason unconnected to it - a window that closed while nobody was mid-draft.
    let ordinarySend = serve("9512", text: "hello", suspected: true, offset: 12)
    check("an ordinary send over a suspected draft leaves the repick untouched",
          ordinarySend.action.typed == "hello" && ordinarySend.action.repick == .untouched)
    var untouched = WindowRepickState()
    untouched.apply(armOrdinary.action.repick, transcript: "before")
    untouched.apply(ordinarySend.action.repick, transcript: "after")
    check("…so an arm standing beside it is still standing",
          windowRepickReadiness(untouched, transcript: "after") == .landed)
    // The three answers, asserted against the state they produce rather than only as values: this is
    // the table `WindowRepickState.apply` is, and the one a caller could get wrong by wiring the
    // cancelling answer to a nil `arm`.
    var table = WindowRepickState()
    table.apply(.arm("/clear"), transcript: "before")
    check("apply arms, leaves alone, and cancels, in the three shapes it is given",
          windowRepickReadiness(table, transcript: "after") == .landed)
    table.apply(.arm("hello"), transcript: "before")
    check("…a line that closes no window changing nothing, as the arm itself decides",
          windowRepickReadiness(table, transcript: "after") == .landed)
    table.apply(.untouched, transcript: "before")
    check("…the untouched answer changing nothing either",
          windowRepickReadiness(table, transcript: "after") == .landed)
    table.apply(.cancel, transcript: "before")
    check("…and the cancelling one clearing every field the arm had set",
          table == WindowRepickState())

    // ORDER, because these lines are read as a story: what was typed, and then where what was
    // already there has gone.
    check("the draft line comes after the line saying what was typed",
          written().range(of: "pid=9501 input=submitted").map { served in
              written().range(of: "pid=9501 input=draft-stashed")
                  .map { served.upperBound < $0.lowerBound } ?? false
          } ?? false)
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
                                 waitingOnPerson: false,
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
              && loop.contains("injectedAt: lastComposerWrite,")
              && loop.contains("now: tickNow)"))
    // AND UNDER THE TICK'S OWN CLOCK, SHARED WITH THE LINE THAT DESCRIBES THE SAME STAMP: the
    // drought audit reports how quiet that keyboard is and how old its burst is, and this reading
    // says whether the same burst is a draft. Three defaulted `Date()` calls are how one line comes
    // to report an age its own `draft-suspected` blocker disagrees with, which is the shape the
    // 2026-09-02 incident was read out of.
    check("…under a clock the audit line about that same stamp is written from too",
          loop.contains("let tickNow = Date()")
              && loop.contains("keyboard.idle(followIdleSeconds, now: tickNow)")
              && loop.contains("burstAt: keyboard.lastBurstAt, carryable: carryable")
              && loop.contains("fuseAllows: fuse.allows(), now: tickNow, log: handoffLog)"))
    check("…and that clock is read before the draft question it dates",
          loop.range(of: "let tickNow = Date()").map { taken in
              loop.range(of: "let draftSuspected = sessionInputDraftSuspected(").map {
                  taken.upperBound < $0.lowerBound
              } ?? false
          } ?? false)
    // BOTH WRITERS INTO THAT COMPOSER GET IT, which is the half that is easy to leave half done: the
    // requested line and the advisory knock type through the same door, and a draft is destroyed by
    // whichever of them was not told (QuotaKnock.swift).
    if let request = loop.range(of: "let action = applySessionInput("),
       let arm = loop.range(of: "windowRepick.apply(action.repick,",
                            range: request.upperBound ..< loop.endIndex),
       let knock = loop.range(of: "applyQuotaKnock(", range: arm.upperBound ..< loop.endIndex),
       // The statement AFTER the call rather than its last argument: the argument list grows (the
       // channel choice joined it in 0.59) and an anchor that names one of them turns a check about
       // the draft reading into a check about argument order (2026-08-20).
       let afterKnock = loop.range(of: "if knocked != nil {",
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
    // AND WHAT MAKES A DIALOG A DIALOG IS TAKEN FROM THE TICK, never from the board's own word for
    // it. `supervisedSessionState` folds a soft `idle_prompt` into `blocked`, so a writer handed
    // `session == .blocked` as this question types one key at a time into the composer of every
    // idle session on a machine with the notification hook installed, which is the 2026-09-05
    // correction. All FOUR writers are read here rather than the two above: the reading is per
    // call, and three of these calls reach no value this suite can inspect from outside.
    /// The argument list of one call in that loop, from its own name to the statement after it.
    func arguments(of call: String, until: String) -> String {
        guard let start = loop.range(of: call),
              let end = loop.range(of: until, range: start.upperBound ..< loop.endIndex)
        else { return "" }
        return String(loop[start.upperBound ..< end.lowerBound])
    }
    let writers = [("let action = applySessionInput(", "windowRepick.apply(action.repick,"),
                   ("applyCapResume(", "if resumed != nil {"),
                   ("applyQuotaKnock(", "if knocked != nil {"),
                   ("applyHostHealthKnock(", "if hostKnocked != nil {")]
    check("every writer into that composer is handed the hard wait, not the board's blocked",
          writers.allSatisfy {
              arguments(of: $0.0, until: $0.1).contains("waitingOnPerson: board.waitingOnPerson")
          })
    // AND EVERY ONE OF THEM IS ACCOUNTED FOR, which is what stops a fifth writer joining the loop
    // on a reading nobody looked at: four calls, four arguments.
    check("…and there are exactly four of them",
          loop.components(separatedBy: "waitingOnPerson: board.waitingOnPerson").count - 1 == 4)

    // MARK: - The loop that carries a plan out

    // WHAT THIS SECTION ANSWERS FOR: that the loop stops at the first refusal and observes every
    // pause the plan carries. Driven through a fake terminal that refuses the byte of its choosing,
    // because the real one a suite can reach (`/dev/null`) refuses the FIRST byte and can therefore
    // say nothing about a refusal anywhere else. The split this drives was bought by a surviving
    // mutant in 2026-08-19, when the loop still had to classify which side of the Return a refusal
    // was on; nothing is pressed after the Return any more, and the loop is asserted here on what it
    // still does.
    /// Run a plan against a terminal that refuses the press at `refuseAt` (nil refuses nothing),
    /// answering what came of it and every byte it managed to write.
    var sleptFor: [TimeInterval] = []
    func carry(_ steps: [SessionInputStep], refuseAt: Int? = nil)
        -> (SessionInputInjection, [UInt8]) {
        var written: [UInt8] = []
        sleptFor = []
        let outcome = runSessionInputPlan(steps, push: { byte in
            guard written.count != refuseAt else { return false }
            written.append(byte)
            return true
        }, sleep: { sleptFor.append($0) }, code: { EPERM })
        return (outcome, written)
    }
    /// The line these rows are about, named because the positions below are counted through it.
    let carriedText = "hi"
    let carried = plan(carriedText, sessionInputDraftGuard(dialog: false, suspected: true))
    let clean = carry(carried)
    check("a plan nothing refuses is done, and every byte of it reached the terminal",
          clean.0 == SessionInputInjection.done && clean.1 == pressed(carried))
    // The pauses belong to the plan rather than to this loop, so what is asserted is that the loop
    // observes them: one that dropped them would give a TUI its Return before it had settled, which
    // is the measurement `sessionInputSubmitPause` carries.
    check("…and it waits out every pause the plan carries, in order",
          sleptFor == waits(carried))
    // EVERY PLACE A REFUSAL CAN LAND, NAMED BY WHAT IS THERE rather than by an offset from the end.
    // The positions are computed from the constants the plan is built out of, because the version of
    // this that said `returnPress - 1` meant "inside the payload" and, once the markers arrived,
    // silently came to mean "the last byte of the closing marker": the check went on passing and the
    // state it claimed to cover stopped being covered (codex review of b5f48ae). A relative offset
    // cannot say which part of a plan it is about.
    let returnPress = pressed(carried).count - 1
    let payloadStart = stashKeys.count + sessionInputPasteStart.count
    let insideOpener = stashKeys.count + 1
    let insideCloser = payloadStart + carriedText.utf8.count + 1
    check("a refusal anywhere in the plan sent nothing, and says so",
          carry(carried, refuseAt: 0).0 == SessionInputInjection.failed(EPERM)
              && carry(carried, refuseAt: payloadStart).0 == SessionInputInjection.failed(EPERM)
              && carry(carried, refuseAt: returnPress).0 == SessionInputInjection.failed(EPERM))
    // AND THE TWO PLACES THIS COMMIT INVENTED: half a paste marker written, and a paste opened but
    // never closed. Both are states no plan could reach before the markers existed, so nothing was
    // asserting them; measured 2026-09-05 on a live composer, what an unclosed paste leaves is half
    // a line that the next keystrokes append to normally, which is the same residue the typed path
    // always left. What matters here is that the writer still calls it a failure rather than a line
    // it delivered.
    check("a refusal inside a paste marker is a line that never went, opened or half-opened",
          carry(carried, refuseAt: insideOpener).0 == SessionInputInjection.failed(EPERM)
              && carry(carried, refuseAt: insideCloser).0 == SessionInputInjection.failed(EPERM)
              && carry(carried, refuseAt: insideCloser).1
                  == Array(pressed(carried).prefix(insideCloser)))
    // AND THE SAME THREE QUESTIONS ON THE PLAN A DIALOG GETS, which has no markers at all: a fixture
    // written only against the pasted shape would stop covering the typed one the moment that shape
    // came back (it did, on 2026-09-05).
    let toDialog = plan("no", dialog)
    check("…and a typed answer refused part-way through is a refusal too",
          carry(toDialog, refuseAt: 0).0 == SessionInputInjection.failed(EPERM)
              && carry(toDialog, refuseAt: 1).0 == SessionInputInjection.failed(EPERM)
              && carry(toDialog).0 == SessionInputInjection.done)
    // AND IT STOPS THERE rather than pressing on: a terminal that refused byte three will refuse
    // byte four, and continuing would leave a partial line in a composer with a Return still to
    // come.
    check("…having written everything before the byte it stopped on, and nothing after it",
          carry(carried, refuseAt: returnPress).1
              == Array(pressed(carried).prefix(returnPress)))
    // THE RETURN IS THE LAST PRESS THERE IS, which is the plan's contract read back through the loop
    // that carries it out: there is no byte a terminal could refuse after the line has gone.
    check("…and the Return is the last byte the loop is ever asked to write",
          pressed(carried)[returnPress] == sessionInputReturnByte
              && carry(carried, refuseAt: returnPress + 1).0 == SessionInputInjection.done)

    // MARK: - The writer, as far as one can be driven without a terminal

    // The failure arm, which is all this process can reach (sessioninputchecks states why). What it
    // proves here is that the guard reaches the ioctl at all: a stash press is attempted first, so
    // the write fails on the STASH rather than on the payload - and both are the same errno, so what
    // separates them is that this call returns before any payload byte could have been written.
    check("a guarded write on a target that is not a terminal fails rather than pretending",
          injectSessionInput("hi", draft: sessionInputDraftGuard(dialog: false, suspected: true),
                             tty: "/dev/null", gap: 0, pause: 0) != .done)
}
