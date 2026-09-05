import Foundation

// PICKING THE WORK BACK UP AFTER A WALL: the one line typed into the session a cap handoff has just
// restarted, and the gates that decide whether it is typed at all.
//
// THE INCIDENT (2026-08-21, session a97d0856). A turn woke, asked for a model that had nothing left,
// and died on a 429. The supervisor did everything it is there for: it read the cap out of the
// transcript, picked a sibling with room and relaunched the conversation on it 1.4 seconds later.
// What it could not do is the last inch. The new child came up on the resumed conversation with an
// empty composer, and the work the wall interrupted sat there until a person came back, read the
// terminal and typed "carry on". The account move was automatic and the reason for it was
// automatic; only the resumption needed hands.
//
// THE RULE THIS ADDS, and the whole of it: when a cap handoff moves a conversation whose turn the
// wall cut short, the supervisor types one marked line into the new child saying what happened and
// asking it to continue. That line is a keystroke channel into somebody's conversation, so it is
// held to the same table every other writer into that composer is held to (`sessionInputHold`,
// SessionInput.swift) plus two gates of its own, and it is ABANDONED rather than delayed the moment
// a person has actually driven: a prompt of their own. Weaker signs of one hold instead, and the
// offer's own life is what ends every wait.
//
// FOUR THINGS IT MAY NEVER DO, which are the reason this is a station with a state rather than two
// lines at the relaunch:
//
//   - SPEAK TWICE FOR ONE WALL. The arm is keyed by the cap's own instant (`lastCapAt`), so a second
//     handoff carrying the same cap re-arms nothing, and firing spends the arm outright.
//   - TYPE OVER SOMEBODY. A prompt of their own in the new child ends the arm for good
//     (`.drop(.userTurn)`): the person is here, they answered the wall themselves, and what they
//     typed is a better answer than what this would have. A keystroke BURST in that composer is the
//     weaker half of the same fact and it HOLDS (`.hold(.drafting)`), on the dialog row's terms:
//     the evidence expires (`sessionInputDraftLife`) and a person who is really there sends a
//     prompt, so both endings are reachable without a clock of this station's own; that claim is
//     about two numbers, see `capResumeLife`. The two were one branch and one word until
//     2026-09-02, and the log says what that cost: six dropped resumes on this machine, every one
//     `reason=someone-typed`, none saying which half fired.
//   - ANSWER A DIALOG. A blocked session is sitting on a permission request or a plan approval, and
//     a line typed at one of those is an answer to a question this supervisor never read. It HOLDS
//     rather than drops, because a dialog is answered and the composer comes back
//     (SessionInputDraft.swift measured that, case A7e).
//   - OUTLIVE ITS CONVERSATION. The offer names the conversation the wall interrupted and is
//     checked against the one in the window at the moment of typing (`Offer.conversation`): a
//     relaunch that starts a DIFFERENT conversation - `tally session clear`, run at the end of every
//     session on this fleet - leaves an offer standing that `arm` will not touch, and a fresh empty
//     window would otherwise be told to carry on work that was never in it.
//   - RECUR. The turn this line starts can hit a wall of its own, and the handoff that follows must
//     not start another one: after a nudge nothing re-arms until a PERSON has typed in the session
//     (`capResumeFollowedByPerson`). What handles a second wall is what handled the first, bounded
//     by the recovery fuse the supervisor already keeps (`RecoveryFuse`, three per ten minutes).
//
// WHY IT TYPES RATHER THAN FILES. The advisory knock next door chooses between the two because its
// reader is a session mid-turn, where a keystroke interleaves with the answer being written and a
// filed sentence does not (QuotaKnock.swift). This one has the opposite reader by construction: a
// child that has just come up on a resumed conversation with nothing running in it. A filed notice
// is handed over on the session's NEXT prompt or tool call, and waiting for a prompt is exactly the
// wait this exists to end, so filing here would deliver the line at the one moment it is worthless.
//
// WHAT IT DOES NOT REACH, deliberately. `cap-fallback` is the other relaunch a wall can produce: the
// session keeps its account and comes back on the declared fallback pairing (CapDetection.swift).
// That path already prints a sentence onto the terminal saying what it did and what to run to undo
// it, and it changes the MODEL under the conversation, so "carry on" is not obviously what its owner
// wants of a turn they may prefer to re-run themselves. Only `cap` is armed here.
//
// WHAT KEEPS IT OFF A CHILD THAT IS STILL COMING UP, since nothing here counts a child's age. The
// handoff COPIES the transcript into the target account's tree (`shareTranscript`), so the file the
// new child binds carries an mtime of that instant, and the board reads a file written within
// `sessionStateQuietSeconds` as a session that is working (`boundFileQuietness`). The offer
// therefore holds through the half minute after the move on the shared table's own `.turn` row,
// which is long enough for a resumed Claude Code to be reading its terminal. A bar of this
// station's own would be a second, weaker spelling of a reading that already exists.
//
// WHAT IT COSTS ON AN ORDINARY TICK: one optional test. Everything behind it, `turnEnded` included,
// is asked only while an arm stands, which is the seconds after a cap handoff and never otherwise.

