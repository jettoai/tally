import Foundation
import Security

// Reading and rewriting the SECRET of a generic-password item, which is a thing Tally does in
// exactly one place: seeding a config home's MCP authorizations from its siblings (MCPAuthSync.swift).
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
// WHY THE READ IS A SUBPROCESS AND THE WRITE IS NOT, which is the shape of this file and the one
// thing worth understanding before changing either half.
//
// A Keychain item's ACL names the programs that may decrypt it, and the program that CREATED an item
// is the one that ends up in that list. Claude Code creates and rewrites its credentials items by
// shelling out to `/usr/bin/security` (`find-generic-password -w`, `add-generic-password -U`,
// `delete-generic-password`, all present in the 2.1.241 binary), so the entry those items carry is
// Apple's own tool and no other. A `SecItemCopyMatching` asking for the data from THIS binary is
// therefore a program the ACL has never heard of, and macOS answers that by putting the consent
// panel on screen and blocking the read until somebody deals with it.
//
// Measured on this machine, 2026-08-23, against a real `Claude Code-credentials-*` item and against
// a throwaway item created the same way Claude Code creates its own:
//
//   * `SecItemCopyMatching` + `kSecReturnData`, dialogs turned off: `errSecAuthFailed` in 8 ms. With
//     dialogs on that is the panel, once per launch, per config home.
//   * The same secret through `/usr/bin/security find-generic-password -w`: exit 0 in 82 ms, 2236
//     bytes, and nothing drawn on screen.
//   * `SecItemUpdate` on an item this binary may not read: status 0 in 16 ms, dialogs off, and the
//     new value read back correctly afterwards. The write was never the problem.
//
// AND THE USER'S "ALWAYS ALLOW" WAS NOT UNDONE BY A NEW ITEM, which is the other candidate and is
// ruled out rather than assumed: every credentials item on this machine has a creation date months
// older than its modification date (2026-04-20 through 2026-08-04 against modification dates of
// today), so Claude Code updates them in place and never deletes and recreates one. What the
// measurement above says is only that this binary is not in those ACLs now; it does not say what
// became of a grant the user gave, and this file does not need to know.
//
// So the read runs as `/usr/bin/security`, which is already in the entry, and the write stays on
// `SecItemUpdate`. The write is NOT moved to the same tool on purpose: `security add-generic-password
// -w <secret>` puts the whole credentials document, the login token in it included, into a command
// line that any local process can read out of `ps`, and there is no stdin form to pass it by instead.

/// Turn this PROCESS's Keychain consent dialogs off (or back on), answering whether it took.
///
/// WHAT THIS STILL COVERS after the read moved to a subprocess, because it is less than it was and a
/// reader who assumes otherwise would be wrong about the thing that matters: the switch is
/// process-global, so it reaches `SecItemUpdate` and the attribute probes made from this binary, and
/// it does NOT reach the `security` child below. That child is bounded by a timeout instead.
///
/// Neither of the calls it now covers has ever been observed to raise a panel (the header measures
/// the write at status 0 with the switch off), so this is a guard against a shape that has not
/// appeared rather than a fix for one that has. It is kept because it costs nothing and because
/// "unattended code may not stop and ask" is worth stating in a mechanism rather than in a comment.
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

/// How long a single secret read may take before it is given up on.
///
/// A BOUND RATHER THAN A SILENCER, because this process's consent switch cannot reach another
/// process. `security` is in the ACL of every item this feature reads (the header says why), so the
/// panel is not expected on any of them; what this covers is the day an item turns up that even
/// Apple's tool is not trusted by, and the answer to that has to be "this home cannot be seeded
/// right now" arriving in bounded time rather than a launch held open behind a panel. Ten seconds is
/// two orders of magnitude above the 82 ms a real read measures, so it can only be reached by
/// something that is not a read at all.
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

/// Replace the secret of an EXISTING item. Never creates one.
///
/// The distinction is the whole safety of the seeding: a config home with no login has no item, and
/// an item holding only the MCP subtree would be a credential document with no login in it - which is
/// not a shape Claude Code ever writes, and not one Tally may invent. `errSecItemNotFound` is
/// therefore the correct outcome for such a home rather than a case to handle.
///
/// STILL THE FRAMEWORK CALL while the read beside it is a subprocess, and the header gives the two
/// measurements that split them: this one has never needed consent, and the tool the read borrows
/// would take the secret through a command line.
func updateKeychainSecret(service: String, account: String, data: Data) -> OSStatus {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    return SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
}
