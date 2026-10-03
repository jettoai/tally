//! Platform layer: everything that differs between macOS and Windows lives here, behind
//! functions the rest of the workspace calls without cfg of its own. Starts with paths; the
//! credential, process, pty and watcher layers arrive with the packages that move them.
pub mod fs;
pub mod paths;
