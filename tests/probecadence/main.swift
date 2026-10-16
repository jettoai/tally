import Foundation

// Assertion harness for which Claude accounts a background round probes (Tally/Core/ProbeCadence.swift)
// and for the store running those probes one at a time.

var passed = 0, failed = 0
func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
func row(_ id: String = "claude:.claude3", readAgo: TimeInterval, resetsAt: Date? = nil) -> AccountUsage {
    let metric = UsageMetric(id: "session", kind: .session, label: "Session", modelName: nil,
                             usedPercent: 40, severity: .normal, resetsAt: resetsAt, isActive: false)
    return AccountUsage(id: id, providerID: "claude", accountLabel: "Claude 3",
                        planName: nil, accountEmail: nil, metrics: [metric],
                        refreshedAt: now.addingTimeInterval(-readAgo))
}
func due(userInitiated: Bool = false, _ previous: AccountUsage?) -> Bool {
    ProbeCadence.isDue(userInitiated: userInitiated, previous: previous, now: now)
}
/// The round's rule: a live supervisor, with or without a status-line fact.
func dueLive(userInitiated: Bool = false, live: Bool = true, _ fact: LiveRateFact?,
             _ previous: AccountUsage?) -> Bool {
    ProbeCadence.isDue(userInitiated: userInitiated, live: live, fact: fact, previous: previous, now: now)
}
func fact(observedAgo: TimeInterval, fiveHour: Double = 40) -> LiveRateFact {
    let at = now.addingTimeInterval(-observedAgo)
    return LiveRateFact(accountID: "claude:.claude3", observedAt: at, changedAt: at,
                        fiveHour: LiveRateWindow(usedPercent: fiveHour, resetsAt: now.addingTimeInterval(3600)),
                        sevenDay: nil, flagshipAt: nil)
}

// MARK: - Cadence

// A live account follows the 5-minute live cadence even with no status-line fact (B rows below).
check("A1 a live account with no fact read 10 seconds ago is skipped, 5 minutes ago is read",
      !dueLive(nil, row(readAgo: 10)) && dueLive(nil, row(readAgo: 5 * 60)))
check("A2 an idle account read 5 minutes ago is skipped", !due(row(readAgo: 5 * 60)))
check("A3 an idle account read 15 minutes ago is read", due(row(readAgo: 15 * 60)))
check("A4 a window that reset since the last read brings the read forward",
      due(row(readAgo: 5 * 60, resetsAt: now.addingTimeInterval(-60))))
check("A5 a reset that had already passed at the last read does not",
      !due(row(readAgo: 5 * 60, resetsAt: now.addingTimeInterval(-10 * 60))))
var failedRound = row(readAgo: 60); failedRound.lastRefreshFailed = true
var staleRow = row(readAgo: 60); staleRow.isStale = true
var errorRow = row(readAgo: 60); errorRow.error = "network down"
var emptyRow = row(readAgo: 60); emptyRow.metrics = []
check("A6 a failed, stale or errored last read is retried",
      due(failedRound) && due(staleRow) && due(errorRow))
check("A7 an account never read is read", due(nil))
check("A8 a manual refresh reads an idle account read just now",
      due(userInitiated: true, row(readAgo: 1)))

// MARK: - Live accounts whose status line went quiet (fact older than 3 minutes, or none)

let quiet = fact(observedAgo: 32 * 60)
check("B1 a live account with a stale fact read 1 minute ago is skipped", !dueLive(quiet, row(readAgo: 60)))
check("B2 a live account with a stale fact read 5 minutes ago is read", dueLive(quiet, row(readAgo: 5 * 60)))
var highProbe = row(readAgo: 60); highProbe.metrics[0].usedPercent = 92
check("B3 near a wall, by the last probe or by the stale fact, a live account reads every tick",
      dueLive(quiet, highProbe) && dueLive(fact(observedAgo: 32 * 60, fiveHour: 95), row(readAgo: 60)))