/// The marker every automatic resume line carries, and the reason it is not just `[tally]`.
///
/// This line becomes a USER TURN in somebody's transcript: Claude Code cannot tell an injected
/// keystroke from a typed one, so afterwards the conversation, the log and any later reader are
/// looking at a prompt that nobody wrote. The marker is what makes it identifiable as this
/// supervisor's (grep `auto-resume` in a transcript or in `~/.tally/logs/input.log`), and it shares
/// the `[tally]` prefix with the advisory knock so a reader has one word for "this line came from
/// the launcher, not from me".
let capResumeMarker = "[tally] auto-resume:"

/// The audit word a typed resume leaves (grep `input=cap-resume`). Its own outcome rather than the
/// served one, on the terms `quotaKnockOutcome` states: the question that log answers is "what
/// typed into my session and when", and a line nobody asked for is exactly the entry a reader needs
/// to tell from one they did.
let capResumeOutcome = "cap-resume"

/// And the word when the terminal refused the write, on the same terms.
let capResumeFailedOutcome = "cap-resume-failed"

/// The word for an arm that will never be typed (grep `input=cap-resume-dropped`), with the reason
/// beside it. It exists because the interesting case is the SILENT one: a resume that did not happen
/// leaves no keystroke and no transcript event, so without this line the record cannot tell "the
/// person came back and took over" from "this feature is not working".
let capResumeDroppedOutcome = "cap-resume-dropped"

/// How long an arm may wait for a moment it can be typed at.
///
/// TWICE `sessionInputDraftLife`, which is what keeps the drafting hold from being the old drop
/// under a friendlier name. That hold clears when the burst behind it ages out at
/// `burstAt + sessionInputDraftLife`, and the burst is in the child the handoff relaunched, so it
/// is always LATER than the wall this clock runs from: equal lives expire first for every burst
/// there can ever be, which is what they did until 2026-09-02 (`sessionInputQueuedLife`, the same
/// fifteen minutes), leaving the branch written that day unable to reach the line beyond it. A real
/// dependency rather than a shared scale, and a second copy of that number would stop saying so.
///
/// THE EDGE IT DOES NOT COVER, stated rather than defended against: a burst landing in the SECOND
/// draft window ages out after this clock does and the offer is dropped as expired instead. That is
/// the judgement this clock already makes, MEASURED FROM THE CAP rather than from the relaunch:
/// half an hour after the work stopped, a session whose owner has still not touched it is one the
/// offer has stopped being about.
let capResumeLife: TimeInterval = sessionInputDraftLife * 2

