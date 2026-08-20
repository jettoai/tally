import Foundation

// THE ROW NOBODY PRESSES, BECAUSE NOBODY KNOWS IT APPEARED.
//
// Every integration in this pane is opt-in, which is right for the FIRST press: these write into
// files the app does not own. It is wrong for the second one. Somebody running the status line, the
// session board and the subagent hooks has already said, in the only way a machine can record it,
// that Tally may manage their Claude settings.json - and when a later version registers another hook
// in that same file, all they get is a row they have no reason to open Settings and find. 0.59.0
// shipped the quota knock exactly that way: onto a machine whose every other row read "Installed",
// installed on none of them, with the warning it exists to deliver still going down the terminal
// channel it was written to replace.
//
// So a component named in `autoFollowComponents` FOLLOWS: on a machine that has already authorized
// writes into settings.json it goes in at launch, and the user is told once, with an Undo beside the
// sentence (SettingsView). Three things are what make doing that without asking honest:
//
//   - THE AUTHORIZATION IS READ, NEVER ASSUMED. `~/.tally/manifest.json` records the paths every
//     press has ever written, so another component's entry naming a settings.json IS a press the
//     user made, in this file (`settingsWriteAuthorized`).
//   - A REMOVAL LEAVES NO TRACE, so it has to be written down. Removing a row takes the hooks out of
//     settings.json AND the entry out of the manifest, which means a later launch cannot tell
//     "removed on purpose" from "never installed" - the same distinction `LaunchAtLoginDefault` had
//     to store for the login item, for the same reason and with the same rule: the record says the
//     one uninvited action has been SPENT, not that it worked. Anything this pass settles, in either
//     direction, is never touched again (`autoFollowHandledKey`).
//   - AN ENTRY IS NOT A DELIVERY. The knock hooks name `/usr/local/bin/tally`, and hooks that cannot
//     run are worse than absent (`quotaKnockCLIDeliverable` argues it in full): they take the
//     channel that works away in favour of one that silently does nothing. A component that cannot
//     be delivered is skipped WITHOUT being recorded, so it follows on the launch after the command
//     line tool goes in.
extension IntegrationsStore {
    // MARK: The set that follows

    /// One integration that follows a machine's existing authorization.
    ///
    /// A LIST RATHER THAN A SPECIAL CASE, because the failure this repairs is not the quota knock's:
    /// it is what happens to every hook this pane gains after somebody has installed the ones before
    /// it. The next one is an entry here and nothing else.
    ///
    /// Deliberately NOT the rest of the pane. The command line tool links into a directory shared
    /// with the rest of the machine, the shims edit a shell profile, the shared harness moves
    /// conversations between config homes: an authorization to register a hook in settings.json is
    /// not an authorization to do any of those, and reading it as one is how "it installed itself"
    /// stops being a courtesy.
    struct AutoFollowComponent {
        /// The manifest key, which is this component's identity in all three records: the manifest,
        /// the handled list, and the notice. One spelling, like every other manifest key here.
        let component: String
        /// The row's own title, through the same localized key the pane uses, so the sentence the
        /// user reads and the row they go looking for can never name it differently.
        let title: () -> String
        let status: (IntegrationsStore) -> Status
        let install: (IntegrationsStore) -> Void
        let remove: (IntegrationsStore) -> Void
        /// Whether what the install registers could actually run, asked before installing it.
        let deliverable: () -> Bool
    }

    /// TWO QUESTIONS ABOUT THE PROGRAM THE HOOKS NAME, and a silent install may not skip either:
    /// can it run, and is it ours.
    ///
    /// `quotaKnockCLIDeliverable` answers the first, over `/usr/local/bin/tally` itself: an entry is
    /// not a delivery, and hooks naming a path with nothing runnable at it take the typed channel
    /// away in favour of nothing.
    ///
    /// `cliToolIsAppManaged` answers the second, and it is the half a press cannot need. A row
    /// somebody CLICKS is them deciding what the command on their PATH is; this pass decides for
    /// them, on a machine where that path is shared with every other program on it. A `tally` that
    /// Homebrew or anything else put there is executable, so the first question alone would have
    /// this app register two hooks that run a STRANGER'S program on every prompt and every tool call
    /// - and, worse than merely useless, the supervisor then reads the registration as a working
    /// filing channel and stops typing the warning down the tty that did work
    /// (`quotaKnockFilingAvailable`). The strict question is the completion install's own gate
    /// (`cliToolIsOurs`: the link points into this bundle, or the manifest says we made it), for the
    /// same reason and against the same Homebrew case.
    static var autoFollowComponents: [AutoFollowComponent] {
        [AutoFollowComponent(component: knockHookManifest,
                             title: { L("Claude quota warning") },
                             status: { $0.knockHookStatus },
                             install: { $0.installKnockHooks() },
                             remove: { $0.removeKnockHooks() },
                             deliverable: { quotaKnockCLIDeliverable() && cliToolIsAppManaged() })]
    }

