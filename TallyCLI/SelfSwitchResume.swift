import Foundation

// PICKING THE WORK BACK UP AFTER A MOVE THE CONVERSATION MADE ITSELF: the second way into the cap
// resume station (CapResume.swift), which owns every gate on the typing side. This file decides
// only whether a `tally account` relaunch is one it may arm for.
//
// THE INCIDENT (2026-09-26, session fcaed6da, pid 72295). A window opened after a hand-over read
// that its account had 6% of the week left, ran `tally account "Claude 3"` as a tool call, and
// ended its turn. The supervisor moved it 1 second later, exactly as asked, and the resumed window
// sat with an empty composer for 7 minutes 27 seconds until another session typed "carry on" into
// it. The cap handoff had had this last inch since 2026-08-21; a move the session asked for had not.
//
// WHICH MOVES, and the whole rule: one the conversation's own agent asked for from inside a turn.
// A person who moves a session (the panel, `/tally`, `! tally account`, a terminal of their own) is
// there and types next; typing "carry on" at them is typing over them. Three facts decide it, and
// each one that cannot be read answers "no", so every way this is wrong is a line NOT typed:
//
//   1. THE WRITER (`SwitchOrigin`, line 4 of the request): `session` only when `tally account`
//      itself ran in a process whose environment names this session. Hooks and the picker write
//      their own words; a build that writes no fourth line is nil.
//   2. THE TURN (`switchIssuedInsideTurn`): the request's millisecond stamp lies inside a
//      main-chain tool call, between the assistant event that opened it and the result that closed
//      it. A `!` line writes no tool call; a prompt hook runs before any model does.
//   3. NOT A PERSON'S `/tally`: when Tally's hook does not answer `/tally`, the command file tells
//      the agent to run `tally account`, which passes 1 and 2. The newest person input before that
//      tool call being a `/tally*` command record is what tells the two apart.
//
// THE KNOWN OVER-REACH, stated rather than defended against: a person who asks the agent in their
// own words to move the session also passes all three. The line then costs one turn at most, and a
// prompt of theirs in the relaunched child drops it (`CapResumeDrop.userTurn`).

/// How much of the transcript the turn test reads. Larger than the open-turn tail because it is read
/// ONCE per `tally account` relaunch rather than every tick, and the turn that ran the command may
/// have gone on writing after it (the move waits for that turn to end).
let selfSwitchTailBytes = 1 << 22

/// The line typed into a session its own `tally account` has just moved. Same marker as the cap
/// line (grep `auto-resume`), different news: nothing ran out, the session chose to move.
func switchResumeMessage(from: Snapshot.Account, to: Snapshot.Account,
                         limit: Int = sessionInputMaxBytes) -> String {
    let line = "\(capResumeMarker) this session moved from \(quotaKnockName(from)) to "
        + "\(quotaKnockName(to)) because it ran `tally account` itself. "
        + "Carry on with the work that was in progress before the move."
    return keystrokeClipped(line, bytes: limit)
}

/// Whether a request written at `requestedAt` was written from inside one of this conversation's
/// own tool calls, and that call was not answering a person's `/tally` (the header's facts 2 and 3).
///
/// Pure over the tail. Main chain only, like `openToolCall`: a subagent's calls live in their own
/// files, and the call that dispatched it is itself a main-chain call that stays open around it.
/// A line that will not parse is skipped. Timestamps go through `parseISO`, which keeps the
/// fraction: the request and the tool result it precedes are usually inside the same second.
func switchIssuedInsideTurn(requestedAt: Date, tail: String) -> Bool {
    var opened: [String: Date] = [:]       // tool_use id -> the assistant event that opened it
    var returned: [String: Date] = [:]     // tool_use id -> the user event carrying its result
    var people: [(at: Date, tally: Bool)] = []
    for line in tail.split(separator: "\n") {
        guard !line.contains("\"isSidechain\":true"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                  as? [String: Any],
              let at = (object["timestamp"] as? String).flatMap(parseISO) else { continue }
        let blocks = ((object["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        switch object["type"] as? String {
        case "assistant":
            for block in blocks where block["type"] as? String == "tool_use" {
                if let id = block["id"] as? String { opened[id] = at }
            }
        case "user":
            for block in blocks where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String { returned[id] = at }
            }
            if !line.contains("\"tool_result\""), lineIsPersonInput(line) {
                people.append((at, lineIsCommandRecord(line, opening: nativeModelCommandOpening)
                                   && line.contains("<command-name>/tally")))
            }
        default:
            continue
        }
    }
    // The call the request was written inside: opened at or before it, and not yet returned then.
    guard let start = opened.filter({ id, at in
        at <= requestedAt && returned[id].map { $0 >= requestedAt } ?? true
    }).values.max() else { return false }
    // The newest thing a person said before that call opened. A `/tally` there is fact 3.
    let before = people.filter { $0.at <= start }.max { $0.at < $1.at }
    return before?.tally != true
}

/// The line a raised switch arm leaves: `cause=self-switch` beside the station's own armed word, so
/// one grep finds every arm and the field says which way in it came.
func switchResumeArmedLine(pid: String, offer: CapResumeState.Offer, now: Date = Date()) -> String {
    let stamp = ISO8601DateFormatter()
    return "\(stamp.string(from: now)) pid=\(pid) input=\(capResumeArmedOutcome) cause=self-switch "
        + "conversation=\(offer.conversation.prefix(8)) requestedAt=\(stamp.string(from: offer.at))\n"
}

/// Arm after a relaunch, when that relaunch was a `tally account` the conversation ran on itself,
/// and say so when an arm was raised. Every refusal returns without touching the state.
///
/// `tail` is a closure because it reads up to four megabytes of transcript, and only a `switch`
/// relaunch from a `session` writer ever needs it.
///
/// `userTurnAt` is the OLD child's reading: a person who said anything after the command was run
/// is there, and the move is theirs to follow up.
func armSwitchResume(_ state: inout CapResumeState, pid: String, log: URL = sessionInputLog,
                     now: Date = Date(), reason: String, fresh: Bool,
                     served: PendingSwitchConsumption?, tail: () -> String?,
                     conversation: String?, from: Snapshot.Account, to: Snapshot.Account,
                     userTurnAt: Date?, caughtUp: Bool) {
    guard reason == "switch", let served, served.origin == .session else { return }
    let requestedAt = Date(timeIntervalSince1970: Double(served.epoch) / 1000)
    guard userTurnAt.map({ $0 <= requestedAt }) ?? true, let text = tail(),
          switchIssuedInsideTurn(requestedAt: requestedAt, tail: text) else { return }
    let before = state.offer
    state.armSwitch(at: requestedAt, fresh: fresh, conversation: conversation,
                    line: switchResumeMessage(from: from, to: to), userTurnAt: userTurnAt,
                    caughtUp: caughtUp)
    if let offer = state.offer, offer != before {
        appendSessionInputLine(switchResumeArmedLine(pid: pid, offer: offer, now: now), to: log)
    }
}