/// How long after this supervisor types a line the user turn it produces keeps arriving.
///
/// `sessionInputDraftGrace`, and for the reason that constant was written: the child reads the
/// injected bytes off the terminal and Claude Code writes the prompt they spell a moment AFTER the
/// write returned, so the two facts are one instant recorded by two clocks. Without the margin, the
/// resume line would be read as the person coming back, which would re-arm this feature against its
/// own output and recur.
///
/// IT IS MEASURED FROM THE END OF THE WRITE, which is what makes two seconds enough. An injection is
/// the stash at `sessionInputByteGap` a key, the payload as one paste into a composer, and the
/// submit pause, so a line of this length spends about a second on the terminal before its Return
/// (five, before the payload stopped being typed on 2026-09-05): a margin measured from the
/// DECISION would have to be longer than the longest injection there is, a number that would stop
/// tracking the constants it is made of. `lastComposerWrite` is stamped after the write for this.
///
/// THE RESIDUAL, stated rather than defended against: a person who types a prompt of their own
/// inside two seconds of the line landing is not counted as having returned, so a genuinely fresh
/// cap minutes later does not re-arm. That fails towards silence, which is the direction this whole
/// station fails in on purpose.
let capResumeOwnLineGrace: TimeInterval = sessionInputDraftGrace

/// The line typed into the session that has just been moved off a capped account.
///
/// Names both accounts because both are the news: which one ran out (so the reader knows why their
/// turn died) and which one they are on now (so a decision to stop instead of carrying on is made
/// against the right window). Names them through `quotaKnockName`, which is the one rule in this
/// repo for what may go on a terminal's input queue as an account name: a label is free text from a
/// rename popover, and a newline in the middle of this sentence would submit half of it as a prompt
/// and type the rest into whatever came up next.
///
/// `limit` is the channel's byte budget, held here the way `quotaKnockMessage` holds its own: the
/// names are clipped to a budget of their own first, and whatever is left is cut to the limit, so
/// the guarantee is measured rather than reasoned about.
func capResumeMessage(from: Snapshot.Account, to: Snapshot.Account,
                      limit: Int = sessionInputMaxBytes) -> String {
    let line = "\(capResumeMarker) \(quotaKnockName(from)) hit its usage limit and cut a turn "
        + "short, and this session is now on \(quotaKnockName(to)). "
        + "Continue the work that was interrupted."
    return keystrokeClipped(line, bytes: limit)
}

/// The line a dropped arm leaves. Pure, and shaped like the other entries in that log: the stamp,
/// the session, what kind of record this is, and why.
func capResumeDropLine(pid: String, why: CapResumeDrop, now: Date = Date()) -> String {
    "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=\(capResumeDroppedOutcome) "
        + "reason=\(why.word)\n"
}

// MARK: - The decision

/// What is standing between an arm and the terminal this tick. Both rows are a WAIT: the next tick
/// decides again, and the arm's own life is what ends the waiting.
enum CapResumeHold: Equatable {
    /// The table every writer into this composer shares (SessionInput.swift): a turn of its own, a
    /// child that has not reported, somebody typing, a restart about to happen.
    case input(SessionInputHold)
    /// This session is waiting on a person: a permission request, a plan approval. Its composer is
    /// behind that dialog and a line typed now is an answer to a question nobody read it.
    case blocked
    /// This tick cannot say WHICH conversation is in that window, so it cannot say the offer still
    /// belongs to it. A wait rather than a drop, because it is what a window with no transcript
    /// bound yet looks like and the next tick usually answers it; what ends the waiting for good is
    /// the offer's own life.
    case unlocated
    /// A run of keystrokes in that composer with no prompt sent since
    /// (`sessionInputDraftSuspected`), which is EVIDENCE of somebody rather than the person
    /// themselves: mouse reporting and an IME write the same shape. A wait for the reason the
    /// dialog row above is one - if they are there they send a prompt, and if they are not the
    /// evidence expires - and it was a final drop until 2026-09-02, when the evidence had no expiry
    /// and this station's only measured failure mode was this branch.
    case drafting
}

