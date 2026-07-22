//! Discord presence policy: mode, decisions, and Activity builders.

const std = @import("std");
const discord_ipc = @import("discord_ipc.zig");
const grok_session = @import("grok_session.zig");
const cursor_session = @import("cursor_session.zig");

pub const Mode = enum {
    cleared,
    grok_auto,
    cursor_auto,
    manual_test,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .cleared => "Presence: cleared",
            .grok_auto => "Presence: Grok session",
            .cursor_auto => "Presence: Cursor session",
            .manual_test => "Presence: manual test",
        };
    }
};

pub const Action = enum {
    /// UI detail only; do not touch Discord activity.
    detail_only,
    set,
    clear,
};

pub const Decision = struct {
    action: Action = .detail_only,
    mode: Mode = .cleared,
    activity: ?discord_ipc.Activity = null,
    detail: []const u8 = "",
};

pub const LiveSessions = struct {
    grok: ?grok_session.SessionInfo = null,
    cursor: ?cursor_session.SessionInfo = null,
};

/// Scratch buffers for detail/activity strings owned by the caller for one apply.
pub const Scratch = struct {
    detail: [200]u8 = undefined,
    state: [64]u8 = undefined,
    details: [128]u8 = undefined,
    tokens: [32]u8 = undefined,
};

const Winner = enum { none, grok, cursor };

pub fn activityManualTest(now_ms: i64) discord_ipc.Activity {
    return .{
        .type = 0,
        .name = "Grok 4.5",
        .details = "Working on: agentcord",
        .state = "manual test presence",
        .large_image = "logo-grok",
        .large_text = "Grok",
        .start_ms = now_ms,
    };
}

pub fn activityFromGrok(s: grok_session.SessionInfo, scratch: *Scratch) discord_ipc.Activity {
    const state: []const u8 = if (s.total_tokens > 0) blk: {
        const tok = grok_session.formatTokens(s.total_tokens, &scratch.tokens);
        break :blk std.fmt.bufPrint(&scratch.state, "{s} tokens", .{tok}) catch "Grok session";
    } else "Grok session";

    const details = std.fmt.bufPrint(&scratch.details, "Working on: {s}", .{s.project()}) catch "Working on: Grok";

    return .{
        .type = 0,
        .name = s.modelName(),
        .details = details,
        .state = state,
        .large_image = "logo-grok",
        .large_text = "Grok",
        .start_ms = if (s.start_epoch_ms > 0) s.start_epoch_ms else 0,
    };
}

pub fn activityFromCursor(s: cursor_session.SessionInfo, scratch: *Scratch) discord_ipc.Activity {
    const details = std.fmt.bufPrint(&scratch.details, "Working on: {s}", .{s.project()}) catch "Working on: Cursor";
    return .{
        .type = 0,
        .name = "Cursor",
        .details = details,
        .state = "Cursor session",
        .large_image = "logo-cursor",
        .large_text = "Cursor",
        .start_ms = if (s.start_epoch_ms > 0) s.start_epoch_ms else 0,
    };
}

fn pickWinner(sessions: LiveSessions) Winner {
    const grok_ms: i64 = if (sessions.grok) |s| activityMs(s.activity_ms, s.start_epoch_ms) else 0;
    const cursor_ms: i64 = if (sessions.cursor) |s| activityMs(s.activity_ms, s.start_epoch_ms) else 0;

    if (sessions.grok != null and sessions.cursor != null) {
        // Same clock: last activity (macOS lastModified max). Unknown (0) loses ties.
        return if (cursor_ms >= grok_ms) .cursor else .grok;
    }
    if (sessions.cursor != null) return .cursor;
    if (sessions.grok != null) return .grok;
    return .none;
}

fn activityMs(activity: i64, start: i64) i64 {
    if (activity > 0) return activity;
    if (start > 0) return start;
    return 0;
}

fn liveSummary(sessions: LiveSessions, scratch: *Scratch, suffix: []const u8) []const u8 {
    return switch (pickWinner(sessions)) {
        .grok => blk: {
            const s = sessions.grok.?;
            break :blk std.fmt.bufPrint(
                &scratch.detail,
                "Grok live · {s} · {s}{s}",
                .{ s.modelName(), s.project(), suffix },
            ) catch "Grok live";
        },
        .cursor => blk: {
            const s = sessions.cursor.?;
            break :blk std.fmt.bufPrint(
                &scratch.detail,
                "Cursor live · {s}{s}",
                .{ s.project(), suffix },
            ) catch "Cursor live";
        },
        .none => "",
    };
}

