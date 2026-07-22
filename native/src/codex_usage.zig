//! Read Codex subscription limits through its local app-server protocol.
//!
//! AgentCord never reads Codex OAuth credentials. The Codex executable owns
//! authentication and returns only the account/rate-limit response we display.

const std = @import("std");
const builtin = @import("builtin");
const win32_fs = @import("win32_fs.zig");
const json_lite = @import("json_lite.zig");
const grok_usage = @import("grok_usage.zig");

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

const messages =
    \\{"method":"initialize","id":0,"params":{"clientInfo":{"name":"agentcord","title":"AgentCord","version":"0.1.0"}}}
    \\{"method":"initialized","params":{}}
    \\{"method":"account/read","id":1,"params":{"refreshToken":false}}
    \\{"method":"account/rateLimits/read","id":2}
;

pub fn fetch(out: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    var exe_buf: [520]u8 = undefined;
    const exe = win32_fs.searchPath("codex.exe", &exe_buf) orelse
        win32_fs.searchPath("codex", &exe_buf) orelse return null;
    return win32_fs.runCaptureWithInput(&.{ exe, "app-server" }, messages, out, 10_000);
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

fn parseRateLimits(line: []const u8, out: *Snapshot) bool {
    const rate_at = std.mem.indexOf(u8, line, "\"rateLimits\"") orelse return false;
    const rate = line[rate_at..];
    const primary_at = std.mem.indexOf(u8, rate, "\"primary\"") orelse return false;
    const primary = rate[primary_at..];
    out.primary = parseWindow(primary);
    if (out.primary.percent < 0) return false;
    setLabel(&out.primary_label, &out.primary_label_len, labelForWindow(primary, "Primary limit"));

    if (std.mem.indexOf(u8, primary, "\"secondary\"")) |secondary_at| {
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
    const used = json_lite.extractNumber(text, "usedPercent") orelse return .{};
    var pct: i64 = @intFromFloat(@round(used));
    pct = @max(0, @min(100, pct));
    const resets = json_lite.extractNumber(text, "resetsAt") orelse 0;
    const reset_ms: i64 = if (resets > 1_000_000_000_000.0) @intFromFloat(resets) else @intFromFloat(resets * 1000.0);
    return .{ .percent = pct, .resets_at_ms = reset_ms };
}

fn labelForWindow(text: []const u8, fallback: []const u8) []const u8 {
    const minutes = json_lite.extractI64(text, "windowDurationMins") orelse return fallback;
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
