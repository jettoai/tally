import Foundation

/// Everything the updater knows, as data, plus the one function that moves it.
///
/// The first version of this feature kept the same facts in half a dozen properties on
/// `UpdaterController` and moved them from inside Sparkle's callbacks, each of which had been
/// written for the case where things go well. Four separate defects came out of that one habit: a
/// failed install tore down the timers and never put them back, a failed background install was
/// retried every minute forever, a response that was not an update was read as "no update", and a
/// slow reply from the feed could overwrite a newer one. They are not four bugs so much as four
/// places where a transition was written down once, in a callback, from one direction.
///
/// So the transitions live here instead, as `state x event -> state + actions`, with no clock, no
/// network and no Sparkle in sight. Every one of the four is a row in the table the tests walk.
struct UpdateState: Equatable {
    /// This bundle's CFBundleVersion. Constant for the life of the process.
    let installedBuild: Int
    /// The "Automatically check for updates" preference.
    var watching = true
    /// The "Install updates automatically" preference: consent to install with nobody present.
    /// Sparkle persists this one, so the caller refreshes it from there on every event rather than
    /// keeping a second copy that could drift.
    var installsAutomatically = false
    /// The newest release the feed has offered so far this run.
    var newest: FeedRelease?
    /// What Sparkle has downloaded and staged.
    var staged: FeedRelease?
    /// Sparkle's install handler is in hand, so an install is one call away.
    var installHandlerHeld = false
    /// The app has handed an install back to Sparkle and expects to be replaced. Nothing else is
    /// started while this is true.
    var installing = false
    /// The build of an install attempt that came back with an error. It is not attempted again on
    /// its own; only a newer release, or somebody pressing the chip, gets past it.
    var failedBuild: Int?
    /// The build the user chose to skip, as Sparkle recorded it (`SUSkippedVersion`).
    var skippedBuild: Int?
    /// A silent install that a PERSON asked for is outstanding, so the payload runs the moment it
    /// is ready rather than waiting for the machine to go quiet.
    ///
    /// Set by exactly one transition (the one that emits `.beginSilentInstall` for a press) and
    /// cleared by every transition that ends such an install. It deliberately is NOT set by a press
    /// that only earns a visible check: Sparkle's UI driver answers a dialog through
    /// `showReadyToInstallAndRelaunch` and never calls `willInstallUpdateOnQuit`
    /// (SPUUIBasedUpdateDriver.m:417-426), so nothing on that path would ever consume the flag. It
    /// would sit set instead, and the next thing to read it would act on a request that was served
    /// long ago: an aborted check re-opening itself, or a later payload skipping the idle rules.
    var requestedByUser = false
    /// When the current offer first became known. The pinned-panel grace in `IdleInstall` is
    /// measured against it, and its absence is what stops the idle install from running at all.
    var knownSince: Date?
    /// The step of an install that is being carried out right now, or nil when nothing is running.
    ///
    /// Every transition that starts one sets it and every transition that ends one clears it, in
    /// this file, for the same reason the rest of the table is here: the version that shipped
    /// without it moved through a background check, a download and an unpack with nothing on
    /// screen changing at all, and then replaced the app. From the outside that is a press that did
    /// nothing followed by the app closing itself, which is what it was reported as.
    var busy: UpdateBusy?

    /// What the app is prepared to offer, which is not everything it knows: a version the user
    /// chose to skip is knowledge, not an offer. Anything newer than the skipped build still is.
    var offeredNewest: FeedRelease? { offering(newest) }
    var offeredStaged: FeedRelease? { offering(staged) }

    /// How the header chip should read, or nil for no chip.
    var chip: UpdateChip? {
        UpdatePlan.chip(installedBuild: installedBuild, staged: offeredStaged, newest: offeredNewest)
    }

    private func offering(_ release: FeedRelease?) -> FeedRelease? {
        guard let release, let skippedBuild, release.build <= skippedBuild else { return release }
        return nil
    }
}

/// The steps of an install, in the order they happen, as far as anybody waiting on one needs them.
/// Sparkle reports the first three; the fourth is the app's own, from the moment it hands the
/// install back and starts expecting to be replaced.
enum UpdateBusy: Equatable {
    case checking
    case downloading
    case extracting
    case restarting
}

