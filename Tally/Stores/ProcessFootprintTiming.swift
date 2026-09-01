import Foundation

// WHEN THE FOOTPRINT PASS RUNS, and who is asking for it. Lifted out of ProcessFootprintStore.swift
// past the repo's 500-line cap, along the seam the class already had inside it: over there is what
// a tick READS and what it publishes, and here is the audience, the two rates and the one piece of
// cache that belongs to the panel rather than to the reading (the ports).
//
// THE PASS NEVER STOPS, WHICH IS THE WHOLE OF WHAT THESE FOUR DECIDE. It used to run only while a
// surface was up, and the trend line is why that changed: a history that exists only while somebody
// is looking is empty at the exact moment it is wanted. What a closed panel switches off is the
// RATE and the ports, not the reading (`ProcessFootprintStore` states the measurement).

extension ProcessFootprintStore {

    /// Start sampling for the life of the process, at the background rate. Called once at launch,
    /// exactly as the roster's own observer is (`SessionRosterStore.install`), and for the same
    /// reason: a registration that is missed is a feature that silently never runs.
    func install() { retime() }

    /// A surface showing the board has appeared. Samples at once, because what somebody just opened
    /// has to say something before the first tick rather than after it, and resets the tick count so
    /// that first sample is the one that reads the ports.
    func beginViewing() {
        if viewers == 0 { ticks = 0 }
        viewers += 1
        retime()
        sample()
    }

    /// The last surface showing the board has gone. The readings go on being taken, slower: what is
    /// dropped is only what is exclusively the panel's, which is the ports (nothing draws them, and
    /// a pid the machine hands out again must never inherit them).
    func endViewing() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        retime()
        ports = [:]
    }

    /// Put the timer on the rate the current audience deserves, and only when that rate changed.
    private func retime() {
        let wanted = viewers > 0 ? Self.visibleInterval : Self.backgroundInterval
        guard timerInterval != wanted else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: wanted, repeats: true) { _ in
            Task { @MainActor in ProcessFootprintStore.shared.sample() }
        }
        // `.common`, so the readings keep coming while a menu or a scroll is tracking - the same
        // reason the roster's own timer is registered that way.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timerInterval = wanted
    }
}
