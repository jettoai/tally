import Foundation

// PICKING THE WORK BACK UP AFTER A WALL (TallyCLI/CapResume.swift): the line typed into a session a
// cap handoff has just moved, and the gates that decide whether it is typed at all.
//
// THE INCIDENT (2026-08-21, session a97d0856). A turn died on a 429, the supervisor moved the
// conversation to a sibling account 1.4 seconds later, and the work the wall interrupted then sat in
// the resumed window until a person came back and typed "carry on". Everything automatic about that
// recovery stopped one inch short of finishing it.
//
// THE GRID IS THE POINT of this file rather than any single case, and it is the whole enumeration
// rather than a sample of it: two kinds of wall (one that cut a turn short, one the conversation
// answered past) by three shapes the relaunched session can be in (nobody there, somebody typing,
// waiting on a person) by two latch states (the first wall, and a wall that follows a line this
// supervisor already typed). Twelve cells, every one asserted, because what this feature can get
// wrong is not one gate but a combination: a line typed over somebody, a line typed twice for one
// wall, or a line that starts a turn which hits a wall which types another line.
//
// Everything here is pure or pointed at a temporary file: no `~/.tally`, no terminal, and the log
// every branch writes is given a sink of its own.

func runCapResumeChecks() {
    let wall = Date(timeIntervalSince1970: 1_800_000_000)

    func acct(_ id: String, label: String) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: label, launchHome: "/tmp/\(id)",
                         sessionRemaining: 40, weeklyRemaining: 40, modelRemaining: 0,
                         sessionResetsAt: wall.addingTimeInterval(3 * 3600),
                         weeklyResetsAt: wall.addingTimeInterval(90 * 3600),
                         modelResetsAt: wall.addingTimeInterval(90 * 3600), modelWindowName: "fable",
                         resetCreditsAvailable: nil, isStale: false, error: nil)
    }
    let capped = acct("A", label: "Claude 2")
    let sibling = acct("B", label: "Claude 3")
    let sentence = capResumeMessage(from: capped, to: sibling)
    /// The conversation every fixture below arms for, and the one a window has to still be holding
    /// for the offer to be typed into it.
    let armedConversation = "abc"

    // MARK: - 33a. The sentence

    check("the resume line carries the marker that says nobody typed it",
          sentence.hasPrefix(capResumeMarker))
    check("…names the account that ran out and the one this session is on now",
          sentence.contains("Claude 2") && sentence.contains("Claude 3"))
    check("…asks the conversation to carry on rather than describing the move",
          sentence.contains("Continue the work that was interrupted."))
    check("…and fits the channel it is typed through",
          sentence.utf8.count <= sessionInputMaxBytes)
    // A label is free text from a rename popover and this is a keystroke channel: a newline in the
    // middle of the sentence submits half of it as a prompt and types the rest into whatever comes
    // up next. `quotaKnockName` is the one rule for that, and this asserts it is the rule used.
    let dangerous = acct("C", label: "Claude\n2")
    check("a label carrying a Return never reaches the terminal",
          !capResumeMessage(from: dangerous, to: sibling).contains("\n"))
    // The guarantee is measured rather than reasoned about, the way the knock's is: a window name
    // and a label are both published from outside this file, so a long one is cut rather than
    // trusted.
    let verbose = acct("D", label: String(repeating: "long name ", count: 40))
    check("and a sentence built from an over-long name is cut to the budget",
          capResumeMessage(from: verbose, to: verbose).utf8.count <= sessionInputMaxBytes)

    // MARK: - 33b. Which relaunches leave work hanging

    check("a cap handoff whose wall cut a turn short is one",
          capResumeInterrupted(reason: "cap", fresh: false, cappedAt: wall,
                               answeredAt: wall.addingTimeInterval(-10)))
    check("…and so is one whose child had answered nothing at all yet",
          capResumeInterrupted(reason: "cap", fresh: false, cappedAt: wall, answeredAt: nil))
    check("a conversation that answered a real turn AFTER the wall is not hanging",
          !capResumeInterrupted(reason: "cap", fresh: false, cappedAt: wall,
                                answeredAt: wall.addingTimeInterval(5)))
    check("a relaunch that is not a cap handoff is not one",
          !capResumeInterrupted(reason: "rebalance", fresh: false, cappedAt: wall,
                                answeredAt: nil))
    check("…the cap answered on the spot included, which keeps its account and changes its model",
          !capResumeInterrupted(reason: "cap-fallback", fresh: false, cappedAt: wall,
                                answeredAt: nil))
    check("a FRESH relaunch is not one: what it starts is a different conversation",
          !capResumeInterrupted(reason: "cap", fresh: true, cappedAt: wall, answeredAt: nil))
    // A MOVE THAT RESUMES NOTHING is refused where the id is UNWRAPPED rather than inside the
    // predicate above, so it is asserted as the state transition it actually is: the offer has to
    // HOLD that id, and there is none to hold.
    check("and a move that resumes nothing arms nothing, because there is no id to hold", {
        var nothing = CapResumeState()
        nothing.arm(reason: "cap", fresh: false, cappedAt: wall, answeredAt: nil,
                    conversation: nil, from: capped, to: sibling, personTurnAt: nil, caughtUp: true)
        return !nothing.isArmed
    }())

    // MARK: - 33c. One line per wall, and no line that answers itself

    check("a session that has armed for no wall arms for this one",
          capResumeFreshCap(cappedAt: wall, lastCapAt: nil))
    check("the same wall twice arms nothing",
          !capResumeFreshCap(cappedAt: wall, lastCapAt: wall))
    check("…nor does one reported a moment EARLIER than the wall already seen",
          !capResumeFreshCap(cappedAt: wall.addingTimeInterval(-1), lastCapAt: wall))
    check("a later wall does",
          capResumeFreshCap(cappedAt: wall.addingTimeInterval(60), lastCapAt: wall))

    // THE BUDGET (B-1360), per conversation: three lines per two hours until a person types.
    func within(_ nudges: [Date], in nudgedIn: String? = armedConversation,
                personTurnAt: Date? = nil, at moment: Date = wall) -> Bool {
        capResumeWithinBudget(conversation: armedConversation, nudgedConversation: nudgedIn,
                              nudges: nudges, personTurnAt: personTurnAt, at: moment)
    }
    // The ledger of those three lines, each write ending at its stamp (AutomaticInput.swift).
    func ownLines(_ nudges: [Date]) -> AutomaticInputLedger {
        var ledger = AutomaticInputLedger(knownSince: wall.addingTimeInterval(-7200))
        for nudge in nudges { ledger.note(start: nudge.addingTimeInterval(-1), end: nudge) }
        return ledger
    }
    let three = [wall.addingTimeInterval(-1800), wall.addingTimeInterval(-1200),
                 wall.addingTimeInterval(-600)]
    check("a conversation this supervisor has never typed into has nothing to recur from",
          within([], in: nil))
    check("after one line, silence still leaves two of three",
          within([wall.addingTimeInterval(-600)]))
    check("after three inside the window, silence is not somebody coming back", !within(three))
    check("…and neither is the user turn the newest line itself becomes",
          !within(three, personTurnAt: lastPersonTurn([three[2].addingTimeInterval(0.2)],
                                                      automatic: ownLines(three))))
    check("a prompt of their own after the newest line resets it",
          within(three, personTurnAt: three[2].addingTimeInterval(30)))
    check("lines typed into ANOTHER conversation spend nothing of this one's",
          within(three, in: "another-conversation"))
    check("the budget and its clock are the ones this file was written against",
          capResumeBudget == 3 && capResumeBudgetWindow == capResumeTestWindow)

    // MARK: - 33d. The grid: two walls by three shapes by two latch states

    /// One session as it stands on the tick after a cap handoff.
    ///
    /// `second` is the anti-recursion case: this supervisor has already typed its whole budget of
    /// resume lines into this conversation inside the window (B-1360), nobody has typed since, and
    /// a fresh wall has arrived. The state is built the way the loop builds it - arm, spend, note
    /// the write, arm again - rather than by setting a field, so what is asserted is the sequence
    /// the supervisor actually performs.
    func session(interrupted: Bool, second: Bool) -> CapResumeState {
        var state = CapResumeState()
        let answered = interrupted ? wall.addingTimeInterval(-10) : wall.addingTimeInterval(5)
        for offset: TimeInterval in second ? [-1800, -1200, -600] : [] {
            state.arm(reason: "cap", fresh: false, cappedAt: wall.addingTimeInterval(offset),
                      answeredAt: wall.addingTimeInterval(offset - 10),
                      conversation: armedConversation, from: capped, to: sibling,
                      personTurnAt: nil, caughtUp: true)
            state.spend()
            state.noteTyped(at: wall.addingTimeInterval(offset + 10))
        }
        state.arm(reason: "cap", fresh: false, cappedAt: wall, answeredAt: answered,
                  conversation: armedConversation, from: capped, to: sibling,
                  // The only user turn the previous child saw is the resume line this supervisor
                  // typed into it, which is exactly what must not read as somebody coming back.
                  personTurnAt: second
                      ? lastPersonTurn([wall.addingTimeInterval(-589.8)],
                                       automatic: ownLines(state.nudges)) : nil,
                  caughtUp: true)
        return state
    }

    // `dialog` is `SessionTick.dialogPossible`, which is what decides the dialog row since issue #2:
    // the board's `blocked` alone is also a soft idle prompt, and that shape is typed into.
    let shapes: [(name: String, state: SupervisedState, draft: Bool, dialog: Bool)] = [
        ("nobody has touched it", .idle, false, false),
        ("somebody is typing in it", .idle, true, false),
        ("it is waiting on a person", .blocked, false, true),
        ("it is only an idle prompt", .blocked, false, false),
    ]
    var grid = 0
    for (interrupted, wallName) in [(true, "a wall that cut a turn short"),
                                    (false, "a wall the conversation answered past")] {
        for shape in shapes {
            for second in [false, true] {
                let latch = second ? "the conversation's budget is already spent" : "first"
                let state = session(interrupted: interrupted, second: second)
                let decision = state.decide(state: shape.state, quiet: .quiet, turnEnded: false,
                                            keyboardIdle: true, relaunchPlanned: false,
                                            dialogPossible: shape.dialog,
                                            draftSuspected: shape.draft, caughtUp: true,
                                            userTurnAt: nil,
                                            conversation: armedConversation,
                                            now: wall.addingTimeInterval(30))
                let expected: CapResumeDecision
                if !interrupted || second {
                    expected = .idle
                } else if shape.dialog {
                    expected = .hold(.blocked)
                } else if shape.draft {
                    // A WAIT SINCE 2026-09-02, not the end of the offer: a burst is evidence about
                    // a person rather than the person, and the evidence expires
                    // (`sessionInputDraftLife`).
                    expected = .hold(.drafting)
                } else {
                    expected = .type(sentence)
                }
                grid += 1
                check("\(wallName), \(shape.name), \(latch)", decision == expected)
            }
        }
    }
    check("every cell of the grid was asserted, not a sample of it", grid == 16)

    // The other half of "somebody is typing": a prompt of their OWN in the relaunched child, which
    // the draft reading cannot see because the burst that spelled it ended in a Return.
    let typedInto = session(interrupted: true, second: false)
    check("a prompt typed into the relaunched child ends the offer",
          typedInto.decide(state: .idle, quiet: .quiet, turnEnded: false, keyboardIdle: true,
                           relaunchPlanned: false, dialogPossible: false, draftSuspected: false,
                           caughtUp: true, userTurnAt: wall.addingTimeInterval(20),
                           conversation: armedConversation,
                           now: wall.addingTimeInterval(30)) == .drop(.userTurn))
    // THE TWO FACTS THAT WERE ONE BRANCH AND ONE WORD UNTIL 2026-09-02, asserted apart: same
    // session, one gate each, opposite answers, and different words in the record. All six resumes
    // this machine ever dropped carried `someone-typed`, and nothing in the log could say which of
    // these two had fired.
    check("a keystroke burst waits where a prompt of their own ends it",
          typedInto.decide(state: .idle, quiet: .quiet, turnEnded: false, keyboardIdle: true,
                           relaunchPlanned: false, dialogPossible: false, draftSuspected: true,
                           caughtUp: true, userTurnAt: nil,
                           conversation: armedConversation,
                           now: wall.addingTimeInterval(30)) == .hold(.drafting))
    check("…and every ending this station can reach carries a word of its own",
          CapResumeDrop.userTurn.word == "user-turn" && CapResumeDrop.expired.word == "expired"
              && CapResumeDrop.otherConversation.word == "other-conversation")
    // AND THE CLOCK OUTRANKS THAT WAIT, which is what keeps the hold from being the old drop under
    // a friendlier name: an offer nobody could type at ends at `capResumeLife` whatever is holding
    // it, and it ends under its own word rather than the hold's.
    check("a drafting hold that outlives the offer becomes the expiry rather than a standing wait",
          typedInto.decide(state: .idle, quiet: .quiet, turnEnded: false, keyboardIdle: true,
                           relaunchPlanned: false, dialogPossible: false, draftSuspected: true,
                           caughtUp: true, userTurnAt: nil,
                           conversation: armedConversation,
                           now: wall.addingTimeInterval(capResumeLife + 1)) == .drop(.expired))
    // AND THE SEQUENCE THOSE TWO ENDINGS ONLY MEAN ANYTHING IN, driven by the real predicate rather
    // than by a boolean this file chose: `sessionInputDraftSuspected` answers from a burst and a
    // clock, and a hand-flipped Bool asserts the branch while asserting nothing about whether the
    // tick that flips it can ever arrive. The burst is in the relaunched child, so it is later than
    // the wall, so the evidence clears at `burstAt + sessionInputDraftLife` while the offer dies at
    // `wall + capResumeLife`. With those two equal the offer always went first, and the hold added
    // on 2026-09-02 was the drop it replaced under a friendlier name. Three moments, one fixture.
    let burst = wall.addingTimeInterval(60)
    func draftEvidence(at moment: TimeInterval) -> Bool {
        sessionInputDraftSuspected(burstAt: burst, userTurnAt: nil, injectedAt: nil,
                                   now: wall.addingTimeInterval(moment))
    }
    func afterBurst(at moment: TimeInterval) -> CapResumeDecision {
        typedInto.decide(state: .idle, quiet: .quiet, turnEnded: false, keyboardIdle: true,
                         relaunchPlanned: false, dialogPossible: false,
                         draftSuspected: draftEvidence(at: moment),
                         caughtUp: true, userTurnAt: nil, conversation: armedConversation,
                         now: wall.addingTimeInterval(moment))
    }
    let evidenceFresh = burst.timeIntervalSince(wall) + 30
    let evidenceGone = burst.timeIntervalSince(wall) + sessionInputDraftLife + 1
    check("a burst in the relaunched child holds the offer while that evidence is fresh",
          draftEvidence(at: evidenceFresh) && afterBurst(at: evidenceFresh) == .hold(.drafting))
    check("…and the line is typed at the tick the evidence expires, which is what the hold is for",
          !draftEvidence(at: evidenceGone) && afterBurst(at: evidenceGone) == .type(sentence))
    check("…with the offer's own life still the far end of the wait",
          afterBurst(at: capResumeLife + 1) == .drop(.expired))
    // THE CONTROL, which is why this station's life is DERIVED from the draft's rather than sharing
    // a scale with it: the first instant that line can be typed at is already past an offer that
    // only lived `sessionInputDraftLife`, and inside the one this station actually keeps.
    check("a life equal to the draft's could never reach that line, and this one reaches it",
          evidenceGone > sessionInputDraftLife && evidenceGone < capResumeLife)

    // MARK: - 33e. The shared table, and the clock

    /// Every gate open, so each check can close exactly one of them.
    func decide(_ state: CapResumeState, session: SupervisedState = .idle,
                quiet: SessionQuiet = .quiet, turnEnded: Bool = false, keyboardIdle: Bool = true,
                relaunchPlanned: Bool = false, dialog: Bool = false,
                conversation: String? = armedConversation, at moment: TimeInterval = 30)
        -> CapResumeDecision {
        state.decide(state: session, quiet: quiet, turnEnded: turnEnded,
                     keyboardIdle: keyboardIdle, relaunchPlanned: relaunchPlanned,
                     dialogPossible: dialog, draftSuspected: false, caughtUp: true,
                     userTurnAt: nil, conversation: conversation,
                     now: wall.addingTimeInterval(moment))
    }
    let ready = session(interrupted: true, second: false)
    check("a child that has not said what it is doing is waited for",
          decide(ready, session: .unknown) == .hold(.input(.notReporting)))
    check("a conversation mid-turn of its own is waited for",
          decide(ready, session: .working) == .hold(.input(.turn)))
    check("…unless that turn is one Claude Code has reported over",
          decide(ready, session: .working, turnEnded: true) == .type(sentence))
    check("somebody at the keyboard is waited for",
          decide(ready, keyboardIdle: false) == .hold(.input(.keyboard)))
    check("and a tick about to replace the child types nothing into it",
          decide(ready, relaunchPlanned: true) == .hold(.input(.restart)))
    check("a session waiting on a person is waited for by this station's own word",
          decide(ready, session: .blocked, dialog: true) == .hold(.blocked))
    check("an offer that never reached a typeable moment is given up on, not held for ever",
          decide(ready, session: .unknown, at: capResumeLife + 1) == .drop(.expired))
    check("…measured from the wall, so it is still live one second inside the life",
          decide(ready, session: .unknown, at: capResumeLife - 1)
              == .hold(.input(.notReporting)))
    check("and a session that was never armed answers nothing at all",
          decide(CapResumeState()) == .idle)

    // MARK: - 33f. One wall, one line

    var once = session(interrupted: true, second: false)
    check("the armed session types its line", decide(once) == .type(sentence))
    once.spend()
    once.noteTyped(at: wall.addingTimeInterval(30))
    check("…and having typed it, says nothing more about that wall", decide(once) == .idle)
    once.arm(reason: "cap", fresh: false, cappedAt: wall, answeredAt: nil,
             conversation: armedConversation, from: capped, to: sibling, personTurnAt: nil,
             caughtUp: true)
    check("…which a second handoff carrying the SAME wall cannot undo", decide(once) == .idle)
    // And the way back: a person types, so the next genuine wall is armed for again.
    once.arm(reason: "cap", fresh: false, cappedAt: wall.addingTimeInterval(600),
             answeredAt: nil, conversation: armedConversation, from: capped, to: sibling,
             personTurnAt: wall.addingTimeInterval(120), caughtUp: true)
    check("but a wall that follows a person coming back is armed for again",
          decide(once, at: 610) == .type(sentence))

    // A dropped offer is just as final as a typed one, and for the same wall.
    var dropped = session(interrupted: true, second: false)
    dropped.drop()
    dropped.arm(reason: "cap", fresh: false, cappedAt: wall, answeredAt: nil,
                conversation: armedConversation, from: capped, to: sibling, personTurnAt: nil,
                caughtUp: true)
    check("a wall whose offer was dropped does not come back on the next handoff",
          decide(dropped) == .idle)

    // MARK: - 33g. The station, end to end

    let log = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-capresume-\(UUID().uuidString).log")
    let fixturePid = "cr-test-\(UInt64.random(in: 60_466_176 ..< 2_176_782_336))"
    var typed: [String] = []
    var asked = 0

    @discardableResult
    func station(_ state: inout CapResumeState, typedAlready: Bool = false,
                 session: SupervisedState = .idle, draftSuspected: Bool = false,
                 userTurnAt: Date? = nil, conversation: String? = armedConversation,
                 caughtUp: Bool = true, at moment: TimeInterval = 30,
                 injection: SessionInputInjection = .done) -> String? {
        applyCapResume(&state, pid: fixturePid, typedAlready: typedAlready, session: session,
                       quiet: .quiet, turnEnded: { asked += 1; return false },
                       keyboardIdle: true, relaunchPlanned: false, draftSuspected: draftSuspected,
                       waitingOnPerson: false, caughtUp: caughtUp, userTurnAt: userTurnAt,
                       conversation: conversation,
                       now: wall.addingTimeInterval(moment), log: log,
                       // The clock read after the write, which in a suite is the same instant: what
                       // the production call buys with the second reading is the seconds an
                       // injection actually spends on a terminal.
                       stamped: { wall.addingTimeInterval(moment + 5) },
                       inject: { text, _ in typed.append(text); return injection })
    }
    func audit() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    var live = session(interrupted: true, second: false)
    let landed = station(&live)
    check("the station types the line the arm decided", landed == sentence && typed == [sentence])
    check("…records it under its own word, so a reader can tell it from a line they asked for",
          audit().contains("input=\(capResumeOutcome)"))
    check("…and spends the arm, so the next tick types nothing", station(&live) == nil)
    // THE STAMP IS THE END OF THE WRITE, NOT THE DECISION, which is what makes two seconds of grace
    // enough to discount the prompt this line becomes: an injection spends one byte every 30ms on
    // that terminal, so the two instants are seconds apart and the earlier one would fall well
    // before the transcript event it has to explain.
    check("…dating the line by when its bytes stopped arriving rather than by when it was decided",
          live.nudgedAt == wall.addingTimeInterval(35))
    check("…and counts it against the conversation it was typed into",
          live.nudgedConversation == armedConversation
              && live.nudges == [wall.addingTimeInterval(35)])
    check("…so the user turn that line becomes is not read as the person coming back",
          !capResumeWithinBudget(conversation: armedConversation,
                                 nudgedConversation: live.nudgedConversation,
                                 nudges: live.nudges + live.nudges + live.nudges,
                                 personTurnAt: lastPersonTurn([wall.addingTimeInterval(35.3)],
                                                              automatic: ownLines(live.nudges)),
                                 at: wall))

    typed.removeAll()
    var busy = session(interrupted: true, second: false)
    check("a tick that has already typed somebody's line says nothing",
          station(&busy, typedAlready: true) == nil && typed.isEmpty)
    check("…and holds its offer for the next tick rather than spending it", busy.isArmed)

    typed.removeAll()
    var abandoned = session(interrupted: true, second: false)
    check("a session somebody may be typing in is not typed into",
          station(&abandoned, draftSuspected: true) == nil && typed.isEmpty)
    // A WAIT RATHER THAN THE END OF IT (2026-09-02): the burst is evidence about a person rather
    // than the person, so the arm stands and the next tick asks again.
    check("…the offer stands, so a tick where that evidence has expired can still use it",
          abandoned.isArmed)
    check("…and nothing is recorded, because nothing has been given up on",
          !audit().contains("reason=drafting"))
    check("…the line landing as soon as the burst stops being read as a draft",
          station(&abandoned, draftSuspected: false, at: 40) == sentence && typed == [sentence])
    // AND THE OTHER WAY OUT OF THAT WAIT, which is what makes the hold safe without a clock of this
    // station's own: nobody comes back, the evidence never clears, and the offer's own life ends it
    // under the word for a clock rather than the word for a person.
    typed.removeAll()
    var waited = session(interrupted: true, second: false)
    _ = station(&waited, draftSuspected: true)
    check("an offer held that way to the end of its life is dropped as expired",
          station(&waited, draftSuspected: true, at: capResumeLife + 1) == nil
              && typed.isEmpty && !waited.isArmed
              && audit().contains("input=\(capResumeDroppedOutcome)")
              && audit().contains("reason=expired"))
    // AND THE HARD EVIDENCE STILL ENDS IT ON THE SPOT, under the word that says which fact it was:
    // this is the half that must NOT have become a wait, since a person who has typed a prompt of
    // their own has answered the wall better than this line would.
    typed.removeAll()
    var overtaken = session(interrupted: true, second: false)
    check("a prompt of their own ends the offer, and the record names that fact rather than a burst",
          station(&overtaken, userTurnAt: wall.addingTimeInterval(20)) == nil
              && typed.isEmpty && !overtaken.isArmed
              && audit().contains("reason=user-turn"))

    typed.removeAll()
    var refused = session(interrupted: true, second: false)
    check("a terminal that refuses the write reports nothing delivered",
          station(&refused, injection: .failed(ENXIO)) == nil)
    check("…says so with the errno, which is the whole of what separates the causes",
          audit().contains("input=\(capResumeFailedOutcome)") && audit().contains("errno=\(ENXIO)"))
    check("…and does NOT keep the arm, because a refusal that repeats every two seconds is how the "
              + "same line gets typed into one conversation twice", !refused.isArmed)

    // What the ordinary tick pays for this feature: one optional test, and nothing behind it.
    let before = asked
    var idle = CapResumeState()
    check("an unarmed session types nothing", station(&idle) == nil)
    check("…and is not charged the transcript read behind the turn question", asked == before)

    // MARK: - 33h. The offer belongs to ONE conversation

    // THE HOLE THIS CLOSES (codex review of fa59018). `arm` refuses everything that is not a cap
    // handoff, and refusing means RETURNING - it does not touch an offer already standing. So a
    // relaunch that starts a different conversation (`tally session clear`, whose plan is
    // `fresh: true`, and which this fleet runs at the end of every session) carried the offer into a
    // brand new empty window, where nothing else could tell: the drops all ask about the PERSON and
    // the holds all ask about the MOMENT, and neither of them notices the wrong conversation.
    //
    // The first version of this file took the id and threw it away: `arm` asked `conversation !=
    // nil` and stored `at` and `line`. The pure function asserting that refusal is three sections
    // up and it still passes - what it never covered is the STATE TRANSITION, `arm(fresh: true)`
    // landing on a state that already holds an offer.
    var carried = session(interrupted: true, second: false)
    check("an armed offer is not disarmed by a fresh relaunch, because arm just returns", {
        carried.arm(reason: "cap", fresh: true, cappedAt: wall.addingTimeInterval(60),
                    answeredAt: nil, conversation: "a-brand-new-window", from: capped, to: sibling,
                    personTurnAt: nil, caughtUp: true)
        return carried.isArmed
    }())
    check("…so the window it lands in is what refuses it: another conversation ends the offer",
          decide(carried, conversation: "a-brand-new-window") == .drop(.otherConversation))
    check("…and the same window still holding the same conversation is typed into",
          decide(carried) == .type(sentence))
    // A window that cannot say WHICH conversation it holds is waited for rather than typed into or
    // given up on: that is what a fresh window looks like before its first turn is written, and the
    // next tick usually answers it. The offer's own life is what ends this waiting.
    check("a window that has not said which conversation it holds is waited for",
          decide(carried, conversation: nil) == .hold(.unlocated))
    check("…and it is asked BEFORE every gate about the moment, since none of those would notice",
          decide(carried, session: .unknown, conversation: "a-brand-new-window")
              == .drop(.otherConversation)
              && decide(carried, relaunchPlanned: true, conversation: "a-brand-new-window")
                  == .drop(.otherConversation))
    // Ending it is final, on the same terms as the other two drops: the work this line offers to
    // resume is not in that window, so there is nothing for a later tick to reconsider.
    var landedElsewhere = session(interrupted: true, second: false)
    check("and the drop is final rather than a wait that could come back", {
        _ = station(&landedElsewhere, conversation: "a-brand-new-window")
        return !landedElsewhere.isArmed
    }())
    check("…and it says so in the log, which is the only trace a resume that never happened leaves",
          audit().contains("reason=other-conversation"))

    // MARK: - 33i. The same shape a second time, with a different cause behind it

    // THE SEQUENCE THIS COVERS, in one state and end to end: a wall, a burst that holds the line
    // back, evidence that expires, the line typed at last - and then the turn THAT line starts hits
    // a wall of its own. The second event has the same shape as the first (a cap handoff, a fresh
    // user turn in the transcript) and a completely different cause: the turn is this supervisor's
    // own sentence read back. It is here rather than in the pure grid because only the sequence can
    // get it wrong - the hold is new, and a hold that quietly re-dated the anti-recursion stamp, or
    // one whose release re-armed the station against its own output, would pass every row above.
    typed.removeAll()
    var recurring = session(interrupted: true, second: false)
    check("the first wall's line waits on the burst rather than being abandoned by it",
          station(&recurring, draftSuspected: true) == nil && recurring.isArmed)
    check("…and is typed once that evidence expires",
          station(&recurring, draftSuspected: false, at: 40) == sentence && typed == [sentence])
    check("…dated by the end of that write rather than by the tick that decided to wait",
          recurring.nudgedAt == wall.addingTimeInterval(45))
    // THE TURN THAT LINE STARTS WALLS AGAIN, and again (B-1360): each wall is fresh, nobody has
    // typed, and the only user turn since each line is that line itself. The conversation has a
    // budget of three lines per two hours, so the second and third walls are resumed and the
    // fourth is not. The turn each wall sees goes through the ledger of the lines typed so far,
    // which is how the supervisor reads it (`lastPersonTurn`).
    func wallAgain(_ offset: TimeInterval, userTurnAt: Date?) {
        recurring.arm(reason: "cap", fresh: false, cappedAt: wall.addingTimeInterval(offset),
                      answeredAt: nil, conversation: armedConversation, from: capped, to: sibling,
                      personTurnAt: lastPersonTurn(userTurnAt.map { [$0] } ?? [],
                                                   automatic: ownLines(recurring.nudges)),
                      caughtUp: true)
    }
    wallAgain(120, userTurnAt: wall.addingTimeInterval(45.5))
    check("a second wall arms again: one line of the conversation's three is spent",
          recurring.isArmed)
    check("…and is typed", station(&recurring, at: 130) == sentence)
    wallAgain(240, userTurnAt: wall.addingTimeInterval(135.5))
    check("a third wall arms too", recurring.isArmed && station(&recurring, at: 250) == sentence)
    wallAgain(360, userTurnAt: wall.addingTimeInterval(255.5))
    check("the fourth wall in two hours arms nothing, because the only turn since is its own line",
          !recurring.isArmed && recurring.nudges.count == 3)
    // AND A PERSON REALLY COMING BACK STILL RE-ARMS IT, which is the boundary of that refusal:
    // what is discounted is a turn inside `automaticTurnLag` of a write, not every later one.
    wallAgain(360, userTurnAt: wall.addingTimeInterval(250 + 120))
    check("…while a prompt somebody typed two minutes after that line does re-arm it",
          recurring.isArmed)
    check("…and the second offer waits on its own burst rather than on the first offer's stamps",
          recurring.decide(state: .idle, quiet: .quiet, turnEnded: false, keyboardIdle: true,
                           relaunchPlanned: false, dialogPossible: false, draftSuspected: true,
                           caughtUp: true, userTurnAt: nil,
                           conversation: armedConversation,
                           now: wall.addingTimeInterval(370)) == .hold(.drafting))

    try? FileManager.default.removeItem(at: log)
    runCapResumeCatchUpChecks(armed: session(interrupted: true, second: false),
                              conversation: armedConversation, wall: wall, sentence: sentence)
    runCapResumeArmCatchUpChecks(conversation: armedConversation, wall: wall, from: capped,
                                 to: sibling)
    runCapResumeBudgetChecks()
}

