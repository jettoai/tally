import Foundation

var passed = 0
func expect(_ value: @autoclosure () -> Bool, _ name: String) {
    guard value() else { fatalError("FAIL: " + name) }
    passed += 1
}

let now = Date(timeIntervalSince1970: 1_790_000_000)
let account = "claude:fixture"
let incident = LoginHealthSession(id: "100:101:" + account, accountID: account,
                                 childPid: 101, directory: "/fixture", failedAt: now)
var health = LoginHealthAlerts()
var local = LoginAlertState()
let localSignedIn: [String: LoginStatusCommand.Verdict] = [account: .signedIn]
let known: Set<String> = [account]

let first = health.advance(sessions: [incident], deadlines: [:], known: known, now: now)
expect(first.count == 1 && first.first?.kind == .session, "session failure begins an incident")
(local, _) = LoginAlertLogic.advance(state: local, verdicts: localSignedIn, known: known)
expect(health.sessions.contains(incident.episode), "local signed-in does not clear the session incident")
expect(health.advance(sessions: [incident], deadlines: [:], known: known, now: now).isEmpty,
       "the same session incident is posted once")
health.rearm(first[0])
expect(health.advance(sessions: [incident], deadlines: [:], known: known, now: now).count == 1,
       "a rejected notification can be submitted again")
expect(health.advance(sessions: [], deadlines: [:], known: known, now: now).isEmpty,
       "a recovered session no longer asks for an alert")
expect(health.sessions.isEmpty, "recovery retires the incident")
expect(health.advance(sessions: [incident], deadlines: [:], known: known, now: now).count == 1,
       "a new failure after recovery is armed")
_ = health.advance(sessions: [], deadlines: [:], known: known, now: now)
expect(health.sessions.isEmpty, "ending the session retires the incident")

let deadline = now.addingTimeInterval(4 * 86400)
expect(health.advance(sessions: [], deadlines: [account: deadline], known: known, now: now).isEmpty,
       "a deadline outside the warning window stays quiet")
let warning = health.advance(sessions: [], deadlines: [account: deadline], known: known,
                             now: now.addingTimeInterval(86400))
expect(warning.map(\.kind) == [.expiring], "a refresh at the three-day threshold warns")
expect(health.advance(sessions: [], deadlines: [account: deadline], known: known,
                      now: now.addingTimeInterval(2 * 86400)).isEmpty, "a deadline warns once")
expect(health.advance(sessions: [], deadlines: [:], known: known, now: deadline).isEmpty,
       "unknown metadata does not invent an expiry")
expect(health.advance(sessions: [], deadlines: [account: deadline], known: known,
                      now: now.addingTimeInterval(2 * 86400)).isEmpty,
       "unknown metadata does not rearm the prior deadline")
let expired = health.advance(sessions: [], deadlines: [account: deadline], known: known, now: deadline)
expect(expired.map(\.kind) == [.expired], "expiry has a separate alert after the advance warning")
expect(health.advance(sessions: [], deadlines: [account: deadline], known: known, now: deadline).isEmpty,
       "the expired alert is deduplicated")
let newDeadline = deadline.addingTimeInterval(86400)
expect(health.advance(sessions: [], deadlines: [account: newDeadline], known: known, now: deadline)
    .map(\.kind) == [.expiring], "renewing to a new deadline rearms the warning")
health.rearm(expired[0])
expect(health.advance(sessions: [], deadlines: [account: newDeadline], known: known, now: deadline).isEmpty,
       "an old asynchronous failure cannot rearm the new deadline")
let encoded = try JSONEncoder().encode(health)
health = try JSONDecoder().decode(LoginHealthAlerts.self, from: encoded)
expect(health.advance(sessions: [], deadlines: [account: newDeadline], known: known, now: deadline).isEmpty,
       "accepted submissions remain deduplicated after relaunch")
