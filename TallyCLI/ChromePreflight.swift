import Darwin
import Foundation

// CLAUDE IN CHROME, ANSWERED BEFORE THE CALL IS SENT (B-558). ChromeReach.swift tells a session
// AFTER a call came back "not connected"; that costs one failed call per generation. With the
// "Claude in Chrome account" setting chosen, the `PreToolUse` hook (HookKnock.swift) already knows
// the call will fail on any other account, so it answers with a permission decision instead:
//
//   - the session is positively free of subagents and background work: it queues a move onto the
//     set account (the same request `tally account` writes, origin `chrome-hook`) and denies the
//     call with a sentence telling the agent to end its turn; the supervisor moves it and types a
//     carry-on line (SelfSwitchResume.swift);
//   - it is not, or that cannot be read, or the move is refused: it denies once per child
//     generation with the hand-off sentence, then lets calls through.
//
// WHICH WAY EACH UNKNOWN FALLS. A move ends every subagent and every background job, so a witness
// that cannot be read answers "there is work in flight" and the session is NOT moved
// (`chromeAgentsIdle`): a roster file that exists but will not decode, a subagents directory that
// exists but cannot be listed, a transcript tail with no person input in it or an assistant line
// after that input that will not parse. Only a roster file that does not exist at all reads as "no
// subagent edge this generation". No setting, or
// one naming an account the snapshot does not know, answers "allow": exactly the 69ead54 behaviour.
// A queued move that has not happened within `chromeMoveDenyWindow` stops being denied, so a stuck
// supervisor never turns into a session that can never call Chrome. `PreToolUse` never claims a
// quota knock.

/// What the hook payload says about the call itself.
struct ChromeCallContext: Equatable {
    /// The call came from a subagent (Claude Code puts `agent_id` / `agent_type` on its events;
    /// CodexSessionHook.swift reads the same pair).
    var fromSubagent = false
    /// The main transcript, whose `<stem>/subagents/` tree is one witness of work in flight.
    var transcriptPath: String? = nil

    init(fromSubagent: Bool = false, transcriptPath: String? = nil) {
        self.fromSubagent = fromSubagent
        self.transcriptPath = transcriptPath
    }

    init(payload: [String: Any]?) {
        fromSubagent = payload?["agent_id"] != nil || payload?["agent_type"] != nil
        transcriptPath = payload?["transcript_path"] as? String
    }
}

enum ChromeMoveQueue: Equatable { case queued, alreadyThere, refused }

enum ChromeSelfMove: Equatable {
    /// A move onto the set account is on disk (written now, or already pending).
    case queued
    case alreadyThere
    /// A move onto the set account has been pending longer than `chromeMoveDenyWindow`.
    case stale
    /// Not moved: subagents may be running, or a person's own move request is pending.
    case withheld
    case refused
}

/// How long a pending move onto the set account keeps denying Chrome calls before letting them go.
let chromeMoveDenyWindow: TimeInterval = 600

/// The audit word a denied Chrome call leaves in the input log.
let chromePreflightDeniedOutcome = "chrome-preflight-denied"

