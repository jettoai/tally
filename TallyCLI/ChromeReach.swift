import Darwin
import Foundation

// WHY A SESSION TALLY MOVED MAY LOSE CHROME, said once at the moment it bites.
// Claude in Chrome's bridge is keyed by the CLI account's claude.ai user, so a session running on an
// account the extension is not signed in to gets "Browser extension is not connected". Tally does
// not read the browser's profile. It learns which accounts have reached Chrome from the tool results
// themselves, on the PostToolUse hook it already runs and on PostToolUseFailure, where a result
// Claude Code marks as an error arrives (HookKnock.swift), and on a "not connected"
// result it tells the session once per child generation what it observed.
//
// The ledger only chooses the wording. It proves an account reached Chrome once, not that the
// extension is signed in to it now, so it never silences a notice.
//
// Where the step goes next is decided by the user's setting alone (`chromeAccountSetting`, the
// Settings row "Claude in Chrome account"): with none set the sentence above is all a session gets;
// with one set, a session on another account is moved there itself whenever it is positively free
// of subagents (ChromePreflight.swift, which also answers before the call is sent); pointing it at a
// live session on that account, or telling it how to move, is the fallback. The ledger still only
// chooses the wording of the sentence above.

let chromeToolPrefix = "mcp__claude-in-chrome__"

enum ChromeReachOutcome: Equatable { case ok, gap, timeout, unknown }

