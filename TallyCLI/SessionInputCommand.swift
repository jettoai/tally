import Foundation

// ASKING FOR IT: the CLI half of `tally session send`, split from SessionInput.swift (which keeps
// the supervisor-side decision) exactly as ModelCommand.swift is split from SessionModel.swift.
// This side decides WHAT WAS ASKED, addresses it to a session and waits for the answer; that side
// decides what a poll tick does about one; SessionInputRequest.swift is the channel between them.
//
// `session` IS A NAMESPACE RATHER THAN A COMMAND, and it is opened here with one verb in it. The
// second (`session renew`: end this child and start a fresh one, re-picking the account) is a
// different act on the same subject, and putting the first under a bare top-level name would leave
// the second either homeless or misfiled.
//
// IT WAITS FOR ANOTHER SESSION AND NOT FOR ITS OWN, which is the one asymmetry in this command and
// the thing to understand before changing anything here. `tally account` and `tally model` return
// the instant the file is on disk. This one waits, because it is normally run by an agent that has
// to know whether the text landed and the answer exists - EXCEPT when the session it is sending to
// is the one it is running in. There the wait is a deadlock: the command is a tool call, an
// unfinished tool call is an open turn, and a session mid-turn is precisely what the supervisor
// will not type into. So a self-send waits only long enough to catch a session that is already
// idle, then says the line is queued and gets out of the turn's way (SessionSendWait.swift carries
// the measurements and every wording).

/// What `tally session send` asks for. Pure to parse, so the grammar is testable.
///
/// NO FLAG SAYS WHETHER TO PRESS RETURN, because there is nothing to decide: a send types the text
/// and sends it, always (SessionInputRequest.swift argues why the half that stops in the composer
/// was the useless half). What the grammar carries is therefore the text, and which session it is
/// for.
struct SessionSendIntent: Equatable {
    /// The text to send. May be empty, which is a request to press Return alone.
    var text: String
    /// A session named on the command line rather than found. nil is the ordinary case: the session
    /// this command is running inside.
    var session: String?
}

/// What one command line asks for, or nil when it asks for something this command cannot act on.
///
/// TEXT IS ONE ARGUMENT. A second bare word is a usage error rather than a join, because the two
/// readings differ by exactly the whitespace the shell ate and there is no answer that is safe to
/// guess at - the same rule `modelIntent` states about its own two words.
///
/// NO TEXT AT ALL IS A REQUEST, not an error: press Return and type nothing, which is how a prompt
/// sitting on its default gets answered. It used to be spelled `--submit` with no text; the flag is
/// gone, so the shape that means it is the absence of an argument.
///
/// `--` ENDS THE FLAGS, so text that begins with a dash can still be sent (`tally session send --
/// --help` sends those six characters). Without it such text is refused rather than guessed at,
/// because every other reading makes a flag this command does not know into content.
func sessionSendIntent(_ args: [String]) -> SessionSendIntent? {
    var text: String?
    var session: String?
    var literal = false
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        index += 1
        if !literal {
            if word == "--" { literal = true; continue }
            if word == "--session" {
                guard index < args.endIndex, session == nil else { return nil }
                session = args[index]
                index += 1
                continue
            }
            guard !word.hasPrefix("-") else { return nil }
        }
        guard text == nil else { return nil }
        text = word
    }
    return SessionSendIntent(text: text ?? "", session: session)
}

/// Why this cannot be asked for, or nil when it can. Pure, and asked BEFORE anything is written, so
/// a refused value never reaches a request file.
func sessionSendProblem(_ intent: SessionSendIntent) -> String? {
    let bytes = intent.text.utf8.count
    guard bytes <= sessionInputMaxBytes else {
        // Named in the unit the limit is in, because a caller looking at 60 characters of Chinese
        // has no way to guess why 200 was exceeded (SessionInputRequest.swift states why bytes).
        return "that is \(bytes) bytes of UTF-8 and the limit is \(sessionInputMaxBytes); nothing "
            + "was queued. This sends short lines - a slash command, an answer to a prompt - and "
            + "anything longer belongs in the conversation itself"
    }
    return nil
}

// MARK: - One send at a time at one address

