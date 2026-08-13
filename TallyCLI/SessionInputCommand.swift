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
// IT WAITS, unlike every other request-writing command here. `tally account` and `tally model`
// return the instant the file is on disk, because what they promise happens at the end of the turn
// and the person who typed it is inside that turn. This one is normally run by an agent that has to
// know whether the text landed before it does anything else, and the answer exists (the supervisor
// writes one) - so returning "queued" and leaving the caller to poll a file would be handing back a
// job this command is better placed to do.

/// How long to wait for the supervisor's answer.
///
/// LONGER THAN THE REQUEST'S OWN LIFE (`sessionInputTTL`, 120s) on purpose: the supervisor answers
/// every request it reads, including by refusing an expired one, so the wait has to outlast the
/// thing it is waiting for or it would time out on requests that were about to be answered. The
/// margin is a poll tick's worth of slack many times over.
let sessionInputWaitSeconds: TimeInterval = 150

/// How often to look for it. A quarter second is well inside the 2s tick that writes it, so the
/// answer is read within one interval of being published.
let sessionInputPollInterval: TimeInterval = 0.25

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

// MARK: - One request per session at a time

/// The request already waiting at this session's address, or nil when nothing there could still be
/// typed.
///
/// EXPIRED ONES DO NOT COUNT, deliberately: a request past `sessionInputTTL` will be refused by the
/// supervisor the next time it looks, and until then it is a husk. Treating a husk as an occupant
/// would take the feature away from a session for two minutes because some earlier caller was killed
/// mid-wait.
func pendingSessionInput(sessionKey: String, dir: URL = sessionInputDir, now: Date = Date())
    -> SessionInputRequest? {
    guard let waiting = readSessionInputRequest(sessionKey: sessionKey, dir: dir),
          !sessionInputExpired(epoch: waiting.epoch, now: now) else { return nil }
    return waiting
}

