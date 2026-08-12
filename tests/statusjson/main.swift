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
  ],
  "fleet": {
    "claude": { "remaining": 91, "capacity": 200, "sustainable": true }
  },
  "fleetPools": {
    "claude": [
      { "poolName": "Fable", "remaining": 2, "capacity": 200,
        "dryAt": "2026-07-23T12:13:00Z", "sustainable": false },
      { "remaining": 91, "capacity": 200, "sustainable": true }
    ]
  }
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

// MARK: a pin whose account SIGNED OUT - the launcher stops honouring it, so the JSON must too
// A dormant account is listed without a launch home (the app publishes `launchableHome`), and the
// saved `pinnedHome` still points at its directory. `runLaunch` falls through to the headroom pick
// there rather than exec'ing a logged-out config dir, and `best` means "would launch".
let dormantFixture = fixture.replacingOccurrences(
    of: "\"launchHome\": \"/Users/u/.claude2\", \"isStale\": false",
    with: "\"isStale\": false")
let dormantPin = parse(encodeStatusReport(statusReport(
    decodeSnapshot(dormantFixture),
    policies: ["claude": LaunchPolicy(mode: "manual", pinnedAccountID: "claude:.claude2",
                                      pinnedHome: "/Users/u/.claude2")],
    now: now)))
check("signed-out pin: the fixture really did lose its launch home",
      account(dormantPin, "claude:.claude2")["launchHome"] == nil)
check("signed-out pin: nothing is flagged pinned",
      accounts(dormantPin).allSatisfy { $0["pinned"] as? Bool == false })
check("signed-out pin: the headroom pick takes over rather than nobody",
      account(dormantPin, "claude:.claude")["best"] as? Bool == true)

// MARK: the markers themselves - the text `tally status` prints from this same resolver
// Both output shapes ask `launchMarkers` (TallyCLI/StatusReport.swift), so the arrow and the
// `(pinned)` suffix in the human output are asserted here directly. The text path used to compare
// `pinnedAccountID` on its own, which marked a signed-out pin as the launch target while the
// launcher was already picking somebody else (2026-08-03).
func markers(_ snap: Snapshot, _ policy: LaunchPolicy, provider: String = "claude",
             held: Set<String> = []) -> (best: String?, pinned: String?) {
    launchMarkers(providerID: provider, in: snap, policy: policy, quarantined: held, now: now)
}
let dormantMarkers = markers(decodeSnapshot(dormantFixture),
                             LaunchPolicy(mode: "manual", pinnedAccountID: "claude:.claude2",
                                          pinnedHome: "/Users/u/.claude2"))
check("markers: a signed-out pin hands the arrow to the headroom pick",
      dormantMarkers.best == "claude:.claude")
check("markers: …and flags nobody as pinned", dormantMarkers.pinned == nil)
// The live pin, so the fallback above cannot be satisfied by never honouring a pin at all.
let livePinMarkers = markers(snapshot, LaunchPolicy(mode: "manual",
                                                    pinnedAccountID: "claude:.claude2"))
check("markers: a live pin takes both markers",
      livePinMarkers.best == "claude:.claude2" && livePinMarkers.pinned == "claude:.claude2")
let autoMarkers = markers(snapshot, LaunchPolicy())
check("markers: an auto policy marks the headroom pick and pins nobody",
      autoMarkers.best == "claude:.claude" && autoMarkers.pinned == nil)
let orphanMarkers = markers(snapshot, LaunchPolicy(mode: "manual", pinnedAccountID: "claude:.gone",
                                                   pinnedHome: "/Users/u/.claude9"))
check("markers: a pin launching a home outside this list marks nobody",
      orphanMarkers.best == nil && orphanMarkers.pinned == nil)
let unknownMarkers = markers(snapshot, LaunchPolicy(), provider: "gemini")
check("markers: a provider this CLI cannot launch gets no arrow",
      unknownMarkers.best == nil && unknownMarkers.pinned == nil)