/// What is at this session's address, when something is.
///
/// TWO FILES, ONE ANSWER, and that is the whole point of this type. A send is in flight from the
/// moment its request is written until the moment its answer is COLLECTED, and those are two
/// different documents: the supervisor writes the answer and then unlinks the request, so between
/// a caller's polls there is a window in which the address looks empty while somebody is very much
/// still waiting at it. Asking only about requests is asking half the question (codex review of
/// 3c37831).
enum SessionInputOccupant: Equatable {
    /// A line still on its way: written, and not served yet.
    case request(SessionInputRequest)
    /// A line already served, whose answer the caller that asked for it has not read yet.
    case answer(SessionInputResult)
}

/// What is at this session's address, or nil when nothing there could still be part of a send.
///
/// THE ONE DOOR, deliberately: there is no way left to ask about requests alone, because that
/// question has a right-looking answer that is wrong for half of every send's life.
///
/// EXPIRED ONES DO NOT COUNT, and each half has its own clock because each is waited on by a
/// different thing:
///
///   - A REQUEST is live for `sessionInputTTL`, which is how long the supervisor will still act on
///     it. Past that it is a husk the next tick refuses, and treating it as an occupant would take
///     the address away for two minutes over a caller that was killed mid-wait.
///   - An ANSWER is live for as long as THAT caller said it would wait, measured from the same
///     stamp, because what makes an answer collectable is not the supervisor's willingness to act
///     but the CALLER's willingness to wait. For the ordinary caller that is `sessionInputWaitSeconds`,
///     longer than the TTL by design (150s against 120s, so a refusal of an expired request still
///     reaches the caller it belongs to). Judging an answer by the TTL would leave exactly the hole
///     this type closes: a `refused-expired` answer is born already older than the TTL, so it would
///     be a husk at birth and the next caller would delete it out from under a caller still polling
///     for it.
///
///     AND THE CALLER'S OWN NUMBER RATHER THAN THAT ONE FOR EVERYBODY, since a send into its own
///     session leaves early by design and its receipt is written to an address nobody is standing
///     at (`SessionInputRequest.waitSeconds` carries the whole argument and the defect it fixes).
///     A request that named no number at all is charged the long wait, exactly as before.
func sessionInputOccupant(sessionKey: String, dir: URL = sessionInputDir, now: Date = Date())
    -> SessionInputOccupant? {
    if let waiting = readSessionInputRequest(sessionKey: sessionKey, dir: dir),
       !sessionInputExpired(epoch: waiting.epoch, now: now) {
        return .request(waiting)
    }
    guard let answer = readSessionInputResult(sessionKey: sessionKey, dir: dir),
          !sessionInputExpired(epoch: answer.epoch, now: now, ttl: sessionInputAnswerLife(answer))
    else { return nil }
    return .answer(answer)
}

/// How long an answer is somebody's to collect: what its caller said it would wait, and the longest
/// wait anybody makes when it said nothing. Its own function because the occupant test and the
/// sentence a second caller is shown must not disagree about when an answer stops mattering.
func sessionInputAnswerLife(_ answer: SessionInputResult) -> TimeInterval {
    answer.waitSeconds.map(TimeInterval.init) ?? sessionInputWaitSeconds
}

