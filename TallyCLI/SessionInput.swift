import Darwin
import Foundation

// TYPING INTO A SESSION ON ITS OWN BEHALF: whether a pending request may be carried out, and the
// terminal write that carries it out. The channel is SessionInputRequest.swift and the command that
// writes one is SessionInputCommand.swift; this is the supervisor's half, the way
// SessionSwitch.swift is `tally account`'s. The tick that acts on this decision is
// SessionInputTick.swift and the audit trail it leaves is SessionInputLog.swift.
//
// WHY THE SUPERVISOR CAN DO THIS AT ALL. It is started by the user's shell and spawns its child with
// null file actions (`spawnChild`, SupervisorRuntime.swift), so the two share one controlling
// terminal - the same fact `KeyboardIdle.swift` reads keystroke timing off. `TIOCSTI` pushes a byte
// into that terminal's input queue as though it had been typed, and the kernel allows it for the
// caller's OWN controlling terminal (any other terminal is EPERM). So the boundary of this feature
// is not the kernel's, it is the one drawn below.
//
// IT PRODUCES NO `RelaunchPlan`. Every other consumer in the poll loop decides whether to restart
// the child; this one writes bytes and returns. It is deliberately not on that path: there is
// nothing to stand down, nothing to hand back, and a relaunch mid-injection would type half a line
// into a child that is about to be killed.
//
// SYNCHRONOUS, ON THE POLL LOOP'S OWN THREAD, and that is a considered trade. The worst case is
// `sessionInputMaxBytes` * `sessionInputByteGap` plus the submit pause, plus the stash rounds and
// the restore pause that protect the draft under it (SessionInputDraft.swift), about 7.9s, during
// which this supervisor's 2s tick does not run: the child is unaffected (it is a separate process
// reading its own terminal), so what is delayed is the state file, the badge and the next relaunch
// decision. The alternative is a thread writing to a terminal while the tick that could kill the
// child runs beside it, and that is a concurrency bug waiting for a cap hit to land at the wrong
// moment. Delay, once, on a rare path, is the cheaper half.
//
// A NOTE ON WHAT INJECTION LOOKS LIKE TO THE REST OF THE TICK: the bytes land on the terminal's
// input queue, so the child's read stamps the device node's atime, and `KeyboardActivity` sees them
// on the next tick exactly as it sees a person typing. A non-urgent relaunch queued behind the
// keyboard gate therefore waits out one burst window after an injection. That is the honest reading
// (something WAS typed into that terminal) and it is why nothing here tries to suppress it. The one
// reader that must tell the two apart is the draft guard, since its whole question is "did a PERSON
// type recently", and it is told when this supervisor last typed rather than left to guess
// (`sessionInputDraftSuspected`, SessionInputDraft.swift).

/// How long to wait between bytes.
///
/// MEASURED, 2026-08-13, on the spike that proved this feature possible (`openpty` + `setsid` +
/// `TIOCSTI`, three stages green): at 2ms per byte a `/help` typed into Claude Code's composer
/// reached Return before the slash-command menu had settled, and the menu ate it. 30ms is inside
/// human typing speed and left every stage of that spike green.
let sessionInputByteGap: TimeInterval = 0.030

/// How long to wait after the last byte before pressing Return, for the same reason and from the
/// same measurement: a TUI redraws and re-filters between keystrokes, and Return has to arrive after
/// it has settled rather than during.
///
/// MEASURED ON CLAUDE CODE'S COMPOSER, AND ON NOTHING ELSE, which is worth saying because the other
/// CLI this app supervises has now been measured too and does not agree: Codex CLI's slash popup
/// was still on an earlier filter state when Return arrived at 400ms AND at 1200ms, so the send
/// picked the wrong menu entry, while the same text with Return four seconds later ran the command
/// it named (2026-08-13, section 3.3 of the design document, with the method and the six
/// combinations tried). Nothing is retuned for it here, and deliberately: `tally codex` is a plain
/// exec with no supervisor (`runLaunch`, main.swift), so no request can reach a Codex session in
/// the first place. When one can, the shape this measurement points at is a pause per provider
/// rather than one number raised until the slowest CLI is happy, since that would slow every
/// Claude Code send to pay for it.
let sessionInputSubmitPause: TimeInterval = 0.400