/// What the second caller is told. Pure, so the wording is assertable.
///
/// REFUSED RATHER THAN WRITTEN OVER, and this is the whole of why. One file addresses one session,
/// so a second request lands on top of the first: the first caller is then waiting for an answer to
/// a request that no longer exists anywhere, gets nothing until its own timeout, and is told "nobody
/// answered" for a line that was in fact thrown away by us. Meanwhile the supervisor serves the
/// second request and writes an answer stamped with ITS epoch, so nothing on either end ever
/// records that an instruction was dropped (codex review of 18b3174).
///
/// AND NOT QUEUED, which is the other obvious answer and the more expensive one. Injection is
/// performed synchronously inside a poll tick, one byte at a time (SessionInput.swift), so a queue
/// turns "one tick may spend six seconds typing" into "one tick may spend as long as the queue is",
/// or else moves the typing off the tick and brings back exactly the concurrency this feature was
/// designed without (section 10 of the design document). Two callers typing into one composer is
/// also a thing neither of them can predict the result of.
///
/// The wording has to be TELLABLE APART FROM A GATE REFUSAL by a caller reading stderr: those say
/// the session was busy or silent and mean "try again, this may work later"; this one means "your
/// text was never queued, and something else is already using this address".
func sessionInputBusyRefusal(_ waiting: SessionInputRequest, sessionKey: String,
                             now: Date = Date()) -> String {
    let expiresIn = max(0, Int(TimeInterval(waiting.epoch) / 1000 + sessionInputTTL
        - now.timeIntervalSince1970))
    return "session \(sessionKey) already has a line waiting to be typed into it, so nothing was "
        + "queued for this one: a second request at that address would replace the first, and the "
        + "caller waiting on it would be told nobody answered. Let that one be served, or wait up "
        + "to \(expiresIn)s for it to expire, then ask again"
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
func namedSession(_ named: String, dir: URL = supervisorStateDir) -> NamedSession {
    guard let pid = pid_t(named), supervisorAlive(pid) else { return .notRunning }
    guard liveSupervisorPids(dir: dir).contains(pid) else { return .notSupervised }
    // Normalised through the pid, so `--session 0123` addresses the same file `--session 123` does
    // rather than writing a request nobody will ever read.
    return .session(String(pid))
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
func sessionInputExitCode(_ result: SessionInputResult?) -> Int32 {
    guard let result else { return 4 }
    return result.delivered ? 0 : 3
}

/// Wait for the answer to this request, or nil when none arrived in time.
///
/// Matched on the EPOCH, which is the whole reason a result carries one: a husk from an earlier
/// request can still be sitting at that path (a caller killed mid-wait, a wait that timed out), and
/// reading somebody else's outcome as this one's is a fire-and-forget channel's one silent failure.
///
/// The clock and the reads are injectable so the suite can exercise the timeout without spending it.
func awaitSessionInputResult(sessionKey: String, epoch: Int, timeout: TimeInterval,
                             interval: TimeInterval = sessionInputPollInterval,
                             now: () -> Date = Date.init,
                             sleep: (TimeInterval) -> Void = { usleep(useconds_t($0 * 1_000_000)) },
                             read: (String) -> SessionInputResult? = {
                                 readSessionInputResult(sessionKey: $0)
                             }) -> SessionInputResult? {
    let deadline = now().addingTimeInterval(timeout)
    while true {
        if let result = read(sessionKey), result.epoch == epoch { return result }
        guard now() < deadline else { return nil }
        sleep(interval)
    }
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
    // ONE AT A TIME AT ONE ADDRESS: refused rather than written over the request already there
    // (`sessionInputBusyRefusal` argues both halves of that).
    //
    // ASKED BEFORE THE CLEAR BELOW, which is not an ordering detail: that answer file may be the one
    // the other caller is polling for right now, and taking it away on our way to being refused
    // would turn its delivery into a timeout. After the sweeps, so a husk left by a session that
    // has since died is not mistaken for an occupant.
    //
    // The window it does not close, said rather than implied: two commands that both read an empty
    // address before either has renamed its file still collide, and the second write still wins.
    // Closing that needs an exclusive publish (`link(2)` rather than `rename(2)`, with its own
    // retry for the expired-overwrite case), and it is not bought here because the race is two
    // invocations inside the same millisecond while the defect this fixes was two callers inside
    // the same TWO MINUTES - the TTL makes overlap the ordinary case rather than the freak one.
    if let waiting = pendingSessionInput(sessionKey: sessionKey) {
        warn(sessionInputBusyRefusal(waiting, sessionKey: sessionKey))
        return 3
    }
    // Our own leftover answer, before the request that would make a reader look for a new one:
    // matching on the epoch already stops it being MISREAD, and taking it away stops it being kept.
    clearSessionInputResult(sessionKey: sessionKey)
    let request = SessionInputRequest(epoch: Int(Date().timeIntervalSince1970 * 1000),
                                      text: intent.text)
    do {
        try writeSessionInputRequest(request, sessionKey: sessionKey)
    } catch {
        warn("cannot write \(sessionInputFile(sessionKey: sessionKey).path): "
            + "\(error.localizedDescription)")
        return 1
    }
    let result = awaitSessionInputResult(sessionKey: sessionKey, epoch: request.epoch,
                                         timeout: sessionInputWaitSeconds)
    guard let result else {
        warn("session \(sessionKey) has not answered in \(Int(sessionInputWaitSeconds))s. The "
            + "request is still at \(sessionInputFile(sessionKey: sessionKey).path); its supervisor "
            + "may be mid-restart, or running a build that does not read it yet")
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
as a tool call); --session names another one by its supervisor pid, which `tally status --json`
lists.

It waits for the answer: the text is sent at the first moment the session is waiting on you or idle,
so a request made mid-turn lands when that turn ends. Nothing is sent while the session is working,
while it is not reporting what it is doing, or while somebody is typing in that terminal; a request
that never reaches such a moment within \(Int(sessionInputTTL))s is refused and says so. One send
at a time per session: a second one while the first is still waiting is refused rather than
replacing it. At most \(sessionInputMaxBytes) bytes of UTF-8, since this is for a slash command or
an answer to a prompt rather than for a prompt.

Exit codes: 0 sent, 3 refused (the reason is printed), 4 nobody answered, 1 something went wrong.
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
