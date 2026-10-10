import Foundation

// B-1395: an update the unattended install has held for hours is said out loud, once per stuck
// installed build. 0.85.28 sat seven hours on the machine it was for before anyone noticed.
func runLagChecks() {
    let hour: TimeInterval = 3600
    func waiting(installed: Int = 510, autoInstall: Bool = true, skipped: Int? = nil) -> UpdateState {
        var state = UpdateState(installedBuild: installed)
        state.installsAutomatically = autoInstall
        send(&state, .feedRead(newest: v531, skippedBuild: skipped))
        return state
    }
    let state = waiting()
    expect(state.knownSince == epoch && state.busy == nil, "L0: the offer is known from the read on")
    expect(UpdateLag.due(state, now: epoch + 3 * hour - 60, announcedFor: nil) == nil,
           "L1: 2h59m is still the ordinary wait")
    expect(UpdateLag.due(state, now: epoch + 3 * hour + 60, announcedFor: nil) == v531,
           "L2: past three hours the newest release is announced")
    expect(UpdateLag.due(state, now: epoch + 9 * hour, announcedFor: 510) == nil,
           "L3: once per stuck installed build")
    expect(UpdateLag.due(waiting(installed: 521), now: epoch + 4 * hour, announcedFor: 510) == v531,
           "L4: a newer installed build that falls behind again re-arms it")
    expect(UpdateLag.due(waiting(autoInstall: false), now: epoch + 4 * hour, announcedFor: nil) == nil,
           "L5: without the install consent the chip is the whole story")
    var checking = waiting()
    checking.busy = .checking
    expect(UpdateLag.due(checking, now: epoch + 4 * hour, announcedFor: nil) == nil,
           "L6: an install under way is not stuck")
    expect(UpdateLag.due(waiting(skipped: 531), now: epoch + 4 * hour, announcedFor: nil) == nil,
           "L7: a skipped version is not announced")
    expect(UpdateLag.due(waiting(installed: 531), now: epoch + 4 * hour, announcedFor: nil) == nil,
           "L8: nothing newer than what is installed")
}
