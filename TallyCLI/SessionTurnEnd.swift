import Foundation

// THAT A TURN HAS ENDED, SAID RATHER THAN INFERRED.
//
// The input gate (`tally session send`) may not type into a conversation that is mid-turn, and the
// only evidence it had for "the turn is over" was silence: a transcript whose mtime had not moved
// for `sessionStateQuietSeconds`. Silence is a slow witness and a coarse one - it says nothing for
// 30 seconds after the last byte of an answer, so a `/clear` asked for at the end of a window sat
// waiting through a stretch in which the session had in fact been free the whole time.
//
// Claude Code fires `Stop` when the turn ends, and the app already registers that hook: it is the
// third of the three the agent roster is folded from (IntegrationsAgentHook.swift registers
// `SubagentStart`, `SubagentStop` and `Stop`; HookAgents.swift is the CLI end). So this adds no
// registration and no daemon. It adds one record beside the roster, written by the same hook run:
// the instant that turn ended, and the conversation it ended in.
//
// AN ACCELERATION AND NOTHING ELSE. A session whose hooks are not installed, whose Claude Code
// stops firing the event, or whose supervisor is older than this record simply has no file here,
// and the 30s inference behind it is untouched (SessionQuiet.swift, SessionStateSync.swift). The
// board's own sensitivity is likewise untouched: this record is read by the input gate alone.
//
// THE STAMP IS THE EVENT'S, NOT THE FILE'S. It is taken in the hook run that the turn boundary
// caused and written into the document, so republishing, copying or touching the file cannot make a
// turn end look more recent than it was - the same rule `UserNotice.at` is under, and for the same
// reason: it is compared against instants that come out of the transcript.

/// The suffix separating a turn-end event from the presence/drift file of the same pid.
let sessionTurnEndSuffix = ".turnend"

/// The last turn boundary this session's Claude Code reported.
struct SessionTurnEnd: Codable, Equatable, Sendable {
    /// When the turn ended, on the clock of the hook run that observed it.
    var at: Date
    /// The conversation it ended in, as Claude Code named it. Optional because the payload may not
    /// carry one, and an event that cannot say which conversation it belongs to is never acted on
    /// (`turnEndStillStands` argues why that is the safe direction rather than a lost feature).
    var sessionID: String?
}

func sessionTurnEndFile(pid: String, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent(pid + sessionTurnEndSuffix)
}

/// Record the boundary. Best-effort and atomic, like every other file on this track: a hook that
/// cannot write costs the acceleration, never the session.
func writeSessionTurnEnd(_ event: SessionTurnEnd, pid: String, dir: URL = supervisorStateDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    // The fractional clock, for the reason UserNotice.swift states where this pair is defined: this
    // instant is compared against timestamps written by Claude Code, and the two events it has to
    // separate land in the same second as a matter of course - an answer at T.6 and the boundary
    // at T.9. Encoded to whole seconds, the boundary decodes as T.0 and reads as older than the
    // answer that preceded it, which is exactly the reading that would refuse to accelerate.
    encoder.dateEncodingStrategy = .custom(encodeFractionalInstant)
    guard let data = try? encoder.encode(event) else { return }
    try? data.write(to: sessionTurnEndFile(pid: pid, dir: dir), options: .atomic)
}

