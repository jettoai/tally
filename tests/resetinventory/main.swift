import Foundation

// Claude limit-reset inventory (ClaudeResetInventory.swift): the `cedar_ember` parser, Claude
// Code's kind rule, the in-force count, the credential path's promise that the access token
// reaches the Authorization header and nothing else, Claude Code's client name on the request
// (ClaudeResetInventoryFetch.swift), and which reading a home keeps when its login changes hands
// (ClaudeResetInventoryLedger.swift).

var passed = 0
var failed = 0
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { passed += 1 } else { failed += 1; print("FAIL: \(label)") }
}
func data(_ text: String) -> Data { Data(text.utf8) }
func iso(_ text: String) -> Date { ClaudeResetInventory.date(text)! }

let now = iso("2026-11-11T12:00:00+00:00")

// The two grants of a Max account, as the endpoint returned them (2026-11-11).
let fullGrant = """
{"id": "full-reset-2611", "label": "One full limit reset (November 2026)",
 "resets_total": 1, "resets_left": 1,
 "starts_at": "2026-11-10T21:30:00+00:00", "ends_at": "2026-12-10T22:00:00+00:00",
 "clears": ["five_hour","seven_day","seven_day_overage_included"],
 "paused": false, "usable_now": true, "use_requires_limit": false,
 "percent_used": {"five_hour":15,"seven_day":84,"seven_day_overage_included":71},
 "blocking": [], "arm": null, "type": "full", "unavailable_reason": null, "gives_back_weekly": false}
"""
let fableGrant = """
{"id": "launch-2610-fable", "label": "New model launch: one Fable reset for Max, Team Premium and Enterprise Premium",
 "resets_total": 1, "resets_left": 1,
 "starts_at": "2026-11-09T18:00:00+00:00", "ends_at": "2027-03-09T07:59:00+00:00",
 "clears": ["five_hour","seven_day_overage_included"],
 "paused": false, "usable_now": true, "use_requires_limit": false,
 "percent_used": {"five_hour":15,"seven_day_overage_included":71,"seven_day":84},
 "blocking": [], "arm": null, "type": "full", "unavailable_reason": null, "gives_back_weekly": true}
"""
func body(_ grants: [String], eligible: String = "true") -> Data {
    data("""
    {"five_hour": {"utilization": 15}, "cedar_ember": {
      "eligible": \(eligible), "ineligible_reason": null, "at_limit": false, "exhausted": [],
      "grants": [\(grants.joined(separator: ","))],
      "next_grant_id": "full-reset-2611", "weekly_resets_at": "2026-11-11T20:00:00+00:00",
      "cooldown_until": null, "event_props": {}, "paused_held": false}}
    """)
}

// MARK: The Max account: a full reset and a Fable reset whose type also says "full"
let max = ClaudeResetInventory.parse(body([fullGrant, fableGrant]), now: now)
expect(max?.eligible == true, "max: eligible")
expect(max?.grants.map(\.kind) == [.full, .fable], "max: gives_back_weekly wins over type full")
expect(max?.left == 2, "max: two resets left in total")
expect(max?.byKind.map(\.kind) == [.full, .fable], "max: soonest-ending kind first")
expect(max?.byKind.first?.endsAt == iso("2026-12-10T22:00:00+00:00"), "max: the full reset's end")
expect(max?.byKind.last?.endsAt == iso("2027-03-09T07:59:00+00:00"), "max: the Fable reset's end")
expect(max.map { !String(describing: $0).contains("full-reset-2611") && !String(describing: $0).contains("launch-2610") } == true,
       "max: grant ids do not survive the parse")

// MARK: The Pro account: one week-long Fable reset
let proGrant = """
{"id": "launch-2610-fable-week", "resets_total": 1, "resets_left": 1,
 "starts_at": "2026-11-09T18:00:00+00:00", "ends_at": "2026-11-17T07:59:00+00:00",
 "clears": ["five_hour","seven_day_overage_included"], "paused": false, "type": "full",
 "gives_back_weekly": true}
"""
let pro = ClaudeResetInventory.parse(body([proGrant]), now: now)
expect(pro?.byKind.count == 1 && pro?.byKind.first?.kind == .fable && pro?.byKind.first?.left == 1,
       "pro: one Fable reset")

