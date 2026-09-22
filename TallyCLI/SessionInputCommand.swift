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
// IT QUEUES RATHER THAN WAITS, which is the thing to understand before changing anything here.
// `tally account` and `tally model` return the instant the file is on disk; this one stays a few
// seconds, because a session that is already idle is served on the next tick and that answer is
// worth catching - and then it says the line is queued and leaves. Waiting for delivery is a
// deadlock when the target is the session the command runs in (the command is a tool call, an
// unfinished tool call is an open turn, and a session mid-turn is precisely what the supervisor
// will not type into), and it is a lie waiting to happen when it is not: a request may sit queued
// behind a turn for `sessionInputQueuedLife`, so a caller that gave up before then would report
// "nobody answered" about a line that is pending and healthy. SessionSendWait.swift carries the
// measurements and every wording.

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
    /// A directory whose one supervised session is meant, resolved to a pid before anything is
    /// written (SessionProjectAddress.swift, which states why a checkout rather than a repository).
    var project: String?
    /// Which provider's session in that directory, when it holds more than one kind.
    var provider: String?
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
    var address = SessionSendAddress()
    var literal = false
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        index += 1
        if !literal {
            if word == "--" { literal = true; continue }
            // The three flags that say WHICH session, and the rules over the set of them, in the
            // one type that owns them (SessionSendAddress). nil is "not one of mine".
            if let taken = address.take(word, args, &index) {
                guard taken else { return nil }
                continue
            }
            guard !word.hasPrefix("-") else { return nil }
        }
        guard text == nil else { return nil }
        text = word
    }
    guard address.namesOneSession else { return nil }
    return SessionSendIntent(text: text ?? "", session: address.session,
                             project: address.project, provider: address.provider)
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

// MARK: - Which session `--session` may name

