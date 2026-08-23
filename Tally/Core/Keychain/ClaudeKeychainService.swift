import Foundation
import CryptoKit

// Where Claude Code keeps a config dir's OAuth login, named the way Claude Code names it.
//
// Shared by BOTH targets rather than reimplemented in each (project.yml compiles this file into the
// CLI as well as the app): the app discovers accounts by probing these names, and `tally add` has to
// ask the same question of the same name to know whether a numbered home is already logged in. Two
// derivations of one string is a silent failure waiting to happen - a drifted hash finds nothing,
// which reads exactly like "not logged in" and never raises an error anywhere.

/// The bare service name, used by the default config dir - AND the stem every other one is built on,
/// which is a second job it acquired rather than a coincidence of spelling.
let claudeBaseKeychainService = "Claude Code-credentials"

/// Keychain service name for a given config dir. `~/.claude` -> bare; others -> hashed suffix.
///
/// Claude Code namespaces its Keychain item by config dir: the default `~/.claude` uses the bare
/// service name; any dir set via `CLAUDE_CONFIG_DIR` (e.g. `~/.claude2`) appends
/// `-<first 8 hex of SHA-256 of the absolute dir path>`. This is what lets Tally monitor two Max
/// accounts independently - the whole point of the project.
func claudeKeychainService(forConfigDir dir: URL) -> String {
    if dir.lastPathComponent == ".claude" { return claudeBaseKeychainService }
    let normalized = dir.path.precomposedStringWithCanonicalMapping
    let digest = SHA256.hash(data: Data(normalized.utf8))
    let suffix = digest.prefix(claudeKeychainServiceSuffixBytes)
        .map { String(format: "%02x", $0) }.joined()
    return "\(claudeBaseKeychainService)-\(suffix)"
}

/// How many bytes of the digest the suffix is made of. Printed `%02x`, so the suffix is twice this
/// many characters - and BOTH DIRECTIONS READ IT FROM HERE, the generator above and the matcher
/// below, which is what makes "could this name have been produced by that function" a question with
/// one answer rather than two constants that agree until somebody edits one.
private let claudeKeychainServiceSuffixBytes = 4

/// Whether `service` is a name the generator above COULD HAVE PRODUCED, which is a different and
/// much narrower question than whether it starts with the same words.
///
/// IT LIVES BESIDE THE GENERATOR ON PURPOSE, and that is the whole reason this function exists at
/// all rather than a `hasPrefix` at each call site: one file owns both directions of the rule, and
/// the one number they could disagree about is read by both of them from the constant above.
///
/// A PREFIX TEST IS NOT THIS TEST. `Claude Code-credentials-backup` starts with the stem and is
/// nobody's config home: it is whatever a person or another program chose to call something of their
/// own. The CLI's repair reads and rewrites the secret of every item it accepts here
/// (TallyCLI/KeychainPartitionRepair.swift), so "close enough" is a stranger's credential being read
/// and written back, and the two legitimate shapes are exactly:
///
///   * the bare stem, which is `~/.claude`; or
///   * the stem, one hyphen, and exactly eight LOWERCASE hex digits, which is every other home.
///
/// Everything else is refused, `-DEADBEEF` and `-deadbeef0` included: the generator prints lowercase
/// and prints eight, so an item wearing any other spelling was not written for a config dir this
/// machine has.
func isClaudeCredentialsService(_ service: String) -> Bool {
    if service == claudeBaseKeychainService { return true }
    guard service.hasPrefix(claudeBaseKeychainService + "-") else { return false }
    let suffix = service.dropFirst(claudeBaseKeychainService.count + 1)
    guard suffix.count == claudeKeychainServiceSuffixBytes * 2 else { return false }
    // ASCII asked for explicitly: `isHexDigit` is a Unicode property and answers true for the
    // fullwidth digits too, which `%02x` has never printed one of.
    return suffix.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
}