/// Why an arm will never be typed. All three are final: the arm is cleared and this wall gets no
/// line.
enum CapResumeDrop: Equatable {
    /// A prompt of their own in the relaunched child: the person answered the wall themselves.
    /// STRICTLY A USER TURN, since 2026-09-02. The keystroke burst that used to share this case
    /// holds instead, and the two carry different words so the log can say which fired.
    case userTurn
    /// It never reached a moment it could be typed at inside `capResumeLife`.
    case expired
    /// The window now holds a DIFFERENT conversation from the one the wall interrupted. Final, and
    /// it has to be: the work this line offers to resume is not in there any more, so there is
    /// nothing for a later tick to reconsider.
    case otherConversation

    /// The word the log records it under.
    var word: String {
        switch self {
        case .userTurn: return "user-turn"
        case .expired: return "expired"
        case .otherConversation: return "other-conversation"
        }
    }
}

/// What this tick does about a pending resume. Pure to decide, so the whole grid is assertable
/// without a terminal, a supervisor or a file.
enum CapResumeDecision: Equatable {
    /// Nothing is armed. Almost every tick.
    case idle
    case hold(CapResumeHold)
    case drop(CapResumeDrop)
    /// Type this line.
    case type(String)
}

// MARK: - The rules, on their own

/// Whether a relaunch is one that left work hanging.
///
/// THREE REFUSALS, and each of them is a way for there to be nothing to resume:
///
///  - the reason is not a cap handoff, so no wall cut anything short (the header names
///    `cap-fallback`, the one neighbour this deliberately excludes);
///  - the relaunch is FRESH, which is `tally session clear` asking for an empty window: what starts
///    is a different conversation, and offering to continue the old one's work in it is the one
///    thing that request said not to do;
///  - a real assistant turn landed AFTER the cap, which is `observeCapHit`'s own recovery test read
///    the other way round: the conversation answered something after the wall, so whatever the wall
///    interrupted is not still sitting there.
///
/// A FOURTH - that there is a conversation to resume at all - is not asked here, and deliberately:
/// `arm` has to UNWRAP that id to store it on the offer, so asking it here as well would be the
/// same fact tested in two places, which is how the two come to disagree.
///
/// `answeredAt` nil means no post-launch main-chain turn was seen at all, which is the ordinary
/// shape of a session whose only recent event IS the 429 - so it counts as interrupted.
func capResumeInterrupted(reason: String, fresh: Bool, cappedAt: Date?,
                          answeredAt: Date?) -> Bool {
    guard reason == "cap", !fresh, let cappedAt else { return false }
    return answeredAt.map { $0 <= cappedAt } ?? true
}

/// Whether this cap is one this session has not already armed for (`lastCapAt`).
///
/// STRICTLY NEWER, so a second handoff carrying the same pending cap arms nothing: that is the
/// "one latch per wall" rule, and it is keyed on the cap's OWN instant rather than on the moment a
/// tick noticed it, because that is the value the whole cap track is keyed on already
/// (`PendingCapRecovery.cappedAt`, fixed once and never recomputed).
func capResumeFreshCap(cappedAt: Date, lastCapAt: Date?) -> Bool {
    lastCapAt.map { cappedAt > $0 } ?? true
}

/// Whether a PERSON has been in this session since the last line this supervisor typed into it.
///
/// The anti-recursion gate, and the whole of it. A session that has never been nudged answers yes,
/// because there is nothing to recur from. One that has answers yes only for a user turn far enough
/// past the nudge to be somebody else's (`capResumeOwnLineGrace`): the resume line itself becomes a
/// user turn in the transcript, so without the margin this feature would read its own output as the
/// person coming back and arm again on the very next wall.
func capResumeFollowedByPerson(nudgedAt: Date?, userTurnAt: Date?,
                               grace: TimeInterval = capResumeOwnLineGrace) -> Bool {
    guard let nudgedAt else { return true }
    guard let userTurnAt else { return false }
    return userTurnAt.timeIntervalSince(nudgedAt) > grace
}

// MARK: - What the supervisor carries between ticks