/// How still the keyboard has to be before anything is typed on the session's behalf.
///
/// The bar `KeyboardActivity` is asked at, not a rule of this feature's own: a burst holds the full
/// bar, a lone stamp only until the burst window closes (KeyboardIdle.swift carries the
/// measurements). Five seconds is what the other non-urgent gates use for their smallest question,
/// and what it buys here is that injected bytes never interleave with a half-typed line.
let sessionInputKeyboardQuietSeconds: TimeInterval = 5

/// The ioctl that puts one byte on a terminal's input queue: `_IOW('t', 114, char)`.
///
/// Named rather than used bare so the suite can assert it against that expansion. `TIOCSTI` imports
/// from Darwin on this platform (checked, not assumed), and the assertion is what would catch a
/// header that stopped exporting it or a value that moved: this is a legacy interface - Linux 6.2
/// removed it outright - so the day it goes away here, a test naming the number is a clearer failure
/// than an ioctl that quietly returns EINVAL.
let sessionInputInjectRequest: UInt = TIOCSTI

/// The byte a Return is.
///
/// CR (13), NOT LF. A terminal sends CR when the user presses Return and the line discipline's
/// ICRNL translates it; a raw-mode TUI reads the CR itself. Measured on the same spike: LF typed
/// into Claude Code's composer did not submit, CR did.
let sessionInputReturnByte: UInt8 = 13

// MARK: - The decision

/// What this tick does about a pending request. Pure to decide, so the whole gate table is
/// assertable without a terminal, a supervisor or a file.
enum SessionInputDecision: Equatable {
    /// Nothing pending, or nothing new: this tick does nothing and says nothing.
    case ignore
    /// There IS a request and something is standing in its way for now. Deliberately distinct from a
    /// refusal: the request stays on disk, and the next tick decides again from scratch. It carries
    /// WHAT stood, because that is the sentence a refusal at the end of the wait has to print.
    case wait(SessionInputHold)
    /// Type it.
    case inject(SessionInputRequest)
    /// Consume it and say why.
    case refuse(SessionInputOutcome, String)
}

/// What is standing between a pending request and the terminal, in the four shapes a caller can act
/// on differently.
///
/// NAMED RATHER THAN COUNTED, and that is the point of the type. The wait used to report "still
/// working after 120s" whatever had actually held it, so a caller whose line was blocked by
/// somebody typing, by a restart, or by its own unfinished turn was told the same sentence about
/// all three - and the one it most often was (its own turn) is the one it could have done something
/// about. Every refusal below is built from this, so the wait and the sentence cannot drift.
enum SessionInputHold: Equatable {
    /// The conversation itself is mid-turn: its transcript is moving, or a tool call it opened has
    /// not come back. Subagents writing in the background are NOT this (see `sessionInputHold`).
    case turn
    /// It has not said what it is doing at all, which is the one hold that never lifts by waiting.
    case notReporting
    /// Somebody is typing in that terminal, and injected bytes would interleave with their line.
    case keyboard
    /// This tick is about to replace the child, so anything typed now goes to a process that is
    /// being terminated.
    case restart

    /// What a refusal says about this hold, worded for the person reading stderr rather than for
    /// the log. `ttl` is named in every one of them: the sentence has to say what ran out as well
    /// as what stood.
    ///
    /// EVERY SENTENCE IS ABOUT THE INSTANT THE CLOCK RAN OUT, and none of them claims anything
    /// about the two minutes before it. A hold is sampled once, on the tick that finds the request
    /// expired, and the gates change from tick to tick: a line held by somebody typing for 119
    /// seconds and by an open turn for the last one was described as having been in a turn "for the
    /// whole 120s", which is a duration this decision never measured (codex review of 0c9798b). The
    /// two sentences that said so are now worded like the two that always were right. Recording the
    /// history instead was weighed and refused: it would mean writing a reason per tick to a file
    /// the caller does not read, for a sentence whose job is to tell that caller what to do NEXT.
    func sentence(ttl: TimeInterval) -> String {
        let seconds = Int(ttl)
        switch self {
        case .turn:
            return "it was still inside a turn of its own when its \(seconds)s ran out"
        case .notReporting:
            return "it was still reporting nothing about itself when its \(seconds)s ran out"
        case .keyboard:
            return "somebody was typing in that terminal when the \(seconds)s ran out"
        case .restart:
            return "this session was being restarted when the \(seconds)s ran out"
        }
    }
}

