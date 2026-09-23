import Darwin
import Foundation

// WHY A SESSION TALLY MOVED MAY LOSE CHROME, said once at the moment it bites.
// Claude in Chrome's bridge is keyed by the CLI account's claude.ai user, so a session running on an
// account the extension is not signed in to gets "Browser extension is not connected". Tally does
// not read the browser's profile. It learns which accounts have reached Chrome from the tool results
// themselves, on the PostToolUse hook it already runs (HookKnock.swift), and on a "not connected"
// result it tells the session once per child generation what it observed.
//
// The ledger only chooses the wording. It proves an account reached Chrome once, not that the
// extension is signed in to it now, so it never silences a notice.

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
    var eventDir: URL

    static var live: ChromeGapDeps {
        ChromeGapDeps(account: { readSupervisorAccount(pid: $0) },
                      child: { readSupervisorChild(pid: $0) },
                      labels: {
                          Dictionary((loadSnapshot().0?.accounts ?? []).map { ($0.id, $0.label) },
                                     uniquingKeysWith: { first, _ in first })
                      },
                      ledgerFile: chromeReachLedgerFile, eventDir: chromeGapEventDir)
    }
}

/// The Chrome branch of a PostToolUse run: the context sentence to deliver, or nil. Records the
/// outcome in the ledger, and on a gap claims this generation's notice and files the app's event.
func chromeGapNotice(tool: String, response: Any?, cwd: String?, supervisor: String,
                     stateDir: URL, now: Date, deps: ChromeGapDeps) -> String? {
    guard tool.hasPrefix(chromeToolPrefix), let account = deps.account(supervisor) else { return nil }
    let outcome = chromeReachOutcome(tool: tool, response: response)
    let ledger = recordChromeReach(outcome, account: account, now: now, file: deps.ledgerFile)
    guard outcome == .gap, let child = deps.child(supervisor),
          claimChromeGapNotice(supervisorPid: supervisor, childPid: child, dir: stateDir)
    else { return nil }
    let labels = deps.labels()
    let label = labels[account] ?? account
    let reachable = chromeReachableAccounts(ledger).map { labels[$0] ?? $0 }.sorted()
    writeChromeGapEvent(ChromeGapEvent(account: account, label: label, cwd: cwd,
                                       reachable: reachable, at: now),
                        supervisorPid: supervisor, childPid: child, dir: deps.eventDir)
    return chromeGapMessage(accountLabel: label,
                            reachedBefore: chromeReachable(ledger, account: account),
                            reachableLabels: reachable)
}