/// What the second caller is told. Pure, so the wording is assertable.
///
/// REFUSED RATHER THAN WRITTEN OVER, and this is the whole of why. One address holds one send, so
/// a second one lands on top of the first: the first caller is then waiting for something that no
/// longer exists anywhere, gets nothing until its own timeout, and is told "nobody answered" for a
/// line that was in fact thrown away by us. Meanwhile the supervisor serves the second request and
/// writes an answer stamped with ITS epoch, so nothing on either end ever records that an
/// instruction was dropped (codex review of 18b3174). The answer half is the same failure with the
/// same ending, one step later: the text has been typed by then, so the caller that is told nobody
/// answered may reasonably send it again, and the session gets the line twice (codex review of
/// 3c37831).
///
/// AND NOT QUEUED, which is the other obvious answer and the more expensive one. Injection is
/// performed synchronously inside a poll tick, one byte at a time (SessionInput.swift), so a queue
/// turns "one tick may spend six seconds typing" into "one tick may spend as long as the queue is",
/// or else moves the typing off the tick and brings back exactly the concurrency this feature was
/// designed without (section 10 of the design document). Two callers typing into one composer is
/// also a thing neither of them can predict the result of.
///
/// TWO WORDINGS RATHER THAN ONE, because the two states differ in what the caller should do and in
/// what is at stake if they force it. A pending request will be served or expire, and waiting costs
/// the caller a minute; an uncollected answer is somebody's DELIVERY REPORT for text that is
/// already in the session, and the harm of stepping on it is a duplicated line rather than a lost
/// one. A caller reading stderr should be able to tell those apart without reading this file.
/// Both are worded so they cannot be mistaken for a gate refusal (`refused: session is working`
/// and its neighbours), which mean "try again, this may work later"; these mean "nothing of yours
/// was queued at all".
func sessionInputBusyRefusal(_ occupant: SessionInputOccupant, sessionKey: String,
                             now: Date = Date()) -> String {
    /// How long the thing at the address has left, on its own clock.
    func expiresIn(_ epoch: Int, _ life: TimeInterval) -> Int {
        max(0, Int(TimeInterval(epoch) / 1000 + life - now.timeIntervalSince1970))
    }
    switch occupant {
    case .request(let waiting):
        return "session \(sessionKey) already has a line waiting to be typed into it, so nothing "
            + "was queued for this one: a second request at that address would replace the first, "
            + "and the caller waiting on it would be told nobody answered. Let that one be served, "
            + "or wait up to \(expiresIn(waiting.epoch, sessionInputTTL))s for it to expire, then "
            + "ask again"
    case .answer(let answer):
        let left = expiresIn(answer.epoch, sessionInputAnswerLife(answer))
        return "session \(sessionKey) was sent a line already and the answer to it "
            + "(\(answer.outcome)) has not been collected yet, so nothing was queued for this one: "
            + "that answer is what the caller before you is still polling for, and taking it away "
            + "would tell them nobody answered for text that was in fact typed. It goes away when "
            + "they read it, or in \(left)s if they are gone"
    }
}

// MARK: - Which session `--session` may name

/// What a pid on the command line turns out to be.
enum NamedSession: Equatable {
    /// A supervisor of this machine's, addressed by its pid.
    case session(String)
    /// Nothing is running under that pid (or it is not a pid at all).
    case notRunning
    /// Something is running there, and it is not one of ours.
    case notSupervised
}

/// Which session `--session <pid>` names, if any.
///
/// LIVENESS IS NOT ENOUGH, which is what this exists to fix. `kill(pid, 0)` says a process is there
/// and nothing about what it is, so `--session <any live pid>` would write a request file addressed
/// to a stranger: it is never read, the command waits out its 150 seconds, and a document holding
/// the text meant for a conversation sits in a shared directory until something sweeps it. The
/// answer costs a directory listing (codex review of 18b3174).
///
/// THE REGISTRY IS THE FACT SOURCE, not a new test of our own: a supervisor writes a presence entry
/// under its own pid at startup (`markSupervisorLive`) and keeps it until it exits, which is the
/// same roster `tally reload` counts and `tally status --json` reports its sessions from. A second
/// notion of "is that one of ours" would be free to disagree with those.
///
/// A SUPERVISOR TOO OLD TO REGISTER is refused here, and that is the right answer rather than a
/// casualty: registration predates this command by many releases, so a supervisor without an entry
/// is one that could never have read the request either.
///
/// The bar is higher than the one the environment marker passes, on purpose. That marker is
/// evidence of DESCENT - this process was started inside that session - while a pid typed on a
/// command line is evidence of nothing at all.
///
/// EITHER HALF OF A SESSION ANSWERS TO ITS NAME, and that is not a convenience. A session is two
/// processes - the supervisor and the Claude Code under it - and the one a caller has in hand is
/// almost always the CHILD: `tally status --json` publishes that pid and no other (`sessions[].pid`
/// is documented as "the Claude Code process itself, not the Tally supervising it"), which is where
/// every agent and script is told to look. Accepting only the supervisor made the documented route
/// fail with "not a session this machine supervises" about a session that is plainly running, so a
/// child pid is resolved to the supervisor that owns it - proved through the same reader the switch
/// uses, which checks both that the file names that pid and that the process is really its child.
func namedSession(_ named: String, dir: URL = supervisorStateDir) -> NamedSession {
    guard let pid = pid_t(named), supervisorAlive(pid) else { return .notRunning }
    let supervisors = liveSupervisorPids(dir: dir)
    // Normalised through the pid, so `--session 0123` addresses the same file `--session 123` does
    // rather than writing a request nobody will ever read.
    if supervisors.contains(pid) { return .session(String(pid)) }
    if let owner = supervisors.first(where: {
        readSupervisorChild(pid: String($0), dir: dir) == Int(pid)
    }) {
        return .session(String(owner))
    }
    return .notSupervised
}