_ = health.advance(sessions: [], deadlines: [:], known: [], now: now)
expect(health.deadlines.isEmpty && health.expiryKeys.isEmpty, "removed accounts release deadline state")
let oldSignedOut = LoginAlertLogic.advance(state: local, verdicts: [account: .signedOut], known: known)
expect(oldSignedOut.1 == [account], "the original signed-out alert remains independent")

// Drive the production usage reader with a real subprocess. No real account or credential is used.
let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let stub = dir.appendingPathComponent("claude-fixture")
func script(_ body: String) throws {
    try ("#!/bin/sh\n" + body + "\n").write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
}
var usageHealth = LoginUsageHealth()
try script("printf 'Not logged in · Please run /login\\n' >&2\nexit 1")
let failure = await ClaudeUsageCLI.fetchUsageText(configDir: dir.path, executable: stub.path,
                                                    probeHomeRoot: dir.appendingPathComponent("probe-home"))
expect(failure.map(ClaudeUsageCLI.authenticationRejected) == true, "nonzero official usage auth failure survives the reader")
usageHealth.record(accountID: account, authenticated: false)
expect(usageHealth.needsSignIn(account, local: .signedIn), "usage rejection remains visible with local auth status true")
expect(usageHealth.applying(to: localSignedIn)[account] == .signedOut, "local success cannot rearm usage rejection notifications")
for text in ["HTTP 429: rate limited", "Network disconnected", "Visit docs for /login options", ""] {
    expect(!ClaudeUsageCLI.authenticationRejected(text), "unrelated output is not an authentication rejection")
}
try script("printf 'Network disconnected\\n' >&2\nexit 1")
let network = await ClaudeUsageCLI.fetchUsageText(configDir: dir.path, executable: stub.path,
                                                    probeHomeRoot: dir.appendingPathComponent("probe-home"))
expect(network == nil, "nonzero network error remains a read failure")
expect(usageHealth.needsSignIn(account, local: .signedIn), "unknown usage failure does not clear prior authentication failure")
try script("printf 'Current session: 12%% used\\n'\nexit 0")
let success = await ClaudeUsageCLI.fetchUsageText(configDir: dir.path, executable: stub.path,
                                                    probeHomeRoot: dir.appendingPathComponent("probe-home"))
expect(success.map { !ClaudeUsageTextMapper.map(text: $0).isEmpty } == true,
       "successful official usage output produces actual metrics")
let argvFile = dir.appendingPathComponent("argv")
try script("printf '%s\\n' \"$@\" > '\(argvFile.path)'\nprintf 'Current session: 12%% used\\n'\nexit 0")
_ = await ClaudeUsageCLI.fetchUsageText(configDir: dir.path, executable: stub.path,
                                                    probeHomeRoot: dir.appendingPathComponent("probe-home"))
let probeArgv = (try? String(contentsOf: argvFile, encoding: .utf8))?.split(separator: "\n").map(String.init)
expect(probeArgv == ["-p", "/usage", "--strict-mcp-config", "--safe-mode", "--no-session-persistence"],
       "the probe runs with MCP isolation, without the user's hooks and plugins, and leaves no transcript (\(probeArgv ?? []))")
// MARK: The isolated probe home, and the old read behind it.
// Inherit an override the way a shell inside an agent team would: the old read must remove it,
// and without this every run would pass whether or not it does.
setenv("CLAUDE_SECURESTORAGE_CONFIG_DIR", "/inherited/override", 1)
let envLog = dir.appendingPathComponent("env.log")
let threeWindows = """
    printf 'Current session: 13%% used · resets Sep 27 at 5:20pm (Asia/Taipei)\\n'
    printf 'Current week (all models): 15%% used · resets Oct 3 at 6pm (Asia/Taipei)\\n'
    printf 'Current week (Fable): 0%% used · resets Oct 3 at 6pm (Asia/Taipei)\\n'
    """
let twoWindows = """
    printf 'Current session: 13%% used · resets Sep 27 at 5:20pm (Asia/Taipei)\\n'
    printf 'Current week (all models): 15%% used · resets Oct 3 at 6pm (Asia/Taipei)\\n'
    """