check("B3b a probe at 90% whose window has since reset is not a wall", {
    var p = row(readAgo: 60, resetsAt: now.addingTimeInterval(-3600)); p.metrics[0].usedPercent = 92
    return !dueLive(quiet, p)
}())
check("B4 a window that reset since the last read brings a live account's read forward",
      dueLive(quiet, row(readAgo: 60, resetsAt: now.addingTimeInterval(-10))))
check("B5 a live account with no fact read 1 minute ago is skipped", !dueLive(nil, row(readAgo: 60)))
check("B6 a live account whose last read did not land is retried",
      dueLive(quiet, nil) && dueLive(quiet, failedRound) && dueLive(quiet, staleRow)
          && dueLive(quiet, errorRow) && dueLive(nil, emptyRow))
check("B7 a manual refresh reads a live account with a stale fact read just now",
      dueLive(userInitiated: true, quiet, row(readAgo: 1)) && dueLive(userInitiated: true, live: false, nil, row(readAgo: 1)))
check("B8 an account with no live supervisor and a stale or no fact keeps the 15-minute idle cadence",
      !dueLive(live: false, quiet, row(readAgo: 60)) && !dueLive(live: false, nil, row(readAgo: 60))
          && dueLive(live: false, quiet, row(readAgo: 15 * 60)))
let fresh = fact(observedAgo: 30)
check("B9 a fresh fact keeps its own path: 5 minutes, sooner near a wall",
      !dueLive(fresh, row(readAgo: 60)) && dueLive(fresh, row(readAgo: 5 * 60))
          && dueLive(fact(observedAgo: 30, fiveHour: 95), row(readAgo: 60))
          && !dueLive(live: false, fresh, row(readAgo: 60)))

// MARK: - Live accounts

