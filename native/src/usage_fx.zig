//! Shared usage-fetch helpers (Grok + Cursor) so main stays under the line budget.

const std = @import("std");
const native_sdk = @import("native_sdk");
const cursor_usage = @import("cursor_usage.zig");

pub const CursorPhase = enum { idle, period, legacy };

pub const CursorState = struct {
    auth: cursor_usage.Auth = .{},
    phase: CursorPhase = .idle,
    tried_alt: bool = false,
    membership: [32]u8 = .{0} ** 32,
    membership_len: usize = 0,

    pub fn membershipSlice(self: *const CursorState) []const u8 {
        return self.membership[0..self.membership_len];
    }

    pub fn reloadMembership(self: *CursorState) void {
        self.membership_len = 0;
        var buf: [32]u8 = undefined;
        if (cursor_usage.loadMembership(&buf)) |m| {
            const n = @min(m.len, self.membership.len);
            @memcpy(self.membership[0..n], m[0..n]);
            self.membership_len = n;
        }
    }

    pub fn applyMembership(self: *const CursorState, snap: *cursor_usage.Snapshot) void {
        if (snap.plan_name_len == 0 and self.membership_len > 0) {
            snap.setPlanName(self.membershipSlice());
        }
    }
};

/// Map non-OK fetch transport outcomes to a UI status string. Null means `.ok`.
pub fn transportStatus(outcome: native_sdk.EffectFetchOutcome, comptime label: []const u8) ?[]const u8 {
    return switch (outcome) {
        .ok => null,
        .rejected => label ++ " fetch rejected (headers over 1 KiB budget)",
        .connect_failed, .tls_failed, .protocol_failed => "Network error fetching " ++ label,
        .timed_out => label ++ " fetch timed out",
        .cancelled => label ++ " fetch cancelled",
    };
}

pub fn copyBody(response: native_sdk.EffectResponse, buf: []u8) []const u8 {
    const n = @min(response.body.len, buf.len);
    @memcpy(buf[0..n], response.body[0..n]);
    return buf[0..n];
}

pub fn httpStatusMsg(status: u16, buf: []u8, comptime prefix: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} HTTP {d}", .{ prefix, status }) catch prefix ++ " error";
}
