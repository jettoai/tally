//! `cargo run -p tally_core --example reap -- --dry-run`: the same entry `tally reap` reaches, for
//! reconciliation runs that should not need an Xcode build.
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut out = std::io::stdout().lock();
    std::process::exit(tally_core::reap::main(&args, &mut out));
}
