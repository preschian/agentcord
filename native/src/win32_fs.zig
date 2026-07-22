//! Shared Win32 file / env helpers for the native prototype.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const INVALID_HANDLE = windows.INVALID_HANDLE_VALUE;
pub const GENERIC_READ: windows.DWORD = 0x80000000;
pub const GENERIC_WRITE: windows.DWORD = 0x40000000;
pub const FILE_SHARE_READ: windows.DWORD = 0x00000001;
pub const FILE_SHARE_WRITE: windows.DWORD = 0x00000002;
pub const OPEN_EXISTING: windows.DWORD = 3;
pub const FILE_ATTRIBUTE_NORMAL: windows.DWORD = 0x80;

pub extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

pub extern "kernel32" fn ReadFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: windows.DWORD,
    lpNumberOfBytesRead: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn WriteFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: windows.DWORD,
    lpNumberOfBytesWritten: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn GetEnvironmentVariableW(
    lpName: [*:0]const u16,
    lpBuffer: [*]u16,
    nSize: windows.DWORD,
) callconv(.winapi) windows.DWORD;

pub extern "kernel32" fn Sleep(dwMilliseconds: windows.DWORD) callconv(.winapi) void;

pub fn userProfile(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE");
    var wide: [260]u16 = undefined;
    const n = GetEnvironmentVariableW(name, &wide, wide.len);
    if (n == 0 or n >= wide.len) return null;
    const utf8_len = std.unicode.utf16LeToUtf8(buf, wide[0..n]) catch return null;
    return buf[0..utf8_len];
}

pub fn readFile(path: []const u8, buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    var wide: [520]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], path) catch return null;
    wide[wide_len] = 0;

    const handle = CreateFileW(
        wide[0..wide_len :0].ptr,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == INVALID_HANDLE) return null;
    defer windows.CloseHandle(handle);

    var total: usize = 0;
    while (total < buf.len) {
        var n: windows.DWORD = 0;
        if (!ReadFile(handle, buf[total..].ptr, @intCast(buf.len - total), &n, null).toBool()) break;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) return null;
    return buf[0..total];
}
