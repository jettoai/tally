import Foundation
import Security

// UNDOING THE DAMAGE TALLY 0.64.0 DID TO CLAUDE CODE'S KEYCHAIN ITEMS, and the detector that says
// which items are in that state.
//
// WHAT WENT WRONG, measured on this machine on 2026-08-23 against throwaway items created the way
// Claude Code creates its own (KeychainSecret.swift's header carries the same measurements from the
// write side). A generic-password item's ACL carries an entry the ACL editors call the PARTITION
// LIST - `kSecACLAuthorizationPartitionID`, whose "description" is a hex-encoded plist of the form
// `{Partitions = ("apple-tool:")}`. It names the code-signing identities macOS will let use the item
// without stopping to ask. Claude Code writes its credentials items by shelling out to
// `/usr/bin/security`, so the partition list on every one of them is `apple-tool:` and nothing else.
//
// `SecItemUpdate(kSecValueData)` from any process that is NOT `security` returns status 0 with user
// interaction disabled: no dialog, no ACL check, and the new value reads back correctly. What it
// also does, silently, is REWRITE THAT PARTITION LIST to the writing process's own partition -
// `teamid:87Z993GX39` for Tally's Developer ID signed helper. `apple-tool:` is gone afterwards, and
// from that moment `/usr/bin/security find-generic-password -w` stops on a consent panel titled
// "security" for every reader that borrows the tool: Claude Code itself, `tally claude`'s seeding,
// and the app's usage polling, which runs the `claude` CLI. That is the whole of the v0.64.0
// incident. Two of the owner's seven items were left that way.
//
// THE DECRYPT HALF OF THE ACL IS UNTOUCHED BY THAT WRITE, and that is a smaller comfort than it
// sounds. `SecItemUpdate` needs no decrypt right at all: measured against an item created by
// `security` with no `-T`, a process the decrypt entry has never heard of still gets status 0 and
// still rewrites the partition list, and the entry afterwards still names `/usr/bin/security` and
// nobody else. So an item Tally damaged is NOT thereby an item Tally may read.
//
// WHETHER THIS BINARY CAN READ A DAMAGED ITEM SILENTLY THEREFORE DEPENDS ON THE PERSON, and on one
// click they made months ago: v0.63 raised a consent panel per item per launch, and answering one
// with "Always Allow" is what put Tally's helper into that item's decrypt entry. Both of the owner's
// two damaged items carry it for exactly that reason. A user who never clicked it has items that are
// damaged AND that this binary cannot read without asking.
//
// SO THE REPAIR COSTS ONE PANEL PER DAMAGED ITEM ON THE MACHINES THAT NEVER SAID ALWAYS ALLOW, and
// that is the deal rather than a defect. An unattended pass (`interactive: false`) gets
// `errSecAuthFailed` from the silent read and answers `.unreadable`, having touched nothing. An
// interactive one - the verb, the app's launch pass, `tally claude` from a terminal - gets ONE macOS
// panel per damaged item, "tally wants to access <service>", and allowing it is what lets the value
// be read and the item healed. One panel, once, in place of a panel at every launch for ever.
//
// The rewrite itself is the easy half: `security add-generic-password -U -X <hex>` puts
// `apple-tool:` back and leaves the decrypt entry's applications alone (measured: a 2960-byte value
// with non-ASCII bytes and a newline in it round-tripped byte for byte).
//
// THE ALTERNATIVES WERE MEASURED BEFORE THEY WERE REJECTED, so that nobody has to re-derive this:
// `security set-generic-password-partition-list` asks for the login password every time, which is
// not a thing an app may do at launch; `-w` through the tool's own stdin prompt truncates at 128
// bytes; and `security -i` line-buffers at about 4 KB, which a 2.2 KB credential in hex exceeds.
//
// NOTHING HERE PRINTS except `runKeychainRepair`, which is a command somebody typed, and no path
// prints a value. What the verb says about an item is one of the outcomes below and its service
// name, which is not a secret (it is a hash of a config directory path).
//
// THE ACL IS READ THROUGH `dlsym` rather than by calling the four functions directly, for the reason
// KeychainSecret.swift gives for the one it looks up: `SecKeychainItemCopyAccess` and its three
// companions are the ONLY API that can answer this question, and the SDK has had them deprecated
// since macOS 10.10, so a direct call costs four build warnings in a repo that commits at zero. The
// second reason is the better one: a symbol that has gone becomes an observable nil rather than a
// silent no-op, and every caller here treats "cannot read the ACL" as "do not touch this item".