/// Decide what Discord / UI should do for one poll tick.
/// `paused` is set after manual Disconnect until Connect.
pub fn decide(
    mode: Mode,
    auto: bool,
    paused: bool,
    discord_ready: bool,
    sessions: LiveSessions,
    scratch: *Scratch,
) Decision {
    const winner = pickWinner(sessions);

    if (!auto) {
        if (winner != .none) {
            return .{
                .action = .detail_only,
                .mode = mode,
                .detail = liveSummary(sessions, scratch, " (auto off)"),
            };
        }
        return .{ .action = .detail_only, .mode = mode, .detail = "No live session (auto off)." };
    }

    if (paused or !discord_ready) {
        if (winner != .none) {
            const suffix = if (paused) " (Discord paused)" else " (Discord not ready)";
            return .{
                .action = .detail_only,
                .mode = mode,
                .detail = liveSummary(sessions, scratch, suffix),
            };
        }
        const d: []const u8 = if (paused)
            "Disconnected — presence paused until Connect."
        else
            "Waiting for Discord READY…";
        return .{ .action = .detail_only, .mode = mode, .detail = d };
    }

    // Don't override manual test until the user clears it or a session takes over.
    if (mode == .manual_test and winner == .none) {
        return .{
            .action = .detail_only,
            .mode = .manual_test,
            .detail = "Manual test presence active; no live session.",
        };
    }

    switch (winner) {
        .grok => {
            const s = sessions.grok.?;
            const act = activityFromGrok(s, scratch);
            const d = std.fmt.bufPrint(
                &scratch.detail,
                "Auto · {s} · {s}",
                .{ s.modelName(), s.project() },
            ) catch "Auto presence";
            return .{ .action = .set, .mode = .grok_auto, .activity = act, .detail = d };
        },
        .cursor => {
            const s = sessions.cursor.?;
            const act = activityFromCursor(s, scratch);
            const d = std.fmt.bufPrint(
                &scratch.detail,
                "Auto · Cursor · {s}",
                .{s.project()},
            ) catch "Auto presence";
            return .{ .action = .set, .mode = .cursor_auto, .activity = act, .detail = d };
        },
        .none => {},
    }

    if (mode == .grok_auto or mode == .cursor_auto) {
        return .{
            .action = .clear,
            .mode = .cleared,
            .detail = "No live session — presence cleared.",
        };
    }

    return .{
        .action = .detail_only,
        .mode = .cleared,
        .detail = "Waiting for a live Grok or Cursor session…",
    };
}

test "decide pauses writes when disconnected" {
    var scratch: Scratch = .{};
    const d = decide(.cleared, true, true, false, .{}, &scratch);
    try std.testing.expect(d.action == .detail_only);
    try std.testing.expect(std.mem.indexOf(u8, d.detail, "paused") != null);
}

test "decide sets grok activity when ready" {
    var scratch: Scratch = .{};
    var session: grok_session.SessionInfo = .{};
    grok_session.SessionInfo.setField(&session.model, &session.model_len, "Grok 4.5");
    grok_session.SessionInfo.setField(&session.project_name, &session.project_len, "agentcord");
    session.start_epoch_ms = 1000;
    const d = decide(.cleared, true, false, true, .{ .grok = session }, &scratch);
    try std.testing.expect(d.action == .set);
    try std.testing.expect(d.mode == .grok_auto);
    try std.testing.expectEqualStrings("logo-grok", d.activity.?.large_image);
}

test "decide prefers newer cursor over grok" {
    var scratch: Scratch = .{};
    var grok: grok_session.SessionInfo = .{};
    grok_session.SessionInfo.setField(&grok.model, &grok.model_len, "Grok 4.5");
    grok_session.SessionInfo.setField(&grok.project_name, &grok.project_len, "old");
    grok.start_epoch_ms = 1000;
    grok.activity_ms = 1000;

    var cursor: cursor_session.SessionInfo = .{};
    cursor_session.SessionInfo.setField(&cursor.project_name, &cursor.project_len, "agentcord");
    cursor.activity_ms = 5000;
    cursor.start_epoch_ms = 4000;

    const d = decide(.cleared, true, false, true, .{ .grok = grok, .cursor = cursor }, &scratch);
    try std.testing.expect(d.action == .set);
    try std.testing.expect(d.mode == .cursor_auto);
    try std.testing.expectEqualStrings("logo-cursor", d.activity.?.large_image);
}

test "decide prefers newer grok activity over cursor" {
    var scratch: Scratch = .{};
    var grok: grok_session.SessionInfo = .{};
    grok_session.SessionInfo.setField(&grok.model, &grok.model_len, "Grok 4.5");
    grok_session.SessionInfo.setField(&grok.project_name, &grok.project_len, "agentcord");
    grok.start_epoch_ms = 1000;
    grok.activity_ms = 9000;

    var cursor: cursor_session.SessionInfo = .{};
    cursor_session.SessionInfo.setField(&cursor.project_name, &cursor.project_len, "other");
    cursor.activity_ms = 5000;
    cursor.start_epoch_ms = 4000;

    const d = decide(.cleared, true, false, true, .{ .grok = grok, .cursor = cursor }, &scratch);
    try std.testing.expect(d.action == .set);
    try std.testing.expect(d.mode == .grok_auto);
}

test "decide missing grok activity does not always win" {
    var scratch: Scratch = .{};
    var grok: grok_session.SessionInfo = .{};
    grok_session.SessionInfo.setField(&grok.model, &grok.model_len, "Grok");
    grok_session.SessionInfo.setField(&grok.project_name, &grok.project_len, "x");
    // start/activity both 0 — unknown clock must not beat Cursor.

    var cursor: cursor_session.SessionInfo = .{};
    cursor_session.SessionInfo.setField(&cursor.project_name, &cursor.project_len, "agentcord");
    cursor.activity_ms = 5000;

    const d = decide(.cleared, true, false, true, .{ .grok = grok, .cursor = cursor }, &scratch);
    try std.testing.expect(d.mode == .cursor_auto);
}

test "decide sets cursor-only activity" {
    var scratch: Scratch = .{};
    var cursor: cursor_session.SessionInfo = .{};
    cursor_session.SessionInfo.setField(&cursor.project_name, &cursor.project_len, "agentcord");
    cursor.activity_ms = 5000;
    const d = decide(.cleared, true, false, true, .{ .cursor = cursor }, &scratch);
    try std.testing.expect(d.action == .set);
    try std.testing.expect(d.mode == .cursor_auto);
}
