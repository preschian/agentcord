//! System-tray UI — the Windows equivalent of the macOS `MenuBarExtra`.
//!
//! Hand-rolled on the raw Win32 API (no tray-icon/winit), matching the macOS
//! app's minimal-dependency stance. We create a hidden message window, register
//! a notification-area icon with `Shell_NotifyIcon`, and show a right/left-click
//! context menu via `TrackPopupMenu`. The presence controller runs on a
//! background thread; this thread owns the Win32 message loop.
//!
//! The menu offers: toggle presence, toggle launch-at-login, open the settings
//! file, and quit. Quitting sets the shared `quit` flag (so the controller
//! clears the presence) and tears down the icon.
//!
//! The icon is the stock application icon for now; embedding a custom `.ico`
//! via a resource is a later refinement.

use std::ffi::c_void;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::thread;

use windows_sys::Win32::Foundation::{HMODULE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{CreateSolidBrush, GetStockObject, DEFAULT_GUI_FONT};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DestroyWindow,
    DispatchMessageW, GetCursorPos, GetDlgItem, GetMessageW, GetSystemMetrics, LoadCursorW,
    LoadIconW, LoadImageW, PostQuitMessage, RegisterClassW, SendMessageW, SetForegroundWindow,
    SetWindowPos, SetWindowTextW, ShowWindow, SystemParametersInfoW, TrackPopupMenu,
    TranslateMessage, BM_SETCHECK, BS_AUTOCHECKBOX, CW_USEDEFAULT,
    HICON, HMENU, HWND_TOPMOST, IDC_ARROW, IDI_APPLICATION, IMAGE_ICON, LR_LOADFROMFILE,
    MF_CHECKED, MF_SEPARATOR, MF_STRING, MSG, SM_CXSMICON, SM_CYSMICON, SPI_GETWORKAREA, SW_HIDE,
    SWP_SHOWWINDOW, TPM_BOTTOMALIGN, TPM_RETURNCMD, TPM_RIGHTBUTTON, WA_INACTIVE, WM_ACTIVATE,
    WM_APP, WM_COMMAND, WM_DESTROY, WM_LBUTTONUP, WM_RBUTTONUP, WM_SETFONT, WNDCLASSW, WS_BORDER,
    WS_CHILD, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_OVERLAPPEDWINDOW, WS_POPUP, WS_VISIBLE,
};

use crate::presence_controller::{PresenceController, SharedState};
use crate::settings::Settings;

/// Custom message Shell_NotifyIcon posts to our window on tray interaction.
const WM_TRAY_CALLBACK: u32 = WM_APP + 1;
const TRAY_ID: u32 = 1;

// Menu command ids.
const ID_TOGGLE_PRESENCE: usize = 1;
const ID_TOGGLE_AUTOSTART: usize = 2;
const ID_OPEN_SETTINGS: usize = 3;
const ID_QUIT: usize = 4;

// Popover control ids.
const ID_LBL_CONN: usize = 201;
const ID_LBL_LINE1: usize = 202;
const ID_LBL_LINE2: usize = 203;
const ID_LBL_USAGE5: usize = 204;
const ID_LBL_USAGEW: usize = 205;
const ID_CHK_PRESENCE: usize = 211;
const ID_CHK_AUTOSTART: usize = 212;
const ID_BTN_SETTINGS: usize = 213;
const ID_BTN_QUIT: usize = 214;

const POPOVER_W: i32 = 300;
const POPOVER_H: i32 = 262;

static SHARED: OnceLock<Arc<SharedState>> = OnceLock::new();

// Window handles, stored as usize so they can live in atomics (HWND is a raw
// pointer and not `Sync`). Only ever used from the UI thread.
static MAIN_HWND: AtomicUsize = AtomicUsize::new(0);
static POPOVER_HWND: AtomicUsize = AtomicUsize::new(0);

