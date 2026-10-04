import Foundation

// 2026-10-04: Check Now with the install consent on went through Sparkle's UI driver, which ended in
// a ready-to-install window nobody could see; the chip read "Updating..." for eighteen minutes over
// it. These walk the press that must now install on its own, and the stall rule that catches every
// shape that still goes quiet.
func runStallChecks() {
    let t0 = epoch

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        expect(send(&state, .checkPressed) == [.beginSilentInstall],
               "T1: with the consent on, Check Now installs in the background rather than asking")
        expect(state.busy == .checking && state.requestedByUser,
               "T1: and it is a press that is waiting, so the payload runs as soon as it is ready")
        send(&state, .sparkleWillDownload)
        send(&state, .sparkleWillExtract)
        expect(send(&state, .installHandlerArrived(v531)) == [.runHeldInstall],
               "T2: the install comes back to the app and runs at once")
        expect(state.busy == .restarting, "T2: and the chip says a restart is coming")
    }

    do {
        // The real sample, replayed down the path the old build took: a press, Install in Sparkle's
        // dialog, a download and an unpack, then nothing at all.
        var state = fresh()
        send(&state, .checkPressed, at: t0)
        send(&state, .userMadeChoice(.install, build: 531), at: t0.addingTimeInterval(3))
        send(&state, .sparkleWillDownload, at: t0.addingTimeInterval(4))
        send(&state, .sparkleWillExtract, at: t0.addingTimeInterval(7))
        expect(!UpdateStall.isStalled(state, now: t0.addingTimeInterval(299)),
               "T3: a spinner under five minutes old is still just working")
        expect(UpdateStall.isStalled(state, now: t0.addingTimeInterval(301)),
               "T3: past five minutes with nothing moving it is stuck, whatever step it sits on")
    }

    do {
        var state = fresh()
        send(&state, .checkPressed)
        expect(send(&state, .updateCycleEnded) == [.visibleCheck],
               "T4: a background check that found nothing still owes the press its window")
        expect(state.busy == nil && !state.requestedByUser, "T4: and the press is then answered")
    }

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed)
        expect(send(&state, .updateCycleEnded) == [.visibleCheck],
               "T5: a chip press Sparkle could not serve in the background gets a window")
        expect(!state.requestedByUser, "T5: and the flag does not outlive the press")
    }

    do {
        var state = fresh(autoInstall: false)
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        expect(send(&state, .checkPressed) == [.visibleCheck] && !state.requestedByUser,
               "T6: without the consent, Check Now is still a question answered in a window")
    }

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed)
        send(&state, .installHandlerArrived(v531))
        send(&state, .installAttemptFailed)
        expect(state.failedBuild == 531, "T7: the attempt is recorded as failed")
        expect(send(&state, .checkPressed) == [.visibleCheck],
               "T7: a failed build is retried only where the person can see what goes wrong")
    }

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed)
        expect(send(&state, .checkPressed) == [.visibleCheck] && state.busy == .checking,
               "T8: Check Now during a running install brings Sparkle forward and changes nothing")
    }

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed, at: t0)
        send(&state, .sparkleWillDownload, at: t0.addingTimeInterval(10))
        send(&state, .sparkleWillExtract, at: t0.addingTimeInterval(20))
        expect(state.busySince == t0, "T9: the clock runs from the start of the install, not the step")
        send(&state, .silentInstallCouldNotStart, at: t0.addingTimeInterval(30))
        expect(state.busySince == nil && !UpdateStall.isStalled(state, now: t0.addingTimeInterval(999)),
               "T10: with nothing running there is no clock and nothing stuck")
    }

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed, at: t0)
        send(&state, .installHandlerArrived(v531), at: t0)
        expect(state.busy == .restarting, "T11: the trigger has been pulled")
        expect(UpdateStall.isStalled(state, now: t0.addingTimeInterval(301)),
               "T11: a restart that never came is stuck too")
    }

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed)
        send(&state, .sparkleWillDownload)
        expect(send(&state, .installAttemptFailed).contains(.visibleCheck),
               "T12: a failed install the person was waiting on reports in a window")
        expect(send(&state, .updateCycleEnded).isEmpty,
               "T12: and the cycle ending after it does not open a second one")
    }
}
