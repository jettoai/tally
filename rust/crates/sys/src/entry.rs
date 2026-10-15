//! The hand-over every `tally` entry binary ends in: replace this process with the Swift CLI
//! beside it. Lives here so an entry built elsewhere (an overlay's own launcher) forwards through
//! the same code as the public one. See crates/cli/src/main.rs for why this is a raw `execv`.
use std::ffi::{c_char, c_int, CString};
use std::io::Write;
use std::os::unix::ffi::OsStrExt;

extern "C" {
    fn execv(path: *const c_char, argv: *const *const c_char) -> c_int;
    fn usleep(microseconds: u32) -> c_int;
}

/// How long a missing Swift CLI is waited for: the moment an installer swaps the bundle.
const MISSING_RETRIES: u32 = 10;
const MISSING_WAIT_US: u32 = 50_000;

fn fail(message: &str) -> c_int {
    let _ = writeln!(std::io::stderr(), "tally: {message}");
    127
}

/// Execs the Swift CLI with `argv` (the NULL-terminated vector `main` received); returns only on
/// failure, with the exit code to use.
pub fn forward(argv: *const *const c_char) -> c_int {
    let entry = match std::env::current_exe().and_then(std::fs::canonicalize) {
        Ok(path) => path,
        Err(error) => return fail(&format!("cannot locate this binary: {error}")),
    };
    let Some(target) = crate::paths::swift_cli(&entry) else {
        return fail("cannot locate the Swift CLI");
    };
    let Ok(c_target) = CString::new(target.as_os_str().as_bytes()) else {
        return fail("Swift CLI path contains a NUL byte");
    };
    let mut attempt = 0;
    loop {
        // Returns only on failure.
        unsafe { execv(c_target.as_ptr(), argv) };
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::NotFound && attempt < MISSING_RETRIES {
            attempt += 1;
            unsafe { usleep(MISSING_WAIT_US) };
            continue;
        }
        return fail(&format!("cannot start {}: {error}", target.display()));
    }
}
