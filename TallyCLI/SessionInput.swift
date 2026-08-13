import Darwin
import Foundation

// TYPING INTO A SESSION ON ITS OWN BEHALF: what a poll tick does about a pending `tally session
// type`, and the terminal write that carries it out. The channel is SessionInputRequest.swift and
// the command that writes one is SessionInputCommand.swift; this is the supervisor's half, the way
// SessionSwitch.swift is `tally account`'s.
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
// `sessionInputMaxBytes` * `sessionInputByteGap` plus the submit pause, about 6.4 seconds, during
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
// (something WAS typed into that terminal) and it is why nothing here tries to suppress it.

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

/// The audit trail: one line per served request, so the answer to "what typed into my session, and
/// when" is never a matter of belief.
let sessionInputLog = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/logs/input.log")

// MARK: - The decision

/// What this tick does about a pending request. Pure to decide, so the whole gate table is
/// assertable without a terminal, a supervisor or a file.
enum SessionInputDecision: Equatable {
    /// Nothing pending, or nothing new: this tick does nothing and says nothing.
    case ignore
    /// There IS a request and the gates are shut for now. Deliberately distinct from a refusal: the
    /// request stays on disk, and the next tick decides again from scratch.
    case wait
    /// Type it.
    case inject(SessionInputRequest)
    /// Consume it and say why.
    case refuse(SessionInputOutcome, String)
}

