import Foundation

// `tally session send` AS A COMMAND: its grammar, what it refuses, which session a pid may name, the
// wording every outcome is reported in, and the four exit codes a script reads.
//
// Split from sessioninputchecks.swift on file size, along the seam the SOURCE is split on: that file
// states the channel and the supervisor tick that serves a request (SessionInputRequest.swift,
// SessionInput.swift), and this states the side that asks for one (SessionInputCommand.swift).
//
// Pure or pointed at a temp directory, like its neighbour: nothing here touches `~/.tally/input`, so
// a machine with live sessions on it can run this without one of them being typed into.

func runSessionSendChecks() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-sessionsend-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)
    /// The stamp a request written at `offset` seconds from t0 carries.
    func epoch(_ offset: TimeInterval) -> Int {
        Int((t0.addingTimeInterval(offset)).timeIntervalSince1970 * 1000)
    }
    func request(_ text: String, at offset: TimeInterval = 0) -> SessionInputRequest {
        SessionInputRequest(epoch: epoch(offset), text: text)
    }
    /// A pid nothing is running under, which every "that is not a session" branch is asked about.
    let deadPid = "999999"

    /// A text of exactly the limit, which is what "too long" is judged one byte past.
    let atLimit = String(repeating: "a", count: sessionInputMaxBytes)
    /// An outcome from a supervisor one build ahead of this one: reported verbatim rather than
    /// flattened, because the word itself is the only information there is.
    let future = SessionInputResult(epoch: 1, outcome: "refused-something-new", detail: "why")

    /// Several checks below are about a mode a umask could FILTER, and reading the ambient one makes
    /// them assertions about the machine rather than about the code (codex review of 80499b3).
    /// Pinning is also what makes them discriminating: under a strict umask a wrong mode argument is
    /// trimmed into looking right, so the value alone proves nothing.
    func underUmask<Result>(_ mask: mode_t, _ body: () -> Result) -> Result {
        let previous = umask(mask)
        defer { umask(previous) }
        return body()
    }

    /// The mode a path is at, or nil when there is nothing there.
    func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    // MARK: - The command's grammar

    check("one word is the text", sessionSendIntent(["hello"])
              == SessionSendIntent(text: "hello", session: nil))
    check("--session names another one", sessionSendIntent(["--session", "412", "hi"])
              == SessionSendIntent(text: "hi", session: "412"))
    // NO TEXT IS A REQUEST IN ITS OWN RIGHT: press Return, type nothing, which is how a prompt
    // sitting on its default gets answered. It used to be spelled `--submit` with no text; the
    // absence of an argument is what means it now.
    check("no text at all presses Return and types nothing",
          sessionSendIntent([]) == SessionSendIntent(text: "", session: nil))
    check("…and it can be aimed at another session too",
          sessionSendIntent(["--session", "412"]) == SessionSendIntent(text: "", session: "412"))
    // THE FLAG THAT USED TO SAY "AND SEND IT" IS NOT A FLAG ANY MORE, so it is content or an error
    // like any other unknown word, and never a silently accepted no-op that makes a caller believe
    // it asked for something.
    check("--submit is no longer a flag this command knows",
          sessionSendIntent(["hello", "--submit"]) == nil && sessionSendIntent(["--submit"]) == nil)
    // Two bare words differ from one by exactly the whitespace the shell ate, and there is no
    // reading that is safe to guess at.
    check("two words are a usage error rather than a join",
          sessionSendIntent(["hello", "there"]) == nil)
    check("a flag this command does not know is not content",
          sessionSendIntent(["--force"]) == nil && sessionSendIntent(["-x", "hi"]) == nil)
    check("--session without a value, or twice, is a usage error",
          sessionSendIntent(["--session"]) == nil
              && sessionSendIntent(["--session", "1", "--session", "2", "hi"]) == nil)
    // `--` is what makes text that looks like a flag sendable at all.
    check("-- ends the flags, so a dash can be sent",
          sessionSendIntent(["--", "--submit"]) == SessionSendIntent(text: "--submit", session: nil)
              && sessionSendIntent(["--session", "9", "--", "--help"])
              == SessionSendIntent(text: "--help", session: "9"))

    check("the command refuses an over-long line before anything is written",
          sessionSendProblem(SessionSendIntent(text: atLimit + "a", session: nil))?
              .contains("201 bytes") == true)
    check("…and says nothing about one that fits",
          sessionSendProblem(SessionSendIntent(text: atLimit, session: nil)) == nil)
    // An empty line is no longer a problem to report: it is the Return-only request.
    check("…nor about an empty one, which is the Return-only request",
          sessionSendProblem(SessionSendIntent(text: "", session: nil)) == nil)

    // The lines the namespace says, and the verbs they name. TWO of them since 2026-08-18, and the
    // namespace text is built from each verb's own first line rather than typed a third time: a
    // verb added without a line here would be a command nothing tells anybody about.
    check("the usage text documents the verbs that exist",
          sessionSendUsage.contains("tally session send [<text>] [--session <pid>]")
              && !sessionSendUsage.contains("--submit")
              && sessionClearUsage.contains("tally session clear [--session <pid>]")
              && sessionUsage.contains("usage: tally session send [<text>] [--session <pid>]")
              && sessionUsage.contains("tally session clear [--session <pid>]"))
    // AND THE SEND POINTS AT THE OTHER ONE, which is the whole of how a caller finds the verb that
    // decides accounts: `send` is deliberately the dumb pipe, so the place it says so is the place
    // somebody reading about `/clear` is standing.
    check("…and the send names the verb for a hand-over clear",
          sessionSendUsage.contains("tally session clear"))

    // MARK: - One send at a time at one address

    // One address holds one send, so a second one written while the first is still in flight lands
    // ON it: the first caller then waits for something that exists nowhere, is told nobody answered,
    // and nothing on either end records that an instruction was dropped (codex review of 18b3174).
    // So the second caller is refused instead.
    let busyKey = "9301"
    let occupant = request("first")
    check("an address with nothing at it is free",
          sessionInputOccupant(sessionKey: busyKey, dir: dir, now: t0.addingTimeInterval(1)) == nil)
    try? writeSessionInputRequest(occupant, sessionKey: busyKey, dir: dir)
    check("…a request still inside its life occupies it",
          sessionInputOccupant(sessionKey: busyKey, dir: dir, now: t0.addingTimeInterval(1))
              == .request(occupant))
    // A husk does NOT occupy it: the supervisor refuses it the next time it looks, and treating it
    // as an occupant would take the address away over a caller killed mid-wait.
    check("…and one past its life does not",
          sessionInputOccupant(sessionKey: busyKey, dir: dir,
                               now: t0.addingTimeInterval(sessionInputQueuedLife + 1)) == nil)
    // THE TWO CLOCKS ARE ONE NUMBER, which is what the 2026-08-18 rework had to keep true on both
    // sides: the supervisor holds a queued request for `sessionInputQueuedLife`, so an address
    // freed any sooner than that would let a second caller write over a line that is pending and
    // healthy - the overwrite this whole type exists to refuse.
    check("…and it is occupied for exactly as long as the supervisor will still act on it",
          sessionInputOccupant(sessionKey: busyKey, dir: dir,
                               now: t0.addingTimeInterval(sessionInputQueuedLife - 1))
              == .request(occupant)
              && !sessionInputExpired(epoch: occupant.epoch,
                                      now: t0.addingTimeInterval(sessionInputQueuedLife - 1))
              && sessionInputExpired(epoch: occupant.epoch,
                                     now: t0.addingTimeInterval(sessionInputQueuedLife + 1)))
    let busy = sessionInputBusyRefusal(.request(occupant), sessionKey: busyKey,
                                       now: t0.addingTimeInterval(20))
    check("the second caller is told nothing was queued, and how long the first one has left",
          busy.contains(busyKey) && busy.contains("nothing was queued")
              && busy.contains("\(Int(sessionInputQueuedLife) - 20)s"))
    // AND IT DESCRIBES A QUEUE RATHER THAN A DEADLINE, since that is what the first line is in
    // now: telling this caller to "wait for it to expire" would be telling it to wait out the one
    // ending nobody wants.
    check("…and it says what will happen to that line rather than only when it dies",
          busy.contains("out of its own turn"))
    // TELLABLE APART FROM A GATE REFUSAL, which is the point of wording it separately: those mean
    // "the session was busy or silent, this may work later", and this one means "your text was
    // never queued at all, because something else is already using this address".
    check("…and it does not read like one of the gate's refusals",
          !busy.contains("never reached a moment") && !busy.contains("never reported"))
    clearSessionInputRequest(sessionKey: busyKey, dir: dir)

    // THE OTHER HALF OF A SEND'S LIFE, which is the state this check used to be blind to: the
    // supervisor writes the answer and then unlinks the request, so between two of the first
    // caller's 250ms polls the address holds an answer and NO request. Reading that as empty is
    // what let the next caller delete a delivery report for text that was already typed, leaving
    // the first caller to time out and reasonably send the same line again (codex review of
    // 3c37831).
    let servedAnswer = SessionInputResult(epoch: epoch(0), outcome: "submitted", detail: nil)
    writeSessionInputResult(servedAnswer, sessionKey: busyKey, dir: dir)
    check("an answer nobody has collected yet occupies the address, with no request in sight",
          readSessionInputRequest(sessionKey: busyKey, dir: dir) == nil
              && sessionInputOccupant(sessionKey: busyKey, dir: dir,
                                      now: t0.addingTimeInterval(1)) == .answer(servedAnswer))
    // AND IT IS LIVE FOR THE CALLER'S WAIT RATHER THAN THE REQUEST'S LIFE, which since 2026-08-18
    // means an answer is normally the SHORTER of the two - the reverse of the arrangement this
    // check was written under, and right for the same reason it was right then: what makes an
    // answer collectable is somebody standing at the address, and every caller now leaves after six
    // seconds. This one names no wait at all (a CLI that predates the field), so it is charged the
    // longest wait anybody ever made.
    check("…for as long as the caller that asked for it said it would wait",
          sessionInputOccupant(sessionKey: busyKey, dir: dir,
                               now: t0.addingTimeInterval(sessionInputWaitSeconds - 1))
              == .answer(servedAnswer))
    check("…and past that it is a husk like any other, whatever the request's own life is",
          sessionInputOccupant(sessionKey: busyKey, dir: dir,
                               now: t0.addingTimeInterval(sessionInputWaitSeconds + 1)) == nil
              && sessionInputWaitSeconds < sessionInputQueuedLife)
    // A REQUEST OUTRANKS AN ANSWER when both are there (a newer send served while an older answer
    // sits uncollected): what the caller is told should name the thing that has not happened yet.
    try? writeSessionInputRequest(request("second", at: 1), sessionKey: busyKey, dir: dir)
    check("…and a request present alongside an answer is what the address is said to hold",
          sessionInputOccupant(sessionKey: busyKey, dir: dir, now: t0.addingTimeInterval(2))
              == .request(request("second", at: 1)))
    clearSessionInputRequest(sessionKey: busyKey, dir: dir)
    let uncollected = sessionInputBusyRefusal(.answer(servedAnswer), sessionKey: busyKey,
                                              now: t0.addingTimeInterval(20))
    // The two wordings differ because what the caller should do differs: one is "wait, it will be
    // served or expire", the other is "somebody's delivery report is sitting here and the text is
    // already in the session".
    check("an uncollected answer is refused in its own words, naming the outcome and the wait left",
          uncollected.contains(busyKey) && uncollected.contains("nothing was queued")
              && uncollected.contains("submitted")
              && uncollected.contains("\(Int(sessionInputWaitSeconds) - 20)s")
              && uncollected != busy)
    check("…and it does not read like one of the gate's refusals either",
          !uncollected.contains("never reached a moment") && !uncollected.contains("never reported"))
    clearSessionInputResult(sessionKey: busyKey, dir: dir)

    // AN ANSWER NOBODY IS WAITING FOR IS NOT AN OCCUPANT, which is the other end of the same rule.
    // Every caller now leaves after `sessionInputGraceSeconds` by design, so the receipt written
    // when the line is finally typed lands at an address with nobody standing at it: charged the
    // long wait, it shut that address for the rest of two and a half minutes and the next
    // legitimate send was refused as a duplicate, measured at up to 144s (codex review of
    // 0c9798b). The caller's own number travels on the request and back on the answer, so the
    // occupant test can ask how long THAT caller was going to be there.
    let selfWait = Int(sessionInputGraceSeconds)
    let unwatched = SessionInputResult(epoch: epoch(0), outcome: "submitted", detail: nil,
                                       waitSeconds: selfWait)
    writeSessionInputResult(unwatched, sessionKey: busyKey, dir: dir)
    check("a receipt for a caller that waits six seconds occupies the address for six seconds",
          sessionInputOccupant(sessionKey: busyKey, dir: dir,
                               now: t0.addingTimeInterval(TimeInterval(selfWait) - 1))
              == .answer(unwatched))
    check("…and is a husk immediately after that, rather than at 150s",
          sessionInputOccupant(sessionKey: busyKey, dir: dir,
                               now: t0.addingTimeInterval(TimeInterval(selfWait) + 1)) == nil
              && sessionInputOccupant(sessionKey: busyKey, dir: dir,
                                      now: t0.addingTimeInterval(30)) == nil)
    // The sentence a second caller would see agrees with that clock rather than quoting the long
    // one, or the refusal would tell them to wait out a wait nobody is making.
    let shortLeft = sessionInputBusyRefusal(.answer(unwatched), sessionKey: busyKey,
                                            now: t0.addingTimeInterval(2))
    check("…and the refusal names the time THAT answer has left, not the longest wait",
          shortLeft.contains("\(selfWait - 2)s")
              && !shortLeft.contains("\(Int(sessionInputWaitSeconds) - 2)s"))
    // An answer from a build with no such field is charged the longest wait, which is the behaviour
    // that stood before the field existed: the fallback is what keeps a mixed pair of builds safe.
    check("…while an answer that names no wait is judged as it always was",
          sessionInputAnswerLife(unwatched) == TimeInterval(selfWait)
              && sessionInputAnswerLife(servedAnswer) == sessionInputWaitSeconds)
    clearSessionInputResult(sessionKey: busyKey, dir: dir)

    // MARK: - Which pid --session may name

    // Liveness alone says a process is there and nothing about what it is, so `--session <any live
    // pid>` used to write a file holding somebody's text to an address nothing would ever read.
    // The registry a supervisor writes itself into (`markSupervisorLive`) is what tells them apart.
    let registry = dir.appendingPathComponent("registry")
    try? FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    let ownPid = String(getpid())
    check("a live process with no presence entry is not a session to type into",
          namedSession(ownPid, dir: registry) == .notSupervised)
    try? "".write(to: registry.appendingPathComponent(ownPid), atomically: true, encoding: .utf8)
    check("…and the same pid once it is registered is one",
          namedSession(ownPid, dir: registry) == .session(ownPid))
    check("a pid nothing is running under is neither",
          namedSession(deadPid, dir: registry) == .notRunning)
    check("…nor is a word that is not a pid at all",
          namedSession("session-9301", dir: registry) == .notRunning)
    // Normalised through the pid, so a padded number addresses the same file the bare one does.
    check("--session 0<pid> addresses the same session <pid> does",
          namedSession("0" + ownPid, dir: registry) == .session(ownPid))
    // The registry is asked for THIS machine's supervisors rather than reimplemented: an entry
    // under a dead pid is not one, whatever the file says.
    try? "".write(to: registry.appendingPathComponent(deadPid), atomically: true, encoding: .utf8)
    check("…and an entry left behind by a dead supervisor names nothing",
          namedSession(deadPid, dir: registry) == .notRunning)
    // EITHER HALF OF A SESSION ANSWERS TO ITS NAME. A session is two processes and the one a caller
    // has in hand is almost always the child: `tally status --json` publishes the Claude Code pid
    // and no other, which is where every agent is told to look, so accepting only the supervisor
    // made the documented route fail about a session that is plainly running. A real child is
    // spawned here rather than faked, because what resolves one is its actual parentage.
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try? sleeper.run()
    defer { sleeper.terminate() }
    let childPid = String(sleeper.processIdentifier)
    let ownChildFile = registry.appendingPathComponent(ownPid + supervisorChildSuffix)
    try? childPid.write(to: ownChildFile, atomically: true, encoding: .utf8)
    check("a session named by its Claude Code pid resolves to the supervisor that owns it",
          sleeper.processIdentifier > 0 && namedSession(childPid, dir: registry) == .session(ownPid))
    // PROVED RATHER THAN BELIEVED, through the same reader the switch uses: the file has to name
    // that pid AND the process has to really be that supervisor's child. A second registered
    // supervisor claiming the same pid is claiming somebody else's, and gets nothing for it.
    let stranger = String(getppid())
    try? "".write(to: registry.appendingPathComponent(stranger), atomically: true, encoding: .utf8)
    try? childPid.write(to: registry.appendingPathComponent(stranger + supervisorChildSuffix),
                        atomically: true, encoding: .utf8)
    try? FileManager.default.removeItem(at: ownChildFile)
    check("…so a child claimed by a supervisor that is not its parent is claimed by nobody",
          namedSession(childPid, dir: registry) == .notSupervised)

    // MARK: - What the caller is told, and what it exits on

    // TWO CODES COME OFF AN ANSWER and the rest are decided by the run: 4 belongs to a session that
    // has exited and 0 also means "queued with nothing refusing it", which no answer can say -
    // since 2026-08-18 the ordinary send has no answer to read at all.
    check("the exit codes an answer decides are kept apart",
          sessionInputExitCode(SessionInputResult(epoch: 1, outcome: "submitted",
                                                  detail: nil)) == 0
              && sessionInputExitCode(SessionInputResult(epoch: 1, outcome: "refused-expired",
                                                         detail: nil)) == 3
              && sessionInputExitCode(SessionInputResult(epoch: 1, outcome: "failed-tty",
                                                         detail: nil)) == 3)
    // An outcome this build has never heard of exits as a refusal AND is reported verbatim: the word
    // is the only information a CLI behind its supervisor has.
    check("an unfamiliar outcome exits as a refusal and is quoted back",
          sessionInputExitCode(future) == 3
              && sessionInputMessage(future, sessionKey: "9").contains("\"refused-something-new\""))
    for outcome in [SessionInputOutcome.submitted, .refusedTooLong, .refusedNotReporting,
                    .refusedExpired, .failedTTY] {
        let message = sessionInputMessage(SessionInputResult(epoch: 1, outcome: outcome.rawValue,
                                                             detail: "why"),
                                          sessionKey: "9208")
        check("`\(outcome.rawValue)` is worded for the caller, and carries the detail",
              !message.isEmpty && message.contains("(why)"))
    }
    check("the delivered wording names the session that got the text, and says it was sent",
          sessionInputMessage(SessionInputResult(epoch: 1, outcome: "submitted", detail: nil),
                              sessionKey: "9208").contains("sent to session 9208"))
    // A word from a build that still had the composer-only outcome is reported verbatim rather than
    // read as a delivery: this build cannot produce it, and guessing what somebody else meant by it
    // is how a caller is told a line landed when it is sitting in a composer.
    check("…and a build's leftover `injected` is quoted back rather than believed",
          sessionInputMessage(SessionInputResult(epoch: 1, outcome: "injected", detail: nil),
                              sessionKey: "9").contains("\"injected\"")
              && sessionInputExitCode(SessionInputResult(epoch: 1, outcome: "injected",
                                                         detail: nil)) == 3)

    // MARK: - The wait

    var clock = t0
    var slept = 0
    var husk: SessionInputResult? = SessionInputResult(epoch: 7, outcome: "submitted", detail: nil)
    let waited = awaitSessionInputResult(
        sessionKey: "9209", epoch: 8, timeout: 1, interval: 0.25, now: { clock },
        sleep: { slept += 1; clock = clock.addingTimeInterval($0) },
        read: { _ in husk })
    // MATCHED ON THE EPOCH, which is the whole reason an answer carries one: a husk from an earlier
    // request can still be at that path, and reading it as this one's would report a delivery that
    // never happened.
    check("an answer to somebody else's request is not this one's",
          waited == .timedOut && slept == 4)
    clock = t0
    slept = 0
    husk = nil
    let arrived = awaitSessionInputResult(
        sessionKey: "9209", epoch: 8, timeout: 10, interval: 0.25, now: { clock },
        sleep: { _ in
            slept += 1
            if slept == 3 { husk = SessionInputResult(epoch: 8, outcome: "submitted", detail: nil) }
        },
        read: { _ in husk })
    check("…and the one that is arrives as soon as it is written",
          arrived == .answered(SessionInputResult(epoch: 8, outcome: "submitted", detail: nil))
              && slept == 3)
    // THE WAIT NO LONGER OUTLASTS THE REQUEST, and it is not meant to: a queued line may sit behind
    // a turn for a quarter of an hour, so a caller that stayed for its receipt would be sitting on
    // a request that is doing exactly what it should. What the grace still has to be is comfortably
    // more than the 2s poll it is racing, or a session that was already idle would be missed.
    check("the grace is a few ticks rather than the request's whole life",
          sessionInputGraceSeconds < sessionInputQueuedLife
              && sessionInputGraceSeconds >= 2 * 2)

    // A WAIT WHOSE END IS ALREADY DECIDED IS NOT WAITED OUT. The only thing that ever writes an
    // answer is that session's supervisor, so one that has exited leaves a caller sitting for its
    // whole 150 seconds to be told "nobody answered" about a process that was not there for any of
    // them (Albert, 2026-08-17: a refusal has to be prompt and has to say why).
    clock = t0
    slept = 0
    let abandoned = awaitSessionInputResult(
        sessionKey: "9209", epoch: 8, timeout: 150, interval: 0.25, now: { clock },
        sleep: { slept += 1; clock = clock.addingTimeInterval($0) },
        abandon: { "session 9209 has exited" }, read: { _ in nil })
    check("a wait for a session that is gone ends at once, with the reason",
          abandoned == .abandoned("session 9209 has exited") && slept == 0)
    // AND AN ANSWER ALREADY ON DISK OUTRANKS IT, which is the ordering inside the loop: a
    // supervisor that typed the line and then exited has answered, and reporting its absence
    // instead would turn a delivery into a failure.
    clock = t0
    let answeredThenGone = awaitSessionInputResult(
        sessionKey: "9209", epoch: 8, timeout: 150, interval: 0.25, now: { clock },
        sleep: { clock = clock.addingTimeInterval($0) }, abandon: { "gone" },
        read: { _ in SessionInputResult(epoch: 8, outcome: "submitted", detail: nil) })
    check("…but an answer already written outranks the absence of the writer",
          answeredThenGone == .answered(SessionInputResult(epoch: 8, outcome: "submitted",
                                                           detail: nil)))
    // The condition behind that sentence, over an injected roster so it asks nothing of this
    // machine: a live supervisor is not abandoned, a dead one is, and a key that is not a pid at
    // all is left alone (it can only come from a caller that resolved it, and inventing a refusal
    // for it would be guessing).
    check("only a session that is really gone is abandoned",
          sessionInputAbandonment(sessionKey: "9209", alive: { _ in true }) == nil
              && sessionInputAbandonment(sessionKey: "9209", alive: { _ in false })?
                  .contains("9209") == true
              && sessionInputAbandonment(sessionKey: "not-a-pid", alive: { _ in false }) == nil)
    // AND IT DOES NOT SAY THE LINE WAS NOT TYPED, which it cannot know: the supervisor types the
    // bytes and writes the receipt afterwards, so one that died between the two leaves a terminal
    // holding the line and an address holding nothing - the same thing this caller sees when the
    // request was never read at all. Claiming the stronger of the two invites the retry that puts
    // the line in twice (codex review of 0c9798b).
    let gone = sessionInputAbandonment(sessionKey: "9209", alive: { _ in false }) ?? ""
    check("…and the sentence claims only what it can know, and points at what does know",
          !gone.contains("Nothing was typed") && gone.contains("unknown")
              && gone.contains("~/.tally/logs/input.log"))

    // MARK: - Sending into the session you are running in

    // THE DEADLOCK THIS EXISTS TO AVOID, stated as the numbers that prove it. A command run inside
    // a conversation is a tool call, an unfinished tool call is an open turn, and a session
    // mid-turn is exactly what the supervisor will not type into - so a caller that waits for its
    // own line to land is waiting for a turn that cannot end until it stops waiting. Measured on
    // this machine 2026-08-17: three self-sends held their own tool call for 120.2s and were killed
    // by Claude Code's own timeout, and two thirds of the sends in the preceding day expired
    // unserved.
    check("a caller gives up long before the request does",
          sessionInputGraceSeconds < sessionInputQueuedLife
              && sessionInputGraceSeconds < sessionInputWaitSeconds)
    let queued = sessionInputQueuedMessage(sessionKey: "9209")
    // It says four things, and a caller that reads only this line has to be able to act on it:
    // which session, that nothing is waiting, when it would be dropped, and where the outcome is
    // recorded.
    check("the queued line names the session, says nothing waits, and points at the record",
          queued.contains("9209") && queued.contains("nothing here waits")
              && queued.contains("~/.tally/logs/input.log")
              && queued.contains("\(Int(sessionInputQueuedLife))s"))
    // And it cannot be mistaken for a delivery, which is the one way this could mislead: exit 0 is
    // shared with a real send, so the sentence has to carry the difference.
    check("…and it does not claim the line was typed",
          !queued.contains("sent to session"))
    // THE VERSION SKEW NOTE, which is the one thing this command can say that is about neither the
    // line nor the session but about the BUILD that will read it: this channel's contract changed
    // on 2026-08-18, so a supervisor that has not replaced itself yet still drops a queued line
    // after 120s - and this caller was told `queued` by a CLI that promises fifteen minutes.
    check("a supervisor from another build is named, with what it changes",
          sessionInputSkewNote(.afterSelfUpdate).map {
              $0.contains("another build") && $0.contains("120s")
                  && $0.contains("\(Int(sessionInputQueuedLife))s")
          } == true)
    // NOTHING IS SAID WHEN THERE IS NOTHING TO SAY, both ways: a matching build has no skew, and a
    // supervisor too old to read the request at all is REFUSED before anything is written, so a
    // note there would be advice about a line nobody queued.
    check("…and nothing is said about a build that matches, or one already refused",
          sessionInputSkewNote(.honoured) == nil && sessionInputSkewNote(.tooOld) == nil)
    // ONE SENTENCE FOR BOTH CALLERS since 2026-08-18, which is what folded the progress note that
    // used to precede a 150s wait into this: what that note carried and this needed is the state
    // the session published, so a caller can tell "behind a turn" from "the next tick will take it".
    let queuedElsewhere = sessionInputQueuedMessage(sessionKey: "9210", doing: "working")
    check("…and it carries what that session said it was doing, when it said anything",
          queuedElsewhere.contains("9210") && queuedElsewhere.contains("it is working right now"))
    check("…without inventing a state for a session that has published none",
          !queued.contains("right now") && queuedElsewhere.contains("right now"))

    // MARK: - The tick's own reading is what the gate sees

    // `applySessionInput` is handed the state THIS tick decided rather than the file's, which is
    // what makes the moment a turn ends usable at all - so the publisher has to hand it back.
    let statedir = dir.appendingPathComponent("state")
    try? FileManager.default.createDirectory(at: statedir, withIntermediateDirectories: true)
    let transcript = statedir.appendingPathComponent("session.jsonl")
    try? "{}".write(to: transcript, atomically: true, encoding: .utf8)
    var watcher = TranscriptWatcher(projectDir: statedir, file: transcript, since: t0)
    var writer = SessionStateWriter()
    let published = syncSessionState(&writer, pid: "9210",
                                     project: PickProject(name: "p", path: statedir.path),
                                     accountID: "claude:.claude", childPid: nil, model: nil,
                                     supervisorVersion: nil,
                                     watcher: &watcher, keyboardBurstAt: nil, dir: statedir,
                                     now: Date().addingTimeInterval(sessionStateQuietSeconds + 5))
    check("the state a tick publishes is the state it hands the input gate",
          published.state == readSessionState(pid: "9210", dir: statedir)?.supervised)
    // The fixture's transcript was written a moment ago, so this tick is the ordinary mid-turn
    // reading: the word and the reading agree, and both travel to the gate.
    check("…and the reading behind it travels with it, since the word cannot carry the difference",
          published.quiet == .busy && published.state == .working)

    // THE 2026-08-17 INCIDENT, END TO END: a head that has finished speaking with one agent still
    // writing. The publisher reads it (`working`, because there is work in flight and the board is
    // right to say so), the gate is handed the reading behind that word, and the `/clear` is typed.
    // Built from the same fixture the dispatch layout suite uses, so this is the shape a real Agent
    // tool dispatch leaves on disk rather than a hand-made one.
    let dispatchDir = statedir.appendingPathComponent("dispatched")
    try? FileManager.default.createDirectory(at: dispatchDir, withIntermediateDirectories: true)
    let running = DispatchLayoutFixture("send-gate", sessionAge: sessionStateQuietSeconds + 60)
    running.put("subagents/agent-a500d9cae3c919612.jsonl", age: 30)
    var runningWatcher = running.watcher()
    var runningWriter = SessionStateWriter()
    let withAgents = syncSessionState(&runningWriter, pid: "9211",
                                      project: PickProject(name: "p", path: running.dir.path),
                                      accountID: "claude:.claude", childPid: nil, model: nil,
                                      supervisorVersion: nil,
                                      watcher: &runningWatcher, keyboardBurstAt: nil,
                                      dir: dispatchDir)
    check("a head with an agent still writing publishes `working`, as the board should show it",
          withAgents.state == .working && withAgents.quiet == .subagentsWriting)
    var agentInput = SessionInputState(sessionKey: "9211", servedEpoch: 0)
    try? writeSessionInputRequest(SessionInputRequest(epoch: Int(Date().timeIntervalSince1970 * 1000),
                                                      text: "/clear"),
                                  sessionKey: "9211", dir: dir)
    var agentTyped: [String] = []
    applySessionInput(&agentInput, session: withAgents.state, quiet: withAgents.quiet,
                      turnEnded: { false },
                      keyboardIdle: true, relaunchPlanned: false, draftSuspected: false,
                      waitingOnPerson: false, dir: dir,
                      log: dir.appendingPathComponent("dispatch.log")) { text, _ in
        agentTyped.append(text)
        return .done
    }
    check("…and the line it asked for is typed anyway, which is the whole of the rework",
          agentTyped == ["/clear"]
              && readSessionInputResult(sessionKey: "9211", dir: dir)?.outcome == "submitted")
    // THE SHADOW'S FAR EDGE, on the same fixture: an agent that last wrote just inside
    // `subagentIdleSeconds` is the WORST case of the reading that used to refuse these lines, since
    // the relaunch gate holds a session for that whole window while a request used to live a fifth
    // of it. Asserted at 599s rather than at 30 because that is the corner, and a `/clear` typed
    // there is the corner being closed.
    let stale = DispatchLayoutFixture("send-gate-shadow", sessionAge: sessionStateQuietSeconds + 60)
    stale.put("subagents/agent-a500d9cae3c919613.jsonl", age: subagentIdleSeconds - 1)
    var staleWatcher = stale.watcher()
    var staleWriter = SessionStateWriter()
    let deepInShadow = syncSessionState(&staleWriter, pid: "9212",
                                        project: PickProject(name: "p", path: stale.dir.path),
                                        accountID: "claude:.claude", childPid: nil, model: nil,
                                        supervisorVersion: nil,
                                        watcher: &staleWatcher, keyboardBurstAt: nil,
                                        dir: dispatchDir)
    check("a head at the far edge of the 600s relaunch shadow is still only its subagents writing",
          deepInShadow.state == .working && deepInShadow.quiet == .subagentsWriting)
    check("…so the gate types into it, and the count it would have been refused by is gone",
          sessionInputHold(state: deepInShadow.state, quiet: deepInShadow.quiet, turnEnded: false,
                           keyboardIdle: true, relaunchPlanned: false) == nil
              && sessionInputQueuedLife > subagentIdleSeconds)

    // THE HAND-OVER, WHOLE, WITH A ROSTER BEHIND IT (2026-08-18). The head has stopped speaking,
    // its agents are writing right now, its Claude Code has published a roster of two - and the
    // `/clear` lands, ends them, and says so. This is the shape the rule is about: an agent running
    // is not a reason a window cannot be cleared, and what it costs is reported rather than avoided.
    var handOver = SessionInputState(sessionKey: "9221", servedEpoch: 0)
    try? writeSessionInputRequest(
        SessionInputRequest(epoch: Int(Date().timeIntervalSince1970 * 1000), text: "/clear"),
        sessionKey: "9221", dir: dir)
    var handOverTyped: [String] = []
    applySessionInput(&handOver, session: withAgents.state, quiet: withAgents.quiet,
                      turnEnded: { false }, keyboardIdle: true, relaunchPlanned: false,
                      draftSuspected: false, waitingOnPerson: false, dir: dir,
                      log: dir.appendingPathComponent("handover.log"),
                      agents: { _ in 2 }) { text, _ in
        handOverTyped.append(text)
        return .done
    }
    check("a head with agents writing has its /clear typed, and the receipt counts what died",
          handOverTyped == ["/clear"]
              && readSessionInputResult(sessionKey: "9221", dir: dir)?.detail
              == "killed 2 live agents")
    check("…and the log carries the same count for the caller that has already gone",
          ((try? String(contentsOf: dir.appendingPathComponent("handover.log"), encoding: .utf8))
              ?? "").contains("pid=9221 input=agents-killed count=2"))
    // AND AN ORDINARY LINE INTO THE SAME SESSION lands on exactly the same terms while ending
    // nothing: the roster is not even read, because nothing about "2" is answered by typing "hello".
    var ordinary = SessionInputState(sessionKey: "9222", servedEpoch: 0)
    try? writeSessionInputRequest(
        SessionInputRequest(epoch: Int(Date().timeIntervalSince1970 * 1000), text: "hello"),
        sessionKey: "9222", dir: dir)
    var rosterReads = 0
    var ordinaryTyped: [String] = []
    applySessionInput(&ordinary, session: withAgents.state, quiet: withAgents.quiet,
                      turnEnded: { false }, keyboardIdle: true, relaunchPlanned: false,
                      draftSuspected: false, waitingOnPerson: false, dir: dir,
                      log: dir.appendingPathComponent("handover.log"),
                      agents: { _ in rosterReads += 1; return 2 }) { text, _ in
        ordinaryTyped.append(text)
        return .done
    }
    check("a line that is not a clear lands the same way, ends nothing, and reads no roster",
          ordinaryTyped == ["hello"] && rosterReads == 0
              && readSessionInputResult(sessionKey: "9222", dir: dir)?.detail == nil)


    // MARK: - Two things no value can be asked about: the wiring, and the shape of the write

    // BOTH OF THESE SURVIVED MUTATION as ordinary assertions, which is why they are read off the
    // source. The first lives in a `while true` inside a process that spawns children, so nothing
    // links it into a harness; the second is a difference in a TRANSIENT state (measured: the shape
    // this refuses leaves the destination existing and EMPTY between two calls) that no reader can
    // observe after the fact. `tests/statusline` reads main.swift the same way and for the same
    // reason: a surface no unit can reach is still a surface that can rot.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the poll loop was really read", loop.contains("applySessionInput("))
    if let planners = loop.range(of: "applySessionDirectives("),
       let input = loop.range(of: "applySessionInput("),
       let execution = loop.range(of: "\n            if let plan {") {
        // AFTER the planners, or `plan` is read before anything has decided it; BEFORE the
        // execution, because that block is what terminates the child, and typing into a child that
        // is already gone is the other half of the same defect.
        check("the input gate is consulted after the planners decide and before the child goes",
              planners.lowerBound < input.lowerBound && input.lowerBound < execution.lowerBound)
        // READ OFF THIS CALL rather than off the whole file, which is not a detail: `selfUpdateDue`
        // takes an argument of the same name a hundred lines up, so a file-wide search for the
        // words is satisfied by somebody else's call and says nothing about this one. Caught by
        // mutation - passing a constant here survived until the search was narrowed.
        let call = String(loop[input.lowerBound ..< execution.lowerBound])
        // ONE ANSWER, TWO READERS. `plan != nil` is the wiring this had first and it is the defect:
        // it reads a stood-down tick as a relaunch. What the gate must be handed is the value the
        // execution block itself branches on, so the two can never disagree about whether this
        // child is being replaced.
        check("…and it is handed the hold-aware answer rather than the bare plan",
              call.contains("relaunchPlanned: replacingChild")
                  && !call.contains("relaunchPlanned: plan != nil"))
        // That value comes from the one ask, which is a line ABOVE the call and so outside the
        // slice: a search for it has to be made against the file.
        check("…and that answer is the tick's own forced ask",
              loop.contains("var replacingChild = relaunchIsHappening(plan: plan, "
                  + "watcher: &watcher)"))
        check("…which is the same value the relaunch itself branches on",
              loop.contains("if !replacingChild {")
                  // and the old duplicate ask is gone, or the two could drift apart again
                  && !loop.contains("if relaunchHeldByUnresolvedFork("))
    } else {
        check("the input gate is consulted after the planners decide and before the child goes",
              false)
        check("…and it is handed THIS tick's plan rather than a constant", false)
    }

    // THE COMMAND'S ORDER OF BUSINESS, read off the source for the same reason as the loop above:
    // `runSessionSend` waits up to 150 seconds on a supervisor, so nothing links it into a harness,
    // and both of these defects are matters of WHEN it asks rather than of any value it returns.
    let command = (try? String(contentsOfFile: "TallyCLI/SessionInputCommand.swift",
                               encoding: .utf8)) ?? ""
    check("the command was really read", command.contains("func runSessionSend("))
    // THE SKEW NOTE IS A NOTE, NOT A REFUSAL: said after the request is on disk, so the exit code
    // and the queued line are exactly what they would have been without it. Read off the source
    // because `runSessionSend` cannot be called here - it writes into a live conversation.
    if let written = command.range(of: "try writeSessionInputRequest("),
       let note = command.range(of: "if let skew = sessionInputSkewNote(honourability)",
                                range: written.upperBound ..< command.endIndex) {
        check("the skew note is said after something was queued, and changes no exit code",
              note.lowerBound > written.lowerBound
                  && !command.contains("sessionInputSkewNote(honourability) { return"))
    } else {
        check("the skew note is said after something was queued, and changes no exit code", false)
    }
    // And it is asked of the SAME reading the refusal above uses, rather than a second call that
    // could answer differently a few lines later.
    check("…off the one honourability reading this command takes",
          command.contains("let honourability = liveRequestHonourability(")
              && command.components(separatedBy: "liveRequestHonourability(").count == 2)
    if let start = command.range(of: "func runSessionSend("),
       let occupied = command.range(of: "sessionInputOccupant(sessionKey: sessionKey)",
                                    range: start.upperBound ..< command.endIndex),
       let cleared = command.range(of: "clearSessionInputResult(sessionKey: sessionKey)",
                                   range: start.upperBound ..< command.endIndex),
       let written = command.range(of: "try writeSessionInputRequest(",
                                   range: start.upperBound ..< command.endIndex) {
        check("the command asks whether the address is occupied before it writes to it",
              occupied.lowerBound < written.lowerBound)
        // BEFORE THE CLEAR TOO, which is not an ordering detail: that answer file may be the one
        // the other caller is polling for right now, so taking it away on the way to being refused
        // would turn its delivery into a timeout.
        check("…and before it takes away an answer that may be the other caller's",
              occupied.lowerBound < cleared.lowerBound)
    } else {
        check("the command asks whether the address is occupied before it writes to it", false)
        check("…and before it takes away an answer that may be the other caller's", false)
    }
    // THE WAIT, read off the source for the same reason: it is a matter of WHICH timeout and WHICH
    // exit the command reaches, and nothing can call `runSessionSend` here without writing into the
    // developer's own conversation. Since 2026-08-18 there is one wait for everybody, and the two
    // shapes below are what that costs and what it refuses: no caller may wait on the long number,
    // and running the short one out has to END IN A QUEUED LINE AND EXIT 0 rather than in a
    // failure - a caller told "nobody answered" about a line that is pending and healthy is the
    // defect this whole rework removed from the supervisor's side.
    check("every caller makes the same short wait, and nobody waits on the long number",
          command.contains("let wait = sessionInputGraceSeconds")
              && command.contains("timeout: wait,")
              && !command.contains("timeout: sessionInputWaitSeconds"))
    // AND THE SAME NUMBER IS STAMPED ON THE REQUEST, which is what stops the receipt of a send
    // nobody is waiting for from holding the address shut behind it: the two must be one value,
    // since a caller that leaves after six seconds and a receipt judged by 150 is exactly the
    // mismatch that refused the next legitimate send (codex review of 0c9798b).
    check("…and the request carries the wait its caller actually makes",
          command.contains("text: intent.text, waitSeconds: Int(wait)"))
    check("…and running out of it queues rather than fails, for both callers",
          command.contains("    case .timedOut:")
              && command.contains("print(sessionInputQueuedMessage(sessionKey: sessionKey,")
              && !command.contains("sessionInputTimeoutMessage("))
    // THE MARKER STILL DECIDES ONE THING, and only one: whether the supervisor being waited on is
    // this process's own ancestor, which is the one question a `--session <our own pid>` caller
    // would get wrong by reading the flag instead.
    check("…while the marker is left deciding whether that supervisor can be abandoned at all",
          command.contains("let ownSession = marker.adopted(sessionKey) != nil")
              && command.contains("abandon: { ownSession ? nil : sessionInputAbandonment("))
    // FAIL FAST, AND BEFORE ANYTHING IS WRITTEN: every way this can refuse - a usage error, an
    // over-long line, a pid that is not a session, a session that cannot be resolved, a supervisor
    // too old to read the request, an address that is already occupied - returns from ABOVE the
    // write. What that rules out is the shape Albert measured on 2026-08-17: a refusal that arrives
    // only when a clock runs out, with the sender reading the silence in between as success.
    if let start = command.range(of: "func runSessionSend("),
       let written = command.range(of: "try writeSessionInputRequest(",
                                   range: start.upperBound ..< command.endIndex) {
        let before = String(command[start.upperBound ..< written.lowerBound])
        let after = String(command[written.upperBound ..< command.endIndex])
        // SEVEN OF THEM, counted rather than sampled: a refusal added below the write is a refusal
        // that can only be reached after a caller has already been told its line was queued.
        check("every refusal is decided before the request is written, so none of them waits",
              before.components(separatedBy: "return 3").count == 8
                  && before.contains("return 2")
                  && !after.contains("return 3")
                  // and the one non-zero ending left below it is the session that has exited
                  && after.components(separatedBy: "return 4").count == 2)
    } else {
        check("every refusal is decided before the request is written, so none of them waits",
              false)
    }
    if let named = command.range(of: "if let named = intent.session {"),
       let end = command.range(of: "\n    } else {", range: named.upperBound ..< command.endIndex) {
        let branch = String(command[named.upperBound ..< end.lowerBound])
        // READ OFF THE BRANCH rather than the file: `supervisorAlive` is a perfectly good question
        // elsewhere in this command (the marker's own liveness), so a file-wide search would be
        // satisfied by somebody else's call and say nothing about this one.
        check("a pid named on the command line is judged by the registry, not by liveness alone",
              branch.contains("namedSession(named)") && !branch.contains("supervisorAlive("))
        // Both refusals, so a live stranger is never folded back into "nothing is running there".
        check("…and the two ways it can name nothing are answered apart",
              branch.contains("case .notRunning:") && branch.contains("case .notSupervised:"))
    } else {
        check("a pid named on the command line is judged by the registry, not by liveness alone",
              false)
        check("…and the two ways it can name nothing are answered apart", false)
    }

    // THE VERB THE NAMESPACE ANSWERS. Read off the source rather than called, because calling it
    // is the one thing this suite must never do: `runSession` resolves the session it is running
    // INSIDE, so a check that ran it on a developer's machine would write a request into their own
    // live conversation and wait two and a half minutes for it to be typed.
    check("the namespace answers `send`, and the name it shipped under is gone",
          command.contains("case \"send\":\n        return runSessionSend(")
              && !command.contains("case \"type\":"))

    let channel = (try? String(contentsOfFile: "TallyCLI/SessionInputRequest.swift",
                               encoding: .utf8)) ?? ""
    if let start = channel.range(of: "func writeSessionInputPrivately"),
       let end = channel.range(of: "\n}\n", range: start.upperBound ..< channel.endIndex) {
        let body = String(channel[start.upperBound ..< end.lowerBound])
        // The destination is only ever REACHED BY A RENAME. Creating it, truncating it or writing
        // to it in place all pass a mode check afterwards and all destroy the live request while
        // they run: a supervisor polling in that window reads an empty file, which parses as no
        // request at all.
        check("the private write reaches the destination only by renaming a finished file over it",
              body.contains("rename(temp.path, file.path)")
                  && !body.contains("createFile(atPath: file.path")
                  && !body.contains("data.write(to: file"))
        // And the mode is on the TEMPORARY, since a rename carries the mode of the inode it moves,
        // never the mode of what it replaces (measured on this machine, 2026-08-13).
        // THE MODE IS AN ARGUMENT OF THE CREATING CALL, which is what `FileManager.createFile`
        // cannot promise: it creates under the umask and applies the attributes afterwards, so a
        // file holding the whole of somebody's line exists at 0644 for a moment and every
        // measurement taken after the fact still reads 0600 (codex review of 1615990). This is a
        // shape check because the window it refuses can only be caught by watching another process
        // mid-syscall; what CAN be measured is below, and the two together are the claim.
        check("…and the temporary is born at that mode rather than chmod'd into it",
              body.contains("open(temp.path, O_WRONLY | O_CREAT | O_EXCL, "
                  + "mode_t(sessionInputFileMode))")
                  && !body.contains("createFile("))
        // The write loop advances by what the kernel took. A short write is not reachable from
        // here - the payload is bounded at a couple of hundred bytes, far under any regime that
        // produces one on a regular file - so this is pinned by shape rather than by value, and
        // said out loud rather than left looking like a covered case.
        check("…and the write loop advances by what was actually written",
              body.contains("offset += written"))
        // SAME KIND OF PIN, same honesty: a filesystem may hold a write error back until the
        // descriptor is closed, and this suite cannot make that happen - it needs a filesystem
        // that defers (a network mount), which a temp directory is not. What can be pinned is that
        // the answer is taken at all, and that the descriptor is closed exactly once whatever it
        // says, since it is deallocated even on failure.
        check("…and the close is judged rather than assumed",
              body.contains("let closeFailure = close(handle) == 0 ? nil : errno")
                  && body.contains("failure ?? closeFailure")
                  && body.components(separatedBy: "close(handle)").count == 2)
    } else {
        check("the private write reaches the destination only by renaming a finished file over it",
              false)
        check("…and the temporary is born at that mode rather than chmod'd into it", false)
    }
    // The measurable half of that claim: the two mechanisms, asked the same question under a
    // KNOWN umask rather than whatever this machine runs. That is the whole point of the second
    // check - it demonstrates that the umask leaks into a creation mode - and reading the ambient
    // one made it an assertion about the environment instead: on a contributor or a CI runner at
    // 077, `createFile` produces 0600 by itself and a perfectly correct implementation goes red
    // (codex review of 80499b3).
    // A mode passed to `open` is filtered by the umask like any other, so it is asked under two
    // that could not be more different: one that clears nothing this mode sets, and one that
    // clears everything for group and other. 0600 survives both, which is the property the
    // implementation rests on.
    for mask: mode_t in [0o022, 0o077] {
        let octal = String(mask, radix: 8)
        let birth = dir.appendingPathComponent("birth-\(octal)")
        let born = underUmask(mask) {
            open(birth.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(sessionInputFileMode))
        }
        check("a file opened with the mode is that mode from the instant it exists (umask \(octal))",
              born >= 0 && mode(birth) == sessionInputFileMode)
        if born >= 0 { close(born) }
        check("…and O_EXCL makes a name collision an error rather than an overwrite (umask \(octal))",
              open(birth.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(sessionInputFileMode)) < 0
                  && errno == EEXIST)
    }
    // And the control, under a pinned umask so the number it produces is a fact rather than a
    // reading of this machine: 0666 with 022 taken out of it is 0644, which is the window.
    let umasked = dir.appendingPathComponent("umasked")
    let made = underUmask(0o022) {
        FileManager.default.createFile(atPath: umasked.path, contents: Data("x".utf8),
                                       attributes: nil)
    }
    check("…while a file created without a mode takes the umask's, which is what the window is",
          made && mode(umasked) == 0o644 && mode(umasked) != sessionInputFileMode)

    try? FileManager.default.removeItem(at: dir)
}
