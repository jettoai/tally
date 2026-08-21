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

/// Turn this PROCESS's Keychain consent dialogs off (or back on), answering whether it took.
///
/// Reading a secret out of an item another program created raises the macOS consent dialog, and the
/// read BLOCKS until somebody answers it. That is acceptable in front of a person who just typed a
/// command and unacceptable everywhere else, so the seeding turns the dialogs off on the paths where
/// nobody is watching (MCPAuthSync.swift states which). Measured 2026-08-21, on a file-based item
/// created by another program: with this off the read returns `errSecAuthFailed` in 9 ms and draws
/// nothing; with it on, the same code path blocks on the dialog.
///
/// LOOKED UP AT RUNTIME rather than called directly, for two reasons and not for cleverness. The
/// first is that `SecKeychainSetUserInteractionAllowed` is the only thing that does this for a
/// file-based item and the SDK has had it deprecated since macOS 10.10, so a direct call costs a
/// build warning in a repo that commits at zero. (The documented replacement does NOT cover this
/// case: `kSecUseAuthenticationUI = fail` was measured against the same item and ignored - the read
/// blocked on the dialog anyway.) The second is worth more: this way "the mechanism is not there any
/// more" becomes an observable false instead of a silent no-op, and the caller can refuse to read at
/// all - which is the direction a missing safety switch has to fail in.
func setKeychainInteractionAllowed(_ allowed: Bool) -> Bool {
    typealias SetUserInteractionAllowed = @convention(c) (DarwinBoolean) -> OSStatus
    // RTLD_DEFAULT: search every image already loaded into this process, which Security.framework is.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                             "SecKeychainSetUserInteractionAllowed") else { return false }
    return unsafeBitCast(symbol, to: SetUserInteractionAllowed.self)(DarwinBoolean(allowed))
        == errSecSuccess
}

/// The secret bytes of a generic-password item, or nil.
///
/// Nil for every reason there is, deliberately: no such item, a locked keychain, a consent dialog the
/// user declined. They are different facts, but not to any caller of this - all of them mean "this
/// home cannot be seeded now", and the seeding does the same thing about each.
func keychainSecret(service: String, account: String) -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
}

/// Replace the secret of an EXISTING item. Never creates one.
///
/// The distinction is the whole safety of the seeding: a config home with no login has no item, and
/// an item holding only the MCP subtree would be a credential document with no login in it - which is
/// not a shape Claude Code ever writes, and not one Tally may invent. `errSecItemNotFound` is
/// therefore the correct outcome for such a home rather than a case to handle.
func updateKeychainSecret(service: String, account: String, data: Data) -> OSStatus {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    return SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
}
