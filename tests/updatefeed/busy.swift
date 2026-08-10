import Foundation

// What the chip shows while a press is being carried out. Split out of main.swift for the reason
// userchoice.swift was: that file is at its size cap.
//
// The defect these forbid: with automatic installs on, pressing the chip started a background
// check, a download and an unpack with nothing on screen changing at all, and the app then replaced
// itself and reopened. From the outside that is a press that did nothing followed by the app
// closing itself, which is exactly how it was reported ("it looks like it hung"). So every step of
// the press is a state here, and, just as importantly, every way a press can END is one of the
// transitions that clears it: a spinner that outlives its install is the same defect wearing the
// fix's clothes, because the chip refuses presses while it is up.

func runBusyChecks() {
    // MARK: P3 - a press says so from the first frame, and keeps saying what it is doing

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        expect(state.busy == nil, "P3: nothing is running before the press")
        expect(send(&state, .chipPressed) == [.beginSilentInstall], "the press starts the install")
        expect(state.busy == .checking, "P3: and the chip says so from the moment it is pressed")
        send(&state, .sparkleWillDownload)
        expect(state.busy == .downloading, "P3: the download is reported as it starts")
        send(&state, .sparkleStagedUpdate(v531))
        expect(state.busy == .downloading,
               "P3: a staged payload is not the end of the wait - the unpack is still to come")
        send(&state, .sparkleWillExtract)
        expect(state.busy == .extracting, "P3: and so is the unpack")
        let onArrival = send(&state, .installHandlerArrived(v531))
        expect(onArrival == [.runHeldInstall], "the outstanding press runs the install")
        expect(state.busy == .restarting,
               "P3: which is the one warning the user gets that the app is about to be replaced")
        send(&state, .willRelaunch)
        expect(state.busy == .restarting, "P3: and it stands until the app is gone")
    }

    do {
        // The unattended path says it too. Nobody asked for this one, which is the argument FOR
        // showing it: an app that restarts itself unannounced is the thing being repaired.
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        expect(send(&state, .momentArrived(idle: true)) == [.beginSilentInstall],
               "the idle moment starts one too")
        expect(state.busy == .checking, "P3: and it is shown, not done behind the user's back")
    }

    // MARK: P3 - every ending clears it, because the chip is refused while it is up

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed)
        send(&state, .installAttemptFailed)
        expect(state.busy == nil, "P3: an install that failed is not an install that is running")
        expect(state.chip != nil && send(&state, .chipPressed) == [.visibleCheck],
               "P3: so the chip takes a press again, which is how the error gets reported")
    }

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed)
        send(&state, .userMadeChoice(.skip, build: 531))
        expect(state.busy == nil, "P3: skipping the version ends the install it was for")
    }

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed)
        send(&state, .userMadeChoice(.dismiss, build: 531))
        expect(state.busy == nil, "P3: and so does closing the window it opened")
    }

    do {
        // The guard in `beginSilentInstall` (Sparkle already busy, or the consent withdrawn between
        // the decision and the call) used to return in silence. Nothing else would ever have come
        // along, so the chip would have spun for the rest of the run over a press that never went
        // anywhere - and refused every press meanwhile.
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed)
        expect(send(&state, .silentInstallCouldNotStart).isEmpty,
               "an install that never started asks for nothing")
        expect(state.busy == nil, "P3: but it does stop the chip claiming one is running")
        expect(send(&state, .chipPressed) == [.beginSilentInstall],
               "P3: and the next press is allowed to try again")
    }

    do {
        // Sparkle's own driver finishing, for the endings that are not errors: a check that found
        // nothing, an update deferred because it needs the user's attention first. Neither reaches
        // didAbortWithError, so neither would otherwise be heard from again.
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed)
        expect(send(&state, .updateCycleEnded).isEmpty, "the cycle ending asks for nothing")
        expect(state.busy == nil, "P3: Sparkle stopped working, so the chip stops saying it is")
    }

    do {
        // The exception, and the reason it is one: after the trigger is pulled the app is on its
        // way out, and the one Sparkle path that ends the cycle at that point (an authorisation
        // the user put off until quit) still installs on quit. A chip that came back to life there
        // would be offering to install the same payload a second time.
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed)
        send(&state, .installHandlerArrived(v531))
        expect(state.busy == .restarting, "the install has been handed back")
        send(&state, .updateCycleEnded)
        expect(state.busy == .restarting, "P3: and that is not undone by the cycle ending")
    }

    do {
        // The idle path stages ahead of any press: the download is over, nothing is running, and
        // the app is waiting for a quiet moment. A spinner there would be claiming work nobody is
        // doing, and would lock the chip out of the press that skips the wait.
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .momentArrived(idle: true))
        send(&state, .installHandlerArrived(v531))
        expect(state.busy == nil && !state.requestedByUser,
               "P3: a payload waiting for an idle moment is not work in progress")
        expect(send(&state, .chipPressed) == [.runHeldInstall],
               "P3: so a press can still skip the wait")
        expect(state.busy == .restarting, "and that press does announce the restart")
    }

    // MARK: P3 - a second press while the first is running changes nothing

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed)
        send(&state, .sparkleWillDownload)
        let before = state
        expect(send(&state, .chipPressed).isEmpty,
               "P3: a press while the install runs starts no second check")
        expect(state == before, "P3: and changes nothing at all")
    }

    // MARK: P3, the half that lives in the controller
    //
    // The reducer can only clear the spinner when it is told the install did not start. Whether it
    // is ever told is the controller's, and the failure is silent in the way the P1 assertions
    // below guard against: a chip that spins forever looks exactly like a slow download.

    // Read here rather than from main.swift's copy: a top-level `let` in main.swift is a global
    // initialized in source order, and this runs before that line does.
    let source = (try? String(contentsOfFile: "Tally/App/UpdaterController.swift", encoding: .utf8)) ?? ""
    let guardBody = body(of: "beginSilentInstall", in: source)
    expect(!guardBody.isEmpty, "beginSilentInstall was located in the controller source")
    expect(guardBody.contains("apply(.silentInstallCouldNotStart)"),
           "P3: the guard that starts nothing says so, rather than returning in silence")
    expect(source.contains("willDownloadUpdate") && source.contains("willExtractUpdate"),
           "P3: and the steps in between are subscribed to, or the chip has nothing to report")
    expect(source.contains("didFinishUpdateCycleFor"),
           "P3: as is the cycle ending, which is the ending that carries no error")
}
