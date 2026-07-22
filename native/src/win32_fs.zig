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

pub const FILE_ATTRIBUTE_DIRECTORY: windows.DWORD = 0x10;
pub const INVALID_FILE_ATTRIBUTES: windows.DWORD = 0xFFFFFFFF;

const FILETIME = extern struct {
    dwLowDateTime: windows.DWORD,
    dwHighDateTime: windows.DWORD,
};

const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: windows.DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: windows.DWORD,
    nFileSizeLow: windows.DWORD,
    dwReserved0: windows.DWORD,
    dwReserved1: windows.DWORD,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

pub extern "kernel32" fn GetFileAttributesW(
    lpFileName: [*:0]const u16,
) callconv(.winapi) windows.DWORD;

pub extern "kernel32" fn FindFirstFileW(
    lpFileName: [*:0]const u16,
    lpFindFileData: *WIN32_FIND_DATAW,
) callconv(.winapi) windows.HANDLE;

pub extern "kernel32" fn FindNextFileW(
    hFindFile: windows.HANDLE,
    lpFindFileData: *WIN32_FIND_DATAW,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn FindClose(
    hFindFile: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn GetFileTime(
    hFile: windows.HANDLE,
    lpCreationTime: ?*FILETIME,
    lpLastAccessTime: ?*FILETIME,
    lpLastWriteTime: ?*FILETIME,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn GetSystemTimeAsFileTime(
    lpSystemTimeAsFileTime: *FILETIME,
) callconv(.winapi) void;

pub extern "kernel32" fn CreatePipe(
    hReadPipe: *windows.HANDLE,
    hWritePipe: *windows.HANDLE,
    lpPipeAttributes: ?*SECURITY_ATTRIBUTES,
    nSize: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn SetHandleInformation(
    hObject: windows.HANDLE,
    dwMask: windows.DWORD,
    dwFlags: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: windows.BOOL,
    dwCreationFlags: windows.DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn WaitForSingleObject(
    hHandle: windows.HANDLE,
    dwMilliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;

pub extern "kernel32" fn GetExitCodeProcess(
    hProcess: windows.HANDLE,
    lpExitCode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn TerminateProcess(
    hProcess: windows.HANDLE,
    uExitCode: windows.UINT,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn SearchPathW(
    lpPath: ?[*:0]const u16,
    lpFileName: [*:0]const u16,
    lpExtension: ?[*:0]const u16,
    nBufferLength: windows.DWORD,
    lpBuffer: [*]u16,
    lpFilePart: ?*?[*:0]u16,
) callconv(.winapi) windows.DWORD;

const HANDLE_FLAG_INHERIT: windows.DWORD = 0x00000001;
const CREATE_NO_WINDOW: windows.DWORD = 0x08000000;
const STARTF_USESTDHANDLES: windows.DWORD = 0x00000100;
const WAIT_OBJECT_0: windows.DWORD = 0;
const WAIT_TIMEOUT: windows.DWORD = 0x00000102;

const SECURITY_ATTRIBUTES = extern struct {
    nLength: windows.DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: windows.BOOL,
};

const STARTUPINFOW = extern struct {
    cb: windows.DWORD,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: windows.DWORD = 0,
    dwY: windows.DWORD = 0,
    dwXSize: windows.DWORD = 0,
    dwYSize: windows.DWORD = 0,
    dwXCountChars: windows.DWORD = 0,
    dwYCountChars: windows.DWORD = 0,
    dwFillAttribute: windows.DWORD = 0,
    dwFlags: windows.DWORD = 0,
    wShowWindow: windows.WORD = 0,
    cbReserved2: windows.WORD = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?windows.HANDLE = null,
    hStdOutput: ?windows.HANDLE = null,
    hStdError: ?windows.HANDLE = null,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: windows.HANDLE,
    hThread: windows.HANDLE,
    dwProcessId: windows.DWORD,
    dwThreadId: windows.DWORD,
};

/// Resolve `name` (e.g. `sqlite3.exe`) on PATH into `out` as UTF-8. Returns null if missing.
pub fn searchPath(name: []const u8, out: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    var name_wide: [260]u16 = undefined;
    const name_len = std.unicode.utf8ToUtf16Le(name_wide[0 .. name_wide.len - 1], name) catch return null;
    name_wide[name_len] = 0;
    var found: [520]u16 = undefined;
    const n = SearchPathW(null, name_wide[0..name_len :0].ptr, null, found.len, &found, null);
    if (n == 0 or n >= found.len) return null;
    const utf8_len = std.unicode.utf16LeToUtf8(out, found[0..n]) catch return null;
    return out[0..utf8_len];
}

/// Run `argv[0..]` (argv[0] = exe path or name), capture stdout into `out` (truncated).
/// Returns stdout slice on exit code 0; null on spawn/timeout/nonzero exit.
pub fn runCapture(argv: []const []const u8, out: []u8, timeout_ms: u32) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    if (argv.len == 0 or out.len == 0) return null;

    var cmdline_utf8: [4096]u8 = undefined;
    var cmdline_len: usize = 0;
    for (argv, 0..) |arg, i| {
        if (i > 0) {
            if (cmdline_len >= cmdline_utf8.len) return null;
            cmdline_utf8[cmdline_len] = ' ';
            cmdline_len += 1;
        }
        const quoted = quoteArg(arg, cmdline_utf8[cmdline_len..]) orelse return null;
        cmdline_len += quoted.len;
    }
    var cmdline_wide: [4096]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(cmdline_wide[0 .. cmdline_wide.len - 1], cmdline_utf8[0..cmdline_len]) catch return null;
    cmdline_wide[wide_len] = 0;

    var sa = SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = windows.BOOL.TRUE,
    };
    var read_pipe: windows.HANDLE = undefined;
    var write_pipe: windows.HANDLE = undefined;
    if (!CreatePipe(&read_pipe, &write_pipe, &sa, 0).toBool()) return null;
    // Parent keeps read; child inherits write. Clear inherit on read end.
    _ = SetHandleInformation(read_pipe, HANDLE_FLAG_INHERIT, 0);

    var si = STARTUPINFOW{
        .cb = @sizeOf(STARTUPINFOW),
        .dwFlags = STARTF_USESTDHANDLES,
        .hStdInput = null,
        .hStdOutput = write_pipe,
        .hStdError = write_pipe,
    };
    var pi: PROCESS_INFORMATION = undefined;
    const ok = CreateProcessW(
        null,
        cmdline_wide[0..wide_len :0].ptr,
        null,
        null,
        windows.BOOL.TRUE,
        CREATE_NO_WINDOW,
        null,
        null,
        &si,
        &pi,
    );
    windows.CloseHandle(write_pipe);
    if (!ok.toBool()) {
        windows.CloseHandle(read_pipe);
        return null;
    }
    defer {
        windows.CloseHandle(pi.hThread);
        windows.CloseHandle(pi.hProcess);
        windows.CloseHandle(read_pipe);
    }

    var total: usize = 0;
    while (total < out.len) {
        var n: windows.DWORD = 0;
        if (!ReadFile(read_pipe, out[total..].ptr, @intCast(out.len - total), &n, null).toBool()) break;
        if (n == 0) break;
        total += n;
    }

    const wait = WaitForSingleObject(pi.hProcess, timeout_ms);
    if (wait == WAIT_TIMEOUT) {
        _ = TerminateProcess(pi.hProcess, 1);
        return null;
    }
    if (wait != WAIT_OBJECT_0) return null;
    var code: windows.DWORD = 1;
    _ = GetExitCodeProcess(pi.hProcess, &code);
    if (code != 0 or total == 0) return null;
    // Trim trailing whitespace / newlines from sqlite3 output.
    while (total > 0 and (out[total - 1] == '\n' or out[total - 1] == '\r' or out[total - 1] == ' ' or out[total - 1] == '\t')) {
        total -= 1;
    }
    if (total == 0) return null;
    return out[0..total];
}

/// Run a short-lived JSONL-style command, supplying stdin and capturing stdout.
/// Used for local protocol clients such as `codex app-server`; credentials stay
/// with the tool process and never enter AgentCord's model or cache.
pub fn runCaptureWithInput(
    argv: []const []const u8,
    input: []const u8,
    out: []u8,
    timeout_ms: u32,
) ?[]const u8 {
    if (builtin.os.tag != .windows or argv.len == 0 or out.len == 0) return null;

    var cmdline_utf8: [4096]u8 = undefined;
    var cmdline_len: usize = 0;
    for (argv, 0..) |arg, i| {
        if (i > 0) {
            if (cmdline_len >= cmdline_utf8.len) return null;
            cmdline_utf8[cmdline_len] = ' ';
            cmdline_len += 1;
        }
        const quoted = quoteArg(arg, cmdline_utf8[cmdline_len..]) orelse return null;
        cmdline_len += quoted.len;
    }
    var cmdline_wide: [4096]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(cmdline_wide[0 .. cmdline_wide.len - 1], cmdline_utf8[0..cmdline_len]) catch return null;
    cmdline_wide[wide_len] = 0;

    var sa = SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = windows.BOOL.TRUE,
    };
    var stdin_read: windows.HANDLE = undefined;
    var stdin_write: windows.HANDLE = undefined;
    var stdout_read: windows.HANDLE = undefined;
    var stdout_write: windows.HANDLE = undefined;
    if (!CreatePipe(&stdin_read, &stdin_write, &sa, 0).toBool()) return null;
    errdefer windows.CloseHandle(stdin_read);
    errdefer windows.CloseHandle(stdin_write);
    if (!SetHandleInformation(stdin_write, HANDLE_FLAG_INHERIT, 0).toBool()) return null;
    if (!CreatePipe(&stdout_read, &stdout_write, &sa, 0).toBool()) return null;
    errdefer windows.CloseHandle(stdout_read);
    errdefer windows.CloseHandle(stdout_write);
    if (!SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0).toBool()) return null;

    var si = STARTUPINFOW{
        .cb = @sizeOf(STARTUPINFOW),
        .dwFlags = STARTF_USESTDHANDLES,
        .hStdInput = stdin_read,
        .hStdOutput = stdout_write,
        .hStdError = stdout_write,
    };
    var pi: PROCESS_INFORMATION = undefined;
    const started = CreateProcessW(null, cmdline_wide[0..wide_len :0].ptr, null, null, windows.BOOL.TRUE, CREATE_NO_WINDOW, null, null, &si, &pi);
    windows.CloseHandle(stdin_read);
    windows.CloseHandle(stdout_write);
    if (!started.toBool()) {
        windows.CloseHandle(stdin_write);
        windows.CloseHandle(stdout_read);
        return null;
    }
    defer {
        windows.CloseHandle(pi.hThread);
        windows.CloseHandle(pi.hProcess);
        windows.CloseHandle(stdout_read);
    }

    var written: windows.DWORD = 0;
    if (input.len > 0 and !WriteFile(stdin_write, input.ptr, @intCast(input.len), &written, null).toBool()) {
        windows.CloseHandle(stdin_write);
        _ = TerminateProcess(pi.hProcess, 1);
        return null;
    }
    windows.CloseHandle(stdin_write); // EOF tells app-server no more requests are coming.

    var total: usize = 0;
    while (total < out.len) {
        var n: windows.DWORD = 0;
        if (!ReadFile(stdout_read, out[total..].ptr, @intCast(out.len - total), &n, null).toBool()) break;
        if (n == 0) break;
        total += n;
    }
    const wait = WaitForSingleObject(pi.hProcess, timeout_ms);
    if (wait == WAIT_TIMEOUT) {
        _ = TerminateProcess(pi.hProcess, 1);
        return null;
    }
    if (wait != WAIT_OBJECT_0) return null;
    var code: windows.DWORD = 1;
    _ = GetExitCodeProcess(pi.hProcess, &code);
    if (code != 0 or total == 0) return null;
    return out[0..total];
}

fn quoteArg(arg: []const u8, buf: []u8) ?[]const u8 {
    // Always quote — safe for paths with spaces.
    if (buf.len < arg.len + 2) return null;
    buf[0] = '"';
    @memcpy(buf[1 .. 1 + arg.len], arg);
    buf[1 + arg.len] = '"';
    return buf[0 .. arg.len + 2];
}

/// UTF-8 path → null-terminated UTF-16 into `wide` (must hold path + NUL).
pub fn pathToWide(path: []const u8, wide: []u16) ?[:0]u16 {
    if (wide.len < 2) return null;
    const n = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], path) catch return null;
    wide[n] = 0;
    return wide[0..n :0];
}

pub fn pathExists(path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    var wide: [520]u16 = undefined;
    const w = pathToWide(path, &wide) orelse return false;
    return GetFileAttributesW(w.ptr) != INVALID_FILE_ATTRIBUTES;
}

pub fn isDirectory(path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    var wide: [520]u16 = undefined;
    const w = pathToWide(path, &wide) orelse return false;
    const attrs = GetFileAttributesW(w.ptr);
    if (attrs == INVALID_FILE_ATTRIBUTES) return false;
    return (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

/// Last-write time as Unix epoch milliseconds, or null if unavailable.
pub fn fileMtimeMs(path: []const u8) ?i64 {
    if (builtin.os.tag != .windows) return null;
    var wide: [520]u16 = undefined;
    const w = pathToWide(path, &wide) orelse return null;
    const handle = CreateFileW(
        w.ptr,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == INVALID_HANDLE) return null;
    defer windows.CloseHandle(handle);
    var ft: FILETIME = undefined;
    if (!GetFileTime(handle, null, null, &ft).toBool()) return null;
    return fileTimeToEpochMs(ft);
}

fn fileTimeToEpochMs(ft: FILETIME) i64 {
    const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    const epoch_diff: u64 = 11_644_473_600_000_000_000;
    if (ticks < epoch_diff) return 0;
    return @intCast((ticks - epoch_diff) / 10_000);
}

/// Current UTC wall clock as Unix epoch milliseconds (Zig 0.16: no std.time.milliTimestamp).
pub fn nowEpochMs() i64 {
    if (builtin.os.tag != .windows) return 0;
    var ft: FILETIME = undefined;
    GetSystemTimeAsFileTime(&ft);
    return fileTimeToEpochMs(ft);
}

pub const DirEntryKind = enum { file, directory };

pub const DirEntry = struct {
    name: []const u8,
    kind: DirEntryKind,
};

/// Iterate immediate children of `dir` (not recursive). Calls `cb` for each entry
/// except `.` / `..`. `name_buf` holds the UTF-8 name for the duration of each call.
pub fn forEachChild(
    dir: []const u8,
    name_buf: []u8,
    context: anytype,
    comptime cb: *const fn (@TypeOf(context), entry: DirEntry) void,
) void {
    if (builtin.os.tag != .windows) return;
    var pattern_buf: [600]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "{s}\\*", .{dir}) catch return;
    var wide: [620]u16 = undefined;
    const w = pathToWide(pattern, &wide) orelse return;

    var data: WIN32_FIND_DATAW = undefined;
    const find = FindFirstFileW(w.ptr, &data);
    if (find == INVALID_HANDLE) return;
    defer _ = FindClose(find);

    while (true) {
        const name_len = std.unicode.utf16LeToUtf8(name_buf, std.mem.sliceTo(&data.cFileName, 0)) catch {
            if (!FindNextFileW(find, &data).toBool()) break;
            continue;
        };
        const name = name_buf[0..name_len];
        if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
            const kind: DirEntryKind = if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
                .directory
            else
                .file;
            cb(context, .{ .name = name, .kind = kind });
        }
        if (!FindNextFileW(find, &data).toBool()) break;
    }
}

pub fn userProfile(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE");
    var wide: [260]u16 = undefined;
    const n = GetEnvironmentVariableW(name, &wide, wide.len);
    if (n == 0 or n >= wide.len) return null;
    const utf8_len = std.unicode.utf16LeToUtf8(buf, wide[0..n]) catch return null;
    return buf[0..utf8_len];
}

pub fn appData(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("APPDATA");
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

/// Copy `value` into `buf`, clamping to capacity. Writes length into `len`.
pub fn copyBounded(buf: []u8, len: *usize, value: []const u8) void {
    const n = @min(value.len, buf.len);
    @memcpy(buf[0..n], value[0..n]);
    len.* = n;
}

/// Final path component (handles `\` and `/`).
pub fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    var end = path.len;
    while (end > 0 and (path[end - 1] == '\\' or path[end - 1] == '/')) end -= 1;
    if (end == 0) return path;
    if (std.mem.lastIndexOfAny(u8, path[0..end], "\\/")) |idx| {
        return path[idx + 1 .. end];
    }
    return path[0..end];
}

/// Recursively visit files under `root` (depth-limited). No per-directory entry cap.
pub fn walkFiles(
    root: []const u8,
    max_depth: u8,
    context: anytype,
    comptime on_file: *const fn (@TypeOf(context), path: []const u8) void,
) void {
    if (builtin.os.tag != .windows) return;
    walkFilesRec(root, 0, max_depth, context, on_file);
}

fn walkFilesRec(
    dir: []const u8,
    depth: u8,
    max_depth: u8,
    context: anytype,
    comptime on_file: *const fn (@TypeOf(context), path: []const u8) void,
) void {
    if (depth > max_depth) return;
    var name_buf: [260]u8 = undefined;
    const Ctx = struct {
        dir: []const u8,
        depth: u8,
        max_depth: u8,
        parent_ctx: @TypeOf(context),
        fn onEntry(self: @This(), entry: DirEntry) void {
            var path_buf: [700]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ self.dir, entry.name }) catch return;
            if (entry.kind == .directory) {
                walkFilesRec(path, self.depth + 1, self.max_depth, self.parent_ctx, on_file);
            } else {
                on_file(self.parent_ctx, path);
            }
        }
    };
    forEachChild(dir, &name_buf, Ctx{
        .dir = dir,
        .depth = depth,
        .max_depth = max_depth,
        .parent_ctx = context,
    }, Ctx.onEntry);
}