/// Each run appends "CLAUDE_CONFIG_DIR|CLAUDE_SECURESTORAGE_CONFIG_DIR", with <unset> for absent,
/// so an empty value and a missing one read differently.
func routedStub(isolated: String, legacy: String) throws {
    try script("""
        printf '%s|%s\\n' "${CLAUDE_CONFIG_DIR-<unset>}" "${CLAUDE_SECURESTORAGE_CONFIG_DIR-<unset>}" >> '\(envLog.path)'
        if [ "${CLAUDE_SECURESTORAGE_CONFIG_DIR+x}" = x ]; then
        \(isolated)
        else
        \(legacy)
        fi
        """)
}
func runs() -> [String] {
    ((try? String(contentsOf: envLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}
func resetLog() { try? FileManager.default.removeItem(at: envLog) }
let probeRoot = dir.appendingPathComponent("probe-home")
let notLoggedIn = "printf 'Not logged in · Please run /login\\n' >&2\nexit 1"
func metricIDs(_ text: String?) -> Set<String> {
    Set(text.map { ClaudeUsageTextMapper.map(text: $0).map(\.id) } ?? [])
}
let fullIDs: Set<String> = ["session", "weekly_all", "weekly_model:Fable"]

// T1: a signed-in extra account is read once, from its own private empty home.
resetLog()
let t1 = dir.appendingPathComponent(".claudeT1").path
try routedStub(isolated: threeWindows, legacy: notLoggedIn)
let t1Text = await ClaudeUsageCLI.fetchUsageText(configDir: t1, executable: stub.path, probeHomeRoot: probeRoot)
expect(metricIDs(t1Text) == fullIDs, "the isolated read yields all three windows")
expect(runs() == ["\(probeRoot.path)/claudeT1|\(t1)"],
       "one run, config home in the probe root, Keychain kept on the account (\(runs()))")
let t1Mode = (try? FileManager.default.attributesOfItem(atPath: probeRoot.path + "/claudeT1"))?[.posixPermissions] as? NSNumber
expect(t1Mode?.intValue == 0o700, "the probe home is private to the user")

// T2: the default account keeps the Keychain lookup on ~/.claude through an EMPTY override.
resetLog()
try routedStub(isolated: threeWindows, legacy: notLoggedIn)
_ = await ClaudeUsageCLI.fetchUsageText(configDir: nil, executable: stub.path, probeHomeRoot: probeRoot)
expect(runs() == ["\(probeRoot.path)/claude|"],
       "the default account sets the override to the empty string, not unset (\(runs()))")

// T3 (the fallback row the brief requires): the override is not honoured (renamed in a CLI
// release), so the isolated home reads as signed out and the old read must take over.
resetLog()
let t3 = dir.appendingPathComponent(".claudeT3").path
try routedStub(isolated: notLoggedIn, legacy: threeWindows)
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let t3Text = await ClaudeUsageCLI.fetchUsageText(configDir: t3, executable: stub.path,
                                                probeHomeRoot: probeRoot, now: t0)
expect(metricIDs(t3Text) == fullIDs, "the fallback returns the old read's three windows (\(t3Text ?? "nil"))")
expect(runs() == ["\(probeRoot.path)/claudeT3|\(t3)", "\(t3)|<unset>"],
       "isolated first, then the old read with the override removed (\(runs()))")
resetLog()
_ = await ClaudeUsageCLI.fetchUsageText(configDir: t3, executable: stub.path,
                                        probeHomeRoot: probeRoot, now: t0.addingTimeInterval(60))
expect(runs() == ["\(t3)|<unset>"], "within the hold the account goes straight to the old read (\(runs()))")
resetLog()
_ = await ClaudeUsageCLI.fetchUsageText(configDir: t3, executable: stub.path, probeHomeRoot: probeRoot,
                                        now: t0.addingTimeInterval(ClaudeUsageCLI.legacyHold))
expect(runs().first == "\(probeRoot.path)/claudeT3|\(t3)", "after the hold the isolated read is tried again")

// T4: a genuinely signed-out account still reports signed out, and convicts nothing.
resetLog()
let t4 = dir.appendingPathComponent(".claudeT4").path
try routedStub(isolated: notLoggedIn, legacy: notLoggedIn)
let t4Text = await ClaudeUsageCLI.fetchUsageText(configDir: t4, executable: stub.path, probeHomeRoot: probeRoot)
expect(t4Text.map(ClaudeUsageCLI.authenticationRejected) == true, "signed out on both reads stays signed out")
resetLog()
_ = await ClaudeUsageCLI.fetchUsageText(configDir: t4, executable: stub.path, probeHomeRoot: probeRoot)
expect(runs().count == 2, "no hold was recorded, so the isolated read is tried again")

// T5: the isolated home drops the model window the old read has: take the old read, hold.
resetLog()
let t5 = dir.appendingPathComponent(".claudeT5").path
try routedStub(isolated: twoWindows, legacy: threeWindows)
let t5Text = await ClaudeUsageCLI.fetchUsageText(configDir: t5, executable: stub.path, probeHomeRoot: probeRoot)
expect(metricIDs(t5Text) == fullIDs, "a missing flagship window is not accepted from the isolated read")
expect(runs() == ["\(probeRoot.path)/claudeT5|\(t5)", "\(t5)|<unset>"],
       "the isolated read was tried first and the old read replaced it (\(runs()))")
resetLog()
_ = await ClaudeUsageCLI.fetchUsageText(configDir: t5, executable: stub.path, probeHomeRoot: probeRoot)
expect(runs() == ["\(t5)|<unset>"], "and the account is held on the old read")

// T6: an account with no model window at all is confirmed once, then read isolated only.
resetLog()
let t6 = dir.appendingPathComponent(".claudeT6").path
try routedStub(isolated: twoWindows, legacy: twoWindows)
_ = await ClaudeUsageCLI.fetchUsageText(configDir: t6, executable: stub.path, probeHomeRoot: probeRoot)
expect(runs().count == 2, "the first two-window reading is checked against the old read")
resetLog()
let t6Text = await ClaudeUsageCLI.fetchUsageText(configDir: t6, executable: stub.path, probeHomeRoot: probeRoot)
expect(runs() == ["\(probeRoot.path)/claudeT6|\(t6)"] && metricIDs(t6Text) == ["session", "weekly_all"],
       "once confirmed, the isolated read alone is enough")

// T7: a transient failure on the isolated read falls back but records no hold.
resetLog()
let t7 = dir.appendingPathComponent(".claudeT7").path
try routedStub(isolated: "printf 'Network disconnected\\n' >&2\nexit 1", legacy: threeWindows)
let t7Text = await ClaudeUsageCLI.fetchUsageText(configDir: t7, executable: stub.path, probeHomeRoot: probeRoot)
expect(metricIDs(t7Text) == fullIDs, "a network failure on the isolated read still gets the old read")
resetLog()
_ = await ClaudeUsageCLI.fetchUsageText(configDir: t7, executable: stub.path, probeHomeRoot: probeRoot)
expect(runs().first == "\(probeRoot.path)/claudeT7|\(t7)", "a transient failure does not hold the account")

// T8: an existing home with loose permissions is tightened before use.
resetLog()
let t8 = dir.appendingPathComponent(".claudeT8").path
let looseRoot = dir.appendingPathComponent("loose-root")
try FileManager.default.createDirectory(at: looseRoot.appendingPathComponent("claudeT8"),
                                        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: looseRoot.path)
try routedStub(isolated: threeWindows, legacy: notLoggedIn)
_ = await ClaudeUsageCLI.fetchUsageText(configDir: t8, executable: stub.path, probeHomeRoot: looseRoot)
for path in [looseRoot.path, looseRoot.path + "/claudeT8"] {
    let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
    expect(mode?.intValue == 0o700, "loose permissions are repaired to 0700 (\(path))")
}

// T9: a home that is a file, or a root that is a symlink, is never used: old read only.
resetLog()
let t9 = dir.appendingPathComponent(".claudeT9").path
let fileRoot = dir.appendingPathComponent("file-root")
try FileManager.default.createDirectory(at: fileRoot, withIntermediateDirectories: true)
try Data().write(to: fileRoot.appendingPathComponent("claudeT9"))
try routedStub(isolated: notLoggedIn, legacy: threeWindows)
_ = await ClaudeUsageCLI.fetchUsageText(configDir: t9, executable: stub.path, probeHomeRoot: fileRoot)
expect(runs() == ["\(t9)|<unset>"], "a file in the home's place sends the read down the old path")
resetLog()
let t9b = dir.appendingPathComponent(".claudeT9b").path
let linkRoot = dir.appendingPathComponent("link-root")
try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: probeRoot)
_ = await ClaudeUsageCLI.fetchUsageText(configDir: t9b, executable: stub.path, probeHomeRoot: linkRoot)
expect(runs() == ["\(t9b)|<unset>"], "a symlinked root sends the read down the old path")

unsetenv("CLAUDE_SECURESTORAGE_CONFIG_DIR")

// Pure verdicts, no process.
expect(ClaudeUsageCLI.isolatedVerdict(nil, shapeVerified: true) == .fallBack(.noOutput), "nil is a transient fallback")
expect(ClaudeUsageCLI.memoryUpdate(reason: .noOutput, legacy: "Current session: 1% used") == .none,
       "a transient failure never holds")
expect(ClaudeUsageCLI.probeHomeName(configDir: nil) == "claude"
       && ClaudeUsageCLI.probeHomeName(configDir: "/Users/x/.claude-work") == "claude-work",
       "probe home names drop the leading dot")
usageHealth.record(accountID: account, authenticated: true)
expect(!usageHealth.needsSignIn(account, local: .signedIn), "a genuine usage success clears the failure")
expect(usageHealth.needsSignIn(account, local: .signedOut), "original signed-out verdict still warns")
var generations = LoginProbeGate.Landings()
let beforeRenewal = generations.mark
usageHealth.record(accountID: account, authenticated: true)
generations.land([account])
expect(!usageHealth.recordIfCurrent(accountID: account, authenticated: false,
                                   since: beforeRenewal, landings: generations),
       "usage rejection started before renewal cannot overwrite the renewed login")
expect(!usageHealth.needsSignIn(account, local: .signedIn), "the renewed account stays healthy")
let beforeRemoval = generations.mark
generations.land([account])
expect(!usageHealth.recordIfCurrent(accountID: account, authenticated: false,
                                   since: beforeRemoval, landings: generations),
       "a removed account cannot be revived by an old provider callback")
let afterLanding = generations.mark
expect(usageHealth.recordIfCurrent(accountID: account, authenticated: false,
                                  since: afterLanding, landings: generations),
       "a fresh provider rejection still records its evidence")
var perAccount = LoginAlertState()
let firstCallback = LoginUsageHealth.updateAlert(state: perAccount, accountID: "a", authenticated: false)
perAccount = firstCallback.0
let secondCallback = LoginUsageHealth.updateAlert(state: perAccount, accountID: "b", authenticated: false)
perAccount = secondCallback.0
expect(perAccount.announced == ["a", "b"], "partial provider callbacks preserve both account outages")
expect(LoginUsageHealth.updateAlert(state: perAccount, accountID: "a", authenticated: false).1.isEmpty,
       "the second provider callback cannot rearm the first account")
perAccount = LoginUsageHealth.updateAlert(state: perAccount, accountID: "b", authenticated: true).0
expect(perAccount.announced == ["a"], "a successful provider callback clears only its own outage")
print("loginhealth: \(passed) passed")