    static func autoFollowComponent(_ component: String) -> AutoFollowComponent? {
        autoFollowComponents.first { $0.component == component }
    }

    // MARK: The decision

    /// What one launch should do about the followable set. Two lists rather than one, because
    /// recording is not installing: the second is what a machine that has already answered for a
    /// component gets, and the difference is the whole of this feature's restraint.
    struct AutoFollowPlan: Equatable {
        /// Install now, and record it only if the install lands.
        var install: [String] = []
        /// Record as settled without touching anything at all.
        var settle: [String] = []
    }

    /// One candidate as the decision reads it. Pure inputs, so the whole table is assertable on a
    /// machine with no config homes, no manifest and no `tally` on its PATH.
    struct AutoFollowCandidate: Equatable {
        let component: String
        let status: Status
        let deliverable: Bool
    }

    /// The decision, in one place and with nothing in it that touches disk.
    ///
    /// `isUnshipped` and `isDemo` are gates rather than callers' business, exactly as they are in
    /// `LaunchAtLoginDefault.plan`: a build nobody installed must never write into the config homes,
    /// and a launch showing fixtures must never change the machine. Both produce an EMPTY plan
    /// rather than a settle list, because a launch that may not act has not spent anything and must
    /// not claim it has.
    ///
    /// ANYTHING ALREADY ON DISK IS SETTLED, installed and broken alike, and the broken half is the
    /// one that reads as pedantry until you follow it: a half-registration this pass declined to
    /// record would be reinstalled the moment the user pressed Remove on it, which is precisely the
    /// press this whole record exists to respect. Repairing a broken row is the row's own Reinstall
    /// button, not something a silent launch pass should be doing.
    static func autoFollowPlan(_ candidates: [AutoFollowCandidate],
                               manifest: [String: Any],
                               handled: [String],
                               isUnshipped: Bool,
                               isDemo: Bool) -> AutoFollowPlan {
        guard !isUnshipped, !isDemo else { return AutoFollowPlan() }
        let settled = Set(handled)
        var plan = AutoFollowPlan()
        for candidate in candidates where !settled.contains(candidate.component) {
            guard candidate.status == .notInstalled else {
                plan.settle.append(candidate.component)
                continue
            }
            // NOT RECORDED WHEN IT IS SKIPPED. An unauthorized machine may authorize itself with the
            // next press, and a command line tool that is not there yet is usually one press away
            // too: recording either as settled would spend the follow on a launch that did nothing.
            guard settingsWriteAuthorized(manifest: manifest, besides: candidate.component),
                  candidate.deliverable else { continue }
            plan.install.append(candidate.component)
        }
        return plan
    }

    /// Whether this machine has ever let Tally write a Claude settings.json, read off the record of
    /// what the presses actually wrote.
    ///
    /// BESIDES THE COMPONENT BEING ASKED ABOUT, which is not a detail. A component's own manifest
    /// entry can outlive a removal that could not finish (it is kept as a retry list, see
    /// `removeKnockHooks(from:)`), and letting that entry authorize its own reinstall would make the
    /// one record standing between a user's Remove and an uninvited reinstall be written by the
    /// thing it is supposed to restrain.
    ///
    /// The file name is what marks a path as this file: it is the name `claudeSettingsFiles()`
    /// builds every one of these paths with, and the manifest holds paths from components that write
    /// shell profiles and symlinks too, which authorize nothing here.
    static func settingsWriteAuthorized(manifest: [String: Any], besides component: String) -> Bool {
        manifest.contains { key, entry in
            guard key != component,
                  let paths = (entry as? [String: Any])?["paths"] as? [String] else { return false }
            return paths.contains {
                URL(fileURLWithPath: $0).lastPathComponent == "settings.json"
            }
        }
    }

    // MARK: The record

    /// The components this feature has finished with, whichever way they were finished.
    ///
    /// Per user, per bundle id, like the login item's one bit, so the dev flavour cannot spend the
    /// release app's follow. It is written in three moments, and the third is the one that makes the
    /// invariant hold: an install that landed, a launch that found the component already there, and
    /// ANY removal of one of these rows (`removeKnockHooks`, which every press reaches - the row's
    /// Remove, Remove all, and the notice's own Undo).
    ///
    /// THE ONE VERSION THIS RECORD CANNOT REACH BACK TO, stated because it is a real gap rather than
    /// an oversight: 0.59.0 shipped the quota warning row with a removal that wrote nothing here,
    /// because none of this existed yet. Somebody who installed that row by hand on 0.59.0 and then
    /// removed it has it put back, once, on their first launch of a version carrying this file.
    ///
    /// There is no migration, and that is a fact about what the old removal DID rather than a
    /// decision taken here: it took the hooks out of settings.json AND the entry out of the
    /// manifest, so the machine holds nothing that separates "removed on purpose" from "never
    /// installed". A migration would have to invent the difference, which is the same guess this
    /// whole record exists to avoid making.
    ///
    /// What that user gets instead is the design's own remedy: the notice says what happened, its
    /// Undo takes it straight back out, and THAT removal is recorded here permanently. The window is
    /// also exactly one version wide (0.59.0 was still the day's release when this landed), which is
    /// why one notice was judged a fair price for closing the silence that shipped it.
    nonisolated static let autoFollowHandledKey = "integrationAutoFollowHandled"

