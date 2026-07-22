//! Full-loop UI tests for the presence prototype (headless).
const std = @import("std");
const main = @import("main.zig");

test "initial model is disconnected" {
    const model = main.initialModel();
    try std.testing.expectEqual(@as(i64, 0), model.conn_code);
    try std.testing.expect(!model.ready);
    try std.testing.expect(!model.presence_set);
    try std.testing.expect(model.auto_presence);
}

test "conn_label tracks conn_code" {
    var model = main.initialModel();
    try std.testing.expectEqualStrings("Disconnected", model.conn_label());
    model.conn_code = 1;
    try std.testing.expectEqualStrings("Connecting…", model.conn_label());
    model.conn_code = 2;
    model.ready = true;
    try std.testing.expectEqualStrings("Connected (READY)", model.conn_label());
}

test "presence_label tracks source" {
    var model = main.initialModel();
    try std.testing.expectEqualStrings("Presence: cleared", model.presence_label());
    model.presence_source = 1;
    try std.testing.expectEqualStrings("Presence: Grok session", model.presence_label());
    model.presence_source = 2;
    try std.testing.expectEqualStrings("Presence: manual test", model.presence_label());
}
