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
let failure = await ClaudeUsageCLI.fetchUsageText(configDir: dir.path, executable: stub.path)
expect(failure.map(ClaudeUsageCLI.authenticationRejected) == true, "nonzero official usage auth failure survives the reader")
usageHealth.record(accountID: account, authenticated: false)
expect(usageHealth.needsSignIn(account, local: .signedIn), "usage rejection remains visible with local auth status true")
expect(usageHealth.applying(to: localSignedIn)[account] == .signedOut, "local success cannot rearm usage rejection notifications")
for text in ["HTTP 429: rate limited", "Network disconnected", "Visit docs for /login options", ""] {
    expect(!ClaudeUsageCLI.authenticationRejected(text), "unrelated output is not an authentication rejection")
}
try script("printf 'Network disconnected\\n' >&2\nexit 1")
let network = await ClaudeUsageCLI.fetchUsageText(configDir: dir.path, executable: stub.path)
expect(network == nil, "nonzero network error remains a read failure")
expect(usageHealth.needsSignIn(account, local: .signedIn), "unknown usage failure does not clear prior authentication failure")
try script("printf 'Current session: 12%% used\\n'\nexit 0")
let success = await ClaudeUsageCLI.fetchUsageText(configDir: dir.path, executable: stub.path)
expect(success.map { !ClaudeUsageTextMapper.map(text: $0).isEmpty } == true,
       "successful official usage output produces actual metrics")
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
