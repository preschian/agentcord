//! Cursor subscription usage (included / auto / API / on-demand).
//!
//! Port of macOS `CursorUsage.swift` for Windows:
//!   POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
//!   GET  https://api2.cursor.sh/auth/usage  (legacy fallback)
//! Auth token from (first hit wins; alternate store tried on 401):
//!   1. `%APPDATA%\Cursor\auth.json` → `accessToken`
//!   2. `%APPDATA%\Cursor\User\globalStorage\state.vscdb` → `cursorAuth/accessToken`

const std = @import("std");
const builtin = @import("builtin");
const win32_fs = @import("win32_fs.zig");
const json_lite = @import("json_lite.zig");
const grok_usage = @import("grok_usage.zig");

pub const period_usage_url = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage";
pub const legacy_usage_url = "https://api2.cursor.sh/auth/usage";

const access_token_key = "cursorAuth/accessToken";
const membership_key = "cursorAuth/stripeMembershipType";

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

    pub fn setPlanName(self: *Snapshot, value: []const u8) void {
        win32_fs.copyBounded(&self.plan_name, &self.plan_name_len, value);
    }
};

pub const AuthSource = enum { none, json, state_db };

pub const Auth = struct {
    access: [4096]u8 = undefined,
    access_len: usize = 0,
    source: AuthSource = .none,

    pub fn accessSlice(self: *const Auth) []const u8 {
        return self.access[0..self.access_len];
    }
    pub fn hasAccess(self: *const Auth) bool {
        return self.access_len > 0;
    }
    pub fn setAccess(self: *Auth, value: []const u8, source: AuthSource) void {
        win32_fs.copyBounded(&self.access, &self.access_len, value);
        self.source = source;
    }
};

/// True when a Cursor auth store exists on disk (no token load).
pub fn looksSignedIn() bool {
    if (builtin.os.tag != .windows) return false;
    return authJsonExists() or stateDbExists();
}

/// Load Cursor access token — prefer auth.json, then state.vscdb.
pub fn loadAuth(out: *Auth) bool {
    out.* = .{};
    if (builtin.os.tag != .windows) return false;
    if (loadAuthFromJson(out)) return true;
    if (loadAuthFromStateDb(out)) return true;
    return false;
}

/// Load from the store that was *not* used last time (401 fallback).
pub fn loadAuthAlternate(out: *Auth, skip: AuthSource) bool {
    out.* = .{};
    if (builtin.os.tag != .windows) return false;
    switch (skip) {
        .json => return loadAuthFromStateDb(out),
        .state_db => return loadAuthFromJson(out),
        .none => return loadAuth(out),
    }
}

/// Membership type from state.vscdb (`cursorAuth/stripeMembershipType`), if any.
pub fn loadMembership(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    var path_buf: [400]u8 = undefined;
    const path = stateDbPath(&path_buf) orelse return null;
    if (!win32_fs.pathExists(path)) return null;
    if (readStateValue(path, membership_key, buf)) |v| {
        if (v.len > 0) return v;
    }
    return null;
}

fn authJsonExists() bool {
    var appdata_buf: [260]u8 = undefined;
    const appdata = win32_fs.appData(&appdata_buf) orelse return false;
    var path_buf: [320]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\Cursor\\auth.json", .{appdata}) catch return false;
    return win32_fs.pathExists(path);
}

fn stateDbExists() bool {
    var path_buf: [400]u8 = undefined;
    const path = stateDbPath(&path_buf) orelse return false;
    return win32_fs.pathExists(path);
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
    out.setAccess(token, .json);
    return true;
}

fn loadAuthFromStateDb(out: *Auth) bool {
    var path_buf: [400]u8 = undefined;
    const path = stateDbPath(&path_buf) orelse return false;
    if (!win32_fs.pathExists(path)) return false;

    var token_buf: [4096]u8 = undefined;
    if (readStateValue(path, access_token_key, &token_buf)) |token| {
        if (token.len > 0) {
            out.setAccess(token, .state_db);
            return true;
        }
    }
    return false;
}

fn stateDbPath(buf: []u8) ?[]const u8 {
    var appdata_buf: [260]u8 = undefined;
    const appdata = win32_fs.appData(&appdata_buf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}\\Cursor\\User\\globalStorage\\state.vscdb", .{appdata}) catch null;
}

fn readStateValue(db_path: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    if (readViaSqlite3(db_path, key, out)) |v| return v;
    return scanValueInFile(db_path, key, out);
}