check("markers: the quarantine the launcher applies is applied here too",
      markers(snapshot, LaunchPolicy(), held: ["claude:.claude"]).best == "claude:.claude2")

// MARK: cap quarantine - `best` means "would launch", so it skips what the launcher skips
// (2026-07-25: a preview that ignored the quarantine named an account no launch could land on).
let quarantined = parse(encodeStatusReport(statusReport(
    snapshot, policies: ["claude": LaunchPolicy()],
    quarantined: ["claude": ["claude:.claude"]], now: now)))
check("quarantine: the held account is not best",
      account(quarantined, "claude:.claude")["best"] as? Bool == false)
check("quarantine: its sibling takes the marker",
      account(quarantined, "claude:.claude2")["best"] as? Bool == true)

// Quarantine emptying the field must not erase the marker: the launcher launches on a held
// account rather than refuse, and the report has to say which one that is.
let allHeld = parse(encodeStatusReport(statusReport(
    snapshot, policies: ["claude": LaunchPolicy()],
    quarantined: ["claude": ["claude:.claude", "claude:.claude2"]], now: now)))
check("quarantine: an all-held provider still names the unfiltered pick",
      account(allHeld, "claude:.claude")["best"] as? Bool == true)

// A quarantine on one provider must not silence another's marker.
check("quarantine: codex keeps its own pick",
      account(quarantined, "codex:.codex")["best"] as? Bool == true)

// A manual pin outranks the quarantine, exactly as runLaunch launches it ("launching anyway").
let pinnedHeld = parse(encodeStatusReport(statusReport(
    snapshot,
    policies: ["claude": LaunchPolicy(mode: "manual", pinnedAccountID: "claude:.claude2")],
    quarantined: ["claude": ["claude:.claude2"]], now: now)))
check("quarantine: a manual pin still launches, so it keeps the marker",
      account(pinnedHeld, "claude:.claude2")["best"] as? Bool == true)

// MARK: live sessions - the context a resume would reload, per account (SessionContext.swift)
let sessions = parse(encodeStatusReport(statusReport(
    snapshot, policies: ["claude": LaunchPolicy()],
    accountSessions: ["claude:.claude": .init(contextTokens: 477_070, model: "opus",
                                              effort: "xhigh")],
    now: now)))
check("a supervised account carries its context reading",
      account(sessions, "claude:.claude")["sessionContextTokens"] as? Int == 477_070)
// Absent rather than zero: an account with no session running has no answer, and a 0 would read
// as an empty conversation.
check("an account with no session has no key at all",
      account(sessions, "claude:.claude2")["sessionContextTokens"] == nil)
// Additive: what that same session was told to RUN, when a `tally model` pinned it. One session's
// fields, never a mixture of several - the caller picks the largest conversation on the account and
// this reports THAT one (SessionContext.swift).
check("…and carries what that session was pinned to run",
      account(sessions, "claude:.claude")["sessionModel"] as? String == "opus"
          && account(sessions, "claude:.claude")["sessionEffort"] as? String == "xhigh")
check("a session following the defaults reports no pair at all, rather than a guess",
      { let unpinned = parse(encodeStatusReport(statusReport(
            snapshot, policies: ["claude": LaunchPolicy()],
            accountSessions: ["claude:.claude": .init(contextTokens: 1_000)], now: now)))
        let row = account(unpinned, "claude:.claude")
        return row["sessionContextTokens"] as? Int == 1_000 && row["sessionModel"] == nil
            && row["sessionEffort"] == nil }())
check("and neither does anything when no session is running",
      accounts(auto).allSatisfy { $0["sessionContextTokens"] == nil })

// MARK: the session inventory - which conversations are running, and where to reach them

