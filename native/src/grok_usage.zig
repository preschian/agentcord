//! Grok weekly credit usage (CLI / SuperGrok billing).
//!
//! Port of macOS `GrokUsage.swift`:
//!   GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
//!   using OIDC tokens from `~/.grok/auth.json` (`key` + `refresh_token`).

const std = @import("std");
const win32_fs = @import("win32_fs.zig");
const json_lite = @import("json_lite.zig");
const grok_session = @import("grok_session.zig");

pub const billing_url = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
pub const token_auth_header = "xai-grok-cli";

/// Matches `native_sdk.max_effect_fetch_header_bytes` (name+value sum).
pub const max_fetch_header_bytes: usize = 1024;

pub const Auth = struct {
    access: [2048]u8 = undefined,
    access_len: usize = 0,
    refresh: [512]u8 = undefined,
    refresh_len: usize = 0,
    client_id: [64]u8 = undefined,
    client_id_len: usize = 0,
    issuer: [128]u8 = undefined,
    issuer_len: usize = 0,
    user_id: [64]u8 = undefined,
    user_id_len: usize = 0,

    pub fn accessSlice(self: *const Auth) []const u8 {
        return self.access[0..self.access_len];
    }
    pub fn refreshSlice(self: *const Auth) []const u8 {
        return self.refresh[0..self.refresh_len];
    }
    pub fn clientIdSlice(self: *const Auth) []const u8 {
        return self.client_id[0..self.client_id_len];
    }
    pub fn issuerSlice(self: *const Auth) []const u8 {
        return self.issuer[0..self.issuer_len];
    }
    pub fn userIdSlice(self: *const Auth) []const u8 {
        return self.user_id[0..self.user_id_len];
    }

    pub fn hasAccess(self: *const Auth) bool {
        return self.access_len > 0;
    }
    pub fn hasRefresh(self: *const Auth) bool {
        return self.refresh_len > 0 and self.client_id_len > 0;
    }

    pub fn setField(buf: []u8, len: *usize, value: []const u8) void {
        const n = @min(value.len, buf.len);
        @memcpy(buf[0..n], value[0..n]);
        len.* = n;
    }

    pub fn setAccess(self: *Auth, value: []const u8) void {
        setField(&self.access, &self.access_len, value);
    }

    pub fn setRefresh(self: *Auth, value: []const u8) void {
        setField(&self.refresh, &self.refresh_len, value);
    }
};

/// Parsed weekly credits snapshot for the UI.
pub const Snapshot = struct {
    /// Weekly included credits used (0–100). -1 = unknown.
    weekly_percent: i64 = -1,
    /// Epoch ms when the current period ends; 0 = unknown.
    resets_at_ms: i64 = 0,
    /// On-demand percent when a cap is set; -1 = none/unknown.
    on_demand_percent: i64 = -1,
    authenticated: bool = false,
};

/// Apply a token refresh JSON body onto Auth. Returns false if access_token missing.
pub fn applyRefreshResponse(auth: *Auth, body: []const u8) bool {
    const access = json_lite.extractString(body, "access_token") orelse return false;
    if (access.len == 0) return false;
    auth.setAccess(access);
    if (json_lite.extractString(body, "refresh_token")) |new_refresh| {
        if (new_refresh.len > 0) auth.setRefresh(new_refresh);
    }
    return true;
}

/// Load the first OIDC credential entry from `~/.grok/auth.json`.
/// Access token lives in the `key` field (Grok CLI convention).
pub fn loadAuth(out: *Auth) bool {
    var home_buf: [260]u8 = undefined;
    const home = win32_fs.userProfile(&home_buf) orelse return false;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\.grok\\auth.json", .{home}) catch return false;
    var file_buf: [16 * 1024]u8 = undefined;
    const json = win32_fs.readFile(path, &file_buf) orelse return false;

    var search: usize = 0;
    while (json_lite.nextObject(json, &search)) |obj| {
        const access = json_lite.extractString(obj, "key");
        const refresh = json_lite.extractString(obj, "refresh_token");
        const has_access = access != null and access.?.len > 0;
        const has_refresh = refresh != null and refresh.?.len > 0;
        if (!has_access and !has_refresh) continue;

        out.* = .{};
        if (access) |a| out.setAccess(a);
        if (refresh) |r| Auth.setField(&out.refresh, &out.refresh_len, r);
        if (json_lite.extractString(obj, "oidc_client_id")) |c| {
            Auth.setField(&out.client_id, &out.client_id_len, c);
        }
        if (json_lite.extractString(obj, "oidc_issuer")) |iss| {
            Auth.setField(&out.issuer, &out.issuer_len, iss);
        } else {
            Auth.setField(&out.issuer, &out.issuer_len, "https://auth.x.ai");
        }
        if (json_lite.extractString(obj, "user_id")) |u| {
            Auth.setField(&out.user_id, &out.user_id_len, u);
        }
        return true;
    }
    return false;
}

