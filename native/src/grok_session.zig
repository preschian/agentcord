//! Detect the active Grok (xAI) coding session on Windows.
//!
//! Port of macOS `GrokSession.swift` for the native-sdk prototype:
//!   - `~/.grok/active_sessions.json` lists open TUI sessions (session_id, pid, cwd)
//!   - A live PID means the session is active
//!   - `sessions/<url-encoded-cwd>/<session-id>/summary.json` → model, project
//!   - sibling `signals.json` → context token usage

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const INVALID_HANDLE = windows.INVALID_HANDLE_VALUE;
const GENERIC_READ: windows.DWORD = 0x80000000;
const FILE_SHARE_READ: windows.DWORD = 0x00000001;
const FILE_SHARE_WRITE: windows.DWORD = 0x00000002;
const OPEN_EXISTING: windows.DWORD = 3;
const FILE_ATTRIBUTE_NORMAL: windows.DWORD = 0x80;
const PROCESS_QUERY_LIMITED_INFORMATION: windows.DWORD = 0x1000;
const STILL_ACTIVE: windows.DWORD = 259;

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn ReadFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: windows.DWORD,
    lpNumberOfBytesRead: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetEnvironmentVariableW(
    lpName: [*:0]const u16,
    lpBuffer: [*]u16,
    nSize: windows.DWORD,
) callconv(.winapi) windows.DWORD;

