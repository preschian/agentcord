//! Full-loop UI tests for the presence prototype (headless).
const std = @import("std");
const main = @import("main.zig");
const presence = @import("presence.zig");
const discord_ipc = @import("discord_ipc.zig");
const codex_session = @import("codex_session.zig");
const grok_session = @import("grok_session.zig");

test "initial model is disconnected" {
    const model = main.initialModel();
    try std.testing.expect(model.conn_state == .disconnected);
    try std.testing.expect(!model.ready);
    try std.testing.expect(!model.presence_set());
    try std.testing.expect(model.auto_presence);
    try std.testing.expect(model.selected_agent == .codex);
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
    model.presence_mode = .codex_auto;
    try std.testing.expectEqualStrings("Presence: Codex session", model.presence_label());
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
    try std.testing.expect(model.agent_is_codex());
    try std.testing.expect(!model.agent_is_cursor());
    try std.testing.expectEqualStrings("Codex", model.agent_name());
    model.selected_agent = .cursor;
    try std.testing.expect(model.agent_is_cursor());
    try std.testing.expectEqualStrings("Cursor", model.agent_name());
}

test "active session card never displays token counts" {
    var model = main.initialModel();

    var codex: codex_session.SessionInfo = .{};
    codex_session.SessionInfo.setField(&codex.model, &codex.model_len, "GPT-5.6 terra");
    codex.total_tokens = 203_600;
    codex.activity_ms = 2_000;
    model.applySessions(codex, null, null, 3_000, .codex, true, false, false);
    try std.testing.expectEqualStrings("GPT-5.6 terra", model.meta_text());
    try std.testing.expect(std.mem.indexOf(u8, model.meta_text(), "token") == null);

    var grok: grok_session.SessionInfo = .{};
    grok_session.SessionInfo.setField(&grok.model, &grok.model_len, "Grok 4.5");
    grok.total_tokens = 81_200;
    grok.activity_ms = 4_000;
    model.applySessions(null, grok, null, 5_000, .grok, false, true, false);
    try std.testing.expectEqualStrings("Grok 4.5", model.meta_text());
    try std.testing.expect(std.mem.indexOf(u8, model.meta_text(), "token") == null);
}
