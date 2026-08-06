import Foundation

// Where the config home an account id names lives, and whether it is still there.
//
// It exists because a snapshot is one OBSERVATION and some questions need EVIDENCE. "This account is
// no longer in the fleet" is one of them: the CLI reads the fleet out of `~/.tally/snapshot.json`,
// which the app rewrites whole every minute, and an account is only in it if that refresh saw the
// account (for claude, that means a Keychain probe answered - ClaudeAccounts.discover). So an id
// missing from one snapshot means "the app did not list it this minute", and reading that as
// "removed" turns a locked Keychain, a rescan in flight, or an app that has not run since the
// account was added into a permanent verdict (a live `tally switch` was cancelled that way,
// reported 2026-08-06, with all five accounts present on disk and in the very next snapshot).
//
// The directory is the stronger witness, and it is the same one the app's own discovery starts from:
// every config home is a direct child of the user's home directory whose name begins with the
// provider's base (`~/.claude`, `~/.claude2`, `~/.claude-work`, `~/.codex2`), and an account id IS
// `<provider>:<that directory's name>` (ClaudeAccounts.swift, CodexAccounts.swift). A directory does
// not come and go while the machine is idle, so its absence is a fact and its presence is a reason to
// wait rather than to cancel.

/// The path of the config home `accountID` names, or nil when the id does not name one for this
/// provider.
///
/// Derived rather than spelled: the family's base name and the directory the homes sit in both come
/// out of `defaultHome` (Snapshot.swift), which is the CLI's one answer to "where does this provider
/// keep its config". Spelling `.claude` here would be a second copy of that rule, free to disagree
/// with the launcher about which directories are accounts at all.
///
/// Two refusals, and they are the same guard from either end: an id whose second half does not start
/// with the provider's base is not a config home this provider ever discovers, and one containing a
/// path separator is not a NAME. Together they mean the returned path is always a direct child of the
/// home directory - nothing built here can reach outside it, whatever a snapshot or a request file
/// happens to contain.
func accountConfigHome(_ accountID: String, provider: Provider) -> String? {
    let defaultDir = URL(fileURLWithPath: defaultHome(provider))
    let prefix = provider.id + ":"
    guard accountID.hasPrefix(prefix) else { return nil }
    let name = String(accountID.dropFirst(prefix.count))
    guard name.hasPrefix(defaultDir.lastPathComponent), !name.contains("/") else { return nil }
    return defaultDir.deletingLastPathComponent().appendingPathComponent(name).path
}

/// Whether the config home an account id names is still on disk. `isDirectory` is injected so the
/// callers' decisions stay testable without a home directory.
///
/// A FILE at that path is not a config home, and answers false: the question is whether the account's
/// directory is still there, and something else standing at the path is not it.
func accountHomeExists(_ accountID: String, provider providerID: String,
                       isDirectory: (String) -> Bool = accountHomeIsDirectory) -> Bool {
    guard let provider = providers.first(where: { $0.id == providerID }),
          let path = accountConfigHome(accountID, provider: provider) else { return false }
    return isDirectory(path)
}

/// The real probe behind it.
func accountHomeIsDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && isDirectory.boolValue
}