    /// The components installed without being asked for, still waiting to be read.
    ///
    /// Persisted, unlike the login item's one-shot report, and for the opposite half of the same
    /// reason: nobody was at the machine when this happened, so a notice that lived only as long as
    /// the launch it was made on would be a notice the user never got. It stands until it is
    /// dismissed or undone.
    nonisolated static let autoFollowNoticeKey = "integrationAutoFollowNotice"

    static func autoFollowHandled() -> [String] {
        UserDefaults.standard.stringArray(forKey: autoFollowHandledKey) ?? []
    }

    /// Adding to one of those lists, as arithmetic: idempotent, and never dropping what is there.
    /// Pure so the property that matters is assertable without a defaults domain to write into.
    static func autoFollowRecorded(_ component: String, in existing: [String]) -> [String] {
        existing.contains(component) ? existing : existing + [component]
    }

    /// Mark a component settled. Undone by nothing: this is the record that answers a user's Remove
    /// press with silence rather than with a reinstall at the next launch.
    func recordAutoFollowHandled(_ component: String) {
        UserDefaults.standard.set(
            Self.autoFollowRecorded(component, in: Self.autoFollowHandled()),
            forKey: Self.autoFollowHandledKey)
    }

    // MARK: The notice

    /// The notices standing when this process starts.
    static func storedAutoFollowNotices() -> [String] {
        UserDefaults.standard.stringArray(forKey: autoFollowNoticeKey) ?? []
    }

    func showAutoFollowNotice(_ component: String) {
        autoFollowNotices = Self.autoFollowRecorded(component, in: autoFollowNotices)
        UserDefaults.standard.set(autoFollowNotices, forKey: Self.autoFollowNoticeKey)
    }

    /// Read and understood: the sentence goes, and does not come back.
    func dismissAutoFollowNotice(_ component: String) {
        autoFollowNotices.removeAll { $0 == component }
        UserDefaults.standard.set(autoFollowNotices, forKey: Self.autoFollowNoticeKey)
    }

    /// Take back what the launch put in.
    ///
    /// Through the row's OWN removal, so a press here and a press on the row below are the same act,
    /// recorded the same way and reported the same way. The sentence only goes if the removal
    /// worked: a failure leaves it standing beside the error the pane is already showing, which is
    /// the one state where the offer is still worth having.
    func undoAutoFollow(_ component: AutoFollowComponent) {
        component.remove(self)
        guard lastError == nil else { return }
        dismissAutoFollowNotice(component.component)
    }

    // MARK: The launch pass

    /// Whether this process has already made its pass. One per launch, like the login item default:
    /// the plan is idempotent, but "at most once" is a property worth having by construction rather
    /// than by argument.
    private static var autoFollowHasRun = false

    /// Install what this machine has already authorized and does not have yet, and say so once.
    ///
    /// Silent about everything except the one thing it did. A failed install lands in `lastError`
    /// like any other (the Settings pane shows it), is not recorded, and is not announced: the row
    /// keeps whatever word describes it, and the next launch tries again from wherever the failure
    /// left the file.
    func followNewIntegrations() {
        guard !Self.autoFollowHasRun else { return }
        Self.autoFollowHasRun = true
        let plan = Self.autoFollowPlan(
            Self.autoFollowComponents.map {
                AutoFollowCandidate(component: $0.component, status: $0.status(self),
                                    deliverable: $0.deliverable())
            },
            manifest: Self.manifestDocument(),
            handled: Self.autoFollowHandled(),
            isUnshipped: BuildVariant.isUnshipped,
            isDemo: DemoUsage.isActive)
        for component in plan.settle { recordAutoFollowHandled(component) }
        for key in plan.install {
            guard let component = Self.autoFollowComponent(key) else { continue }
            component.install(self)   // refreshes the store on its way out
            // The install's own verdict, read off the status it just recomputed rather than off the
            // absence of an error: a registration that landed in one config home and threw in the
            // next is neither installed nor nothing, and announcing it as done would put an Undo in
            // front of the user for a state they have to repair instead.
            guard component.status(self) == .installed else { continue }
            recordAutoFollowHandled(key)
            showAutoFollowNotice(key)
        }
    }
}
