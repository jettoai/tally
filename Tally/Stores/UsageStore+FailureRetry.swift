import Foundation

// The failure-retry ladder, split out of UsageStore.swift (line limit). Its timer state stays
// there (stored properties cannot live in an extension); only this file writes it.

extension UsageStore {
    /// Backoff ladder for retrying after a failure, so a transient miss (the seconds-long window
    /// while the CLI rotates a token, a network blip) heals in ~1 minute instead of sitting on
    /// screen until the next full 5-minute tick. Doubles per consecutive failure so a real outage
    /// (e.g. a 429 spell) is probed gently, and never exceeds the regular interval.
    func scheduleRetryIfNeeded(anyFailure: Bool, soon: Bool) {
        retryTimer?.cancel()
        retryTimer = nil
        retryFireAt = nil
        guard anyFailure else {
            retryDelay = 60   // healthy again - reset the ladder
            return
        }
        let interval = TimeInterval(max(1, SettingsStore.shared.refreshIntervalMinutes) * 60)
        let delay = soon ? FailureRetry.newAccountDelay : min(retryDelay, interval)
        if !soon { retryDelay = min(retryDelay * 2, interval) }  // one quick look, ladder unmoved
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.retryFireAt = nil
                await self?.refresh(userInitiated: false, trigger: .retry)
            }
        }
        timer.resume()
        retryTimer = timer
        retryFireAt = Date().addingTimeInterval(delay)
    }
}
