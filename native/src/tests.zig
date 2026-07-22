//! Full-loop UI tests for the presence prototype (headless).
const std = @import("std");
const main = @import("main.zig");
const presence = @import("presence.zig");
const discord_ipc = @import("discord_ipc.zig");

test "initial model is disconnected" {
    const model = main.initialModel();
    try std.testing.expect(model.conn_state == .disconnected);
    try std.testing.expect(!model.ready);
    try std.testing.expect(!model.presence_set());
    try std.testing.expect(model.auto_presence);
    try std.testing.expect(model.selected_agent == .grok);
}

test "conn_label tracks conn_state" {
    var model = main.initialModel();
    try std.testing.expectEqualStrings("Disconnected", model.conn_label());
    model.conn_state = .connecting;
    try std.testing.expectEqualStrings("Connecting…", model.conn_label());
    model.conn_state = .connected;
    model.ready = true;
    try std.testing.expectEqualStrings("Connected", model.conn_label());
    _ = discord_ipc.ConnState.disconnected;
}

test "presence_label tracks mode" {
    var model = main.initialModel();
    try std.testing.expectEqualStrings("Presence: cleared", model.presence_label());
    model.presence_mode = .grok_auto;
    try std.testing.expectEqualStrings("Presence: Grok session", model.presence_label());
    model.presence_mode = .cursor_auto;
    try std.testing.expectEqualStrings("Presence: Cursor session", model.presence_label());
    model.presence_mode = .manual_test;
    try std.testing.expectEqualStrings("Presence: manual test", model.presence_label());
    _ = presence.Mode.cleared;
}

test "presence_enabled respects pause and auto" {
    var model = main.initialModel();
    try std.testing.expect(model.presence_enabled());
    model.presence_paused = true;
    try std.testing.expect(!model.presence_enabled());
    model.presence_paused = false;
    model.auto_presence = false;
    try std.testing.expect(!model.presence_enabled());
}

test "agent selection helpers" {
    var model = main.initialModel();
    try std.testing.expect(model.agent_is_grok());
    try std.testing.expect(!model.agent_is_cursor());
    try std.testing.expectEqualStrings("Grok", model.agent_name());
    model.selected_agent = .cursor;
    try std.testing.expect(model.agent_is_cursor());
    try std.testing.expectEqualStrings("Cursor", model.agent_name());
}