/// Whether a request is past its life. Its own function because two answers depend on it and the
/// boundary is asserted: `at` exactly `sessionInputQueuedLife` old is still live, so a caller who
/// wrote one at the limit is not refused by a rounding.
func sessionInputExpired(epoch: Int, now: Date, ttl: TimeInterval = sessionInputQueuedLife) -> Bool {
    now.timeIntervalSince1970 - TimeInterval(epoch) / 1000 > ttl
}

/// The gate table, in order.
///
/// `working` AND `unknown` ARE A WAIT RATHER THAN A REFUSAL, which is the one decision here that
/// looks wrong until the caller is pictured. The design document proposed refusing both, and the
/// commonest caller by far is an agent INSIDE the session running this as a tool call: at the
/// instant its request lands, that session is `working` by construction, because the tool call is
/// itself a turn that has not closed. Refusing on sight would mean the feature never fires on its
/// main path. So the request waits, tick by tick, for the state to become one it can be served from,
/// and what ends that wait is a ceiling on staleness rather than a deadline the session is racing
/// (`sessionInputQueuedLife` carries the reasoning and the measurement). The precedent is
/// `manualMoveIdleSeconds`: an instruction typed inside a turn is served at the end of that turn
/// rather than argued with.
///
/// QUEUED IS NOT LATE, which is the 2026-08-18 rework and the reason the clock below is fifteen
/// minutes rather than two. A request waiting for a turn to end is waiting for exactly the thing it
/// was written for, and charging that wait against a two-minute life made the ordinary hand-over
/// fail: the caller was told `queued`, the supervisor refused the line 120 seconds later, and the
/// window it meant to close stayed open (measured across two thirds of every send on this machine,
/// 2026-08-16/17). Nothing here distinguishes one hold from another for the purposes of that clock,
/// deliberately: a per-hold life would refuse a line that had waited out a long turn because
/// somebody happened to touch the keyboard on the tick the wait ended, which is an arbitrary
/// ending dressed up as a rule.
///
/// EXPIRY IS CHECKED BEFORE THE STATE GATES, and it has to be: those gates are the reason a request
/// waits at all, so a life evaluated after them could only fire on a request that was already being
/// served. What the expiry then reports is WHY it never became injectable - `unknown` gets its own
/// word, because a session that cannot say what it is doing will not become injectable by waiting,
/// while a busy one would have.
///
/// `relaunchPlanned` IS THE GATE THAT CANNOT BE READ OFF THE STATE, and it is the one this tick is
/// most likely to be wrong without. The poll loop decides on a relaunch (a `tally model`, a reload,
/// a self-update, a cap handoff) BEFORE it reaches this, and performs it a few lines AFTER: a
/// session that has just gone quiet enough to be typed into is exactly the session those planners
/// were waiting for, so the two fire on the same tick. Typing into a child that is about to be
/// SIGTERMed loses an unsent composer outright, and the caller is told `submitted` for a line that
/// no conversation ever saw (codex review of 18b3174). So a planned relaunch is a WAIT: nothing is
/// injected, nothing is consumed, no answer is written, and the next tick decides again against the
/// new child. The life keeps running through it, deliberately - whether that line still belongs in a
/// conversation whose child has been replaced is the caller's judgement, not this gate's.
///
/// It has no default value. A gate that can be forgotten at a call site is one that will be, and the
/// symptom here is invisible: the injection succeeds, and only the terminal knows it went nowhere.
///
/// A SESSION WHOSE SUBAGENTS ARE STILL WRITING IS TYPED INTO, which is the 2026-08-17 correction and
/// the one gate here that was removed rather than added. `working` covers two situations and this
/// gate used to refuse both: a conversation mid-turn, and a conversation that has finished speaking
/// while the agents it dispatched work on. Only the first is a reason not to type - the second is
/// precisely the head that has written its hand-over and wants its context cleared, and the agents
/// it is waiting on are not answered by a `/clear` either way. The cost of getting this wrong was
/// measured rather than argued: over 24 hours of real use, two thirds of every send on this machine
/// expired unserved (`~/.tally/logs/input.log`, 2026-08-16/17), and the ones that got through did so
/// on a retry. Albert's rule, in his words: an agent running is not a reason a window cannot be
/// cleared, because the hand-over file already says what to dispatch again.
///
/// AND IN EVERY SHAPE, which is the 2026-08-18 half of that rule and lives one file over. The
/// exemption below only ever reached the reading `subagentsWriting`, and which reading a session got
/// depended on what else lay in its transcript: dispatched work beside an over-age unmatched
/// `tool_use` came out `busy`, so the same hand-over was held after all - not refused any more (a
/// queued request outlives that window) but late by up to `subagentIdleSeconds`. That distinction is
/// gone from `boundFileQuietness`, where it belonged: what holds a line here is the head's OWN turn.
///
/// A TURN THAT SAID IT ENDED IS THE OTHER WAY PAST `working`, and it is what makes this gate act at
/// the moment the turn ends rather than 30 seconds later. `turnEnded` is the fact channel Claude
/// Code's own `Stop` hook leaves (SessionTurnEnd.swift): it is checked for the conversation it names
/// and for anything written since, and it is false on every machine that has not registered those
/// hooks, where the silence bar decides alone exactly as it did.
func sessionInputDecision(request: SessionInputRequest?, servedEpoch: Int, state: SupervisedState,
                          quiet: SessionQuiet, turnEnded: Bool, keyboardIdle: Bool,
                          relaunchPlanned: Bool, now: Date = Date()) -> SessionInputDecision {
    // Strictly newer than what this supervisor has served, the rule every request file on this
    // track follows: pids are reused and a served request is not unlinked until after it is served,
    // so "newer" is the only thing that makes a decision idempotent.
    guard let request, request.epoch > servedEpoch else { return .ignore }
    // Checked here as well as in the command, because this directory is writable by anything running
    // as this user: the command's limit is a courtesy to the person typing, this one is the bound
    // the poll loop's own stall depends on (see the header).
    let bytes = request.text.utf8.count
    guard bytes <= sessionInputMaxBytes else {
        return .refuse(.refusedTooLong, "\(bytes) bytes, limit \(sessionInputMaxBytes)")
    }
    let hold = sessionInputHold(state: state, quiet: quiet, turnEnded: turnEnded,
                                keyboardIdle: keyboardIdle, relaunchPlanned: relaunchPlanned)
    guard !sessionInputExpired(epoch: request.epoch, now: now) else {
        // WHAT STOOD AT THE END, named rather than summarised as the state word. A session that
        // never reported anything gets its own outcome, because that hold is the one that would
        // never have lifted by waiting; every other refusal is the clock running out on a hold
        // that might have.
        guard let hold else {
            return .refuse(.refusedExpired, "it reached a moment this could be typed at only after "
                + "its \(Int(sessionInputQueuedLife))s life had run out")
        }
        return .refuse(hold == .notReporting ? .refusedNotReporting : .refusedExpired,
                       hold.sentence(ttl: sessionInputQueuedLife))
    }
    guard let hold else { return .inject(request) }
    return .wait(hold)
}