/// The app icon (multi-size .ico generated from the macOS app icon), embedded
/// so the binary stays self-contained.
static ICON_BYTES: &[u8] = include_bytes!("../assets/agentcord.ico");

/// Launch the tray app: spawn the presence controller, then run the message
/// loop. Blocks until the user quits.
pub fn run() {
    let shared = Arc::new(SharedState::new(Settings::load()));
    let _ = SHARED.set(Arc::clone(&shared));

    let controller_shared = Arc::clone(&shared);
    thread::spawn(move || PresenceController::new(controller_shared).run());

    // Poll subscription usage in the background; keep the last good value on a
    // failed poll (the numbers move slowly).
    let usage_shared = Arc::clone(&shared);
    thread::spawn(move || loop {
        if let Some(info) = crate::claude_usage::fetch() {
            *usage_shared.usage.lock().unwrap() = Some(info);
        }
        thread::sleep(crate::claude_usage::POLL_INTERVAL);
    });

    unsafe { run_message_loop() };
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

unsafe fn run_message_loop() {
    let hinstance = GetModuleHandleW(std::ptr::null());
    let class_name = wide("AgentCordTray");

    let mut wc: WNDCLASSW = std::mem::zeroed();
    wc.lpfnWndProc = Some(wndproc);
    wc.hInstance = hinstance as _;
    wc.lpszClassName = class_name.as_ptr();
    wc.hCursor = LoadCursorW(std::ptr::null_mut(), IDC_ARROW);
    RegisterClassW(&wc);

    // A normal window that we never show — it just receives messages.
    let hwnd = CreateWindowExW(
        0,
        class_name.as_ptr(),
        wide("AgentCord").as_ptr(),
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        std::ptr::null_mut(),
        std::ptr::null_mut(),
        hinstance as _,
        std::ptr::null(),
    );

    MAIN_HWND.store(hwnd as usize, Ordering::Relaxed);
    add_icon(hwnd);

    let popover = create_popover();
    POPOVER_HWND.store(popover as usize, Ordering::Relaxed);

    let mut msg: MSG = std::mem::zeroed();
    while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_TRAY_CALLBACK => {
            // The mouse event is the low word of lParam. Left click opens the
            // status popover; right click opens the context menu.
            let event = (lparam as u32) & 0xffff;
            if event == WM_LBUTTONUP {
                show_popover();
            } else if event == WM_RBUTTONUP {
                show_menu(hwnd);
            }
            0
        }
        WM_DESTROY => {
            remove_icon(hwnd);
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

unsafe fn show_menu(hwnd: HWND) {
    let hmenu = CreatePopupMenu();
    if hmenu.is_null() {
        return;
    }

    let shared = SHARED.get().expect("SHARED set");
    let presence_on = shared.settings.lock().unwrap().presence_enabled;
    let autostart_on = crate::autostart::is_enabled();

    let check = |on: bool| if on { MF_CHECKED } else { 0 };
    AppendMenuW(hmenu, MF_STRING | check(presence_on), ID_TOGGLE_PRESENCE, wide("Presence enabled").as_ptr());
    AppendMenuW(hmenu, MF_STRING | check(autostart_on), ID_TOGGLE_AUTOSTART, wide("Launch at login").as_ptr());
    AppendMenuW(hmenu, MF_SEPARATOR, 0, std::ptr::null());
    AppendMenuW(hmenu, MF_STRING, ID_OPEN_SETTINGS, wide("Open settings file").as_ptr());
    AppendMenuW(hmenu, MF_SEPARATOR, 0, std::ptr::null());
    AppendMenuW(hmenu, MF_STRING, ID_QUIT, wide("Quit AgentCord").as_ptr());

    let mut pt = POINT { x: 0, y: 0 };
    GetCursorPos(&mut pt);
    // Required so the menu dismisses correctly when focus moves elsewhere.
    SetForegroundWindow(hwnd);
    let cmd = TrackPopupMenu(
        hmenu,
        TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_RETURNCMD,
        pt.x,
        pt.y,
        0,
        hwnd,
        std::ptr::null(),
    );
    DestroyMenu(hmenu);

    if cmd != 0 {
        handle_command(hwnd, cmd as usize);
    }
}

unsafe fn handle_command(hwnd: HWND, id: usize) {
    let shared = SHARED.get().expect("SHARED set");
    match id {
        ID_TOGGLE_PRESENCE => {
            let mut s = shared.settings.lock().unwrap();
            s.presence_enabled = !s.presence_enabled;
            let _ = s.save();
        }
        ID_TOGGLE_AUTOSTART => {
            let now = crate::autostart::is_enabled();
            crate::autostart::set_enabled(!now);
        }
        ID_OPEN_SETTINGS => {
            // Make sure the file exists before opening it.
            {
                let s = shared.settings.lock().unwrap();
                let _ = s.save();
            }
            let path = Settings::config_path();
            let _ = std::process::Command::new("notepad").arg(path).spawn();
        }
        ID_QUIT => {
            shared.quit.store(true, Ordering::Relaxed);
            DestroyWindow(hwnd);
        }
        _ => {}
    }
}

/// Load the tray icon from the embedded `.ico`. We write it to a temp file and
/// use `LoadImageW`, which (unlike `CreateIconFromResource`) handles PNG-encoded
/// icon entries and scales to the small-icon size. Falls back to the stock app
/// icon if anything fails.
unsafe fn load_tray_icon() -> HICON {
    let path = std::env::temp_dir().join("agentcord-tray.ico");
    if std::fs::write(&path, ICON_BYTES).is_ok() {
        if let Some(p) = path.to_str() {
            let wpath = wide(p);
            let icon = LoadImageW(
                std::ptr::null_mut(),
                wpath.as_ptr(),
                IMAGE_ICON,
                GetSystemMetrics(SM_CXSMICON),
                GetSystemMetrics(SM_CYSMICON),
                LR_LOADFROMFILE,
            );
            if !icon.is_null() {
                return icon as HICON;
            }
        }
    }
    LoadIconW(std::ptr::null_mut(), IDI_APPLICATION)
}

unsafe fn add_icon(hwnd: HWND) {
    let mut nid: NOTIFYICONDATAW = std::mem::zeroed();
    nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
    nid.hWnd = hwnd;
    nid.uID = TRAY_ID;
    nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    nid.uCallbackMessage = WM_TRAY_CALLBACK;
    nid.hIcon = load_tray_icon();
    for (i, c) in wide("AgentCord").iter().enumerate().take(nid.szTip.len() - 1) {
        nid.szTip[i] = *c;
    }
    Shell_NotifyIconW(NIM_ADD, &nid);
}

unsafe fn remove_icon(hwnd: HWND) {
    let mut nid: NOTIFYICONDATAW = std::mem::zeroed();
    nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
    nid.hWnd = hwnd;
    nid.uID = TRAY_ID;
    Shell_NotifyIconW(NIM_DELETE, &nid);
}

// MARK: - Status popover

/// Create the (hidden) popover window and its child controls once at startup.
unsafe fn create_popover() -> HWND {
    let hinstance = GetModuleHandleW(std::ptr::null());
    let class_name = wide("AgentCordPopover");

    let mut wc: WNDCLASSW = std::mem::zeroed();
    wc.lpfnWndProc = Some(popover_wndproc);
    wc.hInstance = hinstance as _;
    wc.lpszClassName = class_name.as_ptr();
    wc.hCursor = LoadCursorW(std::ptr::null_mut(), IDC_ARROW);
    wc.hbrBackground = CreateSolidBrush(0x00F3F3F3); // light panel background
    RegisterClassW(&wc);

    let hwnd = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
        class_name.as_ptr(),
        wide("AgentCord").as_ptr(),
        WS_POPUP | WS_BORDER,
        0,
        0,
        POPOVER_W,
        POPOVER_H,
        std::ptr::null_mut(),
        std::ptr::null_mut(),
        hinstance as _,
        std::ptr::null(),
    );

    let font = GetStockObject(DEFAULT_GUI_FONT) as WPARAM;
    let label = |id, text, x, y, w, h| child(hwnd, hinstance, "STATIC", text, 0, id, x, y, w, h, font);

    label(0, "AgentCord", 16, 12, 268, 18);
    label(ID_LBL_CONN, "Discord: —", 16, 38, 268, 18);
    label(ID_LBL_LINE1, "", 16, 58, 268, 18);
    label(ID_LBL_LINE2, "", 16, 78, 268, 18);
    label(ID_LBL_USAGE5, "5-hour: —", 16, 104, 268, 18);
    label(ID_LBL_USAGEW, "Weekly: —", 16, 124, 268, 18);
    child(hwnd, hinstance, "BUTTON", "Presence enabled", BS_AUTOCHECKBOX as u32, ID_CHK_PRESENCE, 16, 152, 268, 22, font);
    child(hwnd, hinstance, "BUTTON", "Launch at login", BS_AUTOCHECKBOX as u32, ID_CHK_AUTOSTART, 16, 178, 268, 22, font);
    child(hwnd, hinstance, "BUTTON", "Open settings", 0, ID_BTN_SETTINGS, 16, 214, 130, 28, font);
    child(hwnd, hinstance, "BUTTON", "Quit", 0, ID_BTN_QUIT, 154, 214, 130, 28, font);

    hwnd
}

#[allow(clippy::too_many_arguments)]
unsafe fn child(
    parent: HWND,
    hinstance: HMODULE,
    class: &str,
    text: &str,
    style: u32,
    id: usize,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    font: WPARAM,
) -> HWND {
    let hwnd = CreateWindowExW(
        0,
        wide(class).as_ptr(),
        wide(text).as_ptr(),
        WS_CHILD | WS_VISIBLE | style,
        x,
        y,
        w,
        h,
        parent,
        id as HMENU,
        hinstance as _,
        std::ptr::null(),
    );
    SendMessageW(hwnd, WM_SETFONT, font, 1);
    hwnd
}

/// Populate the popover from current state, then show it anchored to the
/// bottom-right of the work area (just above the taskbar).
unsafe fn show_popover() {
    let hwnd = POPOVER_HWND.load(Ordering::Relaxed) as HWND;
    if hwnd.is_null() {
        return;
    }
    let shared = SHARED.get().expect("SHARED set");
    let (conn, line1, line2) = {
        let s = shared.status.lock().unwrap();
        (s.connection.clone(), s.line1.clone(), s.line2.clone())
    };
    let presence_on = shared.settings.lock().unwrap().presence_enabled;
    let autostart_on = crate::autostart::is_enabled();
    let (usage5, usagew) = {
        let u = shared.usage.lock().unwrap();
        match u.as_ref() {
            Some(info) => (
                format_usage("5-hour", &info.five_hour),
                format_usage("Weekly", &info.weekly),
            ),
            None => ("5-hour: —".to_string(), "Weekly: —".to_string()),
        }
    };

    let conn = if conn.is_empty() { "—".to_string() } else { conn };
    SetWindowTextW(GetDlgItem(hwnd, ID_LBL_CONN as i32), wide(&format!("Discord: {conn}")).as_ptr());
    SetWindowTextW(GetDlgItem(hwnd, ID_LBL_LINE1 as i32), wide(&line1).as_ptr());
    SetWindowTextW(GetDlgItem(hwnd, ID_LBL_LINE2 as i32), wide(&line2).as_ptr());
    SetWindowTextW(GetDlgItem(hwnd, ID_LBL_USAGE5 as i32), wide(&usage5).as_ptr());
    SetWindowTextW(GetDlgItem(hwnd, ID_LBL_USAGEW as i32), wide(&usagew).as_ptr());
    set_check(GetDlgItem(hwnd, ID_CHK_PRESENCE as i32), presence_on);
    set_check(GetDlgItem(hwnd, ID_CHK_AUTOSTART as i32), autostart_on);

    let wa = work_area();
    let x = wa.right - POPOVER_W - 8;
    let y = wa.bottom - POPOVER_H - 8;
    SetWindowPos(hwnd, HWND_TOPMOST, x, y, POPOVER_W, POPOVER_H, SWP_SHOWWINDOW);
    SetForegroundWindow(hwnd);

    // Pull fresh usage numbers (throttled) so the next open is current.
    let shared = Arc::clone(shared);
    thread::spawn(move || {
        if let Some(info) = crate::claude_usage::fetch_throttled(60) {
            *shared.usage.lock().unwrap() = Some(info);
        }
    });
}

/// "5-hour: 42% · resets in 1h 20m", or just "5-hour: 42%" when no reset time.
fn format_usage(prefix: &str, w: &crate::models::UsageWindow) -> String {
    let mark = if w.is_elevated() { " ⚠" } else { "" };
    match w.resets_at_ms {
        Some(ms) => format!("{prefix}: {}%{mark} · resets {}", w.percent, format_reset(ms)),
        None => format!("{prefix}: {}%{mark}", w.percent),
    }
}

/// Relative reset time — timezone-free, so no local-offset math needed.
fn format_reset(resets_at_ms: i64) -> String {
    let secs = (resets_at_ms - crate::claude_session::now_ms()) / 1000;
    if secs <= 0 {
        return "now".to_string();
    }
    let (m, h, d) = (secs / 60 % 60, secs / 3600 % 24, secs / 86_400);
    if d > 0 {
        format!("in {d}d {h}h")
    } else if h > 0 {
        format!("in {h}h {m}m")
    } else {
        format!("in {m}m")
    }
}

unsafe fn set_check(ctrl: HWND, checked: bool) {
    // BST_CHECKED = 1, BST_UNCHECKED = 0.
    let state: WPARAM = if checked { 1 } else { 0 };
    SendMessageW(ctrl, BM_SETCHECK, state, 0);
}

unsafe fn work_area() -> RECT {
    let mut r = RECT { left: 0, top: 0, right: 0, bottom: 0 };
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &mut r as *mut RECT as *mut c_void, 0);
    r
}

unsafe extern "system" fn popover_wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_COMMAND => {
            handle_popover_command(hwnd, wparam & 0xffff);
            0
        }
        WM_ACTIVATE => {
            // Lost activation (clicked elsewhere) — dismiss, like the macOS popover.
            if (wparam & 0xffff) == WA_INACTIVE as WPARAM {
                ShowWindow(hwnd, SW_HIDE);
            }
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

unsafe fn handle_popover_command(hwnd: HWND, id: WPARAM) {
    let shared = SHARED.get().expect("SHARED set");
    match id {
        ID_CHK_PRESENCE => {
            let mut s = shared.settings.lock().unwrap();
            s.presence_enabled = !s.presence_enabled;
            let _ = s.save();
        }
        ID_CHK_AUTOSTART => {
            let now = crate::autostart::is_enabled();
            crate::autostart::set_enabled(!now);
            // Reflect the actual resulting state (the toggle may have failed).
            set_check(GetDlgItem(hwnd, ID_CHK_AUTOSTART as i32), crate::autostart::is_enabled());
        }
        ID_BTN_SETTINGS => {
            {
                let s = shared.settings.lock().unwrap();
                let _ = s.save();
            }
            let _ = crate::util::command("notepad").arg(Settings::config_path()).spawn();
            ShowWindow(hwnd, SW_HIDE);
        }
        ID_BTN_QUIT => {
            shared.quit.store(true, Ordering::Relaxed);
            let main = MAIN_HWND.load(Ordering::Relaxed) as HWND;
            if !main.is_null() {
                DestroyWindow(main);
            }
        }
        _ => {}
    }
}
