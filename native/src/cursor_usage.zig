//! Cursor subscription usage (included / auto / API / on-demand).
//!
//! Port of macOS `CursorUsage.swift` for Windows:
//!   POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
//! Auth token from (first hit wins):
//!   1. `%APPDATA%\Cursor\auth.json` → `accessToken`
//!   2. `%APPDATA%\Cursor\User\globalStorage\state.vscdb` → `cursorAuth/accessToken`

const std = @import("std");
const builtin = @import("builtin");
const win32_fs = @import("win32_fs.zig");
const json_lite = @import("json_lite.zig");
const grok_usage = @import("grok_usage.zig");

pub const period_usage_url = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage";
pub const legacy_usage_url = "https://api2.cursor.sh/auth/usage";

pub const Window = struct {
    percent: i64 = -1,
    resets_at_ms: i64 = 0,
};

pub const Snapshot = struct {
    included: Window = .{},
    auto: Window = .{},
    api: Window = .{},
    on_demand: Window = .{},
    plan_name: [32]u8 = .{0} ** 32,
    plan_name_len: usize = 0,
    authenticated: bool = false,

    pub fn planName(self: *const Snapshot) []const u8 {
        return self.plan_name[0..self.plan_name_len];
    }

    pub fn hasData(self: *const Snapshot) bool {
        return self.included.percent >= 0;
    }
};

pub const Auth = struct {
    access: [4096]u8 = undefined,
    access_len: usize = 0,

    pub fn accessSlice(self: *const Auth) []const u8 {
        return self.access[0..self.access_len];
    }
    pub fn hasAccess(self: *const Auth) bool {
        return self.access_len > 0;
    }
    pub fn setAccess(self: *Auth, value: []const u8) void {
        win32_fs.copyBounded(&self.access, &self.access_len, value);
    }
};

/// Load Cursor access token from Windows local stores.
pub fn loadAuth(out: *Auth) bool {
    out.* = .{};
    if (builtin.os.tag != .windows) return false;
    if (loadAuthFromJson(out)) return true;
    if (loadAuthFromStateDb(out)) return true;
    return false;
}

fn loadAuthFromJson(out: *Auth) bool {
    var appdata_buf: [260]u8 = undefined;
    const appdata = win32_fs.appData(&appdata_buf) orelse return false;
    var path_buf: [320]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\Cursor\\auth.json", .{appdata}) catch return false;
    var file_buf: [16 * 1024]u8 = undefined;
    const json = win32_fs.readFile(path, &file_buf) orelse return false;
    const token = json_lite.extractString(json, "accessToken") orelse return false;
    if (token.len == 0) return false;
    out.setAccess(token);
    return true;
}

fn loadAuthFromStateDb(out: *Auth) bool {
    var path_buf: [400]u8 = undefined;
    const path = stateDbPath(&path_buf) orelse return false;
    if (!win32_fs.pathExists(path)) return false;

    // Prefer sqlite3 CLI when available (macOS parity).
    if (readViaSqlite3(path, "cursorAuth/accessToken", out)) return true;

    // Fallback: JWT plaintext scan near the key (no libsqlite required).
    // Cap the read — state.vscdb can be large; token rows sit early enough in practice.
    const alloc = std.heap.page_allocator;
    const data = alloc.alloc(u8, 4 * 1024 * 1024) catch return false;
    defer alloc.free(data);
    const bytes = win32_fs.readFile(path, data) orelse return false;
    if (extractJwtNearKey(bytes, "cursorAuth/accessToken")) |token| {
        out.setAccess(token);
        return true;
    }
    return false;
}

fn stateDbPath(buf: []u8) ?[]const u8 {
    var appdata_buf: [260]u8 = undefined;
    const appdata = win32_fs.appData(&appdata_buf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}\\Cursor\\User\\globalStorage\\state.vscdb", .{appdata}) catch null;
}

