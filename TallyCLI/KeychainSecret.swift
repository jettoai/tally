import Foundation
import Security

// Reading and rewriting the SECRET of a generic-password item, which is a thing Tally does in
// exactly two places: seeding a config home's MCP authorizations from its siblings
// (MCPAuthSync.swift), and healing an item whose ACL an earlier version of this binary damaged
// (KeychainPartitionRepair.swift).
//
// Everything else about the Keychain in this repo is an attribute probe that returns no secret and
// raises no consent prompt (KeychainReader.swift, and it says so). This file is the exception, and it
// is deliberately narrow: two calls, no logging of anything they return, and the value never leaves
// the process it was read in.
//
// FAILURE IS A VALUE HERE, not an error to report. Every caller of these is fail-open by design: a
// missing item, a locked keychain, an ACL the user declined, a keychain that is not there at all -
// all of them mean "this home cannot be seeded right now", which leaves Claude Code to ask for the
// authorization the way it does today. So the status comes back for the caller to branch on and
// nothing here prints.
//
// BOTH DIRECTIONS RUN AS `/usr/bin/security`, AND THE WRITE ONLY JOINED THE READ AFTER IT HAD
// SHIPPED DAMAGE. This is the shape of the file and the one thing worth understanding before
// changing either half.
//
// A Keychain item's ACL has two halves that matter here. The DECRYPT entry names the programs that
// may read the secret without a prompt, and the program that CREATED an item is the one that ends
// up in it. Beside it sits an entry the ACL editors call the PARTITION LIST
// (`ACLAuthorizationPartitionID`), whose description is a hex-encoded plist naming the code-signing
// identities allowed to use the item at all. Claude Code creates and rewrites its credentials items
// by shelling out to `/usr/bin/security` (`find-generic-password -w`, `add-generic-password -U`,
// `delete-generic-password`, all present in the 2.1.241 binary), so both halves name Apple's tool
// and no other: `/usr/bin/security` in the decrypt entry, `apple-tool:` in the partition list.
//
// Measured on this machine, 2026-08-23, against a real `Claude Code-credentials-*` item and against
// throwaway items created the same way Claude Code creates its own:
//
//   * `SecItemCopyMatching` + `kSecReturnData` from a binary the decrypt entry does not name:
//     `errSecAuthFailed` in 8 ms with dialogs turned off. With dialogs on that is the panel, once
//     per launch, per config home.
//   * The same secret through `/usr/bin/security find-generic-password -w`: exit 0 in 82 ms, 2236
//     bytes, and nothing drawn on screen.
//   * `SecItemUpdate` from any process that is not `security`: status 0 in 16 ms with dialogs off,
//     no ACL check, and the new value reads back correctly. THE WRITE WAS THE PROBLEM ALL ALONG,
//     and this line is the correction of what this header used to claim: macOS silently rewrites
//     the PARTITION LIST to the writing process's own partition (`teamid:87Z993GX39` for this
//     Developer ID signed helper, `cdhash:<hash>` for an ad-hoc build). `apple-tool:` is gone
//     afterwards, so `/usr/bin/security -w` stops on a consent panel titled "security" for every
//     later reader - Claude Code itself, the read below, and the app's usage polling, which runs
//     the `claude` CLI. The DECRYPT entry is left alone by that write, which is why the damage is
//     invisible from the writer and visible from everywhere else - but it is not a licence either:
//     the write needs no decrypt right, so damaging an item does not put the writer into its ACL
//     (measured against an item Tally was never trusted with). KeychainPartitionRepair.swift says
//     what that costs the repair.
//
// Two of the owner's seven items were left in exactly that state by Tally 0.64.0, and undoing it is
// what KeychainPartitionRepair.swift is for.
//
// So both halves run as `/usr/bin/security`, the program the items' ACLs already name, and neither
// may go back to the framework call beside it. What that costs is stated rather than hidden: the
// write carries the whole credentials document, the login token in it included, through a command
// line, where any local process can read it out of `ps`. That is the status quo rather than a new
// exposure - Claude Code writes its own items the same way, and its binary carries the string
// "exceeds security -i stdin limit; using argv" for the documents too big for the alternative. The
// alternatives were measured before they were rejected: `set-generic-password-partition-list` asks
// for the login password, `-w` fed through the tool's stdin prompt truncates at 128 bytes, and
// `security -i` line-buffers at about 4 KB, which a 2.2 KB credential in hex exceeds.

