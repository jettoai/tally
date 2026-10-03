//! `tally`: the entry every caller reaches (the /usr/local/bin link, Claude Code hooks, the app).
//!
//! Until a subcommand moves to Rust, this binary claims none of them: it replaces itself with the
//! Swift CLI beside it (Contents/Helpers/swift/tally) with the arguments, environment, open files,
//! signal dispositions and signal mask exactly as it received them, and in the same process.
//!
//! WHY `no_main` AND A RAW `execv`: Rust's own start-up sets SIGPIPE to ignored, and
//! `std::process::Command::exec` resets SIGPIPE and clears the signal mask before it execs. Either
//! one hands the Swift CLI a process that differs from the one its caller started, and the
//! acceptance test for this binary is that nothing differs. argv[0] is passed through untouched
//! because `tally harness install` writes it into the hooks it registers.
#![cfg_attr(unix, no_main)]

/// Found by scripts/build-release.sh in both slices before the binary is embedded.
#[used]
static ENTRY_MARKER: [u8; 22] = *b"tally_entry forward-v1";

#[cfg(unix)]
mod forward {
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

    pub fn run(argv: *const *const c_char) -> c_int {
        let entry = match std::env::current_exe().and_then(std::fs::canonicalize) {
            Ok(path) => path,
            Err(error) => return fail(&format!("cannot locate this binary: {error}")),
        };
        let Some(target) = tally_sys::paths::swift_cli(&entry) else {
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
}

#[cfg(unix)]
#[no_mangle]
pub extern "C" fn main(_argc: std::ffi::c_int, argv: *const *const std::ffi::c_char) -> std::ffi::c_int {
    forward::run(argv)
}

#[cfg(not(unix))]
fn main() {
    // Windows has no Swift CLI to forward to; subcommands land here as they move to Rust.
    eprintln!("tally: not available on this platform yet");
    std::process::exit(2);
}