/// Everything that can happen to the updater. Named for the fact, not for the Sparkle callback or
/// the timer that noticed it, so that "the feed said nothing new" and "the feed could not be read"
/// are different events rather than the same one with a nil in it.
enum UpdateEvent: Equatable {
    case watchingChanged(Bool)
    /// A reading of the feed that SUCCEEDED: transport fine, HTTP 2xx, XML parsed.
    case feedRead(newest: FeedRelease?, skippedBuild: Int?)
    /// A reading that did not. Carries nothing because it knows nothing.
    case feedReadFailed
    case sparkleFoundUpdate(FeedRelease?)
    /// Sparkle is about to fetch the payload, and about to spend a while doing it.
    case sparkleWillDownload
    /// The archive is on disk and is being unpacked, which on a signed DMG is not instant either.
    case sparkleWillExtract
    case sparkleStagedUpdate(FeedRelease?)
    case installHandlerArrived(FeedRelease?)
    /// A silent install was asked for and never got off the ground, because Sparkle already had a
    /// session open or the consent was withdrawn between the decision and the call. It is an event
    /// rather than a silent return in the caller because the chip is at that moment saying an
    /// install is running, and nothing else would ever come along to correct it.
    case silentInstallCouldNotStart
    /// Sparkle's update cycle ended (`didFinishUpdateCycleForUpdateCheck`). It cannot end while the
    /// install trigger is held, so this only arrives with nothing left running: a check that found
    /// nothing, an item deferred as informational, a session somebody closed.
    case updateCycleEnded
    /// Sparkle gave up on an update. The app is still running, which is the whole point.
    case installAttemptFailed
    /// The app is about to be replaced. The only event that may take the machinery down.
    case willRelaunch
    /// The header chip: an instruction, "put the newest version on".
    /// What the user answered in Sparkle's own update dialog. `build` is the item it was about.
    case userMadeChoice(UpdateUserChoice, build: Int?)
    case chipPressed
    /// Settings' Check Now, and the CLI's `tally update`: a question, "is there anything?", which
    /// earns an answer in a window rather than a restart nobody asked for.
    case checkPressed
    /// The idle timer fired; `idle` is `IdleInstall`'s verdict, read from the world by the caller.
    case momentArrived(idle: Bool)
}

/// The three answers Sparkle's update dialog can carry back
/// (`SPUUpdaterDelegate.updater(_:userDidMakeChoice:forUpdate:state:)`).
enum UpdateUserChoice: Equatable {
    case install
    case dismiss
    case skip
}

/// What the caller should go and do about it.
enum UpdateAction: Equatable {
    case startWatching
    case stopWatching
    case runHeldInstall
    case beginSilentInstall
    /// Run a check with Sparkle's own windows attached, so whatever happens is visible. Used for
    /// anything a person asked for, including the reporting of a failure.
    case visibleCheck
    case teardownForRelaunch
    /// Let go of an install trigger Sparkle has cancelled underneath us.
    case discardHeldInstall
}

enum UpdateReducer {
    static func reduce(_ state: inout UpdateState, _ event: UpdateEvent, now: Date) -> [UpdateAction] {
        switch event {
        case .watchingChanged(let on):
            state.watching = on
            state.settle(now: now)
            return on ? [.startWatching] : [.stopWatching]

        case .feedRead(let found, let skipped):
            state.skippedBuild = skipped
            state.learn(found)
            state.settle(now: now)
            return []

        case .feedReadFailed:
            // A 404 with a body, a 500 with a page, a truncated document: all of them parse to
            // "no items", and none of them is news about the feed. Nothing is written, which
            // includes not moving the "Last checked" clock the caller keeps.
            return []

        case .sparkleFoundUpdate(let found):
            state.learn(found)
            state.settle(now: now)
            return []

        case .sparkleWillDownload:
            state.busy = .downloading
            return []

        case .sparkleWillExtract:
            state.busy = .extracting
            return []

        case .sparkleStagedUpdate(let release):
            // Deliberately not the end of the wait: the payload is downloaded, and the unpack and
            // the preparation that follow it are most of the time the user spends looking at this.
            if let release { state.staged = release }
            state.settle(now: now)
            return []

        case .silentInstallCouldNotStart:
            state.busy = nil
            return []

        case .updateCycleEnded:
            // Nothing of Sparkle's is running any more, so a chip still claiming otherwise is
            // wrong. `.restarting` is the exception: the trigger has been pulled by then and the
            // app is on its way out, and the one path that ends the cycle afterwards (an
            // authorisation the user put off until quit) still installs on quit.
            if state.busy != .restarting { state.busy = nil }
            return []

        case .installHandlerArrived(let release):
            if let release { state.staged = release }
            state.installHandlerHeld = true
            // The fetching is over. Either the dispatch below turns this straight into a restart,
            // or nothing more happens until somebody asks, and a chip that goes on spinning while
            // the app waits for an idle moment is claiming work nobody is doing.
            state.busy = nil
            state.settle(now: now)
            // Only an outstanding press installs on the spot. Everything else waits to be asked
            // by the idle timer, which is the next thing the caller does anyway.
            guard state.requestedByUser else { return [] }
            return state.dispatch(userAsked: true)

        case .installAttemptFailed:
            // The app is alive and the update is not happening. Two things follow: the payload
            // that failed must not be retried on a timer (a signing or disk error would repeat
            // every minute for as long as the app runs), and everything that was stood down for
            // the restart has to come back, because a restart that did not happen must not be the
            // reason the app stops watching for updates. That was the original bug's shape.
            state.failedBuild = state.staged?.build ?? state.newest?.build
            state.staged = nil
            state.installHandlerHeld = false
            state.installing = false
            state.busy = nil
            let personWasWaiting = state.requestedByUser
            state.requestedByUser = false
            state.settle(now: now)
            return (state.watching ? [.startWatching] : []) + (personWasWaiting ? [.visibleCheck] : [])

        case .willRelaunch:
            state.installing = true
            return [.teardownForRelaunch]

        case .userMadeChoice(let choice, let build):
            switch choice {
            case .install:
                // Sparkle carries it out from here; how it goes arrives as its own event.
                break
            case .dismiss:
                // The visible session is over. Nothing there could have set the flag, and this is
                // the belt to that pair of braces.
                state.requestedByUser = false
                state.busy = nil
            case .skip:
                // Read here rather than waiting for the next reading of the feed. Sparkle writes
                // SUSkippedVersion when the button is pressed, and the app's own poll had usually
                // already answered by then; with automatic checks off there is no next poll at
                // all. Either way the chip would go on offering a version the user just declined.
                if let build { state.skippedBuild = build }
                // Sparkle cancels a staged installation on skip (SPUCoreBasedUpdateDriver.m:313),
                // so the payload and its trigger are gone.
                let hadTrigger = state.installHandlerHeld
                state.staged = nil
                state.installHandlerHeld = false
                state.requestedByUser = false
                state.busy = nil
                state.settle(now: now)
                return hadTrigger ? [.discardHeldInstall] : []
            }
            return []

        case .chipPressed:
            // A press while the last one is still being carried out. The chip is disabled off the
            // same fact and this is the belt to that brace: the press says nothing new, and acting
            // on it would put a second check on top of the running one.
            guard state.busy == nil else { return [] }
            return state.dispatch(userAsked: true)

        case .checkPressed:
            // A held handler stalls Sparkle's whole cycle, so a check would have nowhere to go
            // (SPUUpdater bails while sessionInProgress); running the thing that is already in
            // hand is the only answer available, and it is the one the press wanted anyway.
            guard !state.installHandlerHeld else { return state.dispatch(userAsked: true) }
            return state.installing ? [] : [.visibleCheck]

        case .momentArrived(let idle):
            // Three separate consents, all of which have to hold for an install nobody asked for:
            // the app is watching at all, the user allowed unattended installs, and the machine is
            // actually idle. The first is here because turning the checks switch off has to stop
            // the unattended install too, not merely stop the polling.
            guard state.watching, state.installsAutomatically, idle else { return [] }
            return state.dispatch(userAsked: false)
        }
    }
}

