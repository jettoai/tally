//! UniFFI surface for `tally reap` and the one git step `tally worktree remove` shares with it.
use std::panic::{catch_unwind, AssertUnwindSafe};

#[derive(uniffi::Record)]
pub struct FfiCommandResult {
    pub out: String,
    pub err: String,
    pub code: i32,
}

/// Runs `tally reap` with its arguments (after the word `reap`) and returns its exit code. Prints
/// to this process's stdout and stderr. A panic is exit code 70 instead of a crash in Swift.
#[uniffi::export]
pub fn reap_main(args: Vec<String>) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let mut out = std::io::stdout().lock();
        let rc = tally_core::reap::main(&args, &mut out);
        let _ = std::io::Write::flush(&mut out);
        rc
    }))
    .unwrap_or(70)
}

/// `git worktree remove [--force] <path>` in `main_repo` (tally_core::git::worktree_remove).
#[uniffi::export]
pub fn git_worktree_remove(main_repo: String, path: String, force: bool) -> FfiCommandResult {
    catch_unwind(AssertUnwindSafe(|| {
        let o = tally_core::git::worktree_remove(std::path::Path::new(&main_repo), &path, force);
        FfiCommandResult { out: o.out, err: o.err, code: o.code }
    }))
    .unwrap_or(FfiCommandResult { out: String::new(), err: "git worktree remove panicked".into(), code: 70 })
}
