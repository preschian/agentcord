//! Small shared helpers.

use std::process::Command;

/// Build a `Command` that won't flash a console window when spawned from the
/// GUI (release) build. `CREATE_NO_WINDOW` only suppresses console allocation,
/// so GUI children (e.g. notepad) still show their own windows.
pub fn command(program: &str) -> Command {
    let mut c = Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        c.creation_flags(CREATE_NO_WINDOW);
    }
    c
}
