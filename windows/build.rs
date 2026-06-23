//! Embed the application icon into the executable so Explorer and the taskbar
//! show it (the tray icon is loaded separately at runtime).
//!
//! We compile `app.rc` into a COFF object with `windres` and ask the linker to
//! include it. The GNU toolchain's bundled `ld` links COFF objects natively, so
//! no linker change is needed. `windres` is tried under a few common names; if
//! none is on PATH we warn and skip, so the build still succeeds (just without
//! the exe icon — the tray icon is loaded separately at runtime and unaffected).

use std::env;
use std::path::Path;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=app.rc");
    println!("cargo:rerun-if-changed=assets/agentcord.ico");

    // Only relevant when targeting Windows.
    if env::var("CARGO_CFG_WINDOWS").is_err() {
        return;
    }

    let out_dir = env::var("OUT_DIR").expect("OUT_DIR");
    let obj = Path::new(&out_dir).join("app_icon.o");

    // Prefer an explicit `WINDRES` (full path, so we don't have to put a whole
    // mingw toolchain on PATH where it could shadow the bundled gcc/ld), then
    // fall back to common names on PATH.
    let mut candidates: Vec<String> = Vec::new();
    if let Ok(w) = env::var("WINDRES") {
        candidates.push(w);
    }
    candidates.extend(
        ["windres", "x86_64-w64-mingw32-windres", "llvm-windres"]
            .iter()
            .map(|s| s.to_string()),
    );

    let compiled = candidates.iter().any(|tool| {
        Command::new(tool)
            .args(["-i", "app.rc", "-o"])
            .arg(&obj)
            .args(["-O", "coff"])
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    });

    if compiled {
        println!("cargo:rustc-link-arg={}", obj.display());
    } else {
        println!(
            "cargo:warning=windres not found; executable icon not embedded \
             (the tray icon still works)"
        );
    }
}
