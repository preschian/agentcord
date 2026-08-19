//! HWND helpers for the popover (hide / drag).

extern "system" {
    fn GetActiveWindow() -> isize;
    fn ReleaseCapture() -> i32;
    fn ShowWindow(hwnd: isize, cmd: i32) -> i32;
    fn PostMessageW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> i32;
}

const WM_SYSCOMMAND: u32 = 0x0112;
const SC_MOVE: usize = 0xF010;
const HTCAPTION: usize = 2;
const SW_HIDE: i32 = 0;

pub fn active_hwnd() -> isize {
    unsafe { GetActiveWindow() }
}

pub fn hide(hwnd: isize) {
    if hwnd != 0 {
        unsafe {
            ShowWindow(hwnd, SW_HIDE);
        }
    }
}

pub fn start_move(hwnd: isize) {
    if hwnd == 0 {
        return;
    }
    unsafe {
        ReleaseCapture();
        PostMessageW(hwnd, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
    }
}
