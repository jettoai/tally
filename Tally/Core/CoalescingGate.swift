import Foundation

/// One store's background pass, serialized: at most one in flight, and every request that arrives
/// while it runs folds into ONE follow-up pass rather than queueing a pass each. What the main-thread
/// scans that went to the background share (the session board, the config-dir watchers, the process
/// sampler), kept pure so the suites can state it without a run loop.
struct CoalescingGate: Sendable, Equatable {
    private(set) var running = false
    private(set) var pending = false

    /// Whether the caller starts a pass now. False means one is already running and this request
    /// has been folded into the follow-up.
    mutating func request() -> Bool {
        if running { pending = true; return false }
        running = true
        return true
    }

    /// Called when a pass completes. True means the caller starts the follow-up now (the gate stays
    /// running); false means the gate is idle again.
    mutating func finish() -> Bool {
        if pending { pending = false; return true }
        running = false
        return false
    }
}