/// Turn this PROCESS's Keychain consent dialogs off (or back on), answering whether it took.
///
/// WHAT THIS COVERS, because it is less than the whole of this file and a reader who assumes
/// otherwise would be wrong about the thing that matters: the switch is process-global, so it
/// reaches the framework calls made from this binary - the attribute probes, and the one data read
/// there is (the repair's, KeychainPartitionRepair.swift) - and it does NOT reach either `security`
/// child below. Those are bounded by a timeout instead.
///
/// LOOKED UP AT RUNTIME rather than called directly, for two reasons and not for cleverness. The
/// first is that `SecKeychainSetUserInteractionAllowed` is the only thing that does this for a
/// file-based item and the SDK has had it deprecated since macOS 10.10, so a direct call costs a
/// build warning in a repo that commits at zero. (The documented replacement does NOT cover this
/// case: `kSecUseAuthenticationUI = fail` was measured against the same item and ignored - the read
/// blocked on the dialog anyway.) The second is worth more: this way "the mechanism is not there any
/// more" becomes an observable false instead of a silent no-op, and the caller can refuse to go on
/// at all - which is the direction a missing safety switch has to fail in.
func setKeychainInteractionAllowed(_ allowed: Bool) -> Bool {
    typealias SetUserInteractionAllowed = @convention(c) (DarwinBoolean) -> OSStatus
    // RTLD_DEFAULT: search every image already loaded into this process, which Security.framework is.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                             "SecKeychainSetUserInteractionAllowed") else { return false }
    return unsafeBitCast(symbol, to: SetUserInteractionAllowed.self)(DarwinBoolean(allowed))
        == errSecSuccess
}

/// How long a single `security` child may take before it is given up on.
///
/// A BOUND RATHER THAN A SILENCER, because this process's consent switch cannot reach another
/// process. `security` is in the decrypt entry of every item this binary touches (the header says
/// why), so the panel is not expected on any of them; what this covers is the day an item turns up
/// that even Apple's tool is not trusted by, and the answer to that has to be "this home cannot be
/// seeded right now" arriving in bounded time rather than a launch held open behind a panel. Ten
/// seconds is two orders of magnitude above the 82 ms a real read measures, so it can only be
/// reached by something that is not a read at all.
private let keychainSecretTimeout: TimeInterval = 10

/// The secret bytes of a generic-password item, or nil.
///
/// Nil for every reason there is, deliberately: no such item, a locked keychain, a consent dialog the
/// user declined, a read that ran out of time. They are different facts, but not to any caller of
/// this - all of them mean "this home cannot be seeded now", and the seeding does the same thing
/// about each.
///
/// THE SECRET NEVER LEAVES THIS FUNCTION'S RETURN VALUE. It is read off a pipe into memory, the
/// child's stderr goes to /dev/null, and no argument this process passes carries it (the service and
/// the account name are not secrets, and they are handed over as argv rather than through a shell,
/// so a service name with a quote or a space in it is a string and not a syntax).
///
/// WHAT `-w` PRINTS, and it is TWO formats rather than one, which is the only part of borrowing
/// this tool that costs anything. The secret is printed literally, followed by exactly one newline,
/// WHEN EVERY BYTE OF IT IS PRINTABLE ASCII. A secret with any other byte in it is printed as
/// lowercase HEX instead, also followed by one newline (measured 2026-08-23 by storing single bytes:
/// 0x20 through 0x7e print literally, 0x1f, 0x7f and 0x80 each turn the whole reading into hex).
///
/// So the hex is decoded back here rather than let through, and the alternative was measured before
/// it was rejected: the documents this reads are JSON written by Claude Code, and today's are pure
/// ASCII, but ONE non-ASCII character anywhere in one - an MCP server named in Chinese, an email
/// with an accent - would turn a whole config home's seeding into a reading that quietly fails to
/// parse. A feature that stops working and says nothing is worse than the shape it was avoiding.
///
/// THE ONE SHAPE THIS CANNOT TELL APART, stated rather than left to be discovered: a secret that is
/// itself an even-length lowercase hex string AND decodes to bytes that are not all printable is
/// indistinguishable from the printed form of those bytes, and comes back decoded. The rule below is
/// the exact inverse of the tool's own, so nothing else is ambiguous - and the only caller's
/// documents begin with `{`, which is not a hex digit.
func keychainSecret(service: String, account: String) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }

    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + keychainSecretTimeout, execute: watchdog)
    // Drained BEFORE the wait, which is the order a pipe requires: a child filling more than the
    // buffer holds would block on its own write while its parent waited for it to exit.
    let printed = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()

    // A signalled exit is not a reading, and it is the shape the timeout above arrives in: the pipe
    // closes when the child is killed, so the read above returns whatever had been printed by then
    // and only this line tells that from a completed one.
    guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
    let text = printed.last == 0x0a ? Data(printed.dropLast()) : printed
    return securityToolHexDecoded(text) ?? text
}

