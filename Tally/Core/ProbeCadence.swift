import Darwin
import Foundation

// Which Claude accounts a background refresh round probes, and in what order (2026-09-27, owner
// report: five `claude -p /usage` running at once, each 23-42% CPU and about 340 MB).
//
// WHY ONE PROBE IS EXPENSIVE: in print mode `/usage` also builds its "What's contributing to your
// limits usage?" section by scanning every session transcript written in the last 7 days under the
// account's `projects` directory, and the Tally-managed homes usually share that directory through
// a symlink. Measured on CC 2.1.283: 6.4 to 7.5 CPU seconds per probe at load 40, against 0.7 for a
// start that signs in and runs no command. No flag keeps the three windows and drops the scan
// (`--bare` never reads OAuth, `--disable-slash-commands` disables `/usage` itself), so the lever
// is how many probes run and how many run at once: five at once cost 56.7 CPU seconds and 1.7 GB
// together, the same five one after another 40.8 seconds and one process's worth of memory.
enum ProbeCadence {
    /// How often an account with no live session is read. Its numbers only move when a window
    /// resets (handled separately below) or when something off this machine spends it: claude.ai,
    /// the Desktop app, another computer. A manual refresh always reads every account.
    static let idleInterval: TimeInterval = 15 * 60

    /// Whether this round probes one account.
    static func isDue(userInitiated: Bool, live: Bool, previous: AccountUsage?, now: Date,
                      idleInterval: TimeInterval = idleInterval) -> Bool {
        if userInitiated || live { return true }
        // Never read, or the last read did not land: the failure-retry ladder sets the pace then.
        guard let previous, previous.error == nil, !previous.lastRefreshFailed, !previous.isStale,
              !previous.metrics.isEmpty else { return true }
        if now.timeIntervalSince(previous.refreshedAt) >= idleInterval { return true }
        return resetPassed(since: previous, now: now)
    }

    /// A window whose reset time fell between the last reading and now reads 0% today while the
    /// card still shows the old number.
    static func resetPassed(since previous: AccountUsage, now: Date) -> Bool {
        previous.metrics.contains { metric in
            guard let resets = metric.resetsAt else { return false }
            return resets > previous.refreshedAt && resets <= now
        }
    }

    /// Account ids ("claude:.claude3") that a live supervised session is running on, read from the
    /// supervisors' `.account` sidecars. A crashed supervisor's leftover file does not count.
    static func liveAccountIDs(dir: URL = supervisorStateDir,
                               isAlive: (pid_t) -> Bool = { supervisorPresenceIsLive(pid: $0) })
        -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var live = Set<String>()
        for name in names where name.hasSuffix(".account") {
            guard let pid = pid_t(name.dropLast(".account".count)), pid > 0, isAlive(pid),
                  let raw = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            else { continue }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { live.insert(id) }
        }
        return live
    }

    /// One provider's accounts for this round. `serial` (Claude) probes one account at a time,
    /// live accounts first and only the ones due; an account skipped here keeps last round's row
    /// through the store's carry (AccountRowCarry.swift). Other providers fetch every account at once.
    static func fetchRound(_ provider: any UsageProvider, active: [ProviderAccount],
                           previous: [AccountUsage], serial: Bool, userInitiated: Bool,
                           live: Set<String>? = nil, facts: [String: LiveRateFact]? = nil,
                           now: Date = Date()) async -> [AccountUsage] {
        guard serial else {
            return await withTaskGroup(of: AccountUsage.self) { group in
                for account in active {
                    group.addTask { await provider.fetchUsage(for: account, userInitiated: userInitiated) }
                }
                var results: [AccountUsage] = []
                for await usage in group { results.append(usage) }
                return results
            }
        }
        let live = live ?? liveAccountIDs()
        let facts = facts ?? Dictionary(uniqueKeysWithValues: active.compactMap { account in
            readLiveRateFact(accountID: account.id).map { (account.id, $0) }
        })
        let previous = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let due = ordered(active, live: live).filter {
            isDue(userInitiated: userInitiated, live: live.contains($0.id), fact: facts[$0.id],
                  previous: previous[$0.id], now: now)
        }
        var results: [AccountUsage] = []
        for account in due {
            results.append(await provider.fetchUsage(for: account, userInitiated: userInitiated))
        }
        return results
    }

    // MARK: - The status-line channel (TallyCLI/LiveRates.swift)

    /// A live account whose two main windows are arriving from its own status line is still probed
    /// this often, for the flagship window the status line does not carry.
    static let liveFlagshipInterval: TimeInterval = 5 * 60
    /// A status-line fact counts as current while its sessions keep rendering.
    static let factFreshness: TimeInterval = 3 * 60
    /// Near a wall every reading matters to the picks and the cap handoff, so the probe runs every tick.
    static let nearWallPercent: Double = 90

    /// The full rule with the status-line channel. A missing or stale fact falls back to `isDue`
    /// above, with a fact still being rendered counting as a live account.
    static func isDue(userInitiated: Bool, live: Bool, fact: LiveRateFact?, previous: AccountUsage?,
                      now: Date) -> Bool {
        let rendering = fact.map { now.timeIntervalSince($0.observedAt) < factFreshness } ?? false
        guard !userInitiated, let fact, rendering else {
            return isDue(userInitiated: userInitiated, live: live || rendering, previous: previous, now: now)
        }
        guard let previous, previous.error == nil, !previous.lastRefreshFailed, !previous.isStale,
              !previous.metrics.isEmpty else { return true }
        if let flagshipAt = fact.flagshipAt, now.timeIntervalSince(flagshipAt) < factFreshness { return true }
        if [fact.fiveHour, fact.sevenDay].contains(where: { ($0?.usedPercent ?? 0) >= nearWallPercent }) {
            return true
        }
        if now.timeIntervalSince(previous.refreshedAt) >= liveFlagshipInterval { return true }
        return resetPassed(since: previous, now: now)
    }

    /// Lay the status line's numbers over a row's session and weekly windows when they moved after
    /// the row was read. The flagship window and `refreshedAt` are left alone: `refreshedAt` dates
    /// the probe, and the snapshot's readers (CapDetection) read it as that. Only Claude rows ever
    /// have a fact (the status line writes `claude:` ids), so the store passes every row through.
    static func overlay(_ row: AccountUsage, fact: LiveRateFact?, now: Date) -> AccountUsage {
        guard let fact, fact.accountID == row.id, row.error == nil,
              fact.changedAt > row.refreshedAt else { return row }
        var copy = row
        copy.metrics = row.metrics.map { metric in
            let window: LiveRateWindow?
            switch metric.kind {
            case .session: window = fact.fiveHour
            case .weeklyAll: window = fact.sevenDay
            default: window = nil
            }
            guard let window, window.resetsAt > now else { return metric }
            var updated = metric
            updated.usedPercent = window.usedPercent
            updated.severity = .fromUsedPercent(window.usedPercent)
            updated.resetsAt = window.resetsAt
            return updated
        }
        return copy
    }

    /// Live accounts first, so the accounts being spent are read earliest in a serial round;
    /// otherwise discovery order.
    static func ordered(_ accounts: [ProviderAccount], live: Set<String>) -> [ProviderAccount] {
        accounts.enumerated().sorted { a, b in
            let (la, lb) = (live.contains(a.element.id), live.contains(b.element.id))
            return la != lb ? la : a.offset < b.offset
        }.map(\.element)
    }
}
