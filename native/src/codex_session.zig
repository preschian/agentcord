//! Detect the most recently active Codex CLI transcript on Windows.
//!
//! Codex owns its own authentication and transcript format.  We only read the
//! public local session records under `%USERPROFILE%\.codex\sessions` and use
//! their modification time as the active-session clock.

const std = @import("std");
const builtin = @import("builtin");
const win32_fs = @import("win32_fs.zig");
const json_lite = @import("json_lite.zig");

pub const default_active_window_ms: i64 = 5 * 60 * 1000;

pub const SessionInfo = struct {
    project_name: [96]u8 = .{0} ** 96,
    project_len: usize = 0,
    model: [64]u8 = .{0} ** 64,
    model_len: usize = 0,
    start_epoch_ms: i64 = 0,
    activity_ms: i64 = 0,
    total_tokens: i64 = 0,
    cwd: [260]u8 = .{0} ** 260,
    cwd_len: usize = 0,

    pub fn project(self: *const SessionInfo) []const u8 {
        return self.project_name[0..self.project_len];
    }
    pub fn modelName(self: *const SessionInfo) []const u8 {
        return self.model[0..self.model_len];
    }
    pub fn setField(buf: []u8, len: *usize, value: []const u8) void {
        win32_fs.copyBounded(buf, len, value);
    }
};

pub fn isInstalled() bool {
    if (builtin.os.tag != .windows) return false;
    var exe: [520]u8 = undefined;
    if (win32_fs.searchPath("codex.exe", &exe) != null or win32_fs.searchPath("codex", &exe) != null) return true;
    var home_buf: [260]u8 = undefined;
    const home = win32_fs.userProfile(&home_buf) orelse return false;
    var sessions_buf: [360]u8 = undefined;
    const sessions = std.fmt.bufPrint(&sessions_buf, "{s}\\.codex\\sessions", .{home}) catch return false;
    return win32_fs.isDirectory(sessions);
}

pub fn scan() ?SessionInfo {
    return scanWithWindow(default_active_window_ms, win32_fs.nowEpochMs());
}

pub fn scanWithWindow(active_window_ms: i64, now_ms: i64) ?SessionInfo {
    if (builtin.os.tag != .windows) return null;
    var home_buf: [260]u8 = undefined;
    const home = win32_fs.userProfile(&home_buf) orelse return null;
    var sessions_buf: [360]u8 = undefined;
    const sessions = std.fmt.bufPrint(&sessions_buf, "{s}\\.codex\\sessions", .{home}) catch return null;
    if (!win32_fs.isDirectory(sessions)) return null;

    var newest_path: [700]u8 = undefined;
    var newest_len: usize = 0;
    var newest_mtime: i64 = 0;
    var walk = FindNewest{ .path = &newest_path, .len = &newest_len, .mtime = &newest_mtime };
    win32_fs.walkFiles(sessions, 8, &walk, FindNewest.onFile);
    if (newest_len == 0 or now_ms - newest_mtime > active_window_ms) return null;

    var info: SessionInfo = .{};
    info.activity_ms = newest_mtime;
    info.start_epoch_ms = newest_mtime;
    applyTranscript(newest_path[0..newest_len], &info);
    if (info.project_len == 0) {
        SessionInfo.setField(&info.project_name, &info.project_len, "Codex");
    }
    if (info.model_len == 0) {
        SessionInfo.setField(&info.model, &info.model_len, "Codex");
    }
    return info;
}

const FindNewest = struct {
    path: []u8,
    len: *usize,
    mtime: *i64,

    fn onFile(self: *@This(), path: []const u8) void {
        if (!std.mem.endsWith(u8, path, ".jsonl")) return;
        const mtime = win32_fs.fileMtimeMs(path) orelse return;
        if (self.len.* > 0 and mtime <= self.mtime.*) return;
        const n = @min(path.len, self.path.len);
        @memcpy(self.path[0..n], path[0..n]);
        self.len.* = n;
        self.mtime.* = mtime;
    }
};

fn applyTranscript(path: []const u8, info: *SessionInfo) void {
    // The tail contains the freshest context and token-count event.  A bounded
    // read also prevents a long coding history from stalling the UI thread.
    var bytes: [256 * 1024]u8 = undefined;
    const text = win32_fs.readFile(path, &bytes) orelse return;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (json_lite.extractString(line, "cwd")) |cwd_raw| {
            var cwd_buf: [260]u8 = undefined;
            if (json_lite.jsonUnescape(cwd_raw, &cwd_buf)) |cwd| {
                SessionInfo.setField(&info.cwd, &info.cwd_len, cwd);
                const project = win32_fs.basename(cwd);
                if (project.len > 0) SessionInfo.setField(&info.project_name, &info.project_len, project);
            }
        }
        if (json_lite.extractString(line, "model")) |model_raw| {
            var model_buf: [64]u8 = undefined;
            const model = prettyModel(model_raw, &model_buf);
            if (model.len > 0) SessionInfo.setField(&info.model, &info.model_len, model);
        }
        if (json_lite.extractI64(line, "total_tokens")) |tokens| {
            if (tokens > info.total_tokens) info.total_tokens = tokens;
        } else if (json_lite.extractI64(line, "input_tokens")) |input| {
            const output = json_lite.extractI64(line, "output_tokens") orelse 0;
            if (input + output > info.total_tokens) info.total_tokens = input + output;
        }
        if (json_lite.extractString(line, "timestamp")) |stamp| {
            if (parseIsoToEpochMs(stamp)) |ms| {
                if (info.start_epoch_ms == 0 or ms < info.start_epoch_ms) info.start_epoch_ms = ms;
                if (ms > info.activity_ms) info.activity_ms = ms;
            }
        }
    }
}

pub fn prettyModel(raw: []const u8, buf: []u8) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    if (std.mem.startsWith(u8, raw, "gpt-")) {
        if (buf.len < 4) return "Codex";
        @memcpy(buf[0..4], "GPT-");
        w = 4;
        i = 4;
    }
    while (i < raw.len and w < buf.len) : (i += 1) {
        if (raw[i] == '-') {
            if (w < buf.len) { buf[w] = '.'; w += 1; }
        } else {
            buf[w] = raw[i];
            w += 1;
        }
    }
    var value = buf[0..w];
    if (std.mem.endsWith(u8, value, ".codex")) value = value[0 .. value.len - ".codex".len];
    return value;
}

fn parseIsoToEpochMs(iso: []const u8) ?i64 {
    if (iso.len < 19) return null;
    const year = std.fmt.parseInt(i32, iso[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, iso[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, iso[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, iso[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, iso[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, iso[17..19], 10) catch return null;
    var y: i64 = year;
    y -= @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) month - 3 else month + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return (era * 146097 + doe - 719468) * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1000;
}

test "prettyModel formats Codex model ids" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("GPT-5.2", prettyModel("gpt-5-2-codex", &buf));
}