fn readViaSqlite3(db_path: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    var exe_buf: [520]u8 = undefined;
    const exe = win32_fs.searchPath("sqlite3.exe", &exe_buf) orelse
        win32_fs.searchPath("sqlite3", &exe_buf) orelse
        return null;

    var sql_buf: [160]u8 = undefined;
    // Keys are fixed app constants — no user input.
    const sql = std.fmt.bufPrint(
        &sql_buf,
        "SELECT value FROM ItemTable WHERE key = '{s}';",
        .{key},
    ) catch return null;

    var stdout_buf: [8192]u8 = undefined;
    const captured = win32_fs.runCapture(&.{ exe, db_path, sql }, &stdout_buf, 5_000) orelse return null;
    if (captured.len == 0 or captured.len > out.len) return null;
    @memcpy(out[0..captured.len], captured);
    return out[0..captured.len];
}

/// Chunked plaintext scan for JWT (or short string) near `key` — no 4 MiB cap.
fn scanValueInFile(path: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    const chunk_size: usize = 1024 * 1024;
    const overlap = key.len + 900;
    const alloc = std.heap.page_allocator;
    const buf = alloc.alloc(u8, chunk_size + overlap) catch return null;
    defer alloc.free(buf);

    var wide: [520]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], path) catch return null;
    wide[wide_len] = 0;
    const handle = win32_fs.CreateFileW(
        wide[0..wide_len :0].ptr,
        win32_fs.GENERIC_READ,
        win32_fs.FILE_SHARE_READ | win32_fs.FILE_SHARE_WRITE,
        null,
        win32_fs.OPEN_EXISTING,
        win32_fs.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == win32_fs.INVALID_HANDLE) return null;
    defer std.os.windows.CloseHandle(handle);

    var tail_len: usize = 0;
    while (true) {
        var n: std.os.windows.DWORD = 0;
        const space = buf.len - tail_len;
        if (space == 0) break;
        if (!win32_fs.ReadFile(handle, buf[tail_len..].ptr, @intCast(space), &n, null).toBool()) break;
        const total = tail_len + n;
        if (total == 0) break;

        if (extractValueNearKey(buf[0..total], key)) |token| {
            if (token.len == 0 or token.len > out.len) return null;
            @memcpy(out[0..token.len], token);
            return out[0..token.len];
        }

        if (n == 0) break;
        // Keep overlap for keys spanning chunk boundaries.
        const keep = @min(overlap, total);
        const start = total - keep;
        @memcpy(buf[0..keep], buf[start..total]);
        tail_len = keep;
    }
    return null;
}