// MARK: Outside the program
let ineligible = data("""
{"cedar_ember": {"eligible": false, "ineligible_reason": "plan_not_eligible", "grants": []}}
""")
expect(ClaudeResetInventory.parse(ineligible, now: now) == ClaudeResetInventory(eligible: false, grants: []),
       "eligible false: no inventory")
expect(ClaudeResetInventory.parse(body([fullGrant], eligible: "false"), now: now)?.grants.isEmpty == true,
       "eligible false: grants listed anyway are not counted")
expect(ClaudeResetInventory.parse(data("{\"cedar_ember\": null}"), now: now)?.eligible == false,
       "cedar_ember null: no inventory")
expect(ClaudeResetInventory.parse(data("{\"five_hour\": {}}"), now: now)?.eligible == false,
       "cedar_ember missing: no inventory")
expect(ClaudeResetInventory.parse(body([fullGrant], eligible: "\"yes\""), now: now) == nil,
       "eligible not a boolean: cannot tell, not ineligible")
expect(ClaudeResetInventory.parse(data("{\"cedar_ember\": \"on\"}"), now: now) == nil,
       "cedar_ember not an object: cannot tell")
for text in ["", "{", "[]", "null", "\"cedar_ember\"", "<html>rate limited</html>"] {
    expect(ClaudeResetInventory.parse(data(text), now: now) == nil, "unreadable body \(text) is unknown, not empty")
}

// MARK: Grants that do not count
func variant(_ grant: String, _ edits: [(String, String)]) -> String {
    edits.reduce(grant) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
}
let expired = variant(fullGrant, [("\"ends_at\": \"2026-12-10T22:00:00+00:00\"", "\"ends_at\": \"2026-11-11T11:59:59+00:00\"")])
let future = variant(fullGrant, [("\"starts_at\": \"2026-11-10T21:30:00+00:00\"", "\"starts_at\": \"2026-11-12T00:00:00+00:00\"")])
let paused = variant(fullGrant, [("\"paused\": false", "\"paused\": true")])
let endsNow = variant(fullGrant, [("\"ends_at\": \"2026-12-10T22:00:00+00:00\"", "\"ends_at\": \"2026-11-11T12:00:00+00:00\"")])
expect(ClaudeResetInventory.parse(body([expired, fableGrant]), now: now)?.grants.map(\.kind) == [.fable],
       "expired grant dropped, the rest kept")
expect(ClaudeResetInventory.parse(body([endsNow]), now: now)?.grants.isEmpty == true, "a grant ending now is over")
expect(ClaudeResetInventory.parse(body([future]), now: now)?.grants.isEmpty == true, "a grant not started yet is not counted")
expect(ClaudeResetInventory.parse(body([paused]), now: now)?.grants.isEmpty == true, "paused grant not counted")
let broken = [
    variant(fullGrant, [("\"resets_left\": 1", "\"resets_left\": \"one\"")]),
    variant(fullGrant, [("\"resets_left\": 1", "\"resets_left\": true")]),
    variant(fullGrant, [("\"resets_left\": 1", "\"resets_left\": 1.5")]),
    variant(fullGrant, [("\"resets_left\": 1", "\"resets_left\": -1")]),
    variant(fullGrant, [("\"resets_left\": 1,", "")]),
    variant(fullGrant, [("\"ends_at\": \"2026-12-10T22:00:00+00:00\"", "\"ends_at\": \"next month\"")]),
    variant(fullGrant, [("\"starts_at\": \"2026-11-10T21:30:00+00:00\",", "")]),
    variant(fullGrant, [("\"paused\": false", "\"paused\": \"no\"")]),
    variant(fullGrant, [("\"gives_back_weekly\": false", "\"gives_back_weekly\": 0")]),
    variant(fullGrant, [("\"type\": \"full\"", "\"type\": 3")]),
    variant(fullGrant, [("\"type\": \"full\"", "\"type\": null"),
                        ("\"clears\": [\"five_hour\",\"seven_day\",\"seven_day_overage_included\"]", "\"clears\": []")]),
    "\"not an object\"", "17",
]
for grant in broken {
    expect(ClaudeResetInventory.parse(body([grant, fableGrant]), now: now) == nil,
           "one unreadable grant fails the whole read, not a shorter list: \(grant.prefix(60))")
}
// Out of scope is decided from starts_at, ends_at and paused alone: a lapsed grant in some other
// shape is skipped, it does not fail the read.
let lapsedOdd = variant(expired, [("\"resets_left\": 1", "\"resets_left\": \"one\""), ("\"type\": \"full\"", "\"type\": 3")])
let pausedOdd = variant(paused, [("\"gives_back_weekly\": false", "\"gives_back_weekly\": 0")])
expect(ClaudeResetInventory.parse(body([lapsedOdd, pausedOdd, fableGrant]), now: now)?.grants.map(\.kind) == [.fable],
       "out-of-scope grants are skipped even when another field is odd")