private extension UpdateState {
    /// Take in a reading. The appcast this app publishes is append-only, so a reading that goes
    /// BACKWARDS is a slow response that arrived after a fresher one, not a release being
    /// withdrawn: two polls in flight at once have no ordering guarantee, and the chip jumping
    /// back to an older version would be the visible half of that. Knowledge therefore only moves
    /// forward, and it resets on every launch.
    mutating func learn(_ found: FeedRelease?) {
        guard let found, found.build > (newest?.build ?? 0) else { return }
        newest = found
        // A newer build is a different payload, so an older one having failed says nothing about it.
        if let failedBuild, found.build > failedBuild { self.failedBuild = nil }
    }

    /// Keep the clock the idle rules measure against in step with whether there is anything to
    /// measure. Also the single place the checks preference takes the unattended install away.
    mutating func settle(now: Date) {
        guard watching, chip != nil else { knownSince = nil; return }
        if knownSince == nil { knownSince = now }
    }

    /// The one place an action is chosen, so that a press and an idle moment cannot drift apart.
    mutating func dispatch(userAsked: Bool) -> [UpdateAction] {
        guard !installing else { return [] }
        switch UpdatePlan.step(installedBuild: installedBuild, staged: offeredStaged, newest: offeredNewest) {
        case .nothing:
            // A press with nothing to install is a question, and Sparkle answers questions.
            return userAsked ? [.visibleCheck] : []
        case .installStaged, .installStaleStaged:
            guard installHandlerHeld else { return userAsked ? [.visibleCheck] : [] }
            installHandlerHeld = false
            requestedByUser = false
            // The app expects to be replaced from here, so the chip stops offering a version and
            // says what is about to happen instead. It is the only warning of the restart there is.
            busy = .restarting
            return [.runHeldInstall]
        case .fetchNewest(let release):
            // The failed build is passable by hand but not by timer: a person pressing it is
            // asking to see what goes wrong, and the visible path is where they find out.
            if release.build == failedBuild { return userAsked ? [.visibleCheck] : [] }
            guard installsAutomatically else { return userAsked ? [.visibleCheck] : [] }
            // The only place the flag goes up, which is what makes it mean what it says.
            if userAsked { requestedByUser = true }
            // Set on the idle path too, and not only for the press that is waiting on it: an
            // unattended install that ends in a restart should have said so on its way past.
            busy = .checking
            return [.beginSilentInstall]
        }
    }
}
