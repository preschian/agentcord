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
const win32_fs = @import("win32_fs.zig");
const json_lite = @import("json_lite.zig");

const PROCESS_QUERY_LIMITED_INFORMATION: windows.DWORD = 0x1000;
const STILL_ACTIVE: windows.DWORD = 259;

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
    /// Best-effort last activity (summary/signals mtime, else start). Used for multi-agent winner.
    activity_ms: i64 = 0,
    total_tokens: i64 = 0,
    /// Context window fill percent from signals.json (`contextWindowUsage`).
    context_percent: i64 = -1,
    context_window_tokens: i64 = 0,
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

    pub fn setField(buf: []u8, len: *usize, value: []const u8) void {
        win32_fs.copyBounded(buf, len, value);
    }
};

/// Scan `~/.grok` for a live Grok session. Returns null when none is active.
pub fn scan() ?SessionInfo {
    if (builtin.os.tag != .windows) return null;

    var home_buf: [260]u8 = undefined;
    const home = win32_fs.userProfile(&home_buf) orelse return null;

    var path_buf: [512]u8 = undefined;
    const active_path = std.fmt.bufPrint(&path_buf, "{s}\\.grok\\active_sessions.json", .{home}) catch return null;

    var file_buf: [32 * 1024]u8 = undefined;
    const active_json = win32_fs.readFile(active_path, &file_buf) orelse return null;

    // Prefer the last live entry (most recently opened tends to be last in the list).
    var best: ?SessionInfo = null;
    var search_from: usize = 0;
    while (json_lite.nextObject(active_json, &search_from)) |obj| {
        const sid = json_lite.extractString(obj, "session_id") orelse continue;
        const cwd_raw = json_lite.extractString(obj, "cwd") orelse continue;
        var cwd_buf: [260]u8 = undefined;
        const cwd = json_lite.jsonUnescape(cwd_raw, &cwd_buf) orelse continue;
        const pid = json_lite.extractI64(obj, "pid") orelse continue;
        if (pid <= 0 or !processIsAlive(@intCast(pid))) continue;

        var info: SessionInfo = .{};
        SessionInfo.setField(&info.session_id, &info.session_id_len, sid);
        SessionInfo.setField(&info.cwd, &info.cwd_len, cwd);

        if (json_lite.extractString(obj, "opened_at")) |opened| {
            info.start_epoch_ms = parseIsoToEpochMs(opened) orelse 0;
            info.activity_ms = info.start_epoch_ms;
        }

        var summary_path_buf: [700]u8 = undefined;
        if (summaryPath(home, cwd, sid, &summary_path_buf)) |summary_path| {
            if (win32_fs.fileMtimeMs(summary_path)) |mtime| {
                if (mtime > info.activity_ms) info.activity_ms = mtime;
            }
            var summary_buf: [64 * 1024]u8 = undefined;
            if (win32_fs.readFile(summary_path, &summary_buf)) |summary| {
                if (json_lite.extractString(summary, "current_model_id")) |model_raw| {
                    var pretty_buf: [64]u8 = undefined;
                    const pretty = prettyModel(model_raw, &pretty_buf);
                    SessionInfo.setField(&info.model, &info.model_len, pretty);
                }
                if (extractFirstGitRemoteRepo(summary)) |repo| {
                    SessionInfo.setField(&info.project_name, &info.project_len, repo);
                }
            }
            var signals_path_buf: [700]u8 = undefined;
            if (siblingPath(summary_path, "signals.json", &signals_path_buf)) |signals_path| {
                if (win32_fs.fileMtimeMs(signals_path)) |mtime| {
                    if (mtime > info.activity_ms) info.activity_ms = mtime;
                }
                var signals_buf: [64 * 1024]u8 = undefined;
                if (win32_fs.readFile(signals_path, &signals_buf)) |signals| {
                    if (json_lite.extractI64(signals, "contextTokensUsed")) |tok| {
                        info.total_tokens = tok;
                    }
                    if (json_lite.extractI64(signals, "contextWindowTokens")) |win| {
                        info.context_window_tokens = win;
                    }
                    if (json_lite.extractI64(signals, "contextWindowUsage")) |pct| {
                        info.context_percent = pct;
                    } else if (info.total_tokens > 0 and info.context_window_tokens > 0) {
                        info.context_percent = @divTrunc(info.total_tokens * 100, info.context_window_tokens);
                    }
                    if (info.model_len == 0) {
                        if (json_lite.extractString(signals, "primaryModelId")) |model_raw| {
                            var pretty_buf: [64]u8 = undefined;
                            const pretty = prettyModel(model_raw, &pretty_buf);
                            SessionInfo.setField(&info.model, &info.model_len, pretty);
                        }
                    }
                }
            }
        }

        if (info.project_len == 0) {
            const base = win32_fs.basename(cwd);
            SessionInfo.setField(&info.project_name, &info.project_len, if (base.len > 0) base else "Grok");
        }
        if (info.model_len == 0) {
            SessionInfo.setField(&info.model, &info.model_len, "Grok");
        }

        best = info;
    }
    return best;
}

