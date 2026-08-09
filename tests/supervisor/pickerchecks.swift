import Foundation

// The one-step picker: the rows Tally.app draws, and the wait that lets the CLI take an answer from
// a FILE without going deaf to the client on stdin (NativePick.swift, MCPServe.swift).
//
// Every check here is about a property the design named, so each one says which: one step, the
// fallback that makes the whole feature riskless, the client still being served while a panel is up,
// and the pair a list must not be able to draw.

/// A channel whose every answer is scripted, so the wait can be driven turn by turn without an app,
/// a client, or a `~/.tally` to write into.
final class PickChannelDouble {
    var published: [PickRequest] = []
    var discarded: [String] = []
    /// Who holds the claim on each turn, in order; the last value repeats. nil is "nobody".
    var claims: [pid_t?] = [4242]
    /// Which claimants are still alive. Anything absent from here is dead.
    var living: Set<pid_t> = [4242]
    /// Whether the claim is sealed, in order; the last value repeats. What tells a current app from
    /// a copy running since before the seal existed, and a SEQUENCE because the seal lands a moment
    /// after the claim it vouches for, which is a state the wait has to sit through (pickclaimchecks
    /// drives both). Asked only on the laps that found a claimant, exactly as the wait asks it.
    var seals: [Bool] = [true]
    /// What `answer` answers, in order; the last value repeats.
    var answers: [PickAnswer?] = [nil]
    /// What `messageWaiting` answers, in order; the last value repeats.
    var messages: [Bool] = [false]
    /// How far the clock has moved when each turn asks, in order; the last value repeats.
    var elapsed: [TimeInterval] = [0]
    private var claimAsks = 0, sealAsks = 0, answerAsks = 0, messageAsks = 0, clockAsks = 0
    /// How many laps the wait actually took, which is the only way to assert that a reading it is
    /// ALLOWED to act on immediately was not quietly given an extra lap (pickclaimchecks 36c9).
    var laps: Int { claimAsks }
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// How many turns the wait may take before the clock is slammed past every deadline. A test
    /// double that never advances would otherwise hang the suite rather than fail it, and a hang is
    /// the one failure that tells you nothing about what broke.
    private let turnLimit = 200

    private func next<T>(_ values: [T], _ count: inout Int) -> T {
        defer { count += 1 }
        return values[min(count, values.count - 1)]
    }

    var channel: NativePickChannel {
        NativePickChannel(
            publish: { [self] request in published.append(request); return true },
            claimant: { [self] _ in next(claims, &claimAsks) },
            isAlive: { [self] pid in living.contains(pid) },
            sealed: { [self] _, _ in next(seals, &sealAsks) },
            answer: { [self] _ in next(answers, &answerAsks) },
            discard: { [self] id in discarded.append(id) },
            messageWaiting: { [self] _ in next(messages, &messageAsks) },
            now: { [self] in
                let turn = clockAsks
                let offset = next(elapsed, &clockAsks)
                return start.addingTimeInterval(
                    turn > turnLimit ? nativePickDeadlineSeconds + 1 : offset)
            })
    }
}

/// A world whose pickers do nothing but record what they were asked to queue.
func pickWorld(applied: @escaping (SwitchIntent) -> Void = { _ in },
               model: @escaping (ModelIntent) -> Void = { _ in }) -> MCPPickerWorld {
    var world = MCPPickerWorld()
    world.modelStatus = { _ in ModelStatus() }
    world.applyModel = { intent, _ in
        model(intent)
        return ModelAttempt(result: .queued, message: "queued the pair")
    }
    world.fleetRows = { _ in
        ([switchAccount("claude:.claude", label: "Claude"),
          switchAccount("claude:.claude2", label: "Claude 2")],
         [SwitchFleetRow(id: "claude:.claude", label: "Claude", windows: "session 90%",
                         tags: [switchCurrentSessionTag]),
          SwitchFleetRow(id: "claude:.claude2", label: "Claude 2", windows: "session 90%",
                         tags: [switchRecommendedTag])],
         nil)
    }
    world.applyAccount = { intent, _ in
        applied(intent)
        return SwitchAttempt(result: .queued, message: "queued the move")
    }
    return world
}