fn readViaSqlite3(db_path: []const u8, key: []const u8, out: *Auth) bool {
    // Avoid interactive shells; require sqlite3.exe on PATH.
    _ = db_path;
    _ = key;
    _ = out;
    // CreateProcess + pipes is heavy for this prototype; plaintext scan covers
    // typical Cursor DBs. Revisit if scan proves unreliable in the wild.
    return false;
}

fn extractJwtNearKey(data: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, data, key) orelse return null;
    const search_end = @min(data.len, at + key.len + 800);
    var i = at + key.len;
    while (i + 3 < search_end) : (i += 1) {
        if (data[i] == 'e' and data[i + 1] == 'y' and data[i + 2] == 'J') {
            const start = i;
            var end = start;
            while (end < data.len and isJwtChar(data[end])) : (end += 1) {}
            if (end - start >= 40) return data[start..end];
        }
    }
    return null;
}

fn isJwtChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '=';
}

/// Build POST headers for GetCurrentPeriodUsage under the 1 KiB budget.
pub fn buildPeriodHeaders(
    auth: *const Auth,
    bearer_buf: []u8,
    headers_buf: []std.http.Header,
) ?[]std.http.Header {
    if (headers_buf.len < 4) return null;
    const bearer = std.fmt.bufPrint(bearer_buf, "Bearer {s}", .{auth.accessSlice()}) catch return null;

    var used: usize = 0;
    const pairs = [_]struct { []const u8, []const u8 }{
        .{ "Authorization", bearer },
        .{ "Content-Type", "application/json" },
        .{ "Connect-Protocol-Version", "1" },
        .{ "User-Agent", "AgentCord" },
    };
    var count: usize = 0;
    for (pairs) |pair| {
        used += pair[0].len + pair[1].len;
        if (used > grok_usage.max_fetch_header_bytes) return null;
        headers_buf[count] = .{ .name = pair[0], .value = pair[1] };
        count += 1;
    }
    return headers_buf[0..count];
}

pub const period_body = "{}";

/// Parse GetCurrentPeriodUsage JSON into Snapshot.
pub fn parsePeriodUsage(body: []const u8, out: *Snapshot) bool {
    out.* = .{};
    out.authenticated = true;

    // Prefer nested planUsage.totalPercentUsed; fall back to includedSpend/limit.
    var total_pct: ?f64 = null;
    if (std.mem.indexOf(u8, body, "\"planUsage\"")) |at| {
        const slice = body[at..@min(body.len, at + 1200)];
        if (json_lite.extractNumber(slice, "totalPercentUsed")) |p| total_pct = p;
        if (total_pct == null) {
            const limit = json_lite.extractNumber(slice, "limit");
            const used = json_lite.extractNumber(slice, "includedSpend") orelse json_lite.extractNumber(slice, "totalSpend");
            if (limit) |lim| {
                if (lim > 0) {
                    if (used) |u| total_pct = u / lim * 100.0;
                }
            }
        }
        if (json_lite.extractNumber(slice, "autoPercentUsed")) |auto| {
            const pct = clampPct(auto);
            if (pct > 0) out.auto = .{ .percent = pct };
        }
        if (json_lite.extractNumber(slice, "apiPercentUsed")) |api| {
            const pct = clampPct(api);
            if (pct > 0) out.api = .{ .percent = pct };
        }
    }
    if (total_pct == null) return false;
    out.included.percent = clampPct(total_pct.?);

    // Drop auto/api rows that duplicate the included total.
    if (out.auto.percent == out.included.percent) out.auto.percent = -1;
    if (out.api.percent == out.included.percent) out.api.percent = -1;

    if (std.mem.indexOf(u8, body, "\"spendLimitUsage\"")) |at| {
        const slice = body[at..@min(body.len, at + 400)];
        if (json_lite.extractNumber(slice, "individualLimit")) |lim| {
            if (lim > 0) {
                const remaining = json_lite.extractNumber(slice, "individualRemaining") orelse lim;
                const used = @max(0.0, lim - remaining);
                out.on_demand.percent = clampPct(used / lim * 100.0);
            }
        }
    }

    const resets = parseBillingCycleEnd(body);
    out.included.resets_at_ms = resets;
    if (out.auto.percent >= 0) out.auto.resets_at_ms = resets;
    if (out.api.percent >= 0) out.api.resets_at_ms = resets;
    if (out.on_demand.percent >= 0) out.on_demand.resets_at_ms = resets;
    return true;
}