/// The bytes `text` is the hex printing of, or nil if it is not one.
///
/// THE EXACT INVERSE of what `security -w` does, which is what keeps it from firing on a secret that
/// was printed literally: the tool prints hex only when a byte is outside 0x20...0x7e, so a hex
/// string whose bytes are ALL inside that range is one the tool would never have produced, and is
/// therefore a secret that happens to look like hex rather than a printing of anything.
private func securityToolHexDecoded(_ text: Data) -> Data? {
    func value(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
    let digits = Array(text)
    guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
    var decoded = Data(capacity: digits.count / 2)
    for pair in stride(from: 0, to: digits.count, by: 2) {
        guard let high = value(digits[pair]), let low = value(digits[pair + 1]) else { return nil }
        decoded.append(high << 4 | low)
    }
    return decoded.contains { $0 < 0x20 || $0 > 0x7e } ? decoded : nil
}

/// Store `data` as the secret of `service`/`account` BY RUNNING `/usr/bin/security`, answering
/// whether the tool said it worked. THE ONE WRITE PATH IN THIS REPO; both callers share it
/// (`updateKeychainSecret` below, and the repair's rewrite) because what makes it safe is a property
/// of the program doing the writing, and a second spelling of it is how one caller quietly goes back
/// to damaging the item.
///
/// `-U` UPDATES AN EXISTING ITEM AND CREATES A MISSING ONE, which is the whole of what this function
/// cannot decide for itself: the tool has no update-only mode. Whether a missing item is allowed to
/// come into existence therefore belongs to the caller, and `updateKeychainSecret` below is the one
/// that says no.
///
/// `-X` RATHER THAN `-w`, because the payload is BYTES: `-w` takes a C string, so a document with a
/// NUL in it would be truncated and a byte-exact round trip could not be promised. The hex form has
/// no such shape, and the read above already decodes what the tool prints back in the same form.
///
/// THE SECRET IS IN THE COMMAND LINE, said plainly rather than left in the header: for as long as
/// this child runs, `ps` shows the whole document in hex to any process on this machine. The header
/// weighs that against the alternatives (all of which were measured) and against Claude Code's own
/// behaviour, which is the same one.
func writeKeychainSecretAsSecurityTool(service: String, account: String, data: Data) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["add-generic-password", "-a", account, "-s", service, "-U",
                         "-X", data.map { String(format: "%02x", $0) }.joined()]
    // Nothing this child says is read: the tool prints its own diagnostics on stderr and nothing at
    // all on success, and a caller that logged either would be logging an argument list.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + keychainSecretTimeout, execute: watchdog)
    process.waitUntilExit()
    watchdog.cancel()
    // A signalled exit is not a write, for the reason the read above gives.
    return process.terminationReason == .exit && process.terminationStatus == 0
}

/// Replace the secret of an EXISTING item. Never creates one.
///
/// The distinction is the whole safety of the seeding: a config home with no login has no item, and
/// an item holding only the MCP subtree would be a credential document with no login in it - which is
/// not a shape Claude Code ever writes, and not one Tally may invent. `errSecItemNotFound` is
/// therefore the correct outcome for such a home rather than a case to handle.
///
/// AND IT IS NOW BOUGHT WITH A PROBE RATHER THAN WITH THE CALL'S OWN SEMANTICS, which is what moving
/// off `SecItemUpdate` cost: that call refuses a missing item by construction, and `security
/// add-generic-password -U` creates one. So existence is asked first, by attributes only, which
/// raises no prompt and reads no secret (KeychainReader.swift). What that leaves is a window of a
/// few milliseconds in which an item deleted between the probe and the write would be recreated -
/// smaller than, and inside, the read-to-write window MCPAuthSync.swift already describes as the
/// only thing here that can destroy something, and bounded by the same fact: nothing on this machine
/// deletes those items except a person signing out.
///
/// The OSStatus shape is kept because the caller branches on `errSecSuccess` and on nothing else. A
/// tool that exited non-zero has no status of its own, so it is reported as `errSecIO`: a write that
/// did not happen, which is exactly how the caller treats it.
func updateKeychainSecret(service: String, account: String, data: Data) -> OSStatus {
    guard KeychainReader.exists(service: service, account: account) else { return errSecItemNotFound }
    return writeKeychainSecretAsSecurityTool(service: service, account: account, data: data)
        ? errSecSuccess : errSecIO
}