for grants in ["{}", "null", "\"none\""] {
    let text = "{\"cedar_ember\": {\"eligible\": true, \"grants\": \(grants)}}"
    expect(ClaudeResetInventory.parse(data(text), now: now) == nil, "eligible with grants \(grants): cannot tell, not empty")
}
expect(ClaudeResetInventory.parse(data("{\"cedar_ember\": {\"eligible\": true}}"), now: now) == nil,
       "eligible with no grants key: cannot tell, not empty")
let spent = variant(fullGrant, [("\"resets_left\": 1", "\"resets_left\": 0")])
let none = ClaudeResetInventory.parse(body([spent]), now: now)
expect(none?.eligible == true && none?.left == 0 && none?.byKind.isEmpty == true && none?.grants.count == 1,
       "eligible with nothing left: in force, zero, no line")
expect(ClaudeResetInventory.parse(body([]), now: now) == ClaudeResetInventory(eligible: true, grants: []),
       "eligible with no grants: empty inventory")
let twoFull = variant(fullGrant, [("\"resets_left\": 1", "\"resets_left\": 2"), ("\"resets_total\": 1", "\"resets_total\": 2"),
                                  ("\"ends_at\": \"2026-12-10T22:00:00+00:00\"", "\"ends_at\": \"2026-11-30T00:00:00.500+00:00\"")])
let summed = ClaudeResetInventory.parse(body([fullGrant, twoFull]), now: now)
expect(summed?.byKind.count == 1 && summed?.byKind.first?.left == 3, "same kind: counts summed")
expect(summed?.byKind.first?.endsAt == iso("2026-11-30T00:00:00.500+00:00"), "same kind: soonest end, fractional seconds read")

// MARK: Claude Code's kind rule
typealias K = ClaudeResetInventory
expect(K.kind(givesBackWeekly: true, type: "session", clears: ["five_hour"]) == .fable, "rule: weekly give-back is Fable")
expect(K.kind(givesBackWeekly: false, type: "weekly", clears: ["five_hour"]) == .weekly, "rule: a known type names it")
expect(K.kind(givesBackWeekly: false, type: nil, clears: ["five_hour"]) == .session, "rule: only five_hour is a 5-hour reset")
expect(K.kind(givesBackWeekly: false, type: nil, clears: ["seven_day"]) == .weekly, "rule: no five_hour is weekly")
expect(K.kind(givesBackWeekly: false, type: nil, clears: ["five_hour", "seven_day"]) == .full, "rule: both is full")
expect(K.kind(givesBackWeekly: false, type: nil, clears: []) == .full, "rule: nothing named reads as full")
expect(K.kind(givesBackWeekly: false, type: "renamed", clears: ["five_hour"]) == .other,
       "rule: an unknown type is its own kind, not read off the windows")
expect(K.kind(givesBackWeekly: true, type: "renamed", clears: ["five_hour"]) == .fable,
       "rule: weekly give-back still wins over an unknown type")