pub fn tokenUrl(auth: *const Auth, buf: []u8) ?[]const u8 {
    const issuer = if (auth.issuer_len > 0) auth.issuerSlice() else "https://auth.x.ai";
    var base = issuer;
    while (base.len > 0 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];
    return std.fmt.bufPrint(buf, "{s}/oauth2/token", .{base}) catch null;
}

/// application/x-www-form-urlencoded body with percent-encoded values (macOS parity).
pub fn refreshBody(auth: *const Auth, buf: []u8) ?[]const u8 {
    var refresh_enc: [1536]u8 = undefined;
    var client_enc: [192]u8 = undefined;
    const refresh = json_lite.percentEncode(auth.refreshSlice(), &refresh_enc) orelse return null;
    const client_id = json_lite.percentEncode(auth.clientIdSlice(), &client_enc) orelse return null;
    return std.fmt.bufPrint(
        buf,
        "grant_type=refresh_token&refresh_token={s}&client_id={s}",
        .{ refresh, client_id },
    ) catch null;
}

fn headerPairBytes(name: []const u8, value: []const u8) usize {
    return name.len + value.len;
}

/// Build billing GET headers under the SDK 1 KiB name+value budget.
/// Drops optional `x-userid` when needed; returns null if still over budget.
pub fn buildBillingHeaders(
    auth: *const Auth,
    bearer_buf: []u8,
    headers_buf: []std.http.Header,
) ?[]std.http.Header {
    if (headers_buf.len < 3) return null;
    const bearer = std.fmt.bufPrint(bearer_buf, "Bearer {s}", .{auth.accessSlice()}) catch return null;

    const accept_name = "Accept";
    const accept_val = "application/json";
    const auth_name = "Authorization";
    const xai_name = "X-XAI-Token-Auth";
    const userid_name = "x-userid";

    var used: usize = 0;
    used += headerPairBytes(auth_name, bearer);
    used += headerPairBytes(accept_name, accept_val);
    used += headerPairBytes(xai_name, token_auth_header);

    var count: usize = 0;
    headers_buf[count] = .{ .name = auth_name, .value = bearer };
    count += 1;
    headers_buf[count] = .{ .name = accept_name, .value = accept_val };
    count += 1;
    headers_buf[count] = .{ .name = xai_name, .value = token_auth_header };
    count += 1;

    if (auth.user_id_len > 0 and count < headers_buf.len) {
        const uid = auth.userIdSlice();
        const extra = headerPairBytes(userid_name, uid);
        if (used + extra <= max_fetch_header_bytes) {
            headers_buf[count] = .{ .name = userid_name, .value = uid };
            count += 1;
            used += extra;
        }
    }

    if (used > max_fetch_header_bytes) return null;
    return headers_buf[0..count];
}

/// Parse billing JSON into a Snapshot. Returns false when unusable.
pub fn parseBilling(body: []const u8, out: *Snapshot) bool {
    out.weekly_percent = -1;
    out.resets_at_ms = 0;
    out.on_demand_percent = -1;

    var percent: ?f64 = null;
    if (json_lite.extractNumber(body, "creditUsagePercent")) |p| percent = p;

    var end_iso: ?[]const u8 = null;
    if (std.mem.indexOf(u8, body, "\"currentPeriod\"")) |at| {
        const slice = body[at..@min(body.len, at + 400)];
        end_iso = json_lite.extractString(slice, "end");
    }
    if (end_iso == null) {
        end_iso = json_lite.extractString(body, "billingPeriodEnd");
    }
    if (end_iso) |iso| {
        out.resets_at_ms = grok_session.parseIsoToEpochMs(iso) orelse 0;
    }

    if (percent == null and out.resets_at_ms > 0) percent = 0;
    if (percent) |p| {
        if (!std.math.isFinite(p)) return false;
        var pct: i64 = @intFromFloat(@round(p));
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        out.weekly_percent = pct;
    } else {
        return false;
    }

    if (json_lite.extractNumber(body, "onDemandCap")) |cap| {
        if (cap > 0) {
            const used = json_lite.extractNumber(body, "onDemandUsed") orelse 0;
            var od: i64 = @intFromFloat(@round(used / cap * 100.0));
            if (od < 0) od = 0;
            if (od > 100) od = 100;
            out.on_demand_percent = od;
        }
    }

    out.authenticated = true;
    return true;
}

