import Foundation

// THE PARTS OF THIS FEATURE THAT ARE AN ORDER RATHER THAN A VALUE, asserted off the source because
// none of them can be called from a test: one entrance execs, the other needs a Keychain item this
// process is not allowed to create, and what they get wrong is not an answer but a sequence.
//
// The rules in main.swift are worth nothing if nothing calls them, and "nothing calls them" is the
// failure this feature would wear best: every launch would work, no dialog would appear, and the
// authorization would simply keep being asked for. There are two entrances (a plain exec replaces
// this process once, a supervisor spawns a child per relaunch) and the second is the one that
// matters most, because a cap handoff is how a session reaches a home that has never authorized
// anything.
//
// THE ORDERING ASSERTIONS ARE THE POINT OF THE FILE, not a bonus on top of the existence ones: the
// grant seeding reads other programs' Keychain items, which can stop for as long as a person takes
// to answer a consent dialog, and then writes one item back WHOLE. Which reading it writes back is
// the difference between a merge and a rollback of whatever Claude Code did during that wait, and an
// assertion that merely finds the read somewhere in the function is green either way.

func source(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// The body of the first function named `name` in `text`, up to its closing brace at column zero.
func body(of name: String, in text: String) -> String {
    let after = text.components(separatedBy: name).last ?? ""
    return after.components(separatedBy: "\n}").first ?? ""
}

/// Whether `first` appears before `second` in `text`, and both appear at all.
func inOrder(_ first: String, _ second: String, in text: String) -> Bool {
    guard let one = text.range(of: first), let other = text.range(of: second) else { return false }
    return one.upperBound <= other.lowerBound
}

func checkTheWiring() {
    let sync = source("TallyCLI/MCPAuthSync.swift")

    do {
        expect(sync.contains("func launchProvider("), "the harness really read the launch wrapper")
        let wrapper = body(of: "func launchProvider(", in: sync)
        // Whether anybody is watching is asked of THIS PROCESS, not written down as a constant and
        // not passed in by eight call sites. `tally claude -p … | jq` and `tally claude > log` reach
        // this same wrapper (a launch whose stdout is not a terminal is one the supervisor declines),
        // and a dialog on one of those is a command hanging with nobody able to see why.
        expect(wrapper.contains("seedMCPAuthorization(provider: provider, home: home,")
                && wrapper.contains("interactive: isatty(STDOUT_FILENO) == 1)")
                && wrapper.contains("exec(provider.cli"),
               "the wrapper seeds the home it is about to run in, and asks whether stdout is a "
                   + "terminal rather than assuming somebody is there")
        expect(inOrder("seedMCPAuthorization", "exec(provider.cli", in: wrapper),
               "…before the exec, which never returns")
        expect(!sync.contains("interactive: true"),
               "…and no path through this file is hard-coded as interactive")
    }

    do {
        // The unattended half of the same axis: a pass that may not ask anybody anything turns the
        // Keychain's dialogs off BEFORE the first read, and refuses to read at all if that switch
        // will not throw. A switch that silently did nothing would hang an unattended relaunch on a
        // dialog, so its absence has to fail closed rather than fall through.
        expect(sync.contains("if !interactive, !setKeychainInteractionAllowed(false) { return }"),
               "an unattended pass silences the Keychain, and gives up when it cannot")
        expect(inOrder("setKeychainInteractionAllowed(false)", "keychainSecret(", in: sync),
               "…before any secret is asked for, which is the only place it can help")
    }

    do {
        let grants = body(of: "private func seedMCPGrants(", in: sync)
        expect(grants.contains("for sibling in siblings"), "the harness really read the grant seeding")
        // THE READ-MODIFY-WRITE WINDOW. Reading a sibling raises a consent dialog and blocks on it,
        // so a target document read BEFORE that loop is a picture of the item as it was before an
        // unbounded wait - and writing it back would roll back a login refresh, or an authorization
        // Claude Code was granted while the dialogs were on screen. Only "somewhere in the function"
        // is asserted by an existence check; the whole defect lives in which side of the loop it is.
        expect(inOrder("for sibling in siblings",
                       "let targetData = keychainSecret(service: targetService", in: grants),
               "the target's own document is read AFTER the siblings, not before the wait for them")
        expect(inOrder("let targetData = keychainSecret(service: targetService",
                       "seededCredentialData(target: targetData", in: grants),
               "…and that reading is what the merge is computed from")
        // The restore is the half that turns the defect into damage rather than a missed merge, so
        // it has to put back the reading the check compared against and not an older one.
        let restore = grants.components(separatedBy: "credentialBlobIsIntactApartFromGrants").last ?? ""
        expect(restore.contains(
                "updateKeychainSecret(service: targetService, account: account, data: targetData)"),
               "…and what a failed verification puts back, which is the same document it checked")
        expect(grants.components(separatedBy: "keychainSecret(service: targetService, account: account)")
                .count - 1 == 2,
               "the target's secret is read exactly twice: once as the base, once to check the write")
        // THE FRESHNESS GATE, which is an order too and nothing but: the rule it applies is asserted
        // by value in main.swift, and it saves exactly nothing unless it is consulted BEFORE the
        // secret reads it exists to avoid. A gate that ran after them would be green on every rule
        // and cost every dialog.
        expect(inOrder("KeychainReader.modifiedAt(service: service",
                       "keychainSecret(service: service", in: grants),
               "a sibling is probed by attributes, which raise no dialog, before its secret is asked")
        expect(grants.contains(
                "let stale = mcpSeedSourcesToRead(probed: probes, record: loadMCPSeedRecord(for: home))"),
               "what the probes found is put to the gate, against this home's own record")
        expect(inOrder("mcpSeedSourcesToRead(probed: probes", "keychainSecret(", in: grants),
               "…before any secret is read, which is the only place it can save one")
        expect(grants.contains("guard !stale.isEmpty else { return }")
                && inOrder("guard !stale.isEmpty else { return }", "keychainSecret(", in: grants),
               "…and a launch where nothing moved returns without reading a single one")
        expect(inOrder("keychainSecret(service: service, account: account)",
                       "observed[probe.home] = modifiedAt", in: grants),
               "a sibling is recorded only after its secret actually came back")
        // The record may only move where the pass CONCLUDED: nothing to adopt, or a write that
        // verified. A pass that gave up, or one whose write was rolled back, has to be tried again.
        expect(grants.components(separatedBy: "recordMCPSeed(observed, for: home)").count - 1 == 2,
               "the record is written on exactly the two paths that reached a conclusion")
        let afterRestore = grants.components(separatedBy: "data: targetData)").last ?? ""
        expect(!afterRestore.contains("recordMCPSeed"),
               "…and never on the one that put the target's own document back")
        // Both faces refuse a home whose item name would be a guess rather than a rule.
        expect(grants.contains("claudeSeedingKeychainService(forConfigDir: URL(fileURLWithPath: home)"),
               "the target is addressed through the guarded name, not the bare shortcut")
        expect(!grants.contains("claudeKeychainService("),
               "…and the unguarded one is not reachable from the seeding at all")
    }

    do {
        // The record lives in the app's own document (`~/.tally/state.json`), which has another
        // writer. So it is patched onto the file AS IT IS at the moment of writing rather than onto
        // the copy the gate read minutes earlier, and it is replaced in one step: a rewrite of the
        // stale copy would put a pinned account back to what it was before the user changed it.
        let recorder = body(of: "private func recordMCPSeed(", in: sync)
        expect(recorder.contains("stateDocumentSettingMCPSeedRecord"),
               "the harness really read the recorder")
        expect(inOrder("Data(contentsOf: stateURL)", "stateDocumentSettingMCPSeedRecord",
                       in: recorder),
               "the record is patched onto the state file as it is NOW, not onto an older reading")
        expect(recorder.contains("options: .atomic"),
               "…and the file it shares with the app is replaced in one step")
        expect(!recorder.contains("createDirectory") && !recorder.contains("StateFile("),
               "…and a document the app has never published is left absent rather than invented")
    }

    do {
        // The app end of the same key: that store writes the whole document from one struct, so a
        // key missing from it is a key deleted at the next settings change.
        let store = source("Tally/Stores/LaunchPolicyStore.swift")
        expect(store.contains("var mcpSeed: [String: [String: Double]]?"),
               "the app's state document declares the CLI's seeding record, so its writes keep it")
        expect(store.contains("mcpSeed: seedRecord"),
               "…and hands it back on every persist")
        expect(inOrder("Data(contentsOf: Self.fileURL)", "mcpSeed: seedRecord",
                       in: body(of: "private func persist(", in: store)),
               "…read off the disk at that moment rather than from a copy taken at app start")
    }

    do {
        let registrations = body(of: "private func seedMCPRegistrations(", in: sync)
        expect(registrations.contains("claudeSeedingStateFile(forConfigDir: URL(fileURLWithPath: home)"),
               "the state file is addressed through the guarded name too")
        expect(!registrations.contains("claudeStateFile("),
               "…and the unguarded one is not reachable from the seeding either")
    }

    do {
        // A state file holds the env and headers of every registered MCP server, which is where API
        // keys are kept. `Data.write` creates at 0644 under the usual umask, so a copy of a 0600 file
        // made that way is a permanent downgrade sitting beside it (the backup is never cleaned up).
        let writer = body(of: "private func writeSeededState(", in: sync)
        expect(writer.contains("mcpSeedBackupSuffix"), "the harness really read the state writer")
        expect(writer.contains("attributes?[.posixPermissions] as? NSNumber ?? NSNumber(value: 0o600)"),
               "the mode the copies are given is the original's, or 0600 when it will not say")
        expect(writer.components(separatedBy: "writeCopy(").count - 1 == 2,
               "both the backup and the temporary are written with the original file's own mode")
        expect(!writer.contains(".write(to: backup") && !writer.contains(".write(to: temporary"),
               "…and neither of them is written at whatever mode the umask happens to give")
        expect(sync.contains("try? FileManager.default.removeItem(at: file)"),
               "a copy whose mode could not be set is removed rather than left lying there")
    }

    do {
        let supervisor = source("TallyCLI/Supervisor.swift")
        expect(supervisor.contains("spawnChild("), "the harness really read the supervisor")
        expect(supervisor.contains("seedMCPAuthorization(provider: provider, home: seedHome,"),
               "the supervised launch seeds too")
        expect(inOrder("seedMCPAuthorization", "guard let childPID = spawnChild(", in: supervisor),
               "…before the child is spawned")
        // Inside the relaunch loop rather than above it: an account can change between two passes,
        // and that pass is the whole reason this feature exists.
        let loop = supervisor.components(separatedBy: "while true {").last ?? ""
        expect(loop.contains("seedMCPAuthorization"),
               "…and inside the loop, so a cap handoff seeds the account it hands off TO")
        // …which is exactly why it may not be interactive on every pass. The flag is read off the
        // supervisor's own relaunch state rather than written down as a constant: the first pass runs
        // in the same second as the command somebody typed, and every pass after it is this process
        // acting on its own, possibly at three in the morning.
        expect(supervisor.contains("interactive: !relaunching"),
               "the supervised seeding may only ask the user on its FIRST pass")
        expect(!supervisor.contains("interactive: true"),
               "…so no pass of it is hard-coded as interactive")
    }

    do {
        let resume = source("TallyCLI/ResumeCommand.swift")
        expect(resume.contains("launchProvider(provider"), "the harness really read resume")
        expect(!resume.contains("exec(provider.cli"),
               "resume launches through the wrapper as well, rather than round it")
    }
}
