import AppKit
import Sparkle

// Sparkle's side of the conversation: every callback the updater makes, turned into one
// `UpdateEvent` and handed to `UpdaterController.apply`. Split out of UpdaterController.swift for
// the 500-line rule; nothing else changed in the move.

extension UpdaterController: SPUUpdaterDelegate {
    /// What Sparkle just fetched, which is a reading of the same feed the poller reads.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let release = Self.release(from: item)
        Task { @MainActor in self.apply(.sparkleFoundUpdate(release)) }
    }

    /// The two callbacks that account for the wait. Between a press and the restart Sparkle spends
    /// most of its time in these, and with automatic installs on it spends all of it off screen:
    /// the press was reported as "the app froze and then closed itself" because nothing in between
    /// was ever said out loud.
    nonisolated func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem,
                             with request: NSMutableURLRequest) {
        Task { @MainActor in self.apply(.sparkleWillDownload) }
    }

    nonisolated func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        Task { @MainActor in self.apply(.sparkleWillExtract) }
    }

    /// Sparkle's driver has finished, whatever came of it. The errors arrive at `didAbortWithError`
    /// as well and are handled there; this one is here for the endings that are not errors and
    /// would otherwise leave a chip saying it was still working: a check that found nothing, an
    /// update deferred because it needs the user's attention first.
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: (any Error)?) {
        Task { @MainActor in self.apply(.updateCycleEnded) }
    }

    /// Second chip state, the Ghostty semantic: the payload is already on disk, so a click means
    /// "restart into the new version", not "start a download". The chip goes green + ↻.
    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let release = Self.release(from: item)
        Task { @MainActor in self.apply(.sparkleStagedUpdate(release)) }
    }

    /// Sparkle's own view of an appcast entry, in the shape the plan compares. An item whose
    /// `sparkle:version` will not read as an integer is not something this app's own ranking can
    /// place, so it is left out and Sparkle's comparator remains the only judge of it.
    nonisolated private static func release(from item: SUAppcastItem) -> FeedRelease? {
        guard let build = Int(item.versionString) else { return nil }
        return FeedRelease(build: build, display: item.displayVersionString,
                           minimumSystemVersion: item.minimumSystemVersion)
    }

    /// Take the install over. Answering true stalls Sparkle's cycle and hands this app the
    /// trigger; when it is pulled is the reducer's business, and the caller follows with the idle
    /// question so a moment that has already arrived is not missed.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void)
        -> Bool {
        let handler = InstallHandler(run: immediateInstallHandler)
        let release = Self.release(from: item)
        Task { @MainActor in
            self.pendingInstall = handler
            self.apply(.installHandlerArrived(release))
            if self.pendingInstall != nil { self.installIfIdle() }
        }
        return true
    }

    /// What the user answered in Sparkle's own dialog. Implementing this is also what stops
    /// Sparkle reaching for its deprecated `userDidSkipThisVersion:` (it prefers this one and only
    /// falls back when this is absent, SPUUIBasedUpdateDriver.m:257-264).
    ///
    /// Skip is the one that matters: it is written to `SUSkippedVersion` at the moment the button
    /// is pressed, and the app's own reading of that key happens when its poll completes, which is
    /// usually earlier and, with automatic checks turned off, may never happen again. Without this
    /// the chip would go on offering a version the user had just declined, and pressing it would
    /// reopen the same update.
    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                             forUpdate updateItem: SUAppcastItem,
                             state updateState: SPUUserUpdateState) {
        let build = Int(updateItem.versionString)
        let answer: UpdateUserChoice
        switch choice {
        case .skip: answer = .skip
        case .install: answer = .install
        case .dismiss: answer = .dismiss
        @unknown default: answer = .dismiss
        }
        Task { @MainActor in self.apply(.userMadeChoice(answer, build: build)) }
    }

    /// Sparkle gave up: a signature that did not verify, an authorisation the user cancelled, a
    /// disk with no room, a feed it could not reach. The app is still here, so everything stood
    /// down for a restart that is not coming gets put back, and the build that failed is
    /// remembered so the idle timer does not spend the rest of the day re-downloading it.
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        Task { @MainActor in self.apply(.installAttemptFailed) }
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.apply(.willRelaunch)
            UpdateAvailability.shared.clear()
        }
    }
}
