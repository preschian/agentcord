//! Persistent, credential-free usage snapshots.
//!
//! The cache intentionally stores only rendered usage values and reset times.
//! Authentication tokens, account IDs, and raw provider responses never enter
//! this file. A failed refresh leaves the last good snapshot in place.

const std = @import("std");
const win32_fs = @import("win32_fs.zig");
const json_lite = @import("json_lite.zig");
const codex_usage = @import("codex_usage.zig");
const cursor_usage = @import("cursor_usage.zig");
const grok_usage = @import("grok_usage.zig");

pub const Data = struct {
    codex: ?codex_usage.Snapshot = null,
    cursor: ?cursor_usage.Snapshot = null,
    grok: ?grok_usage.Snapshot = null,

    pub fn hasAny(self: *const Data) bool {
        return self.codex != null or self.cursor != null or self.grok != null;
    }
};

pub fn load(out: *Data) bool {
    out.* = .{};
    var path_buf: [360]u8 = undefined;
    const path = cachePath(&path_buf) orelse return false;
    var file_buf: [2048]u8 = undefined;
    const text = win32_fs.readFile(path, &file_buf) orelse return false;
    return parse(text, out);
}

pub fn save(data: *const Data) bool {
    if (!data.hasAny()) return false;
    var path_buf: [360]u8 = undefined;
    const path = cachePath(&path_buf) orelse return false;
    var output_buf: [2048]u8 = undefined;
    const output = serialize(data, &output_buf) orelse return false;
    return win32_fs.writeFile(path, output);
}

fn cachePath(buf: []u8) ?[]const u8 {
    var app_data_buf: [260]u8 = undefined;
    const app_data = win32_fs.appData(&app_data_buf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}\\agentcord-usage-cache-v1.json", .{app_data}) catch null;
}

pub fn parse(text: []const u8, out: *Data) bool {
    out.* = .{};
    const version = json_lite.extractI64(text, "version") orelse return false;
    if (version != 1) return false;
    readCodex(text, out);
    readCursor(text, out);
    readGrok(text, out);
    return out.hasAny();
}

fn readCodex(text: []const u8, out: *Data) void {
    const primary_percent = readPercent(text, "codex_primary_percent") orelse return;
    var snap: codex_usage.Snapshot = .{};
    snap.primary = .{
        .percent = primary_percent,
        .resets_at_ms = readEpoch(text, "codex_primary_reset_ms"),
    };
    if (json_lite.extractString(text, "codex_primary_label")) |label| {
        win32_fs.copyBounded(&snap.primary_label, &snap.primary_label_len, label);
    }
    if (readPercent(text, "codex_secondary_percent")) |secondary_percent| {
        snap.secondary = .{
            .percent = secondary_percent,
            .resets_at_ms = readEpoch(text, "codex_secondary_reset_ms"),
        };
        if (json_lite.extractString(text, "codex_secondary_label")) |label| {
            win32_fs.copyBounded(&snap.secondary_label, &snap.secondary_label_len, label);
        }
    }
    out.codex = snap;
}

fn readCursor(text: []const u8, out: *Data) void {
    const included_percent = readPercent(text, "cursor_included_percent") orelse return;
    var snap: cursor_usage.Snapshot = .{};
    snap.included = .{
        .percent = included_percent,
        .resets_at_ms = readEpoch(text, "cursor_included_reset_ms"),
    };
    if (readPercent(text, "cursor_auto_percent")) |percent| {
        snap.auto = .{ .percent = percent, .resets_at_ms = readEpoch(text, "cursor_auto_reset_ms") };
    }
    if (readPercent(text, "cursor_api_percent")) |percent| {
        snap.api = .{ .percent = percent, .resets_at_ms = readEpoch(text, "cursor_api_reset_ms") };
    }
    if (readPercent(text, "cursor_ondemand_percent")) |percent| {
        snap.on_demand = .{ .percent = percent, .resets_at_ms = readEpoch(text, "cursor_ondemand_reset_ms") };
    }
    out.cursor = snap;
}