/// What a pid on the command line turns out to be.
enum NamedSession: Equatable {
    /// A supervisor of this machine's, addressed by its pid.
    case session(String)
    /// A live monitored Codex supervisor that cannot prove a direct terminal target. It is named
    /// separately so a legacy registration gets a restart-required refusal rather than falling
    /// through to the generic "not supervised" message.
    case monitoringOnly(String)
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
    let key = String(pid)
    if SessionMonitoring.isMarked(pid: key, dir: dir),
       !SessionMonitoring.supportsDirectSend(pid: key, dir: dir) {
        return .monitoringOnly(key)
    }
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

/// `tally session send [<text>] [--session <pid> | --project <dir> [--provider claude|codex]]`:
/// type into a supervised session's own terminal and press Return.
func runSessionSend(args: [String]) -> Int32 {
    guard let intent = sessionSendIntent(args) else {
        warn(sessionSendUsage)
        return 2
    }
    return runSessionSend(intent)
}

/// One request, sent. THE ONE PATH BOTH SPELLINGS TAKE, which is the whole of what makes `tally
/// send <provider>` a spelling rather than a second command: by here the grammar has already said
/// what was asked for, and nothing below can tell which of the two said it
/// (SessionSendVerb.swift).
///
/// `requiredProvider` is the one thing the top-level spelling carries that the other cannot: the
/// kind of session it named. It is checked at the far end of the addressing, where there is a
/// session key to check it against.
func runSessionSend(_ intent: SessionSendIntent, requiredProvider: String? = nil) -> Int32 {
    var intent = intent
    // A DIRECTORY BECOMES A PID HERE, and nowhere after this line is there anything left to tell a
    // `--project` send from a `--session` one: the roster is asked only where a directory was named
    // (it costs a scan), and a refusal to name one session is a refusal to send
    // (SessionProjectAddress.swift carries every wording and the reason ambiguity is not resolved).
    if intent.project != nil {
        switch resolveSessionProject(intent, sessions: liveSessionProjectCandidates()) {
        case .addressed(let addressed):
            intent = addressed
        case .refused(let why):
            warn(why)
            return 3
        }
    }
    // NO INTENT, which is this command's whole promise: the bytes named are the bytes typed, and
    // nothing the supervisor finds in them earns it a decision (SessionClear.swift argues why the
    // verb that DOES decide is a different verb).
    return queueSessionLine(intent, requestIntent: nil, requiredProvider: requiredProvider)
}

/// Queue one line for one session and stay for the grace, shared by both verbs in this namespace.
///
/// `requestIntent` is the only difference between them on this path, and it travels on the request
/// rather than changing anything here: what it authorises happens at the far end, at the instant the
/// line lands (`sessionClearMovesAccounts`).
///
/// `requiredProvider` is what `tally send <claude|codex>` named, and nil from every other caller:
/// the two verbs in the `session` namespace have nothing to compare a provider against, and a
/// check with nothing to check is a filter that does nothing.
func queueSessionLine(_ intent: SessionSendIntent, requestIntent: String?,
                      requiredProvider: String? = nil) -> Int32 {
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
        case .monitoringOnly(let key):
            let refusal = requestIntent == sessionClearIntent
                ? sessionControlRefusal(pid: key, dir: supervisorStateDir)
                : sessionSendRefusal(pid: key, dir: supervisorStateDir)
            warn(refusal
                 ?? "This Codex session cannot accept direct input. Nothing was queued.")
            return 3
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
    // WHICH KIND OF SESSION THIS TURNED OUT TO BE. Asked HERE and nowhere earlier, because here is
    // where all three ways of naming one have become the same key: a pid, a directory and this
    // session are checked by one line rather than by three that could disagree. Asked before
    // anything is written, so a refusal is a send that never happened. The directory route has
    // already been filtered by provider on its way through the roster
    // (SessionProjectAddress.swift), and this asks the same question of the session it arrived at.
    if let requiredProvider,
       let mismatch = sessionProviderMismatch(
           wanted: requiredProvider,
           found: sessionProviderName(sessionKey: sessionKey, dir: supervisorStateDir),
           sessionKey: sessionKey) {
        warn(mismatch)
        return 3
    }
    // Whether anything will read the request, through the same answer `tally account` and `tally
    // model` get. Judged only where the session named ITSELF (`adopted` returns nil when the
    // directory answered, or when --session named somebody else): the version stamped in this
    // environment describes this session's supervisor and says nothing about another one's.
    let refusal = requestIntent == nil
        ? sessionSendRefusal(pid: sessionKey, dir: supervisorStateDir)
        : sessionControlRefusal(pid: sessionKey, dir: supervisorStateDir)
    if let refusal {
        warn(refusal)
        return 3
    }
    if SessionMonitoring.isMarked(pid: sessionKey, dir: supervisorStateDir),
       let problem = codexSessionInputProblem(intent.text) {
        warn(problem)
        return 3
    }
    let honourability = liveRequestHonourability(marker: marker.adopted(sessionKey))
    if honourability == .tooOld {
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
    // the same QUARTER HOUR - a queued request's life makes overlap the ordinary case rather than
    // the freak one.
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
    // else, and both of those are callers standing outside the turn they are writing into. It no
    // longer decides how long to wait (nobody waits long any more, `sessionInputGraceSeconds` says
    // why); what is left to it is the one question that really does differ - whether the supervisor
    // being waited on is this process's own ancestor, and so alive by construction.
    let ownSession = marker.adopted(sessionKey) != nil
    // ASKED BEFORE THE REQUEST IS WRITTEN, because the request carries the answer: how long this
    // caller will be there decides how long its receipt is anybody's to collect
    // (`SessionInputRequest.waitSeconds`).
    let wait = sessionInputGraceSeconds
    let request = SessionInputRequest(epoch: Int(Date().timeIntervalSince1970 * 1000),
                                      text: intent.text, waitSeconds: Int(wait),
                                      intent: requestIntent)
    do {
        try writeSessionInputRequest(request, sessionKey: sessionKey)
    } catch {
        warn("cannot write \(sessionInputFile(sessionKey: sessionKey).path): "
            + "\(error.localizedDescription)")
        return 1
    }
    // WHICH BUILD IS ABOUT TO READ IT, said only once something was actually queued: a version
    // skew changes what this line is served on, and the caller is told `queued` either way
    // (`sessionInputSkewNote` carries the whole argument).
    if let skew = sessionInputSkewNote(honourability) { warn(skew) }
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
        // THE ORDINARY ENDING RATHER THAN A FAILURE, and the one thing that changed here on
        // 2026-08-18. The line is queued, the session's own turn is what it is waiting for, and
        // leaving is how it gets typed rather than how it is lost - for a caller inside that
        // session because staying holds the turn open, and for one outside it because a request may
        // legitimately sit queued for a quarter of an hour and "nobody answered" would be a lie
        // about a line that is very much alive.
        print(sessionInputQueuedMessage(sessionKey: sessionKey,
                                        doing: readSessionState(pid: sessionKey)?.state,
                                        mayMove: requestIntent == sessionClearIntent))
        return 0
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
usage: tally session send [<text>] [--session <pid> | --project <dir-or-name> [--provider claude|codex]]

Types <text> into a supervised session's own terminal and presses Return. Claude supports slash
commands and permission answers. With no text, Claude presses Return alone to answer the default
choice in a prompt. Typing and sending are one act: this exists to trigger what a session cannot trigger
for itself (`/clear`, `/compact`, an answer to a permission prompt), and a line left in the composer
triggers nothing. Run it inside the session it is meant for (an agent in that conversation can run it
as a tool call); --session names another one by either of its pids, the provider process that
`tally status --json` lists under `sessions[].pid` or the Tally supervising it.

--project <dir-or-name> names it by the directory it was launched in instead, matched against the same
`sessions[].directory` that JSON publishes: the exact checkout, so a parallel line of a repository
is addressed by its own path rather than by the trunk's. --provider claude|codex narrows that to
one kind of session. A directory that has more than one session is refused with the candidates
listed, naming the pid to pass to --session; a directory with none is refused too, and nothing is
queued either way. Whichever flag found the pid, everything after it is identical.

--project also takes a bare PROJECT NAME: a word with no slash, no `~` and no leading dot is
matched against the last component of every directory on the roster, exactly and with its case
(no prefix or fuzzy matching). Which reading applies is decided on the spelling alone and never on
what is on disk, so one command line means one thing wherever it is run. A name two different
directories answer to is refused with both full paths listed, and so is a name nothing was launched
under; pass a full path to name a checkout precisely.

`tally send claude|codex [<text>] [--project <dir-or-name> | --session <pid>]` is the same send
spelled provider-first, and the one thing it adds: the session it reaches is checked against the
provider named, and one of the other kind is refused rather than typed into. This spelling stays,
and everything below is true of both.

Updated supervised Codex sessions support nonempty direct prompts when status lists `send`.
Codex requires trusted native lifecycle reporting and a completed turn before advertising this
capability. Monitoring-only sessions must restart with the current `tally codex`. Account, model,
clear and reload controls remain Claude-only. Use the native Codex UI for slash commands, shell
mode and empty Return.
Codex waits while working, asking permission, unknown, or while a human is typing. Once quiet,
unexplained terminal input causes an explicit refusal because the composer may contain a draft;
submit an actual prompt in that session, wait for its turn to finish, then retry. Codex reports
sent only after a matching native prompt receipt; an unconfirmed terminal write must be inspected before retrying. Custom submit keys may
prevent confirmation. No frontmost-window or process-global keyboard fallback is used.

For Claude, text is typed when the session is waiting on you, idle, or done speaking, so a
request made mid-turn lands when that turn ends. Agents it dispatched do not hold it, whatever they
are doing: a `/clear` that lands while they are running ends them, and the log records how many.
Nothing is typed while the conversation itself is in a turn, while it is not reporting what it is
doing, while a restart of it is pending, or while somebody is typing in that terminal; a request
that never reaches a typeable moment within \(Int(sessionInputQueuedLife))s is refused and the
refusal names which of those stood in its way.

QUEUEING IS SUCCESS. Every caller waits \(Int(sessionInputGraceSeconds))s, which is long enough to
catch a session that is already idle, and then says the line is queued and exits 0. It does not wait
for delivery: a line behind a turn is doing what it was asked to, and a caller inside that session
that stayed would hold open the very turn it is waiting for. What became of it is recorded in
~/.tally/logs/input.log, including how many running subagents a `/clear` ended when it landed.

For a hand-over clear, use `tally session clear`: same queueing, and it may reopen the session on a
healthier account instead of typing (nothing here decides anything about accounts).

One send at a time per session: a second one while the first is still queued is refused rather than
replacing it. At most \(sessionInputMaxBytes) bytes of UTF-8, for short direct input.

Exit codes: 0 confirmed or queued; 3 refused or unconfirmed (inspect the printed reason before
retrying); 4 that session has exited; 1 something went wrong.
"""

/// What a missing or unknown verb is told: the first line of each verb's own text rather than a
/// third copy of them, so what the namespace says cannot drift from what its verbs document.
let sessionUsage = [sessionSendUsage, sessionClearUsage]
    .map { String($0.prefix { $0 != "\n" }) }
    .joined(separator: "\n       ")

/// `tally session <verb>`: the acts a supervised session can be asked to perform on itself.
func runSession(args: [String]) -> Int32 {
    switch args.first {
    case "send":
        return runSessionSend(args: Array(args.dropFirst()))
    case "clear":
        return runSessionClear(args: Array(args.dropFirst()))
    default:
        // Named rather than defaulted, the rule `runCompletion` states: a bare `tally session` is a
        // usage error rather than a guess, so the day a second verb arrives nothing that was written
        // down changes meaning.
        warn(sessionUsage)
        return 2
    }
}