fn parseBillingCycleEnd(body: []const u8) i64 {
    // billingCycleEnd may be a JSON string or number (epoch ms).
    if (json_lite.extractString(body, "billingCycleEnd")) |raw| {
        if (raw.len == 0) return 0;
        const millis = std.fmt.parseFloat(f64, raw) catch return 0;
        return epochFromFlexible(millis);
    }
    if (json_lite.extractNumber(body, "billingCycleEnd")) |millis| {
        return epochFromFlexible(millis);
    }
    return 0;
}

fn epochFromFlexible(millis: f64) i64 {
    if (!std.math.isFinite(millis) or millis <= 0) return 0;
    // Accept seconds or milliseconds.
    const ms: f64 = if (millis > 1_000_000_000_000) millis else millis * 1000.0;
    return @intFromFloat(ms);
}

fn clampPct(p: f64) i64 {
    if (!std.math.isFinite(p)) return 0;
    var pct: i64 = @intFromFloat(@round(p));
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    return pct;
}

/// "42% · resets in 6d 22h" for a usage window.
pub fn formatWindowLine(window: Window, now_ms: i64, buf: []u8) []const u8 {
    if (window.percent < 0) return "—";
    var reset_buf: [32]u8 = undefined;
    if (grok_usage.formatReset(window.resets_at_ms, now_ms, &reset_buf)) |reset| {
        if (std.mem.eql(u8, reset, "now")) {
            return std.fmt.bufPrint(buf, "{d}% · resets now", .{window.percent}) catch "—";
        }
        return std.fmt.bufPrint(buf, "{d}% · resets in {s}", .{ window.percent, reset }) catch "—";
    }
    return std.fmt.bufPrint(buf, "{d}%", .{window.percent}) catch "—";
}

pub fn windowFrac(window: Window) f32 {
    if (window.percent < 0) return 0;
    return @as(f32, @floatFromInt(window.percent)) / 100.0;
}

test "parsePeriodUsage total percent and on-demand" {
    const body =
        \\{"billingCycleEnd":"1785000000000","planUsage":{"totalPercentUsed":42.4,"autoPercentUsed":10.0,"apiPercentUsed":42.4},"spendLimitUsage":{"individualLimit":100,"individualRemaining":25}}
    ;
    var snap: Snapshot = .{};
    try std.testing.expect(parsePeriodUsage(body, &snap));
    try std.testing.expectEqual(@as(i64, 42), snap.included.percent);
    try std.testing.expectEqual(@as(i64, 10), snap.auto.percent);
    try std.testing.expectEqual(@as(i64, -1), snap.api.percent); // same as included → dropped
    try std.testing.expectEqual(@as(i64, 75), snap.on_demand.percent);
    try std.testing.expect(snap.included.resets_at_ms > 0);
}

test "extractJwtNearKey" {
    const blob = "xxcursorAuth/accessToken\x00eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abc_def-GHI=\x00trailer";
    const tok = extractJwtNearKey(blob, "cursorAuth/accessToken").?;
    try std.testing.expect(std.mem.startsWith(u8, tok, "eyJ"));
    try std.testing.expect(std.mem.endsWith(u8, tok, "GHI="));
}

test "formatWindowLine" {
    var buf: [64]u8 = undefined;
    const w = Window{ .percent = 42, .resets_at_ms = 0 };
    try std.testing.expectEqualStrings("42%", formatWindowLine(w, 0, &buf));
}