// MARK: - 33k. The arm is not raised off a half-read transcript (8292c97 fixup, scope widened)

/// The OLD child's watcher at the handoff: it has read the cap but not what came after it, where an
/// answer would say the wall interrupted nothing. The budget is shrunk so the cap and that answer
/// fall either side of one bounded read, which in production takes a cap landing inside the first
/// catch-up ticks after a launch.
func runCapResumeArmCatchUpChecks(conversation: String, wall: Date, from: Snapshot.Account,
                                  to: Snapshot.Account) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-capresume-arm-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let filler = catchUpToolResult(stamp(1), uuid: "t-after",
                                   payload: String(repeating: "z", count: 256 << 10))
    let answer = catchUpAssistant(stamp(3), uuid: "a-after", parent: "t-after", cacheCreation: 9)
    /// The watcher after `ticks` bounded scans of `lines`, and the offer its readings raise.
    func armed(_ lines: [String], ticks: Int)
        -> (watcher: TranscriptWatcher, state: CapResumeState) {
        writeCatchUp(lines.map { CatchUpLine(text: $0, fullPath: true) },
                     to: dir.appendingPathComponent("\(conversation).jsonl"))
        var w = TranscriptWatcher(projectDir: dir, since: wall.addingTimeInterval(-60),
                                  resumeID: conversation)
        w.scanBudgetBytes = 64 << 10
        for _ in 0..<ticks { _ = w.sawCapHit() }
        var state = CapResumeState()
        state.arm(reason: "cap", fresh: false, cappedAt: w.capHitAt,
                  answeredAt: w.lastMainChainEventAt, conversation: w.transcriptSessionID,
                  from: from, to: to, personTurnAt: w.lastUserTurnAt, caughtUp: w.caughtUp)
        return (w, state)
    }
    let cap = catchUpCap(stamp(0), uuid: "a-cap")
    let half = armed([cap, filler, answer], ticks: 1)
    check("the old child has read the wall but not the answer after it",
          half.watcher.capHitAt != nil && half.watcher.lastMainChainEventAt == nil
              && !half.watcher.caughtUp)
    check("…so the handoff raises no offer off that half-read transcript", !half.state.isArmed)
    let answered = armed([cap, filler, answer], ticks: 20)
    check("read to the end, the answer says the wall interrupted nothing: still no offer",
          answered.watcher.caughtUp && !answered.state.isArmed)
    let unanswered = armed([cap, filler], ticks: 20)
    check("read to the end with no answer after the wall, the offer is raised as before",
          unanswered.watcher.caughtUp && unanswered.state.isArmed)
    let unansweredHalf = armed([cap, filler], ticks: 1)
    check("…but not from the tick that has read only the wall", !unansweredHalf.state.isArmed)
}

