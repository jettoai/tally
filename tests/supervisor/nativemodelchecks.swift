import Foundation

// Claude Code's OWN `/model`, made to work inside a Tally session.
//
// THE INCIDENT. A user typed `/model` in a supervised geo session and chose Opus 5 at xhigh. The
// next turn was served by opus, `applyDegradationRescue` read "the serving model is not the one we
// expect" as a quota degradation, moved the session to another account and relaunched it from the
// argv - which put fable back. Typing `/model` again went round the same loop
// (handoff.log reason=degraded, 2026-08-06T19:40:59Z, session 7cfa11a4). The owner's question was
// "why is the native one not supported".
//
// The transcript cannot tell a degradation from a person on the serving model alone: both look like
// "not what we expect". The `/model` event is the signal that separates them, and once the two are
// separable the right answer is the opposite of a rescue - the choice is an instruction, so it joins
// the pin layer `tally model` already built, and nothing needs to restart because the session is
// already serving it.

func runNativeModelChecks() {
    // MARK: - 35a. Reading a foreign command's output

    // The exact line from the incident, ANSI and all. The model NAME in it is a display string
    // ("Opus 5 (1M context)") that changes with the product and is never parsed; the effort is one
    // of the levels the CLI itself enumerates, and that is the only thing read here.
    let real = "Set model to \u{1B}[1mOpus 5 (1M context)\u{1B}[22m and saved as your default for "
        + "new sessions with \u{1B}[1mxhigh\u{1B}[22m effort"
    check("the effort is read out of the real line, past its escape codes",
          nativeModelEffort(inStdout: real) == "xhigh")
    check("…and the display name in it is not mistaken for a model id",
          nativeModelEffort(inStdout: real) != "Opus 5 (1M context)")
    // BOTH SHAPES ARE ORDINARY. Counted across this machine's transcripts: 78 lines end after "for
    // new sessions", 92 carry an effort. An absent one is not a parse failure.
    check("a line naming no effort answers nil, which means leave that axis alone",
          nativeModelEffort(inStdout: "Set model to \u{1B}[1mFable 5\u{1B}[22m and saved as your "
              + "default for new sessions") == nil)
    check("every level the enumeration holds is recognised",
          claudeEffortNames().allSatisfy {
              nativeModelEffort(inStdout: "... with \($0) effort") == $0
          })
    // The whole phrase is matched, which is what keeps the shorter level out of the longer one.
    check("`high` does not claim a line that says `xhigh`",
          nativeModelEffort(inStdout: "... with xhigh effort") == "xhigh")
    check("…and a level outside the enumeration is not invented into one",
          nativeModelEffort(inStdout: "... with extreme effort") == nil)
    check("…nor is a bare word that happens to be a level",
          nativeModelEffort(inStdout: "Set model to high") == nil)
    check("escape codes are stripped, and nothing else is",
          strippingANSI("\u{1B}[1mOpus 5 (1M context)\u{1B}[22m/x")
              == "Opus 5 (1M context)/x")
    check("text with no escape codes survives untouched",
          strippingANSI("plain text") == "plain text")
    check("a truncated escape sequence does not run off the end",
          strippingANSI("done\u{1B}[") == "done")

    // MARK: - 35b. Which `/model` events count

    /// The two adjacent main-chain user events Claude Code writes for one `/model`, and nothing
    /// else: the picker produces no assistant turn of its own, so what proves which model it chose
    /// is the reply to whatever the session does NEXT (`answeredTurn` builds those).
    func modelCommandLines(at offset: TimeInterval, effort: String?,
                           sidechain: Bool = false) -> [String] {
        let side = sidechain ? "true" : "false"
        let tail = effort.map { " with \\u001b[1m\($0)\\u001b[22m effort" } ?? ""
        return [
            #"{"type":"user","isSidechain":\#(side),"timestamp":"\#(stamp(offset))","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-message>model</command-message>"}}"#,
            #"{"type":"user","isSidechain":\#(side),"timestamp":"\#(stamp(offset))","message":{"role":"user","content":"<local-command-stdout>Set model to \#("\\u001b[1mOpus 5 (1M context)\\u001b[22m")\#(" and saved as your default for new sessions")\#(tail)</local-command-stdout>"}}"#,
        ]
    }
    /// An assistant event. `parent` is what attaches it to a turn: without one it hangs off nothing,
    /// which is what an event whose chain cannot be resolved looks like (T12) and therefore never
    /// answers a `/model`.
    func servedLine(_ model: String, at offset: TimeInterval, uuid: String = "a-\(UUID())",
                    parent: String? = nil) -> String {
        let parentField = parent.map { #""parentUuid":"\#($0)","# } ?? ""
        return #"{\#(parentField)"type":"assistant","isSidechain":false,"uuid":"\#(uuid)","timestamp":"\#(stamp(offset))","message":{"model":"\#(model)"}}"#
    }
    /// ONE EXCHANGE: the prompt that starts a turn and the reply that answers it. Fixtures are built
    /// out of these rather than out of bare assistant lines because that is what a transcript is -
    /// and because the answer to a `/model` is now identified by the turn it belongs to, so a reply
    /// with no prompt behind it is not an answer to anything (TranscriptSignals.swift).
    func answeredTurn(askedAt: TimeInterval, servedAt: TimeInterval, by model: String,
                      id: String, text: String = "carry on then") -> [String] {
        [userLine(askedAt, uuid: "u-\(id)", text: text),
         servedLine(model, at: servedAt, uuid: "a-\(id)", parent: "u-\(id)")]
    }
    /// The next turn OPENING, and nothing more: a bare prompt with no answer yet. Fixtures that
    /// assert a confirmation end with one, because that is what settles a held candidate - the
    /// transcript saying the turn it belonged to is over (`pendingConfirmation`,
    /// TranscriptWatcher.swift). A conversation always has one; a fixture stopping at the answer
    /// describes a session frozen mid-sentence.
    func nextTurnOpens(at offset: TimeInterval, id: String = "closer") -> [String] {
        [userLine(offset, uuid: "u-\(id)", text: "and then?")]
    }
    /// A tool_result and the assistant event that follows it: the shape of a turn's TAIL, which
    /// arrives whenever the tool call returns and carries that arrival as its timestamp. It inherits
    /// the root of the turn it belongs to, which is the whole reason a late tail cannot answer a
    /// command typed while it was still running.
    func tailLines(of turn: String, resultAt: TimeInterval, servedAt: TimeInterval,
                   by model: String, id: String) -> [String] {
        [#"{"parentUuid":"a-\#(turn)","type":"user","uuid":"t-\#(id)","isSidechain":false,"timestamp":"\#(stamp(resultAt))","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
         servedLine(model, at: servedAt, uuid: "a-\(id)", parent: "t-\(id)")]
    }

    let typed = watcherAfterScanning(modelCommandLines(at: 30, effort: "xhigh")
        + answeredTurn(askedAt: 50, servedAt: 60, by: "claude-opus-4-8", id: "typed")
        + nextTurnOpens(at: 80))
    check("a post-launch /model is noticed, with the effort it printed",
          typed.lastModelCommandAt == launch.addingTimeInterval(30)
              && typed.lastModelCommandEffort == "xhigh")
    // THE GUARD THAT MATTERS MOST. A resumed session replays its entire history, and that history
    // holds every earlier /model - the incident session had four. A replayed one is not somebody
    // changing the model now, and adopting it would pin a choice from another day.
    let replayed = watcherAfterScanning(modelCommandLines(at: -3600, effort: "high")
        + [servedLine("claude-opus-4-8", at: 60)])
    check("a /model replayed out of history is not one",
          replayed.lastModelCommandAt == nil)
    check("a /model on a subagent's chain is not this session's either",
          watcherAfterScanning(modelCommandLines(at: 30, effort: "high", sidechain: true))
              .lastModelCommandAt == nil)
    check("a session where nobody typed it has none",
          watcherAfterScanning([servedLine("claude-opus-4-8", at: 60)]).lastModelCommandAt == nil)
    check("a /model that printed no effort leaves that axis unnamed",
          watcherAfterScanning(modelCommandLines(at: 30, effort: nil)).lastModelCommandEffort == nil)
    // `/tally-model` writes a command event too, and it is a different command: it asks this
    // supervisor for something, where the native one only reports what already happened.
    check("Tally's own slash command is not mistaken for the native one",
          watcherAfterScanning([
              #"{"type":"user","isSidechain":false,"timestamp":"\#(stamp(30))","message":{"role":"user","content":"<command-name>/tally-model</command-name>"}}"#,
          ]).lastModelCommandAt == nil)

    // MARK: - 35c. Adopting it

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-native-model-\(UUID().uuidString)")
    func freshState() -> SessionModelState {
        SessionModelState(sessionKey: "6001", servedEpoch: 0, dir: dir)
    }
    var state = freshState()
    var follow = FollowState(launchArgs: ["--model", "fable", "--effort", "high"])
    check("the choice becomes this session's pin",
          adoptNativeModelChoice(state: &state, follow: &follow, watcher: typed,
                                 primaryModel: "fable",
                                 launchArgs: ["--model", "fable", "--effort", "high"], log: testAuditLog))
    check("…as the OBSERVED id, never the display name the line showed",
          state.pin.model == "claude-opus-4-8")
    check("…with the effort that line named", state.pin.effort == "xhigh")
    check("…and the launch-default baseline re-pointed, so the follow does not undo it",
          follow.followedModel == "claude-opus-4-8" && follow.followedEffort == "xhigh")
    // Once is once: re-announcing a choice the user made a minute ago, every two seconds, would be
    // its own defect.
    check("a second tick does not adopt it again",
          !adoptNativeModelChoice(state: &state, follow: &follow, watcher: typed,
                                  primaryModel: "claude-opus-4-8",
                                  launchArgs: ["--model", "fable"], log: testAuditLog))

    // MARK: - 35c2. It is told to the STATUS LINE, never to the terminal

    // THE ONE MODEL-AXIS EVENT WITH NO RELAUNCH BEHIND IT, which is what made printing it wrong: the
    // child is drawing, so the line landed inside the live TUI's input box and pushed the prompt
    // around it (owner screenshot, 2026-08-07). The rule was already written down one file over
    // ("is the child about to die?", PendingNotice.swift); this was the adoption that is not.
    var announced = freshState()
    var announcedFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "high"])
    _ = adoptNativeModelChoice(state: &announced, follow: &announcedFollow, watcher: typed,
                               primaryModel: "fable",
                               launchArgs: ["--model", "fable", "--effort", "high"],
                               now: Date(timeIntervalSince1970: 1_800_000_000), log: testAuditLog)
    // The stamp is the event that CONFIRMED the choice, not the poll that noticed it: a poll
    // timestamp is later than a prompt the user has already sent, so the badge outlived its turn by
    // one (review, 2026-08-07). Everything below measures the expiry from this.
    let raisedAt = typed.modelConfirmation?.at ?? .distantPast
    check("the notice is stamped with the turn that confirmed the choice",
          announced.adoptedAt == raisedAt && raisedAt == launch.addingTimeInterval(60))

    // AND ONE POLL READS A WHOLE EXCHANGE. The chunk holds the command, the answer that confirms it,
    // the user's next prompt, and the answer to THAT - so a stamp taken from the newest event in the
    // chunk is newer than the prompt sitting between them, the prompt cannot expire the notice, and
    // the badge outlives its turn exactly as it did with the poll clock (probe, 2026-08-07).
    let batched = watcherAfterScanning(modelCommandLines(at: 30, effort: "xhigh")
        + answeredTurn(askedAt: 50, servedAt: 60, by: "claude-opus-4-8", id: "b1")
        + answeredTurn(askedAt: 90, servedAt: 120, by: "claude-opus-4-8", id: "b2")
        + nextTurnOpens(at: 150))
    check("the confirmation is the turn that answered the command, not the last in the chunk",
          batched.modelConfirmation?.at == launch.addingTimeInterval(60)
              && batched.lastMainChainEventAt == launch.addingTimeInterval(120))
    var batchState = freshState()
    var batchFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "high"])
    _ = adoptNativeModelChoice(state: &batchState, follow: &batchFollow, watcher: batched,
                               primaryModel: "fable",
                               launchArgs: ["--model", "fable", "--effort", "high"],
                               now: launch.addingTimeInterval(200), log: testAuditLog)
    check("…so the notice is stamped before the prompt that follows it",
          batchState.adoptedAt == launch.addingTimeInterval(60))
    batchState.expireAdoption(lastUserTurnAt: batched.lastUserTurnAt)
    check("…and the prompt already in that same chunk takes it down on this very tick",
          batchState.adopted == nil)
    // THE SAME CHUNK, WITH A REAL DEGRADATION AT THE END OF IT. This is the case that makes the
    // choice of model load-bearing rather than cosmetic: the user picks Opus, it answers, they ask
    // something else, and the flagship window runs dry mid-answer so Haiku serves it. Read off the
    // newest event in the chunk, the adoption pinned HAIKU as the user's choice - and a pin is what
    // the session is expected to run, so from that moment the degradation rescue read the fallback
    // as correct and never fired again for the rest of the session (review, 2026-08-07).
    let degradedAfter = watcherAfterScanning(modelCommandLines(at: 30, effort: "xhigh")
        + answeredTurn(askedAt: 50, servedAt: 60, by: "claude-opus-4-8", id: "d1")
        + answeredTurn(askedAt: 90, servedAt: 120, by: "claude-haiku-4-5", id: "d2")
        + nextTurnOpens(at: 150))
    var degradedState = freshState()
    var degradedFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "high"])
    check("the choice adopted is the one that ANSWERED the command",
          adoptNativeModelChoice(state: &degradedState, follow: &degradedFollow,
                                 watcher: degradedAfter, primaryModel: "fable",
                                 launchArgs: ["--model", "fable", "--effort", "high"],
                                 now: launch.addingTimeInterval(200), log: testAuditLog)
              && degradedState.pin.model == "claude-opus-4-8")
    check("…not the quota fallback that served a later turn in the same chunk",
          degradedAfter.lastModel == "claude-haiku-4-5")
    check("…and the notice is stamped with that answer, not with the fallback",
          degradedState.adoptedAt == launch.addingTimeInterval(60))
    degradedState.expireAdoption(lastUserTurnAt: degradedAfter.lastUserTurnAt)
    check("…so the prompt between them still takes the badge down", degradedState.adopted == nil)
    // The whole point of getting the model right: the session is expected to run Opus, Haiku is
    // serving, and that difference is what the rescue acts on. Pinning Haiku would have erased it.
    check("…and the degradation is still a degradation the rescue can see", {
        let primary = sessionPrimaryModel(pin: degradedState.pin,
                                          launchArgs: ["--model", "fable"],
                                          providerID: "claude", policy: LaunchPolicy())
        return primary == "claude-opus-4-8"
            && modelsAgree(degradedAfter.lastModel, primary) == false
    }())

    // (b) A REPLY STILL IN FLIGHT when the command lands finishes after it, so the first
    // post-command turn can be the OLD model. It belongs to the prompt BEFORE the command, which is
    // exactly what the correlation drops - the tense guard from the other side.
    let inFlight = watcherAfterScanning(
        answeredTurn(askedAt: 5, servedAt: 10, by: "claude-fable-5", id: "old",
                     text: "the previous ask")
            + modelCommandLines(at: 30, effort: "xhigh")
            // The tail of that same turn, arriving after the command: a tool call came back and the
            // model wrote more. Its root is the prompt at 5, so no arrival time makes it eligible.
            + tailLines(of: "old", resultAt: 35, servedAt: 40, by: "claude-fable-5", id: "tail")
            + answeredTurn(askedAt: 50, servedAt: 60, by: "claude-opus-4-8", id: "new",
                           text: "now do the thing")
            + nextTurnOpens(at: 80))
    check("the turn that answered it is the one that started after it",
          inFlight.modelConfirmation?.at == launch.addingTimeInterval(60))
    var inFlightState = freshState()
    var inFlightFollow = FollowState(launchArgs: ["--model", "claude-fable-5"])
    _ = adoptNativeModelChoice(state: &inFlightState, follow: &inFlightFollow, watcher: inFlight,
                               primaryModel: "claude-fable-5",
                               launchArgs: ["--model", "claude-fable-5"],
                               now: launch.addingTimeInterval(200), log: testAuditLog)
    check("…so a straggling turn on the old model is not read as the answer",
          inFlightState.pin.model == "claude-opus-4-8"
              && inFlightState.adoptedAt == launch.addingTimeInterval(60))

    // (a) THE CASE THAT REFUTED THE PREVIOUS RULE. The user re-picks the model they are already on,
    // and a quota fallback serves a later turn in the same chunk. Skipping same-model events made
    // that fallback the earliest DIFFERENT one, so it was pinned as the user's choice and the rescue
    // was dead for the rest of the session (review, 2026-08-07).
    let repickedThenFell = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + answeredTurn(askedAt: 50, servedAt: 60, by: "claude-fable-5", id: "r1")
        + answeredTurn(askedAt: 90, servedAt: 120, by: "claude-haiku-4-5", id: "r2")
        + nextTurnOpens(at: 150))
    var repickState = freshState()
    var repickFollow = FollowState(launchArgs: ["--model", "claude-fable-5"])
    check("re-picking the running model still adopts nothing, even with a fallback behind it",
          !adoptNativeModelChoice(state: &repickState, follow: &repickFollow,
                                  watcher: repickedThenFell, primaryModel: "claude-fable-5",
                                  launchArgs: ["--model", "claude-fable-5"],
                                  now: launch.addingTimeInterval(200), log: testAuditLog))
    check("…so the fallback is not pinned as a choice nobody made", repickState.pin.model == nil)
    check("…and the command is consumed all the same, which is what stops a later fallback "
          + "being read as that choice",
          repickState.servedModelCommandAt == launch.addingTimeInterval(30))
    check("…leaving the rescue with the difference it exists to act on", {
        let primary = sessionPrimaryModel(pin: repickState.pin,
                                          launchArgs: ["--model", "claude-fable-5"],
                                          providerID: "claude", policy: LaunchPolicy())
        return primary == "claude-fable-5"
            && modelsAgree(repickedThenFell.lastModel, primary) == false
    }())

    // A NEWER command asks the question again, so what confirmed the previous one is not evidence
    // for it: the map is cleared rather than kept.
    let recommanded = watcherAfterScanning(modelCommandLines(at: 30, effort: "xhigh")
        + answeredTurn(askedAt: 50, servedAt: 60, by: "claude-opus-4-8", id: "c1")
        + modelCommandLines(at: 90, effort: "high"))
    check("a newer /model clears what answered the older one",
          recommanded.modelConfirmation == nil)
    // …and starts waiting on a turn that begins after IT, not on the one that answered the last
    // command.
    check("…and the canary starts counting again with it", recommanded.unanchoredServed == 0)
    check("the adoption raises a status-line badge", announced.adopted != nil)
    check("…short, because it shares the line with the quota meters",
          (announced.adopted?.badge.count ?? 99) <= 20)
    // The status line already renders the pair, so the badge does not repeat it. What nothing else
    // says is that this is a PIN rather than a degradation, and how to undo it.
    check("…and the long form carries what the status line cannot say", {
        let detail = announced.adopted?.detail ?? ""
        return detail.contains("tally model auto") && detail.contains("degradation")
            && detail.contains("claude-opus-4-8/xhigh")
    }())
    check("…which is the badge the rest of the loop asks for",
          announced.badge == announced.adopted)
    // A live wait outranks old news, the same ranking the account axis applies to its two.
    check("…until something is actually being held, which is still true", {
        var both = announced
        both.waiting = PendingBadge("model at idle")
        return both.badge?.badge == "model at idle"
    }())

    // NEWS NEEDS AN END, and a prompt is the first moment the user demonstrably has: the adoption
    // happens inside a turn, so "an assistant event since" is true seconds later and would take the
    // notice down before anyone saw it (`expireCancellation` states the rule one axis over).
    var expiring = announced
    expiring.expireAdoption(lastUserTurnAt: raisedAt.addingTimeInterval(-10))
    check("a prompt older than the notice does not take it down", expiring.adopted != nil)
    expiring.expireAdoption(lastUserTurnAt: nil)
    check("nor does a session where nobody has typed since", expiring.adopted != nil)
    expiring.expireAdoption(lastUserTurnAt: raisedAt.addingTimeInterval(10))
    check("the user's next prompt does", expiring.adopted == nil && expiring.adoptedAt == nil)

    // SURVIVING THE SELF-UPDATE EXEC. It keeps the pid and rebuilds this state from nothing, so a
    // notice raised moments before lives only in `<pid>.notice` - where the new image's first honest
    // "nothing is pending" unlinks it, and the badge is gone before the user ever looked (review,
    // 2026-08-07). Recognised by its own kind, exactly as the cancelled switch is one axis over.
    let noticeDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-model-notice-\(UUID().uuidString)")
    writePendingNotice(PendingNotice(badge: "/model pinned", detail: "…", since: raisedAt,
                                     kind: modelAdoptionNoticeKind), pid: "7171", dir: noticeDir)
    var afterUpgrade = SessionModelState(sessionKey: "7171", servedEpoch: 0, dir: noticeDir)
    afterUpgrade.adoptAdoption(readPendingNotice(pid: "7171", dir: noticeDir))
    check("a session that came back from an upgrade still has its notice",
          afterUpgrade.adopted?.badge == "/model pinned")
    check("…stamped from when it was raised, so the expiry is unchanged by the upgrade",
          afterUpgrade.adoptedAt == raisedAt)
    check("…and still recognisable, so the next image can adopt it too",
          afterUpgrade.adopted?.kind == modelAdoptionNoticeKind)
    // A whitelist: the account axis's news, and every live wait, belong to somebody else.
    var refusing = SessionModelState(sessionKey: "7272", servedEpoch: 0, dir: noticeDir)
    refusing.adoptAdoption(PendingNotice(badge: switchCancelledBadge, detail: nil, since: raisedAt,
                                         kind: cancellationNoticeKind))
    check("another axis's news is not adopted", refusing.adopted == nil)
    refusing.adoptAdoption(PendingNotice(badge: "model at idle", detail: nil, since: raisedAt,
                                         kind: nil))
    check("nor is a live wait, which the new image re-derives anyway", refusing.adopted == nil)
    try? FileManager.default.removeItem(at: noticeDir)

    // The badge is gone the moment they type, so the only durable record of an event that changes
    // what a session runs and restarts nothing is the log line.
    let logged = sessionModelAdoptionLine(pair: "claude-opus-4-8/xhigh",
                                          sessionID: "abcdefgh12345678", now: raisedAt)
    check("the adoption is recorded where it can be read back",
          logged.contains(" session=abcdefgh ") && logged.contains(" model-pin=adopted ")
              && logged.contains(" pair=claude-opus-4-8/xhigh ") && logged.hasSuffix("\n"))
    check("…and it is one line", logged.filter { $0 == "\n" }.count == 1)

    // AND THE ORDER IN THE TICK IS THE OTHER HALF of that stamp: the expiry has to be asked AFTER
    // the adoption, or it asks about a badge that does not exist yet and the prompt already sitting
    // in the transcript takes a whole extra turn to be noticed (review, 2026-08-07).
    let directivesSource = (try? String(contentsOfFile: "TallyCLI/SessionDirectives.swift",
                                        encoding: .utf8)) ?? ""
    check("the directives source is readable from the suite", !directivesSource.isEmpty)
    check("the tick expires the notice after raising it, never before", {
        guard let adopt = directivesSource.range(of: "adoptNativeModelChoice(state:"),
              let expire = directivesSource.range(of: "model.expireAdoption(") else { return false }
        return expire.lowerBound > adopt.upperBound
    }())

    // AND THE FUNCTION ITSELF MUST NOT REACH THE TERMINAL. Asserted against the source, because the
    // behaviour above stays green if a `warn` is added BESIDE the badge - and a `warn` beside the
    // badge is exactly the defect: it is the printing that breaks the TUI, not the absence of a
    // notice.
    let modelSource = (try? String(contentsOfFile: "TallyCLI/SessionModel.swift",
                                   encoding: .utf8)) ?? ""
    check("the session-model source is readable from the suite", !modelSource.isEmpty)
    if let start = modelSource.range(of: "func adoptNativeModelChoice("),
       let end = modelSource.range(of: "func sessionModelAdoptionLine(",
                                   range: start.upperBound ..< modelSource.endIndex) {
        let body = String(modelSource[start.upperBound ..< end.lowerBound])
        check("the adoption writes no line to the shared terminal", !body.contains("warn("))
    } else {
        check("the adoption body was found", false)
    }

    // THE TENSE GUARD, and the fixture is the sequence that makes it load-bearing. `lastModel` is
    // the model that served the last answer WRITTEN DOWN, so between a /model and the next turn it
    // still holds the previous one. That is harmless while the previous one was what we expected -
    // and it is exactly wrong in the case a user is most likely to be IN: something had already
    // degraded the session onto another model, they opened /model to fix it, and no answer has come
    // back yet. Adopting then would pin the degradation as though they had asked for it.
    //
    // (Written first with a fixture where the previous answer AGREED with the primary. It passed,
    // and it passed for the wrong reason - the agreement check refused it long before the tense
    // check was consulted - so a mutation removing the tense guard stayed green.)
    let degradedThenTyped = watcherAfterScanning([servedLine("claude-opus-4-8", at: 10)]
        + modelCommandLines(at: 30, effort: "xhigh"))
    var waiting = freshState()
    var waitingFollow = FollowState(launchArgs: ["--model", "fable"])
    check("a /model with no answer served since it is not adopted yet",
          !adoptNativeModelChoice(state: &waiting, follow: &waitingFollow,
                                  watcher: degradedThenTyped, primaryModel: "fable",
                                  launchArgs: ["--model", "fable"], log: testAuditLog))
    check("…so a degradation the user was reacting TO is never pinned as their choice",
          !waiting.isPinned)
    // Once an answer does come back, it is that answer that is adopted - which may be neither the
    // model they were degraded onto nor the one they were launched with.
    let confirmed = watcherAfterScanning([servedLine("claude-opus-4-8", at: 10)]
        + modelCommandLines(at: 30, effort: "xhigh")
        + answeredTurn(askedAt: 50, servedAt: 60, by: "claude-haiku-4-5", id: "settled")
        + nextTurnOpens(at: 80))
    var settled = freshState()
    var settledFollow = FollowState(launchArgs: ["--model", "fable"])
    check("the answer that arrives after the command is the one adopted",
          adoptNativeModelChoice(state: &settled, follow: &settledFollow, watcher: confirmed,
                                 primaryModel: "fable", launchArgs: ["--model", "fable"], log: testAuditLog)
              && settled.pin.model == "claude-haiku-4-5")

    // A /model that chose what the session was already running changes nothing, so there is nothing
    // to adopt and nothing to say.
    var agreeing = freshState()
    var agreeingFollow = FollowState(launchArgs: ["--model", "fable"])
    check("choosing the model already running adopts nothing",
          !adoptNativeModelChoice(state: &agreeing, follow: &agreeingFollow,
                                  watcher: watcherAfterScanning(
                                      modelCommandLines(at: 30, effort: nil)
                                          + answeredTurn(askedAt: 50, servedAt: 60,
                                                         by: "claude-fable-5", id: "agree")
                                          + nextTurnOpens(at: 80)),
                                  primaryModel: "fable", launchArgs: ["--model", "fable"], log: testAuditLog))
    // An effort the line did not name leaves that axis alone rather than resetting it - the same
    // thing `tally model <model>` with no effort means.
    var effortless = freshState()
    var effortlessFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "max"])
    _ = adoptNativeModelChoice(state: &effortless, follow: &effortlessFollow,
                               watcher: watcherAfterScanning(
                                   modelCommandLines(at: 30, effort: nil)
                                       + answeredTurn(askedAt: 50, servedAt: 60,
                                                      by: "claude-opus-4-8", id: "eff")
                                       + nextTurnOpens(at: 80)),
                               primaryModel: "fable",
                               launchArgs: ["--model", "fable", "--effort", "max"], log: testAuditLog)
    check("a choice that named no effort pins only the model",
          effortless.pin == SessionModelPin(model: "claude-opus-4-8", effort: nil))
    check("…and the baseline keeps the effort the command line still carries",
          effortlessFollow.followedEffort == "max")

    // MARK: - 35c1. The anchor's shape matrix (T1-T14)

    // One fixture per row of the design's walk-through table. They exist because every rule this
    // feature has had was refuted by a shape nobody had written a fixture for: the user side of a
    // transcript has at least fourteen of them and three families of slash command are byte-for-byte
    // identical at the invocation. The anchor is on the assistant side now, so what these assert is
    // that no user-side shape can reach it - and that every way a real request can be made still
    // does.

    /// Another command entirely: same record shape as `/model`, no model request behind it (the
    /// `/effort` family). T1's whole point is that this used to be read as "the next prompt".
    func otherCommandLines(_ name: String, at offset: TimeInterval) -> [String] {
        [#"{"type":"user","isSidechain":false,"uuid":"u-cmd-\#(name)","timestamp":"\#(stamp(offset))","message":{"role":"user","content":"<command-message>\#(name)</command-message>\n<command-name>/\#(name)</command-name>"}}"#,
         #"{"type":"user","isSidechain":false,"uuid":"u-out-\#(name)","timestamp":"\#(stamp(offset))","message":{"role":"user","content":"<local-command-stdout>done</local-command-stdout>"}}"#]
    }
    /// A user event with a shape flag on it, used for the rows that turn on one field.
    func flaggedUserLine(_ offset: TimeInterval, uuid: String, extra: String,
                         content: String = "\"go on\"") -> String {
        #"{"type":"user","isSidechain":false,"uuid":"\#(uuid)",\#(extra)"timestamp":"\#(stamp(offset))","message":{"role":"user","content":\#(content)}}"#
    }

    // T1 - the case codex reproduced: /model, then /effort, then the tail of the turn that was
    // already running, then a real prompt. The tail must not answer; the real turn must.
    let t1 = watcherAfterScanning(
        answeredTurn(askedAt: 5, servedAt: 10, by: "claude-fable-5", id: "t1old")
            + modelCommandLines(at: 30, effort: "xhigh")
            + otherCommandLines("effort", at: 40)
            + tailLines(of: "t1old", resultAt: 45, servedAt: 50, by: "claude-fable-5", id: "t1tail")
            + answeredTurn(askedAt: 60, servedAt: 70, by: "claude-opus-4-8", id: "t1new")
            + nextTurnOpens(at: 90, id: "t1end"))
    check("T1 another command in between answers nothing",
          t1.modelConfirmation?.at == launch.addingTimeInterval(70))
    check("T1 …and the tail of the turn that was running is not the answer either",
          t1.modelConfirmation?.model == "claude-opus-4-8")
    // …nor is it a LOST anchor. The canary is about a chain that will not resolve, which is what a
    // format drift looks like; a turn that resolved and simply began too early is the machinery
    // working. Counting those reported drift on ordinary sessions (gate review, 2026-08-07).
    check("T1 …and an old turn's tail is not reported as a lost anchor",
          t1.unanchoredServed == 0 && !t1.anchorLossReported)

    // T2 - /compact writes a summary as a user event with no promptSource. It starts no request, and
    // it is not somebody coming back either (P3).
    let t2 = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + otherCommandLines("compact", at: 40)
        + [flaggedUserLine(45, uuid: "u-sum", extra: #""isCompactSummary":true,"#)]
        + answeredTurn(askedAt: 60, servedAt: 70, by: "claude-opus-4-8", id: "t2")
        + nextTurnOpens(at: 90, id: "t2end"))
    check("T2 the turn after a compaction is the answer",
          t2.modelConfirmation?.at == launch.addingTimeInterval(70))
    // Asserted on its own rather than off the fixture above: what matters is that the summary never
    // counts, and reading that off a sequence containing real prompts only proves the last one won.
    check("T2 …and an auto-compact summary is not the person coming back",
          watcherAfterScanning([flaggedUserLine(45, uuid: "u-only-sum",
                                                extra: #""isCompactSummary":true,"#)])
              .lastUserTurnAt == nil)

    // T3 - /tally-model is intercepted by a hook: the reply is `<synthetic>` and no request runs.
    let t3 = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + otherCommandLines("tally-model", at: 40)
        + [servedLine("<synthetic>", at: 45, uuid: "a-syn", parent: "u-cmd-tally-model")]
        + answeredTurn(askedAt: 60, servedAt: 70, by: "claude-opus-4-8", id: "t3")
        + nextTurnOpens(at: 90, id: "t3end"))
    check("T3 a synthetic reply answers nothing",
          t3.modelConfirmation?.at == launch.addingTimeInterval(70))

    // T4 - a second /model resets the question; the turn between the two belongs to neither.
    let t4 = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + answeredTurn(askedAt: 40, servedAt: 50, by: "claude-opus-4-8", id: "t4a")
        + modelCommandLines(at: 60, effort: nil)
        + answeredTurn(askedAt: 70, servedAt: 80, by: "claude-haiku-4-5", id: "t4b")
        + nextTurnOpens(at: 100, id: "t4end"))
    check("T4 the newer command is answered by the turn that follows IT",
          t4.modelConfirmation?.at == launch.addingTimeInterval(80)
              && t4.modelConfirmation?.model == "claude-haiku-4-5")

    // T5 - a skill command's expansion is a meta user event, and it DOES reach the model.
    let t5 = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + otherCommandLines("commit", at: 40)
        + [flaggedUserLine(41, uuid: "u-exp", extra: #""isMeta":true,"#,
                           content: #"[{"type":"text","text":"expanded"}]"#),
           servedLine("claude-opus-4-8", at: 50, uuid: "a-exp", parent: "u-exp")]
        + nextTurnOpens(at: 80, id: "t5end"))
    check("T5 a skill expansion roots a real turn, so its reply is the answer",
          t5.modelConfirmation?.at == launch.addingTimeInterval(50))

    // T6 - a task notification wakes a real turn. Not the person (L1 untouched), but a real request
    // (L2 root), and its reply reports what the session is actually running.
    let t6 = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + [flaggedUserLine(40, uuid: "u-wake", extra: #""promptSource":"system","#),
           servedLine("claude-opus-4-8", at: 50, uuid: "a-wake", parent: "u-wake")]
        + nextTurnOpens(at: 80, id: "t6end"))
    check("T6 a woken turn answers the command", t6.modelConfirmation?.at == launch.addingTimeInterval(50))
    // On its own, for the same reason as T2: a notification is not the person, whatever else the
    // transcript happens to contain. (A `/model` the user typed IS the person acting, deliberately -
    // which is why the fixture above cannot answer this question.)
    check("T6 …without counting as the person coming back",
          watcherAfterScanning([flaggedUserLine(40, uuid: "u-only-wake",
                                                extra: #""promptSource":"system","#)])
              .lastUserTurnAt == nil)

    // T7 - a prompt typed during the previous turn and sent after it.
    let t7 = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + [flaggedUserLine(40, uuid: "u-q", extra: #""promptSource":"queued","#),
           servedLine("claude-opus-4-8", at: 50, uuid: "a-q", parent: "u-q")]
        + nextTurnOpens(at: 80, id: "t7end"))
    check("T7 a queued prompt's reply answers the command",
          t7.modelConfirmation?.at == launch.addingTimeInterval(50))

    // T8 - a tool_result carrying the tag as CONTENT. Reading tally's own source inside a supervised
    // session produces exactly this, and it used to raise a phantom command (P2).
    let t8 = watcherAfterScanning([
        #"{"parentUuid":"a-t8","type":"user","isSidechain":false,"uuid":"t-t8","timestamp":"\#(stamp(30))","message":{"role":"user","content":[{"type":"tool_result","content":"let tag = \"<command-name>/model</command-name>\""}]}}"#])
    check("T8 a tool_result quoting the tag is not a command", t8.lastModelCommandAt == nil)

    // T9 - the user interrupts a running turn; the continuation is a NEW request and answers.
    let t9 = watcherAfterScanning(
        answeredTurn(askedAt: 5, servedAt: 10, by: "claude-fable-5", id: "t9old")
            + modelCommandLines(at: 30, effort: nil)
            + [userLine(40, uuid: "u-int", text: "actually, stop"),
               servedLine("claude-opus-4-8", at: 50, uuid: "a-int", parent: "u-int")]
            + nextTurnOpens(at: 80, id: "t9end"))
    check("T9 an interruption's continuation is the answer",
          t9.modelConfirmation?.at == launch.addingTimeInterval(50))

    // T10 - a resumed conversation replays all of it, command and answer alike.
    let t10 = watcherAfterScanning(modelCommandLines(at: -3600, effort: "xhigh")
        + answeredTurn(askedAt: -3500, servedAt: -3400, by: "claude-opus-4-8", id: "t10"))
    check("T10 a replayed command and its replayed answer are both nothing",
          t10.lastModelCommandAt == nil && t10.modelConfirmation == nil)

    // T11 - P5: the first fresh turn is served by the model the API had already fallen onto. Adopting
    // it would make the fallback what this session is EXPECTED to run, which is the one thing that
    // stops the rescue from ever seeing a difference.
    let refusal = #"{"parentUuid":"u-t11a","isSidechain":false,"type":"system","subtype":"model_refusal_fallback","originalModel":"claude-opus-4-8","fallbackModel":"claude-haiku-4-5","apiRefusalCategory":"cyber","uuid":"f-1","timestamp":"\#(stamp(45))"}"#
    let t11 = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + [userLine(40, uuid: "u-t11a", text: "go on"), refusal,
           servedLine("claude-haiku-4-5", at: 50, uuid: "a-t11a", parent: "u-t11a")]
        + answeredTurn(askedAt: 60, servedAt: 70, by: "claude-opus-4-8", id: "t11b")
        + nextTurnOpens(at: 100, id: "t11end"))
    check("T11 a turn the API fell back on does not answer the command",
          t11.modelConfirmation?.model == "claude-opus-4-8")
    check("T11 …the answer waits for the next turn instead",
          t11.modelConfirmation?.at == launch.addingTimeInterval(70))

    // T11b - THE REAL WRITE ORDER, which is what T11's fixture got wrong: Claude Code writes the
    // assistant records of a fallback-served turn FIRST and the `model_refusal_fallback` system
    // record AFTER them. A candidate decided when it arrives therefore reads the fallback before the
    // evidence that it was one (gate review, 2026-08-07). Holding it until the turn is over is what
    // both orders work.
    let lateFlag = #"{"parentUuid":"u-t11c","isSidechain":false,"type":"system","subtype":"model_refusal_fallback","originalModel":"claude-opus-4-8","fallbackModel":"claude-haiku-4-5","apiRefusalCategory":"cyber","uuid":"f-late","timestamp":"\#(stamp(55))"}"#
    let t11c = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + [userLine(40, uuid: "u-t11c", text: "go on"),
           servedLine("claude-haiku-4-5", at: 50, uuid: "a-t11c", parent: "u-t11c"),
           lateFlag]
        + answeredTurn(askedAt: 60, servedAt: 70, by: "claude-opus-4-8", id: "t11d")
        + nextTurnOpens(at: 100, id: "t11cend"))
    check("T11b a flag written AFTER the turn it explains still disqualifies that turn",
          t11c.modelConfirmation?.model == "claude-opus-4-8"
              && t11c.modelConfirmation?.at == launch.addingTimeInterval(70))

    // T11c - the ordinary case the holding must not break: no flag ever comes, and the candidate is
    // settled by the next turn opening. Late by one turn, never absent.
    let noFlag = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + answeredTurn(askedAt: 40, servedAt: 50, by: "claude-opus-4-8", id: "t11e"))
    check("T11c a candidate with no next turn behind it is still held",
          noFlag.modelConfirmation == nil && noFlag.pendingConfirmation?.at == launch.addingTimeInterval(50))
    let settledByNext = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + answeredTurn(askedAt: 40, servedAt: 50, by: "claude-opus-4-8", id: "t11f")
        + nextTurnOpens(at: 80, id: "t11fend"))
    check("T11c …and the next turn opening settles it, flag or no flag",
          settledByNext.modelConfirmation?.at == launch.addingTimeInterval(50)
              && settledByNext.pendingConfirmation == nil)

    // T11d - the canary is about a LOST anchor, not about a deliberate wait: a fallback turn writing
    // more than a handful of assistant records used to report a format drift that had not happened.
    let chatty = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + [userLine(40, uuid: "u-chat", text: "go on")]
        + (1 ... unanchoredConfirmationLimit + 2).map { i in
            servedLine("claude-haiku-4-5", at: 40 + Double(i),
                       uuid: "a-chat-\(i)", parent: "u-chat")
        }, sink: testAuditLog)
    check("T11d a resolved turn never counts against the canary, however many records it writes",
          chatty.unanchoredServed == 0 && !chatty.anchorLossReported)

    // T15 - THE CLOCK CANNOT BE TRUSTED. A transcript's stamps are not monotonic: around a
    // compaction this machine's corpus has a command record stamped two minutes EARLIER than the
    // summary written before it. Compared by time, such a command reads as older than the turn that
    // was already running when it was typed, and that turn's tail qualifies as the answer - the
    // failure the whole anchor exists to prevent, re-entered through the clock. Position is what the
    // scan compares, so the deflated stamp changes nothing.
    let deflated = watcherAfterScanning(
        // The turn already running, stamped LATER than the command that follows it in the file.
        answeredTurn(askedAt: 100, servedAt: 110, by: "claude-fable-5", id: "t15old")
            + modelCommandLines(at: 30, effort: nil)
            + tailLines(of: "t15old", resultAt: 120, servedAt: 130, by: "claude-fable-5",
                        id: "t15tail")
            + answeredTurn(askedAt: 140, servedAt: 150, by: "claude-opus-4-8", id: "t15new")
            + nextTurnOpens(at: 180, id: "t15end"))
    check("T15 a turn written before the command is out, whatever its stamp says",
          deflated.modelConfirmation?.model == "claude-opus-4-8")
    check("T15 …and the answer is the turn that was written after it",
          deflated.modelConfirmation?.at == launch.addingTimeInterval(150))

    // T16 - two fallbacks inside one command's window. The newest flag names a model that has
    // nothing to do with the candidate, and comparing against only that one lets the candidate the
    // EARLIER flag disqualifies straight through (gate review, 2026-08-07).
    func refusalLine(_ offset: TimeInterval, to model: String, uuid: String) -> String {
        #"{"isSidechain":false,"type":"system","subtype":"model_refusal_fallback","originalModel":"claude-opus-4-8","fallbackModel":"\#(model)","apiRefusalCategory":"cyber","uuid":"\#(uuid)","timestamp":"\#(stamp(offset))"}"#
    }
    let twoFlags = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + [userLine(40, uuid: "u-t16", text: "go on"),
           servedLine("claude-haiku-4-5", at: 50, uuid: "a-t16", parent: "u-t16"),
           refusalLine(55, to: "claude-haiku-4-5", uuid: "f-first"),
           refusalLine(58, to: "claude-sonnet-4-5", uuid: "f-second")]
        + answeredTurn(askedAt: 60, servedAt: 70, by: "claude-opus-4-8", id: "t16b")
        + nextTurnOpens(at: 100, id: "t16end"))
    check("T16 an earlier flag in the window still disqualifies the turn it explains",
          twoFlags.modelConfirmation?.model == "claude-opus-4-8"
              && twoFlags.modelConfirmation?.at == launch.addingTimeInterval(70))

    // T17 - the canary's three EXPECTED ways to fail to resolve, which are not what it watches for.
    // (a) a turn longer than the map: its own root is evicted, so everything after it resolves to
    // nothing - correct, and expected.
    let longTurn = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + [userLine(40, uuid: "u-long", text: "go on")]
        + (1 ... turnRootCapacity + 8).flatMap { i -> [String] in
            let parent = i == 1 ? "u-long" : "a-long-\(i - 1)"
            let lines = [#"{"parentUuid":"\#(parent)","type":"user","uuid":"t-long-\#(i)","isSidechain":false,"timestamp":"\#(stamp(40 + Double(i) / 100))","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
             servedLine("claude-opus-4-8", at: 40 + Double(i) / 100 + 0.005,
                        uuid: "a-long-\(i)", parent: "t-long-\(i)")]
            return lines
        }, sink: testAuditLog)
    check("T17a a turn longer than the map evicts entries",
          longTurn.turnRoots.evicted > 0)
    // …and resolution survives it, which is worth knowing precisely: each entry stores the ROOT it
    // resolved to rather than a pointer to walk, so evicting the root does not orphan the events
    // behind it. Eviction only bites when a line's DIRECT parent is more than the capacity behind
    // it, which a linear turn never does. The canary's guard against it is cheap insurance for the
    // branching case rather than the everyday one.
    check("T17a …without losing the anchor, and so without reporting one lost",
          longTurn.unanchoredServed == 0 && !longTurn.anchorLossReported)

    // T18 - THE PAUSE. A user chooses a model, reads the answer, and stops. No next turn ever opens,
    // so a candidate held for one waits forever - and while it waits the session's expected model is
    // still the old one, which is exactly the difference the degradation rescue acts on: it would
    // move the conversation to another account to restore the model the user just chose to leave
    // (decision review, 2026-08-07). Silence settles it instead.
    let paused = ForkFixture("model-pause")
    func pausedLines() -> [String] {
        [#"{"type":"user","isSidechain":false,"uuid":"u-p-cmd","timestamp":"\#(paused.stamp(5))","message":{"role":"user","content":"<command-message>model</command-message>\n<command-name>/model</command-name>"}}"#,
         #"{"type":"user","isSidechain":false,"uuid":"u-p-ask","timestamp":"\#(paused.stamp(10))","message":{"role":"user","content":"go on"}}"#,
         #"{"parentUuid":"u-p-ask","isSidechain":false,"type":"assistant","uuid":"a-p-ans","timestamp":"\#(paused.stamp(20))","message":{"model":"claude-opus-4-8"}}"#]
    }
    // Written as of ten minutes ago, which is what "they walked away" looks like on disk.
    paused.write("only.jsonl", pausedLines(), born: -300, wrote: 0)
    var pausedWatcher = paused.watcher(pinnedTo: "only")
    _ = pausedWatcher.sawCapHit()
    check("T18 the answer is held when it arrives, as always",
          pausedWatcher.pendingConfirmation != nil && pausedWatcher.modelConfirmation == nil)
    // The next tick reads nothing new, and the file has been silent well past the bar.
    _ = pausedWatcher.sawCapHit()
    check("T18 …and silence settles it, so a session nobody types into is still adopted",
          pausedWatcher.modelConfirmation?.model == "claude-opus-4-8")
    check("T18 …leaving nothing held", pausedWatcher.pendingConfirmation == nil)
    try? FileManager.default.removeItem(at: paused.dir)

    // …and the ordering that makes the settlement soon enough: the scan that settles runs at the top
    // of the tick, before anything reasons about a difference between the expected model and the
    // serving one. Asserted against the source, because it is the loop that guarantees it.
    let loopOrder = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("T18 the supervisor source is readable from here", !loopOrder.isEmpty)
    check("T18 …and the transcript scan runs before the degradation paths it protects", {
        guard let scan = loopOrder.range(of: "observeCapHit("),
              let rescue = loopOrder.range(of: "applyDegradationRescue("),
              let fallback = loopOrder.range(of: "applyFallbackProfile(") else { return false }
        return scan.upperBound < rescue.lowerBound && scan.upperBound < fallback.lowerBound
    }())

    // T20 - the downstream half of T15. The watcher decides on position, so a command record stamped
    // LATER than the turn that answers it still gets an answer - and the adoption must not re-ask
    // the question with the clock, which would leave a confirmation nobody ever adopts and a canary
    // with nothing to report (decision review, 2026-08-07).
    let lateStamp = watcherAfterScanning(modelCommandLines(at: 100, effort: nil)
        + answeredTurn(askedAt: 30, servedAt: 40, by: "claude-opus-4-8", id: "t20")
        + nextTurnOpens(at: 130, id: "t20end"))
    check("T20 the watcher answers a command whose stamp is later than the turn that answers it",
          lateStamp.modelConfirmation?.model == "claude-opus-4-8"
              && lateStamp.modelConfirmation?.at == launch.addingTimeInterval(40))
    var lateState = freshState()
    var lateFollow = FollowState(launchArgs: ["--model", "fable"])
    check("T20 …and the adoption takes it, rather than re-asking with the clock",
          adoptNativeModelChoice(state: &lateState, follow: &lateFollow, watcher: lateStamp,
                                 primaryModel: "fable", launchArgs: ["--model", "fable"],
                                 now: launch.addingTimeInterval(200), log: testAuditLog)
              && lateState.pin.model == "claude-opus-4-8")

    // T21 - THE PAUSE, INTERRUPTED BY A `/clear`. The answer arrives, the user clears, and the new
    // transcript has no turn in it yet - so the watcher is still bound to the old file, that file is
    // quiet by definition, and settling there pins a choice from a conversation that no longer
    // exists. The move itself drops the candidate; the silence must not beat it to the punch
    // (review, 2026-08-07).
    let cleared = ForkFixture("model-cleared")
    cleared.write("only.jsonl", [
        #"{"type":"user","isSidechain":false,"uuid":"u-c-cmd","timestamp":"\#(cleared.stamp(5))","message":{"role":"user","content":"<command-message>model</command-message>\n<command-name>/model</command-name>"}}"#,
        #"{"type":"user","isSidechain":false,"uuid":"u-c-ask","timestamp":"\#(cleared.stamp(10))","message":{"role":"user","content":"go on"}}"#,
        #"{"parentUuid":"u-c-ask","isSidechain":false,"type":"assistant","uuid":"a-c-ans","timestamp":"\#(cleared.stamp(20))","message":{"model":"claude-opus-4-8"}}"#,
    ], born: -300, wrote: 0)
    var clearedWatcher = cleared.watcher(pinnedTo: "only")
    _ = clearedWatcher.sawCapHit()
    check("T21 the answer is held, as it is on any pause",
          clearedWatcher.pendingConfirmation != nil && clearedWatcher.modelConfirmation == nil)
    // `/clear`: a newer transcript with nothing in it yet, so nothing can say whether the
    // conversation moved there. That is exactly what the fork hold is.
    cleared.write("fresh.jsonl", cleared.clearedLines(own: "fresh"), born: 1, wrote: 2)
    _ = clearedWatcher.sawCapHit()
    check("T21 …and the fork is unresolved", clearedWatcher.hasUnresolvedFork)
    check("T21 …so silence settles nothing while it is",
          clearedWatcher.modelConfirmation == nil && clearedWatcher.pendingConfirmation != nil)
    try? FileManager.default.removeItem(at: cleared.dir)

    // T22 - eviction is a property of a LINEAGE, not of one entry. An event that cannot resolve
    // because its parent was evicted leaves its own children unable to resolve too, and reading
    // those as mysteries reported a drift that had not happened: six ordinary descendants of one
    // evicted entry were enough to write the canary line (review, 2026-08-07).
    var lineage = TurnRoots()
    var seq = 0
    func place(_ uuid: String, parent: String?, startsTurn: Bool = false) -> TurnRoot? {
        seq += 1
        return lineage.record(uuid: uuid, parent: parent, startsTurn: startsTurn,
                              at: launch.addingTimeInterval(Double(seq)), seq: seq)
    }
    _ = place("root", parent: nil, startsTurn: true)
    // Fill past the cap so the root itself is dropped, each entry hanging off the one before it.
    var previous = "root"
    for i in 1 ... turnRootCapacity + 1 {
        let id = "fill-\(i)"
        _ = place(id, parent: previous)
        previous = id
    }
    check("T22 the root really was evicted", lineage.wasEvicted("root"))
    // A child of the evicted root cannot resolve - expected - and its own child inherits that.
    check("T22 …a child of it cannot resolve", place("child", parent: "root") == nil)
    check("T22 …and is itself marked gone, so the grandchild is expected too",
          lineage.wasEvicted("child") && lineage.wasEvicted("grandchild") == false)
    check("T22 …which the grandchild then inherits in turn", {
        _ = place("grandchild", parent: "child")
        return lineage.wasEvicted("grandchild")
    }())
    // A parent that was never here at all stays a mystery, which is what the canary is for.
    check("T22 …while a parent nobody ever saw is not excused",
          place("stranger", parent: "never-existed") == nil
              && !lineage.wasEvicted("stranger"))

    // T19 - the canary's eviction exemption has to be about THIS parent. Counting a session as
    // exempt for ever after its first eviction silences the canary on any long conversation, which
    // is where a format drift is most likely to be noticed (decision review, 2026-08-07).
    let afterEviction = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + [userLine(40, uuid: "u-ev", text: "go on")]
        // A turn long enough to push entries out of the map…
        + (1 ... turnRootCapacity + 4).flatMap { i -> [String] in
            let parent = i == 1 ? "u-ev" : "a-ev-\(i - 1)"
            let lines = [#"{"parentUuid":"\#(parent)","type":"user","uuid":"t-ev-\#(i)","isSidechain":false,"timestamp":"\#(stamp(40 + Double(i) / 100))","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
             servedLine("claude-opus-4-8", at: 40 + Double(i) / 100 + 0.005,
                        uuid: "a-ev-\(i)", parent: "t-ev-\(i)")]
            return lines
        }
        // …and then an event whose parent was never in it at all. That one is a symptom.
        + [userLine(200, uuid: "u-ev2", text: "next"),
           servedLine("claude-opus-4-8", at: 210, uuid: "a-ev2", parent: "u-ev2")]
        + modelCommandLines(at: 220, effort: nil)
        + [servedLine("claude-opus-4-8", at: 230, uuid: "a-ghost", parent: "u-never-existed")],
        sink: testAuditLog)
    check("T19 entries really were evicted", afterEviction.turnRoots.evicted > 0)
    check("T19 …and an unrelated unresolved parent is still counted",
          afterEviction.unanchoredServed == 1)

    // T12 - the chain cannot be resolved (the parent was never seen). Fail-safe: nothing is adopted,
    // and the wait continues rather than guessing.
    let t12 = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + [servedLine("claude-opus-4-8", at: 50, uuid: "a-orphan", parent: "u-never-seen")])
    check("T12 an event whose turn cannot be resolved answers nothing",
          t12.modelConfirmation == nil)

    // T13 - the residual the design accepted: a typed prompt whose content OPENS with the tag is
    // indistinguishable from an invocation. Asserted as it stands, so a change is a decision.
    let t13 = watcherAfterScanning([
        flaggedUserLine(30, uuid: "u-quote", extra: "",
                        content: #""<command-name>/model</command-name> is what it writes""#)])
    check("T13 a prompt that opens with the tag is still read as a command (known residual)",
          t13.lastModelCommandAt == launch.addingTimeInterval(30))
    check("T13 …and on its own it adopts nothing, so the cost is a no-op",
          t13.modelConfirmation == nil)

    // T14 - the conversation moves to another file before the command is answered. A uuid names an
    // event inside ONE transcript, so a map carried across the move points at nothing (the fail-safe
    // holds and the wait never ends) or, worse, at a collision. The command itself deliberately
    // survives the move - a model chosen before a `/clear` still applies to what follows.
    let forked = ForkFixture("model-anchor")
    func forkedCommand(_ offset: TimeInterval) -> [String] {
        [#"{"type":"user","isSidechain":false,"uuid":"u-cmd-old","timestamp":"\#(forked.stamp(offset))","message":{"role":"user","content":"<command-message>model</command-message>\n<command-name>/model</command-name>"}}"#]
    }
    func forkedTurn(_ askedAt: TimeInterval, _ servedAt: TimeInterval, id: String,
                    by model: String) -> [String] {
        [#"{"type":"user","isSidechain":false,"uuid":"u-\#(id)","timestamp":"\#(forked.stamp(askedAt))","message":{"role":"user","content":"go on"}}"#,
         #"{"parentUuid":"u-\#(id)","isSidechain":false,"type":"assistant","uuid":"a-\#(id)","timestamp":"\#(forked.stamp(servedAt))","message":{"model":"\#(model)"}}"#]
    }
    // The parent is written as of a moment ago, so the first scan reads it rather than moving off it
    // straight away: an unforced fork check only looks once the bound file has gone quiet.
    forked.write("parent.jsonl", forkedCommand(5), born: -300, wrote: 598)
    forked.write("child.jsonl", [forked.marker(own: "child", launched: "parent", at: 590)]
        + forkedTurn(592, 594, id: "fresh", by: "claude-opus-4-8")
        // …and the turn after it, which is what settles the candidate (`pendingConfirmation`).
        + [#"{"type":"user","isSidechain":false,"uuid":"u-after","timestamp":"\#(forked.stamp(596))","message":{"role":"user","content":"and then?"}}"#],
        born: 599, wrote: 599)
    var moving = forked.watcher(pinnedTo: "parent")
    _ = moving.sawCapHit()
    check("T14 the command is seen in the file it was typed in", moving.lastModelCommandAt != nil)
    let commandSurvives = moving.lastModelCommandAt
    moving.followFork(force: true)
    check("T14 the move drops the turn map with the file it described",
          moving.turnRoots.roots.isEmpty && moving.modelConfirmation == nil)
    check("T14 …while the command itself survives it",
          moving.lastModelCommandAt == commandSurvives)
    _ = moving.sawCapHit()
    check("T14 …and the first real turn in the new file is what answers it",
          moving.modelConfirmation?.model == "claude-opus-4-8")
    // (b) The head of a file this conversation has just moved to: those events hang off parents from
    // a file this map no longer describes, which is expected rather than a symptom.
    check("T14b …and the events at the top of the new file are not counted as lost anchors",
          moving.unanchoredServed == 0 && !moving.anchorLossReported)
    check("T14 …anchored on an event from that file, with nothing left of the old one",
          moving.turnRoots.roots.keys.contains("a-fresh")
              && !moving.turnRoots.roots.keys.contains("u-cmd-old"))
    try? FileManager.default.removeItem(at: forked.dir)

    // THE CANARY. The anchor rests on `parentUuid` chains, which are Claude Code's private format:
    // if their shape drifts, roots stop resolving, the fail-safe holds, and the feature goes quiet.
    // A quiet failure is the one this design chose, so it says so once rather than being swallowed.
    let canary = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + (1 ... unanchoredConfirmationLimit + 1).flatMap { i in
            [servedLine("claude-opus-4-8", at: 40 + Double(i),
                        uuid: "a-lost-\(i)", parent: "u-gone-\(i)")]
        }, sink: testAuditLog)
    check("the canary counts every request served while the command waits",
          canary.unanchoredServed == unanchoredConfirmationLimit + 1)
    check("…and nothing is adopted from any of them", canary.modelConfirmation == nil)

    // MARK: - 35c2. One command, one adoption

    // WITHOUT THIS THE ADOPTION IS A STANDING RULE, not a decision. The `/model` marker lives as
    // long as the child, so every later disagreement between the serving model and the pin still
    // satisfied "a /model happened, and this observation is newer than it" - a genuine quota
    // fallback included. It would be adopted as the user's choice, and the degradation rescue would
    // never fire again for the rest of that child (review of c914b41).
    var consumed = freshState()
    var consumedFollow = FollowState(launchArgs: ["--model", "fable"])
    check("the first adoption is served",
          adoptNativeModelChoice(state: &consumed, follow: &consumedFollow, watcher: typed,
                                 primaryModel: "fable", launchArgs: ["--model", "fable"], log: testAuditLog)
              && consumed.servedModelCommandAt == launch.addingTimeInterval(30))
    // Now a REAL degradation, on the same child: the serving model moves again, and no new /model
    // was typed. This is the rescue's case and it must stay the rescue's case.
    let laterDegradation = watcherAfterScanning(modelCommandLines(at: 30, effort: "xhigh")
        + answeredTurn(askedAt: 50, servedAt: 60, by: "claude-opus-4-8", id: "l1")
        + answeredTurn(askedAt: 80, servedAt: 90, by: "claude-haiku-4-5", id: "l2")
        + nextTurnOpens(at: 110))
    check("a later degradation under the SAME /model is not adopted as a second choice",
          !adoptNativeModelChoice(state: &consumed, follow: &consumedFollow,
                                  watcher: laterDegradation, primaryModel: "claude-opus-4-8",
                                  launchArgs: ["--model", "fable"], log: testAuditLog))
    check("…so the pin still names what the user actually chose",
          consumed.pin.model == "claude-opus-4-8")
    // A genuinely new /model is a new instruction, and is adopted.
    let typedAgain = watcherAfterScanning(modelCommandLines(at: 30, effort: "xhigh")
        + answeredTurn(askedAt: 50, servedAt: 60, by: "claude-opus-4-8", id: "t1")
        + modelCommandLines(at: 90, effort: nil)
        + answeredTurn(askedAt: 110, servedAt: 120, by: "claude-haiku-4-5", id: "t2")
        + nextTurnOpens(at: 150))
    check("a NEWER /model is a new instruction",
          adoptNativeModelChoice(state: &consumed, follow: &consumedFollow, watcher: typedAgain,
                                 primaryModel: "claude-opus-4-8", launchArgs: ["--model", "fable"], log: testAuditLog)
              && consumed.pin.model == "claude-haiku-4-5")

    // A /model that re-picked what was already running changed nothing, but it WAS served, and the
    // stamp belongs to that rather than to whether anything moved. Leaving it unconsumed put the
    // whole child back in the state the stamp exists to prevent: the next real fallback satisfied
    // "a /model happened, newer than the stamp" and was adopted as a choice (review of 62335b8).
    var noop = freshState()
    var noopFollow = FollowState(launchArgs: ["--model", "fable"])
    let repicked = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + answeredTurn(askedAt: 50, servedAt: 60, by: "claude-fable-5", id: "noop")
        + nextTurnOpens(at: 80))
    check("re-picking the model already running adopts nothing",
          !adoptNativeModelChoice(state: &noop, follow: &noopFollow, watcher: repicked,
                                  primaryModel: "fable", launchArgs: ["--model", "fable"], log: testAuditLog))
    check("…but the event is still consumed, because it was still served",
          noop.servedModelCommandAt == launch.addingTimeInterval(30))
    let fallbackAfterNoop = watcherAfterScanning(modelCommandLines(at: 30, effort: nil)
        + answeredTurn(askedAt: 50, servedAt: 60, by: "claude-fable-5", id: "n1")
        + answeredTurn(askedAt: 80, servedAt: 90, by: "claude-haiku-4-5", id: "n2")
        + nextTurnOpens(at: 110))
    check("…so a real fallback after it is left to the rescue, not read as that choice",
          !adoptNativeModelChoice(state: &noop, follow: &noopFollow, watcher: fallbackAfterNoop,
                                  primaryModel: "fable", launchArgs: ["--model", "fable"], log: testAuditLog)
              && !noop.isPinned)

    // MARK: - 35c3. Keeping the model and moving only the depth

    // The picker can leave the model alone and change the effort, and reading "the model still
    // agrees" as "nothing happened" threw the parsed effort away: the child ran xhigh while the
    // next relaunch would put high back (review of c914b41).
    let depthOnly = watcherAfterScanning(modelCommandLines(at: 30, effort: "xhigh")
        + answeredTurn(askedAt: 50, servedAt: 60, by: "claude-fable-5", id: "depth")
        + nextTurnOpens(at: 80))
    var depth = freshState()
    var depthFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "high"])
    check("a /model that kept the model but moved the depth is still adopted",
          adoptNativeModelChoice(state: &depth, follow: &depthFollow, watcher: depthOnly,
                                 primaryModel: "fable",
                                 launchArgs: ["--model", "fable", "--effort", "high"], log: testAuditLog))
    check("…pinning the effort, and leaving the model alone because it did not move",
          depth.pin == SessionModelPin(model: nil, effort: "xhigh"))
    check("…and it is consumed once, so the same event cannot be adopted again",
          !adoptNativeModelChoice(state: &depth, follow: &depthFollow, watcher: depthOnly,
                                  primaryModel: "fable",
                                  launchArgs: ["--model", "fable", "--effort", "high"], log: testAuditLog))
    // Choosing the depth already running is not a change either.
    var sameDepth = freshState()
    var sameDepthFollow = FollowState(launchArgs: ["--model", "fable", "--effort", "xhigh"])
    check("choosing the depth already running adopts nothing",
          !adoptNativeModelChoice(state: &sameDepth, follow: &sameDepthFollow, watcher: depthOnly,
                                  primaryModel: "fable",
                                  launchArgs: ["--model", "fable", "--effort", "xhigh"], log: testAuditLog))

    // MARK: - 35d. What the rest of the tick then believes

    // The pin leads, and that is what stops the rescue: the session runs what was chosen, so the
    // difference the rescue exists to cure no longer exists.
    check("the pin outranks the command line when the tick asks what this session runs",
          sessionPrimaryModel(pin: state.pin, launchArgs: ["--model", "fable"],
                              providerID: "claude", policy: LaunchPolicy()) == "claude-opus-4-8")
    var declaredPolicy = LaunchPolicy()
    declaredPolicy.model = "haiku"
    check("with no pin it is the command line, then the configured default",
          sessionPrimaryModel(pin: SessionModelPin(), launchArgs: ["--model", "fable"],
                              providerID: "claude", policy: declaredPolicy) == "fable"
              && sessionPrimaryModel(pin: SessionModelPin(), launchArgs: [],
                                     providerID: "claude", policy: declaredPolicy) == "haiku")
    // ADOPTION DOES NOT RESTART. The session is already serving the chosen model; a relaunch would
    // interrupt a conversation to arrive where it already is, and that pointless restart is the
    // whole cost of the incident. The argv catches up at the next relaunch something else asks for.
    // Asserted THROUGH THE TICK'S OWN SEQUENCE, not through the adoption alone: the adoption has no
    // plan to write, so testing it by itself cannot tell whether the caller turns the result into a
    // restart. A mutation that made it plan one passed that weaker check silently.
    var plan: RelaunchPlan?
    var replanState = freshState()
    var replanFollow = FollowState(launchArgs: ["--model", "fable"])
    var moves = ManualMoveState(sessionKey: "6001", servedEpoch: 0, dir: dir)
    var switchRecord: PendingSwitchConsumption?
    var modelRecord: PendingModelConsumption?
    var tickPolicy = LaunchPolicy()
    var tickPrimary: String? = "fable"
    var tickWatcher = typed
    applySessionDirectives(plan: &plan, moves: &moves, switchRecord: &switchRecord,
                           model: &replanState, modelRecord: &modelRecord,
                           follow: &replanFollow, following: false, policy: &tickPolicy,
                           steering: true,
                           account: switchAccount("A"), providerID: "claude",
                           launchArgs: ["--model", "fable"], primaryModel: &tickPrimary,
                           quarantine: [:], watcher: &tickWatcher, childAge: 600,
                           keyboardIdle: { _ in true }, modelRequest: { _ in nil },
                           switchRequest: { _ in nil }, log: testAuditLog)
    check("the tick adopts the choice", replanState.pin.model == "claude-opus-4-8")
    check("…and plans NO relaunch for it: the session already serves that model",
          plan == nil && modelRecord == nil)
    check("…while handing the rest of the tick the model it now runs",
          tickPrimary == "claude-opus-4-8")
    // And with the pin in hand the rescue no longer sees a degradation. Asserted through the real
    // function: its first guard is what returns here, so it never reaches a snapshot read.
    var rescued = typed
    applyDegradationRescue(plan: &plan, watcher: &rescued, driftActive: false,
                           policy: LaunchPolicy(), account: switchAccount("A"),
                           providerID: "claude",
                           primaryModel: sessionPrimaryModel(pin: replanState.pin,
                                                             launchArgs: ["--model", "fable"],
                                                             providerID: "claude",
                                                             policy: LaunchPolicy()),
                           quarantine: [:], steering: true, fuseAllows: true)
    check("and the degradation rescue no longer has anything to cure", plan == nil)

    // MARK: - 35d2. The pin reaches the next relaunch's command line

    // The adoption deliberately does not relaunch, which leaves the argv saying what the session
    // was LAUNCHED with. So any later plan carrying no axes of its own - a reload, a switch, a cap
    // handoff, a self-update - would respawn the child on the old pair while `sessionPrimaryModel`
    // reported the new one, and the two would disagree until something noticed (review of c914b41).
    // Closed at the one place every relaunch's args pass through, rather than in each mover.
    let adopted = SessionModelPin(model: "claude-opus-4-8", effort: "xhigh")
    let reload = RelaunchPlan(target: switchAccount("A"), reason: "reload", countsFuse: false)
    check("a plan naming no axes carries the adopted pair onto the new command line",
          planLaunchArgs(["--model", "fable", "--effort", "high", "--continue"], plan: reload,
                         sessionPin: adopted)
              == ["--continue", "--model", "claude-opus-4-8", "--effort", "xhigh"])
    check("…and with no pin at all it leaves the args exactly as they were",
          planLaunchArgs(["--model", "fable", "--continue"], plan: reload)
              == ["--model", "fable", "--continue"])
    // An effort-only pin keeps the model the args already carry: everything below strips both
    // flags before injecting, so the axis nobody pinned has to be re-named from the args.
    check("an effort-only pin keeps the model the command line already had",
          planLaunchArgs(["--model", "fable", "--effort", "high"], plan: reload,
                         sessionPin: SessionModelPin(effort: "xhigh"))
              == ["--model", "fable", "--effort", "xhigh"])
    check("…and the injected pair lands where a flag is READ, before any bare marker",
          planLaunchArgs(["--model", "fable", "--", "write a haiku"], plan: reload,
                         sessionPin: adopted)
              == ["--model", "claude-opus-4-8", "--effort", "xhigh", "--", "write a haiku"])
    // A plan that names its own axes is the more specific instruction and wins; a release is an
    // instruction to take them off, and the pin must not put them back.
    let follows = RelaunchPlan(target: switchAccount("A"), reason: "follow", countsFuse: false,
                               model: "haiku", effort: "low")
    check("a plan that names its own pair outranks the pin",
          planLaunchArgs(["--model", "fable"], plan: follows, sessionPin: adopted)
              == ["--model", "haiku", "--effort", "low"])
    var release = RelaunchPlan(target: switchAccount("A"), reason: "model", countsFuse: false)
    release.clearsAxes = true
    check("a release takes the axes off rather than having the pin put them back",
          planLaunchArgs(["--model", "fable", "--continue"], plan: release, sessionPin: adopted)
              == ["--continue"])

    // A REAL DEGRADATION IS UNTOUCHED. No /model event, so nothing is adopted, the primary stays
    // what it was, and the difference the rescue acts on is still there.
    let degraded = watcherAfterScanning([servedLine("claude-opus-4-8", at: 60)])
    var untouched = freshState()
    var untouchedFollow = FollowState(launchArgs: ["--model", "fable"])
    check("a serving model nobody asked for is not adopted",
          !adoptNativeModelChoice(state: &untouched, follow: &untouchedFollow, watcher: degraded,
                                  primaryModel: "fable", launchArgs: ["--model", "fable"], log: testAuditLog))
    check("…so the session is still understood to run what it was launched with",
          !untouched.isPinned
              && sessionPrimaryModel(pin: untouched.pin, launchArgs: ["--model", "fable"],
                                     providerID: "claude", policy: LaunchPolicy()) == "fable")
    check("…which is exactly the difference the rescue reads",
          degraded.lastModel?.contains("fable") == false)
    try? FileManager.default.removeItem(at: dir)
}
