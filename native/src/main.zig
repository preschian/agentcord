//! AgentCord native-sdk prototype — Discord Rich Presence + Grok/Cursor sessions.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const discord_ipc = @import("discord_ipc.zig");
const grok_session = @import("grok_session.zig");
const cursor_session = @import("cursor_session.zig");
const grok_usage = @import("grok_usage.zig");
const presence = @import("presence.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 300;
const window_height: f32 = 560;

/// Baked-in Application ID from the production AgentCord app (not a secret).
const discord_client_id = "1517099756063686677";

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "AgentCord presence", .accessibility_label = "AgentCord", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "AgentCord",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .close_policy = .hide,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

const EffectKeys = struct {
    const poll_timer: u64 = 1;
    const usage_timer: u64 = 2;
    const usage_billing: u64 = 10;
    const usage_refresh: u64 = 11;
};

const UsagePhase = enum { idle, fetching, refreshing };

pub const AgentKind = enum {
    grok,
    cursor,

    pub fn displayName(self: AgentKind) []const u8 {
        return switch (self) {
            .grok => "Grok",
            .cursor => "Cursor",
        };
    }
};

var g_discord: discord_ipc.Client = .{};
var g_auth: grok_usage.Auth = .{};
var g_usage_phase: UsagePhase = .idle;
/// One refresh attempt per billing cycle / manual Refresh (reset on tick / button).
var g_usage_allow_refresh: bool = true;

const main_window_label = "main";

/// Tray dropdown: Open (show window) + Quit. Static for the prototype.
const tray_menu_items = [_]native_sdk.TrayMenuItem{
    .{ .id = 1, .label = "Open AgentCord", .command = "app.open" },
    .{ .separator = true },
    .{ .id = 2, .label = "Quit", .command = "app.quit" },
};

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    connect,
    disconnect,
    toggle_presence,
    toggle_auto,
    set_test_presence,
    clear_presence,
    refresh_usage,
    open_settings,
    close_settings,
    select_grok,
    select_cursor,
    /// Tray / menu: un-hide + activate the main window.
    show_window,
    /// Tray / menu: graceful app quit (clears presence via main's defer).
    quit,
    poll: native_sdk.EffectTimer,
    usage_tick: native_sdk.EffectTimer,
    usage_fetched: native_sdk.EffectResponse,
    usage_refreshed: native_sdk.EffectResponse,

    pub const view_unbound = .{ "poll", "usage_tick", "usage_fetched", "usage_refreshed", "show_window", "quit", "toggle_auto" };
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
        "status_pill_line",     "status_pill_len",       "settings_summary_line",
        "settings_summary_len", "usage_weekly_line",     "usage_weekly_len",
        "usage_ondemand_line",  "usage_status_line",     "usage_status_len",
        "presence_set",         "status_text",           "conn_label",
        "presence_label",       "grok_status_label",
    };

    conn_state: discord_ipc.ConnState = .disconnected,
    ready: bool = false,
    /// Auto-push session activity to Discord (macOS "Enable presence").
    auto_presence: bool = true,
    /// After Disconnect, skip Discord writes until Connect.
    presence_paused: bool = false,
    presence_mode: presence.Mode = .cleared,
    show_settings: bool = false,
    selected_agent: AgentKind = .grok,

    status_line: [160]u8 = .{0} ** 160,
    status_len: usize = 0,
    detail_line: [200]u8 = .{0} ** 200,
    detail_len: usize = 0,
    error_line: [160]u8 = .{0} ** 160,
    error_len: usize = 0,

    // --- selected-agent session card ---
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
    settings_summary_line: [32]u8 = .{0} ** 32,
    settings_summary_len: usize = 0,

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

    pub fn presence_set(model: *const Model) bool {
        return model.presence_mode != .cleared;
    }

    pub fn presence_enabled(model: *const Model) bool {
        return model.auto_presence and !model.presence_paused;
    }

    pub fn agent_is_grok(model: *const Model) bool {
        return model.selected_agent == .grok;
    }
    pub fn agent_is_cursor(model: *const Model) bool {
        return model.selected_agent == .cursor;
    }
    pub fn agent_name(model: *const Model) []const u8 {
        return model.selected_agent.displayName();
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
    pub fn settings_summary(model: *const Model) []const u8 {
        return model.settings_summary_line[0..model.settings_summary_len];
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

    pub fn conn_label(model: *const Model) []const u8 {
        return switch (model.conn_state) {
            .connecting => "Connecting…",
            .connected => if (model.ready) "Connected" else "Connected",
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

    fn setStatus(model: *Model, text: []const u8) void {
        setBuf(&model.status_line, &model.status_len, text);
    }
    fn setDetail(model: *Model, text: []const u8) void {
        setBuf(&model.detail_line, &model.detail_len, text);
    }
    fn setError(model: *Model, text: []const u8) void {
        setBuf(&model.error_line, &model.error_len, text);
    }

    fn applyDiscordSnapshot(model: *Model, snap: discord_ipc.Snapshot) void {
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

    fn refreshChrome(model: *Model) void {
        if (!model.auto_presence or model.presence_paused) {
            setBuf(&model.status_pill_line, &model.status_pill_len, "Off");
        } else if (model.conn_state == .connected and model.ready) {
            setBuf(&model.status_pill_line, &model.status_pill_len, "Connected");
        } else if (model.conn_state == .connecting or (model.conn_state == .connected and !model.ready)) {
            setBuf(&model.status_pill_line, &model.status_pill_len, "Connecting");
        } else {
            setBuf(&model.status_pill_line, &model.status_pill_len, "Connecting");
        }

        if (model.presence_enabled()) {
            setBuf(&model.settings_summary_line, &model.settings_summary_len, "Presence on");
        } else {
            setBuf(&model.settings_summary_line, &model.settings_summary_len, "Presence off");
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

    fn applySessions(
        model: *Model,
        grok: ?grok_session.SessionInfo,
        cursor: ?cursor_session.SessionInfo,
        now_ms: i64,
        sharing_agent: ?AgentKind,
    ) void {
        model.grok_active = grok != null;
        model.cursor_active = cursor != null;
        model.cursor_installed = cursor_session.isInstalled();
        model.grok_linked = g_auth.hasAccess() or g_auth.hasRefresh() or grok != null;

        const linked = switch (model.selected_agent) {
            .grok => model.grok_linked,
            .cursor => model.cursor_installed,
        };
        model.show_connect_card = !linked;

        var sub_buf: [120]u8 = undefined;
        const sub = std.fmt.bufPrint(
            &sub_buf,
            "Link your {s} account to track usage, sessions and status here.",
            .{model.selected_agent.displayName()},
        ) catch "Connect to track sessions.";
        setBuf(&model.connect_subtitle_line, &model.connect_subtitle_len, sub);

        const active = switch (model.selected_agent) {
            .grok => grok != null,
            .cursor => cursor != null,
        };
        setBuf(
            &model.session_title_line,
            &model.session_title_len,
            if (active) "ACTIVE SESSION" else "LAST SESSION",
        );

        var elapsed_buf: [16]u8 = undefined;
        switch (model.selected_agent) {
            .grok => {
                if (grok) |s| {
                    setBuf(&model.project_line, &model.project_len, s.project());
                    const elapsed = formatElapsed(s.start_epoch_ms, now_ms, &elapsed_buf);
                    setBuf(&model.elapsed_line, &model.elapsed_len, elapsed);

                    var meta_buf: [96]u8 = undefined;
                    var tok_buf: [32]u8 = undefined;
                    const meta = if (s.total_tokens > 0) blk: {
                        const tok = grok_session.formatTokens(s.total_tokens, &tok_buf);
                        break :blk std.fmt.bufPrint(&meta_buf, "{s}  ·  {s} tokens", .{ s.modelName(), tok }) catch s.modelName();
                    } else s.modelName();
                    setBuf(&model.meta_line, &model.meta_len, meta);
                } else {
                    setBuf(&model.project_line, &model.project_len, "No active session");
                    setBuf(&model.elapsed_line, &model.elapsed_len, "—");
                    setBuf(&model.meta_line, &model.meta_len, "Waiting for a session");
                }
            },
            .cursor => {
                if (cursor) |s| {
                    setBuf(&model.project_line, &model.project_len, s.project());
                    const elapsed = formatElapsed(s.start_epoch_ms, now_ms, &elapsed_buf);
                    setBuf(&model.elapsed_line, &model.elapsed_len, elapsed);
                    setBuf(&model.meta_line, &model.meta_len, "Cursor");
                } else {
                    setBuf(&model.project_line, &model.project_len, "No active session");
                    setBuf(&model.elapsed_line, &model.elapsed_len, "—");
                    setBuf(&model.meta_line, &model.meta_len, "Waiting for a session");
                }
            },
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

    fn applyUsage(model: *Model, snap: grok_usage.Snapshot, now_ms: i64) void {
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

    fn setUsageStatus(model: *Model, text: []const u8) void {
        setBuf(&model.usage_status_line, &model.usage_status_len, text);
    }
};

pub const Effects = native_sdk.Effects(Msg);

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .connect => {
            model.presence_paused = false;
            model.auto_presence = true;
            model.setDetail("Connecting with AgentCord Application ID…");
            model.error_len = 0;
            g_discord.connect(discord_client_id);
            model.applyDiscordSnapshot(g_discord.snapshot());
            syncPresence(model, fx.wallMs());
        },
        .disconnect => {
            model.presence_paused = true;
            g_discord.disconnect();
            model.presence_mode = .cleared;
            model.setDetail("Disconnected — presence paused until Connect.");
            model.applyDiscordSnapshot(g_discord.snapshot());
        },
        .toggle_presence => {
            if (model.presence_enabled()) {
                model.auto_presence = false;
                if (model.presence_mode == .grok_auto or model.presence_mode == .cursor_auto) {
                    g_discord.setActivity(null);
                    model.presence_mode = .cleared;
                }
                model.setDetail("Presence off.");
            } else {
                model.auto_presence = true;
                model.presence_paused = false;
                if (model.conn_state == .disconnected) {
                    g_discord.connect(discord_client_id);
                }
                model.setDetail("Presence on — scanning sessions.");
                syncPresence(model, fx.wallMs());
            }
            model.applyDiscordSnapshot(g_discord.snapshot());
        },
        .toggle_auto => {
            // Kept for tests / hot-reload of older markup.
            model.auto_presence = !model.auto_presence;
            syncPresence(model, fx.wallMs());
        },
        .set_test_presence => {
            g_discord.setActivity(presence.activityManualTest(fx.wallMs()));
            model.presence_mode = .manual_test;
            model.presence_paused = false;
            model.auto_presence = true;
            model.setDetail("SET_ACTIVITY: manual test presence");
            model.applyDiscordSnapshot(g_discord.snapshot());
        },
        .clear_presence => {
            g_discord.setActivity(null);
            model.presence_mode = .cleared;
            model.setDetail("Cleared presence (activity: null).");
            model.applyDiscordSnapshot(g_discord.snapshot());
        },
        .refresh_usage => {
            g_usage_allow_refresh = true;
            requestBilling(model, fx);
        },
        .open_settings => model.show_settings = true,
        .close_settings => model.show_settings = false,
        .select_grok => {
            model.selected_agent = .grok;
            syncPresence(model, fx.wallMs());
        },
        .select_cursor => {
            model.selected_agent = .cursor;
            syncPresence(model, fx.wallMs());
        },
        .show_window => {
            fx.showWindow(main_window_label);
            model.setDetail("Window shown from tray.");
        },
        .quit => {
            g_discord.setActivity(null);
            g_discord.disconnect();
            fx.quitApp();
        },
        .poll => |timer| {
            if (timer.outcome != .fired) return;
            model.applyDiscordSnapshot(g_discord.snapshot());
            syncPresence(model, fx.wallMs());
        },
        .usage_tick => |timer| {
            if (timer.outcome != .fired) return;
            g_usage_allow_refresh = true;
            requestBilling(model, fx);
        },
        .usage_fetched => |response| handleBillingResponse(model, fx, response),
        .usage_refreshed => |response| handleRefreshResponse(model, fx, response),
    }
}

/// Map tray / app-menu command names to Msg arms.
fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "app.open")) return .show_window;
    if (std.mem.eql(u8, name, "app.quit")) return .quit;
    return null;
}

fn requestBilling(model: *Model, fx: *Effects) void {
    if (g_usage_phase != .idle) return;
    _ = grok_usage.loadAuth(&g_auth);
    if (!g_auth.hasAccess()) {
        if (g_auth.hasRefresh() and g_usage_allow_refresh) {
            requestTokenRefresh(model, fx);
            return;
        }
        model.setUsageStatus("Not signed in — run grok login");
        model.usage_has_data = false;
        model.usage_weekly_len = 0;
        model.usage_ondemand_len = 0;
        model.usage_weekly_frac = 0;
        model.usage_ondemand_frac = 0;
        return;
    }

    var auth_val: [16 + 2048]u8 = undefined;
    var headers_buf: [4]std.http.Header = undefined;
    const headers = grok_usage.buildBillingHeaders(&g_auth, &auth_val, &headers_buf) orelse {
        model.setUsageStatus("Access token too large for fetch header budget");
        return;
    };

    g_usage_phase = .fetching;
    model.setUsageStatus("Fetching usage…");
    fx.fetch(.{
        .key = EffectKeys.usage_billing,
        .method = .GET,
        .url = grok_usage.billing_url,
        .headers = headers,
        .timeout_ms = 15_000,
        .on_response = Effects.responseMsg(.usage_fetched),
    });
}

fn requestTokenRefresh(model: *Model, fx: *Effects) void {
    if (!g_auth.hasRefresh()) {
        model.setUsageStatus("Not signed in — run grok login");
        return;
    }
    var url_buf: [256]u8 = undefined;
    const url = grok_usage.tokenUrl(&g_auth, &url_buf) orelse {
        model.setUsageStatus("Invalid OIDC issuer");
        return;
    };
    var body_buf: [2048]u8 = undefined;
    const body = grok_usage.refreshBody(&g_auth, &body_buf) orelse {
        model.setUsageStatus("Could not build refresh body");
        return;
    };

    g_usage_phase = .refreshing;
    g_usage_allow_refresh = false;
    model.setUsageStatus("Refreshing sign-in…");
    fx.fetch(.{
        .key = EffectKeys.usage_refresh,
        .method = .POST,
        .url = url,
        .headers = &.{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Accept", .value = "application/json" },
        },
        .body = body,
        .timeout_ms = 15_000,
        .on_response = Effects.responseMsg(.usage_refreshed),
    });
}

fn handleBillingResponse(model: *Model, fx: *Effects, response: native_sdk.EffectResponse) void {
    g_usage_phase = .idle;
    switch (response.outcome) {
        .ok => {
            if (response.status == 401) {
                if (g_usage_allow_refresh and g_auth.hasRefresh()) {
                    requestTokenRefresh(model, fx);
                    return;
                }
                model.setUsageStatus("Auth expired — run grok login");
                return;
            }
            if (response.status != 200) {
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Billing HTTP {d}", .{response.status}) catch "Billing error";
                model.setUsageStatus(msg);
                return;
            }
            var body_buf: [16 * 1024]u8 = undefined;
            const n = @min(response.body.len, body_buf.len);
            @memcpy(body_buf[0..n], response.body[0..n]);
            const body = body_buf[0..n];

            var snap: grok_usage.Snapshot = .{};
            if (!grok_usage.parseBilling(body, &snap)) {
                model.setUsageStatus("Could not parse billing response");
                return;
            }
            model.applyUsage(snap, fx.wallMs());
        },
        .rejected => model.setUsageStatus("Usage fetch rejected (headers over 1 KiB budget)"),
        .connect_failed, .tls_failed, .protocol_failed => model.setUsageStatus("Network error fetching usage"),
        .timed_out => model.setUsageStatus("Usage fetch timed out"),
        .cancelled => {},
    }
}

fn handleRefreshResponse(model: *Model, fx: *Effects, response: native_sdk.EffectResponse) void {
    g_usage_phase = .idle;
    if (response.outcome != .ok or response.status != 200) {
        model.setUsageStatus("Token refresh failed — run grok login");
        return;
    }
    var body_buf: [8 * 1024]u8 = undefined;
    const n = @min(response.body.len, body_buf.len);
    @memcpy(body_buf[0..n], response.body[0..n]);
    if (!grok_usage.applyRefreshResponse(&g_auth, body_buf[0..n])) {
        model.setUsageStatus("Refresh response missing access_token");
        return;
    }
    g_usage_allow_refresh = false;
    requestBilling(model, fx);
}

fn syncPresence(model: *Model, now_ms: i64) void {
    _ = grok_usage.loadAuth(&g_auth);
    const grok = grok_session.scan();
    const cursor = cursor_session.scan();

    var scratch: presence.Scratch = .{};
    const decision = presence.decide(
        model.presence_mode,
        model.auto_presence,
        model.presence_paused,
        model.ready,
        .{ .grok = grok, .cursor = cursor },
        &scratch,
    );

    switch (decision.action) {
        .detail_only => {},
        .set => {
            if (decision.activity) |act| g_discord.setActivity(act);
        },
        .clear => g_discord.setActivity(null),
    }
    model.presence_mode = decision.mode;
    model.setDetail(decision.detail);

    const sharing: ?AgentKind = switch (decision.mode) {
        .grok_auto => .grok,
        .cursor_auto => .cursor,
        else => null,
    };
    model.applySessions(grok, cursor, now_ms, sharing);
}

fn boot(model: *Model, fx: *Effects) void {
    model.setStatus("Disconnected");
    model.setDetail("Starting…");
    model.setUsageStatus("Loading usage…");
    model.refreshChrome();
    fx.startTimer(.{
        .key = EffectKeys.poll_timer,
        .interval_ms = 2000,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.poll),
    });
    fx.startTimer(.{
        .key = EffectKeys.usage_timer,
        .interval_ms = 300_000,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.usage_tick),
    });
    g_discord.connect(discord_client_id);
    model.applyDiscordSnapshot(g_discord.snapshot());
    syncPresence(model, fx.wallMs());
    g_usage_allow_refresh = true;
    requestBilling(model, fx);
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const PresenceApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    return .{};
}

pub fn main(init: std.process.Init) !void {
    g_discord = discord_ipc.Client.init();

    const app_state = try PresenceApp.create(std.heap.page_allocator, .{
        .name = "agentcord-native",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .on_command = onCommand,
        .status_item = .{
            .title = "AC",
            .icon_path = "assets/icon.png",
            .tooltip = "AgentCord",
            .items = &tray_menu_items,
        },
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer {
        g_discord.disconnect();
        app_state.destroy();
    }
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "agentcord-native",
        .window_title = "AgentCord",
        .bundle_id = "dev.agentcord.native",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("discord_ipc.zig");
    _ = @import("grok_session.zig");
    _ = @import("cursor_session.zig");
    _ = @import("grok_usage.zig");
    _ = @import("json_lite.zig");
    _ = @import("presence.zig");
    _ = @import("tests.zig");
}