// MARK: - 33j. A bounded catch-up is not evidence that nobody typed (codex review of 8292c97)

/// The review's own replay: 96 MiB of history, then a stop typed after the wall. The watcher is the
/// real one at the product budget, so its first tick reads a third of the file; the offer must wait
/// for the rest rather than read "no prompt yet" off a transcript it has not finished.
func runCapResumeCatchUpChecks(armed: CapResumeState, conversation: String, wall: Date,
                               sentence: String) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-capresume-catchup-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let history = catchUpHistory(stamp, small: 200, big: 96, bigBytes: 1 << 20)
    let stop = CatchUpLine(text: catchUpUser(stamp(10), uuid: "u-stop",
                                             text: "Stop, do not continue."), fullPath: true)
    /// One tick: the scan, then the decision off what it read, every other gate open.
    func tick(_ w: inout TranscriptWatcher, at moment: TimeInterval = 30) -> CapResumeDecision {
        _ = w.sawCapHit()
        return armed.decide(state: .idle, quiet: .quiet, turnEnded: true, keyboardIdle: true,
                            relaunchPlanned: false, dialogPossible: false, draftSuspected: false,
                            caughtUp: w.caughtUp, userTurnAt: w.lastUserTurnAt,
                            conversation: w.transcriptSessionID,
                            now: wall.addingTimeInterval(moment))
    }
    /// Ticks until the watcher has read to the end; every decision on the way, in order.
    func drain(_ lines: [CatchUpLine])
        -> (first: TranscriptWatcher, decisions: [CapResumeDecision]) {
        writeCatchUp(lines, to: dir.appendingPathComponent("\(conversation).jsonl"))
        var w = TranscriptWatcher(projectDir: dir, since: wall.addingTimeInterval(5),
                                  resumeID: conversation)
        var decisions = [tick(&w)]
        let first = w
        while !w.caughtUp, decisions.count < 20 { decisions.append(tick(&w)) }
        return (first, decisions)
    }
    let stopped = drain(history.lines + [stop])
    check("the first tick of a large catch-up has not read the stop typed after the wall "
          + "(offset \(stopped.first.offset))",
          stopped.first.lastUserTurnAt == nil && !stopped.first.caughtUp)
    check("…so the offer waits for the rest of the transcript rather than typing over the stop",
          stopped.decisions.first == .hold(.catchingUp))
    check("…holds on every tick until then (\(stopped.decisions))",
          stopped.decisions.dropLast().allSatisfy { $0 == .hold(.catchingUp) }
              && stopped.decisions.count > 1)
    check("…and once the transcript is read to its end, the stop ends the offer",
          stopped.decisions.last == .drop(.userTurn))
    // The other half of the exit: with nobody in the tail, the wait ends in the line itself.
    let quiet = drain(history.lines)
    check("with no prompt in the tail the same catch-up ends in the resume line "
          + "(\(quiet.decisions))",
          quiet.decisions.first == .hold(.catchingUp) && quiet.decisions.last == .type(sentence))
    // And the offer's own life still ends the wait: the hold is not a way to outlive it.
    var late = TranscriptWatcher(projectDir: dir, since: wall.addingTimeInterval(5),
                                 resumeID: conversation)
    check("an offer whose life runs out mid catch-up is dropped as expired, not held",
          tick(&late, at: capResumeLife + 1) == .drop(.expired) && !late.caughtUp)
}

