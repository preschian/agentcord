//! Grok weekly credit usage (CLI / SuperGrok billing).
//!
//! Port of macOS `GrokUsage.swift`:
//!   GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
//!   using OIDC tokens from `~/.grok/auth.json` (`key` + `refresh_token`).

const std = @import("std");
const grok_session = @import("grok_session.zig");

pub const billing_url = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
pub const token_auth_header = "xai-grok-cli";

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

/// Load the first OIDC credential entry from `~/.grok/auth.json`.
/// Access token lives in the `key` field (Grok CLI convention).
pub fn loadAuth(out: *Auth) bool {
    var home_buf: [260]u8 = undefined;
    const home = grok_session.userProfile(&home_buf) orelse return false;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\.grok\\auth.json", .{home}) catch return false;
    var file_buf: [16 * 1024]u8 = undefined;
    const json = grok_session.readFile(path, &file_buf) orelse return false;

    // auth.json is a map of account-key → credential object. Walk objects.
    var search: usize = 0;
    while (nextObject(json, &search)) |obj| {
        const access = grok_session.extractString(obj, "key");
        const refresh = grok_session.extractString(obj, "refresh_token");
        const has_access = access != null and access.?.len > 0;
        const has_refresh = refresh != null and refresh.?.len > 0;
        if (!has_access and !has_refresh) continue;

        out.* = .{};
        if (access) |a| out.setAccess(a);
        if (refresh) |r| Auth.setField(&out.refresh, &out.refresh_len, r);
        if (grok_session.extractString(obj, "oidc_client_id")) |c| {
            Auth.setField(&out.client_id, &out.client_id_len, c);
        }
        if (grok_session.extractString(obj, "oidc_issuer")) |iss| {
            Auth.setField(&out.issuer, &out.issuer_len, iss);
        } else {
            Auth.setField(&out.issuer, &out.issuer_len, "https://auth.x.ai");
        }
        if (grok_session.extractString(obj, "user_id")) |u| {
            Auth.setField(&out.user_id, &out.user_id_len, u);
        }
        return true;
    }
    return false;
}

pub fn tokenUrl(auth: *const Auth, buf: []u8) ?[]const u8 {
    const issuer = if (auth.issuer_len > 0) auth.issuerSlice() else "https://auth.x.ai";
    // Trim trailing slash.
    var base = issuer;
    while (base.len > 0 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];
    return std.fmt.bufPrint(buf, "{s}/oauth2/token", .{base}) catch null;
}

pub fn refreshBody(auth: *const Auth, buf: []u8) ?[]const u8 {
    // application/x-www-form-urlencoded
    return std.fmt.bufPrint(
        buf,
        "grant_type=refresh_token&refresh_token={s}&client_id={s}",
        .{ auth.refreshSlice(), auth.clientIdSlice() },
    ) catch null;
}

/// Parse billing JSON into a Snapshot. Returns false when unusable.
pub fn parseBilling(body: []const u8, out: *Snapshot) bool {
    out.weekly_percent = -1;
    out.resets_at_ms = 0;
    out.on_demand_percent = -1;

    // Prefer nested config.creditUsagePercent, fall back to top-level.
    var percent: ?f64 = null;
    if (extractNumber(body, "creditUsagePercent")) |p| percent = p;

    // Period end: currentPeriod.end or billingPeriodEnd.
    var end_iso: ?[]const u8 = null;
    if (std.mem.indexOf(u8, body, "\"currentPeriod\"")) |at| {
        const slice = body[at..@min(body.len, at + 400)];
        end_iso = grok_session.extractString(slice, "end");
    }
    if (end_iso == null) {
        end_iso = grok_session.extractString(body, "billingPeriodEnd");
    }
    if (end_iso) |iso| {
        out.resets_at_ms = grok_session.parseIsoToEpochMs(iso) orelse 0;
    }

    // Unified-billing accounts may omit percent but still report a period → 0%.
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

    // On-demand when cap > 0.
    if (extractNumber(body, "onDemandCap")) |cap| {
        if (cap > 0) {
            const used = extractNumber(body, "onDemandUsed") orelse 0;
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

fn extractNumber(json: []const u8, key: []const u8) ?f64 {
    var pattern_buf: [96]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;
    const key_at = std.mem.indexOf(u8, json, pattern) orelse return null;
    var i = key_at + pattern.len;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    if (i >= json.len or json[i] != ':') return null;
    i += 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    const start = i;
    if (i < json.len and (json[i] == '-' or json[i] == '+')) i += 1;
    while (i < json.len and ((json[i] >= '0' and json[i] <= '9') or json[i] == '.' or json[i] == 'e' or json[i] == 'E' or json[i] == '+' or json[i] == '-')) : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseFloat(f64, json[start..i]) catch null;
}

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
    // 2 days + 3 hours
    const reset = now + (2 * 24 * 60 + 3 * 60) * 60_000;
    try std.testing.expectEqualStrings("2d 3h", formatReset(reset, now, &buf).?);
    try std.testing.expectEqualStrings("now", formatReset(now - 1000, now, &buf).?);
}

test "formatWeeklyLine" {
    var buf: [64]u8 = undefined;
    const snap = Snapshot{ .weekly_percent = 42, .resets_at_ms = 0 };
    try std.testing.expectEqualStrings("42%", formatWeeklyLine(snap, 0, &buf));
}