func inventory(_ top: [String: Any]) -> [[String: Any]] {
    top["sessions"] as? [[String: Any]] ?? []
}
let inventoried = parse(encodeStatusReport(statusReport(
    snapshot, policies: ["claude": LaunchPolicy()],
    sessions: [.init(accountID: "claude:.claude", pid: 4_242,
                     directory: "/Users/u/code/tally", project: "/Users/u/code/tally",
                     messagingSocket: "/tmp/cc-socks/4242.sock"),
               .init(accountID: "claude:.claude2", pid: 5_050,
                     directory: "/Users/u/code/tally-cart", project: "/Users/u/code/tally",
                     worktree: "cart")],
    now: now)))
check("every running session is listed, not one per account",
      inventory(inventoried).count == 2)
check("a session names the account it runs on, so it joins the rows above",
      inventory(inventoried).map { $0["accountID"] as? String }
          == ["claude:.claude", "claude:.claude2"])
check("…and the Claude Code pid to address",
      inventory(inventoried).first?["pid"] as? Int == 4_242)
check("a socket that is really there is published whole",
      inventory(inventoried).first?["messagingSocket"] as? String == "/tmp/cc-socks/4242.sock")
// Absent rather than empty: a reader takes no key as "not addressable this way" and falls back to
// its file channel, where an empty string is an address it would try to dial.
check("a session with no socket carries no key at all",
      inventory(inventoried).last?["messagingSocket"] == nil)
// The two project fields are not one field twice: a parallel line reports its own checkout AND the
// repository every line of it shares, which is what lets a caller address the LINE rather than the
// trunk (a worktree keeps its own inbox).
check("a worktree session reports its own checkout beside the repo key",
      inventory(inventoried).last?["directory"] as? String == "/Users/u/code/tally-cart"
          && inventory(inventoried).last?["project"] as? String == "/Users/u/code/tally"
          && inventory(inventoried).last?["worktree"] as? String == "cart")
check("a session on the trunk names no line at all",
      inventory(inventoried).first?["worktree"] == nil
          && inventory(inventoried).first?["directory"] as? String
              == inventory(inventoried).first?["project"] as? String)
// A SESSION NOTHING CAN ATTRIBUTE IS STILL A SESSION. The roster is every live supervisor, and one
// from a build too old to publish its account at the spawn has nothing to join on until its
// conversation has had a turn (SessionInventory.swift) - dropping it would lose exactly the sessions
// somebody has just started, which is when they are looked for.
let anonymous = parse(encodeStatusReport(statusReport(
    snapshot, policies: ["claude": LaunchPolicy()],
    sessions: [.init(directory: "/Users/u/code/fresh", project: "/Users/u/code/fresh")],
    now: now)))
check("a session with no account is listed all the same",
      inventory(anonymous).count == 1
          && inventory(anonymous).first?["directory"] as? String == "/Users/u/code/fresh")
check("…with no account key at all, rather than a null or an empty string",
      inventory(anonymous).first?["accountID"] == nil)
// The one block that is published empty rather than omitted: absence has to keep meaning "this
// Tally cannot answer", or a reader falls back to its slower channel without ever learning why.
check("a machine with nothing running still publishes the list",
      auto["sessions"] as? [Any] != nil && inventory(auto).isEmpty)

// MARK: what each session is DOING (SessionState.swift)

let board = parse(encodeStatusReport(statusReport(
    snapshot, policies: ["claude": LaunchPolicy()],
    sessions: [.init(accountID: "claude:.claude", directory: "/Users/u/code/tally",
                     project: "/Users/u/code/tally",
                     state: "blocked", stateSince: parseISO("2026-07-23T11:58:00Z")),
               .init(accountID: "claude:.claude2", directory: "/Users/u/code/old",
                     project: "/Users/u/code/old")],
    now: now)))
check("a session publishes what it is doing, and since when",
      inventory(board).first?["state"] as? String == "blocked"
          && inventory(board).first?["stateSince"] as? String == "2026-07-23T11:58:00Z")
