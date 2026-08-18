//! Windows tray icon using the same .ico as the exe / taskbar.

use agentcord_gpui::discord::Client;
use std::mem::size_of;
use std::ptr;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::sync::{Arc, Mutex};

const NIM_ADD: u32 = 0;
const NIM_MODIFY: u32 = 1;
const NIM_DELETE: u32 = 2;
const NIF_MESSAGE: u32 = 0x01;
const NIF_ICON: u32 = 0x02;
const NIF_TIP: u32 = 0x04;
const WM_APP: u32 = 0x8000;
const WM_TRAY: u32 = WM_APP + 1;
const WM_LBUTTONUP: u32 = 0x0202;
const WM_RBUTTONUP: u32 = 0x0205;
const WM_DESTROY: u32 = 0x0002;
const WM_SETICON: u32 = 0x0080;
const ICON_SMALL: usize = 0;
const ICON_BIG: usize = 1;
const SW_SHOW: i32 = 5;
const HWND_MESSAGE: isize = -3;
const CS_HREDRAW: u32 = 0x0002;
const CS_VREDRAW: u32 = 0x0001;

#[repr(C)]
struct NotifyIconDataW {
    cb_size: u32,
    hwnd: isize,
    uid: u32,
    flags: u32,
    callback: u32,
    icon: isize,
    tip: [u16; 128],
    state: u32,
    state_mask: u32,
    info: [u16; 256],
    timeout_or_version: u32,
    info_title: [u16; 64],
    info_flags: u32,
    guid: [u8; 16],
    balloon_icon: isize,
}

#[repr(C)]
struct WndClassW {
    style: u32,
    wnd_proc: Option<unsafe extern "system" fn(isize, u32, usize, isize) -> isize>,
    cls_extra: i32,
    wnd_extra: i32,
    instance: isize,
    icon: isize,
    cursor: isize,
    background: isize,
    menu_name: *const u16,
    class_name: *const u16,
}

extern "system" {
    fn GetModuleHandleW(name: *const u16) -> isize;
    fn GetModuleFileNameW(module: isize, buf: *mut u16, size: u32) -> u32;
    fn ExtractIconExW(
        file: *const u16,
        index: i32,
        large: *mut isize,
        small: *mut isize,
        n: u32,
    ) -> u32;
    fn Shell_NotifyIconW(msg: u32, data: *mut NotifyIconDataW) -> i32;
    fn RegisterClassW(class: *const WndClassW) -> u16;
    fn CreateWindowExW(
        ex: u32,
        class: *const u16,
        name: *const u16,
        style: u32,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        parent: isize,
        menu: isize,
        instance: isize,
        param: *mut core::ffi::c_void,
    ) -> isize;
    fn DefWindowProcW(hwnd: isize, msg: u32, w: usize, l: isize) -> isize;
    fn SetWindowLongPtrW(hwnd: isize, index: i32, value: isize) -> isize;
    fn GetWindowLongPtrW(hwnd: isize, index: i32) -> isize;
    fn CallWindowProcW(prev: isize, hwnd: isize, msg: u32, w: usize, l: isize) -> isize;
    fn SendMessageW(hwnd: isize, msg: u32, w: usize, l: isize) -> isize;
    fn ShowWindow(hwnd: isize, cmd: i32) -> i32;
    fn SetForegroundWindow(hwnd: isize) -> i32;
    fn DestroyWindow(hwnd: isize) -> i32;
    fn DestroyIcon(icon: isize) -> i32;
}

const GWLP_USERDATA: i32 = -21;
const GWLP_WNDPROC: i32 = -4;

static ORIG_WNDPROC: AtomicIsize = AtomicIsize::new(0);
static SESSION_CLIENT: Mutex<Option<Arc<Client>>> = Mutex::new(None);

pub fn hook_session_end(app_hwnd: isize, discord: Arc<Client>) {
    if app_hwnd == 0 {
        return;
    }
    if let Ok(mut g) = SESSION_CLIENT.lock() {
        *g = Some(discord);
    }
    let orig = unsafe {
        SetWindowLongPtrW(app_hwnd, GWLP_WNDPROC, session_proc as *const () as isize)
    };
    ORIG_WNDPROC.store(orig, Ordering::SeqCst);
}

unsafe extern "system" fn session_proc(hwnd: isize, msg: u32, w: usize, l: isize) -> isize {
    const WM_QUERYENDSESSION: u32 = 0x0011;
    const WM_ENDSESSION: u32 = 0x0016;
    if msg == WM_QUERYENDSESSION || (msg == WM_ENDSESSION && w != 0) {
        if let Ok(g) = SESSION_CLIENT.lock() {
            if let Some(client) = g.as_ref() {
                client.disconnect();
            }
        }
    }
    let orig = ORIG_WNDPROC.load(Ordering::SeqCst);
    if orig == 0 {
        DefWindowProcW(hwnd, msg, w, l)
    } else {
        CallWindowProcW(orig, hwnd, msg, w, l)
    }
}

