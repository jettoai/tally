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
                    conversation: nil, from: capped, to: sibling, userTurnAt: nil)
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

    check("a session this supervisor has never typed into has nothing to recur from",
          capResumeFollowedByPerson(nudgedAt: nil, userTurnAt: nil))
    check("after a line is typed, silence is not somebody coming back",
          !capResumeFollowedByPerson(nudgedAt: wall, userTurnAt: nil))
    check("…and neither is the user turn that line itself becomes",
          !capResumeFollowedByPerson(nudgedAt: wall,
                                     userTurnAt: wall.addingTimeInterval(0.2)))
    check("a prompt of their own is",
          capResumeFollowedByPerson(nudgedAt: wall, userTurnAt: wall.addingTimeInterval(30)))

    // MARK: - 33d. The grid: two walls by three shapes by two latch states

    /// One session as it stands on the tick after a cap handoff.
    ///
    /// `second` is the anti-recursion case: this supervisor has already typed a resume line into
    /// this session, nobody has typed since, and a fresh wall has arrived. The state is built the
    /// way the loop builds it - arm, spend, arm again - rather than by setting a field, so what is
    /// asserted is the sequence the supervisor actually performs.
    func session(interrupted: Bool, second: Bool) -> CapResumeState {
        var state = CapResumeState()
        let answered = interrupted ? wall.addingTimeInterval(-10) : wall.addingTimeInterval(5)
        if second {
            state.arm(reason: "cap", fresh: false, cappedAt: wall.addingTimeInterval(-600),
                      answeredAt: wall.addingTimeInterval(-610), conversation: armedConversation,
                      from: capped, to: sibling, userTurnAt: nil)
            state.spend()
            state.noteTyped(at: wall.addingTimeInterval(-590))
        }
        state.arm(reason: "cap", fresh: false, cappedAt: wall, answeredAt: answered,
                  conversation: armedConversation, from: capped, to: sibling,
                  // The only user turn the previous child saw is the resume line this supervisor
                  // typed into it, which is exactly what must not read as somebody coming back.
                  userTurnAt: second ? wall.addingTimeInterval(-589.8) : nil)
        return state
    }

    let shapes: [(name: String, state: SupervisedState, draft: Bool)] = [
        ("nobody has touched it", .idle, false),
        ("somebody is typing in it", .idle, true),
        ("it is waiting on a person", .blocked, false),
    ]
    var grid = 0
    for (interrupted, wallName) in [(true, "a wall that cut a turn short"),
                                    (false, "a wall the conversation answered past")] {
        for shape in shapes {
            for second in [false, true] {
                let latch = second ? "a line has already been typed for an earlier wall" : "first"
                let state = session(interrupted: interrupted, second: second)
                let decision = state.decide(state: shape.state, quiet: .quiet, turnEnded: false,
                                            keyboardIdle: true, relaunchPlanned: false,
                                            draftSuspected: shape.draft, userTurnAt: nil,
                                            conversation: armedConversation,
                                            now: wall.addingTimeInterval(30))
                let expected: CapResumeDecision
                if !interrupted || second {
                    expected = .idle
                } else if shape.draft {
                    expected = .drop(.userTyped)
                } else if shape.state == .blocked {
                    expected = .hold(.blocked)
                } else {
                    expected = .type(sentence)
                }
                grid += 1
                check("\(wallName), \(shape.name), \(latch)", decision == expected)
            }
        }
    }
    check("every cell of the grid was asserted, not a sample of it", grid == 12)

    // The other half of "somebody is typing": a prompt of their OWN in the relaunched child, which
    // the draft reading cannot see because the burst that spelled it ended in a Return.
    let typedInto = session(interrupted: true, second: false)
    check("a prompt typed into the relaunched child ends the offer too",
          typedInto.decide(state: .idle, quiet: .quiet, turnEnded: false, keyboardIdle: true,
                           relaunchPlanned: false, draftSuspected: false,
                           userTurnAt: wall.addingTimeInterval(20),
                           conversation: armedConversation,
                           now: wall.addingTimeInterval(30)) == .drop(.userTyped))

    // MARK: - 33e. The shared table, and the clock

    /// Every gate open, so each check can close exactly one of them.
    func decide(_ state: CapResumeState, session: SupervisedState = .idle,
                quiet: SessionQuiet = .quiet, turnEnded: Bool = false, keyboardIdle: Bool = true,
                relaunchPlanned: Bool = false, conversation: String? = armedConversation,
                at moment: TimeInterval = 30)
        -> CapResumeDecision {
        state.decide(state: session, quiet: quiet, turnEnded: turnEnded,
                     keyboardIdle: keyboardIdle, relaunchPlanned: relaunchPlanned,
                     draftSuspected: false, userTurnAt: nil, conversation: conversation,
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
    check("a session waiting on a person is waited for by this station's own gate",
          decide(ready, session: .blocked) == .hold(.blocked))
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
             conversation: armedConversation, from: capped, to: sibling, userTurnAt: nil)
    check("…which a second handoff carrying the SAME wall cannot undo", decide(once) == .idle)
    // And the way back: a person types, so the next genuine wall is armed for again.
    once.arm(reason: "cap", fresh: false, cappedAt: wall.addingTimeInterval(600),
             answeredAt: nil, conversation: armedConversation, from: capped, to: sibling,
             userTurnAt: wall.addingTimeInterval(120))
    check("but a wall that follows a person coming back is armed for again",
          decide(once, at: 610) == .type(sentence))

    // A dropped offer is just as final as a typed one, and for the same wall.
    var dropped = session(interrupted: true, second: false)
    dropped.drop()
    dropped.arm(reason: "cap", fresh: false, cappedAt: wall, answeredAt: nil,
                conversation: armedConversation, from: capped, to: sibling, userTurnAt: nil)
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
                 at moment: TimeInterval = 30,
                 injection: SessionInputInjection = .done) -> String? {
        applyCapResume(&state, pid: fixturePid, typedAlready: typedAlready, session: session,
                       quiet: .quiet, turnEnded: { asked += 1; return false },
                       keyboardIdle: true, relaunchPlanned: false, draftSuspected: draftSuspected,
                       userTurnAt: userTurnAt, conversation: conversation,
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
    check("…so the user turn that line becomes is not read as the person coming back",
          !capResumeFollowedByPerson(nudgedAt: live.nudgedAt,
                                     userTurnAt: wall.addingTimeInterval(35.3)))

    typed.removeAll()
    var busy = session(interrupted: true, second: false)
    check("a tick that has already typed somebody's line says nothing",
          station(&busy, typedAlready: true) == nil && typed.isEmpty)
    check("…and holds its offer for the next tick rather than spending it", busy.isArmed)

    typed.removeAll()
    var abandoned = session(interrupted: true, second: false)
    check("a session somebody is typing in is not typed into",
          station(&abandoned, draftSuspected: true) == nil && typed.isEmpty)
    check("…the offer is given up rather than held", !abandoned.isArmed)
    check("…and the silence is recorded, since nothing else about it leaves a trace",
          audit().contains("input=\(capResumeDroppedOutcome)")
              && audit().contains("reason=someone-typed"))

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
                    userTurnAt: nil)
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

    try? FileManager.default.removeItem(at: log)
}
