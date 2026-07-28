import Foundation
import CryptoKit

// Where Claude Code keeps a config dir's OAuth login, named the way Claude Code names it.
//
// Shared by BOTH targets rather than reimplemented in each (project.yml compiles this file into the
// CLI as well as the app): the app discovers accounts by probing these names, and `tally add` has to
// ask the same question of the same name to know whether a numbered home is already logged in. Two
// derivations of one string is a silent failure waiting to happen - a drifted hash finds nothing,
// which reads exactly like "not logged in" and never raises an error anywhere.

/// The bare service name, used by the default config dir.
private let claudeBaseKeychainService = "Claude Code-credentials"

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
    let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    return "\(claudeBaseKeychainService)-\(suffix)"
}
