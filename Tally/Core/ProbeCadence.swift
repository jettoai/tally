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
                           live: Set<String>? = nil, now: Date = Date()) async -> [AccountUsage] {
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
        let previous = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let due = ordered(active, live: live).filter {
            isDue(userInitiated: userInitiated, live: live.contains($0.id), previous: previous[$0.id], now: now)
        }
        var results: [AccountUsage] = []
        for account in due {
            results.append(await provider.fetchUsage(for: account, userInitiated: userInitiated))
        }
        return results
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