let renamed = variant(fullGrant, [("\"type\": \"full\"", "\"type\": \"renamed\""),
                                  ("\"clears\": [\"five_hour\",\"seven_day\",\"seven_day_overage_included\"]", "\"clears\": [\"five_hour\"]")])
let renamedRead = ClaudeResetInventory.parse(body([renamed]), now: now)
expect(renamedRead?.grants.first?.kind == .other && renamedRead?.grants.first?.name == "renamed",
       "unknown type: kind other, the raw type kept for the snapshot")
expect(max?.grants.map(\.name) == ["full", "fable"], "known kinds: the snapshot name is the kind")

// MARK: The credential never leaves the request
let token = "sk-ant-oat01-FIXTURE-SECRET-\(UUID().uuidString)"
func blob(expiresAt: String, token: String = token) -> Data {
    data("{\"claudeAiOauth\":{\"accessToken\":\"\(token)\",\"refreshToken\":\"r-\(token)\",\"expiresAt\":\(expiresAt),\"refreshTokenExpiresAt\":1891617039890}}")
}
let live = Int((now.timeIntervalSince1970 + 3_600) * 1000)
let credential = ClaudeResetInventoryFetch.credential(from: blob(expiresAt: "\(live)"), now: now)
expect(credential != nil, "credential: a live token is usable")
if let credential {
    var dumped = ""
    dump(credential, to: &dumped)
    let printed = [String(describing: credential), String(reflecting: credential), "\(credential)", dumped,
                   Mirror(reflecting: credential).children.map { "\($0.label ?? ""):\($0.value)" }.joined()]
    expect(printed.allSatisfy { !$0.contains(token) && !$0.contains("FIXTURE-SECRET") },
           "credential: no description, debug print, dump or mirror carries the token")
    let request = ClaudeResetInventoryFetch.request(credential, version: "2.1.311")
    expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.311 (external, cli)",
           "request: Claude Code's own User-Agent")
    expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)", "request: token only as bearer")
    expect(request.url?.absoluteString.contains(token) == false, "request: token not in the URL")
    expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1",
           "request: Claude Code's endpoint")
    expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20", "request: oauth beta header")
    expect(request.httpMethod == "GET" && request.httpBody == nil, "request: a GET with no body")
    let others = (request.allHTTPHeaderFields ?? [:]).filter { $0.key != "Authorization" }
    expect(!others.values.contains { $0.contains(token) }, "request: no other header carries the token")
    expect(!String(describing: request).contains(token), "request: its description does not carry the token")
}

// MARK: Claude Code's version, read off the launcher's symlink
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("resetinventory-\(UUID().uuidString)")
let versions = scratch.appendingPathComponent("versions")
let bin = scratch.appendingPathComponent("bin")
try! FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
func link(_ name: String, to target: String) -> String {
    let path = bin.appendingPathComponent(name).path
    try! FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    return path
}
FileManager.default.createFile(atPath: versions.appendingPathComponent("2.1.400").path, contents: Data())
FileManager.default.createFile(atPath: versions.appendingPathComponent("cli.js").path, contents: Data())
FileManager.default.createFile(atPath: versions.appendingPathComponent("2.1.400 (evil)").path, contents: Data())
typealias F = ClaudeResetInventoryFetch
expect(F.version(executable: link("claude", to: versions.appendingPathComponent("2.1.400").path)) == "2.1.400",
       "version: the symlink target's last component")
expect(F.version(executable: link("relative", to: "../versions/2.1.400")) == "2.1.400", "version: a relative symlink")
expect(F.version(executable: link("npm", to: versions.appendingPathComponent("cli.js").path)) == F.fallbackVersion,
       "version: not x.y.z falls back")
expect(F.version(executable: link("odd", to: versions.appendingPathComponent("2.1.400 (evil)").path)) == F.fallbackVersion,
       "version: anything past x.y.z falls back, so the header stays clean")
expect(F.version(executable: versions.appendingPathComponent("cli.js").path) == F.fallbackVersion,
       "version: a plain file named otherwise falls back")