/// What one supervised session remembers about resuming after a wall.
///
/// In memory and per SESSION rather than per child, like `QuotaKnockState` and `DroughtWatch`
/// beside it, and here that is not a preference: the arm is RAISED by the tick that ends one child
/// and SPENT by a tick of the next one, so a per-child value could never carry it across the one
/// event it exists for.
///
/// A SELF-UPDATE EXEC LOSES AN ARM, which is the honest cost of holding this in memory rather than
/// on disk, stated the way `QuotaKnockState` states its own. That exec replaces the process image
/// and restarts the child; a session it catches in the seconds between a cap handoff and its resume
/// line comes back without the offer. The alternative is a file per session on a path that would
/// have to be swept, for a window measured in seconds.
struct CapResumeState: Equatable {
    /// One standing offer: the wall it is about, and the line that answers it.
    ///
    /// ONE VALUE RATHER THAN TWO OPTIONAL FIELDS, so that "there is a line iff there is an arm" is
    /// a shape the compiler holds rather than a convention three mutating methods have to keep.
    struct Offer: Equatable {
        /// The instant of the wall. Every clock in this file is measured from it.
        let at: Date
        /// The conversation the wall interrupted, by Claude Code's own id for it (the transcript's
        /// basename). THE OFFER IS ABOUT THIS CONVERSATION AND NO OTHER, and holding the id is what
        /// makes that checkable at the moment of typing rather than assumed from the fact that an
        /// offer exists.
        ///
        /// The first version of this file took the id into `arm`, asked `!= nil` of it and threw it
        /// away (codex review of fa59018): a relaunch that starts a DIFFERENT conversation - `tally
        /// session clear`, which this fleet runs at the end of every session - fails `arm`'s guard
        /// and returns without touching the offer, so a fresh empty window inherited an offer to
        /// carry on work that was never in it. Holding the id closes it at the other end, where the
        /// question is answerable: whatever route the window changed by, the id in front of us is
        /// not the id this offer is about.
        let conversation: String
        /// The line, built at the move from the two accounts as they were THEN. Held rather than
        /// rebuilt because it is a sentence about a moment: by the time it is typed the session may
        /// have moved again, and a line naming where it is now would describe a different event.
        let line: String
    }

    /// What is waiting to be typed, and nil on almost every tick of almost every session.
    private(set) var offer: Offer?
    /// The newest wall this session has armed for, kept after the offer is spent or dropped: it is
    /// what makes one wall worth one line (`capResumeFreshCap`).
    private(set) var lastCapAt: Date?
    /// When this supervisor last FINISHED typing a resume line into this session, and the
    /// anti-recursion gate reads it (`capResumeFollowedByPerson`).
    private(set) var nudgedAt: Date?

    /// Whether anything is waiting to be typed, which is the one question the ordinary tick asks.
    var isArmed: Bool { offer != nil }

    /// Raise an arm for a relaunch that has just happened, or leave everything as it was.
    ///
    /// Called AFTER the handoff rather than when the plan is made, so `conversation` is the id the
    /// relaunch actually resumes: `performHandoff` relocates the file with a forced fork check
    /// exactly because the id it resumes must be the one the conversation is really in, and arming
    /// off the earlier reading would judge "is there anything to resume" against a file the session
    /// may have left.
    ///
    /// `from` and `to` are accounts rather than labels because the sentence names them through the
    /// one rule for what may go on a terminal's input queue (`quotaKnockName`), and a second
    /// spelling of that rule is how a label with a newline in it gets typed into somebody's
    /// composer.
    mutating func arm(reason: String, fresh: Bool, cappedAt: Date?, answeredAt: Date?,
                      conversation: String?, from: Snapshot.Account, to: Snapshot.Account,
                      userTurnAt: Date?) {
        // The id the offer is ABOUT, and the reason its absence refuses here rather than inside
        // the predicate above: no conversation is no id, and no id is nothing for a later tick to
        // compare the window against.
        guard let conversation,
              capResumeInterrupted(reason: reason, fresh: fresh, cappedAt: cappedAt,
                                   answeredAt: answeredAt),
              let cappedAt,
              capResumeFreshCap(cappedAt: cappedAt, lastCapAt: lastCapAt),
              capResumeFollowedByPerson(nudgedAt: nudgedAt, userTurnAt: userTurnAt)
        else { return }
        lastCapAt = cappedAt
        offer = Offer(at: cappedAt, conversation: conversation,
                      line: capResumeMessage(from: from, to: to))
    }