/// Whether this turn, from the newest person input to the end of `tail`, started background work: a
/// tool call with `run_in_background: true` (Bash, PowerShell, Agent, Task) or any Monitor. The
/// roster counts background work only at `Stop`, so it cannot see a job started in the turn that is
/// running now. nil when the turn's start is not in the tail, or an assistant line after it will not
/// parse: the question cannot be answered.
func chromeBackgroundStartedThisTurn(tail: String) -> Bool? {
    var sawPerson = false, started = false, unreadable = false
    for line in tail.split(separator: "\n") where !line.contains("\"isSidechain\":true") {
        if !line.contains("\"tool_result\""), lineIsPersonInput(line) {
            (sawPerson, started, unreadable) = (true, false, false)
            continue
        }
        guard sawPerson, line.contains("\"type\":\"assistant\"") else { continue }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { unreadable = true; continue }
        let blocks = ((object["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        for block in blocks where block["type"] as? String == "tool_use" {
            if block["name"] as? String == "Monitor"
                || (block["input"] as? [String: Any])?["run_in_background"] as? Bool == true {
                started = true
            }
        }
    }
    return sawPerson && !unreadable ? started : nil
}

/// Whether this session is positively free of subagents and background work. Pure. Every witness
/// that is missing or unreadable answers false, which leaves the session where it is.
func chromeAgentsIdle(fromSubagent: Bool, childStartedAt: Date?, agentHookRegistered: Bool,
                      claudeReportsAgents: Bool, record: SessionAgentsRecord?,
                      rosterUnreadable: Bool, newestSubagentWrite: Date?,
                      subagentsUnreadable: Bool, backgroundThisTurn: Bool?,
                      now: Date) -> Bool {
    guard !fromSubagent, let start = childStartedAt, agentHookRegistered, claudeReportsAgents,
          !rosterUnreadable, !subagentsUnreadable, backgroundThisTurn == false
    else { return false }
    if let write = newestSubagentWrite, write > start,
       now.timeIntervalSince(write) <= subagentIdleSeconds { return false }
    // A roster from an earlier generation means this child has had no SubagentStart edge at all.
    guard let record, record.updatedAt >= start else { return true }
    return record.live.isEmpty && (record.background ?? 0) == 0
}

/// The same, with the live witnesses. A payload with no transcript path cannot be walked, and so
/// answers false. The tail is read with the bound the self-switch turn test uses.
func chromeAgentsIdleLive(supervisor: String, context: ChromeCallContext,
                          environment: [String: String] = ProcessInfo.processInfo.environment,
                          dir: URL = supervisorStateDir, now: Date = Date()) -> Bool {
    guard let transcriptPath = context.transcriptPath else { return false }
    let transcript = URL(fileURLWithPath: transcriptPath)
    let start = readSupervisorChild(pid: supervisor, dir: dir).flatMap { processIdentity(pid_t($0)) }
        .map { Date(timeIntervalSince1970: Double($0.startedAt) / 1_000_000) }
    let home = environment["CLAUDE_CONFIG_DIR"] ?? defaultHome(providers[0])
    let record = readSessionAgents(pid: supervisor, dir: dir)
    let manager = FileManager.default
    let subagents = transcript.deletingPathExtension().appendingPathComponent("subagents")
    var isDirectory: ObjCBool = false
    let subagentsUnreadable = manager.fileExists(atPath: subagents.path, isDirectory: &isDirectory)
        && isDirectory.boolValue && (try? manager.contentsOfDirectory(atPath: subagents.path)) == nil
    return chromeAgentsIdle(
        fromSubagent: context.fromSubagent, childStartedAt: start,
        agentHookRegistered: agentRosterHookRegistered(home: home),
        claudeReportsAgents: claudeCodeReportsAgents(executablePath: environment["CLAUDE_CODE_EXECPATH"]),
        record: record,
        rosterUnreadable: record == nil
            && manager.fileExists(atPath: sessionAgentsFile(pid: supervisor, dir: dir).path),
        newestSubagentWrite: start.flatMap { subagentTreeNewestWrite(transcript: transcript, since: $0) },
        subagentsUnreadable: subagentsUnreadable,
        backgroundThisTurn: transcriptTail(of: transcript, bytes: selfSwitchTailBytes)
            .flatMap(chromeBackgroundStartedThisTurn),
        now: now)
}

/// Queue the move through the same path `tally account` takes. Prints nothing: a hook's stdout
/// carries the hook JSON or nothing.
func chromeQueueMoveLive(setting: String, supervisor: String) -> ChromeMoveQueue {
    switch attemptSwitch(.pinAccount(setting), marker: .trusted(supervisor),
                         surface: .chromeHook).result {
    case .queued: return .queued
    case .alreadyThere: return .alreadyThere
    case .refused: return .refused
    }
}

/// Whether to move this session onto the set account, shared by the call before (`pre`) and after
/// it failed. nil when the deps carry no way to move, which keeps the 69ead54 behaviour.
func chromeSelfMove(setting: String, supervisor: String, context: ChromeCallContext, now: Date,
                    pre: Bool, deps: ChromeGapDeps) -> ChromeSelfMove? {
    guard let queue = deps.queueMove, let idle = deps.agentsIdle else { return nil }
    if let pending = deps.pendingSwitch(supervisor) {
        let age = now.timeIntervalSince1970 - Double(pending.epoch) / 1000
        // Never rewritten: the request on disk already says this.
        if pending.accountID == setting { return !pre || age <= chromeMoveDenyWindow ? .queued : .stale }
        // Somebody else's move, made moments ago, is not overwritten.
        if age <= chromeMoveDenyWindow { return .withheld }
    }
    guard idle(supervisor, context) else { return .withheld }
    switch queue(setting, supervisor) {
    case .queued: return .queued
    case .alreadyThere: return .alreadyThere
    case .refused: return .refused
    }
}

func chromePreflightOpening(accountLabel: String, settingLabel: String) -> String {
    "Tally: Claude in Chrome is signed in to \"\(settingLabel)\" (set in Tally), not to this"
        + " session's account \"\(accountLabel)\", so this call was not sent."
}

/// S1: the call was denied and the move is queued.
func chromePreflightMoveMessage(accountLabel: String, settingLabel: String) -> String {
    chromePreflightOpening(accountLabel: accountLabel, settingLabel: settingLabel)
        + " This session moves to \"\(settingLabel)\" when this turn ends, and the conversation"
        + " continues there on its own. End this turn now without retrying the Chrome step; it"
        + " continues after the move. Run `tally account --auto` later to hand the session back to"
        + " automatic account selection."
}

/// S4: a call failed and the move is queued.
func chromeMovedMessage(accountLabel: String, settingLabel: String) -> String {
    chromeGapOpening(accountLabel: accountLabel)
        + " The user set \"\(settingLabel)\" in Tally as the account Claude in Chrome is signed in"
        + " to, so this session moves to \"\(settingLabel)\" when this turn ends and the"
        + " conversation continues there on its own. End this turn now; retry the Chrome step after"
        + " the move. Run `tally account --auto` later to hand the session back to automatic"
        + " account selection."
}

/// S6: appended to a hand-off when the session was not moved because of work in flight.
let chromeAgentsSuffix = " Subagents or background work may still be running in this session, so"
    + " Tally did not move it: a move ends them. Hand the step off as above, or move after they finish."

/// One hand-off denial per child generation, claimed the way `claimChromeGapNotice` claims its own.
func claimChromePreflightNotice(supervisorPid: String, childPid: Int,
                                dir: URL = supervisorStateDir) -> Bool {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("\(supervisorPid)\(chromePreflightNoticeInfix)\(childPid)")
    let handle = open(file.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
    guard handle >= 0 else { return false }
    close(handle)
    return true
}

/// The reason to deny this Chrome call with, or nil to let it through.
func chromePreflightReason(tool: String, supervisor: String, context: ChromeCallContext,
                           stateDir: URL, now: Date, deps: ChromeGapDeps) -> String? {
    guard tool.hasPrefix(chromeToolPrefix), let account = deps.account(supervisor),
          let setting = deps.chromeAccount() else { return nil }
    let labels = deps.labels()
    guard labels[setting] != nil, setting != account else { return nil }
    let label = labels[account] ?? account
    let settingLabel = labels[setting] ?? setting
    let move = chromeSelfMove(setting: setting, supervisor: supervisor, context: context, now: now,
                              pre: true, deps: deps)
    switch move {
    case nil, .alreadyThere, .stale:
        return nil
    case .queued:
        return chromePreflightMoveMessage(accountLabel: label, settingLabel: settingLabel)
    case .withheld, .refused:
        guard let child = deps.child(supervisor),
              claimChromePreflightNotice(supervisorPid: supervisor, childPid: child, dir: stateDir)
        else { return nil }
        let opening = chromePreflightOpening(accountLabel: label, settingLabel: settingLabel)
        let sessions = deps.relays(setting, supervisor)
        let handOff = sessions.isEmpty
            ? chromeMoveMessage(accountLabel: label, settingLabel: settingLabel, settingID: setting,
                                opening: opening)
            : chromeRelayMessage(accountLabel: label, settingLabel: settingLabel, sessions: sessions,
                                 selfSupervisor: supervisor, opening: opening)
        return handOff + (move == .withheld ? chromeAgentsSuffix : "")
    }
}

/// The deny document, built by the serializer (labels can carry quotes and backslashes).
func chromePreflightHookOutput(reason: String) -> String {
    let document: [String: Any] = ["hookSpecificOutput": [
        "hookEventName": chromePreflightHookEvent,
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    ]]
    guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}
