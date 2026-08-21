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
          !sessionClearMovesAccounts(request: clearRequest(intent: nil), state: .idle,
                                     draft: .none))
    check("…while the clear verb's own request may",
          sessionClearMovesAccounts(request: clearRequest(), state: .idle, draft: .none))
    // The field is checked against the text as well, because this directory is writable by anything
    // running as this user: a forged request claiming the intent with some other text would
    // otherwise buy a relaunch that no `/clear` was ever queued for.
    check("…and an intent claimed over text that closes nothing does not",
          !sessionClearMovesAccounts(request: clearRequest(text: "hello"), state: .idle,
                                     draft: .none)
              && !sessionClearMovesAccounts(request: clearRequest(text: "/compact"), state: .idle,
                                            draft: .none))
    // A SESSION WAITING ON A PERSON IS NEVER RESTARTED AWAY. The typing path is safe there because
    // a line a prompt eats moves nothing and the repick's id check catches it; a path that never
    // types has no such backstop, so the prompt is the gate.
    check("a session sitting on a prompt is cleared by typing, never by relaunching",
          !sessionClearMovesAccounts(request: clearRequest(), state: .blocked, draft: .none))
    check("…while the states that are not somebody's question may move",
          sessionClearMovesAccounts(request: clearRequest(), state: .working, draft: .none)
              && sessionClearMovesAccounts(request: clearRequest(), state: .idle, draft: .none))
    // AND NEITHER IS A SESSION THAT MAY BE HOLDING A HALF-WRITTEN PROMPT (2026-08-19). The typing
    // path can save a draft - it stashes the composer into the kill buffer and puts it back
    // afterwards - and this path structurally cannot, because the kill buffer lives in the child
    // this ending SIGTERMs. So the account question loses to the draft, which is the asymmetry: the
    // account is asked again every time this window closes, the draft is gone for good.
    check("a session that may hold an unsent draft is cleared by typing, not moved away from it",
          !sessionClearMovesAccounts(request: clearRequest(), state: .idle,
                                     draft: sessionInputDraftGuard(state: .idle, suspected: true)))
    check("…while the same session with nothing suspected still moves",
          sessionClearMovesAccounts(request: clearRequest(), state: .idle,
                                    draft: sessionInputDraftGuard(state: .idle, suspected: false)))

    // MARK: - The landing's three endings

    /// What one landing did: its answer, what reached the terminal, and whether the account
    /// question was asked at all. The third is the one no outcome can show, and two checks below
    /// are about exactly that.
    var typedLines: [String] = []
    var boundaryAsked = 0
    func land(_ request: SessionInputRequest, state: SupervisedState = .idle, agents: Int? = nil,
              boundary: Snapshot.Account? = nil,
              draft: SessionInputDraftGuard = .none) -> SessionInputLanding {
        typedLines = []
        boundaryAsked = 0
        return landSessionInput(request, sessionKey: "9401", state: state, draft: draft,
                                agents: { _ in agents },
                                boundary: { boundaryAsked += 1; return boundary },
                                inject: { text, _ in typedLines.append(text); return .done })
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
    // AND THE DRAFT SENDS IT BACK DOWN THE TYPING PATH, through the landing rather than only through
    // the rule next door: an account waiting to be moved to is exactly the setting in which this
    // could be got wrong, and the outcome (`typed`) is the only thing that says which ending ran.
    check("a landing that suspects a draft types instead of moving, however good the account is",
          land(clearRequest(), boundary: healthy,
               draft: sessionInputDraftGuard(state: .idle, suspected: true))
              == .typed(.done, agents: nil)
              && typedLines == [windowClearCommand])

    // MARK: - Through the tick

    /// One tick against its own session key, with everything injected.
    func tick(_ request: SessionInputRequest, key: String, state: SupervisedState = .idle,
              agents: Int? = nil, boundary: Snapshot.Account? = nil, draftSuspected: Bool = false,
              at offset: TimeInterval = 1) -> (action: SessionInputAction, typed: [String]) {
        var input = SessionInputState(sessionKey: key, servedEpoch: 0, dir: dir)
        try? writeSessionInputRequest(request, sessionKey: key, dir: dir)
        var typed: [String] = []
        let action = applySessionInput(&input, session: state, quiet: .quiet,
                                       turnEnded: { false }, keyboardIdle: true,
                                       relaunchPlanned: false, draftSuspected: draftSuspected,
                                       dir: dir, log: log,
                                       now: t0.addingTimeInterval(offset),
                                       agents: { _ in agents },
                                       clearBoundary: { boundary }) { text, _ in
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
    repick.apply(moved.action.repick, transcript: "abc")
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

    // …AND THE DRAFT READING REACHES THE LANDING THROUGH THE TICK, which is the wiring that could be
    // forgotten without any check above noticing: same request, same healthy account, one reading
    // apart. The move is declined and the line is typed, which is the ending that can put the draft
    // back (SessionInputDraft.swift).
    let drafting = tick(clearRequest(4), key: "9411", boundary: healthy, draftSuspected: true,
                        at: 5)
    check("a tick whose session may hold a draft types the clear rather than moving the session",
          drafting.typed == [windowClearCommand] && drafting.action.moveTo == nil
              && drafting.action.typed == windowClearCommand)

    // A SUPERVISOR TOO OLD TO KNOW THE FIELD, which is the shape the wire contract promises: the
    // request decodes without it and reads as a plain send, so the line is typed and the window
    // closes the way it did before this verb existed.
    let legacy = Data("{\"epoch\":1,\"text\":\"/clear\",\"waitSeconds\":6}".utf8)
    check("a request from a build without the field decodes, and claims no authority",
          (parseSessionInput(legacy) as SessionInputRequest?)?.intent == nil
              && !sessionClearMovesAccounts(
                  request: parseSessionInput(legacy) as SessionInputRequest? ?? clearRequest(),
                  state: .idle, draft: .none))
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

    // MARK: - What it does to a pin standing over the session

    // THE HOLE THIS FAMILY OPENED, and the reason it was invisible until the release existed
    // (codex review of 7404128). Before it, a pinned session's `policy.mode` was `manual` at this
    // landing, `windowRepickMove` answered nothing, and a clear could only ever type - so a
    // clear-boundary move for a pinned session was unreachable and its absence from
    // `pinPassingReasons` cost nothing. Released, the same landing plans a move, and a move whose
    // reason is not on that list leaves the pin naming an account the session has just left: all
    // four preventive movers refuse it from then on (`sessionPolicy` folds a phantom pin back into
    // `manual`), and nobody is told, because the sentence is printed by the caller that reads the
    // list. It is the defect `RelaunchPlan.swift` already records against 9ea3ea9, reached from a
    // new direction, by the verb this fleet runs at the end of every session.
    check("a window closing under a pin is a move that may pass it",
          pinPassingReasons.contains(clearBoundaryReason))
    check("…so the relaunch it plans clears the pin rather than leaving a phantom behind", {
        var pinned = ManualMoveState(sessionKey: "clear-pin", servedEpoch: 1, sessionPin: "A",
                                     dir: dir)
        let cleared = pinned.pinCleared(by: clearBoundaryReason)
        return cleared && pinned.sessionPin == nil
    }())
    check("…and the session is told, in the wording a move off an empty account uses",
          sessionPinClearedNotice(reason: clearBoundaryReason)
              == sessionPinClearedNotice(reason: turnBoundaryReason)
              && sessionPinClearedNotice(reason: clearBoundaryReason).contains("out of quota")
              && sessionPinClearedNotice(reason: clearBoundaryReason)
                  != sessionPinClearedByCapNotice)
    // A session with no pin has nothing to clear, and says nothing: the notice is printed on this
    // answer, so a `true` here would announce a pin that never existed.
    check("a clear-boundary move on an unpinned session clears nothing and announces nothing", {
        var unpinned = ManualMoveState(sessionKey: "clear-nopin", servedEpoch: 1, dir: dir)
        return !unpinned.pinCleared(by: clearBoundaryReason)
    }())
    // AND THE OTHER ENDING IS UNTOUCHED. A clear that TYPES plans no relaunch at all, so nothing
    // reads this list and the pin stands - which is right: the session has not moved.
    check("the endings that do not move an account are not on that list",
          !pinPassingReasons.contains("switch") && !pinPassingReasons.contains("pin")
              && !pinPassingReasons.contains("reload"))
    // The tag is compiled where the list that names it is, so a suite that never compiles the verb
    // still agrees about the word (RelaunchPlan.swift states the rule; `turnBoundaryReason` moved
    // there first, for this reason).
    check("the tag and the plan it rides on agree about the word",
          clearBoundaryPlan(healthy, from: clearAccount("A", "Claude 1"),
                            primaryModel: nil)?.reason == clearBoundaryReason)

    // MARK: - What the published reading does when the window closes

    // THE READING IS ABOUT A CONVERSATION, NOT ABOUT A SESSION, and a clear-boundary move ends one
    // and starts another. Carrying it across would publish the closed window's size under the
    // account it reopened on - and, worse, keep naming its transcript id, which is the witness every
    // hook matches its events against (HookNotify.swift, HookAgents.swift): until it is corrected,
    // the new conversation's notifications, agent roll call and turn-end fact are all dropped as
    // somebody else's.
    var context = SessionContextWriter()
    let closedPid = "9420"
    context.sync(tokens: 250_000, accountID: "A", pin: nil, transcript: "conv-OLD", pid: closedPid,
                 dir: dir, now: t0)
    check("a session that has had turns has a published reading",
          readSessionContext(pid: closedPid, dir: dir)?.transcriptSessionID == "conv-OLD")
    context.conversationEnded(pid: closedPid, dir: dir)
    check("the conversation ending takes the published reading with it",
          readSessionContext(pid: closedPid, dir: dir) == nil)
    // AND THE WRITER'S OWN COPY, which unlinking the file alone does not touch: the republish a
    // relaunch makes judges itself against that copy, so a writer still holding the dead reading
    // writes the closed window's id and size straight back under the new account, and the panel and
    // the hooks are exactly where they were.
    context.accountChanged(to: "B", pin: nil, transcript: "conv-OLD", pid: closedPid, dir: dir,
                           now: t0.addingTimeInterval(1))
    check("…so nothing republishes it under the account the window reopened on",
          readSessionContext(pid: closedPid, dir: dir) == nil)
    // The next conversation publishes on its own terms, from its first turn with usage in it, which
    // is what says the silence above is a gap rather than a session that can never report again.
    context.sync(tokens: 4_000, accountID: "B", pin: nil, transcript: "conv-NEW", pid: closedPid,
                 dir: dir, now: t0.addingTimeInterval(2))
    let reopened = readSessionContext(pid: closedPid, dir: dir)
    check("…and the window that opened in its place reports itself, from its own first turn",
          reopened?.transcriptSessionID == "conv-NEW" && reopened?.contextTokens == 4_000)

    // MARK: - The wiring no value can be asked about

    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the clear checks", !loop.isEmpty)
    // THE DECISION IS THE REPICK'S OWN, asked with this session's real gates rather than with a
    // second threshold invented here: same function, same account, same fuse, same quarantine.
    if let start = loop.range(of: "let action = applySessionInput("),
       let end = loop.range(of: "windowRepick.apply(action.repick,",
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
    // AND THE SIDECAR IS RETIRED ON THAT SAME FRESHNESS, which no value above can be asked about:
    // the writer's `conversationEnded` can be perfect while the loop calls the republish anyway, and
    // the republish is handed the OLD child's watcher (this tick's `watcher` is rebuilt only at the
    // next spawn), so the conversation that just ended would be published under the new account.
    if let start = loop.range(of: "performHandoff(to: plan.target"),
       let end = loop.range(of: "writeSupervisorAccount(account.id, pid: supervisorPID)",
                            range: start.upperBound ..< loop.endIndex) {
        let block = String(loop[start.upperBound ..< end.lowerBound])
        check("a fresh relaunch retires the published reading instead of republishing it",
              block.contains("if plan.fresh {")
                  && block.contains("sessionContext.conversationEnded(pid: supervisorPID)"))
        // THE REPUBLISH IS THE OTHER BRANCH, not a line that runs beside it: one that still ran
        // after the retirement would write the dead conversation's id back a moment later, and the
        // check above would pass on it.
        if let fresh = block.range(of: "if plan.fresh {"),
           let moved = block.range(of: "sessionContext.accountChanged") {
            check("…and the account republish is the branch a clear does not take",
                  fresh.lowerBound < moved.lowerBound
                      && block.range(of: "} else {",
                                     range: fresh.upperBound ..< moved.lowerBound) != nil)
        } else {
            check("…and the account republish is the branch a clear does not take", false)
        }
    } else {
        check("a fresh relaunch retires the published reading instead of republishing it", false)
        check("…and the account republish is the branch a clear does not take", false)
    }

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