expect(F.version(executable: nil) == F.fallbackVersion, "version: no CLI found falls back")
expect(F.fallbackVersion == "2.1.311" && F.userAgent(version: F.fallbackVersion) == "claude-cli/2.1.311 (external, cli)",
       "version: the fallback User-Agent")
try? FileManager.default.removeItem(at: scratch)

// MARK: The log line's program fields carry no grant
let fields = ClaudeResetInventory.programFields(body([fullGrant, fableGrant]))
expect(fields == ("present", "true", "-"), "log: an eligible block")
let why = ClaudeResetInventory.programFields(ineligible)
expect(why == ("present", "false", "plan_not_eligible"), "log: the ineligible reason")
expect(ClaudeResetInventory.programFields(data("{\"five_hour\": {}}")) == ("absent", "-", "-"), "log: no block")
expect(ClaudeResetInventory.programFields(data("{\"cedar_ember\": null}")) == ("null", "-", "-"), "log: a null block")
let longReason = String(repeating: "x", count: 200)
expect(ClaudeResetInventory.programFields(data("{\"cedar_ember\": {\"eligible\": false, \"ineligible_reason\": \"\(longReason)\"}}")).reason.count == 64,
       "log: a long reason is cut")
expect(![fields.block, fields.eligible, fields.reason].joined().contains("full-reset-2611"), "log: no grant id")

let outcomes: [ClaudeResetInventoryFetch.Outcome] = [.noCredential, .failed(status: 401), .failed(status: nil)]
expect(outcomes.allSatisfy { !String(describing: $0).contains(token) }, "outcome: failures carry a status only")

let expiredToken = Int((now.timeIntervalSince1970 - 1) * 1000)
let almost = Int((now.timeIntervalSince1970 + 30) * 1000)
expect(ClaudeResetInventoryFetch.credential(from: blob(expiresAt: "\(expiredToken)"), now: now) == nil,
       "credential: expired token is not used (no refresh)")
expect(ClaudeResetInventoryFetch.credential(from: blob(expiresAt: "\(almost)"), now: now) == nil,
       "credential: a token inside a minute of expiry is not used")
for value in ["null", "\"\(live)\"", "true", "1891617039", "1e309"] {
    expect(ClaudeResetInventoryFetch.credential(from: blob(expiresAt: value), now: now) == nil,
           "credential: undated or oddly dated token \(value) is not used")
}
expect(ClaudeResetInventoryFetch.credential(from: blob(expiresAt: "\(live)", token: ""), now: now) == nil,
       "credential: empty token is not used")
expect(ClaudeResetInventoryFetch.credential(from: data("{}"), now: now) == nil, "credential: no oauth block")

// MARK: Which credential is read: the Keychain item wins as a whole
let home = "/tmp/fixture/.claude2"
let defaultHome = "/tmp/fixture-home/.claude"
var fileReads = 0
func read(_ source: ClaudeLoginExpiry.Source, file: Data?) -> ClaudeResetInventoryFetch.Credential? {
    ClaudeResetInventoryFetch.readCredential(home: home, defaultHome: defaultHome, now: now,
                                             keychainRead: { _ in source },
                                             fileRead: { _ in fileReads += 1; return file })
}
let good = blob(expiresAt: "\(live)")
expect(read(.init(data: good), file: nil) != nil, "keychain: a readable item is used")
expect(read(.init(data: data("not json")), file: good) == nil && fileReads == 0,
       "keychain: a malformed item does not fall back to the file")
expect(read(.init(data: nil), file: good) == nil && fileReads == 0,
       "keychain: a locked or denied item does not fall back to the file (and never prompts)")
expect(read(.init(data: nil, isAbsent: true), file: good) != nil && fileReads == 1,
       "keychain: only an absent item falls back to .credentials.json")
var services: [String] = []
_ = ClaudeResetInventoryFetch.readCredential(home: home, defaultHome: defaultHome, now: now,
                                             keychainRead: { services.append($0); return .init(data: nil) },
                                             fileRead: { _ in nil })
