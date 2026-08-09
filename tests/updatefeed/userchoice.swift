import Foundation

// What the user answering Sparkle's own dialog does to the state, and the flag that says a person
// is waiting on a silent install. Split out of main.swift when that file reached its size cap;
// the checks are unchanged and are called from there.

func runUserChoiceChecks() {
    // MARK: P2a - requestedByUser only lives in the transitions that can consume it
    //
    // The flag means "a person is waiting on a silent install", and the only thing that consumes it is
    // an install handler arriving. Sparkle's UI driver never delivers one (it answers its dialog
    // through showReadyToInstallAndRelaunch instead), so a press that merely earns a visible check
    // must not raise it: the flag would sit set and the next reader would act on a request that was
    // answered long ago. Stated as an invariant over every press, rather than as a list of the cases
    // somebody happened to think of.

    let pressScenarios: [(name: String, state: UpdateState)] = [
        ("nothing known", fresh()),
        ("update known, silent installs allowed", {
            var s = fresh(); send(&s, .feedRead(newest: v531, skippedBuild: nil)); return s }()),
        ("update known, silent installs NOT allowed", {
            var s = fresh(autoInstall: false); send(&s, .feedRead(newest: v531, skippedBuild: nil)); return s }()),
        ("this build already failed to install", {
            var s = fresh()
            send(&s, .feedRead(newest: v531, skippedBuild: nil))
            send(&s, .sparkleStagedUpdate(v531))
            send(&s, .installAttemptFailed)
            return s }()),
        ("the version was skipped", {
            var s = fresh(); send(&s, .feedRead(newest: v531, skippedBuild: 531)); return s }()),
        ("a payload is staged and its trigger is in hand", {
            var s = fresh()
            send(&s, .feedRead(newest: v531, skippedBuild: nil))
            send(&s, .installHandlerArrived(v531))
            return s }()),
    ]

    for scenario in pressScenarios {
        var state = scenario.state
        let actions = send(&state, .chipPressed)
        expect(state.requestedByUser == actions.contains(.beginSilentInstall),
               "P2a: the flag is up exactly when a silent install was started - \(scenario.name)")
    }

    do {
        var state = fresh(autoInstall: false)
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        expect(send(&state, .chipPressed) == [.visibleCheck], "no consent, so the press opens a window")
        expect(!state.requestedByUser, "P2a: which leaves nothing outstanding")
        // The window's session ending in an error must not be read as "the silent install I asked for
        // failed", because none was asked for. That reading re-opened the check, over and over.
        expect(send(&state, .installAttemptFailed).contains(.visibleCheck) == false,
               "P2a: an aborted visible check does not open another visible check")
    }

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        expect(send(&state, .chipPressed) == [.beginSilentInstall], "consent given, so it goes silently")
        expect(state.requestedByUser, "and that IS outstanding")
        expect(send(&state, .installAttemptFailed).contains(.visibleCheck),
               "P2a: so this one does earn the window that reports the error")
        expect(!state.requestedByUser, "and is spent afterwards")
    }

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .chipPressed)
        send(&state, .userMadeChoice(.dismiss, build: 531))
        expect(!state.requestedByUser, "P2a: dismissing the dialog clears any outstanding request")
    }

    // MARK: P2b - Skip This Version lands when it is pressed, not when the next poll happens

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        expect(state.chip?.display == "0.41.0", "the update is on offer")
        send(&state, .userMadeChoice(.skip, build: 531))
        expect(state.skippedBuild == 531, "P2b: the skip is recorded there and then")
        expect(state.chip == nil, "P2b: and the chip goes, without waiting for a reading of the feed")
        expect(send(&state, .chipPressed) == [.visibleCheck],
               "P2b: pressing the chip cannot reopen the update that was just declined")
        expect(send(&state, .momentArrived(idle: true)).isEmpty,
               "P2b: nor does it install itself later")
    }

    do {
        // With automatic checks off there is no next poll at all, which is the case the callback
        // exists for: reading SUSkippedVersion only at poll time would never catch up.
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .watchingChanged(false))
        send(&state, .userMadeChoice(.skip, build: 531))
        expect(state.chip == nil, "P2b: the skip lands even when nothing will ever poll again")
        expect(send(&state, .userMadeChoice(.skip, build: 540)).isEmpty,
               "a skip with no trigger in hand asks for nothing - there is nothing to let go of")
    }

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .installHandlerArrived(v531))
        expect(state.installHandlerHeld, "a trigger is in hand")
        let actions = send(&state, .userMadeChoice(.skip, build: 531))
        expect(actions == [.discardHeldInstall],
               "P2b: Sparkle cancels a staged install on skip, so the trigger is let go of")
        expect(!state.installHandlerHeld && state.staged == nil,
               "P2b: and the app stops believing it has a payload")
        expect(send(&state, .checkPressed) == [.visibleCheck],
               "P2b: so Check Now asks again rather than running a cancelled install")
    }

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .userMadeChoice(.skip, build: 531))
        send(&state, .feedRead(newest: release(540, "0.42.0"), skippedBuild: 531))
        expect(state.chip?.display == "0.42.0", "P2b: skipping one version does not skip the next")
    }

    do {
        var state = fresh()
        send(&state, .feedRead(newest: v531, skippedBuild: nil))
        send(&state, .userMadeChoice(.install, build: 531))
        expect(state.chip?.display == "0.41.0" && state.skippedBuild == nil,
               "choosing Install skips nothing and changes nothing - Sparkle takes it from there")
    }
}
