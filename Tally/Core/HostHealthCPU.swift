import Foundation

// THE CPU WITNESS OF THE HOST WATCH (B-4094), split from HostHealthLogic.swift for size and compiled
// by both targets for the same reason that file is: the app JUDGES and publishes `cpuOver`, and the
// readers of `~/.tally/host-health.json` act on it without a second copy of the rule.
//
// WHY CPU AND NOT LOAD. The one-minute load average counts runnable plus uninterruptible threads.
// Two virtual machines queueing vCPU threads read 99 to 244 on a 16-core machine whose CPU was 50%
// busy, and four "host under pressure" banners went out while nothing was starved. The machine is
// short of CPU when its CPU is used up, so that is what is asked. Foundation only.

/// The lines the host watch is decided against, with the rule that a number outside its range
/// falls back to the default rather than being clamped: a typo must not silently become the edge.
struct HostHealthLimits: Equatable, Sendable {
    /// The share of the whole machine's CPU that counts as used up, over one minute's windows.
    /// 90 is the line `CPUAlertLogic.enterPercent` and the pool's `FULL_BUSY` already draw.
    var cpuPercent: Double
    /// How many samples in a row it takes to move in either direction.
    ///
    /// A RUN RATHER THAN A READING, in both directions and for two different reasons. Upwards it is
    /// what keeps a single spike quiet: a `pnpm install`, a full test run or an Xcode build all put
    /// this machine over the line for less than a minute, and none of them is the thing this exists
    /// to report. Downwards it is hysteresis: a machine hovering at the line would otherwise
    /// announce, recover and announce again every minute, which is the one failure that would get
    /// this feature turned off.
    var samples: Int
    /// The share of memory left that counts as too little. A share rather than 2 GB because the
    /// same line has to fit a 16 GB laptop and a 128 GB desktop.
    var memoryPercent: Double

    static let standard = HostHealthLimits(cpuPercent: 90, samples: 3, memoryPercent: 3)

    static let cpuKey = "hostHealthCPUPercent"
    static let samplesKey = "hostHealthConsecutiveSamples"
    static let memoryKey = "hostHealthMemoryPercent"

    static func from(_ defaults: UserDefaults) -> HostHealthLimits {
        func number(_ key: String, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard let value = (defaults.object(forKey: key) as? NSNumber)?.doubleValue,
                  range.contains(value) else { return fallback }
            return value
        }
        return HostHealthLimits(
            cpuPercent: number(cpuKey, 50...100, standard.cpuPercent),
            samples: Int(number(samplesKey, 1...30, Double(standard.samples))),
            memoryPercent: number(memoryKey, 1...50, standard.memoryPercent))
    }
}

/// What one minute of ten-second windows came to.
struct HostCPUSample: Equatable, Sendable {
    /// The mean busy share over the windows, nil when there were too few to say.
    var percent: Double?
    var windows: Int
    /// Why `percent` is nil: `ticks` (the counters could not be read or went backwards), `gap`
    /// (a window straddled a sleep or a missed tick and was dropped) or `windows` (too few).
    var unreadReason: String?
}

/// The ten-second windows a minute's CPU share is the mean of.
///
/// A WINDOW IS TWO READINGS OF THE CUMULATIVE TICK COUNTERS, ten seconds apart or so
/// (`HostHealthMonitor.tick` rides the footprint timer). A pair further apart than `maxGap` (the
/// CPU alert's own 25 seconds) is a machine that slept or a sampler that did not get a turn, and
/// the figure across it is an average over the gap, so it is dropped rather than counted as one.
struct HostCPUWindows: Equatable, Sendable {
    static let interval: TimeInterval = 10
    static let maxGap: TimeInterval = 25
    static let minimumWindows = 3

    private struct Counters: Equatable, Sendable {
        var busy: UInt64
        var total: UInt64
        var at: Date
    }
    private var last: Counters?
    private var percents: [Double] = []
    private var dropped: String?

    /// Whether the next reading is due: ten seconds since the last one, or the clock went back.
    func due(at now: Date) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last.at)
        return elapsed >= Self.interval || elapsed < 0
    }

    /// Fold one reading of the cumulative counters (busy = user + system + nice, total = busy + idle)
    /// in. Nil means the syscall refused: the next reading starts a fresh window.
    mutating func observe(busy: UInt64?, total: UInt64?, at now: Date) {
        guard let busy, let total else {
            last = nil
            dropped = "ticks"
            return
        }
        let current = Counters(busy: busy, total: total, at: now)
        defer { last = current }
        guard let previous = last else { return }
        let gap = now.timeIntervalSince(previous.at)
        guard gap >= 0, gap <= Self.maxGap else {
            dropped = "gap"
            return
        }
        guard busy >= previous.busy, total > previous.total else {
            dropped = "ticks"
            return
        }
        percents.append(min(100, Double(busy - previous.busy) / Double(total - previous.total) * 100))
    }

    /// The minute's sample, and the windows start again.
    mutating func take() -> HostCPUSample {
        defer { percents = []; dropped = nil }
        guard percents.count >= Self.minimumWindows else {
            return HostCPUSample(percent: nil, windows: percents.count,
                                 unreadReason: dropped ?? "windows")
        }
        return HostCPUSample(percent: percents.reduce(0, +) / Double(percents.count),
                             windows: percents.count, unreadReason: nil)
    }
}

extension HostHealthLogic {

    /// Whether one reading is over the line: either witness on its own is enough, because the two
    /// failures the incident produced were exactly these two and either alone makes the machine
    /// unusable.
    static func exceeds(_ reading: HostHealthReading, _ limits: HostHealthLimits = .standard) -> Bool {
        cpuExceeds(reading, limits) || memoryExceeds(reading, limits)
    }

    /// The CPU witness on its own, which is also what decides whether an alarm is worth a CPU
    /// sample. A reading that could not be taken is not over (fail-closed: it does not alarm).
    static func cpuExceeds(_ reading: HostHealthReading,
                           _ limits: HostHealthLimits = .standard) -> Bool {
        reading.cpuPercent.map { $0 >= limits.cpuPercent } ?? false
    }

    /// The memory witness: a share of the machine, or the old 2 GB floor when the total is unread.
    static func memoryExceeds(_ reading: HostHealthReading,
                              _ limits: HostHealthLimits = .standard) -> Bool {
        reading.memoryAvailablePercent.map { $0 < limits.memoryPercent }
            ?? (reading.freeBytes < minimumFreeBytes)
    }
}

/// The one line written when the CPU reading goes from readable to unreadable (not every minute).
func hostHealthCPUUnreadLine(reason: String, now: Date) -> String {
    "\(ISO8601DateFormatter().string(from: now)) host-health=cpu-unread reason=\(reason)\n"
}
