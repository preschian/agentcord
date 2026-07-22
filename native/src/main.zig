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

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 460;
const window_height: f32 = 480;

/// Baked-in Application ID from the production AgentCord app (not a secret).
const discord_client_id = "1517099756063686677";

/// Discord Rich Presence Art Asset keys (uploaded in the Developer Portal).
const logo_claude = "logo-claude";
const logo_chatgpt = "logo-chatgpt";
const logo_cursor = "logo-cursor";
const logo_grok = "logo-grok";

/// Large-image asset for a detected agent. Keep in sync with portal uploads.
fn logoForAgent(agent: []const u8) []const u8 {
    if (std.mem.eql(u8, agent, "claude")) return logo_claude;
    if (std.mem.eql(u8, agent, "codex") or std.mem.eql(u8, agent, "chatgpt")) return logo_chatgpt;
    if (std.mem.eql(u8, agent, "cursor")) return logo_cursor;
    if (std.mem.eql(u8, agent, "grok")) return logo_grok;
    return logo_grok;
}

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

var g_discord: discord_ipc.Client = .{};
var g_auth: grok_usage.Auth = .{};
var g_usage_in_flight: bool = false;
var g_usage_allow_refresh: bool = true;

const poll_timer_key: u64 = 1;
const usage_timer_key: u64 = 2;
const usage_billing_key: u64 = 10;
const usage_refresh_key: u64 = 11;
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
    /// 0 disconnected, 1 connecting, 2 connected
    conn_code: i64 = 0,
    ready: bool = false,
    /// Auto-push Grok session activity to Discord.
    auto_presence: bool = true,
    presence_set: bool = false,
    /// 0 none, 1 grok live, 2 manual test
    presence_source: i64 = 0,

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
        return switch (model.conn_code) {
            1 => "Connecting…",
            2 => if (model.ready) "Connected (READY)" else "Connected",
            else => "Disconnected",
        };
    }

    pub fn presence_label(model: *const Model) []const u8 {
        return switch (model.presence_source) {
            1 => "Presence: Grok session",
            2 => "Presence: manual test",
            else => "Presence: cleared",
        };
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
        model.conn_code = switch (snap.state) {
            .disconnected => 0,
            .connecting => 1,
            .connected => 2,
        };
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
            model.setDetail("Connecting with AgentCord Application ID…");
            model.error_len = 0;
            g_discord.connect(discord_client_id);
            model.applyDiscordSnapshot(g_discord.snapshot());
        },
        .disconnect => {
            g_discord.disconnect();
            model.presence_set = false;
            model.presence_source = 0;
            model.setDetail("Disconnected from Discord IPC.");
            model.applyDiscordSnapshot(g_discord.snapshot());
        },
        .toggle_auto => {
            model.auto_presence = !model.auto_presence;
            if (!model.auto_presence and model.presence_source == 1) {
                g_discord.setActivity(null);
                model.presence_set = false;
                model.presence_source = 0;
                model.setDetail("Auto presence off — cleared Grok activity.");
            } else if (model.auto_presence) {
                model.setDetail("Auto presence on — scanning Grok sessions.");
                syncPresence(model, fx);
            }
        },
        .set_test_presence => {
            const start_ms = fx.wallMs();
            g_discord.setActivity(.{
                .type = 0,
                .name = "Grok 4.5",
                .details = "Working on: agentcord",
                .state = "manual test presence",
                .large_image = logoForAgent("grok"),
                .large_text = "Grok",
                .small_image = "",
                .small_text = "",
                .start_ms = start_ms,
                .button_label = "What is Grok",
                .button_url = "https://grok.com",
            });
            model.presence_set = true;
            model.presence_source = 2;
            model.setDetail("SET_ACTIVITY: manual test presence");
            model.applyDiscordSnapshot(g_discord.snapshot());
        },
        .clear_presence => {
            g_discord.setActivity(null);
            model.presence_set = false;
            model.presence_source = 0;
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
            // Best-effort clear before the process tears down.
            g_discord.setActivity(null);
            g_discord.disconnect();
            fx.quitApp();
        },
        .poll => |timer| {
            if (timer.outcome != .fired) return;
            model.applyDiscordSnapshot(g_discord.snapshot());
            syncPresence(model, fx);
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
    if (g_usage_in_flight) return;
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

    // Header budget is 1 KiB total — keep names short (skip User-Agent).
    var auth_val: [16 + 2048]u8 = undefined;
    const bearer = std.fmt.bufPrint(&auth_val, "Bearer {s}", .{g_auth.accessSlice()}) catch {
        model.setUsageStatus("Access token too large");
        return;
    };

    var headers_buf: [4]std.http.Header = undefined;
    var header_count: usize = 0;
    headers_buf[header_count] = .{ .name = "Authorization", .value = bearer };
    header_count += 1;
    headers_buf[header_count] = .{ .name = "Accept", .value = "application/json" };
    header_count += 1;
    headers_buf[header_count] = .{ .name = "X-XAI-Token-Auth", .value = grok_usage.token_auth_header };
    header_count += 1;
    if (g_auth.user_id_len > 0) {
        headers_buf[header_count] = .{ .name = "x-userid", .value = g_auth.userIdSlice() };
        header_count += 1;
    }

    g_usage_in_flight = true;
    model.setUsageStatus("Fetching usage…");
    fx.fetch(.{
        .key = usage_billing_key,
        .method = .GET,
        .url = grok_usage.billing_url,
        .headers = headers_buf[0..header_count],
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
    var body_buf: [1024]u8 = undefined;
    const body = grok_usage.refreshBody(&g_auth, &body_buf) orelse {
        model.setUsageStatus("Could not build refresh body");
        return;
    };

    g_usage_in_flight = true;
    g_usage_allow_refresh = false;
    model.setUsageStatus("Refreshing sign-in…");
    fx.fetch(.{
        .key = usage_refresh_key,
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
    g_usage_in_flight = false;
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
            // COPY body — drain scratch dies after this update.
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
        .rejected => model.setUsageStatus("Usage fetch rejected (headers/budget?)"),
        .connect_failed, .tls_failed, .protocol_failed => model.setUsageStatus("Network error fetching usage"),
        .timed_out => model.setUsageStatus("Usage fetch timed out"),
        .cancelled => {},
    }
}

fn handleRefreshResponse(model: *Model, fx: *Effects, response: native_sdk.EffectResponse) void {
    g_usage_in_flight = false;
    if (response.outcome != .ok or response.status != 200) {
        model.setUsageStatus("Token refresh failed — run grok login");
        return;
    }
    var body_buf: [8 * 1024]u8 = undefined;
    const n = @min(response.body.len, body_buf.len);
    @memcpy(body_buf[0..n], response.body[0..n]);
    const body = body_buf[0..n];
    const access = grok_session.extractString(body, "access_token") orelse {
        model.setUsageStatus("Refresh response missing access_token");
        return;
    };
    g_auth.setAccess(access);
    if (grok_session.extractString(body, "refresh_token")) |new_refresh| {
        if (new_refresh.len > 0) g_auth.setRefresh(new_refresh);
    }
    // Retry billing once with the new access token.
    g_usage_allow_refresh = false;
    requestBilling(model, fx);
}

fn syncPresence(model: *Model, fx: *Effects) void {
    _ = fx;
    const session = grok_session.scan();
    model.applyGrok(session);

    if (!model.auto_presence) {
        if (session) |s| {
            var buf: [200]u8 = undefined;
            const d = std.fmt.bufPrint(&buf, "Grok live · {s} · {s} (auto off)", .{ s.modelName(), s.project() }) catch "Grok live";
            model.setDetail(d);
        } else {
            model.setDetail("No live Grok session (auto off).");
        }
        return;
    }

    // Don't override a manual test presence until the user clears it or Grok takes over.
    if (model.presence_source == 2 and session == null) {
        model.setDetail("Manual test presence active; no live Grok session.");
        return;
    }

    if (session) |s| {
        var state_buf: [64]u8 = undefined;
        const state = if (s.total_tokens > 0) blk: {
            var tok_buf: [32]u8 = undefined;
            const tok = grok_session.formatTokens(s.total_tokens, &tok_buf);
            break :blk std.fmt.bufPrint(&state_buf, "{s} tokens", .{tok}) catch "Grok session";
        } else "Grok session";

        var details_buf: [128]u8 = undefined;
        const details = std.fmt.bufPrint(&details_buf, "Working on: {s}", .{s.project()}) catch "Working on: Grok";

        g_discord.setActivity(.{
            .type = 0,
            .name = s.modelName(),
            .details = details,
            .state = state,
            .large_image = logoForAgent("grok"),
            .large_text = "Grok",
            .small_image = "",
            .small_text = "",
            .start_ms = if (s.start_epoch_ms > 0) s.start_epoch_ms else 0,
            .button_label = "What is Grok",
            .button_url = "https://grok.com",
        });
        model.presence_set = true;
        model.presence_source = 1;

        var detail_buf: [200]u8 = undefined;
        const d = std.fmt.bufPrint(&detail_buf, "Auto · {s} · {s}", .{ s.modelName(), s.project() }) catch "Auto presence";
        model.setDetail(d);
    } else if (model.presence_source == 1 or model.presence_set) {
        // Live session gone — clear auto presence.
        g_discord.setActivity(null);
        model.presence_set = false;
        model.presence_source = 0;
        model.setDetail("No live Grok session — presence cleared.");
    } else {
        model.setDetail("Waiting for a live Grok CLI session…");
    }
}

fn boot(model: *Model, fx: *Effects) void {
    model.setStatus("Disconnected");
    model.setDetail("Starting…");
    model.applyGrok(null);
    model.setUsageStatus("Loading usage…");
    fx.startTimer(.{
        .key = poll_timer_key,
        .interval_ms = 2000,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.poll),
    });
    // Weekly credits poll (matches macOS GrokUsage cadence of ~5 min).
    fx.startTimer(.{
        .key = usage_timer_key,
        .interval_ms = 300_000,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.usage_tick),
    });
    g_discord.connect(discord_client_id);
    model.applyDiscordSnapshot(g_discord.snapshot());
    syncPresence(model, fx);
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
        // System tray (Windows notification area / macOS status item).
        // icon_path is the app icon; title is the text fallback if the icon fails.
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
    _ = @import("tests.zig");
}