// MARK: - 33l. The budget: three resumes per conversation per two hours (B-1360)

/// The window the budget runs on, spelled here so a change to it is a change to this file too.
let capResumeTestWindow: TimeInterval = 2 * 60 * 60

/// The anti-recursion gate as a budget kept per CONVERSATION. Until B-1360 one nudge per supervisor
/// refused every later wall until a person typed in the current child, and a PM fleet that rotates
/// conversations with /clear and is driven by cross-session messages never has one: 2026-10-07 left
/// three walls unresumed for 8 minutes, 58 minutes and two hours. Every fixture is built the way the
/// loop builds it (arm, spend, noteTyped), so what is asserted is the sequence the supervisor runs.
func runCapResumeBudgetChecks() {
    let iso = ISO8601DateFormatter()
    func at(_ text: String) -> Date { iso.date(from: text)! }
    func acct(_ id: String) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 40, weeklyRemaining: 40, modelRemaining: nil,
                         sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                         modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
                         error: nil)
    }
    let from = acct("A"), to = acct("B")
    /// One wall that cut a turn short, handed off with nobody typing in the new child.
    func wall(_ state: inout CapResumeState, _ cappedAt: Date, in conversation: String,
              userTurnAt: Date? = nil) {
        state.arm(reason: "cap", fresh: false, cappedAt: cappedAt, answeredAt: nil,
                  conversation: conversation, from: from, to: to, personTurnAt: userTurnAt,
                  caughtUp: true)
    }
    /// A wall whose line was typed, the write ending `typed` seconds after the wall.
    func resumed(_ state: inout CapResumeState, _ cappedAt: Date, in conversation: String,
                 typed: TimeInterval = 20) {
        wall(&state, cappedAt, in: conversation)
        state.spend()
        state.noteTyped(at: cappedAt.addingTimeInterval(typed))
    }

    // B12. The three walls of 2026-10-07, replayed with their own stamps. The previous nudge
    // belongs to the conversation the supervisor was in that morning; every user event the new
    // child saw was a cross-session message (`promptSource:"system"`), so none counts as a person.
    let replays: [(name: String, lastCap: String, nudged: String, nudgedIn: String,
                   wall: String, conversation: String)] = [
        ("#1 add635cc 12:11:46Z (waited two hours)", "2026-10-07T06:18:07Z",
         "2026-10-07T06:19:02Z", "62212a9c", "2026-10-07T12:11:46Z", "add635cc"),
        ("#2 530e00ca 12:14:00Z (waited 8 minutes)", "2026-10-07T06:42:18Z",
         "2026-10-07T06:58:03Z", "6f836d11", "2026-10-07T12:14:00Z", "530e00ca"),
        ("#3 add635cc 13:10:53Z (waited 58 minutes)", "2026-10-07T06:18:07Z",
         "2026-10-07T06:19:02Z", "62212a9c", "2026-10-07T13:10:53Z", "add635cc"),
    ]
    for replay in replays {
        var state = CapResumeState()
        wall(&state, at(replay.lastCap), in: replay.nudgedIn)
        state.spend()
        state.noteTyped(at: at(replay.nudged))
        wall(&state, at(replay.wall), in: replay.conversation)
        check("B12 replay \(replay.name) arms", state.isArmed)
    }

    // B1. A resume into conversation X, then /clear to Y with nobody typing: Y's wall arms.
    var cleared = CapResumeState()
    resumed(&cleared, at("2026-10-07T06:18:07Z"), in: "x-conversation")
    wall(&cleared, at("2026-10-07T12:11:46Z"), in: "y-conversation")
    check("B1 a wall in a conversation the supervisor has not resumed into arms", cleared.isArmed)

    // B2. One resume into Y, then Y walls again 59 minutes later with nobody typing (#3's shape).
    var again = CapResumeState()
    resumed(&again, at("2026-10-07T12:12:00Z"), in: "y-conversation")
    wall(&again, at("2026-10-07T13:10:50Z"), in: "y-conversation")
    check("B2 the second wall in one conversation inside the window arms (one of three spent)",
          again.isArmed)

    // B3. Three resumes into one conversation inside two hours: the fourth wall is refused, and the
    // refusal leaves a line saying the budget refused it.
    let log = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-capresume-budget-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: log) }
    let start = at("2026-10-07T12:00:00Z")
    var spent = CapResumeState()
    for minutes in [0.0, 20, 40] {
        resumed(&spent, start.addingTimeInterval(minutes * 60), in: "z-conversation")
    }
    let fourth = start.addingTimeInterval(60 * 60)
    var refused = spent
    armCapResume(&refused, pid: "b1360-test", log: log, now: fourth, reason: "cap", fresh: false,
                 cappedAt: fourth, answeredAt: nil, conversation: "z-conversation", from: from,
                 to: to, personTurnAt: nil, caughtUp: true)
    let audit = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    check("B3 the fourth wall in one conversation inside two hours arms nothing", !refused.isArmed)
    check("…and says the budget refused it (\(audit.debugDescription))",
          audit.hasSuffix("pid=b1360-test input=cap-resume-skipped reason=budget\n")
              && audit.components(separatedBy: "\n").count == 2)
    // A wall the budget did NOT refuse leaves no such line: the same call with a stamp short.
    let quiet = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-capresume-budget-ok-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: quiet) }
    var allowed = again
    armCapResume(&allowed, pid: "b1360-test", log: quiet, now: fourth, reason: "cap",
                 fresh: false, cappedAt: at("2026-10-07T13:30:00Z"), answeredAt: nil,
                 conversation: "y-conversation", from: from, to: to, personTurnAt: nil,
                 caughtUp: true)
    check("…while a wall the budget allows writes the armed line and no skipped one",
          ((try? String(contentsOf: quiet, encoding: .utf8)) ?? "").contains("cap-resume-armed")
              && !((try? String(contentsOf: quiet, encoding: .utf8)) ?? "").contains("skipped"))

    // B4. A person typing after the newest resume resets the budget.
    let newest = start.addingTimeInterval(40 * 60 + 20)
    var personBack = spent
    wall(&personBack, fourth, in: "z-conversation", userTurnAt: newest.addingTimeInterval(30))
    check("B4 a prompt of their own after the newest resume re-arms it", personBack.isArmed)
    // B4b. ...and the reset is WRITTEN, not just read at that one wall: the walls after it are read
    // by a newer child's watcher, which never saw the person (B-1360 line-close review: 12:50 typed,
    // 13:00 resumed, 13:20 refused). The fresh budget still stops at three.
    var back = spent
    wall(&back, fourth, in: "z-conversation", userTurnAt: start.addingTimeInterval(50 * 60))
    back.spend()
    back.noteTyped(at: fourth.addingTimeInterval(20))
    var later: [Bool] = []
    for minutes in [80.0, 100] {
        let cap = start.addingTimeInterval(minutes * 60)
        wall(&back, cap, in: "z-conversation")
        later.append(back.isArmed)
        back.spend()
        back.noteTyped(at: cap.addingTimeInterval(20))
    }
    check("B4b after a person, the 13:20 and 13:40 walls arm too (\(later))", later == [true, true])
    wall(&back, start.addingTimeInterval(120 * 60), in: "z-conversation")
    check("B4b …and the fourth line since the person, at 14:00, is refused", !back.isArmed)
    // The ledger of the three resume lines, the newest write ending at `newest`.
    var ledger = AutomaticInputLedger(knownSince: start)
    for nudge in spent.nudges { ledger.note(start: nudge.addingTimeInterval(-1), end: nudge) }
    var ownLine = spent
    wall(&ownLine, fourth, in: "z-conversation",
         userTurnAt: lastPersonTurn([newest.addingTimeInterval(0.3)], automatic: ledger))
    check("…while the turn that resume line itself becomes does not", !ownLine.isArmed)

    // B13. Tally's own typing never resets the budget, however late its turn lands (PM review of
    // 84fe4b2: 7 of 79 resume lines landed more than two seconds after their write).
    var slow = spent
    wall(&slow, fourth, in: "z-conversation",
         userTurnAt: lastPersonTurn([newest.addingTimeInterval(5.2)], automatic: ledger))
    check("B13 a resume line landing 5.2s after its write does not reset the budget",
          !slow.isArmed)
    var sent = ledger
    sent.note(start: newest.addingTimeInterval(100), end: newest.addingTimeInterval(101))
    var sendLine = spent
    wall(&sendLine, fourth, in: "z-conversation",
         userTurnAt: lastPersonTurn([newest.addingTimeInterval(104)], automatic: sent))
    check("B13 …nor a `tally session send` line 3s after its write", !sendLine.isArmed)
    var person = spent
    wall(&person, fourth, in: "z-conversation",
         userTurnAt: lastPersonTurn([newest.addingTimeInterval(120)], automatic: ledger))
    check("B13 …while a person two minutes after the line does", person.isArmed)

    // B14. A wall with no live work behind it was never going to be resumed, so the budget is not
    // what refused it: no `reason=budget` line, whatever the budget holds.
    let idleLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-capresume-idle-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: idleLog) }
    var idle = spent
    armCapResume(&idle, pid: "budget-test", log: idleLog, now: fourth, reason: "cap", fresh: false,
                 cappedAt: fourth, answeredAt: nil, conversation: "z-conversation", from: from,
                 to: to, personTurnAt: nil, caughtUp: true, owed: false, requiresLiveWork: true)
    let idleAudit = (try? String(contentsOf: idleLog, encoding: .utf8)) ?? ""
    check("B14 a budget refusal is not logged when there was no live work to resume (\(idleAudit.debugDescription))",
          !idle.isArmed && !idleAudit.contains("reason=budget"))

    // B5. The window is measured from the wall: every stamp older than it refills the budget, and
    // one stamp still inside keeps it spent only while all three are.
    var refilled = spent
    wall(&refilled, newest.addingTimeInterval(capResumeTestWindow + 1), in: "z-conversation")
    check("B5 a wall after every stamp has left the two hour window arms", refilled.isArmed)
    var partial = spent
    wall(&partial, start.addingTimeInterval(20 + capResumeTestWindow + 1), in: "z-conversation")
    check("…and so does one after only the oldest has left it", partial.isArmed)
    var inside = spent
    wall(&inside, start.addingTimeInterval(20 + capResumeTestWindow - 1), in: "z-conversation")
    check("…but not one a second before the oldest leaves it", !inside.isArmed)

    // B6. The same wall handed off twice arms once.
    var same = CapResumeState()
    wall(&same, fourth, in: "z-conversation")
    same.spend()
    wall(&same, fourth, in: "z-conversation")
    check("B6 the same wall's second handoff arms nothing", !same.isArmed)

    // B8. A `tally account` the conversation ran itself shares the budget.
    var switched = spent
    switched.armSwitch(at: fourth, fresh: false, conversation: "z-conversation", line: "x",
                       personTurnAt: nil, caughtUp: true)
    check("B8 a self-switch after three resumes in one conversation arms nothing",
          !switched.isArmed)
    var switchedElsewhere = spent
    switchedElsewhere.armSwitch(at: fourth, fresh: false, conversation: "other-conversation",
                                line: "x", personTurnAt: nil, caughtUp: true)
    check("…while one in another conversation does", switchedElsewhere.isArmed)
}