/// What to tell the caller about an answer. Pure, so every wording is assertable.
///
/// An outcome this build does not recognise is REPORTED VERBATIM rather than flattened into a
/// generic failure: a CLI one version behind a supervisor is exactly the case where the word itself
/// is the only information there is.
func sessionInputMessage(_ result: SessionInputResult, sessionKey: String) -> String {
    // Appended to EVERY wording, the successes included. A delivery does not normally carry one, but
    // a supervisor from a later build may say something alongside an outcome this one already
    // understands, and dropping it because the news was good is how a channel loses exactly the
    // sentence somebody added for a reason.
    let detail = result.detail.map { " (\($0))" } ?? ""
    switch result.resolved {
    case .submitted: return "sent to session \(sessionKey)\(detail)"
    case .refusedTooLong: return "refused: too long\(detail)"
    case .refusedNotReporting:
        return "refused: session \(sessionKey) never reported what it was doing, so nothing was "
            + "typed into it\(detail)"
    case .refusedExpired:
        return "refused: session \(sessionKey) never reached a moment this could be typed at"
            + "\(detail)"
    case .failedTTY: return "failed: the session's terminal refused the write\(detail)"
    case nil: return "the supervisor answered \"\(result.outcome)\"\(detail)"
    }
}

/// The exit code one run ends on. Four answers a script can act on, and they are kept apart on
/// purpose: 0 it landed; 3 it was refused, with a reason; 4 nobody answered in time; 1 something
/// here broke. Usage errors are 2, as everywhere else in this binary.
///
/// A SELF-SEND THAT WAS QUEUED EXITS 0 WITHOUT A RESULT, which is the one thing this code says that
/// no `SessionInputResult` can: the caller IS the session, so "did it land" cannot be answered from
/// inside the turn that has to end first (SessionSendWait.swift). Exit 0 therefore means "typed, or
/// queued for this session with nothing refusing it", and the line printed says which. A code of
/// its own was weighed and refused: every caller of this is a hand-over that reads non-zero as
/// "fall back to doing it by hand", and a queued line is not a failure to fall back from.
func sessionInputExitCode(_ result: SessionInputResult?) -> Int32 {
    guard let result else { return 4 }
    return result.delivered ? 0 : 3
}

