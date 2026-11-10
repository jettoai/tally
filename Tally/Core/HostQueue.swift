import Foundation

/// How crowded the run queue is per core. Display only (B-4171).
enum HostHealthQueueLevel: String, Codable, Equatable, Sendable {
    case green, yellow, red
}

/// The one place the run-queue rule lives: the host-health report and any private card call this,
/// nothing else spells the thresholds (B-4171).
enum HostQueue {
    /// Over this many threads per core the queue reads yellow, over `redPerCore` red.
    static let yellowPerCore = 2.0
    static let redPerCore = 4.0

    /// The one-minute load average per core: runnable plus uninterruptible threads smoothed over one
    /// minute, so it lags a spike by up to a minute. Nil when the cores or the load cannot be used.
    /// No new syscall: both numbers are already in the reading.
    static func perCore(load1: Double, cores: Int) -> Double? {
        guard cores > 0, load1 >= 0, load1.isFinite else { return nil }
        return load1 / Double(cores)
    }

    static func level(_ perCore: Double) -> HostHealthQueueLevel {
        if perCore > redPerCore { return .red }
        if perCore > yellowPerCore { return .yellow }
        return .green
    }
}