/// The partition every Claude Code credentials item must carry, and the one `security` writes.
///
/// AN ITEM IS JUDGED BY WHETHER THIS IS PRESENT, never by what else is beside it: macOS may add a
/// partition without taking this one away (a `security` write on an item another program had also
/// written), and such an item still reads silently, which is the only property that matters here.
let appleToolPartition = "apple-tool:"

/// What happened to one item.
enum KeychainPartitionOutcome: Equatable {
    /// The partition list already names `apple-tool:`. Nothing was read and nothing was written.
    case healthy
    /// It did not, and now does: the value was read, stored again through `security`, and both the
    /// partition list and the value were checked afterwards.
    case repaired
    /// The item is damaged but this process cannot read its value, so there is nothing to store
    /// again. The status is the one `SecItemCopyMatching` answered with.
    case unreadable(OSStatus)
    /// The value was read but `security` did not store it.
    case writeFailed
    /// `security` said it stored it, and the check afterwards disagreed: either the partition list
    /// still lacks `apple-tool:`, or reading the value back does not give what went in.
    case verifyFailed
}

// MARK: - Reading the ACL

/// A Security function this file may only reach through `dlsym` (the header says why), or nil when
/// the symbol is not in this process.
private func securitySymbol<Function>(_ name: String, as type: Function.Type) -> Function? {
    // RTLD_DEFAULT: every image already loaded here, which Security.framework is.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}

private typealias SecKeychainItemTypeID = @convention(c) () -> CFTypeID
private typealias SecKeychainItemAccess =
    @convention(c) (SecKeychainItem, UnsafeMutablePointer<SecAccess?>) -> OSStatus
private typealias SecAccessACLList =
    @convention(c) (SecAccess, UnsafeMutablePointer<CFArray?>) -> OSStatus
private typealias SecACLAuthorizations = @convention(c) (SecACL) -> Unmanaged<CFArray>?
private typealias SecACLContents =
    @convention(c) (SecACL, UnsafeMutablePointer<CFArray?>, UnsafeMutablePointer<CFString?>,
                    UnsafeMutablePointer<SecKeychainPromptSelector>) -> OSStatus

/// The partition list of a generic-password item, and the status that explains an absent one.
///
/// The partitions are nil for every way this can fail to be answered - no such item, a keychain that
/// will not describe it, a symbol that has gone, an ACL with no partition entry in it - and the
/// status is what `SecItemCopyMatching` said, so a caller can tell "no such item" from "there is one
/// and its ACL could not be read". Both are the same instruction to `repairKeychainPartitions`
/// below: leave it alone.
///
/// NOTHING HERE READS A SECRET and nothing here can raise a prompt: the query asks for a REFERENCE
/// rather than for data, and reading an ACL off that reference is not a decryption (measured, and
/// the reason the detector can run at every launch).
private func partitionReading(service: String, account: String)
    -> (partitions: [String]?, status: OSStatus) {
    var reference: CFTypeRef?
    let status = SecItemCopyMatching([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnRef as String: true,
    ] as CFDictionary, &reference)
    guard status == errSecSuccess, let reference else { return (nil, status) }
    // The reference is only a `SecKeychainItem` for a file-based keychain, which is the only kind
    // this repo queries (nothing here passes `kSecUseDataProtectionKeychain`). The type is ASKED
    // rather than assumed, because the cast below cannot check anything itself: CF types have no
    // conditional downcast, so what makes this safe is the comparison in front of it.
    guard let typeID = securitySymbol("SecKeychainItemGetTypeID", as: SecKeychainItemTypeID.self),
          CFGetTypeID(reference) == typeID() else { return (nil, status) }
    let item = unsafeDowncast(reference, to: SecKeychainItem.self)

    guard let copyAccess = securitySymbol("SecKeychainItemCopyAccess", as: SecKeychainItemAccess.self),
          let copyACLList = securitySymbol("SecAccessCopyACLList", as: SecAccessACLList.self),
          let copyAuthorizations = securitySymbol("SecACLCopyAuthorizations",
                                                  as: SecACLAuthorizations.self),
          let copyContents = securitySymbol("SecACLCopyContents", as: SecACLContents.self)
    else { return (nil, status) }

    var access: SecAccess?
    guard copyAccess(item, &access) == errSecSuccess, let access else { return (nil, status) }
    var list: CFArray?
    guard copyACLList(access, &list) == errSecSuccess,
          let acls = list as? [SecACL] else { return (nil, status) }
    for acl in acls {
        guard let authorizations = copyAuthorizations(acl)?.takeRetainedValue() as? [String],
              authorizations.contains(kSecACLAuthorizationPartitionID as String) else { continue }
        var applications: CFArray?
        var description: CFString?
        var prompt = SecKeychainPromptSelector()
        guard copyContents(acl, &applications, &description, &prompt) == errSecSuccess,
              let hex = description as String? else { continue }
        return (partitionsInHexEncodedPlist(hex), status)
    }
    return (nil, status)
}

/// The `Partitions` array inside the hex-encoded plist an `ACLAuthorizationPartitionID` entry keeps
/// as its description, or nil when it is not one.
///
/// Written out rather than borrowed: the description is documented nowhere and is a plist only by
/// observation, so every step of the reading is allowed to fail into "this is not a partition list I
/// understand", which is the same instruction as an unreadable ACL.
private func partitionsInHexEncodedPlist(_ hex: String) -> [String]? {
    let digits = Array(hex.utf8)
    guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
    func value(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return character - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
    var bytes = Data(capacity: digits.count / 2)
    for pair in stride(from: 0, to: digits.count, by: 2) {
        guard let high = value(digits[pair]), let low = value(digits[pair + 1]) else { return nil }
        bytes.append(high << 4 | low)
    }
    guard let plist = try? PropertyListSerialization.propertyList(from: bytes, options: [],
                                                                  format: nil),
          let document = plist as? [String: Any],
          let partitions = document["Partitions"] as? [String] else { return nil }
    return partitions
}

/// The partition list of an item, or nil when it cannot be read (see `partitionReading`).
func keychainPartitions(service: String, account: String) -> [String]? {
    partitionReading(service: service, account: account).partitions
}

/// Whether a partition list that HAS been read is one `security` can no longer use.
///
/// THE ONE RULE, spelled once: the detector below and the repair further down both ask this, so
/// there is no way to loosen what counts as damage in one place and not the other. It is a judgement
/// about the list rather than about the item, which is what lets the repair reuse the reading it
/// already has instead of taking a second one.
///
/// Judged by ABSENCE rather than by what is present, and that is the whole of it: the damage has as
/// many names as there are code-signing identities (`teamid:…` for a Developer ID build,
/// `cdhash:…` for an ad-hoc one), so a rule that listed them would be a rule that the next writer
/// walks past. What every reader of these items actually needs is `apple-tool:`, and its absence is
/// the only thing that stops them.
func partitionsNeedRepair(_ partitions: [String]) -> Bool {
    !partitions.contains(appleToolPartition)
}

/// Whether an item's partition list was read AND does not name `apple-tool:`.
///
/// A LIST THAT CANNOT BE READ IS NOT DAMAGED, deliberately: this answer decides whether Tally reads
/// and rewrites somebody's credential, and "I could not tell" has to mean "leave it alone" rather
/// than "rewrite it and see".
func keychainPartitionsAreDamaged(service: String, account: String) -> Bool {
    guard let partitions = keychainPartitions(service: service, account: account) else { return false }
    return partitionsNeedRepair(partitions)
}

// MARK: - Repairing one item

/// Put `apple-tool:` back into one item's partition list by storing its own value again through
/// `/usr/bin/security`, and check afterwards that both the partition list and the value are what
/// they should be.
///
/// `interactive` is whether A PERSON IS WATCHING, and it is the same axis the seeding runs on
/// (MCPAuthSync.swift): true when this runs in the same second as a command somebody typed, false
/// for anything a supervisor decided to do on its own. What it decides is whether this process
/// leaves its own Keychain consent on. An unattended pass that cannot turn the dialogs off REFUSES
/// TO GO ON, because a switch that silently did nothing would leave a 3am relaunch able to stop on a
/// panel with nobody at the machine.
///
/// THE VALUE IS READ FROM THE FRAMEWORK AND THAT IS THE ONE PLACE IN THIS REPO THAT DOES IT, because
/// there is no other way to get the bytes back: `security` cannot read the item any more, which is
/// the whole complaint.
///
/// AND WHETHER THAT READ IS SILENT IS NOT THIS CODE'S TO DECIDE. The damaging write left the decrypt
/// entry alone, so being damaged tells you nothing about whether Tally may read it (the header has
/// the measurement, taken against an item Tally was never trusted with). Where the person once
/// answered a v0.63 panel with "Always Allow", this binary is in that entry and the read returns
/// without a sound; where they did not, it does not. So:
///
///   * `interactive: false` - the read answers `errSecAuthFailed` and this returns `.unreadable`,
///     having written nothing. That is the right answer for a 3am relaunch, and the next interactive
///     pass will find the item still damaged and deal with it.
///   * `interactive: true` - macOS puts up ONE panel, "tally wants to access <service>", and what
///     the person does with it decides the item. Allowing it is the one-time price of the repair;
///     refusing it leaves `.unreadable` and the item exactly as it was.
///
/// The value exists in this process's memory and in the argument list of one `security` child (which
/// KeychainSecret.swift weighs), and nowhere else. Nothing here logs it.
func repairKeychainPartitions(service: String, account: String,
                              interactive: Bool) -> KeychainPartitionOutcome {
    let switched = setKeychainInteractionAllowed(interactive)
    if !interactive, !switched { return .unreadable(errSecInteractionNotAllowed) }

    let reading = partitionReading(service: service, account: account)
    guard let partitions = reading.partitions else { return .unreadable(reading.status) }
    guard partitionsNeedRepair(partitions) else { return .healthy }

    var value: CFTypeRef?
    let status = SecItemCopyMatching([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
    ] as CFDictionary, &value)
    guard status == errSecSuccess, let data = value as? Data else { return .unreadable(status) }

    guard writeKeychainSecretAsSecurityTool(service: service, account: account,
                                            data: data) else { return .writeFailed }

    // BOTH HALVES ARE CHECKED, because each one can be right while the other is wrong. The partition
    // list is what the whole repair is for; the value is what a repair may never cost somebody. The
    // second check deliberately goes through the read path everybody else uses - `security -w`,
    // which is the very thing that was stopping on a panel - so a pass here means the item is
    // readable again by the programs that were locked out, and not merely by this one.
    guard let after = keychainPartitions(service: service, account: account),
          after.contains(appleToolPartition) else { return .verifyFailed }
    guard keychainSecret(service: service, account: account) == data else { return .verifyFailed }
    return .repaired
}

// MARK: - Repairing every Claude Code item

/// Every `Claude Code-credentials*` item of this login user, with what the repair did to each.
///
/// ENUMERATED BY ATTRIBUTES ONLY (`kSecMatchLimitAll` with `kSecReturnAttributes`), which returns no
/// secret and raises no prompt, and filtered down to two things before anything is touched: a
/// service name in Claude Code's own family, and this user's account. Nothing else on the machine is
/// looked at, let alone written - somebody's mail password is not this feature's business, and an
/// item belonging to another login user is not this process's to read.
///
/// Sorted by service name so that the verb's output is the same list in the same order every time.
func repairClaudeKeychainPartitions(interactive: Bool)
    -> [(service: String, outcome: KeychainPartitionOutcome)] {
    let account = NSUserName()
    var found: CFTypeRef?
    guard SecItemCopyMatching([
        kSecClass as String: kSecClassGenericPassword,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnAttributes as String: true,
    ] as CFDictionary, &found) == errSecSuccess,
        let items = found as? [[String: Any]] else { return [] }

    let services = items.compactMap { attributes -> String? in
        guard let service = attributes[kSecAttrService as String] as? String,
              service.hasPrefix(claudeBaseKeychainService),
              attributes[kSecAttrAccount as String] as? String == account else { return nil }
        return service
    }
    // THE DETECTOR IS THE GATE, and on almost every machine on almost every launch it is the whole
    // of the work: an item whose list already names `apple-tool:` is answered from one ACL read,
    // with no value read, nothing written, and this process's consent switch never touched. Only an
    // item that fails it is handed to the repair, which reads the list again for itself - a second
    // ACL read on the rare path, in exchange for one function that can be called on its own and
    // still tell "I cannot read this item's value" from "there was nothing wrong with it".
    return Set(services).sorted().map { service in
        guard keychainPartitionsAreDamaged(service: service, account: account) else {
            return (service, KeychainPartitionOutcome.healthy)
        }
        return (service, repairKeychainPartitions(service: service, account: account,
                                                  interactive: interactive))
    }
}

// MARK: - `tally keychain-repair`

/// What one item's outcome is called on the verb's output. English, like every other line this
/// binary prints, and never a value.
func keychainRepairLine(service: String, outcome: KeychainPartitionOutcome) -> String {
    switch outcome {
    case .healthy: return "\(service): healthy"
    case .repaired: return "\(service): repaired"
    case let .unreadable(status): return "\(service): unreadable (status \(status))"
    case .writeFailed: return "\(service): write failed"
    case .verifyFailed: return "\(service): verify failed"
    }
}

/// Whether an outcome leaves the item still unreadable by `security`, which is what the exit code is
/// about: `healthy` and `repaired` are the two that do not.
func keychainRepairLeftDamage(_ outcome: KeychainPartitionOutcome) -> Bool {
    switch outcome {
    case .healthy, .repaired: return false
    case .unreadable, .writeFailed, .verifyFailed: return true
    }
}

/// `tally keychain-repair` - heal every Claude Code credentials item this binary's own 0.64.0 write
/// path damaged, and say what became of each.
///
/// INTERACTIVE, because it is a command somebody typed: an item that needs consent to be read is one
/// the person at the keyboard can answer for, and this is the surface where that is the right trade.
/// The launch path runs the same repair on the axis a launch already has (MCPAuthSync.swift).
///
/// Exit 0 when nothing is left damaged, which includes a machine with no such items at all: "there
/// is nothing wrong here" and "there was something and it is fixed" are the same answer to whoever
/// or whatever ran this.
func runKeychainRepair() -> Int32 {
    let outcomes = repairClaudeKeychainPartitions(interactive: true)
    for outcome in outcomes { print(keychainRepairLine(service: outcome.service, outcome: outcome.outcome)) }
    return outcomes.contains { keychainRepairLeftDamage($0.outcome) } ? 1 : 0
}