/// Every text a tool_response carries, in any of the shapes Claude Code hands it over in: a plain
/// string, a list of `{type, text}` blocks, or an object holding such a list under `content`.
func chromeResponseText(_ response: Any?) -> String? {
    if let text = response as? String { return text }
    if let list = response as? [[String: Any]] {
        let texts = list.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
    if let object = response as? [String: Any] {
        return chromeResponseText(object["content"]) ?? (object["text"] as? String)
    }
    return nil
}

/// Words that make a result anything but a certain success. `.ok` is only ever recorded for text
/// free of all of them, because a failure misread as ok is the one error that changes the wording.
let chromeFailureMarkers = ["error", "not connected", "failed", "unable", "timed out",
                            "did not respond", "not logged in", "authentication"]

/// How a "not connected" result BEGINS. Matched at the start only: a successful page read
/// (`get_page_text`, `read_page`, `find`, `javascript_tool`) can quote the same sentence as page
/// content, and a match anywhere in the text would read that page as a gap.
let chromeGapOpenings = ["Browser extension is not connected", "Authentication error occurred"]

func chromeReachOutcome(tool: String, response: Any?) -> ChromeReachOutcome {
    guard tool.hasPrefix(chromeToolPrefix), let text = chromeResponseText(response) else {
        return .unknown
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = trimmed.hasPrefix("Error: ")
        ? String(trimmed.dropFirst("Error: ".count)).trimmingCharacters(in: .whitespaces) : trimmed
    if chromeGapOpenings.contains(where: body.hasPrefix) { return .gap }
    if tool == chromeToolPrefix + "list_connected_browsers" && trimmed == "[]" { return .gap }
    // An error object is never a success, whatever its text says.
    if let object = response as? [String: Any],
       object["is_error"] as? Bool == true || object["isError"] as? Bool == true { return .unknown }
    // The timeout sentence names the lookup first ("The hidden tabs_context_mcp lookup did not
    // respond within 8s."), so it is matched within the first sentence rather than as a prefix.
    let firstSentence = body.components(separatedBy: ". ").first ?? body
    if firstSentence.contains("did not respond within") { return .timeout }
    let lowered = trimmed.lowercased()
    if trimmed.isEmpty || chromeFailureMarkers.contains(where: lowered.contains) { return .unknown }
    return .ok
}

/// The outcome of a Chrome call that arrived on `PostToolUseFailure`, whose only text is `error`.
/// Never `.ok`: a failed call is not a connection. Besides the gap openings, a first sentence saying
/// the extension must be `re-authenticated` or that the call was `never delivered to the Chrome
/// extension` is a gap here, and only here, because only an error result can carry either.
func chromeFailureOutcome(tool: String, error: String?) -> ChromeReachOutcome {
    guard let error else { return .unknown }
    if chromeReachOutcome(tool: tool, response: ["content": error, "is_error": true]) == .gap {
        return .gap
    }
    let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = trimmed.hasPrefix("Error: ") ? String(trimmed.dropFirst("Error: ".count)) : trimmed
    let firstSentence = body.components(separatedBy: ". ").first ?? body
    let failureGaps = ["re-authenticated", "never delivered to the Chrome extension"]
    return tool.hasPrefix(chromeToolPrefix) && failureGaps.contains(where: firstSentence.contains)
        ? .gap : .unknown
}

/// accountID -> the last time each outcome was seen.
struct ChromeReachLedger: Codable, Equatable {
    struct Entry: Codable, Equatable { var lastOk: Date?; var lastGap: Date? }
    var accounts: [String: Entry] = [:]
}

let chromeReachLedgerFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/chrome-reach.json")

/// A missing or unreadable ledger reads as empty, which only changes the wording to the colder form.
func readChromeReachLedger(file: URL = chromeReachLedgerFile) -> ChromeReachLedger {
    guard let data = try? Data(contentsOf: file) else { return ChromeReachLedger() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode(ChromeReachLedger.self, from: data)) ?? ChromeReachLedger()
}

/// Record one outcome and return the ledger as it now stands. Writes only when this outcome's stamp
/// is absent or over an hour old, so a Chrome-heavy session does not rewrite the file on every call.
/// Atomic; a lost race loses one stamp, which the next Chrome call writes again.
func recordChromeReach(_ outcome: ChromeReachOutcome, account: String, now: Date,
                       file: URL = chromeReachLedgerFile) -> ChromeReachLedger {
    var ledger = readChromeReachLedger(file: file)
    guard outcome == .ok || outcome == .gap else { return ledger }
    var entry = ledger.accounts[account] ?? ChromeReachLedger.Entry()
    let stamp = outcome == .ok ? entry.lastOk : entry.lastGap
    if let stamp, now.timeIntervalSince(stamp) < 3600 { return ledger }
    if outcome == .ok { entry.lastOk = now } else { entry.lastGap = now }
    ledger.accounts[account] = entry
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    if let data = try? encoder.encode(ledger) { try? data.write(to: file, options: .atomic) }
    return ledger
}

/// Whether this account has ever reached Chrome on this machine.
func chromeReachable(_ ledger: ChromeReachLedger, account: String) -> Bool {
    ledger.accounts[account]?.lastOk != nil
}

/// The accounts the ledger has seen reach Chrome, sorted by id.
func chromeReachableAccounts(_ ledger: ChromeReachLedger) -> [String] {
    ledger.accounts.filter { $0.value.lastOk != nil }.map(\.key).sorted()
}

/// The claim file for one child generation. Named `<supervisor><infix><child>` so the dead-pid sweep
/// can read the supervisor back out of it (`supervisorStatePid`, PendingNotice.swift).
func chromeGapNoticeFile(supervisorPid: String, childPid: Int, dir: URL = supervisorStateDir) -> URL {
    dir.appendingPathComponent("\(supervisorPid)\(chromeGapNoticeInfix)\(childPid)")
}

/// Exactly one hook run per child generation wins: O_CREAT|O_EXCL is atomic, and Claude Code runs
/// hooks concurrently. Any failure to create reads as "lost", so a broken directory stays silent.
func claimChromeGapNotice(supervisorPid: String, childPid: Int,
                          dir: URL = supervisorStateDir) -> Bool {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = chromeGapNoticeFile(supervisorPid: supervisorPid, childPid: childPid, dir: dir)
    let handle = open(file.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
    guard handle >= 0 else { return false }
    close(handle)
    return true
}

/// The sentence handed to the session. States what was observed and what to check; it names no
/// file, setting or process to change, so the agent reading it is not invited to change one.
func chromeGapMessage(accountLabel: String, reachedBefore: Bool,
                      reachableLabels: [String]) -> String {
    let observed = reachableLabels.isEmpty ? "none recorded yet"
        : reachableLabels.joined(separator: ", ")
    var text = "Tally: Claude in Chrome reported not connected on account \"\(accountLabel)\"."
    if reachedBefore {
        text += " This account has connected to Chrome on this machine before, so the browser may be"
            + " closed, asleep, or signed out."
    }
    return text + " Verify the extension is open and signed in to the same claude.ai account as"
        + " this session. Accounts observed connecting previously: \(observed)."
}

/// The account the user set as the one Claude in Chrome is signed in to, or nil when none is set.
/// Mirror of the app's `LaunchPolicyStore.StateFile.chromeAccount`; the schema only gains keys.
/// ONLY THIS decides routing. The chrome-reach ledger never does (it proves an account reached
/// Chrome once, not which account the extension is signed in to now).
func chromeAccountSetting(_ url: URL = stateURL) -> String? {
    struct StateFile: Decodable { var chromeAccount: String? }
    guard let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(StateFile.self, from: data),
          let chosen = file.chromeAccount?.trimmingCharacters(in: .whitespaces),
          chosen.hasPrefix("claude:") else { return nil }
    return chosen
}

/// A live Claude session on the account set for Chrome: what a hand-off needs to address it.
struct ChromeRelaySession: Equatable {
    let supervisorPid: String
    let project: String?
}

enum ChromeGapRoute {
    /// No usable setting: today's sentence, worded by the ledger.
    case explain
    /// This session already runs on the account set for Chrome, and it is not connected.
    case settingItself(String)
    /// Another session runs on the account set for Chrome: hand the step to it.
    case relay(String, [ChromeRelaySession])
    /// Nothing runs on that account: move this session there.
    case move(String)
}

/// Pure. `known` is the snapshot's account ids; a setting naming an account the snapshot does not
/// know (removed, or a stale file) is read as no setting at all.
func chromeGapRoute(account: String, setting: String?, known: Set<String>,
                    relays: (String) -> [ChromeRelaySession]) -> ChromeGapRoute {
    guard let setting, known.contains(setting) else { return .explain }
    if setting == account { return .settingItself(setting) }
    let live = relays(setting)
    return live.isEmpty ? .move(setting) : .relay(setting, live)
}

/// The live Claude sessions on `account`, in the order given, excluding this supervisor (`me`), any
/// Codex session and any supervisor whose child is gone. Pure over the readers it is handed.
func chromeRelaySessions(account: String, excluding me: String, pids: [String],
                         isCodex: (String) -> Bool, accountOf: (String) -> String?,
                         hasChild: (String) -> Bool, cwd: (String) -> String?) -> [ChromeRelaySession] {
    pids.compactMap { pid in
        guard pid != me, !isCodex(pid), accountOf(pid) == account, hasChild(pid) else { return nil }
        return ChromeRelaySession(supervisorPid: pid,
                                  project: cwd(pid).map { URL(fileURLWithPath: $0).lastPathComponent })
    }
}

/// The same, read from the files each supervisor publishes, oldest pid first. No git and no
/// transcript: this runs inside a hook.
func liveChromeRelaySessions(account: String, excluding me: String,
                             dir: URL = supervisorStateDir) -> [ChromeRelaySession] {
    chromeRelaySessions(account: account, excluding: me,
                        pids: liveSupervisorPids(dir: dir).sorted().map(String.init),
                        isCodex: { SessionMonitoring.isMarked(pid: $0, dir: dir) },
                        accountOf: { readSupervisorAccount(pid: $0, dir: dir) },
                        hasChild: { readSupervisorChild(pid: $0, dir: dir) != nil },
                        cwd: { readSupervisorCwd(pid: $0, dir: dir) })
}

let chromeRelayListLimit = 5

/// The hand-off sentence: which sessions run on the account set for Chrome, and the exact command
/// that sends one of them the Chrome step, with the address to send the result back to.
func chromeRelayMessage(accountLabel: String, settingLabel: String,
                        sessions: [ChromeRelaySession], selfSupervisor: String,
                        opening: String? = nil) -> String {
    let listed = sessions.prefix(chromeRelayListLimit).map { session in
        session.project.map { "\(session.supervisorPid) (\($0))" } ?? session.supervisorPid
    }.joined(separator: ", ")
    let task = "/tmp/tally-chrome-task-\(selfSupervisor).md"
    return (opening ?? chromeGapOpening(accountLabel: accountLabel))
        + " The user set \"\(settingLabel)\" in Tally as the account Claude in Chrome is signed in"
        + " to, and these sessions run on it: \(listed)."
        + " Hand the Chrome step to one of them: write it to \(task) as a self-contained task (what"
        + " to open, what to do, what to report), and in it ask the other session to send the result"
        + " back with `tally message claude --session \(selfSupervisor) --file <its result file>`."
        + " Then run: tally message claude --session \(sessions[0].supervisorPid) --file \(task)"
}

/// The move sentence, for when nothing runs on the account set for Chrome. `tally account <dir>` in a
/// session moves it there at the end of the turn and continues the conversation (SwitchCommand.swift).
func chromeMoveMessage(accountLabel: String, settingLabel: String, settingID: String,
                       opening: String? = nil) -> String {
    let dir = settingID.hasPrefix("claude:") ? String(settingID.dropFirst("claude:".count)) : settingID
    return (opening ?? chromeGapOpening(accountLabel: accountLabel))
        + " The user set \"\(settingLabel)\" in Tally as the account Claude in Chrome is signed in"
        + " to, and no session runs on it now. To use Chrome from this conversation, run"
        + " `tally account \(dir)`: the session moves to \"\(settingLabel)\" at the end of this turn"
        + " and continues there, so retry the Chrome step after that."
        + " `tally account --auto` hands it back to automatic account selection later."
}

/// The first sentence of the hand-off and move sentences after a failed call.
func chromeGapOpening(accountLabel: String) -> String {
    "Tally: Claude in Chrome reported not connected on account \"\(accountLabel)\"."
}

/// Appended to the existing sentence on the `.settingItself` route.
let chromeSettingItselfSuffix = " This is the account the user set in Tally as the one Claude in"
    + " Chrome is signed in to; Tally has asked the user to check that setting."

/// What the Chrome branch of `tally hook-knock` reads from outside, injectable so the suite never
/// touches a real `~/.tally`, supervisor or snapshot.
struct ChromeGapDeps {
    /// Supervisor pid -> the account its current child runs on.
    var account: (String) -> String?
    /// Supervisor pid -> its live child pid, the identity of this generation.
    var child: (String) -> Int?
    /// Account id -> display label. Read only on the notice path.
    var labels: () -> [String: String]
    var ledgerFile: URL
    /// The account set as Claude in Chrome's (state.json), or nil. Read only on the notice path.
    var chromeAccount: () -> String? = { nil }
    /// Live Claude sessions on one account (first argument), excluding this supervisor (second).
    /// Read only when a setting names another account.
    var relays: (String, String) -> [ChromeRelaySession] = { _, _ in [] }
    /// Tell the app the account set for Chrome is itself not connected.
    var signalSettingGap: (String, Date) -> Void = { _, _ in }
    /// Whether this session is positively free of subagents and background work. nil: never move.
    var agentsIdle: ((String, ChromeCallContext) -> Bool)? = nil
    /// Queue a move of this supervisor's session (second) to the account set for Chrome (first).
    /// nil: never move.
    var queueMove: ((String, String) -> ChromeMoveQueue)? = nil
    /// This supervisor's pending switch request, if any.
    var pendingSwitch: (String) -> SwitchRequest? = { _ in nil }

    static var live: ChromeGapDeps {
        ChromeGapDeps(account: { readSupervisorAccount(pid: $0) },
                      child: { readSupervisorChild(pid: $0) },
                      labels: {
                          Dictionary((loadSnapshot().0?.accounts ?? []).map { ($0.id, $0.label) },
                                     uniquingKeysWith: { first, _ in first })
                      },
                      ledgerFile: chromeReachLedgerFile,
                      chromeAccount: { chromeAccountSetting() },
                      relays: { account, me in liveChromeRelaySessions(account: account, excluding: me) },
                      signalSettingGap: { account, now in
                          writeChromeSettingGapSignal(ChromeSettingGapSignal(account: account, at: now))
                      },
                      agentsIdle: { chromeAgentsIdleLive(supervisor: $0, context: $1) },
                      queueMove: { chromeQueueMoveLive(setting: $0, supervisor: $1) },
                      pendingSwitch: { readSwitchRequest(sessionKey: $0) })
    }
}

/// The Chrome branch of a PostToolUse or PostToolUseFailure run, given the classified outcome: the
/// context sentence to deliver, or nil. Records the outcome in the ledger, and on a gap claims this
/// generation's notice.
func chromeGapNotice(tool: String, outcome: ChromeReachOutcome,
                     supervisor: String, stateDir: URL, now: Date,
                     context: ChromeCallContext = ChromeCallContext(),
                     deps: ChromeGapDeps) -> String? {
    guard tool.hasPrefix(chromeToolPrefix), let account = deps.account(supervisor) else { return nil }
    let ledger = recordChromeReach(outcome, account: account, now: now, file: deps.ledgerFile)
    guard outcome == .gap, let child = deps.child(supervisor),
          claimChromeGapNotice(supervisorPid: supervisor, childPid: child, dir: stateDir)
    else { return nil }
    let labels = deps.labels()
    let label = labels[account] ?? account
    let route = chromeGapRoute(account: account, setting: deps.chromeAccount(),
                               known: Set(labels.keys), relays: { deps.relays($0, supervisor) })
    func explained() -> String {
        chromeGapMessage(accountLabel: label,
                         reachedBefore: chromeReachable(ledger, account: account),
                         reachableLabels: chromeReachableAccounts(ledger).map { labels[$0] ?? $0 }.sorted())
    }
    switch route {
    case .explain:
        return explained()
    case .settingItself(let setting):
        deps.signalSettingGap(setting, now)
        return explained() + chromeSettingItselfSuffix
    case .relay(let setting, let sessions):
        let move = chromeSelfMove(setting: setting, supervisor: supervisor, context: context,
                                  now: now, pre: false, deps: deps)
        let settingLabel = labels[setting] ?? setting
        if move == .queued { return chromeMovedMessage(accountLabel: label, settingLabel: settingLabel) }
        return chromeRelayMessage(accountLabel: label, settingLabel: settingLabel,
                                  sessions: sessions, selfSupervisor: supervisor)
            + (move == .withheld ? chromeAgentsSuffix : "")
    case .move(let setting):
        let move = chromeSelfMove(setting: setting, supervisor: supervisor, context: context,
                                  now: now, pre: false, deps: deps)
        let settingLabel = labels[setting] ?? setting
        if move == .queued { return chromeMovedMessage(accountLabel: label, settingLabel: settingLabel) }
        return chromeMoveMessage(accountLabel: label, settingLabel: settingLabel, settingID: setting)
            + (move == .withheld ? chromeAgentsSuffix : "")
    }
}
