//! Discord presence policy: mode, decisions, and Activity builders.

const std = @import("std");
const discord_ipc = @import("discord_ipc.zig");
const grok_session = @import("grok_session.zig");

pub const Mode = enum {
    cleared,
    grok_auto,
    manual_test,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .cleared => "Presence: cleared",
            .grok_auto => "Presence: Grok session",
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

/// Scratch buffers for detail/activity strings owned by the caller for one apply.
pub const Scratch = struct {
    detail: [200]u8 = undefined,
    state: [64]u8 = undefined,
    details: [128]u8 = undefined,
    tokens: [32]u8 = undefined,
};

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

/// Decide what Discord / UI should do for one poll tick.
/// `paused` is set after manual Disconnect until Connect.
pub fn decide(
    mode: Mode,
    auto: bool,
    paused: bool,
    discord_ready: bool,
    session: ?grok_session.SessionInfo,
    scratch: *Scratch,
) Decision {
    if (!auto) {
        if (session) |s| {
            const d = std.fmt.bufPrint(
                &scratch.detail,
                "Grok live · {s} · {s} (auto off)",
                .{ s.modelName(), s.project() },
            ) catch "Grok live";
            return .{ .action = .detail_only, .mode = mode, .detail = d };
        }
        return .{ .action = .detail_only, .mode = mode, .detail = "No live Grok session (auto off)." };
    }

    if (paused or !discord_ready) {
        if (session) |s| {
            const d = std.fmt.bufPrint(
                &scratch.detail,
                "Grok live · {s} · {s} (Discord {s})",
                .{ s.modelName(), s.project(), if (paused) "paused" else "not ready" },
            ) catch "Grok live";
            return .{ .action = .detail_only, .mode = mode, .detail = d };
        }
        const d: []const u8 = if (paused)
            "Disconnected — presence paused until Connect."
        else
            "Waiting for Discord READY…";
        return .{ .action = .detail_only, .mode = mode, .detail = d };
    }

    // Don't override manual test until the user clears it or Grok takes over.
    if (mode == .manual_test and session == null) {
        return .{
            .action = .detail_only,
            .mode = .manual_test,
            .detail = "Manual test presence active; no live Grok session.",
        };
    }

    if (session) |s| {
        const act = activityFromGrok(s, scratch);
        const d = std.fmt.bufPrint(
            &scratch.detail,
            "Auto · {s} · {s}",
            .{ s.modelName(), s.project() },
        ) catch "Auto presence";
        return .{ .action = .set, .mode = .grok_auto, .activity = act, .detail = d };
    }

    if (mode == .grok_auto) {
        return .{
            .action = .clear,
            .mode = .cleared,
            .detail = "No live Grok session — presence cleared.",
        };
    }

    return .{
        .action = .detail_only,
        .mode = .cleared,
        .detail = "Waiting for a live Grok CLI session…",
    };
}

test "decide pauses writes when disconnected" {
    var scratch: Scratch = .{};
    const d = decide(.cleared, true, true, false, null, &scratch);
    try std.testing.expect(d.action == .detail_only);
    try std.testing.expect(std.mem.indexOf(u8, d.detail, "paused") != null);
}

test "decide sets grok activity when ready" {
    var scratch: Scratch = .{};
    var session: grok_session.SessionInfo = .{};
    grok_session.SessionInfo.setField(&session.model, &session.model_len, "Grok 4.5");
    grok_session.SessionInfo.setField(&session.project_name, &session.project_len, "agentcord");
    const d = decide(.cleared, true, false, true, session, &scratch);
    try std.testing.expect(d.action == .set);
    try std.testing.expect(d.mode == .grok_auto);
    try std.testing.expectEqualStrings("logo-grok", d.activity.?.large_image);
}
