import Foundation

// ASKING FOR IT: the CLI half of `tally session type`, split from SessionInput.swift (which keeps
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

/// What `tally session type` asks for. Pure to parse, so the grammar is testable.
struct SessionTypeIntent: Equatable {
    /// The text to type. May be empty, which is legal only with `--submit`.
    var text: String
    var submit: Bool
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
/// `--` ENDS THE FLAGS, so text that begins with a dash can still be typed (`tally session type --
/// --help` types those six characters into the session). Without it such text is refused rather than
/// guessed at, because every other reading makes a flag this command does not know into content.
func sessionTypeIntent(_ args: [String]) -> SessionTypeIntent? {
    var text: String?
    var submit = false
    var session: String?
    var literal = false
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        index += 1
        if !literal {
            if word == "--" { literal = true; continue }
            if word == "--submit" { submit = true; continue }
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
    // A bare `--submit` IS a request: press Return and type nothing, which is how a prompt sitting
    // on its default gets answered. Everything else with no text at all (a lone `--session`, an
    // empty line) is a usage error rather than a guess.
    guard let text else {
        return submit ? SessionTypeIntent(text: "", submit: true, session: session) : nil
    }
    return SessionTypeIntent(text: text, submit: submit, session: session)
}

/// Why this cannot be asked for, or nil when it can. Pure, and asked BEFORE anything is written, so
/// a refused value never reaches a request file.
func sessionTypeProblem(_ intent: SessionTypeIntent) -> String? {
    let bytes = intent.text.utf8.count
    guard bytes <= sessionInputMaxBytes else {
        // Named in the unit the limit is in, because a caller looking at 60 characters of Chinese
        // has no way to guess why 200 was exceeded (SessionInputRequest.swift states why bytes).
        return "that is \(bytes) bytes of UTF-8 and the limit is \(sessionInputMaxBytes); nothing "
            + "was queued. This types short lines - a slash command, an answer to a prompt - and "
            + "anything longer belongs in the conversation itself"
    }
    guard !intent.text.isEmpty || intent.submit else {
        return "nothing to type: pass some text, or `--submit` on its own to press Return"
    }
    return nil
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
    case .injected:
        return "typed into session \(sessionKey) and left in the composer; pass --submit to send it"
            + "\(detail)"
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

/// `tally session type <text> [--submit] [--session <pid>]`: type into a supervised session's own
/// terminal, and optionally press Return.
func runSessionType(args: [String]) -> Int32 {
    guard let intent = sessionTypeIntent(args) else {
        warn(sessionTypeUsage)
        return 2
    }
    if let problem = sessionTypeProblem(intent) {
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
        guard let pid = pid_t(named), supervisorAlive(pid) else {
            warn("no supervisor is running as pid \(named). `tally status --json` lists the "
                + "sessions this machine is supervising")
            return 3
        }
        // Normalised through the pid, so `--session 0123` addresses the same file `--session 123`
        // does rather than writing a request nobody will ever read.
        sessionKey = String(pid)
    } else {
        switch marker.resolve(here: supervisorsInDirectory(FileManager.default.currentDirectoryPath))
        {
        case .session(let key):
            sessionKey = key
        case .none:
            warn("this session is not supervised, so nothing here can type into it: it was launched "
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
        warn("this session's supervisor predates `tally session type` and would never read the "
            + "request, so nothing was queued. Restart this session once (exit, then launch again "
            + "with `tally claude`) and it can be typed into from then on.")
        return 3
    }
    // Both husk sweeps, at the only moment this directory grows. The requests are swept by the same
    // loop every per-session channel uses; the answers need their own, because that loop reads a
    // file name as a pid outright (SessionInputRequest.swift).
    sweepDeadSessionRequests(dir: sessionInputDir)
    sweepDeadSessionInputResults(dir: sessionInputDir)
    // Our own leftover answer, before the request that would make a reader look for a new one:
    // matching on the epoch already stops it being MISREAD, and taking it away stops it being kept.
    clearSessionInputResult(sessionKey: sessionKey)
    let request = SessionInputRequest(epoch: Int(Date().timeIntervalSince1970 * 1000),
                                      text: intent.text, submit: intent.submit)
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

let sessionTypeUsage = """
usage: tally session type <text> [--submit] [--session <pid>]

Types <text> into a supervised session's own terminal, exactly as if it had been typed there, and
with --submit presses Return afterwards. Run inside the session it is meant for (an agent in that
conversation can run it as a tool call); --session names another one by its supervisor pid, which
`tally status --json` lists.

It waits for the answer: the text is typed at the first moment the session is waiting on you or
idle, so a request made mid-turn lands when that turn ends. Nothing is typed while the session is
working, while it is not reporting what it is doing, or while somebody is typing in that terminal;
a request that never reaches such a moment within \(Int(sessionInputTTL))s is refused and says so.
At most \(sessionInputMaxBytes) bytes of UTF-8: this is for a slash command or an answer to a prompt,
not for a prompt.

Exit codes: 0 typed, 3 refused (the reason is printed), 4 nobody answered, 1 something went wrong.
"""

/// What a missing or unknown verb is told: the first line of the text above rather than a second
/// copy of it, so the one thing a namespace with one verb in it can say cannot drift from what that
/// verb documents.
let sessionUsage = String(sessionTypeUsage.prefix { $0 != "\n" })

/// `tally session <verb>`: the acts a supervised session can be asked to perform on itself.
func runSession(args: [String]) -> Int32 {
    switch args.first {
    case "type":
        return runSessionType(args: Array(args.dropFirst()))
    default:
        // Named rather than defaulted, the rule `runCompletion` states: a bare `tally session` is a
        // usage error rather than a guess, so the day a second verb arrives nothing that was written
        // down changes meaning.
        warn(sessionUsage)
        return 2
    }
}
