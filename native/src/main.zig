//! AgentCord native-sdk prototype — Discord Rich Presence + Grok session detection.
//!
//! Phase 2: auto-set Discord presence from a live Grok CLI session
//! (`~/.grok/active_sessions.json` + summary/signals). Phase 1 Discord IPC remains.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const discord_ipc = @import("discord_ipc.zig");
const grok_session = @import("grok_session.zig");
const grok_usage = @import("grok_usage.zig");
const presence = @import("presence.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 460;
const window_height: f32 = 480;

/// Baked-in Application ID from the production AgentCord app (not a secret).
const discord_client_id = "1517099756063686677";

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "AgentCord presence", .accessibility_label = "AgentCord", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "AgentCord Native",
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
    toggle_auto,
    set_test_presence,
    clear_presence,
    refresh_usage,
    /// Tray / menu: un-hide + activate the main window.
    show_window,
    /// Tray / menu: graceful app quit (clears presence via main's defer).
    quit,
    poll: native_sdk.EffectTimer,
    usage_tick: native_sdk.EffectTimer,
    usage_fetched: native_sdk.EffectResponse,
    usage_refreshed: native_sdk.EffectResponse,

    pub const view_unbound = .{ "poll", "usage_tick", "usage_fetched", "usage_refreshed", "show_window", "quit" };
};