/// Whether a request is past its life. Its own function because two answers depend on it and the
/// boundary is asserted: `at` exactly `sessionInputTTL` old is still live, so a caller who wrote one
/// at the limit is not refused by a rounding.
func sessionInputExpired(epoch: Int, now: Date, ttl: TimeInterval = sessionInputTTL) -> Bool {
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
/// and the TTL is what ends the wait (`sessionInputTTL` carries the same reasoning from the other
/// side). The precedent is `manualMoveIdleSeconds`: an instruction typed inside a turn is served at
/// the end of that turn rather than argued with.
///
/// EXPIRY IS CHECKED BEFORE THE STATE GATES, and it has to be: those gates are the reason a request
/// waits at all, so a TTL evaluated after them could only fire on a request that was already being
/// served. What the expiry then reports is WHY it never became injectable - `unknown` gets its own
/// word, because a session that cannot say what it is doing will not become injectable by waiting,
/// while a busy one would have.
func sessionInputDecision(request: SessionInputRequest?, servedEpoch: Int, state: SupervisedState,
                          keyboardIdle: Bool, now: Date = Date()) -> SessionInputDecision {
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
    guard !sessionInputExpired(epoch: request.epoch, now: now) else {
        return state == .unknown
            ? .refuse(.refusedNotReporting,
                      "this session reported nothing about itself for \(Int(sessionInputTTL))s")
            : .refuse(.refusedExpired, "still \(state.rawValue) after \(Int(sessionInputTTL))s")
    }
    guard state == .blocked || state == .idle else { return .wait }
    // Somebody is typing in that terminal: their keystrokes and these bytes would interleave into
    // one line. Waiting costs a tick; interleaving costs whatever the mixture happens to spell.
    guard keyboardIdle else { return .wait }
    return .inject(request)
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

/// Type `text` into this process's controlling terminal, and press Return if asked.
///
/// ONE BYTE AT A TIME WITH A PAUSE, because a TUI is a program that redraws between keystrokes and
/// filters a menu as they arrive; `sessionInputByteGap` carries the measurement that settled the
/// interval. STOPS AT THE FIRST FAILURE rather than pressing on: a terminal that refused byte three
/// will refuse byte four, and continuing would leave a partial line in a composer with a Return
/// still to come.
///
/// `tty` and the two intervals are injectable so a suite can exercise the loop without a terminal
/// and without waiting six seconds for it.
func injectSessionInput(_ text: String, submit: Bool, tty: String = "/dev/tty",
                        gap: TimeInterval = sessionInputByteGap,
                        pause: TimeInterval = sessionInputSubmitPause) -> SessionInputInjection {
    let fd = open(tty, O_RDWR)
    guard fd >= 0 else { return .failed(errno) }
    defer { close(fd) }
    func push(_ byte: UInt8) -> Bool {
        var character = CChar(bitPattern: byte)
        return ioctl(fd, sessionInputInjectRequest, &character) == 0
    }
    for byte in Array(text.utf8) {
        guard push(byte) else { return .failed(errno) }
        usleep(useconds_t(gap * 1_000_000))
    }
    guard submit else { return .done }
    usleep(useconds_t(pause * 1_000_000))
    guard push(sessionInputReturnByte) else { return .failed(errno) }
    return .done
}

// MARK: - The audit line

/// One line per served request. Pure, so the shape can be asserted without a home directory - the
/// whole point of these fields is that somebody reads them back weeks later.
///
/// The TEXT GOES LAST, the rule `handoffLogLine` states about its own cwd: it is the one field that
/// can contain a space, so everything before it stays at a fixed offset for an eye or a `grep`. It
/// is truncated to 40 characters and stripped of anything that is not printable, because a control
/// byte written verbatim into a log is a log that reformats somebody's terminal when they `cat` it -
/// and because this file must show WHAT was typed without becoming a transcript of it.
func sessionInputLogLine(pid: String, outcome: String, submit: Bool, text: String,
                         now: Date = Date()) -> String {
    let visible = String(text.unicodeScalars.map { scalar -> Character in
        scalar.properties.isDefaultIgnorableCodePoint || scalar.value < 0x20 || scalar.value == 0x7F
            ? "·" : Character(scalar)
    }.prefix(40))
    return "\(ISO8601DateFormatter().string(from: now)) pid=\(pid) input=\(outcome) "
        + "submit=\(submit ? "yes" : "no") bytes=\(text.utf8.count) text=\(visible)\n"
}

/// The mode this log is kept at: readable by its owner and by nobody else.
///
/// DELIBERATELY UNLIKE ITS NEIGHBOURS, and this is the note for whoever comes to make it consistent.
/// Everything else under `~/.tally` is 0644 (`handoff.log`, the history, the state directory), and
/// that is right for what those files hold: accounts, quota windows, which session moved where -
/// events ABOUT the work. This one holds the work itself. Every line carries the first 40 characters
/// of text that was typed into a live conversation, which is content rather than telemetry, and the
/// default mode hands it to every other uid on the machine.
///
/// THE CONTENT STAYS AND THE MODE MOVES, which is the trade this feature is built on. An audit line
/// stripped of what was typed answers "somebody typed something" and nothing a person consulting
/// this log ever asks; the cost of keeping it is one chmod.
let sessionInputLogMode = 0o600

/// Append one audit line, keeping the log at `sessionInputLogMode`.
///
/// IT CONVERGES AN EXISTING FILE rather than only setting the mode at creation, because the file
/// that matters most is the one that already exists: a machine that ran an earlier build has a 0644
/// log on it, and a permission applied only at `O_CREAT` would leave every one of those open for
/// good. Checked before it is set so the ordinary append costs a `stat` rather than a `chmod`.
///
/// Created HERE rather than left to the appender below, which opens `O_CREAT` at 0644: a mode is
/// only applied by `open` when the call actually creates the file, so making it first is what
/// decides the mode at all.
func appendSessionInputLine(_ line: String, to log: URL) {
    let manager = FileManager.default
    try? manager.createDirectory(at: log.deletingLastPathComponent(),
                                 withIntermediateDirectories: true)
    if !manager.fileExists(atPath: log.path) {
        manager.createFile(atPath: log.path, contents: nil,
                           attributes: [.posixPermissions: sessionInputLogMode])
    } else if (try? manager.attributesOfItem(atPath: log.path))?[.posixPermissions] as? Int
        != sessionInputLogMode {
        try? manager.setAttributes([.posixPermissions: sessionInputLogMode],
                                   ofItemAtPath: log.path)
    }
    appendHandoffLine(line, to: log)
}

// MARK: - The tick

/// Serve this session's pending `tally session type`, if there is one to serve.
///
/// The whole of it lives here rather than in the poll loop for the reason `syncSessionState` does:
/// Supervisor.swift is over its size cap, so the loop hands over the state it has already decided
/// this tick and everything else happens on this side.
///
/// `state` is THIS TICK'S reading rather than the file's, and the call site is immediately after
/// `syncSessionState` for that reason: the gate has to judge the session as it is now, not as it was
/// two seconds ago - the whole feature turns on noticing the moment a turn ends.
///
/// `inject` is injectable so the suite can drive every branch without a terminal.
func applySessionInput(_ state: inout SessionInputState, session: SupervisedState,
                       keyboardIdle: Bool, dir: URL = sessionInputDir,
                       log: URL = sessionInputLog, now: Date = Date(),
                       inject: (String, Bool) -> SessionInputInjection = {
                           injectSessionInput($0, submit: $1)
                       }) {
    let pid = state.sessionKey
    // Read once, and nothing to decide without one: every branch below is about a request, so the
    // absent case is answered here rather than in each of them.
    guard let request = readSessionInputRequest(sessionKey: pid, dir: dir) else { return }
    let outcome: SessionInputOutcome
    var detail: String?
    switch sessionInputDecision(request: request, servedEpoch: state.servedEpoch, state: session,
                                keyboardIdle: keyboardIdle, now: now) {
    case .ignore, .wait:
        return
    case .refuse(let refusal, let why):
        outcome = refusal
        detail = why
    case .inject(let asked):
        switch inject(asked.text, asked.submit) {
        case .done:
            outcome = asked.submit ? .submitted : .injected
        case .failed(let code):
            outcome = .failedTTY
            detail = "errno \(code): \(String(cString: strerror(code)))"
        }
    }
    // THE ANSWER FIRST, then the request file. The caller is polling for the answer, so writing it
    // first means there is never a moment where the request has vanished and nothing has replaced
    // it - which the caller could only read as "still waiting", right up to its timeout.
    state.servedEpoch = request.epoch
    writeSessionInputResult(SessionInputResult(epoch: request.epoch, outcome: outcome.rawValue,
                                               detail: detail),
                            sessionKey: pid, dir: dir)
    // Unlinked only when the file still holds the request that was SERVED, the rule
    // `PendingSwitchConsumption.commit` states: injection takes seconds, and a second `tally session
    // type` written in that window is a newer stamp at the same path. An unconditional unlink would
    // delete an instruction nobody has carried out; leaving it means the next tick serves it,
    // because `servedEpoch` records the epoch that was served rather than "whatever is pending".
    if readSessionInputRequest(sessionKey: pid, dir: dir)?.epoch == request.epoch {
        clearSessionInputRequest(sessionKey: pid, dir: dir)
    }
    appendSessionInputLine(sessionInputLogLine(pid: pid, outcome: outcome.rawValue,
                                               submit: request.submit, text: request.text,
                                               now: now),
                           to: log)
}
