import Foundation

// What started each refresh round and how long it held the spinner (B-1745), on the same channel
// as each probe's own line (ProbeCadence.log).

/// What asked for a round. `user` is every user-initiated caller (the refresh button, a renewal,
/// a redeem, adding or removing an account); `other` is every background caller this store does
/// not name itself (the early-start nudge on wake and at the end of quiet hours, settings toggles).
enum RefreshTrigger: String {
    case timer, retry, watcher, queued, user, other
}

extension UsageStore {
    func logRound(_ trigger: RefreshTrigger, since start: Date, results: [AccountUsage]) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let claude = results.filter { $0.providerID == ClaudeAccounts.providerID }.count
        let others = results.count - claude
        let failed = results.filter { $0.error != nil }.count
        ProbeCadence.log.notice("round trigger=\(trigger.rawValue, privacy: .public) ms=\(ms, privacy: .public) claude=\(claude, privacy: .public) codex=\(others, privacy: .public) failed=\(failed, privacy: .public)")
    }
}