struct TrayState {
    app_hwnd: isize,
}

unsafe extern "system" fn tray_proc(hwnd: isize, msg: u32, w: usize, l: isize) -> isize {
    if msg == WM_TRAY {
        let state = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut TrayState;
        if !state.is_null() {
            let app = (*state).app_hwnd;
            if l as u32 == WM_LBUTTONUP || l as u32 == WM_RBUTTONUP {
                if app != 0 {
                    ShowWindow(app, SW_SHOW);
                    SetForegroundWindow(app);
                }
            }
        }
        return 0;
    }
    if msg == WM_DESTROY {
        let state = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut TrayState;
        if !state.is_null() {
            drop(Box::from_raw(state));
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        }
    }
    DefWindowProcW(hwnd, msg, w, l)
}

pub struct Tray {
    tray_hwnd: isize,
    icon_large: isize,
    icon_small: isize,
}

impl Tray {
    pub fn attach(app_hwnd: isize) -> Option<Self> {
        if app_hwnd == 0 {
            return None;
        }
        let (large, small) = load_exe_icons()?;
        unsafe {
            SendMessageW(app_hwnd, WM_SETICON, ICON_SMALL, small);
            SendMessageW(app_hwnd, WM_SETICON, ICON_BIG, large);
        }

        let class = wide("AgentCordGpuiTray");
        let instance = unsafe { GetModuleHandleW(ptr::null()) };
        let wc = WndClassW {
            style: CS_HREDRAW | CS_VREDRAW,
            wnd_proc: Some(tray_proc),
            cls_extra: 0,
            wnd_extra: 0,
            instance,
            icon: small,
            cursor: 0,
            background: 0,
            menu_name: ptr::null(),
            class_name: class.as_ptr(),
        };
        unsafe { RegisterClassW(&wc) };

        let tray_hwnd = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                class.as_ptr(),
                0,
                0,
                0,
                0,
                0,
                HWND_MESSAGE,
                0,
                instance,
                ptr::null_mut(),
            )
        };
        if tray_hwnd == 0 {
            return None;
        }

        let state = Box::new(TrayState { app_hwnd });
        unsafe {
            SetWindowLongPtrW(tray_hwnd, GWLP_USERDATA, Box::into_raw(state) as isize);
        }

        let mut nid = empty_nid(tray_hwnd, small);
        set_tip(&mut nid, "agentcord");
        let ok = unsafe { Shell_NotifyIconW(NIM_ADD, &mut nid) } != 0;
        if !ok {
            unsafe {
                DestroyWindow(tray_hwnd);
            }
            return None;
        }

        Some(Self {
            tray_hwnd,
            icon_large: large,
            icon_small: small,
        })
    }

    pub fn set_tip(&self, text: &str) {
        let mut nid = empty_nid(self.tray_hwnd, self.icon_small);
        set_tip(&mut nid, text);
        unsafe {
            Shell_NotifyIconW(NIM_MODIFY, &mut nid);
        }
    }
}

impl Drop for Tray {
    fn drop(&mut self) {
        let mut nid = empty_nid(self.tray_hwnd, 0);
        unsafe {
            Shell_NotifyIconW(NIM_DELETE, &mut nid);
            DestroyWindow(self.tray_hwnd);
            if self.icon_large != 0 {
                DestroyIcon(self.icon_large);
            }
            if self.icon_small != 0 && self.icon_small != self.icon_large {
                DestroyIcon(self.icon_small);
            }
        }
    }
}

fn load_exe_icons() -> Option<(isize, isize)> {
    let mut path = [0u16; 520];
    let n = unsafe { GetModuleFileNameW(0, path.as_mut_ptr(), path.len() as u32) };
    if n == 0 {
        return None;
    }
    let mut large = 0isize;
    let mut small = 0isize;
    let count = unsafe { ExtractIconExW(path.as_ptr(), 0, &mut large, &mut small, 1) };
    if count == 0 || (large == 0 && small == 0) {
        return None;
    }
    if small == 0 {
        small = large;
    }
    if large == 0 {
        large = small;
    }
    Some((large, small))
}

fn empty_nid(hwnd: isize, icon: isize) -> NotifyIconDataW {
    NotifyIconDataW {
        cb_size: size_of::<NotifyIconDataW>() as u32,
        hwnd,
        uid: 1,
        flags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
        callback: WM_TRAY,
        icon,
        tip: [0; 128],
        state: 0,
        state_mask: 0,
        info: [0; 256],
        timeout_or_version: 0,
        info_title: [0; 64],
        info_flags: 0,
        guid: [0; 16],
        balloon_icon: 0,
    }
}

fn set_tip(nid: &mut NotifyIconDataW, text: &str) {
    for (i, c) in text.encode_utf16().take(127).enumerate() {
        nid.tip[i] = c;
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}