/// One bare `/tally-account` through the server, with the channel scripted by the caller. Returns
/// what the tool answered with and what the client was told along the way.
func runPick(_ channel: NativePickChannel, tool: PromptHookTool = .pickAccount,
             client: [[String: Any]] = [], world: MCPPickerWorld) -> (decision: String, sent: [[String: Any]]) {
    let script = MCPScriptedConnection(client)
    let server = MCPServer(connection: script.connection, world: world, claudeCodePID: nil,
                           pick: channel)
    server.handle(["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                   "params": ["name": tool.rawValue,
                              "arguments": ["command_name": "tally-account", "command_args": "",
                                            "cwd": "/tmp/work", "session_id": "conv-1"]]])
    let answered = script.sent.first { $0["id"] as? Int == 9 }
    return (mcpDecisionText(answered ?? [:]) ?? "", script.sent)
}

func runPickerChecks() {
    // MARK: - 36a. One step: the answer file ends the wait, and the row IS the decision

    var queued: [SwitchIntent] = []
    let chosen = PickChannelDouble()
    chosen.claims = [4242]
    // Nothing on the first turn, the answer on the second: the wait has to keep looking rather than
    // deciding on the first miss.
    chosen.answers = [nil, PickAnswer(value: "claude:.claude2")]
    let picked = runPick(chosen.channel, world: pickWorld(applied: { queued.append($0) }))
    check("a row that comes back on the answer file ends the wait",
          picked.decision.contains("queued the move"))
    check("…and it is queued BY ID, so a label that merely shares a prefix cannot be landed on",
          queued == [.pinAccount("claude:.claude2")])
    check("…with no form ever raised, which is what makes it one step",
          !picked.sent.contains { $0["method"] as? String == "elicitation/create" })
    check("the request really was published, and taken away again afterwards",
          chosen.published.count == 1 && chosen.discarded == chosen.published.map(\.id))
    check("…carrying the rows the panel draws, one of them marked as where the session is",
          chosen.published.first?.rows.contains { $0.isCurrent } == true)

    // Cancelling is an ANSWER, not a silence: Esc and a click outside both write one, so the wait
    // ends when the person decides rather than at the deadline.
    let cancelled = PickChannelDouble()
    cancelled.answers = [PickAnswer.cancelled]
    let declined = runPick(cancelled.channel, world: pickWorld())
    check("a cancelled pick changes nothing and says so",
          declined.decision.contains(mcpNothingChanged))
    check("…without falling back to a form the person just dismissed",
          !declined.sent.contains { $0["method"] as? String == "elicitation/create" })

    // An answer this build cannot read is a CANCELLATION rather than a guess. Asserted at the
    // contract, because that is where the decision is made.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-pick-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    check("no answer file yet is not an answer", readPickAnswer(id: "abc", dir: dir) == nil)
    try! Data("{not json".utf8).write(to: pickAnswerFile(id: "abc", dir: dir))
    check("an unreadable answer is a cancellation, never a guess at a row",
          readPickAnswer(id: "abc", dir: dir) == .cancelled)
    try! encodePick(PickAnswer(value: "claude:.claude2", effort: "xhigh"))!
        .write(to: pickAnswerFile(id: "abc", dir: dir))
    check("a readable one carries both axes",
          readPickAnswer(id: "abc", dir: dir) == PickAnswer(value: "claude:.claude2",
                                                            effort: "xhigh"))
    check("an id that could name a file outside the directory is refused at both ends",
          !isPickID("../../etc/passwd") && !isPickID("") && isPickID(newPickID()))
    try? FileManager.default.removeItem(at: dir)

    // MARK: - 36b. The fallback, which is what makes this riskless

    // Nobody claims it: Tally.app is not running, or is not going to draw. The person gets the form
    // that shipped before this feature, not an error and not a hang.
    let unclaimed = PickChannelDouble()
    unclaimed.claims = [nil]
    unclaimed.elapsed = [0, 0, nativePickClaimSeconds + 0.1]
    let fellBack = runPick(unclaimed.channel, world: pickWorld())
    check("an unclaimed request falls back to the form",
          fellBack.sent.contains { $0["method"] as? String == "elicitation/create" })
    check("…and the files are cleaned up on the way out", unclaimed.discarded.count == 1)
    // A request that could not even be written falls back the SAME WAY and without waiting: there is
    // nothing to wait for, so the form goes up immediately. `.unavailable` is that shape, and it is
    // also what every other suite here uses so a test can never knock on a running app.
    let unwritable = runPick(.unavailable, world: pickWorld())
    check("a request that could not be published draws the form straight away",
          unwritable.sent.contains { $0["method"] as? String == "elicitation/create" })

    // A panel somebody raised and walked away from: the claim held, the deadline did not.
    let abandoned = PickChannelDouble()
    abandoned.claims = [4242]
    abandoned.elapsed = [0, 0, nativePickDeadlineSeconds + 1]
    let expired = runPick(abandoned.channel, world: pickWorld())
    check("a claimed panel nobody answers expires as nothing chosen",
          expired.decision.contains(mcpNothingChanged))
    check("…and does NOT fall back to a second dialog for a question already on screen",
          !expired.sent.contains { $0["method"] as? String == "elicitation/create" })

    // MARK: - 36c. The client is still served while the panel is up

    // THE STRUCTURAL RULE (MCPServe.swift): the client keeps talking while a pick is outstanding,
    // and a server that reads only for its own answer leaves it waiting with a panel on screen.
    // The elicitation wait had this for free; the native wait has to watch two sources to keep it.
    let busy = PickChannelDouble()
    busy.claims = [4242]
    busy.messages = [true, false]
    busy.answers = [nil, nil, PickAnswer(value: "claude:.claude2")]
    let served = runPick(busy.channel, client: [["jsonrpc": "2.0", "id": 4, "method": "ping"]],
                         world: pickWorld())
    check("a ping that arrives while the panel is open is answered",
          served.sent.contains { $0["id"] as? Int == 4 && $0["result"] != nil })
    check("…and the pick still lands afterwards", served.decision.contains("queued the move"))
    // The client going away mid-panel is a decline: nothing was chosen, and nothing may be queued on
    // a guess.
    let gone = PickChannelDouble()
    gone.claims = [4242]
    gone.messages = [true]
    let hungUp = runPick(gone.channel, client: [], world: pickWorld())
    check("end of input while the panel is open is a decline",
          hungUp.decision.contains(mcpNothingChanged))

    // MARK: - 36c2. A message already in hand is served without asking the descriptor

    // THE DEFECT (review of ee77152): a client that writes several messages in one pipe write leaves
    // them in ONE chunk, the read that takes the first line pulls the rest into user space, and
    // `poll(fd 0)` then says - correctly - that the descriptor is empty. The second message would
    // sit unanswered until the person chose or the wait timed out, which is exactly the deafness
    // this loop exists to prevent. So the wait asks OUR OWN buffer first.
    let holding = PickChannelDouble()
    holding.claims = [4242]
    holding.answers = [nil, nil, PickAnswer(value: "claude:.claude2")]
    // The descriptor NEVER has anything on it: every turn of this wait must come from the buffer.
    holding.messages = [false]
    let script = MCPScriptedConnection([["jsonrpc": "2.0", "id": 4, "method": "ping"]])
    var buffered = MCPConnection(read: script.connection.read, write: script.connection.write)
    var lines = 1
    buffered.buffered = { lines > 0 }
    let readThrough = buffered.read
    buffered.read = { lines -= 1; return readThrough() }
    let bufferedServer = MCPServer(connection: buffered, world: pickWorld(), claudeCodePID: nil,
                                   pick: holding.channel)
    bufferedServer.handle(["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                           "params": ["name": PromptHookTool.pickAccount.rawValue,
                                      "arguments": ["cwd": "/tmp/w", "command_args": ""]]])
    check("a message already in our own buffer is served, though the descriptor is quiet",
          script.sent.contains { $0["id"] as? Int == 4 && $0["result"] != nil })
    check("…and the pick still lands afterwards",
          mcpDecisionText(script.sent.first { $0["id"] as? Int == 9 } ?? [:])?
              .contains("queued the move") == true)

    // The reader that makes it possible, on its own: lines in, lines out, and it can say whether it
    // is holding one. The general path asks nothing else of it.
    let pipe = Pipe()
    let reader = StdioLineReader(descriptor: pipe.fileHandleForReading.fileDescriptor)
    check("nothing buffered before anything is written", !reader.hasCompleteLine)
    // BOTH MESSAGES IN ONE WRITE, which is the shape that produced the defect.
    pipe.fileHandleForWriting.write(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
    check("the first line reads back whole", reader.line() == "{\"a\":1}")
    check("…and the second is now IN HAND, where poll could never have seen it",
          reader.hasCompleteLine)
    check("…and reads back without touching the descriptor again", reader.line() == "{\"b\":2}")
    check("with the buffer drained, nothing is claimed to be waiting", !reader.hasCompleteLine)
    try? pipe.fileHandleForWriting.close()
    check("end of input is nil, exactly as the general path has always read it", reader.line() == nil)

    // MARK: - 36c3. A claim is only worth anything while its holder is alive

    // A claim that was true once is not a claim that is true now: an app that took the request and
    // then died used to hold the wait to its five-minute deadline and answer "nothing changed",
    // when what it owes the person is the form.
    let died = PickChannelDouble()
    died.claims = [4242]
    died.living = []          // claimed by a process that is not there any more
    died.elapsed = [0, 0, nativePickClaimSeconds + 0.1]
    let orphaned = runPick(died.channel, world: pickWorld())
    check("a claim held by a dead process falls back to the form",
          orphaned.sent.contains { $0["method"] as? String == "elicitation/create" })
    // …while a live one is waited on, which is the whole point of telling them apart.
    let watching = PickChannelDouble()
    watching.claims = [4242]
    watching.elapsed = [0, 0, nativePickClaimSeconds + 0.1, nativePickClaimSeconds + 0.2]
    watching.answers = [nil, nil, nil, PickAnswer(value: "claude:.claude2")]
    let waited = runPick(watching.channel, world: pickWorld())
    check("a claim held by a live process is waited on past the claim window",
          waited.decision.contains("queued the move")
              && !waited.sent.contains { $0["method"] as? String == "elicitation/create" })

    // MARK: - 36c4. Two apps cannot claim the same request

    // The knock reaches every listener on the machine, so a release build and a dev build both hear
    // it. The file system decides once; the loser draws nothing.
    let raceDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tally-claim-\(UUID().uuidString)")
    check("the first app to ask gets the claim", takePickClaim(id: "abc", owner: 111, dir: raceDir))
    check("…and the second is refused rather than overwriting it",
          !takePickClaim(id: "abc", owner: 222, dir: raceDir))
    check("…so the claim still names the app that is actually drawing",
          readPickClaim(id: "abc", dir: raceDir) == 111)
    check("an unclaimed request has no claimant at all",
          readPickClaim(id: "nobody", dir: raceDir) == nil)
    try! Data("not a pid\n".utf8).write(to: pickClaimFile(id: "junk", dir: raceDir))
    check("a claim that says nothing usable is nobody, not a wait",
          readPickClaim(id: "junk", dir: raceDir) == nil)
    try? FileManager.default.removeItem(at: raceDir)

    // MARK: - 36d. The pair a list must not be able to draw

    // `auto` hands both axes back, so it cannot carry an effort - the grammar refuses that pair
    // (`modelIntent`). The FORM can still express it, which is a defect somebody hit: fill in auto,
    // fill in an effort, press Accept, be told no. In a one-step list it is not refused, it is
    // undrawable.
    let rows = mcpModelPickRows(ModelStatus())
    let autoRows = rows.filter { $0.value == mcpModelAutoValue }
    check("the list offers exactly one release row", autoRows.count == 1)
    check("…and it carries no effort, so the refused pair cannot be drawn at all",
          autoRows.allSatisfy { $0.effort == nil })
    check("no row in the whole list pairs the release with an effort",
          !rows.contains { $0.value == mcpModelAutoValue && $0.effort != nil })
    // Every other model is offered on its own AND at each depth, which is what makes one click a
    // whole decision rather than the first half of one.
    check("a model is offered on its own, which leaves the depth alone",
          rows.contains { $0.value == "opus" && $0.effort == nil })
    // EXPANDED TO TWO DEPTHS, deliberately: the list is meant to be taken in at a glance, and the
    // whole enumeration would put a scroll in front of every choice. The rest are typed, which the
    // grammar has always accepted (asserted below, because "reachable another way" is the entire
    // justification for not drawing them).
    check("…and at the two depths this surface expands",
          pickerExpandedEfforts.allSatisfy { effort in
              rows.contains { $0.value == "opus" && $0.effort == effort }
          })
    check("…and at no others, so the list stays one screen",
          Set(rows.compactMap(\.effort)) == Set(pickerExpandedEfforts))
    check("a depth the list does not draw is still typeable, which is why it may be left out",
          modelIntent(["opus", "low"]) == .pin(model: "opus", effort: "low")
              && modelIntentProblem(.pin(model: "opus", effort: "low")) == nil)
    check("…and the form fallback still offers every one of them",
          (((mcpModelSchema(models: [], efforts: claudeEffortNames())["properties"]
             as? [String: Any])?[mcpEffortField] as? [String: Any])?["enum"] as? [String])
              == claudeEffortNames())
    check("the release is the last row, where a list of escapes belongs",
          rows.last?.value == mcpModelAutoValue)
    // A SESSION AT A DEPTH THE LIST DOES NOT DRAW still has to have a resting row, or the cursor
    // opens on an unrelated model and the keyboard path starts by scrolling away from where the
    // person already is. The bare row means "leave the depth alone", so in that case it IS where
    // they are.
    func rowsRunning(_ model: String?, _ effort: String?) -> [PickRow] {
        var status = ModelStatus()
        status.observedModel = model
        status.declared = SessionModelPin(model: model, effort: effort)
        return mcpModelPickRows(status)
    }
    let onLow = rowsRunning("opus", "low")
    check("a session at a depth the list does not draw rests on the model's own row",
          onLow.filter(\.isCurrent).map { ($0.value, $0.effort) }.map(\.0) == ["opus"]
              && onLow.first(where: \.isCurrent)?.effort == nil)
    let onHigh = rowsRunning("opus", "high")
    check("…while a session at a depth it does draw rests on that pair",
          onHigh.filter(\.isCurrent).map(\.effort) == ["high"])
    let noDepth = rowsRunning("opus", nil)
    check("…and one whose depth nothing has read yet rests on the model too",
          noDepth.filter(\.isCurrent).allSatisfy { $0.effort == nil })
    check("exactly one row rests, in every one of those",
          [onLow, onHigh, noDepth].allSatisfy { $0.filter(\.isCurrent).count == 1 })
    // The form is unchanged, which is the fallback's whole promise: it still has two fields.
    let schema = mcpModelSchema(models: mcpModelOptions(ModelStatus()), efforts: claudeEffortNames())
    check("the form fallback still asks per axis, exactly as it did",
          (schema["properties"] as? [String: Any])?.count == 2)

    // MARK: - 36e. The account list is one list, drawn two ways

    let accounts = [switchAccount("claude:.claude", label: "Claude"),
                    switchAccount("claude:.claude2", label: "Claude 2")]
    let ranked = switchFleetRows(accounts: accounts, provider: "claude", current: "claude:.claude")
    let accountRows = mcpAccountPickRows(accounts, ranked: ranked)
    let options = mcpAccountOptions(accounts: accounts, ranked: ranked)
    check("the panel and the form offer the same accounts in the same order",
          accountRows.map(\.value) == options.map(\.value))
    check("…the panel getting the label and the windows apart, so it can lay them out",
          accountRows.first?.label == "Claude" && accountRows.first?.detail?.contains("session") == true)
    check("…and the form getting them joined, exactly as before",
          options.first?.label.hasPrefix("Claude  ") == true)
    check("the row the session is on is marked, so the keyboard opens there",
          accountRows.filter(\.isCurrent).map(\.value) == ["claude:.claude"])
    check("the release row is offered last and is on nobody's account",
          accountRows.last?.value == switchAutoRequest && accountRows.last?.tags.isEmpty == true)

    // MARK: - 36e3. The form fallback, end to end, over a real pipe

    // THE FACE THIS ROUND MISSED. Every fallback check above asserts that the form is SENT; none of
    // them carried a reply back through the transport that was rewritten underneath it
    // (`StdioLineReader`). A round trip that stops at "the question went out" cannot see a reader
    // that answers nil, and the incident made that gap worth closing whichever way it had gone.
    let toServer = Pipe()
    let wireReader = StdioLineReader(descriptor: toServer.fileHandleForReading.fileDescriptor)
    // THE REPLY IS LOADED BEFORE THE QUESTION IS ASKED, which is what keeps this test honest under
    // a mutant: a client that only answers when it SEES the form turns "the form was never sent"
    // into a deadlock, and a hanging test says nothing about what broke. The id is the server's
    // first (`tally-elicit-1`), so the reply is already in the pipe whichever way the run goes.
    let accept: [String: Any] = ["jsonrpc": "2.0", "id": "tally-elicit-1",
                                 "result": ["action": "accept",
                                            "content": ["model": "sonnet"]]]
    toServer.fileHandleForWriting.write(try! JSONSerialization.data(withJSONObject: accept))
    toServer.fileHandleForWriting.write(Data("\n".utf8))
    var replies: [[String: Any]] = []
    let wire = MCPConnection(read: { wireReader.line() },
                             write: { line in
                                 if let data = line.data(using: .utf8),
                                    let object = (try? JSONSerialization.jsonObject(with: data))
                                        as? [String: Any] {
                                     replies.append(object)
                                 }
                             },
                             buffered: { wireReader.hasCompleteLine })
    var formQueued: [ModelIntent] = []
    let formServer = MCPServer(connection: wire, world: pickWorld(model: { formQueued.append($0) }),
                               claudeCodePID: nil, pick: .unavailable)
    formServer.handle(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                       "params": ["name": PromptHookTool.pickModel.rawValue,
                                  "arguments": ["cwd": "/tmp/w", "command_args": ""]]])
    check("with no app to draw it, the form goes out over the real transport",
          replies.contains { $0["method"] as? String == "elicitation/create" })
    check("…the reply comes back THROUGH THE NEW READER and is applied",
          formQueued == [ModelIntent.pin(model: "sonnet", effort: nil)])
    check("…and the tool answers with what was queued rather than with a cancellation",
          mcpDecisionText(replies.first { $0["id"] as? Int == 7 } ?? [:])?
              .contains(mcpNothingChanged) == false)
    try? toServer.fileHandleForWriting.close()

    // MARK: - 36f. What a chosen row comes back as

    // One offer, two channels, one answer shape: the callers read `content[mcpModelField]` and do
    // not care which of them filled it in. The rows are the ones the offer was actually built with,
    // because an answer naming a row nobody drew is not a pick (`MCPPickOffer.content`); which
    // SECTION an answer came from is asserted next door, in pickpalettechecks.
    let modelOffer = MCPPickOffer(kind: .model, message: "",
                                  rows: [PickRow(value: "opus", effort: "xhigh",
                                                 label: "opus · xhigh"),
                                         PickRow(value: "opus", label: "opus")],
                                  schema: [:])
    check("a model row answers with the pair it carried",
          modelOffer.content(for: PickAnswer(value: "opus", effort: "xhigh"))
              == ["model": "opus", "effort": "xhigh"])
    check("…and a row with no effort leaves that field ABSENT rather than empty",
          modelOffer.content(for: PickAnswer(value: "opus")) == ["model": "opus"])
    let accountOffer = MCPPickOffer(kind: .account, message: "",
                                    rows: [PickRow(value: "claude:.claude2", label: "Claude 2")],
                                    schema: [:])
    check("an account row answers under the account field",
          accountOffer.content(for: PickAnswer(value: "claude:.claude2"))
              == ["account": "claude:.claude2"])
    check("a cancellation carries nothing at all",
          accountOffer.content(for: .cancelled).isEmpty)
}