fn extractValueNearKey(data: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, data, key) orelse return null;
    const search_end = @min(data.len, at + key.len + 800);
    var i = at + key.len;
    const want_jwt = std.mem.eql(u8, key, access_token_key);
    while (i + 3 < search_end) : (i += 1) {
        if (want_jwt) {
            if (data[i] == 'e' and data[i + 1] == 'y' and data[i + 2] == 'J') {
                const start = i;
                var end = start;
                while (end < data.len and isJwtChar(data[end])) : (end += 1) {}
                if (end - start >= 40) return data[start..end];
            }
        } else if (isIdentStart(data[i])) {
            const start = i;
            var end = start;
            while (end < data.len and isIdentChar(data[end])) : (end += 1) {}
            const len = end - start;
            if (len >= 2 and len <= 32) return data[start..end];
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

fn isIdentStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9') or c == '_' or c == '-';
}

/// Build POST headers for GetCurrentPeriodUsage under the 1 KiB budget.
/// Drops User-Agent to leave more room for long JWTs.
pub fn buildPeriodHeaders(
    auth: *const Auth,
    bearer_buf: []u8,
    headers_buf: []std.http.Header,
) ?[]std.http.Header {
    if (headers_buf.len < 3) return null;
    const bearer = std.fmt.bufPrint(bearer_buf, "Bearer {s}", .{auth.accessSlice()}) catch return null;

    var used: usize = 0;
    const pairs = [_]struct { []const u8, []const u8 }{
        .{ "Authorization", bearer },
        .{ "Content-Type", "application/json" },
        .{ "Connect-Protocol-Version", "1" },
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

/// Minimal headers for legacy GET `/auth/usage`.
pub fn buildLegacyHeaders(
    auth: *const Auth,
    bearer_buf: []u8,
    headers_buf: []std.http.Header,
) ?[]std.http.Header {
    if (headers_buf.len < 1) return null;
    const bearer = std.fmt.bufPrint(bearer_buf, "Bearer {s}", .{auth.accessSlice()}) catch return null;
    const used = "Authorization".len + bearer.len;
    if (used > grok_usage.max_fetch_header_bytes) return null;
    headers_buf[0] = .{ .name = "Authorization", .value = bearer };
    return headers_buf[0..1];
}

pub const period_body = "{}";

/// Parse GetCurrentPeriodUsage JSON into Snapshot.
pub fn parsePeriodUsage(body: []const u8, out: *Snapshot) bool {
    out.* = .{};
    out.authenticated = true;

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

/// Parse legacy `/auth/usage` JSON (request buckets).
pub fn parseLegacyUsage(body: []const u8, out: *Snapshot) bool {
    out.* = .{};
    out.authenticated = true;

    var best_max: f64 = 0;
    var best_used: f64 = 0;
    var best_key: []const u8 = "";

    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, body, search_from, "\"maxRequestUsage\"")) |at| {
        search_from = at + 1;
        const window_start = if (at > 200) at - 200 else 0;
        const window = body[window_start..@min(body.len, at + 80)];
        const max_u = json_lite.extractNumber(window, "maxRequestUsage") orelse continue;
        if (max_u <= 0) continue;
        const used = json_lite.extractNumber(window, "numRequests") orelse 0;

        // Plan / bucket key: nearest quoted key before the bucket object.
        var key: []const u8 = "";
        if (std.mem.lastIndexOfScalar(u8, body[window_start..at], '{')) |brace_rel| {
            const before = body[window_start .. window_start + brace_rel];
            if (std.mem.lastIndexOfScalar(u8, before, '"')) |end_q| {
                if (std.mem.lastIndexOfScalar(u8, before[0..end_q], '"')) |start_q| {
                    key = before[start_q + 1 .. end_q];
                }
            }
        }

        if (max_u > best_max) {
            best_max = max_u;
            best_used = used;
            best_key = key;
        }
    }
    if (best_max <= 0) return false;

    out.included.percent = clampPct(best_used / best_max * 100.0);
    out.included.resets_at_ms = parseLegacyReset(body);
    if (best_key.len > 0 and !std.mem.eql(u8, best_key, "startOfMonth")) {
        out.setPlanName(best_key);
    }
    return true;
}

fn parseLegacyReset(body: []const u8) i64 {
    const raw = json_lite.extractString(body, "startOfMonth") orelse return 0;
    // Expect ISO-8601; quota resets at start of next month (macOS parity).
    if (raw.len < 10) return 0;
    const year = std.fmt.parseInt(i32, raw[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(i32, raw[5..7], 10) catch return 0;
    var y = year;
    var m = month + 1;
    if (m > 12) {
        m = 1;
        y += 1;
    }
    // Approximate midnight UTC as epoch ms (day=1).
    const days = civilDaysFromYmd(y, m, 1);
    return days * 86_400_000;
}

fn civilDaysFromYmd(year: i32, month: i32, day: i32) i64 {
    // Howard Hinnant civil_from_days inverse (UTC days since 1970-01-01).
    var y = year;
    const m = month;
    const d = day;
    y -= @intFromBool(m <= 2);
    const era = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn parseBillingCycleEnd(body: []const u8) i64 {
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
    try std.testing.expectEqual(@as(i64, -1), snap.api.percent);
    try std.testing.expectEqual(@as(i64, 75), snap.on_demand.percent);
    try std.testing.expect(snap.included.resets_at_ms > 0);
}

test "parseLegacyUsage picks largest bucket" {
    const body =
        \\{"startOfMonth":"2026-01-01T00:00:00.000Z","pro":{"numRequests":40,"maxRequestUsage":500},"gpt-4":{"numRequests":10,"maxRequestUsage":50}}
    ;
    var snap: Snapshot = .{};
    try std.testing.expect(parseLegacyUsage(body, &snap));
    try std.testing.expectEqual(@as(i64, 8), snap.included.percent); // 40/500
    try std.testing.expectEqualStrings("pro", snap.planName());
    try std.testing.expect(snap.included.resets_at_ms > 0);
}

test "extractValueNearKey JWT" {
    const blob = "xxcursorAuth/accessToken\x00eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abc_def-GHI=\x00trailer";
    const tok = extractValueNearKey(blob, "cursorAuth/accessToken").?;
    try std.testing.expect(std.mem.startsWith(u8, tok, "eyJ"));
    try std.testing.expect(std.mem.endsWith(u8, tok, "GHI="));
}

test "formatWindowLine" {
    var buf: [64]u8 = undefined;
    const w = Window{ .percent = 42, .resets_at_ms = 0 };
    try std.testing.expectEqualStrings("42%", formatWindowLine(w, 0, &buf));
}

test "buildPeriodHeaders under budget for typical token" {
    var auth: Auth = .{};
    var tok: [403]u8 = undefined;
    @memset(&tok, 'a');
    tok[0] = 'e';
    tok[1] = 'y';
    tok[2] = 'J';
    auth.setAccess(&tok, .json);
    var bearer: [16 + 4096]u8 = undefined;
    var headers: [4]std.http.Header = undefined;
    const h = buildPeriodHeaders(&auth, &bearer, &headers).?;
    try std.testing.expectEqual(@as(usize, 3), h.len);
}