/// The boundary this session last reported, or nil when there is none (or the file is from a format
/// this build does not know, which reads the same way: nothing said, so nothing is accelerated).
func readSessionTurnEnd(pid: String, dir: URL = supervisorStateDir) -> SessionTurnEnd? {
    guard let data = try? Data(contentsOf: sessionTurnEndFile(pid: pid, dir: dir)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom(decodeFractionalInstant)
    return try? decoder.decode(SessionTurnEnd.self, from: data)
}

/// What the hook writes down about one roster event, or nil when that event is not a turn boundary.
///
/// Pure, so the one thing the producer decides is assertable without a hook run: `SubagentStop` is
/// a subagent finishing and says nothing whatever about the conversation's own turn. Reading it as
/// one would hand the gate a boundary in the middle of a fan-out, which is the precise moment the
/// head is still mid-turn.
func turnEndEvent(_ event: AgentRosterEvent, sessionID: String?,
                  now: Date = Date()) -> SessionTurnEnd? {
    guard event.kind == .boundary else { return nil }
    return SessionTurnEnd(at: now, sessionID: sessionID)
}

/// Whether a recorded boundary still describes this session RIGHT NOW: the whole of what the input
/// gate is allowed to conclude from it. Pure, so every way it can be wrong is assertable.
///
/// It answers no unless all four hold, and the two in the middle are the misreadings this record
/// would otherwise invite:
///
///   - AN EVENT AT ALL. No file is the ordinary case on a machine where the hooks are not
///     installed, and it means the 30s inference decides alone, exactly as before.
///   - IT NAMES THIS CONVERSATION. The hook writes the id Claude Code gave it, and this compares it
///     against the transcript the supervisor is watching NOW. That is what separates a boundary
///     from the conversation this session used to be - a `/clear` or a fork starts a new transcript
///     with a new id, and the last thing the OLD one did was end a turn, so an unchecked record
///     would report the new conversation as between turns for as long as it never fired one of its
///     own. An event that names nothing, or a watcher with no file bound, cannot be checked and is
///     therefore not acted on: the cost is that a session goes back to waiting 30s, which is where
///     it started.
///   - NOTHING HAS HAPPENED SINCE. `newestMessageAt` is the newest main-chain user or assistant
///     event in the transcript (`newestMainChainMessage`), and a turn that has begun since the
///     boundary has written one by definition. The file's mtime cannot answer this: Claude Code
///     writes its own turn-end records (`stop_hook_summary`, `turn_duration`) AFTER the Stop hooks
///     return, so a transcript is always modified a moment after the boundary it just reported, and
///     an mtime test would refuse every acceleration this record exists for. The instants inside
///     the events are what distinguish the tail of the ended turn from the head of a new one.
///     NO MESSAGE IN VIEW IS A REFUSAL rather than a clear field: a turn that ended wrote one by
///     definition, so seeing none means the window is short rather than that nothing happened - a
///     tool result larger than `openTurnTailBytes` (1,567 of them on this machine) pushes the last
///     message out of the tail, and the records that can follow it there (an attachment, a system
///     line) would otherwise read as a conversation with nothing outstanding.
///   - IT IS THIS CHILD'S. A relaunch resumes the same transcript under a new child, and the
///     record left by the child before it describes a turn that ended in another process. Same
///     dimension `newestSubagentWrite` filters on, and for the same reason.
///
/// AND NOT WHILE A FORK IS UNRESOLVED, which is the one condition that is not about this record at
/// all: while a newer transcript in the directory cannot yet be told apart from the file the
/// conversation moved to, the id compared above is the id of a file that may already be abandoned
/// (TranscriptFork.swift owns that hold, and `quietness` takes it as busy for the same reason).
///
/// WHAT IT IS NOT: a promise that no new turn can begin between this reading and the injection a
/// tick later. Nothing on this side can promise that - the gate has always been a reading of an
/// instant - and the narrow window that stays open is a prompt submitted DURING the stop hooks,
/// which Claude Code queues and writes as a user event only once they return. That event is newer
/// than the boundary, so the next tick refuses; the exposure is one tick of one line, against a
/// hold that used to be thirty seconds of every send.
func turnEndStillStands(_ event: SessionTurnEnd?, transcript: String?, newestMessageAt: Date?,
                        childStartedAt: Date, forked: Bool) -> Bool {
    guard let event, !forked else { return false }
    guard let named = event.sessionID, let transcript, named == transcript else { return false }
    guard event.at >= childStartedAt else { return false }
    guard let newestMessageAt else { return false }
    return newestMessageAt <= event.at
}

/// When the newest main-chain user or assistant event in this tail was written, or nil when the
/// tail holds none (a transcript a `/clear` has just started, one that is all attachments and
/// modes, or a window that opened past every message).
///
/// The same reading rules `openToolCall` walks by, one file over: sidechain events are skipped
/// whichever way they lean, a line that will not parse is skipped rather than trusted (the last
/// line may still be half written), and the `type` that decides is the parsed one rather than a
/// substring - an attachment can carry another event's JSON inside it.
///
/// WITH ONE FILTER FEWER THAN THAT ONE, and deliberately: it opens with a substring test for
/// `"isSidechain":true` as a cheap way past a subagent's events, which cannot be afforded here
/// because SKIPPING A MESSAGE IS THE UNSAFE DIRECTION FOR THIS READER. What this answers is "has
/// anything happened since the boundary", so a main-chain event passed over - an assistant message
/// whose own text quotes that substring, which is a conversation about this code - would let the
/// walk fall back to an older event and report a live turn as a finished one. The parsed field
/// decides instead, and the positive test for the two types is what keeps the walk cheap.
///
/// Only user and assistant events count, deliberately. Claude Code writes several records of its
/// own AFTER a turn's stop hooks return (`stop_hook_summary`, `turn_duration`, a file-history
/// snapshot), and those are the turn ENDING rather than a new one beginning: counting them would
/// make every boundary look stale the instant it was reported.
func newestMainChainMessage(inTail tail: String) -> Date? {
    for line in tail.split(separator: "\n").reversed() {
        guard line.contains("\"type\":\"assistant\"") || line.contains("\"type\":\"user\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                  as? [String: Any],
              (object["isSidechain"] as? Bool) != true,
              let type = object["type"] as? String, type == "assistant" || type == "user",
              let stamp = (object["timestamp"] as? String).flatMap(parseISO) else { continue }
        return stamp
    }
    return nil
}

/// Whether the fact channel says this session is between turns right now.
///
/// The impure half: it reads the record and the tail of the transcript the watcher is bound to, and
/// hands both to the decision above. A tail that cannot be read answers NO rather than yes - the
/// freshness test is what stands between this and a line typed into a live turn, and a test that
/// cannot be run has not passed.
///
/// The watcher is taken by value because nothing here moves it: the tick has already located the
/// file (`syncSessionState` runs `quietness` first), and re-locating inside the input gate would be
/// a second answer to a question this tick has already answered.
///
/// COST, since this runs on a 2s poll: one small read plus one tail read, and only while a request
/// is actually pending (`applySessionInput` returns before asking when there is none).
func sessionTurnEnded(pid: String, watcher: TranscriptWatcher,
                      dir: URL = supervisorStateDir) -> Bool {
    guard let event = readSessionTurnEnd(pid: pid, dir: dir), let file = watcher.file,
          let tail = transcriptTail(of: file) else { return false }
    return turnEndStillStands(event, transcript: watcher.transcriptSessionID,
                              newestMessageAt: newestMainChainMessage(inTail: tail),
                              childStartedAt: watcher.since, forked: watcher.hasUnresolvedFork)
}
