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
#[no_mangle]
pub extern "C" fn main(_argc: std::ffi::c_int, argv: *const *const std::ffi::c_char) -> std::ffi::c_int {
    tally_sys::entry::forward(argv)
}

#[cfg(not(unix))]
fn main() {
    // Windows has no Swift CLI to forward to; subcommands land here as they move to Rust.
    eprintln!("tally: not available on this platform yet");
    std::process::exit(2);
}
