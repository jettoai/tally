import Foundation
import Security

// THE DAMAGE TALLY 0.64.0 DID AND THE UNDOING OF IT (TallyCLI/KeychainPartitionRepair.swift),
// asserted against a real Keychain item this suite creates, damages, heals and removes.
//
// WHY A REAL ITEM AND NOT A FIXTURE, for the reason secret.swift gives one degree further: what is
// being tested is not a value this process computes but what MACOS DOES TO AN ACL when a program
// that is not `/usr/bin/security` writes an item's data. No fixture can state that, it is not
// documented anywhere, and it is the entire mechanism of the incident.
//
// THE ITEM IS THIS SUITE'S OWN: named after its process, holding an obviously fake value, trusted to
// this test binary and to `security` the way a real Claude Code item is trusted to `security`, and
// removed on the way out. It is NOT a `Claude Code-*` item.
//
// AND NOTHING HERE CALLS THE SWEEP. `repairClaudeKeychainPartitions` addresses the machine's REAL
// `Claude Code-credentials*` items, so running it from a test would rewrite the credentials of
// whoever is running the suite. Its filter - which items it will and will not look at - is therefore
// asserted off the source, the way wiring.swift asserts the things it cannot call; the per-item
// engine underneath it is asserted for real, below.
//
// EVERY `security` CHILD IN HERE IS BOUNDED. A consent panel is the failure this whole file is
// about, and a suite that waited for one would hang instead of failing. The product's own read has a
// watchdog of its own (KeychainSecret.swift), and the calls this file makes directly have the one
// below, so a panel costs seconds and a red line rather than an afternoon.

private let repairService = "tally-mcpauthsync-repair-\(getpid())"
private let repairAccount = "tally-test"

