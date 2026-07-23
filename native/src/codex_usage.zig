//! Read Codex subscription limits through its local app-server protocol.
//!
//! AgentCord first asks Codex app-server for limits, then falls back to the
//! same local ChatGPT session used by Codex when app-server returns no data.

const std = @import("std");
const builtin = @import("builtin");
const win32_fs = @import("win32_fs.zig");
const json_lite = @import("json_lite.zig");
const grok_usage = @import("grok_usage.zig");

pub const wham_usage_url = "https://chatgpt.com/backend-api/wham/usage";

pub const Window = struct {
    percent: i64 = -1,
    resets_at_ms: i64 = 0,
};

pub const Snapshot = struct {
    primary: Window = .{},
    secondary: Window = .{},
    primary_label: [40]u8 = .{0} ** 40,
    primary_label_len: usize = 0,
    secondary_label: [40]u8 = .{0} ** 40,
    secondary_label_len: usize = 0,
    plan_name: [32]u8 = .{0} ** 32,
    plan_name_len: usize = 0,

    pub fn hasData(self: *const Snapshot) bool {
        return self.primary.percent >= 0;
    }
    pub fn primaryLabel(self: *const Snapshot) []const u8 {
        return self.primary_label[0..self.primary_label_len];
    }
    pub fn secondaryLabel(self: *const Snapshot) []const u8 {
        return self.secondary_label[0..self.secondary_label_len];
    }
    pub fn planName(self: *const Snapshot) []const u8 {
        return self.plan_name[0..self.plan_name_len];
    }
};

/// Codex's local ChatGPT sign-in. Credentials remain in process memory only
/// and are used solely for the usage request when app-server is unavailable.
pub const Auth = struct {
    access: [2048]u8 = undefined,
    access_len: usize = 0,
    account_id: [128]u8 = undefined,
    account_id_len: usize = 0,

    pub fn accessSlice(self: *const Auth) []const u8 {
        return self.access[0..self.access_len];
    }
    pub fn accountIdSlice(self: *const Auth) []const u8 {
        return self.account_id[0..self.account_id_len];
    }
    pub fn setField(buf: []u8, len: *usize, value: []const u8) void {
        const n = @min(buf.len, value.len);
        @memcpy(buf[0..n], value[0..n]);
        len.* = n;
    }
};

const messages =
    \\{"method":"initialize","id":0,"params":{"clientInfo":{"name":"agentcord","title":"AgentCord","version":"0.1.0"}}}
    // Codex app-server v2 expects the parameter value to be JSON null.
    // The former initialized/account-read messages are no longer needed to
    // obtain rate limits and can suppress the reply on current Codex CLI.
    \\{"method":"account/rateLimits/read","id":2,"params":null}
;

pub fn fetch(out: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    var exe_buf: [520]u8 = undefined;
    const exe = win32_fs.searchPath("codex.exe", &exe_buf) orelse
        win32_fs.searchPath("codex", &exe_buf) orelse return null;
    return win32_fs.runCaptureWithInput(&.{ exe, "app-server" }, messages, out, 10_000);
}

/// Fetch the same ChatGPT usage snapshot Codex uses as a fallback when the
/// app-server closes stdout without answering. curl reads the Authorization
/// header from stdin config, never from a command-line argument.
pub fn fetchWhamUsage(out: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    var auth: Auth = .{};
    if (!loadAuth(&auth)) return null;

    var exe_buf: [520]u8 = undefined;
    const curl = win32_fs.searchPath("curl.exe", &exe_buf) orelse
        win32_fs.searchPath("curl", &exe_buf) orelse return null;
    var config_buf: [4096]u8 = undefined;
    const config = buildWhamCurlConfig(&auth, &config_buf) orelse return null;
    return win32_fs.runCaptureWithInput(&.{ curl, "--config", "-" }, config, out, 15_000);
}