pub const Model = struct {
    conn_state: discord_ipc.ConnState = .disconnected,
    ready: bool = false,
    /// Auto-push Grok session activity to Discord.
    auto_presence: bool = true,
    /// After Disconnect, skip Discord writes until Connect.
    presence_paused: bool = false,
    presence_mode: presence.Mode = .cleared,

    status_line: [160]u8 = .{0} ** 160,
    status_len: usize = 0,
    detail_line: [200]u8 = .{0} ** 200,
    detail_len: usize = 0,
    error_line: [160]u8 = .{0} ** 160,
    error_len: usize = 0,

    grok_active: bool = false,
    grok_model: [64]u8 = .{0} ** 64,
    grok_model_len: usize = 0,
    grok_project: [96]u8 = .{0} ** 96,
    grok_project_len: usize = 0,
    grok_tokens_line: [48]u8 = .{0} ** 48,
    grok_tokens_len: usize = 0,
    grok_context_line: [64]u8 = .{0} ** 64,
    grok_context_len: usize = 0,
    grok_session_line: [80]u8 = .{0} ** 80,
    grok_session_len: usize = 0,

    /// Weekly credits from billing API (-1 unknown).
    usage_has_data: bool = false,
    usage_weekly_line: [80]u8 = .{0} ** 80,
    usage_weekly_len: usize = 0,
    usage_ondemand_line: [80]u8 = .{0} ** 80,
    usage_ondemand_len: usize = 0,
    usage_status_line: [96]u8 = .{0} ** 96,
    usage_status_len: usize = 0,

    pub fn presence_set(model: *const Model) bool {
        return model.presence_mode != .cleared;
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
    pub fn grok_model_text(model: *const Model) []const u8 {
        return model.grok_model[0..model.grok_model_len];
    }
    pub fn grok_project_text(model: *const Model) []const u8 {
        return model.grok_project[0..model.grok_project_len];
    }
    pub fn grok_tokens_text(model: *const Model) []const u8 {
        return model.grok_tokens_line[0..model.grok_tokens_len];
    }
    pub fn grok_context_text(model: *const Model) []const u8 {
        return model.grok_context_line[0..model.grok_context_len];
    }
    pub fn grok_session_text(model: *const Model) []const u8 {
        return model.grok_session_line[0..model.grok_session_len];
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
            .connected => if (model.ready) "Connected (READY)" else "Connected",
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
    }

    fn applyGrok(model: *Model, session: ?grok_session.SessionInfo) void {
        if (session) |s| {
            model.grok_active = true;
            setBuf(&model.grok_model, &model.grok_model_len, s.modelName());
            setBuf(&model.grok_project, &model.grok_project_len, s.project());
            var tok_buf: [32]u8 = undefined;
            const tok = if (s.total_tokens > 0)
                grok_session.formatTokens(s.total_tokens, &tok_buf)
            else
                "—";
            var line_buf: [48]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "{s} tokens used", .{tok}) catch "tokens";
            setBuf(&model.grok_tokens_line, &model.grok_tokens_len, line);

            if (s.context_percent >= 0) {
                var ctx_buf: [64]u8 = undefined;
                const ctx = if (s.context_window_tokens > 0) blk: {
                    var win_buf: [32]u8 = undefined;
                    const win = grok_session.formatTokens(s.context_window_tokens, &win_buf);
                    break :blk std.fmt.bufPrint(&ctx_buf, "Context {d}% of {s}", .{ s.context_percent, win }) catch "Context";
                } else std.fmt.bufPrint(&ctx_buf, "Context {d}%", .{s.context_percent}) catch "Context";
                setBuf(&model.grok_context_line, &model.grok_context_len, ctx);
            } else {
                model.grok_context_len = 0;
            }

            const sid = s.sessionId();
            const short = if (sid.len > 8) sid[0..8] else sid;
            var sess_buf: [80]u8 = undefined;
            const sess_line = std.fmt.bufPrint(&sess_buf, "session {s}…", .{short}) catch "session";
            setBuf(&model.grok_session_line, &model.grok_session_len, sess_line);
        } else {
            model.grok_active = false;
            model.grok_model_len = 0;
            model.grok_project_len = 0;
            model.grok_context_len = 0;
            setBuf(&model.grok_tokens_line, &model.grok_tokens_len, "no live session");
            setBuf(&model.grok_session_line, &model.grok_session_len, "check ~/.grok/active_sessions.json");
        }
    }

    fn applyUsage(model: *Model, snap: grok_usage.Snapshot, now_ms: i64) void {
        model.usage_has_data = snap.weekly_percent >= 0;
        var weekly_buf: [80]u8 = undefined;
        const weekly = grok_usage.formatWeeklyLine(snap, now_ms, &weekly_buf);
        setBuf(&model.usage_weekly_line, &model.usage_weekly_len, weekly);

        if (snap.on_demand_percent >= 0) {
            var od_buf: [80]u8 = undefined;
            const od = std.fmt.bufPrint(&od_buf, "On-demand {d}%", .{snap.on_demand_percent}) catch "On-demand";
            setBuf(&model.usage_ondemand_line, &model.usage_ondemand_len, od);
        } else {
            model.usage_ondemand_len = 0;
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
            model.setDetail("Connecting with AgentCord Application ID…");
            model.error_len = 0;
            g_discord.connect(discord_client_id);
            model.applyDiscordSnapshot(g_discord.snapshot());
            syncPresence(model);
        },
        .disconnect => {
            model.presence_paused = true;
            g_discord.disconnect();
            model.presence_mode = .cleared;
            model.setDetail("Disconnected — presence paused until Connect.");
            model.applyDiscordSnapshot(g_discord.snapshot());
        },
        .toggle_auto => {
            model.auto_presence = !model.auto_presence;
            if (!model.auto_presence and model.presence_mode == .grok_auto) {
                g_discord.setActivity(null);
                model.presence_mode = .cleared;
                model.setDetail("Auto presence off — cleared Grok activity.");
            } else if (model.auto_presence) {
                model.setDetail("Auto presence on — scanning Grok sessions.");
                syncPresence(model);
            }
        },
        .set_test_presence => {
            g_discord.setActivity(presence.activityManualTest(fx.wallMs()));
            model.presence_mode = .manual_test;
            model.presence_paused = false;
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
            syncPresence(model);
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

fn syncPresence(model: *Model) void {
    const session = grok_session.scan();
    model.applyGrok(session);

    var scratch: presence.Scratch = .{};
    const decision = presence.decide(
        model.presence_mode,
        model.auto_presence,
        model.presence_paused,
        model.ready,
        session,
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
}

fn boot(model: *Model, fx: *Effects) void {
    model.setStatus("Disconnected");
    model.setDetail("Starting…");
    model.applyGrok(null);
    model.setUsageStatus("Loading usage…");
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
    syncPresence(model);
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
        .window_title = "AgentCord Native",
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
    _ = @import("grok_usage.zig");
    _ = @import("json_lite.zig");
    _ = @import("presence.zig");
    _ = @import("tests.zig");
}