/// `tally session send [<text>] [--session <pid>]`: type into a supervised session's own terminal
/// and press Return.
func runSessionSend(args: [String]) -> Int32 {
    guard let intent = sessionSendIntent(args) else {
        warn(sessionSendUsage)
        return 2
    }
    if let problem = sessionSendProblem(intent) {
        warn(problem)
        return 3
    }
    // The marker this process carries, checked for liveness: the session it descends from. Trusted
    // rather than corroborated, the rule SessionAddressing.swift states - a command typed (or run as
    // a tool call) inside a session descends from it, which is the case corroboration exists to tell
    // apart from a prompt somebody was merely told about.
    let marker = SessionMarkerTrust.trusted(liveSessionMarker())
    let sessionKey: String
    if let named = intent.session {
        switch namedSession(named) {
        case .session(let key):
            sessionKey = key
        case .notRunning:
            warn("no supervisor is running as pid \(named). `tally status --json` lists the "
                + "sessions this machine is supervising")
            return 3
        case .notSupervised:
            // Named apart from the case above because the two want different things done: one is a
            // pid that has gone, the other is a live process this machine never supervised, and
            // writing a request to the second would leave somebody's text in a file addressed to a
            // stranger.
            warn("pid \(named) is running, but it is not a session this machine supervises, so "
                + "nothing there would ever read the request. `tally status --json` lists the ones "
                + "that would; a session supervised by a build too old to register is refused here "
                + "too, and one restart (exit, then `tally claude`) is what fixes that")
            return 3
        }
    } else {
        switch marker.resolve(here: supervisorsInDirectory(FileManager.default.currentDirectoryPath))
        {
        case .session(let key):
            sessionKey = key
        case .none:
            warn("this session is not supervised, so nothing here can send into it: it was launched "
                + "bare, with --no-handoff, or with an --account pin. Sessions started with `tally "
                + "claude` can be typed into.")
            return 3
        case .ambiguous(let pids):
            warn("\(pids.count) supervised sessions are running in this directory, so this command "
                + "cannot tell which one you mean (pids \(pids.joined(separator: ", "))). Run it "
                + "inside the session you mean, or name it with --session <pid>.")
            return 3
        }
    }
    // Whether anything will read the request, through the same answer `tally account` and `tally
    // model` get. Judged only where the session named ITSELF (`adopted` returns nil when the
    // directory answered, or when --session named somebody else): the version stamped in this
    // environment describes this session's supervisor and says nothing about another one's.
    if liveRequestHonourability(marker: marker.adopted(sessionKey)) == .tooOld {
        warn("this session's supervisor predates `tally session send` and would never read the "
            + "request, so nothing was queued. Restart this session once (exit, then launch again "
            + "with `tally claude`) and it can be typed into from then on.")
        return 3
    }
    // Both husk sweeps, at the only moment this directory grows. The requests are swept by the same
    // loop every per-session channel uses; the answers need their own, because that loop reads a
    // file name as a pid outright (SessionInputRequest.swift).
    sweepDeadSessionRequests(dir: sessionInputDir)
    sweepDeadSessionInputResults(dir: sessionInputDir)
    // ONE SEND AT A TIME AT ONE ADDRESS: refused rather than written over whatever is still there,
    // where "still there" spans BOTH documents a send uses (`SessionInputOccupant` says why a
    // request-only question is half a question, and `sessionInputBusyRefusal` argues the refusal).
    //
    // ASKED BEFORE THE CLEAR BELOW, which is not an ordering detail: that answer file may be the one
    // another caller is polling for right now, and taking it away on our way to being refused would
    // turn its delivery into a timeout. After the sweeps, so a husk left by a session that has since
    // died is not mistaken for an occupant.
    //
    // The window it does not close, said rather than implied: two commands that both read an empty
    // address before either has renamed its file still collide, and the second write still wins.
    // Closing that needs an exclusive publish (`link(2)` rather than `rename(2)`, with its own
    // retry for the expired-overwrite case), and it is not bought here because the race is two
    // invocations inside the same millisecond while the defect this fixes was two callers inside
    // the same TWO MINUTES - the TTL makes overlap the ordinary case rather than the freak one.
    if let occupant = sessionInputOccupant(sessionKey: sessionKey) {
        warn(sessionInputBusyRefusal(occupant, sessionKey: sessionKey))
        return 3
    }
    // Whatever answer is at this address is a HUSK, and that is established rather than assumed: the
    // check above just refused every answer a caller could still come back for, so what can be left
    // is one older than the longest wait anybody makes. It was called "our own leftover answer"
    // when this line was written, and that is exactly the belief this had to stop acting on - the
    // answer at this address belongs to whoever sent the last line, which is often not us. Taken
    // away so the next reader cannot find it waiting; the epoch match in `awaitSessionInputResult`
    // is what stops it being MISREAD in the meantime.
    clearSessionInputResult(sessionKey: sessionKey)
    // IS THIS OUR OWN SESSION? The marker answers it, and only where the resolution actually USED
    // it: `adopted` is nil when the directory found the session or when `--session` named somebody
    // else, and both of those are callers standing outside the turn they are writing into.
    //
    // ASKED BEFORE THE REQUEST IS WRITTEN, because the request carries the answer: how long this
    // caller will be there decides how long its receipt is anybody's to collect
    // (`SessionInputRequest.waitSeconds`).
    let ownSession = marker.adopted(sessionKey) != nil
    let wait = ownSession ? sessionInputSelfWaitSeconds : sessionInputWaitSeconds
    let request = SessionInputRequest(epoch: Int(Date().timeIntervalSince1970 * 1000),
                                      text: intent.text, waitSeconds: Int(wait))
    do {
        try writeSessionInputRequest(request, sessionKey: sessionKey)
    } catch {
        warn("cannot write \(sessionInputFile(sessionKey: sessionKey).path): "
            + "\(error.localizedDescription)")
        return 1
    }
    if !ownSession {
        // Said before the wait rather than after it, which is the whole point: two and a half
        // minutes of nothing is indistinguishable from a command that has hung.
        warn(sessionInputWaitingLine(sessionKey: sessionKey,
                                     doing: readSessionState(pid: sessionKey)?.state,
                                     timeout: sessionInputWaitSeconds))
    }
    let answer = awaitSessionInputResult(
        sessionKey: sessionKey, epoch: request.epoch, timeout: wait,
        // Not asked of our own session: this process descends from that supervisor, so it is alive
        // by construction, and the one thing this wait can never be is abandoned for its absence.
        abandon: { ownSession ? nil : sessionInputAbandonment(sessionKey: sessionKey) })
    let result: SessionInputResult
    switch answer {
    case .answered(let answered):
        result = answered
    case .abandoned(let why):
        warn(why)
        return 4
    case .timedOut:
        // OUR OWN SESSION IS NOT A TIMEOUT. The line is queued and the turn this command is part of
        // is what it is waiting for, so leaving is how it gets typed rather than how it is lost.
        guard !ownSession else {
            print(sessionInputQueuedMessage(sessionKey: sessionKey))
            return 0
        }
        warn(sessionInputTimeoutMessage(sessionKey: sessionKey,
                                        path: sessionInputFile(sessionKey: sessionKey).path,
                                        timeout: sessionInputWaitSeconds))
        return 4
    }
    // Read, so it stops being an answer waiting for somebody.
    clearSessionInputResult(sessionKey: sessionKey)
    let message = sessionInputMessage(result, sessionKey: sessionKey)
    // The one line answering the command goes to stdout when the text landed, so a script can read
    // it; everything else is stderr, like every other failure here.
    if result.delivered { print(message) } else { warn(message) }
    return sessionInputExitCode(result)
}