pub fn loadAuth(out: *Auth) bool {
    var home_buf: [260]u8 = undefined;
    const home = win32_fs.userProfile(&home_buf) orelse return false;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\.codex\\auth.json", .{home}) catch return false;
    var file_buf: [16 * 1024]u8 = undefined;
    const json = win32_fs.readFile(path, &file_buf) orelse return false;
    const access = json_lite.extractString(json, "access_token") orelse return false;
    if (access.len == 0 or access.len > out.access.len) return false;

    out.* = .{};
    Auth.setField(&out.access, &out.access_len, access);
    if (json_lite.extractString(json, "account_id")) |account_id| {
        Auth.setField(&out.account_id, &out.account_id_len, account_id);
    }
    return true;
}

fn buildWhamCurlConfig(auth: *const Auth, buf: []u8) ?[]const u8 {
    if (auth.access_len == 0) return null;
    if (auth.account_id_len > 0) {
        return std.fmt.bufPrint(
            buf,
            "url = \"{s}\"\n" ++
                "header = \"Authorization: Bearer {s}\"\n" ++
                "header = \"ChatGPT-Account-ID: {s}\"\n" ++
                "header = \"Accept: application/json\"\n" ++
                "silent\nshow-error\nfail-with-body\nmax-time = 15\n",
            .{ wham_usage_url, auth.accessSlice(), auth.accountIdSlice() },
        ) catch null;
    }
    return std.fmt.bufPrint(
        buf,
        "url = \"{s}\"\n" ++
            "header = \"Authorization: Bearer {s}\"\n" ++
            "header = \"Accept: application/json\"\n" ++
            "silent\nshow-error\nfail-with-body\nmax-time = 15\n",
        .{ wham_usage_url, auth.accessSlice() },
    ) catch null;
}

pub fn parseResponse(text: []const u8, out: *Snapshot) bool {
    out.* = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // The rate-limits reply has id 2. Other JSONL replies (initialize and
        // account/read) may also include superficially similar fields.
        if (std.mem.indexOf(u8, line, "\"id\":2") == null) continue;
        if (std.mem.indexOf(u8, line, "\"rateLimits\"") == null) continue;
        return parseRateLimits(line, out);
    }
    return false;
}

/// Parse ChatGPT's `wham/usage` response (snake_case) into the same snapshot
/// used for the app-server's camelCase response.
pub fn parseWhamUsage(text: []const u8, out: *Snapshot) bool {
    out.* = .{};
    const rate_at = std.mem.indexOf(u8, text, "\"rate_limit\"") orelse return false;
    if (!parseRateLimits(text[rate_at..], out)) return false;
    if (json_lite.extractString(text, "plan_type")) |plan| {
        setLabel(&out.plan_name, &out.plan_name_len, plan);
    }
    return true;
}

fn parseRateLimits(line: []const u8, out: *Snapshot) bool {
    const rate = if (std.mem.indexOf(u8, line, "\"rateLimits\"")) |rate_at| line[rate_at..] else line;
    const primary_at = std.mem.indexOf(u8, rate, "\"primary\"") orelse
        std.mem.indexOf(u8, rate, "\"primary_window\"") orelse return false;
    const primary = rate[primary_at..];
    out.primary = parseWindow(primary);
    if (out.primary.percent < 0) return false;
    setLabel(&out.primary_label, &out.primary_label_len, labelForWindow(primary, "Primary limit"));

    if (std.mem.indexOf(u8, primary, "\"secondary\"") orelse
        std.mem.indexOf(u8, primary, "\"secondary_window\"")) |secondary_at|
    {
        const secondary = primary[secondary_at..];
        const value = parseWindow(secondary);
        if (value.percent >= 0) {
            out.secondary = value;
            setLabel(&out.secondary_label, &out.secondary_label_len, labelForWindow(secondary, "Secondary limit"));
        }
    }
    if (json_lite.extractString(rate, "planType")) |plan| setLabel(&out.plan_name, &out.plan_name_len, plan);
    return true;
}