extern "kernel32" fn OpenProcess(
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwProcessId: windows.DWORD,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: windows.HANDLE,
    lpExitCode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

/// Snapshot of the most recently opened live Grok session.
pub const SessionInfo = struct {
    project_name: [96]u8 = .{0} ** 96,
    project_len: usize = 0,
    model: [64]u8 = .{0} ** 64,
    model_len: usize = 0,
    start_epoch_ms: i64 = 0,
    total_tokens: i64 = 0,
    session_id: [64]u8 = .{0} ** 64,
    session_id_len: usize = 0,
    cwd: [260]u8 = .{0} ** 260,
    cwd_len: usize = 0,

    pub fn project(self: *const SessionInfo) []const u8 {
        return self.project_name[0..self.project_len];
    }
    pub fn modelName(self: *const SessionInfo) []const u8 {
        return self.model[0..self.model_len];
    }
    pub fn sessionId(self: *const SessionInfo) []const u8 {
        return self.session_id[0..self.session_id_len];
    }
    pub fn cwdPath(self: *const SessionInfo) []const u8 {
        return self.cwd[0..self.cwd_len];
    }

    fn setField(buf: []u8, len: *usize, value: []const u8) void {
        const n = @min(value.len, buf.len);
        @memcpy(buf[0..n], value[0..n]);
        len.* = n;
    }
};

/// Scan `~/.grok` for a live Grok session. Returns null when none is active.
pub fn scan() ?SessionInfo {
    if (builtin.os.tag != .windows) return null;

    var home_buf: [260]u8 = undefined;
    const home = userProfile(&home_buf) orelse return null;

    var path_buf: [512]u8 = undefined;
    const active_path = std.fmt.bufPrint(&path_buf, "{s}\\.grok\\active_sessions.json", .{home}) catch return null;

    var file_buf: [32 * 1024]u8 = undefined;
    const active_json = readFile(active_path, &file_buf) orelse return null;

    // Prefer the last live entry (most recently opened tends to be last in the list).
    var best: ?SessionInfo = null;
    var search_from: usize = 0;
    while (nextObject(active_json, &search_from)) |obj| {
        const sid = extractString(obj, "session_id") orelse continue;
        const cwd_raw = extractString(obj, "cwd") orelse continue;
        var cwd_buf: [260]u8 = undefined;
        const cwd = jsonUnescape(cwd_raw, &cwd_buf) orelse continue;
        const pid = extractI64(obj, "pid") orelse continue;
        if (pid <= 0 or !processIsAlive(@intCast(pid))) continue;

        var info: SessionInfo = .{};
        SessionInfo.setField(&info.session_id, &info.session_id_len, sid);
        SessionInfo.setField(&info.cwd, &info.cwd_len, cwd);

        // opened_at → start timer
        if (extractString(obj, "opened_at")) |opened| {
            info.start_epoch_ms = parseIsoToEpochMs(opened) orelse 0;
        }

        // Enrich from summary + signals when present.
        var summary_path_buf: [700]u8 = undefined;
        if (summaryPath(home, cwd, sid, &summary_path_buf)) |summary_path| {
            var summary_buf: [64 * 1024]u8 = undefined;
            if (readFile(summary_path, &summary_buf)) |summary| {
                if (extractString(summary, "current_model_id")) |model_raw| {
                    var pretty_buf: [64]u8 = undefined;
                    const pretty = prettyModel(model_raw, &pretty_buf);
                    SessionInfo.setField(&info.model, &info.model_len, pretty);
                }
                // Prefer git remote repo name, then summary cwd basename, then active cwd.
                if (extractFirstGitRemoteRepo(summary)) |repo| {
                    SessionInfo.setField(&info.project_name, &info.project_len, repo);
                }
            }
            // signals.json sits next to summary.json
            var signals_path_buf: [700]u8 = undefined;
            if (siblingPath(summary_path, "signals.json", &signals_path_buf)) |signals_path| {
                var signals_buf: [64 * 1024]u8 = undefined;
                if (readFile(signals_path, &signals_buf)) |signals| {
                    if (extractI64(signals, "contextTokensUsed")) |tok| {
                        info.total_tokens = tok;
                    }
                    if (info.model_len == 0) {
                        if (extractString(signals, "primaryModelId")) |model_raw| {
                            var pretty_buf: [64]u8 = undefined;
                            const pretty = prettyModel(model_raw, &pretty_buf);
                            SessionInfo.setField(&info.model, &info.model_len, pretty);
                        }
                    }
                }
            }
        }

        if (info.project_len == 0) {
            const base = basename(cwd);
            SessionInfo.setField(&info.project_name, &info.project_len, if (base.len > 0) base else "Grok");
        }
        if (info.model_len == 0) {
            SessionInfo.setField(&info.model, &info.model_len, "Grok");
        }

        best = info; // last live entry wins
    }
    return best;
}

/// "grok-4.5" → "Grok 4.5"
pub fn prettyModel(raw: []const u8, buf: []u8) []const u8 {
    if (raw.len >= 5 and std.ascii.eqlIgnoreCase(raw[0..5], "grok-")) {
        const rest = raw[5..];
        if (rest.len == 0) return copyLiteral(buf, "Grok");
        if (buf.len < 5 + rest.len) return copyLiteral(buf, "Grok");
        @memcpy(buf[0..5], "Grok ");
        @memcpy(buf[5..][0..rest.len], rest);
        return buf[0 .. 5 + rest.len];
    }
    return copyTo(buf, raw);
}

pub fn formatTokens(count: i64, buf: []u8) []const u8 {
    if (count >= 1_000_000) {
        const v = @as(f64, @floatFromInt(count)) / 1_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.1}M", .{v}) catch "?";
    }
    if (count >= 1_000) {
        const v = @as(f64, @floatFromInt(count)) / 1_000.0;
        return std.fmt.bufPrint(buf, "{d:.1}K", .{v}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}", .{count}) catch "?";
}

// ------------------------------------------------------------------ helpers

fn copyLiteral(buf: []u8, lit: []const u8) []const u8 {
    return copyTo(buf, lit);
}

fn copyTo(buf: []u8, value: []const u8) []const u8 {
    const n = @min(value.len, buf.len);
    @memcpy(buf[0..n], value[0..n]);
    return buf[0..n];
}

fn userProfile(buf: []u8) ?[]const u8 {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE");
    var wide: [260]u16 = undefined;
    const n = GetEnvironmentVariableW(name, &wide, wide.len);
    if (n == 0 or n >= wide.len) return null;
    const utf8_len = std.unicode.utf16LeToUtf8(buf, wide[0..n]) catch return null;
    return buf[0..utf8_len];
}

fn processIsAlive(pid: u32) bool {
    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid);
    if (handle == INVALID_HANDLE) return false;
    defer windows.CloseHandle(handle);
    var code: windows.DWORD = 0;
    if (!GetExitCodeProcess(handle, &code).toBool()) return false;
    return code == STILL_ACTIVE;
}