let sessionSendUsage = """
usage: tally session send [<text>] [--session <pid>]

Types <text> into a supervised session's own terminal, exactly as if it had been typed there, and
presses Return. With no text it presses Return alone, which is how a prompt sitting on its default
gets answered. Typing and sending are one act: this exists to trigger what a session cannot trigger
for itself (`/clear`, `/compact`, an answer to a permission prompt), and a line left in the composer
triggers nothing. Run it inside the session it is meant for (an agent in that conversation can run it
as a tool call); --session names another one by either of its pids, the Claude Code that
`tally status --json` lists under `sessions[].pid` or the Tally supervising it.

The text is typed at the first moment the session is waiting on you, idle, or done speaking with
only its subagents still writing - so a request made mid-turn lands when that turn ends, and agents
running in the background do not hold it. Nothing is typed while the conversation itself is in a
turn, while it is not reporting what it is doing, while a restart of it is pending, or while
somebody is typing in that terminal; a request that never reaches a typeable moment within
\(Int(sessionInputTTL))s is refused and the refusal names which of those stood in its way.

Sending into ANOTHER session waits up to \(Int(sessionInputWaitSeconds))s for the answer and prints
what it is waiting on. Sending into your OWN waits \(Int(sessionInputSelfWaitSeconds))s and then
says the line is queued, because this command is part of the turn the line is waiting for: holding
it open is the one way to guarantee the line is never typed.

One send at a time per session: a second one while the first is still waiting is refused rather than
replacing it. At most \(sessionInputMaxBytes) bytes of UTF-8, since this is for a slash command or
an answer to a prompt rather than for a prompt.

Exit codes: 0 sent (or queued for this session), 3 refused (the reason is printed), 4 nobody
answered, 1 something went wrong.
"""

/// What a missing or unknown verb is told: the first line of the text above rather than a second
/// copy of it, so the one thing a namespace with one verb in it can say cannot drift from what that
/// verb documents.
let sessionUsage = String(sessionSendUsage.prefix { $0 != "\n" })

/// `tally session <verb>`: the acts a supervised session can be asked to perform on itself.
func runSession(args: [String]) -> Int32 {
    switch args.first {
    case "send":
        return runSessionSend(args: Array(args.dropFirst()))
    default:
        // Named rather than defaulted, the rule `runCompletion` states: a bare `tally session` is a
        // usage error rather than a guess, so the day a second verb arrives nothing that was written
        // down changes meaning.
        warn(sessionUsage)
        return 2
    }
}
