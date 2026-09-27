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

// MARK: - Store wiring (read as text)

let store = (try? String(contentsOfFile: "Tally/Stores/UsageStore.swift", encoding: .utf8)) ?? ""
check("A12d the store routes every provider's round through the cadence, Claude serially",
      store.contains("ProbeCadence.fetchRound(provider, active: active, previous: accounts,")
          && store.contains("serial: provider.id == ClaudeAccounts.providerID")
          && !store.contains("group.addTask"))
let launchLoop = store.components(separatedBy: "for account in active {").dropFirst().first ?? ""
check("A13 every enabled account still reaches the launchable homes, due or not",
      launchLoop.prefix(400).contains("launchHomes[account.id] = home"))

print(failed == 0 ? "ALL \(passed) PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