fn readFile(path: []const u8, buf: []u8) ?[]const u8 {
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

fn summaryPath(home: []const u8, cwd: []const u8, session_id: []const u8, buf: []u8) ?[]const u8 {
    var enc: [400]u8 = undefined;
    const encoded = percentEncode(cwd, &enc) orelse return null;
    return std.fmt.bufPrint(buf, "{s}\\.grok\\sessions\\{s}\\{s}\\summary.json", .{ home, encoded, session_id }) catch null;
}

fn siblingPath(path: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "\\/") orelse return null;
    const dir = path[0..slash];
    return std.fmt.bufPrint(buf, "{s}\\{s}", .{ dir, name }) catch null;
}

fn percentEncode(input: []const u8, out: []u8) ?[]const u8 {
    var i: usize = 0;
    for (input) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            if (i >= out.len) return null;
            out[i] = c;
            i += 1;
        } else {
            if (i + 3 > out.len) return null;
            const hex = "0123456789ABCDEF";
            out[i] = '%';
            out[i + 1] = hex[c >> 4];
            out[i + 2] = hex[c & 0xf];
            i += 3;
        }
    }
    return out[0..i];
}

fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    var end = path.len;
    while (end > 0 and (path[end - 1] == '\\' or path[end - 1] == '/')) end -= 1;
    if (end == 0) return path;
    if (std.mem.lastIndexOfAny(u8, path[0..end], "\\/")) |idx| {
        return path[idx + 1 .. end];
    }
    return path[0..end];
}

/// Walk top-level JSON objects in an array (or bare objects) without a full parser.
fn nextObject(json: []const u8, from: *usize) ?[]const u8 {
    var i = from.*;
    while (i < json.len and json[i] != '{') : (i += 1) {}
    if (i >= json.len) return null;
    const start = i;
    var depth: i32 = 0;
    var in_string = false;
    var escape = false;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        if (in_string) {
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    const end = i + 1;
                    from.* = end;
                    return json[start..end];
                }
            },
            else => {},
        }
    }
    return null;
}

/// Decode a JSON string body (`\\` → `\`, `\"` → `"`, …) into `out`.
fn jsonUnescape(src: []const u8, out: []u8) ?[]const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        if (src[i] == '\\' and i + 1 < src.len) {
            i += 1;
            const mapped: u8 = switch (src[i]) {
                '"', '\\', '/' => src[i],
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => src[i],
            };
            if (o >= out.len) return null;
            out[o] = mapped;
            o += 1;
            i += 1;
        } else {
            if (o >= out.len) return null;
            out[o] = src[i];
            o += 1;
            i += 1;
        }
    }
    return out[0..o];
}

fn extractString(json: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buf: [96]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, json, search_from, pattern)) |key_at| {
        var i = key_at + pattern.len;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
        if (i >= json.len or json[i] != ':') {
            search_from = key_at + 1;
            continue;
        }
        i += 1;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
        if (i >= json.len or json[i] != '"') {
            search_from = key_at + 1;
            continue;
        }
        i += 1;
        const start = i;
        var escape = false;
        while (i < json.len) : (i += 1) {
            if (escape) {
                escape = false;
                continue;
            }
            if (json[i] == '\\') {
                escape = true;
                continue;
            }
            if (json[i] == '"') {
                return json[start..i];
            }
        }
        return null;
    }
    return null;
}

fn extractI64(json: []const u8, key: []const u8) ?i64 {
    var pattern_buf: [96]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;
    const key_at = std.mem.indexOf(u8, json, pattern) orelse return null;
    var i = key_at + pattern.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    if (i >= json.len or json[i] != ':') return null;
    i += 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    const start = i;
    if (i < json.len and json[i] == '-') i += 1;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
    if (i == start or (i == start + 1 and json[start] == '-')) return null;
    return std.fmt.parseInt(i64, json[start..i], 10) catch null;
}

