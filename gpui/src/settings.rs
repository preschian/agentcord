//! `%APPDATA%\AgentCord\settings.json`, launch-at-login, sleep, single-instance.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

const ACTIVITY_TYPES: [(i32, &'static str); 4] =
    [(0, "Playing"), (2, "Listening"), (3, "Watching"), (5, "Competing")];
pub const IDLE_MINUTES: [i32; 7] = [1, 5, 10, 15, 20, 25, 30];

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub presence_enabled: bool,
    pub show_model: bool,
    pub show_tokens: bool,
    pub show_project: bool,
    pub unified_usage: bool,
    pub small_image_key: String,
    pub selected_agent: i32,
    pub agent_claude_enabled: bool,
    pub agent_codex_enabled: bool,
    pub agent_cursor_enabled: bool,
    pub agent_antigravity_enabled: bool,
    pub agent_grok_enabled: bool,
    pub activity_type: i32,
    pub idle_window_seconds: f64,
    pub prevent_sleep: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            presence_enabled: true,
            show_model: true,
            show_tokens: true,
            show_project: true,
            unified_usage: true,
            small_image_key: "discord-presence-icon".into(),
            selected_agent: 0,
            agent_claude_enabled: true,
            agent_codex_enabled: true,
            agent_cursor_enabled: true,
            agent_antigravity_enabled: true,
            agent_grok_enabled: true,
            activity_type: 0,
            idle_window_seconds: 300.0,
            prevent_sleep: false,
        }
    }
}

impl Settings {
    pub fn load() -> Self {
        let mut s: Self = config_path()
            .and_then(|p| fs::read_to_string(p).ok())
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        if s.idle_window_seconds < 60.0 {
            s.idle_window_seconds = 300.0;
        }
        s
    }

    pub fn save(&self) {
        let Some(path) = config_path() else {
            return;
        };
        if let Some(dir) = path.parent() {
            let _ = fs::create_dir_all(dir);
        }
        let Ok(text) = serde_json::to_string_pretty(self) else {
            return;
        };
        let tmp = path.with_extension("json.tmp");
        if fs::write(&tmp, text).is_ok() {
            let _ = fs::rename(&tmp, path);
        }
    }

    pub fn activity_label(&self) -> &'static str {
        ACTIVITY_TYPES
            .iter()
            .find(|(v, _)| *v == self.activity_type)
            .map(|(_, n)| *n)
            .unwrap_or("Playing")
    }

    pub fn activity_type(&self) -> i32 {
        if ACTIVITY_TYPES.iter().any(|(v, _)| *v == self.activity_type) {
            self.activity_type
        } else {
            0
        }
    }

    pub fn cycle_activity(&mut self) {
        let i = ACTIVITY_TYPES
            .iter()
            .position(|(v, _)| *v == self.activity_type)
            .unwrap_or(0);
        self.activity_type = ACTIVITY_TYPES[(i + 1) % ACTIVITY_TYPES.len()].0;
    }

    pub fn idle_minutes(&self) -> i32 {
        let m = (self.idle_window_seconds / 60.0).round() as i32;
        IDLE_MINUTES
            .iter()
            .copied()
            .min_by_key(|step| (*step - m).abs())
            .unwrap_or(5)
    }

    pub fn set_idle_minutes(&mut self, minutes: i32) {
        self.idle_window_seconds = minutes.max(1) as f64 * 60.0;
    }

    pub fn idle_label(&self) -> String {
        format!("{}m", self.idle_minutes())
    }
}

fn config_path() -> Option<PathBuf> {
    let base = std::env::var_os("APPDATA").map(PathBuf::from)?;
    Some(base.join("AgentCord").join("settings.json"))
}

pub fn set_prevent_sleep(on: bool) {
    const ES_CONTINUOUS: u32 = 0x8000_0000;
    const ES_SYSTEM_REQUIRED: u32 = 0x0000_0001;
    extern "system" {
        fn SetThreadExecutionState(flags: u32) -> u32;
    }
    unsafe {
        SetThreadExecutionState(if on {
            ES_CONTINUOUS | ES_SYSTEM_REQUIRED
        } else {
            ES_CONTINUOUS
        });
    }
}

pub struct InstanceGuard(isize);