/// "6d 22h" / "2h 17m" / "now" / null when unknown.
pub fn formatReset(resets_at_ms: i64, now_ms: i64, buf: []u8) ?[]const u8 {
    if (resets_at_ms <= 0) return null;
    const remaining = resets_at_ms - now_ms;
    if (remaining <= 0) return "now";
    const total_minutes: i64 = @divTrunc(remaining, 60_000);
    if (total_minutes <= 0) return "<1m";
    const days = @divTrunc(total_minutes, 24 * 60);
    const hours = @rem(@divTrunc(total_minutes, 60), 24);
    const minutes = @rem(total_minutes, 60);
    if (days > 0) {
        return std.fmt.bufPrint(buf, "{d}d {d}h", .{ days, hours }) catch null;
    }
    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m", .{ hours, minutes }) catch null;
    }
    return std.fmt.bufPrint(buf, "{d}m", .{minutes}) catch null;
}

/// "42% · resets in 6d 22h" or "42%" or "—".
pub fn formatWeeklyLine(snap: Snapshot, now_ms: i64, buf: []u8) []const u8 {
    if (snap.weekly_percent < 0) return "—";
    var reset_buf: [32]u8 = undefined;
    if (formatReset(snap.resets_at_ms, now_ms, &reset_buf)) |reset| {
        if (std.mem.eql(u8, reset, "now")) {
            return std.fmt.bufPrint(buf, "{d}% · resets now", .{snap.weekly_percent}) catch "—";
        }
        return std.fmt.bufPrint(buf, "{d}% · resets in {s}", .{ snap.weekly_percent, reset }) catch "—";
    }
    return std.fmt.bufPrint(buf, "{d}%", .{snap.weekly_percent}) catch "—";
}

test "parseBilling weekly percent and period end" {
    const body =
        \\{"config":{"creditUsagePercent":42.4,"currentPeriod":{"type":"week","start":"2026-07-15T00:00:00Z","end":"2026-07-22T00:00:00Z"}}}
    ;
    var snap: Snapshot = .{};
    try std.testing.expect(parseBilling(body, &snap));
    try std.testing.expectEqual(@as(i64, 42), snap.weekly_percent);
    try std.testing.expect(snap.resets_at_ms > 0);
}

test "formatReset duration" {
    var buf: [32]u8 = undefined;
    const now: i64 = 1_700_000_000_000;
    const reset = now + (2 * 24 * 60 + 3 * 60) * 60_000;
    try std.testing.expectEqualStrings("2d 3h", formatReset(reset, now, &buf).?);
    try std.testing.expectEqualStrings("now", formatReset(now - 1000, now, &buf).?);
}

test "formatWeeklyLine" {
    var buf: [64]u8 = undefined;
    const snap = Snapshot{ .weekly_percent = 42, .resets_at_ms = 0 };
    try std.testing.expectEqualStrings("42%", formatWeeklyLine(snap, 0, &buf));
}

test "refreshBody percent-encodes special chars" {
    var auth: Auth = .{};
    auth.setRefresh("abc+/=&xyz");
    Auth.setField(&auth.client_id, &auth.client_id_len, "client/id");
    var buf: [512]u8 = undefined;
    const body = refreshBody(&auth, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, body, "abc%2B%2F%3D%26xyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "client%2Fid") != null);
}

test "buildBillingHeaders drops userid when over budget" {
    var auth: Auth = .{};
    // ~950-byte token → core headers near the cap; userid must be dropped.
    @memset(auth.access[0..950], 'a');
    auth.access_len = 950;
    Auth.setField(&auth.user_id, &auth.user_id_len, "user-with-a-fairly-long-id-value");

    var bearer_buf: [16 + 2048]u8 = undefined;
    var headers_buf: [4]std.http.Header = undefined;
    const headers = buildBillingHeaders(&auth, &bearer_buf, &headers_buf).?;
    try std.testing.expect(headers.len == 3);
    var total: usize = 0;
    for (headers) |h| total += h.name.len + h.value.len;
    try std.testing.expect(total <= max_fetch_header_bytes);
}