fn parseWindow(text: []const u8) Window {
    const used = json_lite.extractNumber(text, "usedPercent") orelse
        json_lite.extractNumber(text, "used_percent") orelse return .{};
    var pct: i64 = @intFromFloat(@round(used));
    pct = @max(0, @min(100, pct));
    const resets = json_lite.extractNumber(text, "resetsAt") orelse
        json_lite.extractNumber(text, "reset_at") orelse 0;
    const reset_ms: i64 = if (resets > 1_000_000_000_000.0) @intFromFloat(resets) else @intFromFloat(resets * 1000.0);
    return .{ .percent = pct, .resets_at_ms = reset_ms };
}

fn labelForWindow(text: []const u8, fallback: []const u8) []const u8 {
    const minutes: i64 = if (json_lite.extractI64(text, "windowDurationMins")) |value|
        value
    else if (json_lite.extractI64(text, "limit_window_seconds")) |seconds|
        @divTrunc(seconds, 60)
    else
        return fallback;
    if (minutes <= 6 * 60) return "5-hour session";
    if (minutes <= 8 * 24 * 60) return "Weekly limit";
    if (minutes <= 40 * 24 * 60) return "Monthly limit";
    return fallback;
}

fn setLabel(buf: []u8, len: *usize, text: []const u8) void {
    const n = @min(buf.len, text.len);
    @memcpy(buf[0..n], text[0..n]);
    len.* = n;
}

pub fn formatWindowLine(window: Window, now_ms: i64, buf: []u8) []const u8 {
    if (window.percent < 0) return "—";
    var reset_buf: [32]u8 = undefined;
    if (grok_usage.formatReset(window.resets_at_ms, now_ms, &reset_buf)) |reset| {
        return std.fmt.bufPrint(buf, "{d}% · resets in {s}", .{ window.percent, reset }) catch "—";
    }
    return std.fmt.bufPrint(buf, "{d}%", .{window.percent}) catch "—";
}

pub fn windowFrac(window: Window) f32 {
    if (window.percent < 0) return 0;
    return @as(f32, @floatFromInt(window.percent)) / 100.0;
}

test "parses app-server primary and secondary limits" {
    const reply =
        \\{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":42.4,"windowDurationMins":300,"resetsAt":1785000000},"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1785600000},"planType":"pro"}}}
    ;
    var snap: Snapshot = .{};
    try std.testing.expect(parseResponse(reply, &snap));
    try std.testing.expectEqual(@as(i64, 42), snap.primary.percent);
    try std.testing.expectEqual(@as(i64, 12), snap.secondary.percent);
    try std.testing.expectEqualStrings("5-hour session", snap.primaryLabel());
    try std.testing.expectEqualStrings("Weekly limit", snap.secondaryLabel());
    try std.testing.expectEqualStrings("pro", snap.planName());
}

test "parses Codex wham usage fallback" {
    const reply =
        \\{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":48,"limit_window_seconds":18000,"reset_at":1785000000},"secondary_window":{"used_percent":19,"limit_window_seconds":604800,"reset_at":1785600000}}}
    ;
    var snap: Snapshot = .{};
    try std.testing.expect(parseWhamUsage(reply, &snap));
    try std.testing.expectEqual(@as(i64, 48), snap.primary.percent);
    try std.testing.expectEqual(@as(i64, 19), snap.secondary.percent);
    try std.testing.expectEqualStrings("5-hour session", snap.primaryLabel());
    try std.testing.expectEqualStrings("Weekly limit", snap.secondaryLabel());
    try std.testing.expectEqualStrings("pro", snap.planName());
}

test "uses the current app-server rate-limit request shape" {
    try std.testing.expect(std.mem.indexOf(u8, messages, "\"account/rateLimits/read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "\"params\":null") != null);
}