    /// What this tick owes, in the order the gates bite.
    ///
    /// THE DROPS COME FIRST, and before the holds, because they are about whether this line is
    /// wanted at all rather than about whether now is the moment for it. A person who has typed a
    /// prompt outranks the clock: it is the more specific fact and it is true whatever the clock
    /// says.
    ///
    /// THEN THE SHARED TABLE, unchanged and asked through the same function every other writer into
    /// this composer asks (`sessionInputHold`): a second spelling of those four rows is four gates
    /// that can come to disagree about one instant.
    ///
    /// AND THIS STATION'S OWN TWO WAITS LAST, after the shared table rather than before it so that
    /// table's stated precedence is not quietly reordered here. Between them the dialog comes
    /// first: a composer behind a permission request is not one somebody is typing into, so naming
    /// the draft there would describe the wrong wait. All of them are holds, so the ordering
    /// decides only which word the record carries.
    func decide(state: SupervisedState, quiet: SessionQuiet, turnEnded: Bool, keyboardIdle: Bool,
                relaunchPlanned: Bool, draftSuspected: Bool, userTurnAt: Date?,
                conversation: String?, now: Date = Date()) -> CapResumeDecision {
        guard let offer else { return .idle }
        // WHICH CONVERSATION IS ACTUALLY IN THAT WINDOW, asked FIRST, because every gate below it
        // is about whether now is a good moment to type into this conversation and none of them
        // notices that it is the wrong one. A window that cannot say is waited for; one that says
        // something else ends the offer, since the work it points at is not in there to resume.
        guard let conversation else { return .hold(.unlocated) }
        guard conversation == offer.conversation else { return .drop(.otherConversation) }
        // A prompt of their own in the relaunched child, measured against the WALL rather than
        // against the relaunch; the two readings agree, since the watcher belongs to the new child
        // and refuses everything older than its launch, so any user turn it has seen at all is
        // newer than the cap that preceded it.
        if userTurnAt.map({ $0 > offer.at }) == true { return .drop(.userTurn) }
        // AND THE CLOCK BEFORE THE WAITS, which is what makes the draft row below reachable in both
        // directions without a second clock: an offer nobody could type at ends here whatever is
        // holding it, and it ends saying `expired` rather than naming the hold that outlasted it.
        if now.timeIntervalSince(offer.at) > capResumeLife { return .drop(.expired) }
        if let hold = sessionInputHold(state: state, quiet: quiet, turnEnded: turnEnded,
                                       keyboardIdle: keyboardIdle,
                                       relaunchPlanned: relaunchPlanned) {
            return .hold(.input(hold))
        }
        if state == .blocked { return .hold(.blocked) }
        if draftSuspected { return .hold(.drafting) }
        return .type(offer.line)
    }

    /// The bytes are on their way: this wall has had its line.
    ///
    /// Spent when the injection is ATTEMPTED rather than when it succeeds, the rule
    /// `applySessionInput` and the knock both state about their own stamps: past that point the
    /// bytes are on the terminal or the write has failed, and a failure that repeats every two
    /// seconds is the one way this types the same line into a conversation twice.
    ///
    /// IT DOES NOT STAMP `nudgedAt`, which is the other half of the same rule read from the other
    /// end: that stamp dates the moment the bytes STOPPED arriving, and this is called before the
    /// first of them is written (`noteTyped`).
    mutating func spend() { offer = nil }

    /// The write is over. Two seconds from here, a user turn is somebody else's
    /// (`capResumeOwnLineGrace`).
    ///
    /// A SECOND ENTRY POINT RATHER THAN AN ARGUMENT TO THE ONE ABOVE, because the two moments are
    /// seconds apart and the gap is the whole point: an injection types one byte every 30ms, so a
    /// stamp taken where the arm is spent would fall several seconds before the prompt it is meant
    /// to discount, and this feature would read its own line as the person coming back.
    mutating func noteTyped(at moment: Date) { nudgedAt = moment }