/// What is standing in the way right now, or nil when nothing is and the line may be typed.
///
/// ONE TABLE FOR BOTH READERS: the tick asks it to decide whether to wait, and the refusal at the
/// end of a request's life asks it to say what the waiting was for. Two copies of this order would
/// let a request wait on one gate and be refused in the name of another.
///
/// THE ORDER IS THE PRECEDENCE. A planned relaunch leads because it outranks what the state can
/// see: `idle` is precisely the reading those planners were waiting for, so the ready-looking
/// session is the dangerous one, and typing into a child that is about to be SIGTERMed loses the
/// line while reporting it delivered (codex review of 18b3174). The keyboard comes last because it
/// is the most transient of the four: it is asked about the instant this tick runs.
///
/// `turnEnded` REACHES EXACTLY ONE ROW, the `working` one, and nothing else here bends to it. It
/// says the turn is over; it says nothing about somebody typing in that terminal, about a restart
/// this tick is going to perform, or about a session that has never reported what it is doing - and
/// a fact that let a line past all four would be a way around the gate rather than a faster route
/// through it.
func sessionInputHold(state: SupervisedState, quiet: SessionQuiet, turnEnded: Bool,
                      keyboardIdle: Bool, relaunchPlanned: Bool) -> SessionInputHold? {
    if relaunchPlanned { return .restart }
    switch state {
    case .unknown:
        return .notReporting
    case .working:
        // The one state that depends on WHY it is working: dispatched work writing in the
        // background is not this conversation being mid-turn (see the note above the decision, and
        // `boundFileQuietness` for the reading that no longer lets anything lying beside that work
        // change the answer), and neither is a turn Claude Code has told us it finished - the board
        // is still right to call the session working, and its own 30s bar is untouched by this.
        guard quiet == .subagentsWriting || turnEnded else { return .turn }
    case .blocked, .idle:
        break
    }
    // Somebody is typing in that terminal: their keystrokes and these bytes would interleave into
    // one line. Waiting costs a tick; interleaving costs whatever the mixture happens to spell.
    return keyboardIdle ? nil : .keyboard
}