// ABSENT IS NOT `unknown`: the word means "this session cannot say", absence means "this Tally
// cannot say", and a supervisor from before the board shipped is the second one while running
// perfectly well. Collapsing them would report a whole class of live sessions as blank.
check("a session whose supervisor publishes no state carries no key at all",
      inventory(board).last?["state"] == nil && inventory(board).last?["stateSince"] == nil)

// MARK: fleet pass-through - the pooled view rides along untouched, and only when present
let fleetTop = auto["fleet"] as? [String: [String: Any]] ?? [:]
let claudePools = (auto["fleetPools"] as? [String: [[String: Any]]])?["claude"] ?? []
check("headline fleet pool passes through",
      fleetTop["claude"]?["remaining"] as? Double == 91
          && fleetTop["claude"]?["sustainable"] as? Bool == true)
check("ordered pool list keeps the leading pool first",
      claudePools.first?["poolName"] as? String == "Fable"
          && claudePools.first?["dryAt"] as? String == "2026-07-23T12:13:00Z"
          && claudePools.count == 2)
let bare = parse(encodeStatusReport(statusReport(
    decodeSnapshot("""
    { "version": 2, "generatedAt": "2026-07-23T11:55:00Z", "accounts": [] }
    """), policies: [:], now: now)))
check("no fleet in the snapshot, no fleet keys in the report",
      bare["fleet"] == nil && bare["fleetPools"] == nil)

// MARK: staleness - an old snapshot is reported, not hidden
let old = parse(encodeStatusReport(statusReport(
    snapshot, policies: [:], now: parseISO("2026-07-23T13:00:00Z")!)))
check("snapshot older than the trust window reports stale", old["stale"] as? Bool == true)

// MARK: the advisor's plan tiers - the join that names them, and the JSON they land in

// The snapshot is where the CLI learns each account's plan (the burn-rate history carries none), so
// the join is only as good as what the app published.
let planned = decodeSnapshot("""
{ "version": 2, "generatedAt": "2026-07-23T11:55:00Z", "accounts": [
  { "id": "codex:.codex", "provider": "codex", "label": "Codex", "plan": "Pro", "isStale": false },
  { "id": "codex:.codex2", "provider": "codex", "label": "Codex 2", "plan": "Team", "isStale": false },
  { "id": "codex:.codex3", "provider": "codex", "label": "Codex 3", "isStale": false } ] }
""")
let plans = accountPlans(planned)
check("the snapshot's plans become the advisor's account lookup",
      plans == ["codex:.codex": "Pro", "codex:.codex2": "Team"])
// An older app publishes no plan at all: every account is simply absent from the lookup, which the
// advisor reads as one unnamed tier rather than as a reason to fail.
check("an account with no published plan is absent rather than empty-stringed",
      plans["codex:.codex3"] == nil)
check("a snapshot from an app that never knew about plans still decodes",
      accountPlans(snapshot).isEmpty && snapshot.accounts.count == 4)

let tiered = UsageAdvisor.Reading(
    provider: "codex", verdict: .sufficient, demandPerWeek: 2.6, activeBurnPerHour: 5,
    starvedHoursPerWeek: 0, daysOfData: 14, accountCount: 4,
    tierDemands: [.init(plan: "Pro", demandPerWeek: 1.7, accountCount: 3),
                  .init(plan: "Team", demandPerWeek: 0.9, accountCount: 1)])
let withTiers = parse(encodeStatusReport(
    statusReport(snapshot, policies: [:], advisor: [tiered], now: now)))
let codexAdvisor = (withTiers["advisor"] as? [String: [String: Any]])?["codex"] ?? [:]
let tiers = codexAdvisor["tierDemands"] as? [[String: Any]] ?? []
check("the tier split reaches the JSON, largest first",
      tiers.map { $0["plan"] as? String } == ["Pro", "Team"])
check("each tier carries its own demand and account count",
      tiers.first?["demandPerWeek"] as? Double == 1.7
          && tiers.first?["accountCount"] as? Int == 3)
check("and the pooled figure it splits is still published",
      codexAdvisor["demandPerWeek"] as? Double == 2.6)

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
