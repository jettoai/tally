import Darwin
import Foundation

// CLAUDE IN CHROME, ANSWERED BEFORE THE CALL IS SENT (B-558). ChromeReach.swift tells a session
// AFTER a call came back "not connected"; that costs one failed call per generation. With the
// "Claude in Chrome account" setting chosen, the `PreToolUse` hook (HookKnock.swift) already knows
// the call will fail on any other account, so it denies the first such call of each child
// generation with the hand-off sentence: write the step down and run it with `tally chrome run`
// (ChromeRun.swift), a one-off run on the set account. The session itself never changes account:
// a move ends its subagents and background work and costs the user a relaunch (owner ruling,
// 2026-10-01, B-558).
//
// ONE DENIAL PER GENERATION, then calls go through. A setting that names the wrong account must not
// turn into a session that can never call Chrome; a call that then fails gets the same sentence
// once from ChromeReach.swift, and one that succeeds records the account in the ledger.
// No setting, or one naming an account the snapshot does not know, answers "allow": exactly the
// 69ead54 behaviour. `PreToolUse` never claims a quota knock.

/// The audit word a denied Chrome call leaves in the input log.
let chromePreflightDeniedOutcome = "chrome-preflight-denied"

func chromePreflightOpening(accountLabel: String, settingLabel: String) -> String {
    "Tally: Claude in Chrome is signed in to \"\(settingLabel)\" (set in Tally), not to this"
        + " session's account \"\(accountLabel)\", so this call was not sent."
}

/// One denial per child generation, claimed the way `claimChromeGapNotice` claims its own.
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
func chromePreflightReason(tool: String, supervisor: String, stateDir: URL,
                           deps: ChromeGapDeps) -> String? {
    guard tool.hasPrefix(chromeToolPrefix), let account = deps.account(supervisor),
          let setting = deps.chromeAccount() else { return nil }
    let labels = deps.labels()
    guard let settingLabel = labels[setting], setting != account,
          let child = deps.child(supervisor),
          claimChromePreflightNotice(supervisorPid: supervisor, childPid: child, dir: stateDir)
    else { return nil }
    let opening = chromePreflightOpening(accountLabel: labels[account] ?? account,
                                         settingLabel: settingLabel)
    return chromeRunnerSentence(settingLabel: settingLabel, supervisor: supervisor, opening: opening)
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