expect(services == [ClaudeLoginExpiry.keychainService(home: home, defaultHome: defaultHome)],
       "keychain: the login-expiry service name is reused")

// MARK: A reading belongs to the login it was taken under (ClaudeResetInventoryLedger)
let a = "claude:.claude2"
let readA = ClaudeResetInventory.parse(body([fullGrant, fableGrant]), now: now)!
let readB = ClaudeResetInventory(eligible: true, grants: [])
func fresh() -> (ClaudeResetInventoryLedger, Int) {
    var ledger = ClaudeResetInventoryLedger()
    ledger.prune(known: [a])
    let generation = ledger.begin(a, now: now, wait: 600)!
    _ = ledger.land(a, generation: generation, outcome: .read(readA), identity: "uuid-A", now: now)
    return (ledger, generation)
}
do {
    var (ledger, _) = fresh()
    expect(ledger.entries[a]?.inventory == readA, "ledger: a read is kept")
    expect(ledger.begin(a, now: now.addingTimeInterval(60), wait: 600) == nil, "ledger: not asked again inside the interval")
    expect(ledger.invalidate(a) && ledger.entries[a] == nil, "ledger: a login landing drops the reading")
    expect(ledger.begin(a, now: now.addingTimeInterval(60), wait: 600) != nil, "ledger: and the next round asks at once")
}
do {
    // A's request is out when B signs in: A's answer comes back after and must not land on B.
    var (ledger, _) = fresh()
    let out = ledger.begin(a, now: now.addingTimeInterval(700), wait: 600)!
    ledger.invalidate(a)
    let next = ledger.begin(a, now: now.addingTimeInterval(701), wait: 600)!
    expect(next != out, "ledger: the request after a login goes out under a new generation")
    expect(!ledger.land(a, generation: out, outcome: .read(readA), identity: "uuid-A", now: now) && ledger.entries[a] == nil,
           "ledger: the old login's answer is refused")
    expect(ledger.land(a, generation: next, outcome: .read(readB), identity: "uuid-B", now: now)
               && ledger.entries[a]?.inventory == readB, "ledger: the new login's answer lands")
}
do {
    // Signed into B in the same home with no login event Tally saw: the config names B now.
    var (ledger, _) = fresh()
    expect(!ledger.note(a, identity: nil) && ledger.entries[a] != nil, "ledger: a config naming nobody changes nothing")
    expect(!ledger.note(a, identity: "uuid-A") && ledger.entries[a] != nil, "ledger: the same login keeps its reading")
    expect(ledger.note(a, identity: "uuid-B") && ledger.entries[a] == nil, "ledger: another login drops the reading")
}
do {
    // A failed read under another login does not keep A's reading on show as stale.
    var (ledger, _) = fresh()
    let out = ledger.begin(a, now: now.addingTimeInterval(700), wait: 600)!
    _ = ledger.land(a, generation: out, outcome: .failed(status: 429), identity: "uuid-B", now: now)
    expect(ledger.entries[a] == nil, "ledger: a failure under another login drops the reading")
    var (same, _) = fresh()
    let again = same.begin(a, now: now.addingTimeInterval(700), wait: 600)!
    _ = same.land(a, generation: again, outcome: .failed(status: 429), identity: "uuid-A", now: now.addingTimeInterval(700))
    expect(same.entries[a]?.isStale == true && same.entries[a]?.checkedAt == now && same.entries[a]?.inventory == readA,
           "ledger: a failure under the same login holds the reading over, stale")
}
do {
    var (ledger, _) = fresh()
    let out = ledger.begin(a, now: now.addingTimeInterval(700), wait: 600)!
    ledger.prune(known: [])
    expect(ledger.entries.isEmpty && !ledger.land(a, generation: out, outcome: .read(readA), identity: "uuid-A", now: now)
               && ledger.entries.isEmpty, "ledger: an account gone takes its reading, and a late answer, with it")
}

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED, \(passed) passed")
exit(failed == 0 ? 0 : 1)
