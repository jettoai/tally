import Foundation

// `tally session clear`: the verb that closes a window, and the one decision it earns that
// `tally session send` deliberately does not (SessionClear.swift).
//
// Split from sessioninputchecks.swift and sessionsendchecks.swift on the seam the source has: those
// two are the channel and the plain command, this is the second verb and the landing decision it
// authorises. Pure or pointed at a temp directory like both of them: nothing here touches
// `~/.tally/input`, and nothing in this file can type into a live session.
//
// WHAT IS NOT COVERED HERE, said out loud: the relaunch itself. What a decided move becomes is a
// `RelaunchPlan` (asserted below) and what the loop then does with it is `performHandoff`, which
// kills a child and spawns one - so the wiring between them is read off the source, the technique
// every station in this suite family uses for a `while true` inside a process that spawns children.

/// Two accounts that differ in the only way this file cares about: which one a move would name.
private func clearAccount(_ id: String, _ label: String) -> Snapshot.Account {
    Snapshot.Account(id: id, provider: "claude", label: label, launchHome: "/tmp/\(id)",
                     sessionRemaining: 80, weeklyRemaining: 80, modelRemaining: 80,
                     sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                     modelWindowName: nil, resetCreditsAvailable: nil, isStale: false, error: nil)
}

func runSessionClearChecks() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-sessionclear-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("input.log")
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)
    func epoch(_ offset: TimeInterval) -> Int {
        Int((t0.addingTimeInterval(offset)).timeIntervalSince1970 * 1000)
    }
    let healthy = clearAccount("B", "Claude 2")
    /// The request the verb writes, and the same request as a plain send would have written it.
    func clearRequest(_ offset: TimeInterval = 0, text: String = windowClearCommand,
                      intent: String? = sessionClearIntent) -> SessionInputRequest {
        SessionInputRequest(epoch: epoch(offset), text: text, waitSeconds: 6, intent: intent)
    }

    // MARK: - The grammar

    // NO TEXT ARGUMENT, which is the grammar saying what the verb is: a word here is a caller who
    // meant `session send`, and swallowing it would type `/clear` while they watched for their line.
    check("bare, it means the session it runs in", sessionClearRequest([]) == SessionClearRequest())
    check("…and --session names another one",
          sessionClearRequest(["--session", "412"]) == SessionClearRequest(session: "412"))
    check("a word is a usage error rather than text nobody will send",
          sessionClearRequest(["hello"]) == nil
              && sessionClearRequest(["--session", "412", "hello"]) == nil
              && sessionClearRequest(["--", "/clear"]) == nil)
    check("…as is a --session with no value, twice, or a flag this verb does not know",
          sessionClearRequest(["--session"]) == nil
              && sessionClearRequest(["--session", "1", "--session", "2"]) == nil
              && sessionClearRequest(["--force"]) == nil)
    // The line it queues is the one the window repick recognises, named once for all three readers.
    check("the line it sends is the one that closes a window",
          isWindowClearCommand(windowClearCommand)
              && sessionInputClearsContext(windowClearCommand))

    // MARK: - Who may move an account

    // THE PRODUCT BOUNDARY, asserted rather than described: `tally session send` is a dumb pipe, so
    // the same six characters through it decide nothing about accounts. This is the check that
    // fails if the intent is ever inferred from the text.
    check("a plain send that types /clear may not move an account",
          !sessionClearMovesAccounts(request: clearRequest(intent: nil), state: .idle))
    check("…while the clear verb's own request may",
          sessionClearMovesAccounts(request: clearRequest(), state: .idle))
    // The field is checked against the text as well, because this directory is writable by anything
    // running as this user: a forged request claiming the intent with some other text would
    // otherwise buy a relaunch that no `/clear` was ever queued for.
    check("…and an intent claimed over text that closes nothing does not",
          !sessionClearMovesAccounts(request: clearRequest(text: "hello"), state: .idle)
              && !sessionClearMovesAccounts(request: clearRequest(text: "/compact"), state: .idle))
    // A SESSION WAITING ON A PERSON IS NEVER RESTARTED AWAY. The typing path is safe there because
    // a line a prompt eats moves nothing and the repick's id check catches it; a path that never
    // types has no such backstop, so the prompt is the gate.
    check("a session sitting on a prompt is cleared by typing, never by relaunching",
          !sessionClearMovesAccounts(request: clearRequest(), state: .blocked))
    check("…while the states that are not somebody's question may move",
          sessionClearMovesAccounts(request: clearRequest(), state: .working)
              && sessionClearMovesAccounts(request: clearRequest(), state: .idle))

    // MARK: - The landing's three endings

    /// What one landing did: its answer, what reached the terminal, and whether the account
    /// question was asked at all. The third is the one no outcome can show, and two checks below
    /// are about exactly that.
    var typedLines: [String] = []
    var boundaryAsked = 0
    func land(_ request: SessionInputRequest, state: SupervisedState = .idle, agents: Int? = nil,
              boundary: Snapshot.Account? = nil) -> SessionInputLanding {
        typedLines = []
        boundaryAsked = 0
        return landSessionInput(request, sessionKey: "9401", state: state, agents: { _ in agents },
                                boundary: { boundaryAsked += 1; return boundary },
                                inject: { typedLines.append($0); return .done })
    }
    check("a healthy account is cleared by typing, exactly as before",
          land(clearRequest()) == .typed(.done, agents: nil)
              && typedLines == [windowClearCommand])
    check("a better account is reopened on instead, and nothing is typed",
          land(clearRequest(), agents: 2, boundary: healthy) == .moved(healthy, agents: 2)
              && typedLines.isEmpty)
    // THE GATE IS ASKED BEFORE THE QUESTION IS, which is what makes `blocked` a rule rather than a
    // hope: a landing that asked first and refused afterwards would still have taken the account's
    // reading, and a later refactor moving the two apart would not be caught by an outcome check.
    check("a blocked session types even when a better account exists, without asking for one",
          land(clearRequest(), state: .blocked, boundary: healthy) == .typed(.done, agents: nil)
              && typedLines == [windowClearCommand] && boundaryAsked == 0)
    // And a plain send is not asked either, for the same reason one file over: the authority is the
    // verb's, so a send never even reaches the account reading.
    check("…and neither is a plain send, whatever it types",
          land(clearRequest(intent: nil), boundary: healthy) == .typed(.done, agents: nil)
              && boundaryAsked == 0)
    // The roster is read for BOTH endings, because both of them end the agents: one by clearing the
    // context, the other by killing the child they run inside.
    check("a move reports the agents it took with it, on the same terms typing does",
          land(clearRequest(), agents: 3, boundary: healthy).agents == 3
              && land(clearRequest(), agents: 0, boundary: healthy).agents == nil)

    // MARK: - Through the tick

    /// One tick against its own session key, with everything injected.
    func tick(_ request: SessionInputRequest, key: String, state: SupervisedState = .idle,
              agents: Int? = nil, boundary: Snapshot.Account? = nil,
              at offset: TimeInterval = 1) -> (action: SessionInputAction, typed: [String]) {
        var input = SessionInputState(sessionKey: key, servedEpoch: 0, dir: dir)
        try? writeSessionInputRequest(request, sessionKey: key, dir: dir)
        var typed: [String] = []
        let action = applySessionInput(&input, session: state, quiet: .quiet,
                                       turnEnded: { false }, keyboardIdle: true,
                                       relaunchPlanned: false, dir: dir, log: log,
                                       now: t0.addingTimeInterval(offset),
                                       agents: { _ in agents },
                                       clearBoundary: { boundary }) { text in
            typed.append(text)
            return .done
        }
        return (action, typed)
    }
    let moved = tick(clearRequest(), key: "9410", agents: 2, boundary: healthy)
    check("the tick that moves a session types nothing and hands the account up",
          moved.typed.isEmpty && moved.action.typed == nil && moved.action.moveTo == healthy)
    // THE ARM IS FED `typed`, so a move arms nothing: the relaunch IS the move, and a second mover
    // waiting behind it would move the session again once the new child reported its own id.
    var repick = WindowRepickState()
    repick.arm(typed: moved.action.typed, transcript: "abc")
    check("…so the window repick is not armed behind it",
          windowRepickReadiness(repick, transcript: "def") == .idle)
    check("…and a tick that did nothing hands back nothing, which is what every other tick is",
          SessionInputAction() == SessionInputAction(typed: nil, moveTo: nil))
    let receipt = readSessionInputResult(sessionKey: "9410", dir: dir)
    check("the receipt says the window was closed by moving, and names the account and the cost",
          receipt?.outcome == "moved-account"
              && receipt?.detail == "reopened on Claude 2 instead of typing, killed 2 live agents")
    check("…and it reads as delivered, because what was asked for is what happened",
          receipt.map { $0.delivered && sessionInputExitCode($0) == 0 } == true)
    check("…and the caller's wording says what happened rather than claiming a line was typed",
          sessionInputMessage(receipt!, sessionKey: "9410")
              .contains("window closed by moving session 9410")
              && !sessionInputMessage(receipt!, sessionKey: "9410").contains("sent to session"))
    let written = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    check("…and the log carries both the outcome and the agents that went with the child",
          written.contains("pid=9410 input=moved-account")
              && written.contains("pid=9410 input=agents-killed count=2"))
    check("…and the request is consumed like any other, so no tick serves it twice",
          readSessionInputRequest(sessionKey: "9410", dir: dir) == nil)

    // THE SAME EVENT A SECOND TIME, WITH A DIFFERENT ANSWER BEHIND IT: the account question is
    // asked per landing rather than remembered, so a second clear on a session whose account has
    // since become healthy types where the first one moved.
    let second = tick(clearRequest(2), key: "9410", agents: nil, boundary: nil, at: 3)
    check("a second clear on the same session asks again rather than repeating the first answer",
          second.typed == [windowClearCommand] && second.action.moveTo == nil
              && second.action.typed == windowClearCommand
              && readSessionInputResult(sessionKey: "9410", dir: dir)?.outcome == "submitted")

    // A SUPERVISOR TOO OLD TO KNOW THE FIELD, which is the shape the wire contract promises: the
    // request decodes without it and reads as a plain send, so the line is typed and the window
    // closes the way it did before this verb existed.
    let legacy = Data("{\"epoch\":1,\"text\":\"/clear\",\"waitSeconds\":6}".utf8)
    check("a request from a build without the field decodes, and claims no authority",
          (parseSessionInput(legacy) as SessionInputRequest?)?.intent == nil
              && !sessionClearMovesAccounts(
                  request: parseSessionInput(legacy) as SessionInputRequest? ?? clearRequest(),
                  state: .idle))
    check("…and the field round-trips where both ends know it",
          sessionInputData(clearRequest()).flatMap {
              parseSessionInput($0) as SessionInputRequest?
          }?.intent == sessionClearIntent)

    // MARK: - What a decided move becomes

    let current = clearAccount("A", "Claude 1")
    let plan = clearBoundaryPlan(healthy, from: current, primaryModel: nil)
    check("a move becomes a relaunch onto that account, tagged for the audit log",
          plan?.target == healthy && plan?.reason == "clear-boundary"
              && plan?.reason == clearBoundaryReason)
    // FRESH, which is the whole difference between this relaunch and every other one: what was
    // asked for is an empty window, and a relaunch that resumed the transcript would carry the
    // context onto the new account instead of dropping it.
    check("…and a FRESH one, because the request that earned it was a clear",
          plan?.fresh == true && plan?.countsFuse == true)
    check("…while a plan nobody decided is no plan at all",
          clearBoundaryPlan(nil, from: current, primaryModel: nil) == nil)
    // The default is the safe one for every other mover: a handoff, a reload and a pin switch all
    // exist to carry the conversation across.
    check("no other relaunch is fresh by default",
          RelaunchPlan(target: healthy, reason: "cap", countsFuse: true).fresh == false)
    // And what `fresh` means at the args, which is where it takes effect: nothing resumed, nothing
    // continued, so the child comes up in a conversation of its own.
    check("a fresh relaunch's args carry no conversation",
          relaunchArgs(["--resume", "abc", "--model", "opus"], sessionID: nil, sameAccount: false)
              == ["--model", "opus"]
              && relaunchArgs(["--continue"], sessionID: nil, sameAccount: false) == [])

    // MARK: - The wiring no value can be asked about

    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the clear checks", !loop.isEmpty)
    // THE DECISION IS THE REPICK'S OWN, asked with this session's real gates rather than with a
    // second threshold invented here: same function, same account, same fuse, same quarantine.
    if let start = loop.range(of: "let action = applySessionInput("),
       let end = loop.range(of: "windowRepick.arm(typed: action.typed,",
                            range: start.upperBound ..< loop.endIndex) {
        let call = String(loop[start.upperBound ..< end.lowerBound])
        check("the boundary question is the window repick's own decision, not a new one",
              call.contains("clearBoundary: {") && call.contains("windowRepickMove(provider:")
                  && call.contains("fuseAllows: fuse.allows()")
                  && call.contains("mode: policy.mode"))
    } else {
        check("the boundary question is the window repick's own decision, not a new one", false)
    }
    // AND THE TICK'S OWN ANSWER MOVES WITH THE PLAN. `replacingChild` is taken before the landing
    // decides anything, so a plan set after it and left unannounced is read by the execution block
    // as one an unresolved fork stood down: it restores, logs a hold that is not there and
    // `continue`s - after the caller has already been told its window was moved. It also feeds the
    // knock beside it, which must not type into a child that is about to be SIGTERMed.
    if let start = loop.range(of: "if let moved = clearBoundaryPlan(action.moveTo,"),
       let end = loop.range(of: "applyQuotaKnock(", range: start.upperBound ..< loop.endIndex) {
        let block = String(loop[start.lowerBound ..< end.lowerBound])
        check("…and what it decides becomes this tick's plan, and this tick's answer about it",
              block.contains("plan = moved") && block.contains("replacingChild = true"))
        check("…which the knock beside it therefore sees before it considers speaking",
              loop.contains("var replacingChild = relaunchIsHappening("))
    } else {
        check("…and what it decides becomes this tick's plan, and this tick's answer about it",
              false)
        check("…which the knock beside it therefore sees before it considers speaking", false)
    }
    // THE FRESHNESS REACHES THE HANDOFF, and both halves of it: nothing is copied to the target
    // account and nothing is resumed. Read off `performHandoff`, because a plan that carried
    // `fresh` to a handoff that ignored it would resume the conversation on the new account -
    // silently delivering the opposite of the clear that was asked for.
    if let start = loop.range(of: "func performHandoff("),
       let end = loop.range(of: "\n            handoff = true", range: start.upperBound ..< loop.endIndex) {
        let body = String(loop[start.upperBound ..< end.lowerBound])
        check("a fresh handoff copies nothing to the target and resumes nothing",
              body.contains("let carrying = fresh ? nil : sessionFile")
                  && body.contains("shareTranscript(carrying,")
                  && body.contains("sessionID: carrying?.deletingPathExtension().lastPathComponent"))
        // …while the AUDIT line still names the conversation that ended here, which is a different
        // question from what the new child resumes: "nothing was carried" is the instruction, and
        // "this is what was left behind" is what somebody reading handoff.log needs.
        check("…while the handoff log still names the conversation that ended",
              body.contains("logHandoff(sessionID: sessionFile?"))
        // …and it is not read as a same-account relaunch, which would re-add a `--continue` and
        // pull up the newest conversation on the target: the same context by another route.
        check("…and never re-adds a continue flag",
              body.contains("sameAccount: sameAccount && !fresh"))
    } else {
        check("a fresh handoff copies nothing to the target and resumes nothing", false)
        check("…and never re-adds a continue flag", false)
    }
    check("the plan carries that instruction to it",
          loop.contains("fresh: plan.fresh"))

    // MARK: - What the caller reads while it waits

    let queued = sessionInputQueuedMessage(sessionKey: "9410", doing: "working", mayMove: true)
    check("the clear's queued line names the second ending it may take",
          queued.contains("reopened on a healthier one") && queued.contains("9410"))
    check("…and a plain send's does not, because its command cannot take it",
          !sessionInputQueuedMessage(sessionKey: "9410", doing: "working").contains("reopened on"))
    // The command shares the send's whole order of business rather than copying it, which is what
    // keeps one address per session true across two verbs.
    let command = (try? String(contentsOfFile: "TallyCLI/SessionInputCommand.swift",
                               encoding: .utf8)) ?? ""
    check("both verbs queue through one path, so the address rules cannot differ",
          command.contains("func queueSessionLine(")
              && command.contains("return queueSessionLine(intent, requestIntent: nil)")
              && command.contains("case \"clear\":"))
    let clear = (try? String(contentsOfFile: "TallyCLI/SessionClear.swift", encoding: .utf8)) ?? ""
    check("…and the clear verb is the only writer of the intent field",
          clear.contains("requestIntent: sessionClearIntent")
              && !command.contains("requestIntent: sessionClearIntent"))

    try? FileManager.default.removeItem(at: dir)
}