    /// This wall gets no line. `lastCapAt` stands, so nothing re-arms for it.
    mutating func drop() { offer = nil }
}

// MARK: - The tick's station

/// One poll tick's automatic resume: nil on almost every tick, and otherwise the line that was
/// typed.
///
/// `typedAlready` is whether this tick has already written into this composer, and it leads for the
/// reason the knock's own copy of it leads: two lines typed into one composer in one tick is one
/// prompt with two instructions in it. This station is asked BEFORE the advisory knock and after
/// the request station, which is the priority those three have - a line somebody asked for, then
/// work this session lost, then news about an account.
///
/// `turnEnded` is a closure because it reads a file and a transcript tail, and it is asked only
/// while an arm stands.
///
/// `log` and `inject` are injectable for the reason every writer on this track keeps them so: a
/// suite that reaches this decision must not type into the terminal it is running in, nor append
/// invented records to the user's own input log.
///
/// `stamped` is the clock read AFTER the write, and it is separate from `now` because they are
/// genuinely different instants: `now` is when this tick decided, and an injection spends seconds on
/// the terminal between the two (`capResumeOwnLineGrace` states what depends on the difference).
@discardableResult
func applyCapResume(_ state: inout CapResumeState, pid: String, typedAlready: Bool,
                    session: SupervisedState, quiet: SessionQuiet, turnEnded: () -> Bool,
                    keyboardIdle: Bool, relaunchPlanned: Bool, draftSuspected: Bool,
                    waitingOnPerson: Bool, userTurnAt: Date?, conversation: String?,
                    now: Date = Date(), log: URL = sessionInputLog,
                    stamped: () -> Date = { Date() },
                    inject: (String, SessionInputDraftGuard) -> SessionInputInjection = {
                        injectSessionInput($0, draft: $1)
                    }) -> String? {
    guard !typedAlready, state.isArmed else { return nil }
    let decision = state.decide(state: session, quiet: quiet, turnEnded: turnEnded(),
                                keyboardIdle: keyboardIdle, relaunchPlanned: relaunchPlanned,
                                draftSuspected: draftSuspected, userTurnAt: userTurnAt,
                                conversation: conversation, now: now)
    switch decision {
    case .idle, .hold:
        return nil
    case .drop(let why):
        // SAID OUT LOUD, because the whole of what happens here is that nothing happens: a resume
        // that was abandoned leaves no keystroke and no transcript event, so this line is the only
        // way the record can tell somebody taking over from this feature failing.
        state.drop()
        appendSessionInputLine(capResumeDropLine(pid: pid, why: why, now: now), to: log)
        return nil
    case .type(let line):
        state.spend()
        // The same protection the requested line gets. `suspected` is false by construction on this
        // branch (a suspected draft is a hold, one gate up), and the stash still runs: it is what
        // covers the draft this supervisor CANNOT see, since a paste is a single stamp and reads as
        // terminal chatter (SessionInputDraft.swift names it as the blind spot).
        let draft = sessionInputDraftGuard(dialog: waitingOnPerson, suspected: draftSuspected)
        let written = inject(line, draft)
        // The moment the bytes stopped arriving, which is what the anti-recursion gate has to
        // discount. Stamped whether or not the write succeeded: a refusal part-way through still
        // leaves keystrokes on that terminal, and suppressing a re-arm is the safe direction.
        state.noteTyped(at: stamped())
        switch written {
        case .done:
            appendSessionInputLine(sessionInputLogLine(pid: pid, outcome: capResumeOutcome,
                                                       text: line, now: now), to: log)
        case .failed(let code):
            appendSessionInputLine(quotaKnockFailureLine(pid: pid, code: code,
                                                         outcome: capResumeFailedOutcome,
                                                         now: now), to: log)
        }
        // AFTER the line that says what was typed, the order both other writers use: what was
        // typed, and then where what was already there has gone.
        appendSessionInputDraftLines(pid: pid, draft: draft, now: now, to: log)
        return written.sent ? line : nil
    }
}