/// Pull the repo name from the first `git_remotes` entry when present.
fn extractFirstGitRemoteRepo(summary: []const u8) ?[]const u8 {
    const key = "\"git_remotes\"";
    const at = std.mem.indexOf(u8, summary, key) orelse return null;
    const slice = summary[at..];
    // Find first string value inside the array.
    const bracket = std.mem.indexOfScalar(u8, slice, '[') orelse return null;
    var i = bracket + 1;
    while (i < slice.len) : (i += 1) {
        if (slice[i] == ']') return null;
        if (slice[i] != '"') continue;
        i += 1;
        const start = i;
        while (i < slice.len and slice[i] != '"') : (i += 1) {}
        if (i >= slice.len) return null;
        const remote = slice[start..i];
        return repoNameFromRemote(remote);
    }
    return null;
}

fn repoNameFromRemote(remote: []const u8) []const u8 {
    // git@github.com:preschian/agentcord.git  or  https://github.com/preschian/agentcord.git
    var base = remote;
    if (std.mem.lastIndexOfAny(u8, remote, "/:")) |idx| {
        base = remote[idx + 1 ..];
    }
    if (std.mem.endsWith(u8, base, ".git")) {
        base = base[0 .. base.len - 4];
    }
    return base;
}

/// Parse ISO-8601 timestamps like `2026-07-22T04:20:53.376422Z` to epoch ms (UTC).
fn parseIsoToEpochMs(iso: []const u8) ?i64 {
    if (iso.len < 20) return null;
    const year = std.fmt.parseInt(i32, iso[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, iso[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u32, iso[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u32, iso[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u32, iso[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u32, iso[17..19], 10) catch return null;
    const days = daysFromCivil(year, month, day) orelse return null;
    const secs = days * 86_400 +
        @as(i64, @intCast(hour)) * 3600 +
        @as(i64, @intCast(minute)) * 60 +
        @as(i64, @intCast(second));
    return secs * 1000;
}

/// Howard Hinnant days-from-civil → Unix day number (days since 1970-01-01).
fn daysFromCivil(year_in: i32, month: u32, day: u32) ?i64 {
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    var year = year_in;
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    year -= @intFromBool(m <= 2);
    const era: i64 = @divFloor(year, 400);
    const yoe: i64 = year - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "prettyModel formats grok ids" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Grok 4.5", prettyModel("grok-4.5", &buf));
    try std.testing.expectEqualStrings("Grok", prettyModel("grok-", &buf));
}

test "formatTokens" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("153.1K", formatTokens(153055, &buf));
    try std.testing.expectEqualStrings("42", formatTokens(42, &buf));
}

test "percentEncode windows path" {
    var buf: [128]u8 = undefined;
    const enc = percentEncode("D:\\Workspace\\agentcord", &buf).?;
    try std.testing.expectEqualStrings("D%3A%5CWorkspace%5Cagentcord", enc);
}

test "extract fields from active session object" {
    // File bytes use JSON escapes: `\\` in source is one backslash in the string value… wait,
    // in a Zig raw string the content is exactly what is on disk.
    const obj =
        \\{"session_id":"019f880e-19ae-75c3-98d9-e6d29feb4b70","pid":20932,"cwd":"D:\\Workspace\\agentcord","opened_at":"2026-07-22T04:20:53.376422Z"}
    ;
    try std.testing.expectEqualStrings("019f880e-19ae-75c3-98d9-e6d29feb4b70", extractString(obj, "session_id").?);
    try std.testing.expectEqual(@as(i64, 20932), extractI64(obj, "pid").?);
    const cwd_raw = extractString(obj, "cwd").?;
    var cwd_buf: [64]u8 = undefined;
    const cwd = jsonUnescape(cwd_raw, &cwd_buf).?;
    try std.testing.expectEqualStrings("D:\\Workspace\\agentcord", cwd);
}

test "parse opened_at to epoch ms" {
    const ms = parseIsoToEpochMs("2026-07-22T04:20:53.376422Z").?;
    // 2026-07-22 04:20:53 UTC
    try std.testing.expect(ms > 1_700_000_000_000);
    try std.testing.expectEqual(@as(i64, 53) * 1000, @rem(ms, 60_000));
}

test "repo name from remote" {
    try std.testing.expectEqualStrings("agentcord", repoNameFromRemote("git@github.com:preschian/agentcord.git"));
    try std.testing.expectEqualStrings("agentcord", repoNameFromRemote("https://github.com/preschian/agentcord.git"));
}
