import Foundation

// PICKING THE WORK BACK UP AFTER A MOVE THE CONVERSATION MADE ITSELF (TallyCLI/SelfSwitchResume.swift):
// which `tally account` relaunches arm the cap resume station, and that the station then treats the
// arm exactly as it treats a wall's.
//
// THE INCIDENT (2026-09-26, session fcaed6da, pid 72295): the agent ran `tally account "Claude 3"`
// in a Bash tool call, the supervisor moved the session a second later, and the resumed window sat
// for 7 minutes 27 seconds until another session typed "carry on" into it. T4 replays that
// transcript's structure; every refusal below is a line NOT typed, the direction this fails in.

func runSelfSwitchResumeChecks() {
    func at(_ iso: String) -> Date { parseISO(iso)! }
    func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object,
                                               options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
    func toolUse(_ id: String, _ time: String, name: String = "Bash",
                 sidechain: Bool = false) -> String {
        json(["type": "assistant", "isSidechain": sidechain, "timestamp": time,
              "message": ["role": "assistant",
                          "content": [["type": "tool_use", "id": id, "name": name,
                                       "input": [String: Any]()]]]])
    }
    func toolResult(_ id: String, _ time: String) -> String {
        json(["type": "user", "isSidechain": false, "timestamp": time,
              "message": ["role": "user",
                          "content": [["type": "tool_result", "tool_use_id": id,
                                       "content": "ok"]]]])
    }
    func prompt(_ text: String, _ time: String, meta: Bool = false,
                extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["type": "user", "isSidechain": false, "timestamp": time,
                                     "promptSource": "typed",
                                     "message": ["role": "user", "content": text]]
        if meta { object["isMeta"] = true }
        for (key, value) in extra { object[key] = value }
        return json(object)
    }
    func command(_ name: String, args: String, _ time: String, messageFirst: Bool = false) -> String {
        let nameTag = "<command-name>/\(name)</command-name>"
        let messageTag = "<command-message>\(name)</command-message>"
        let argsTag = "<command-args>\(args)</command-args>"
        return prompt((messageFirst ? [messageTag, nameTag, argsTag] : [nameTag, messageTag, argsTag])
                          .joined(separator: "\n"), time)
    }
    func tail(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    let requested = "2026-09-26T11:05:15.900Z"
    let requestedAt = at(requested)
    func inside(_ lines: [String], _ when: Date = requestedAt) -> Bool {
        switchIssuedInsideTurn(requestedAt: when, tail: tail(lines))
    }

    // MARK: - T3. The turn test

    let wrapped = [toolUse("t1", "2026-09-26T11:05:15.705Z"), toolResult("t1", "2026-09-26T11:05:15.970Z")]
    check("a request written between a tool call and its result was written inside a turn",
          inside(wrapped))
    check("…one written before the call opened was not",
          !inside(wrapped, at("2026-09-26T11:05:15.600Z")))
    check("…nor one written after its result came back",
          !inside(wrapped, at("2026-09-26T11:05:16.000Z")))
    check("a call that has not returned yet still holds the request",
          inside([toolUse("t1", "2026-09-26T11:05:15.705Z")]))
    check("a subagent's call around the request is not this conversation's turn",
          !inside([toolUse("t1", "2026-09-26T11:05:15.705Z", sidechain: true)]))
    check("a `!` line runs no tool call, so a person's shell escape is not a turn",
          !inside([prompt("<bash-input>tally account Claude 3</bash-input>",
                          "2026-09-26T11:05:15.800Z")]))
    let tallyFallback = [prompt("x", "2026-09-26T11:04:00.000Z")]
    check("a person's `/tally` the agent then answered with `tally account` is theirs",
          !inside(tallyFallback + [command("tally", args: "Claude 3", "2026-09-26T11:05:10.000Z"),
                                   prompt("expanded command file", "2026-09-26T11:05:10.100Z",
                                          meta: true)] + wrapped))
    check("…whichever order the command's tags come in",
          !inside([command("tally", args: "Claude 3", "2026-09-26T11:05:10.000Z",
                           messageFirst: true)] + wrapped))
    check("a `/tally` a person said something after no longer decides the turn",
          inside([command("tally", args: "Claude 3", "2026-09-26T11:04:10.000Z"),
                  prompt("carry on with the refactor", "2026-09-26T11:05:00.000Z")] + wrapped))
    check("an empty tail, or one that will not parse, says no",
          !inside([]) && !inside(["{not json", "\"half\":"]))

    // MARK: - T4. The incident, replayed

    let incident = tail([
        command("clear", args: "", "2026-09-26T11:03:01.927Z"),
        prompt("Another Claude session sent a message", "2026-09-26T11:03:02.589Z", meta: true),
        toolUse("skill", "2026-09-26T11:05:00.978Z", name: "Skill"),
        prompt("<!-- tally-command v24 --> run tally account", "2026-09-26T11:05:00.986Z",
               meta: true, extra: ["sourceToolUseID": "skill"]),
        toolResult("skill", "2026-09-26T11:05:01.019Z"),
        toolUse("bash", "2026-09-26T11:05:15.705Z"),
        toolResult("bash", "2026-09-26T11:05:15.970Z"),
    ])
    check("the 2026-09-26 move was the conversation's own, asked from inside a turn",
          switchIssuedInsideTurn(requestedAt: requestedAt, tail: incident))

    // MARK: - T5. Arming

    let wall = requestedAt
    func acct(_ id: String, label: String) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: label, launchHome: "/tmp/\(id)",
                         sessionRemaining: 40, weeklyRemaining: 40, modelRemaining: 0,
                         sessionResetsAt: wall.addingTimeInterval(3 * 3600),
                         weeklyResetsAt: wall.addingTimeInterval(90 * 3600),
                         modelResetsAt: wall.addingTimeInterval(90 * 3600), modelWindowName: "fable",
                         resetCreditsAvailable: nil, isStale: false, error: nil)
    }
    let from = acct("A", label: "Claude 5")
    let to = acct("B", label: "Claude 3")
    let sentence = switchResumeMessage(from: from, to: to)
    let conversation = "fcaed6da-9a59-4726-bd5e-d3625baebb1b"
    let epoch = Int((requestedAt.timeIntervalSince1970 * 1000).rounded())
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-selfswitch-\(UUID().uuidString)")
    func served(_ origin: SwitchOrigin?) -> PendingSwitchConsumption {
        PendingSwitchConsumption(epoch: epoch, sessionPin: "B", dir: dir, origin: origin)
    }
    let log = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-selfswitch-\(UUID().uuidString).log")
    func audit() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
    let lastPerson = at("2026-09-26T11:03:01.927Z")

    @discardableResult
    func arm(_ state: inout CapResumeState, reason: String = "switch", fresh: Bool = false,
             served record: PendingSwitchConsumption? = served(.session),
             tail text: String? = incident, conversation id: String? = conversation,
             userTurnAt: Date? = lastPerson, caughtUp: Bool = true) -> Bool {
        let before = state
        armSwitchResume(&state, pid: "ss-test", log: log, now: wall, reason: reason, fresh: fresh,
                        served: record, tail: { text }, conversation: id, from: from, to: to,
                        userTurnAt: userTurnAt, caughtUp: caughtUp)
        return state != before
    }

    var live = CapResumeState()
    arm(&live)
    check("the incident arms: the offer is keyed on the instant the request was written",
          live.offer?.at == requestedAt && live.offer?.conversation == conversation)
    check("…and carries the switch sentence, not the wall's",
          live.offer?.line == sentence)
    check("…and the arm leaves its audit line with the cause beside the station's word",
          audit().contains("input=cap-resume-armed cause=self-switch conversation=fcaed6da"))

    func ready(_ state: CapResumeState, session: SupervisedState = .idle, dialog: Bool = false,
               userTurnAt: Date? = nil, conversation id: String? = conversation,
               after seconds: TimeInterval = 30) -> CapResumeDecision {
        state.decide(state: session, quiet: .quiet, turnEnded: false, keyboardIdle: true,
                     relaunchPlanned: false, dialogPossible: dialog, draftSuspected: false,
                     caughtUp: true, userTurnAt: userTurnAt, conversation: id,
                     now: requestedAt.addingTimeInterval(seconds))
    }
    check("the new child, idle and in the same conversation, gets the line typed",
          ready(live) == .type(sentence))

    let linesBefore = audit()
    var untouched: [(String, Bool)] = []
    func refuses(_ name: String, _ body: (inout CapResumeState) -> Bool) {
        var state = CapResumeState()
        untouched.append((name, !body(&state) && state == CapResumeState()))
    }
    refuses("a pin move") { arm(&$0, reason: "pin") }
    refuses("a cap handoff through this door") { arm(&$0, reason: "cap") }
    refuses("a shell's request") { arm(&$0, served: served(.shell)) }
    refuses("a prompt hook's request") { arm(&$0, served: served(.promptHook)) }
    refuses("a picker's request") { arm(&$0, served: served(.picker)) }
    refuses("a request with no writer") { arm(&$0, served: served(nil)) }
    refuses("no request served") { arm(&$0, served: nil) }
    refuses("an unreadable tail") { arm(&$0, tail: nil) }
    refuses("a tail with no call around the request") {
        arm(&$0, tail: tail([prompt("<bash-input>tally account</bash-input>",
                                     "2026-09-26T11:05:15.800Z")]))
    }
    refuses("a person who spoke after the command") {
        arm(&$0, userTurnAt: requestedAt.addingTimeInterval(1))
    }
    refuses("a fresh window") { arm(&$0, fresh: true) }
    refuses("a watcher still catching up") { arm(&$0, caughtUp: false) }
    refuses("a window with no conversation id") { arm(&$0, conversation: nil) }
    for (name, held) in untouched { check("no arm: \(name)", held) }
    var nudged = CapResumeState(nudgedAt: at("2026-09-26T11:04:00.000Z"))
    check("no arm: a line already typed that nobody has answered since",
          !arm(&nudged) && nudged == CapResumeState(nudgedAt: at("2026-09-26T11:04:00.000Z")))
    check("…and none of those refusals wrote a line to the log", audit() == linesBefore)

    var twice = CapResumeState()
    arm(&twice)
    let afterOne = audit()
    check("the same request armed twice is still one offer", !arm(&twice))
    check("…and one audit line", audit() == afterOne)
    twice.spend()
    check("a spent offer does not come back for the same request", !arm(&twice) && !twice.isArmed)

    check("a prompt of theirs in the new child drops the offer",
          ready(live, userTurnAt: requestedAt.addingTimeInterval(5)) == .drop(.userTurn))
    check("a dialog holds it", ready(live, session: .blocked, dialog: true) == .hold(.blocked))
    check("a different conversation in the window drops it",
          ready(live, conversation: "some-other-window") == .drop(.otherConversation))
    check("and it expires on the station's own clock",
          ready(live, after: capResumeLife + 1) == .drop(.expired))

    // MARK: - T6. The sentence

    check("the switch line carries the marker that says nobody typed it",
          sentence.hasPrefix(capResumeMarker))
    check("…names both accounts and the command that moved it",
          sentence.contains("Claude 5") && sentence.contains("Claude 3")
              && sentence.contains("tally account"))
    check("…and reads differently from a wall's line", !sentence.contains("hit its usage limit"))
    check("a label carrying a Return never reaches the terminal",
          !switchResumeMessage(from: acct("C", label: "Claude\n5"), to: to).contains("\n"))
    let verbose = acct("D", label: String(repeating: "long name ", count: 40))
    check("an over-long name is cut to the channel's budget",
          switchResumeMessage(from: verbose, to: verbose).utf8.count <= sessionInputMaxBytes)
    check("the sentence carries no em dash", !sentence.contains("\u{2014}"))

    // MARK: - T8. Across a self-update

    check("a switch arm rides the self-update exec intact",
          encodeCapResume(live).flatMap(decodeCapResume) == live)

    // MARK: - T9. Wiring

    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    let capArm = loop.range(of: "armCapResume(&capResume")
    let switchArm = loop.range(of: "armSwitchResume(&capResume")
    let exec = loop.range(of: "execPlannedSelfUpdate(upgrade")
    check("the supervisor arms a self-switch after the cap arm and before the self-update exec",
          capArm != nil && switchArm != nil && exec != nil
              && capArm!.lowerBound < switchArm!.lowerBound
              && switchArm!.lowerBound < exec!.lowerBound)
    let command = (try? String(contentsOfFile: "TallyCLI/SwitchCommand.swift", encoding: .utf8)) ?? ""
    check("`tally account` writes its requests as the session's own",
          command.contains("attemptSwitch(intent, surface: .session)"))
    let picker = (try? String(contentsOfFile: "TallyCLI/MCPPicker.swift", encoding: .utf8)) ?? ""
    check("the native picker writes its requests as the picker's", picker.contains("surface: .picker"))
}