impl Drop for InstanceGuard {
    fn drop(&mut self) {
        if self.0 != 0 {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}

/// `None` when another GPUI instance already holds the mutex.
pub fn acquire_instance() -> Option<InstanceGuard> {
    let name = wide("AgentCord.Gpui.SingleInstance");
    let handle = unsafe { CreateMutexW(std::ptr::null(), 1, name.as_ptr()) };
    if handle == 0 {
        return Some(InstanceGuard(0));
    }
    if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        unsafe {
            CloseHandle(handle);
        }
        return None;
    }
    Some(InstanceGuard(handle))
}

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const APPROVED_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
const VALUE_NAME: &str = "AgentCordGpui";
const HKEY_CURRENT_USER: isize = 0x8000_0001u32 as i32 as isize;
const KEY_SET_VALUE: u32 = 0x0002;
const KEY_QUERY_VALUE: u32 = 0x0001;
const REG_SZ: u32 = 1;
const REG_BINARY: u32 = 3;
const ERROR_ALREADY_EXISTS: u32 = 183;

pub fn autostart_enabled() -> bool {
    let Some(exe) = exe_path() else {
        return false;
    };
    let Some(stored) = reg_get_sz(RUN_KEY, VALUE_NAME) else {
        return false;
    };
    if !same_path(&stored, &exe) {
        return false;
    }
    is_startup_approved(reg_get_bin(APPROVED_KEY, VALUE_NAME).as_deref())
}

pub fn set_autostart(enabled: bool) -> bool {
    let Some(exe) = exe_path() else {
        return false;
    };
    if enabled {
        let quoted = format!("\"{exe}\"");
        reg_set_sz(RUN_KEY, VALUE_NAME, &quoted) && reg_set_bin(APPROVED_KEY, VALUE_NAME, &enabled_approved_blob())
    } else {
        reg_delete(RUN_KEY, VALUE_NAME);
        reg_delete(APPROVED_KEY, VALUE_NAME);
        true
    }
}

pub fn is_startup_approved(blob: Option<&[u8]>) -> bool {
    match blob {
        None | Some([]) => true,
        Some(b) => b[0] == 0x02 || b[0] == 0x06,
    }
}

fn enabled_approved_blob() -> [u8; 12] {
    let mut blob = [0u8; 12];
    blob[0] = 0x02;
    let time = filetime_now();
    blob[4..12].copy_from_slice(&time.to_le_bytes());
    blob
}

fn filetime_now() -> u64 {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    // FILETIME is 100ns ticks since 1601-01-01.
    (ms * 10_000 + 116_444_736_000_000_000) as u64
}

fn same_path(a: &str, b: &str) -> bool {
    a.trim().trim_matches('"').eq_ignore_ascii_case(b.trim().trim_matches('"'))
}

fn exe_path() -> Option<String> {
    let mut buf = [0u16; 520];
    let n = unsafe { GetModuleFileNameW(0, buf.as_mut_ptr(), buf.len() as u32) };
    if n == 0 {
        return None;
    }
    String::from_utf16(&buf[..n as usize]).ok()
}

fn reg_open(subkey: &str, write: bool) -> Option<isize> {
    let mut h = 0isize;
    let sam = KEY_QUERY_VALUE | if write { KEY_SET_VALUE } else { 0 };
    let status = if write {
        unsafe {
            RegCreateKeyExW(
                HKEY_CURRENT_USER,
                wide(subkey).as_ptr(),
                0,
                std::ptr::null_mut(),
                0,
                sam,
                std::ptr::null(),
                &mut h,
                std::ptr::null_mut(),
            )
        }
    } else {
        unsafe {
            RegOpenKeyExW(
                HKEY_CURRENT_USER,
                wide(subkey).as_ptr(),
                0,
                sam,
                &mut h,
            )
        }
    };
    (status == 0 && h != 0).then_some(h)
}

fn reg_get_sz(subkey: &str, name: &str) -> Option<String> {
    let key = reg_open(subkey, false)?;
    let mut kind = 0u32;
    let mut size = 0u32;
    unsafe {
        RegQueryValueExW(
            key,
            wide(name).as_ptr(),
            std::ptr::null_mut(),
            &mut kind,
            std::ptr::null_mut(),
            &mut size,
        );
    }
    if kind != REG_SZ || size == 0 {
        unsafe { RegCloseKey(key) };
        return None;
    }
    let mut buf = vec![0u16; (size as usize + 1) / 2];
    let status = unsafe {
        RegQueryValueExW(
            key,
            wide(name).as_ptr(),
            std::ptr::null_mut(),
            &mut kind,
            buf.as_mut_ptr() as *mut u8,
            &mut size,
        )
    };
    unsafe { RegCloseKey(key) };
    if status != 0 {
        return None;
    }
    let n = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16(&buf[..n]).ok()
}

fn reg_get_bin(subkey: &str, name: &str) -> Option<Vec<u8>> {
    let key = reg_open(subkey, false)?;
    let mut kind = 0u32;
    let mut size = 0u32;
    unsafe {
        RegQueryValueExW(
            key,
            wide(name).as_ptr(),
            std::ptr::null_mut(),
            &mut kind,
            std::ptr::null_mut(),
            &mut size,
        );
    }
    if kind != REG_BINARY || size == 0 {
        unsafe { RegCloseKey(key) };
        return None;
    }
    let mut buf = vec![0u8; size as usize];
    let status = unsafe {
        RegQueryValueExW(
            key,
            wide(name).as_ptr(),
            std::ptr::null_mut(),
            &mut kind,
            buf.as_mut_ptr(),
            &mut size,
        )
    };
    unsafe { RegCloseKey(key) };
    (status == 0).then_some(buf)
}

fn reg_set_sz(subkey: &str, name: &str, value: &str) -> bool {
    let Some(key) = reg_open(subkey, true) else {
        return false;
    };
    let data = wide(value);
    let bytes = data.len() * 2;
    let status = unsafe {
        RegSetValueExW(
            key,
            wide(name).as_ptr(),
            0,
            REG_SZ,
            data.as_ptr() as *const u8,
            bytes as u32,
        )
    };
    unsafe { RegCloseKey(key) };
    status == 0
}

fn reg_set_bin(subkey: &str, name: &str, value: &[u8]) -> bool {
    let Some(key) = reg_open(subkey, true) else {
        return false;
    };
    let status = unsafe {
        RegSetValueExW(
            key,
            wide(name).as_ptr(),
            0,
            REG_BINARY,
            value.as_ptr(),
            value.len() as u32,
        )
    };
    unsafe { RegCloseKey(key) };
    status == 0
}

fn reg_delete(subkey: &str, name: &str) {
    if let Some(key) = reg_open(subkey, true) {
        unsafe {
            RegDeleteValueW(key, wide(name).as_ptr());
            RegCloseKey(key);
        }
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

extern "system" {
    fn CreateMutexW(attr: *const core::ffi::c_void, initial_owner: i32, name: *const u16) -> isize;
    fn GetLastError() -> u32;
    fn CloseHandle(handle: isize) -> i32;
    fn GetModuleFileNameW(module: isize, buf: *mut u16, size: u32) -> u32;
    fn RegCreateKeyExW(
        key: isize,
        subkey: *const u16,
        reserved: u32,
        class: *mut u16,
        options: u32,
        sam: u32,
        security: *const core::ffi::c_void,
        result: *mut isize,
        disposition: *mut u32,
    ) -> i32;
    fn RegOpenKeyExW(
        key: isize,
        subkey: *const u16,
        options: u32,
        sam: u32,
        result: *mut isize,
    ) -> i32;
    fn RegSetValueExW(
        key: isize,
        name: *const u16,
        reserved: u32,
        kind: u32,
        data: *const u8,
        size: u32,
    ) -> i32;
    fn RegQueryValueExW(
        key: isize,
        name: *const u16,
        reserved: *mut u32,
        kind: *mut u32,
        data: *mut u8,
        size: *mut u32,
    ) -> i32;
    fn RegDeleteValueW(key: isize, name: *const u16) -> i32;
    fn RegCloseKey(key: isize) -> i32;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_production() {
        let s = Settings::default();
        assert!(s.presence_enabled && s.show_project && s.unified_usage);
        assert_eq!(s.activity_type, 0);
        assert_eq!(s.idle_window_seconds, 300.0);
        assert!(!s.prevent_sleep);
    }

    #[test]
    fn roundtrip_json_keeps_idle_window() {
        let mut s = Settings::default();
        s.idle_window_seconds = 900.0;
        s.activity_type = 3;
        s.agent_antigravity_enabled = false;
        let text = serde_json::to_string(&s).unwrap();
        let back: Settings = serde_json::from_str(&text).unwrap();
        assert_eq!(back.idle_window_seconds, 900.0);
        assert_eq!(back.activity_type, 3);
        assert!(!back.agent_antigravity_enabled);
    }

    #[test]
    fn missing_fields_use_defaults() {
        let s: Settings = serde_json::from_str(r#"{"presence_enabled":false}"#).unwrap();
        assert!(!s.presence_enabled);
        assert!(s.show_model && s.agent_claude_enabled);
        assert_eq!(s.activity_type, 0);
    }

    #[test]
    fn activity_cycles_allowed_types() {
        let mut s = Settings::default();
        assert_eq!(s.activity_label(), "Playing");
        s.cycle_activity();
        assert_eq!(s.activity_label(), "Listening");
        s.cycle_activity();
        assert_eq!(s.activity_label(), "Watching");
        s.cycle_activity();
        assert_eq!(s.activity_label(), "Competing");
        s.cycle_activity();
        assert_eq!(s.activity_label(), "Playing");
        s.activity_type = 99;
        assert_eq!(s.activity_type(), 0);
    }

    #[test]
    fn idle_minutes_snap_to_steps() {
        let mut s = Settings::default();
        assert_eq!(s.idle_minutes(), 5);
        s.set_idle_minutes(15);
        assert_eq!(s.idle_window_seconds, 900.0);
        assert_eq!(s.idle_minutes(), 15);
        s.idle_window_seconds = 100.0;
        assert_eq!(s.idle_minutes(), 1);
        s.idle_window_seconds = 250.0;
        assert_eq!(s.idle_minutes(), 5);
        s.set_idle_minutes(0);
        assert_eq!(s.idle_label(), "1m");
    }

    #[test]
    fn startup_approved_blob() {
        assert!(is_startup_approved(None));
        assert!(is_startup_approved(Some(&[0x02, 0, 0, 0])));
        assert!(is_startup_approved(Some(&[0x06])));
        assert!(!is_startup_approved(Some(&[0x03])));
        assert!(!is_startup_approved(Some(&[0x07, 0, 0])));
    }
}
