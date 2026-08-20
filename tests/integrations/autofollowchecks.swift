import Foundation

// The one integration pass that installs something NOBODY PRESSED (IntegrationsAutoFollow.swift), so
// what these assert is not that it works but that it stays inside its licence:
//
//   - it acts only where the user has already let Tally write the file it writes,
//   - it acts only on a row that is not there at all,
//   - it never puts back a row somebody took out,
//   - and it never touches a machine it may not touch (a dev build, a demo launch).
//
// The decision is pure for exactly that reason: the table below is asserted on a machine with no
// config homes, no manifest and no `tally` on its PATH.
@MainActor
func runAutoFollowChecks(tmp: URL) throws {
    typealias Candidate = IntegrationsStore.AutoFollowCandidate
    typealias Plan = IntegrationsStore.AutoFollowPlan
    let knock = IntegrationsStore.knockHookManifest
    let artifact = IntegrationsStore.artifactHookManifest

    /// A manifest whose OTHER component records a settings.json: the user's own earlier press.
    let authorized: [String: Any] = [
        "claudeStatusLine": ["paths": ["/Users/x/.claude/settings.json",
                                       "/Users/x/.claude2/settings.json"],
                             "installedAt": "2026-01-01T00:00:00Z"],
    ]
    /// A machine that has pressed Install on things that write ANYWHERE ELSE. A symlink into
    /// /usr/local/bin and a block in a shell profile authorize nothing about somebody's harness
    /// configuration, and reading them as consent is how "it installed itself" stops being a
    /// courtesy.
    let elsewhereOnly: [String: Any] = [
        "cliTool": ["paths": ["/usr/local/bin/tally"]],
        "claudeShim": ["paths": ["/Users/x/.tally/bin/claude", "/Users/x/.zshenv"]],
    ]

    func plan(status: IntegrationsStore.Status = .notInstalled,
              deliverable: Bool = true,
              manifest: [String: Any] = authorized,
              handled: [String] = [],
              isUnshipped: Bool = false,
              isDemo: Bool = false) -> Plan {
        IntegrationsStore.autoFollowPlan(
            [Candidate(component: knock, status: status, deliverable: deliverable)],
            manifest: manifest, handled: handled, isUnshipped: isUnshipped, isDemo: isDemo)
    }

    // THE ONE CASE THIS EXISTS FOR: everything else in that file is Tally's already, and the row the
    // new version added is not.
    check("a machine that already lets Tally write settings.json follows the new row",
          plan() == Plan(install: [knock], settle: []))
    // And with more than one candidate, which is what this list holds now: each is judged on its own
    // word, so a row already installed does not carry a missing one in with it.
    check("…and every followable row is judged on its own status",
          IntegrationsStore.autoFollowPlan(
            [Candidate(component: knock, status: .installed, deliverable: true),
             Candidate(component: artifact, status: .notInstalled, deliverable: true)],
            manifest: authorized, handled: [], isUnshipped: false, isDemo: false)
              == Plan(install: [artifact], settle: [knock]))

    // MARK: the three preconditions, each removed on its own

    check("a machine that has only let it write shell files and symlinks does not",
          plan(manifest: elsewhereOnly) == Plan())
    check("…nor one that has never pressed anything at all", plan(manifest: [:]) == Plan())
    // The row's OWN entry can outlive a removal that could not finish (it is kept as a retry list),
    // and letting it authorize its own reinstall would have the record that restrains this pass
    // written by the thing it restrains.
    check("…nor one where the only settings.json on record is this row's own leftover",
          plan(manifest: [knock: ["paths": ["/Users/x/.claude/settings.json"]]]) == Plan())
    check("…and an entry of an unexpected shape authorizes nothing either",
          plan(manifest: ["claudeSkill": "not an object"]) == Plan())

    // ALREADY THERE IS NOT A REASON TO INSTALL, it is a reason to stop asking. Both words that mean
    // something is on disk settle it, and the broken one is the half that matters: a
    // half-registration left unrecorded would be reinstalled the moment the user pressed Remove on
    // it, which is the press this whole record exists to respect.
    check("a row the user installed by hand is settled rather than installed",
          plan(status: .installed) == Plan(install: [], settle: [knock]))
    check("…and so is one that is present but not right",
          plan(status: .broken("Older version installed")) == Plan(install: [], settle: [knock]))

    // AN ENTRY IS NOT A DELIVERY: hooks naming a `tally` that cannot run replace a channel that
    // works with one that silently does nothing.
    check("a machine with no command line tool installs nothing", plan(deliverable: false) == Plan())
    check("…and is NOT recorded as settled, so it follows once that tool goes in",
          plan(deliverable: false).settle.isEmpty && plan(deliverable: true).install == [knock])

    // MARK: a build nobody installed, and a launch showing fixtures

    check("a dev build writes nothing into the config homes", plan(isUnshipped: true) == Plan())
    check("…and spends nothing either, so the installed app still follows",
          plan(isUnshipped: true).settle.isEmpty)
    check("a demo launch changes the machine just as little",
          plan(isDemo: true) == Plan() && plan(isDemo: true).settle.isEmpty)

    // MARK: the whole story, which is the property the record exists for

    // A removal leaves NOTHING behind - the hooks come out of settings.json and the entry out of the
    // manifest - so without the handled list the next launch reads a removed row as a row that was
    // never installed, and installs it. Told as the sequence it actually happens in.
    let installed = plan()
    check("launch one installs it", installed.install == [knock])
    let afterRemoval = IntegrationsStore.autoFollowRecorded(knock, in: [])
    check("…the Remove press records that this row has been answered for",
          afterRemoval == [knock])
    check("…and no later launch ever puts it back",
          plan(handled: afterRemoval) == Plan()
              && plan(status: .installed, handled: afterRemoval) == Plan()
              && plan(status: .broken("Not installed for every account"),
                      handled: afterRemoval) == Plan())
    check("recording is idempotent and never drops what is already there",
          IntegrationsStore.autoFollowRecorded(knock, in: [knock]) == [knock]
              && IntegrationsStore.autoFollowRecorded("other", in: [knock]) == [knock, "other"])

    // MARK: the registry

    // THE SETTINGS.JSON HOOK FAMILY, and the next hook in it is one more line of the list: the
    // Artifact guard is the second, and it followed the same way the quota knock did. The rest of
    // the pane is deliberately absent: those rows write shell profiles, a shared /usr/local/bin, and
    // other people's config homes, none of which a settings.json press authorizes.
    let followable = IntegrationsStore.autoFollowComponents.map(\.component)
    check("exactly the settings.json hook family follows", followable == [knock, artifact])
    check("…found by the key the manifest and the notice both name it with",
          IntegrationsStore.autoFollowComponent(knock)?.component == knock
              && IntegrationsStore.autoFollowComponent(artifact)?.component == artifact
              && IntegrationsStore.autoFollowComponent("claudeSkill") == nil)
    check("…and each is named by the row's own title, so the notice cannot call it something else",
          IntegrationsStore.autoFollowComponent(knock)?.title() == L("Claude quota warning")
              && IntegrationsStore.autoFollowComponent(artifact)?.title()
                  == L("Artifact publishing account"))
    check("…and the two are recorded apart, so answering for one never answers for the other",
          knock != artifact)
    check("the handled list and the notice list are kept apart",
          IntegrationsStore.autoFollowHandledKey != IntegrationsStore.autoFollowNoticeKey)

    // THE GATE THAT CANNOT BE EXERCISED FROM HERE, so it is READ instead, the way the launch-flag
    // suite reads the settings controller it cannot compile. Whether the hooks may be registered
    // asks two things about /usr/local/bin/tally: can it run, and is it OURS. A machine running this
    // suite has Tally installed, so it answers yes to both, and no input this harness can produce
    // separates a build that asks both from one that asks only the first: producing that input means
    // owning a shared path and putting somebody else's program at it. So what is pinned is the
    // wiring, which is exactly what a silent install may not get wrong (a Homebrew `tally` is
    // executable, and hooks naming it would run a stranger's program on every prompt while the
    // supervisor stopped typing the warning down the channel that worked).
    let sourceRoot = URL(fileURLWithPath: #filePath)   // tests/integrations/autofollowchecks.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = (try? String(
        contentsOf: sourceRoot.appendingPathComponent("Tally/Stores/IntegrationsAutoFollow.swift"),
        encoding: .utf8)) ?? ""
    check("the auto-follow source is readable from here at all",
          source.contains("static var autoFollowComponents"))
    check("…and EVERY row's deliverable gate asks both questions, not merely whether something runs",
          source.components(separatedBy:
            "deliverable: { quotaKnockCLIDeliverable() && cliToolIsAppManaged() }").count - 1
              == IntegrationsStore.autoFollowComponents.count)

    // MARK: reading the manifest as a whole

    let manifestFile = tmp.appendingPathComponent("autofollow-manifest.json")
    try JSONSerialization.data(withJSONObject: authorized).write(to: manifestFile)
    check("the manifest is read back whole, not one component at a time",
          IntegrationsStore.settingsWriteAuthorized(
            manifest: IntegrationsStore.manifestDocument(manifestFile), besides: knock))
    check("…and a manifest that is not there answers no rather than throwing",
          IntegrationsStore.manifestDocument(tmp.appendingPathComponent("nope.json")).isEmpty)
    check("…while the per-component reader still answers for one",
          IntegrationsStore.manifestPaths("claudeStatusLine", manifest: manifestFile)
              == ["/Users/x/.claude/settings.json", "/Users/x/.claude2/settings.json"])
}