// MARK: - What the supervisor carries between ticks

/// What one supervised session remembers about the input it has been asked to type. In memory and
/// per session, like `ManualMoveState` beside it and on the same terms.
struct SessionInputState {
    /// This session's address: the supervisor's own pid, the name the request file carries.
    let sessionKey: String
    /// The newest stamp this supervisor has served.
    var servedEpoch: Int

    /// `servedEpoch` defaults to whatever is pending right now, so a request written before this
    /// supervisor existed is never replayed - the file is addressed by pid and pids come round
    /// again, which for this feature means typing a stranger's line into a fresh conversation.
    ///
    /// The ONE caller for which that default is wrong is the same one `ManualMoveState` names: a
    /// self-update exec keeps the pid and IS the same session, so a request written moments before
    /// it belongs to this conversation and would be swallowed by the seed (`resumed`,
    /// Supervisor.swift passes 0 there).
    init(sessionKey: String, servedEpoch: Int? = nil, dir: URL = sessionInputDir) {
        self.sessionKey = sessionKey
        self.servedEpoch = servedEpoch
            ?? (readSessionInputRequest(sessionKey: sessionKey, dir: dir)?.epoch ?? 0)
    }
}

// MARK: - The terminal write

/// What one injection came to.
enum SessionInputInjection: Equatable {
    case done
    /// The terminal refused a write, with the errno it refused it under. ENXIO means this process
    /// has no controlling terminal (started from a script, a launch agent); EINVAL on a future macOS
    /// would mean this ioctl has been retired, which is the risk the header names.
    case failed(Int32)
}

/// Type `text` into this process's controlling terminal and press Return, moving whatever was in
/// that composer out of the way first and putting it back afterwards when `draft` says to.
///
/// RETURN IS NOT OPTIONAL, and that is the shape of the whole feature rather than a detail of this
/// function: what it exists to do is trigger what a session cannot trigger for itself, and text
/// left in a composer triggers nothing (SessionInputRequest.swift argues it where the record is
/// defined). An empty `text` is therefore a legitimate request: press Return alone, which is how a
/// prompt sitting on its default gets answered.
///
/// ONE BYTE AT A TIME WITH A PAUSE, because a TUI is a program that redraws between keystrokes and
/// filters a menu as they arrive; `sessionInputByteGap` carries the measurement that settled the
/// interval. STOPS AT THE FIRST FAILURE rather than pressing on: a terminal that refused byte three
/// will refuse byte four, and continuing would leave a partial line in a composer with a Return
/// still to come. A failure part-way through a stash therefore leaves the draft in the kill buffer
/// and unrestored, which is what the caller's `draft-restore-dropped` line is for.
///
/// `draft` HAS NO DEFAULT, on the same terms as `relaunchPlanned` next door: a call site that forgot
/// it would type over somebody's half-written prompt and report the line delivered, which is the
/// exact defect this parameter exists to end. `SessionInputDraftGuard.none` is how a caller says it
/// has no reading to offer, in words.
///
/// `tty` and the three intervals are injectable so a suite can exercise the loop without a terminal
/// and without waiting six seconds for it.
func injectSessionInput(_ text: String, draft: SessionInputDraftGuard, tty: String = "/dev/tty",
                        gap: TimeInterval = sessionInputByteGap,
                        pause: TimeInterval = sessionInputSubmitPause,
                        restorePause: TimeInterval = sessionInputRestorePause)
    -> SessionInputInjection {
    let fd = open(tty, O_RDWR)
    guard fd >= 0 else { return .failed(errno) }
    defer { close(fd) }
    func push(_ byte: UInt8) -> Bool {
        var character = CChar(bitPattern: byte)
        return ioctl(fd, sessionInputInjectRequest, &character) == 0
    }
    for step in sessionInputInjectionPlan(text: text, draft: draft, gap: gap, pause: pause,
                                          restorePause: restorePause) {
        switch step {
        case .press(let byte):
            guard push(byte) else { return .failed(errno) }
        case .wait(let seconds):
            usleep(useconds_t(seconds * 1_000_000))
        }
    }
    return .done
}