/// "grok-4.5" → "Grok 4.5"
pub fn prettyModel(raw: []const u8, buf: []u8) []const u8 {
    if (raw.len >= 5 and std.ascii.eqlIgnoreCase(raw[0..5], "grok-")) {
        const rest = raw[5..];
        if (rest.len == 0) return copyTo(buf, "Grok");
        if (buf.len < 5 + rest.len) return copyTo(buf, "Grok");
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

fn copyTo(buf: []u8, value: []const u8) []const u8 {
    const n = @min(value.len, buf.len);
    @memcpy(buf[0..n], value[0..n]);
    return buf[0..n];
}

fn processIsAlive(pid: u32) bool {
    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid);
    if (handle == win32_fs.INVALID_HANDLE) return false;
    defer windows.CloseHandle(handle);
    var code: windows.DWORD = 0;
    if (!GetExitCodeProcess(handle, &code).toBool()) return false;
    return code == STILL_ACTIVE;
}

fn summaryPath(home: []const u8, cwd: []const u8, session_id: []const u8, buf: []u8) ?[]const u8 {
    var enc: [400]u8 = undefined;
    const encoded = json_lite.percentEncode(cwd, &enc) orelse return null;
    return std.fmt.bufPrint(buf, "{s}\\.grok\\sessions\\{s}\\{s}\\summary.json", .{ home, encoded, session_id }) catch null;
}

fn siblingPath(path: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "\\/") orelse return null;
    const dir = path[0..slash];
    return std.fmt.bufPrint(buf, "{s}\\{s}", .{ dir, name }) catch null;
}

fn extractFirstGitRemoteRepo(summary: []const u8) ?[]const u8 {
    const key = "\"git_remotes\"";
    const at = std.mem.indexOf(u8, summary, key) orelse return null;
    const slice = summary[at..];
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
pub fn parseIsoToEpochMs(iso: []const u8) ?i64 {
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

test "extract fields from active session object" {
    const obj =
        \\{"session_id":"019f880e-19ae-75c3-98d9-e6d29feb4b70","pid":20932,"cwd":"D:\\Workspace\\agentcord","opened_at":"2026-07-22T04:20:53.376422Z"}
    ;
    try std.testing.expectEqualStrings("019f880e-19ae-75c3-98d9-e6d29feb4b70", json_lite.extractString(obj, "session_id").?);
    try std.testing.expectEqual(@as(i64, 20932), json_lite.extractI64(obj, "pid").?);
    const cwd_raw = json_lite.extractString(obj, "cwd").?;
    var cwd_buf: [64]u8 = undefined;
    const cwd = json_lite.jsonUnescape(cwd_raw, &cwd_buf).?;
    try std.testing.expectEqualStrings("D:\\Workspace\\agentcord", cwd);
}

test "parse opened_at to epoch ms" {
    const ms = parseIsoToEpochMs("2026-07-22T04:20:53.376422Z").?;
    try std.testing.expect(ms > 1_700_000_000_000);
    try std.testing.expectEqual(@as(i64, 53) * 1000, @rem(ms, 60_000));
}

test "repo name from remote" {
    try std.testing.expectEqualStrings("agentcord", repoNameFromRemote("git@github.com:preschian/agentcord.git"));
    try std.testing.expectEqualStrings("agentcord", repoNameFromRemote("https://github.com/preschian/agentcord.git"));
}