fn readGrok(text: []const u8, out: *Data) void {
    const weekly_percent = readPercent(text, "grok_weekly_percent") orelse return;
    var snap: grok_usage.Snapshot = .{
        .weekly_percent = weekly_percent,
        .resets_at_ms = readEpoch(text, "grok_weekly_reset_ms"),
        .authenticated = true,
    };
    if (readPercent(text, "grok_ondemand_percent")) |percent| snap.on_demand_percent = percent;
    out.grok = snap;
}

fn readPercent(text: []const u8, key: []const u8) ?i64 {
    const value = json_lite.extractI64(text, key) orelse return null;
    if (value < 0 or value > 100) return null;
    return value;
}

fn readEpoch(text: []const u8, key: []const u8) i64 {
    const value = json_lite.extractI64(text, key) orelse return 0;
    return @max(0, value);
}

pub fn serialize(data: *const Data, buf: []u8) ?[]const u8 {
    const codex = data.codex orelse codex_usage.Snapshot{};
    const cursor = data.cursor orelse cursor_usage.Snapshot{};
    const grok = data.grok orelse grok_usage.Snapshot{};
    return std.fmt.bufPrint(
        buf,
        "{{\"version\":1," ++
            "\"codex_primary_percent\":{d},\"codex_primary_reset_ms\":{d},\"codex_primary_label\":\"{s}\"," ++
            "\"codex_secondary_percent\":{d},\"codex_secondary_reset_ms\":{d},\"codex_secondary_label\":\"{s}\"," ++
            "\"cursor_included_percent\":{d},\"cursor_included_reset_ms\":{d}," ++
            "\"cursor_auto_percent\":{d},\"cursor_auto_reset_ms\":{d}," ++
            "\"cursor_api_percent\":{d},\"cursor_api_reset_ms\":{d}," ++
            "\"cursor_ondemand_percent\":{d},\"cursor_ondemand_reset_ms\":{d}," ++
            "\"grok_weekly_percent\":{d},\"grok_weekly_reset_ms\":{d},\"grok_ondemand_percent\":{d}}}",
        .{
            codex.primary.percent,
            codex.primary.resets_at_ms,
            codex.primaryLabel(),
            codex.secondary.percent,
            codex.secondary.resets_at_ms,
            codex.secondaryLabel(),
            cursor.included.percent,
            cursor.included.resets_at_ms,
            cursor.auto.percent,
            cursor.auto.resets_at_ms,
            cursor.api.percent,
            cursor.api.resets_at_ms,
            cursor.on_demand.percent,
            cursor.on_demand.resets_at_ms,
            grok.weekly_percent,
            grok.resets_at_ms,
            grok.on_demand_percent,
        },
    ) catch null;
}

test "round trips credential-free provider usage" {
    var data: Data = .{};
    var codex: codex_usage.Snapshot = .{};
    codex.primary = .{ .percent = 51, .resets_at_ms = 1_785_276_745_000 };
    win32_fs.copyBounded(&codex.primary_label, &codex.primary_label_len, "Weekly limit");
    data.codex = codex;
    data.cursor = .{
        .included = .{ .percent = 58, .resets_at_ms = 1_785_000_000_000 },
        .auto = .{ .percent = 65, .resets_at_ms = 1_785_000_000_000 },
    };
    data.grok = .{ .weekly_percent = 42, .resets_at_ms = 1_785_000_000_000 };

    var buffer: [2048]u8 = undefined;
    const text = serialize(&data, &buffer).?;
    try std.testing.expect(std.mem.indexOf(u8, text, "access_token") == null);
    var restored: Data = .{};
    try std.testing.expect(parse(text, &restored));
    try std.testing.expectEqual(@as(i64, 51), restored.codex.?.primary.percent);
    try std.testing.expectEqualStrings("Weekly limit", restored.codex.?.primaryLabel());
    try std.testing.expectEqual(@as(i64, 65), restored.cursor.?.auto.percent);
    try std.testing.expectEqual(@as(i64, 42), restored.grok.?.weekly_percent);
}
