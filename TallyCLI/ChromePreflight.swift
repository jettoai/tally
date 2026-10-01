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
// (`chromeAgentsIdle`): a roster that will not decode, or a roll call this generation with a count
// that is not zero; a subagents directory that exists but cannot be listed; a transcript tail that
// reaches back neither to the boundary (that roll call, else the child's start) nor to the top of the
// file, or an assistant line after it that will not parse. No setting, or
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
}

extension ChromeCallContext {
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

/// Whether background work was started after `countedSince`: a tool call with
/// `run_in_background: true` (Bash, PowerShell, Agent, Task) or any Monitor, on a main-chain
/// assistant line stamped later than that moment. The boundary is the later of this child's start
/// and the roster's last roll call in this generation (`chromeBackgroundBoundary`): the roll call
/// counts what was running at `Stop`, and work from an earlier child died with it. A person's input
/// is NOT a boundary: a queued message or a turn interrupted before its `Stop` leaves the start
/// uncounted, so the evidence stands until a roll call covers it. nil when there is no boundary, when
/// the tail neither starts at the top of the file (`fromFileStart`) nor reaches back to the boundary,
/// or when an assistant line after it will not parse or carries no stamp.
func chromeBackgroundStartedThisTurn(tail: String, countedSince: Date?, fromFileStart: Bool = false) -> Bool? {
    guard let countedSince else { return nil }
    var reachesBack = fromFileStart, started = false
    for line in tail.split(separator: "\n") where !line.contains("\"isSidechain\":true") {
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let stamp = (object?["timestamp"] as? String).flatMap(transcriptParseISO)
        if let stamp, stamp <= countedSince { reachesBack = true; continue }
        guard line.contains("\"type\":\"assistant\"") else { continue }
        guard let object, stamp != nil else { return nil }
        let blocks = ((object["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        for block in blocks where block["type"] as? String == "tool_use" {
            if block["name"] as? String == "Monitor"
                || (block["input"] as? [String: Any])?["run_in_background"] as? Bool == true {
                started = true
            }
        }
    }
    return reachesBack ? started : nil
}

/// The moment after which the transcript must show no background start: this child's start, or the
/// roster's roll call when one was taken in this generation (the roster file keeps whole seconds, so
/// that moment rounds down, which only widens the window).
func chromeBackgroundBoundary(record: SessionAgentsRecord?, childStartedAt: Date) -> Date {
    guard let counted = record?.backgroundCountedAt, counted >= childStartedAt else { return childStartedAt }
    return counted
}

/// Whether this session is positively free of subagents and background work. Pure. Every witness
/// that is missing or unreadable answers false, which leaves the session where it is. No roster, or
/// one from an earlier generation, means no subagent edge this generation; background work is then
/// the transcript's to answer (`backgroundThisTurn`, measured from the child's start). A roll call
/// taken in this generation must count zero (nil is not zero).
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
    guard let record, record.updatedAt >= start else { return true }
    if let counted = record.backgroundCountedAt, counted >= start, record.background != 0 { return false }
    return record.live.isEmpty
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
    let boundary = start.map { chromeBackgroundBoundary(record: record, childStartedAt: $0) }
    return chromeAgentsIdle(
        fromSubagent: context.fromSubagent, childStartedAt: start,
        agentHookRegistered: agentRosterHookRegistered(home: home),
        claudeReportsAgents: claudeCodeReportsAgents(executablePath: environment["CLAUDE_CODE_EXECPATH"]),
        record: record,
        rosterUnreadable: record == nil
            && manager.fileExists(atPath: sessionAgentsFile(pid: supervisor, dir: dir).path),
        newestSubagentWrite: start.flatMap { subagentTreeNewestWrite(transcript: transcript, since: $0) },
        subagentsUnreadable: subagentsUnreadable,
        backgroundThisTurn: backgroundSince(transcript: transcript, boundary: boundary),
        now: now)
}

/// `chromeBackgroundStartedThisTurn` over the transcript's tail. The size is read AFTER the tail: the
/// file only grows, so a size within the bound then means the tail was read from the top.
private func backgroundSince(transcript: URL, boundary: Date?) -> Bool? {
    guard let tail = transcriptTail(of: transcript, bytes: selfSwitchTailBytes) else { return nil }
    let size = (try? FileManager.default.attributesOfItem(atPath: transcript.path))?[.size] as? Int
    return chromeBackgroundStartedThisTurn(tail: tail, countedSince: boundary,
                                           fromFileStart: size.map { $0 <= selfSwitchTailBytes } ?? false)
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
