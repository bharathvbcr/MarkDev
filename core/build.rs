//! Generates `include/markdev.h` from the `#[no_mangle]` FFI surface.
//!
//! The header is generated rather than hand-written so the struct layouts
//! Swift reads can never drift from the Rust definitions — a drift that would
//! show up as silently misaligned text ranges rather than a build error.

use std::path::PathBuf;

fn main() {
    let crate_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let out = crate_dir.join("include").join("markdev.h");

    println!("cargo:rerun-if-changed=src/ffi.rs");
    println!("cargo:rerun-if-changed=src/md/model.rs");
    println!("cargo:rerun-if-changed=cbindgen.toml");

    if let Err(e) = std::fs::create_dir_all(out.parent().expect("include dir")) {
        println!("cargo:warning=could not create include dir: {e}");
        return;
    }

    match cbindgen::generate(&crate_dir) {
        Ok(bindings) => {
            bindings.write_to_file(&out);
        }
        // A header failure must not block `cargo test`, which does not need
        // it — but it must be loud, because the Swift build does.
        Err(e) => println!(
            "cargo:warning=cbindgen failed to generate {}: {e}",
            out.display()
        ),
    }
}