let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("probecadence-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
try! "claude:.claude3\n".write(to: dir.appendingPathComponent("111.account"), atomically: true, encoding: .utf8)
try! "claude:.claude4".write(to: dir.appendingPathComponent("222.account"), atomically: true, encoding: .utf8)
try! "claude:.claude5".write(to: dir.appendingPathComponent("333.state"), atomically: true, encoding: .utf8)
let live = ProbeCadence.liveAccountIDs(dir: dir, isAlive: { $0 == 111 })
check("A9 only a live supervisor's .account file names a live account", live == ["claude:.claude3"])
try! "claude:.claude3".write(to: dir.appendingPathComponent("444.account"), atomically: true, encoding: .utf8)
check("liveSessionCounts counts two live sessions on one account",
      liveSessionCounts(dir: dir, isAlive: { [111, 222, 444].contains($0) })
          == ["claude:.claude3": 2, "claude:.claude4": 1])
// Unknown is nil, as the CLI's liveSessionCount reads it, and the badge reads nil as full.
let file111 = dir.appendingPathComponent("111.account")
chmod(file111.path, 0)
check("A9b a live supervisor's account file that cannot be read is unknown",
      liveSessionCounts(dir: dir, isAlive: { [111, 222].contains($0) }) == nil)
check("A9b …a dead supervisor's unreadable file is still skipped",
      liveSessionCounts(dir: dir, isAlive: { $0 == 222 }) == ["claude:.claude4": 1])
check("A9b …and liveAccountIDs keeps the accounts it could read, for probe order only",
      ProbeCadence.liveAccountIDs(dir: dir, isAlive: { [111, 222].contains($0) }) == ["claude:.claude4"])
chmod(file111.path, 0o644)
try! "".write(to: dir.appendingPathComponent("555.account"), atomically: true, encoding: .utf8)
check("A9b a live supervisor's empty account file is unknown",
      liveSessionCounts(dir: dir, isAlive: { $0 == 555 }) == nil)
chmod(dir.path, 0)
check("A9b a state directory that cannot be listed is unknown",
      liveSessionCounts(dir: dir, isAlive: { _ in true }) == nil)
chmod(dir.path, 0o755)
check("A9b a state directory nobody has written yet is a real zero",
      liveSessionCounts(dir: dir.appendingPathComponent("absent")) == [:])
try? FileManager.default.removeItem(at: dir)

func account(_ id: String) -> ProviderAccount {
    ProviderAccount(id: id, providerID: "claude", label: id, locator: [:])
}
check("A10 live accounts go first, the rest keep discovery order",
      ProbeCadence.ordered([account("a"), account("b"), account("c")], live: ["c"]).map(\.id)
          == ["c", "a", "b"])

// MARK: - One round

/// Records which accounts were fetched and how many fetches were in flight at once.
actor Probe {
    var inFlight = 0, peak = 0, ids: [String] = []
    func begin(_ id: String) { inFlight += 1; peak = max(peak, inFlight); ids.append(id) }
    func end() { inFlight -= 1 }
}
struct FakeProvider: UsageProvider {
    let id = "claude", displayName = "Fake"
    let probe: Probe
    func discoverAccounts() -> [ProviderAccount] { [] }
    func fetchUsage(for account: ProviderAccount, userInitiated: Bool) async -> AccountUsage {
        await probe.begin(account.id)
        try? await Task.sleep(nanoseconds: 30_000_000)
        await probe.end()
        return row(account.id, readAgo: 0)
    }
}
// a: idle, read 5 minutes ago (not due). b: live, read 5 minutes ago (due). c: never read.
let roundAccounts = [account("a"), account("b"), account("c")]
let roundPrevious = [row("a", readAgo: 5 * 60), row("b", readAgo: 5 * 60)]

let serialProbe = Probe()
let serialRows = await ProbeCadence.fetchRound(FakeProvider(probe: serialProbe), active: roundAccounts,
                                               previous: roundPrevious, serial: true,
                                               userInitiated: false, live: ["b"], now: now)
let serialIDs = await serialProbe.ids, serialPeak = await serialProbe.peak
check("A11 a Claude round reads only the due accounts, live first", serialIDs == ["b", "c"]
          && serialRows.map(\.id) == ["b", "c"])
check("A12 a Claude round runs one probe at a time", serialPeak == 1)

let manualProbe = Probe()
_ = await ProbeCadence.fetchRound(FakeProvider(probe: manualProbe), active: roundAccounts,
                                  previous: roundPrevious, serial: true,
                                  userInitiated: true, live: ["b"], now: now)
let manualIDs = await manualProbe.ids
check("A12b a manual Claude round reads every account", manualIDs.sorted() == ["a", "b", "c"])

let groupProbe = Probe()
let groupRows = await ProbeCadence.fetchRound(FakeProvider(probe: groupProbe), active: roundAccounts,
                                              previous: roundPrevious, serial: false,
                                              userInitiated: false, live: [], now: now)
let groupPeak = await groupProbe.peak
check("A12c other providers still fetch every account at once",
      groupRows.map(\.id).sorted() == ["a", "b", "c"] && groupPeak == 3)

// MARK: - A slow account does not hold the ones behind it (B-1745)

/// Per-account delays; records each start time, the peak in flight, and the order of starts and ends.
actor LaneLog {
    var inFlight = 0, peak = 0, events: [String] = [], startedAt: [String: Date] = [:], endedAt: [String: Date] = [:]
    func begin(_ id: String) { inFlight += 1; peak = max(peak, inFlight); events.append("start \(id)"); startedAt[id] = Date() }
    func end(_ id: String) { inFlight -= 1; events.append("end \(id)"); endedAt[id] = Date() }
}
struct LaneProvider: UsageProvider {
    let id = "claude", displayName = "Lanes"
    let delays: [String: Double]
    let log: LaneLog
    func discoverAccounts() -> [ProviderAccount] { [] }
    func fetchUsage(for account: ProviderAccount, userInitiated: Bool) async -> AccountUsage {
        await log.begin(account.id)
        try? await Task.sleep(nanoseconds: UInt64((delays[account.id] ?? 0.02) * 1_000_000_000))
        await log.end(account.id)
        return row(account.id, readAgo: 0)
    }
}
func laneRound(_ delays: [String: Double], slowAfter: TimeInterval = 0.15) async -> (LaneLog, [AccountUsage], Date) {
    let log = LaneLog(), start = Date()
    let rows = await ProbeCadence.fetchRound(LaneProvider(delays: delays, log: log),
                                             active: ["a", "b", "c", "d"].map(account), previous: [],
                                             serial: true, userInitiated: true, live: [], now: now,
                                             slowAfter: slowAfter)
    return (log, rows, start)
}

let (calmLog, calmRows, calmStart) = await laneRound([:])
let calmPeak = await calmLog.peak, calmEvents = await calmLog.events
check("L1 with no slow account one probe runs at a time, in order",
      calmPeak == 1 && calmRows.map(\.id) == ["a", "b", "c", "d"]
          && calmEvents == ["start a", "end a", "start b", "end b", "start c", "end c", "start d", "end d"])
let defaultStart = Date()
_ = await ProbeCadence.fetchRound(LaneProvider(delays: [:], log: LaneLog()), active: ["a", "b"].map(account),
                                  previous: [], serial: true, userInitiated: true, live: [], now: now)
check("L1 the slow timers of probes that came back in time do not hold the round open",
      Date().timeIntervalSince(defaultStart) < 2 && Date().timeIntervalSince(calmStart) < 3)

let (oneLog, oneRows, _) = await laneRound(["a": 1.2])
let onePeak = await oneLog.peak, oneStarts = await oneLog.startedAt, oneEnds = await oneLog.endedAt
check("L2 one stuck account: the next starts once it is slow, never more than two at once",
      onePeak == 2 && oneStarts["b"].map { $0.timeIntervalSince(oneStarts["a"]!) >= 0.14 } == true)
check("L2 …and every account behind it lands before the stuck one returns",
      ["b", "c", "d"].allSatisfy { (oneEnds[$0] ?? .distantFuture) < oneEnds["a"]! }
          && oneRows.map(\.id).last == "a" && oneRows.count == 4)

let (twoLog, _, _) = await laneRound(["a": 0.8, "b": 0.8])
let twoPeak = await twoLog.peak, twoStarts = await twoLog.startedAt, twoEnds = await twoLog.endedAt
check("L3 two stuck accounts: no third lane opens, the next waits for one of them",
      twoPeak == 2 && twoStarts["c"].map { $0 >= min(twoEnds["a"]!, twoEnds["b"]!) } == true)

// MARK: - Store wiring (read as text)

let store = (try? String(contentsOfFile: "Tally/Stores/UsageStore.swift", encoding: .utf8)) ?? ""
check("A12d the store routes every provider's round through the cadence at once, Claude serially",
      store.contains("ProbeCadence.fetchRounds(rounds, previous: accounts,")
          && store.contains("serial: provider.id == ClaudeAccounts.providerID")
          && !store.contains("group.addTask") && !store.contains("ProbeCadence.fetchRound("))
let launchLoop = store.components(separatedBy: "for account in active {").dropFirst().first ?? ""
check("A13 every enabled account still reaches the launchable homes, due or not",
      launchLoop.prefix(400).contains("launchHomes[account.id] = home"))


// MARK: - Rows land as their probes return (B-1745)

func labeled(_ id: String, _ provider: String, _ label: String, used: Double) -> AccountUsage {
    var usage = row(id, readAgo: 0)
    usage.providerID = provider; usage.accountLabel = label; usage.metrics[0].usedPercent = used
    return usage
}
let shown = [labeled("c1", "claude", "A", used: 10), labeled("c2", "claude", "B", used: 20),
             labeled("x1", "codex", "A", used: 30)]
let swapped = ProbeCadence.landing(labeled("c2", "claude", "B", used: 77), into: shown, fact: nil, now: now)
check("A16 a landed row replaces its own row and leaves every other row as it was",
      swapped.map(\.id) == ["c1", "c2", "x1"] && swapped[1].metrics[0].usedPercent == 77
          && swapped[0] == shown[0] && swapped[2] == shown[2])
let inserted = ProbeCadence.landing(labeled("c0", "claude", "0", used: 5), into: shown, fact: nil, now: now)
check("A16 a row not on screen yet is inserted in the panel's order",
      inserted.map(\.id) == ["c0", "c1", "c2", "x1"])
// B-2027: rows seeded from the last launch's cache are replaced in place as probes land: the count
// never drops to zero and never grows past the cached accounts, and only the landed row changes.
let reseeded = ProbeCadence.landing(labeled("x1", "codex", "A", used: 99), into: shown, fact: nil, now: now)
check("A16b a landing over seeded rows keeps every account and updates only its own row",
      reseeded.count == shown.count && reseeded[2].metrics[0].usedPercent == 99
          && reseeded[0] == shown[0] && reseeded[1] == shown[1])

/// Records when each fetch starts and ends and when each row reaches the callback.
actor Timeline {
    var events: [String] = []
    var inFlight: [String: Int] = [:], peak: [String: Int] = [:]
    func begin(_ provider: String) {
        inFlight[provider, default: 0] += 1; peak[provider] = max(peak[provider] ?? 0, inFlight[provider]!)
    }
    func end(_ provider: String, _ id: String) { inFlight[provider]! -= 1; events.append("end \(id)") }
    func landed(_ id: String) { events.append("land \(id)") }
}
struct TimedProvider: UsageProvider {
    let id: String, displayName = "Timed"
    let delay: UInt64
    let timeline: Timeline
    func discoverAccounts() -> [ProviderAccount] { [] }
    func fetchUsage(for account: ProviderAccount, userInitiated: Bool) async -> AccountUsage {
        await timeline.begin(id)
        try? await Task.sleep(nanoseconds: delay)
        await timeline.end(id, account.id)
        return labeled(account.id, id, account.id, used: 1)
    }
}
let timeline = Timeline()
let slow = TimedProvider(id: "claude", delay: 300_000_000, timeline: timeline)
let fast = TimedProvider(id: "codex", delay: 50_000_000, timeline: timeline)
let both = await ProbeCadence.fetchRounds(
    [.init(provider: slow, active: [account("s1"), account("s2")], serial: true),
     .init(provider: fast, active: [account("f1"), account("f2")], serial: false)],
    previous: [], userInitiated: true, live: [], now: now,
    onResult: { await timeline.landed($0.id) })
let events = await timeline.events, peaks = await timeline.peak
let firstFastLand = events.firstIndex { $0 == "land f1" || $0 == "land f2" } ?? .max
let secondSlowEnd = events.firstIndex(of: "end s2") ?? -1
check("A17 the fast provider's rows land before the slow provider's second probe ends",
      firstFastLand < secondSlowEnd)
check("A17 Claude stays one probe at a time while the other provider runs beside it",
      peaks["claude"] == 1 && peaks["codex"] == 2)
check("A17 every row reaches the callback once and comes back in provider order",
      events.filter { $0.hasPrefix("land") }.count == 4
          && both.map(\.id).prefix(2) == ["s1", "s2"] && Set(both.map(\.id).suffix(2)) == ["f1", "f2"])

// The store's half, read as text: the store cannot be compiled into this harness.
let landRowBody = store.components(separatedBy: "private func landRow(").dropFirst().first?
    .components(separatedBy: "\n    }\n").first ?? ""
check("A18 the commit reuses a landed row rather than folding it a second time",
      store.contains("results.map { landedRows[$0.id] ?? applyLastGood($0) }")
          && landRowBody.components(separatedBy: "applyLastGood(usage)").count == 2
          && landRowBody.contains("removals.removedIDs(inRound: round)")
          && !landRowBody.contains("republishSnapshot"))
check("A19 a refresh asked for mid-round still queues exactly one follow-up",
      store.contains("private var refreshQueued = false")
          && store.components(separatedBy: "trigger: .queued").count == 2
          && store.contains("queuedUserInitiated = queuedUserInitiated || userInitiated"))
let cadence = (try? String(contentsOfFile: "Tally/Core/ProbeCadence.swift", encoding: .utf8)) ?? ""
let roundLog = (try? String(contentsOfFile: "Tally/Stores/UsageStore+RoundLog.swift", encoding: .utf8)) ?? ""
check("A20 the probe and round lines carry ids and timings, never an email",
      cadence.contains("probe provider=") && roundLog.contains("round trigger=")
          && !(cadence + roundLog).contains("accountEmail"))

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
