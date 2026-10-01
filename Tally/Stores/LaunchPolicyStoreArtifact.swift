import Foundation

extension LaunchPolicyStore {
    /// The Artifact publishing account after a config home has been removed: nil when that home IS
    /// the chosen one, and the choice untouched otherwise.
    ///
    /// Compared through `artifactAccountHome`, the same normalization the CLI compares with, so a
    /// choice stored with a trailing slash or through a symlink is still recognised as the home
    /// being removed. Text rather than a filesystem identity read because by the time this is asked
    /// the directory has already gone to the Trash (`artifactAccountHome` states it in full).
    ///
    /// Pure, so the rule is assertable without a state file to write into.
    static func artifactAccountAfterRemoving(_ current: String?, home: String) -> String? {
        guard let current, let removed = artifactAccountHome(home),
              artifactAccountHome(current) == removed else { return current }
        return nil
    }
}
