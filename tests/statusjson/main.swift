import Foundation

// Assertion harness for the `tally status --json` public contract (StatusReport in
// TallyCLI/Snapshot.swift). Structural checks parse the encoded string back with
// JSONSerialization, so they hold regardless of JSONEncoder's whitespace choices.

var passed = 0, failed = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

let now = parseISO("2026-07-23T12:00:00Z")!

let fixture = """
{
  "version": 2,
  "generatedAt": "2026-07-23T11:55:00Z",
  "accounts": [
    { "id": "claude:.claude", "provider": "claude", "label": "Claude",
      "launchHome": "/Users/u/.claude", "isStale": false,
      "sessionRemaining": 80, "sessionResetsAt": "2026-07-23T14:00:00Z",
      "weeklyRemaining": 60, "weeklyResetsAt": "2026-07-27T12:00:00Z",
      "modelWindowName": "Fable", "modelRemaining": 50,
      "modelResetsAt": "2026-07-27T12:00:00Z" },
    { "id": "claude:.claude2", "provider": "claude", "label": "Claude 2",
      "launchHome": "/Users/u/.claude2", "isStale": false,
      "sessionRemaining": 10, "sessionResetsAt": "2026-07-23T16:00:00Z",
      "weeklyRemaining": 5, "weeklyResetsAt": "2026-07-29T12:00:00Z",
      "modelWindowName": "Fable", "modelRemaining": 5,
      "modelResetsAt": "2026-07-29T12:00:00Z" },
    { "id": "codex:.codex", "provider": "codex", "label": "Codex",
      "launchHome": "/Users/u/.codex", "isStale": false,
      "weeklyRemaining": 58, "weeklyResetsAt": "2026-07-29T02:00:00Z",
      "resetCreditsAvailable": 3 },
    { "id": "gemini:.gemini", "provider": "gemini", "label": "Gemini",
      "launchHome": "/Users/u/.gemini", "isStale": false,
      "weeklyRemaining": 90, "weeklyResetsAt": "2026-07-29T02:00:00Z" }
  ]
}
"""

func decodeSnapshot(_ json: String) -> Snapshot {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(Snapshot.self, from: Data(json.utf8))
}

func parse(_ encoded: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(encoded.utf8))) as? [String: Any] ?? [:]
}

func accounts(_ top: [String: Any]) -> [[String: Any]] {
    top["accounts"] as? [[String: Any]] ?? []
}

func account(_ top: [String: Any], _ id: String) -> [String: Any] {
    accounts(top).first { $0["id"] as? String == id } ?? [:]
}

let snapshot = decodeSnapshot(fixture)

// MARK: auto policy - headroom pick gets the marker, unknown providers pass through
let auto = parse(encodeStatusReport(
    statusReport(snapshot, policies: ["claude": LaunchPolicy(), "codex": LaunchPolicy()], now: now)))
check("contract version is 1", auto["version"] as? Int == 1)
check("fresh snapshot is not stale", auto["stale"] as? Bool == false)
check("generatedAt is ISO8601", auto["generatedAt"] as? String == "2026-07-23T11:55:00Z")
check("every snapshot account passes through", accounts(auto).count == 4)
check("auto: healthier claude account is best",
      account(auto, "claude:.claude")["best"] as? Bool == true)
check("auto: drained sibling is not best",
      account(auto, "claude:.claude2")["best"] as? Bool == false)
check("auto: nothing is pinned",
      accounts(auto).allSatisfy { $0["pinned"] as? Bool == false })
check("codex best is assigned too", account(auto, "codex:.codex")["best"] as? Bool == true)
check("unknown provider passes through without a pick",
      account(auto, "gemini:.gemini")["best"] as? Bool == false)
check("account fields mirror the snapshot",
      account(auto, "claude:.claude")["weeklyRemaining"] as? Double == 60
          && account(auto, "claude:.claude")["modelWindowName"] as? String == "Fable"
          && account(auto, "claude:.claude")["sessionResetsAt"] as? String == "2026-07-23T14:00:00Z")
check("nil fields are omitted, not null",
      account(auto, "claude:.claude")["error"] == nil
          && account(auto, "claude:.claude")["resetCreditsAvailable"] == nil)
check("codex reset banking is carried",
      account(auto, "codex:.codex")["resetCreditsAvailable"] as? Int == 3)

// MARK: manual pin - the pin is the launch target even when it is the weaker account
let pinned = parse(encodeStatusReport(statusReport(
    snapshot,
    policies: ["claude": LaunchPolicy(mode: "manual", pinnedAccountID: "claude:.claude2")],
    now: now)))
check("pin: pinned account is best", account(pinned, "claude:.claude2")["best"] as? Bool == true)
check("pin: pinned account is flagged", account(pinned, "claude:.claude2")["pinned"] as? Bool == true)
check("pin: healthier sibling loses the marker",
      account(pinned, "claude:.claude")["best"] as? Bool == false)

// MARK: manual pin to a vanished account - falls back to the headroom pick (mirrors runLaunch)
let ghost = parse(encodeStatusReport(statusReport(
    snapshot,
    policies: ["claude": LaunchPolicy(mode: "manual", pinnedAccountID: "claude:.gone")],
    now: now)))
check("ghost pin: headroom pick takes over", account(ghost, "claude:.claude")["best"] as? Bool == true)
check("ghost pin: nothing is flagged pinned",
      accounts(ghost).allSatisfy { $0["pinned"] as? Bool == false })

// MARK: vanished pin with a saved pinnedHome - runLaunch launches BY HOME, the JSON must agree
let homePin = parse(encodeStatusReport(statusReport(
    snapshot,
    policies: ["claude": LaunchPolicy(mode: "manual", pinnedAccountID: "claude:.gone",
                                      pinnedHome: "/Users/u/.claude2")],
    now: now)))
check("home pin: the account owning the pinned home is best",
      account(homePin, "claude:.claude2")["best"] as? Bool == true)
check("home pin: it is flagged pinned",
      account(homePin, "claude:.claude2")["pinned"] as? Bool == true)
check("home pin: the headroom favourite loses the marker",
      account(homePin, "claude:.claude")["best"] as? Bool == false)

// MARK: pinnedHome owned by NO listed account - the launch lands outside the list, no marker
let orphanHome = parse(encodeStatusReport(statusReport(
    snapshot,
    policies: ["claude": LaunchPolicy(mode: "manual", pinnedAccountID: "claude:.gone",
                                      pinnedHome: "/Users/u/.claude9")],
    now: now)))
check("orphan home pin: no claude account claims best",
      accounts(orphanHome).filter { $0["provider"] as? String == "claude" }
          .allSatisfy { $0["best"] as? Bool == false })

// MARK: staleness - an old snapshot is reported, not hidden
let old = parse(encodeStatusReport(statusReport(
    snapshot, policies: [:], now: parseISO("2026-07-23T13:00:00Z")!)))
check("snapshot older than the trust window reports stale", old["stale"] as? Bool == true)

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
