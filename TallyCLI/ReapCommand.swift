import Foundation

// `tally reap [--dry-run]`: reclaim idle Xcode build folders, finished worktrees and clones, and
// long-idle session directories under /private/tmp/claude-<uid>. The whole command lives in the
// Rust core (rust/crates/core/src/reap); this only hands it the arguments.
func runReap(args: [String]) -> Int32 {
    reapMain(args: args)
}
