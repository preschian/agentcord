//! UI model and state projection for the AgentCord Native SDK workspace.

const std = @import("std");
const codex_session = @import("codex_session.zig");
const codex_usage = @import("codex_usage.zig");
const discord_ipc = @import("discord_ipc.zig");
const grok_session = @import("grok_session.zig");
const cursor_session = @import("cursor_session.zig");
const grok_usage = @import("grok_usage.zig");
const cursor_usage = @import("cursor_usage.zig");
const presence = @import("presence.zig");

pub const AgentKind = enum {
    codex,
    cursor,
    grok,

    pub fn displayName(self: AgentKind) []const u8 {
        return switch (self) {
            .codex => "Codex",
            .cursor => "Cursor",
            .grok => "Grok",
        };
    }

    pub fn providerName(self: AgentKind) []const u8 {
        return switch (self) {
            .codex => "OpenAI",
            .cursor => "Cursor",
            .grok => "xAI",
        };
    }
};

pub const Model = struct {
    /// Internal / helper state not bound directly in markup (accessors are).
    pub const view_unbound = .{
        "conn_state",           "ready",                 "auto_presence",
        "presence_paused",      "presence_mode",         "selected_agent",
        "status_line",          "status_len",            "detail_line",
        "detail_len",           "error_line",            "grok_active",
        "cursor_active",        "cursor_installed",      "grok_linked",
        "session_title_line",   "session_title_len",     "elapsed_line",
        "elapsed_len",          "project_line",          "project_len",
        "meta_line",            "meta_len",              "broadcast_line",
        "broadcast_len",        "connect_subtitle_line", "connect_subtitle_len",
        "status_pill_line",     "status_pill_len",
        "usage_weekly_line",     "usage_weekly_len",
        "usage_ondemand_line",  "usage_status_line",     "usage_status_len",
        "cursor_included_line", "cursor_included_len",   "cursor_auto_line",
        "cursor_auto_len",      "cursor_api_line",       "cursor_api_len",
        "cursor_ondemand_line", "cursor_ondemand_len",   "cursor_status_line",
        "cursor_status_len",    "cursor_plan_line",      "cursor_plan_len",
        "codex_active",         "codex_primary_line",    "codex_primary_len",
        "codex_secondary_line", "codex_usage_status_line", "codex_usage_status_len",
        "codex_plan_line",      "codex_plan_len",
        "presence_set",         "status_text",           "detail_text",
        "conn_label",           "presence_label",        "grok_status_label",
        "cursor_plan_text",
        "enabled_agent_count",  "linked_agent_count",
    };

    conn_state: discord_ipc.ConnState = .disconnected,
    ready: bool = false,
    /// Auto-push session activity to Discord (macOS "Enable presence").
    auto_presence: bool = true,
    /// After Disconnect, skip Discord writes until Connect.
    presence_paused: bool = false,
    presence_mode: presence.Mode = .cleared,
    selected_agent: AgentKind = .codex,
    unified_usage: bool = false,

    codex_enabled: bool = true,
    cursor_enabled: bool = true,
    grok_enabled: bool = true,
    status_line: [160]u8 = .{0} ** 160,
    status_len: usize = 0,
    detail_line: [200]u8 = .{0} ** 200,
    detail_len: usize = 0,
    error_line: [160]u8 = .{0} ** 160,
    error_len: usize = 0,

    // --- selected-agent session card ---
    codex_active: bool = false,
    codex_installed: bool = false,
    grok_active: bool = false,
    cursor_active: bool = false,
    cursor_installed: bool = false,
    grok_linked: bool = false,
    show_connect_card: bool = false,

    session_title_line: [32]u8 = .{0} ** 32,
    session_title_len: usize = 0,
    elapsed_line: [16]u8 = .{0} ** 16,
    elapsed_len: usize = 0,
    project_line: [96]u8 = .{0} ** 96,
    project_len: usize = 0,
    meta_line: [96]u8 = .{0} ** 96,
    meta_len: usize = 0,
    broadcast_line: [80]u8 = .{0} ** 80,
    broadcast_len: usize = 0,
    connect_subtitle_line: [120]u8 = .{0} ** 120,
    connect_subtitle_len: usize = 0,
    status_pill_line: [32]u8 = .{0} ** 32,
    status_pill_len: usize = 0,

    /// Weekly credits from billing API.
    usage_has_data: bool = false,
    usage_weekly_line: [80]u8 = .{0} ** 80,
    usage_weekly_len: usize = 0,
    usage_ondemand_line: [80]u8 = .{0} ** 80,
    usage_ondemand_len: usize = 0,
    usage_status_line: [96]u8 = .{0} ** 96,
    usage_status_len: usize = 0,
    usage_weekly_frac: f32 = 0,
    usage_ondemand_frac: f32 = 0,

    cursor_usage_has_data: bool = false,
    cursor_included_line: [80]u8 = .{0} ** 80,
    cursor_included_len: usize = 0,
    cursor_included_frac: f32 = 0,
    cursor_auto_line: [80]u8 = .{0} ** 80,
    cursor_auto_len: usize = 0,
    cursor_auto_frac: f32 = 0,
    cursor_api_line: [80]u8 = .{0} ** 80,
    cursor_api_len: usize = 0,
    cursor_api_frac: f32 = 0,
    cursor_ondemand_line: [80]u8 = .{0} ** 80,
    cursor_ondemand_len: usize = 0,
    cursor_ondemand_frac: f32 = 0,
    cursor_status_line: [96]u8 = .{0} ** 96,
    cursor_status_len: usize = 0,
    cursor_plan_line: [40]u8 = .{0} ** 40,
    cursor_plan_len: usize = 0,

    codex_usage_has_data: bool = false,
    codex_primary_line: [80]u8 = .{0} ** 80,
    codex_primary_len: usize = 0,
    codex_primary_frac: f32 = 0,
    codex_secondary_line: [80]u8 = .{0} ** 80,
    codex_secondary_len: usize = 0,
    codex_secondary_frac: f32 = 0,
    codex_usage_status_line: [96]u8 = .{0} ** 96,
    codex_usage_status_len: usize = 0,
    codex_plan_line: [32]u8 = .{0} ** 32,
    codex_plan_len: usize = 0,

    pub fn presence_set(model: *const Model) bool {
        return model.presence_mode != .cleared;
    }

    pub fn presence_enabled(model: *const Model) bool {
        return model.auto_presence and !model.presence_paused;
    }

    pub fn agent_is_grok(model: *const Model) bool {
        return model.selected_agent == .grok;
    }
    pub fn agent_is_codex(model: *const Model) bool {
        return model.selected_agent == .codex;
    }
    pub fn agent_is_cursor(model: *const Model) bool {
        return model.selected_agent == .cursor;
    }
    pub fn agent_name(model: *const Model) []const u8 {
        return model.selected_agent.displayName();
    }
    pub fn agent_initial(model: *const Model) []const u8 {
        return model.selected_agent.displayName()[0..1];
    }

    pub fn enabled_agent_count(model: *const Model) u8 {
        var count: u8 = 0;
        if (model.codex_enabled) count += 1;
        if (model.cursor_enabled) count += 1;
        if (model.grok_enabled) count += 1;
        return count;
    }
    pub fn show_agent_switcher(model: *const Model) bool {
        return model.enabled_agent_count() > 1;
    }
    pub fn agent_linked(model: *const Model, agent: AgentKind) bool {
        return switch (agent) {
            .codex => model.codex_installed,
            .cursor => model.cursor_installed,
            .grok => model.grok_linked,
        };
    }
    pub fn linked_agent_count(model: *const Model) u8 {
        var count: u8 = 0;
        if (model.codex_installed and model.codex_enabled) count += 1;
        if (model.cursor_installed and model.cursor_enabled) count += 1;
        if (model.grok_linked and model.grok_enabled) count += 1;
        return count;
    }
    pub fn has_connected_agents(model: *const Model) bool {
        return model.linked_agent_count() > 0;
    }
    pub fn selected_agent_active(model: *const Model) bool {
        return switch (model.selected_agent) {
            .codex => model.codex_active,
            .cursor => model.cursor_active,
            .grok => model.grok_active,
        };
    }
    pub fn status_text(model: *const Model) []const u8 {
        return model.status_line[0..model.status_len];
    }
    pub fn detail_text(model: *const Model) []const u8 {
        return model.detail_line[0..model.detail_len];
    }
    pub fn error_text(model: *const Model) []const u8 {
        return model.error_line[0..model.error_len];
    }
    pub fn session_title(model: *const Model) []const u8 {
        return model.session_title_line[0..model.session_title_len];
    }
    pub fn elapsed_text(model: *const Model) []const u8 {
        return model.elapsed_line[0..model.elapsed_len];
    }
    pub fn project_text(model: *const Model) []const u8 {
        return model.project_line[0..model.project_len];
    }
    pub fn meta_text(model: *const Model) []const u8 {
        return model.meta_line[0..model.meta_len];
    }
    pub fn broadcast_text(model: *const Model) []const u8 {
        return model.broadcast_line[0..model.broadcast_len];
    }
    pub fn connect_subtitle(model: *const Model) []const u8 {
        return model.connect_subtitle_line[0..model.connect_subtitle_len];
    }
    pub fn status_pill_text(model: *const Model) []const u8 {
        return model.status_pill_line[0..model.status_pill_len];
    }
    pub fn usage_weekly_text(model: *const Model) []const u8 {
        return model.usage_weekly_line[0..model.usage_weekly_len];
    }
    pub fn usage_ondemand_text(model: *const Model) []const u8 {
        return model.usage_ondemand_line[0..model.usage_ondemand_len];
    }
    pub fn usage_status_text(model: *const Model) []const u8 {
        return model.usage_status_line[0..model.usage_status_len];
    }
    pub fn cursor_included_text(model: *const Model) []const u8 {
        return model.cursor_included_line[0..model.cursor_included_len];
    }
    pub fn cursor_auto_text(model: *const Model) []const u8 {
        return model.cursor_auto_line[0..model.cursor_auto_len];
    }
    pub fn cursor_api_text(model: *const Model) []const u8 {
        return model.cursor_api_line[0..model.cursor_api_len];
    }
    pub fn cursor_ondemand_text(model: *const Model) []const u8 {
        return model.cursor_ondemand_line[0..model.cursor_ondemand_len];
    }
    pub fn cursor_status_text(model: *const Model) []const u8 {
        return model.cursor_status_line[0..model.cursor_status_len];
    }
    pub fn cursor_plan_text(model: *const Model) []const u8 {
        return model.cursor_plan_line[0..model.cursor_plan_len];
    }
    pub fn codex_primary_text(model: *const Model) []const u8 {
        return model.codex_primary_line[0..model.codex_primary_len];
    }
    pub fn codex_secondary_text(model: *const Model) []const u8 {
        return model.codex_secondary_line[0..model.codex_secondary_len];
    }
    pub fn codex_usage_status_text(model: *const Model) []const u8 {
        return model.codex_usage_status_line[0..model.codex_usage_status_len];
    }
    pub fn codex_plan_text(model: *const Model) []const u8 {
        return model.codex_plan_line[0..model.codex_plan_len];
    }

    pub fn conn_label(model: *const Model) []const u8 {
        return switch (model.conn_state) {
            .connecting => "Connecting…",
            .connected => "Connected",
            .disconnected => "Disconnected",
        };
    }

    pub fn presence_label(model: *const Model) []const u8 {
        return model.presence_mode.label();
    }

    pub fn grok_status_label(model: *const Model) []const u8 {
        return if (model.grok_active) "Grok: active" else "Grok: idle";
    }

    fn setBuf(buf: []u8, len: *usize, text: []const u8) void {
        const n = @min(text.len, buf.len);
        @memcpy(buf[0..n], text[0..n]);
        len.* = n;
    }

    pub fn setStatus(model: *Model, text: []const u8) void {
        setBuf(&model.status_line, &model.status_len, text);
    }
    pub fn setDetail(model: *Model, text: []const u8) void {
        setBuf(&model.detail_line, &model.detail_len, text);
    }
    pub fn setError(model: *Model, text: []const u8) void {
        setBuf(&model.error_line, &model.error_len, text);
    }

    pub fn applyDiscordSnapshot(model: *Model, snap: discord_ipc.Snapshot) void {
        model.conn_state = snap.state;
        model.ready = snap.ready;
        if (snap.last_error_len > 0) {
            model.setError(snap.errorSlice());
        } else {
            model.error_len = 0;
        }
        model.setStatus(model.conn_label());
        model.refreshChrome();
    }

    pub fn refreshChrome(model: *Model) void {
        const enabled = model.enabled_agent_count();
        const linked = model.linked_agent_count();
        if (enabled > 1) {
            var connected_buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&connected_buf, "{d} of {d} connected", .{ linked, enabled }) catch "Connected";
            setBuf(&model.status_pill_line, &model.status_pill_len, text);
        } else if (!model.auto_presence or model.presence_paused) {
            setBuf(&model.status_pill_line, &model.status_pill_len, "Off");
        } else if (model.conn_state == .connected and model.ready) {
            setBuf(&model.status_pill_line, &model.status_pill_len, "Connected");
        } else {
            setBuf(&model.status_pill_line, &model.status_pill_len, "Connecting");
        }
    }

    fn formatElapsed(start_ms: i64, now_ms: i64, buf: []u8) []const u8 {
        if (start_ms <= 0) return "—";
        const total = @max(@divTrunc(now_ms - start_ms, 1000), 0);
        const h = @divTrunc(total, 3600);
        const m = @divTrunc(@rem(total, 3600), 60);
        const s = @rem(total, 60);
        if (h > 0) {
            return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "—";
        }
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, s }) catch "—";
    }

    pub fn applySessions(
        model: *Model,
        codex: ?codex_session.SessionInfo,
        grok: ?grok_session.SessionInfo,
        cursor: ?cursor_session.SessionInfo,
        now_ms: i64,
        sharing_agent: ?AgentKind,
        codex_installed: bool,
        grok_linked: bool,
        cursor_installed: bool,
    ) void {
        model.codex_active = codex != null;
        model.codex_installed = codex_installed;
        model.grok_active = grok != null;
        model.cursor_active = cursor != null;
        model.cursor_installed = cursor_installed;
        model.grok_linked = grok_linked;

        const linked = switch (model.selected_agent) {
            .codex => model.codex_installed,
            .grok => model.grok_linked,
            .cursor => model.cursor_installed,
        };
        model.show_connect_card = !linked;

        const sub: []const u8 = switch (model.selected_agent) {
            .codex => "Install Codex CLI and sign in to track usage, sessions and Discord status here.",
            .grok => "Sign in with grok login to track usage, sessions and status here.",
            .cursor => "Install Cursor desktop and sign in to track sessions and usage here.",
        };
        setBuf(&model.connect_subtitle_line, &model.connect_subtitle_len, sub);

        const active = switch (model.selected_agent) {
            .codex => codex != null,
            .grok => grok != null,
            .cursor => cursor != null,
        };
        setBuf(
            &model.session_title_line,
            &model.session_title_len,
            if (active) "ACTIVE SESSION" else "LAST SESSION",
        );

        var elapsed_buf: [16]u8 = undefined;
        if (active) {
            switch (model.selected_agent) {
                .codex => {
                    const s = codex.?;
                    setBuf(&model.project_line, &model.project_len, s.project());
                    setBuf(&model.elapsed_line, &model.elapsed_len, formatElapsed(s.start_epoch_ms, now_ms, &elapsed_buf));
                    var meta_buf: [96]u8 = undefined;
                    var tok_buf: [32]u8 = undefined;
                    const meta = if (s.total_tokens > 0) blk: {
                        const tok = grok_session.formatTokens(s.total_tokens, &tok_buf);
                        break :blk std.fmt.bufPrint(&meta_buf, "{s}  ·  {s} tokens", .{ s.modelName(), tok }) catch s.modelName();
                    } else s.modelName();
                    setBuf(&model.meta_line, &model.meta_len, meta);
                },
                .grok => {
                    const s = grok.?;
                    setBuf(&model.project_line, &model.project_len, s.project());
                    setBuf(&model.elapsed_line, &model.elapsed_len, formatElapsed(s.start_epoch_ms, now_ms, &elapsed_buf));
                    var meta_buf: [96]u8 = undefined;
                    var tok_buf: [32]u8 = undefined;
                    const meta = if (s.total_tokens > 0) blk: {
                        const tok = grok_session.formatTokens(s.total_tokens, &tok_buf);
                        break :blk std.fmt.bufPrint(&meta_buf, "{s}  ·  {s} tokens", .{ s.modelName(), tok }) catch s.modelName();
                    } else s.modelName();
                    setBuf(&model.meta_line, &model.meta_len, meta);
                },
                .cursor => {
                    const s = cursor.?;
                    setBuf(&model.project_line, &model.project_len, s.project());
                    setBuf(&model.elapsed_line, &model.elapsed_len, formatElapsed(s.start_epoch_ms, now_ms, &elapsed_buf));
                    setBuf(&model.meta_line, &model.meta_len, "Cursor");
                },
            }
        } else {
            setBuf(&model.project_line, &model.project_len, "No active session");
            setBuf(&model.elapsed_line, &model.elapsed_len, "—");
            setBuf(&model.meta_line, &model.meta_len, "Waiting for a session");
        }

        if (!model.auto_presence or model.presence_paused) {
            setBuf(&model.broadcast_line, &model.broadcast_len, "Presence is off");
        } else if (sharing_agent) |agent| {
            if (agent == model.selected_agent) {
                setBuf(&model.broadcast_line, &model.broadcast_len, "Sharing to Discord as your status");
            } else {
                var bbuf: [80]u8 = undefined;
                const line = std.fmt.bufPrint(
                    &bbuf,
                    "Active — Discord is sharing {s}",
                    .{agent.displayName()},
                ) catch "Sharing another agent";
                setBuf(&model.broadcast_line, &model.broadcast_len, line);
            }
        } else {
            setBuf(&model.broadcast_line, &model.broadcast_len, "Waiting for a session");
        }

        model.refreshChrome();
    }

    pub fn applyUsage(model: *Model, snap: grok_usage.Snapshot, now_ms: i64) void {
        model.usage_has_data = snap.weekly_percent >= 0;
        var weekly_buf: [80]u8 = undefined;
        const weekly = grok_usage.formatWeeklyLine(snap, now_ms, &weekly_buf);
        setBuf(&model.usage_weekly_line, &model.usage_weekly_len, weekly);
        model.usage_weekly_frac = if (snap.weekly_percent >= 0)
            @as(f32, @floatFromInt(snap.weekly_percent)) / 100.0
        else
            0;

        if (snap.on_demand_percent >= 0) {
            var od_buf: [80]u8 = undefined;
            const od = std.fmt.bufPrint(&od_buf, "{d}%", .{snap.on_demand_percent}) catch "On-demand";
            setBuf(&model.usage_ondemand_line, &model.usage_ondemand_len, od);
            model.usage_ondemand_frac = @as(f32, @floatFromInt(snap.on_demand_percent)) / 100.0;
        } else {
            model.usage_ondemand_len = 0;
            model.usage_ondemand_frac = 0;
        }
        setBuf(&model.usage_status_line, &model.usage_status_len, "Weekly credits (SuperGrok / CLI)");
    }

    pub fn setUsageStatus(model: *Model, text: []const u8) void {
        setBuf(&model.usage_status_line, &model.usage_status_len, text);
    }

    pub fn applyCursorUsage(model: *Model, snap: cursor_usage.Snapshot, now_ms: i64) void {
        model.cursor_usage_has_data = snap.hasData();
        var line_buf: [80]u8 = undefined;

        const included = cursor_usage.formatWindowLine(snap.included, now_ms, &line_buf);
        setBuf(&model.cursor_included_line, &model.cursor_included_len, included);
        model.cursor_included_frac = cursor_usage.windowFrac(snap.included);

        if (snap.auto.percent >= 0) {
            const auto = cursor_usage.formatWindowLine(snap.auto, now_ms, &line_buf);
            setBuf(&model.cursor_auto_line, &model.cursor_auto_len, auto);
            model.cursor_auto_frac = cursor_usage.windowFrac(snap.auto);
        } else {
            model.cursor_auto_len = 0;
            model.cursor_auto_frac = 0;
        }
        if (snap.api.percent >= 0) {
            const api = cursor_usage.formatWindowLine(snap.api, now_ms, &line_buf);
            setBuf(&model.cursor_api_line, &model.cursor_api_len, api);
            model.cursor_api_frac = cursor_usage.windowFrac(snap.api);
        } else {
            model.cursor_api_len = 0;
            model.cursor_api_frac = 0;
        }
        if (snap.on_demand.percent >= 0) {
            const od = cursor_usage.formatWindowLine(snap.on_demand, now_ms, &line_buf);
            setBuf(&model.cursor_ondemand_line, &model.cursor_ondemand_len, od);
            model.cursor_ondemand_frac = cursor_usage.windowFrac(snap.on_demand);
        } else {
            model.cursor_ondemand_len = 0;
            model.cursor_ondemand_frac = 0;
        }

        if (snap.plan_name_len > 0) {
            setBuf(&model.cursor_plan_line, &model.cursor_plan_len, snap.planName());
        } else {
            model.cursor_plan_len = 0;
        }
        setBuf(&model.cursor_status_line, &model.cursor_status_len, "Included usage (current billing period)");
    }

    pub fn setCursorUsageStatus(model: *Model, text: []const u8) void {
        setBuf(&model.cursor_status_line, &model.cursor_status_len, text);
    }

    pub fn clearCursorUsage(model: *Model) void {
        model.cursor_usage_has_data = false;
        model.cursor_included_len = 0;
        model.cursor_included_frac = 0;
        model.cursor_auto_len = 0;
        model.cursor_auto_frac = 0;
        model.cursor_api_len = 0;
        model.cursor_api_frac = 0;
        model.cursor_ondemand_len = 0;
        model.cursor_ondemand_frac = 0;
        model.cursor_plan_len = 0;
    }

    pub fn applyCodexUsage(model: *Model, snap: codex_usage.Snapshot, now_ms: i64) void {
        model.codex_usage_has_data = snap.hasData();
        var line_buf: [80]u8 = undefined;
        const primary = codex_usage.formatWindowLine(snap.primary, now_ms, &line_buf);
        setBuf(&model.codex_primary_line, &model.codex_primary_len, primary);
        model.codex_primary_frac = codex_usage.windowFrac(snap.primary);
        if (snap.secondary.percent >= 0) {
            const secondary = codex_usage.formatWindowLine(snap.secondary, now_ms, &line_buf);
            setBuf(&model.codex_secondary_line, &model.codex_secondary_len, secondary);
            model.codex_secondary_frac = codex_usage.windowFrac(snap.secondary);
        } else {
            model.codex_secondary_len = 0;
            model.codex_secondary_frac = 0;
        }
        setBuf(&model.codex_usage_status_line, &model.codex_usage_status_len, "Rate limits from Codex app-server");
        setBuf(&model.codex_plan_line, &model.codex_plan_len, snap.planName());
    }

    pub fn setCodexUsageStatus(model: *Model, text: []const u8) void {
        setBuf(&model.codex_usage_status_line, &model.codex_usage_status_len, text);
    }

    pub fn clearCodexUsage(model: *Model) void {
        model.codex_usage_has_data = false;
        model.codex_primary_len = 0;
        model.codex_primary_frac = 0;
        model.codex_secondary_len = 0;
        model.codex_secondary_frac = 0;
        model.codex_plan_len = 0;
    }

    pub fn toggleAgent(model: *Model, agent: AgentKind) void {
        switch (agent) {
            .codex => model.codex_enabled = !model.codex_enabled,
            .cursor => model.cursor_enabled = !model.cursor_enabled,
            .grok => model.grok_enabled = !model.grok_enabled,
        }
        if (!model.isAgentEnabled(model.selected_agent)) {
            model.selected_agent = model.firstEnabledAgent();
        }
        model.refreshChrome();
    }

    pub fn isAgentEnabled(model: *const Model, agent: AgentKind) bool {
        return switch (agent) {
            .codex => model.codex_enabled,
            .cursor => model.cursor_enabled,
            .grok => model.grok_enabled,
        };
    }

    fn firstEnabledAgent(model: *const Model) AgentKind {
        if (model.codex_enabled) return .codex;
        if (model.cursor_enabled) return .cursor;
        if (model.grok_enabled) return .grok;
        return .codex;
    }
};