/// Run `security` with the given arguments, answering its exit status and whether it had to be
/// killed. Nothing it prints is kept.
@discardableResult
private func boundedSecurity(_ arguments: [String], timeout: TimeInterval = 10)
    -> (status: Int32, timedOut: Bool) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return (-1, false) }
    var timedOut = false
    let watchdog = DispatchWorkItem {
        if process.isRunning { timedOut = true; process.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    process.waitUntilExit()
    watchdog.cancel()
    return (process.terminationStatus, timedOut)
}

/// Create the suite's item the way Claude Code creates its own - through `security`, so the
/// partition list starts as `apple-tool:` - and trusted to this test binary as well.
///
/// THE `-T` IS A FIXTURE CHOICE AND NOT A LAW ABOUT DAMAGED ITEMS. Damaging an item does not put the
/// writer in its decrypt entry (the write needs no decrypt right, measured); Tally is in the two
/// real damaged items' entries only because the owner once answered a v0.63 panel with "Always
/// Allow". What the `-T` buys here is that the repair's read can be asserted WITHOUT a consent panel
/// in the suite, so this fixture is the already-allowed machine. The other machine - damaged, not
/// trusted - is the one where the repair costs one panel per item, and a suite cannot answer a panel
/// any more than it can raise one on purpose.
private func createRepairItem(value: String) -> Bool {
    boundedSecurity(["add-generic-password", "-U", "-a", repairAccount, "-s", repairService,
                     "-w", value, "-T", CommandLine.arguments[0], "-T", "/usr/bin/security"])
        .status == 0
}

private func removeRepairItem() {
    boundedSecurity(["delete-generic-password", "-a", repairAccount, "-s", repairService])
}

/// Write an item's data the way Tally 0.64.0 did: the framework call, from a process that is not
/// `security`. This is the damage.
@discardableResult
private func damageRepairItem(_ value: Data) -> OSStatus {
    _ = setKeychainInteractionAllowed(false)
    return SecItemUpdate([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: repairService,
        kSecAttrAccount as String: repairAccount,
    ] as CFDictionary, [kSecValueData as String: value] as CFDictionary)
}

func checkTheKeychainRepair() {
    let repair = source("TallyCLI/KeychainPartitionRepair.swift")
    let sync = source("TallyCLI/MCPAuthSync.swift")
    let supervisor = source("TallyCLI/Supervisor.swift")

    do {
        // THE SWEEP'S MOTHER SET, asserted off the source because calling it would rewrite the real
        // credentials of whoever runs this. Two conditions and no third: the service is in Claude
        // Code's own family, taken from the constant that derives those names rather than spelled
        // again here, and the account is this login user's. Everything else on the machine -
        // somebody's mail password, another user's item - is out of the query's reach by
        // construction rather than by care.
        let sweep = body(of: "func repairClaudeKeychainPartitions(", in: repair)
        expect(sweep.contains("isClaudeCredentialsService(service)")
                && !sweep.contains("hasPrefix(claudeBaseKeychainService)"),
               "the sweep asks whether a name is one the generator could have PRODUCED, not whether "
                   + "it starts with the same words: what it does to an item it accepts is read and "
                   + "rewrite the secret")
        expect(sweep.contains("attributes[kSecAttrAccount as String] as? String == account")
                && sweep.contains("let account = NSUserName()"),
               "…and only at this login user's, which is the account attribute Claude Code writes")
        expect(sweep.contains("kSecMatchLimit as String: kSecMatchLimitAll")
                && sweep.contains("kSecReturnAttributes as String: true")
                && !sweep.contains("kSecReturnData"),
               "the enumeration asks for attributes and never for data, so listing the machine's "
                   + "items reads no secret and can raise no panel")
    }

    do {
        // A SCAN THAT COULD NOT RUN IS NOT AN EMPTY SCAN. A locked keychain used to arrive as `[]`,
        // which the verb reported as a clean machine with a zero exit - the one answer that is worse
        // than no answer, because it tells somebody whose items ARE damaged that they are fine
        // (codex review, 2026-08-23). Asserted off the source: a locked keychain is not a state a
        // suite can put this machine into.
        let sweep = body(of: "func repairClaudeKeychainPartitions(", in: repair)
        expect(sweep.contains("if status == errSecItemNotFound { return .scanned([]) }"),
               "a machine with no generic-password items at all is an empty scan and not a failure, "
                   + "which is what `errSecItemNotFound` from the enumeration means")
        expect(sweep.contains("return .scanFailed(status)")
                && !sweep.contains("else { return [] }"),
               "…while every other way the enumeration can fail carries its status out, rather than "
                   + "being flattened into the same silence a clean machine gives")
        let verb = body(of: "func runKeychainRepair(", in: repair)
        expect(verb.contains("case let .scanFailed(status):")
                && verb.contains("print(\"keychain scan failed (status \\(status))\")"),
               "the verb says so on one line…")
        expect(inOrder("case let .scanFailed(status):", "return 1", in: verb),
               "…and exits non-zero, because the question it was asked went unanswered")
        // The launch path is the one place that answer is right to swallow: fail-open, like
        // everything else the launcher does with the Keychain.
        let healer = body(of: "func repairClaudeKeychain(", in: sync)
        expect(healer.contains("guard case let .scanned(results) = repairClaudeKeychainPartitions("),
               "a launch treats a failed scan as nothing repaired and says nothing, because a "
                   + "locked keychain is not a reason to hold up `claude`")
    }

    do {
        // THE NAME TEST ITSELF, which is a real function with no Keychain behind it, so it is asked
        // rather than read. Every row is a name that either IS or IS NOT one
        // `claudeKeychainService(forConfigDir:)` could have printed.
        expect(isClaudeCredentialsService(claudeBaseKeychainService),
               "the bare stem is `~/.claude`'s own item")
        expect(isClaudeCredentialsService(claudeBaseKeychainService + "-deadbeef"),
               "…and the stem with eight lowercase hex digits is every other config home")
        expect(isClaudeCredentialsService(
                claudeKeychainService(forConfigDir: URL(fileURLWithPath: "/Users/someone/.claude3"))),
               "…which is asserted against what the generator actually prints, not against a "
                   + "hand-written example of it")
        // The four refusals, and the first is the one that made this a defect: an item somebody
        // called `-backup` is theirs, and accepting it means reading and rewriting their secret.
        for refused in ["-backup", "-deadbee", "-DEADBEEF", "-deadbeef0"] {
            expect(!isClaudeCredentialsService(claudeBaseKeychainService + refused),
                   "`\(claudeBaseKeychainService)\(refused)` is not a name that generator prints")
        }
    }

    do {
        // THE APP'S FIRST USAGE READING WAITS FOR THE REPAIR. A refresh runs the `claude` CLI, which
        // reads its credentials through `security`, so a poll started before the rewrite raises the
        // very panel the repair removes and races the write besides (codex review, 2026-08-23).
        // Asserted off the source because no harness compiles the app's delegate.
        let delegate = source("Tally/App/AppDelegate.swift")
        expect(delegate.contains("func applicationDidFinishLaunching"),
               "the harness really read the app delegate")
        expect(delegate.contains("await KeychainRepairLaunch.run()"),
               "the repair is awaited rather than left to run beside everything else")
        // ADJACENCY RATHER THAN ORDER, because "after it" is not the property: a start in a task of
        // its own is after this line and races it anyway. The two statements have to be the two
        // statements of one task, which is what a search for them back to back says.
        expect(delegate.contains("await KeychainRepairLaunch.run()\n            UsageStore.shared.start()"),
               "…and the usage store is started by the next statement of that same task, so the "
                   + "reading cannot begin until the rewrite has finished or timed out")
        // ONCE, so that a second start somewhere above cannot quietly restore the race the ordering
        // above was added to close.
        expect(delegate.components(separatedBy: "UsageStore.shared.start()").count == 2,
               "and the store is started in exactly one place")
        expect(!delegate.contains("KeychainRepairLaunch.runAtStartup()"),
               "the fire-and-forget form is gone rather than left beside the awaited one")
    }

    do {
        // The verb is a command somebody typed, so it is the one surface allowed to stop and ask.
        let verb = body(of: "func runKeychainRepair(", in: repair)
        expect(verb.contains("repairClaudeKeychainPartitions(interactive: true)"),
               "`tally keychain-repair` runs interactively, because a person is at the keyboard")
        expect(!repair.contains("print(keychainSecret") && !repair.contains("print(data"),
               "…and no path in this file prints a value")
    }

    do {
        // IN FRONT OF THE LAUNCH, AND IN FRONT OF THE SEEDING. The next thing to happen on either
        // path is a `claude` reading its own credentials through `/usr/bin/security`, which is
        // exactly what a damaged item stops. A repair that ran after the exec would never run at
        // all, and one that ran after the seeding would let the seeding's own reads meet the panel
        // first.
        let wrapper = body(of: "func launchProvider(", in: sync)
        expect(wrapper.contains("repairClaudeKeychain(provider: provider,"),
               "the plain exec heals before it launches")
        expect(inOrder("repairClaudeKeychain", "seedMCPAuthorization", in: wrapper)
                && inOrder("repairClaudeKeychain", "exec(provider.cli", in: wrapper),
               "…before the seeding and before the exec, which never returns")
        expect(supervisor.contains("repairClaudeKeychain(provider: provider, interactive: !relaunching)"),
               "and so does the supervised launch, on the same axis the seeding beside it runs on")
        expect(inOrder("repairClaudeKeychain", "guard let childPID = spawnChild(", in: supervisor),
               "…before the child it is protecting is spawned")
        // NOT BEHIND THE SEEDING'S OPT-IN: that flag is off because the seeding is the face under
        // investigation, and the damage it already did has to come off the machine either way.
        let healer = body(of: "func repairClaudeKeychain(", in: sync)
        expect(!healer.contains("TALLY_MCP_GRANT_SEEDING"),
               "the repair is not gated on the seeding's opt-in, which is off")
    }

    // THE BEHAVIOURAL HALF. A failure to create the item is a FAILURE and not a skip, for the reason
    // secret.swift gives: a locked keychain would otherwise turn every assertion below into a silent
    // pass.
    removeRepairItem()
    defer { removeRepairItem() }
    expect(createRepairItem(value: "not-a-real-secret-v1"),
           "the suite can create a generic-password item through `security`")

    do {
        // WHAT AN UNDAMAGED ITEM LOOKS LIKE, which is the baseline every row below is read against:
        // an item `security` created carries exactly one partition, Apple's own tool.
        expect(keychainPartitions(service: repairService, account: repairAccount)
                == [appleToolPartition],
               "an item created through `security` carries `apple-tool:` and nothing else")
        expect(!keychainPartitionsAreDamaged(service: repairService, account: repairAccount),
               "…so the detector calls it healthy")
    }

    // A value with the awkward parts of a real credentials document in it: bigger than the tool's
    // stdin buffer, not ASCII, and ending in a newline of its own.
    let credential = Data(("{\"claudeAiOauth\":{\"accessToken\":\"" + String(repeating: "x", count: 2900)
        + "\",\"name\":\"caf\u{e9}\u{4e2d}\u{6587}\"}}\n").utf8)

    do {
        // THE DAMAGE, REPRODUCED. This is the whole of what Tally 0.64.0 did: one framework write,
        // status 0, no dialog, the value readable afterwards from this process - and the partition
        // list silently replaced by the writer's own, which is what locked `security` out.
        expect(damageRepairItem(credential) == errSecSuccess,
               "a `SecItemUpdate` from a process that is not `security` is allowed, with no dialog "
                   + "and no ACL check")
        let after = keychainPartitions(service: repairService, account: repairAccount)
        expect(after != nil && after?.contains(appleToolPartition) == false,
               "…and it takes `apple-tool:` out of the partition list, which is the whole incident")
        expect(keychainPartitionsAreDamaged(service: repairService, account: repairAccount),
               "…which the detector reports as damage, whatever the writer's own partition is called")
    }

    do {
        // THE REPAIR. Not read back through `security -w` before this line: that is the call the
        // damage makes stop on a panel, so asking it here would be asking for the hang.
        expect(repairKeychainPartitions(service: repairService, account: repairAccount,
                                        interactive: false) == .repaired,
               "the repair reads the value under Tally's own trust and stores it again through the "
                   + "tool that owns the partition")
        expect(keychainPartitions(service: repairService, account: repairAccount)
                == [appleToolPartition],
               "…which puts `apple-tool:` back")
        expect(keychainSecret(service: repairService, account: repairAccount) == credential,
               "…and the value survives it byte for byte, read back through the very call that was "
                   + "locked out, non-ASCII and trailing newline included")
        expect(repairKeychainPartitions(service: repairService, account: repairAccount,
                                        interactive: false) == .healthy,
               "a second pass over a healed item reads no value and writes nothing")
    }

    do {
        // THE ASSERTION THAT WOULD HAVE CAUGHT v0.64.0. The seeding's write is the thing that did
        // the damage, so what is asked of it is not that it works but that it leaves the ACL alone.
        removeRepairItem()
        expect(createRepairItem(value: "not-a-real-secret-v2"), "the suite can recreate its item")
        expect(updateKeychainSecret(service: repairService, account: repairAccount,
                                    data: credential) == errSecSuccess,
               "the seeding's write path stores a document")
        expect(keychainPartitions(service: repairService, account: repairAccount)
                == [appleToolPartition],
               "…and leaves the partition list exactly as `security` wrote it, which is the one "
                   + "thing `SecItemUpdate` could not do")
        expect(keychainSecret(service: repairService, account: repairAccount) == credential,
               "…having actually written what it was given")
    }

    do {
        // NEVER CREATES ONE, which is the safety the seeding rests on and the property that moving
        // off `SecItemUpdate` had to be bought back: `security add-generic-password -U` would have
        // made an item for a config home that has no login, holding grants and no credential.
        removeRepairItem()
        expect(updateKeychainSecret(service: repairService, account: repairAccount,
                                    data: credential) == errSecItemNotFound,
               "a home with no item is refused rather than given one")
        expect(keychainPartitions(service: repairService, account: repairAccount) == nil,
               "…and nothing was created")
        expect(repairKeychainPartitions(service: repairService, account: repairAccount,
                                        interactive: false) == .unreadable(errSecItemNotFound),
               "and an item that is not there is reported as unreadable rather than repaired")
    }
}
