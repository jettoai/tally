// The UniFFI binding generator, pinned to the workspace's uniffi version through Cargo.lock.
// Only scripts/gen-uniffi.sh runs it.
fn main() {
    uniffi::uniffi_bindgen_main()
}
