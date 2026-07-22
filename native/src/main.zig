//! AgentCord native-sdk prototype — Discord Rich Presence + Grok/Cursor sessions.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const discord_ipc = @import("discord_ipc.zig");
const codex_session = @import("codex_session.zig");
const codex_usage = @import("codex_usage.zig");
const grok_session = @import("grok_session.zig");
const cursor_session = @import("cursor_session.zig");
const grok_usage = @import("grok_usage.zig");
const cursor_usage = @import("cursor_usage.zig");
const win32_fs = @import("win32_fs.zig");
const usage_fx = @import("usage_fx.zig");
const presence = @import("presence.zig");
const app_model = @import("app_model.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 340;
const window_height: f32 = 620;

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
    const cursor_period: u64 = 20;
    const cursor_legacy: u64 = 21;
};

const UsagePhase = enum { idle, fetching, refreshing };

pub const AgentKind = app_model.AgentKind;
pub const Model = app_model.Model;

var g_discord: discord_ipc.Client = .{};
var g_auth: grok_usage.Auth = .{};
var g_cursor: usage_fx.CursorState = .{};
var g_usage_phase: UsagePhase = .idle;
/// One refresh attempt per billing cycle / manual Refresh (reset on tick / button).
var g_usage_allow_refresh: bool = true;
/// Throttle expensive `.cursor/projects` walks (poll is 2s; scan every 3rd tick).
var g_poll_n: u32 = 0;
var g_cached_cursor: ?cursor_session.SessionInfo = null;

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
    set_test_presence,
    clear_presence,
    refresh_usage,
    toggle_unified_usage,
    open_connect_help,
    select_codex,
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
    cursor_usage_fetched: native_sdk.EffectResponse,
    cursor_legacy_fetched: native_sdk.EffectResponse,

    pub const view_unbound = .{
        "connect", "disconnect", "set_test_presence", "clear_presence", "refresh_usage",
        "poll", "usage_tick", "usage_fetched", "usage_refreshed", "cursor_usage_fetched", "cursor_legacy_fetched", "show_window", "quit",
    };
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
            g_discord.setActivity(null);
            g_discord.disconnect();
            model.presence_mode = .cleared;
            model.setDetail("Disconnected — presence paused until Connect.");
            model.applyDiscordSnapshot(g_discord.snapshot());
            refreshUi(model, fx.wallMs());
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
            refreshUi(model, fx.wallMs());
        },
        .refresh_usage => {
            g_usage_allow_refresh = true;
            requestCodexUsage(model, fx);
            requestBilling(model, fx);
            requestCursorUsage(model, fx);
        },
        .toggle_unified_usage => model.unified_usage = !model.unified_usage,
        .open_connect_help => model.setDetail("Connect the selected agent, then reopen AgentCord."),
        .select_codex => { model.selected_agent = .codex; refreshUi(model, fx.wallMs()); },
        .select_grok => {
            model.selected_agent = .grok;
            refreshUi(model, fx.wallMs());
        },
        .select_cursor => {
            model.selected_agent = .cursor;
            refreshUi(model, fx.wallMs());
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
            requestCodexUsage(model, fx);
            requestBilling(model, fx);
            requestCursorUsage(model, fx);
        },
        .usage_fetched => |response| handleBillingResponse(model, fx, response),
        .usage_refreshed => |response| handleRefreshResponse(model, fx, response),
        .cursor_usage_fetched => |response| handleCursorPeriodResponse(model, fx, response),
        .cursor_legacy_fetched => |response| handleCursorLegacyResponse(model, fx, response),
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

/// Codex exposes rate limits through its own local app-server JSONL protocol.
/// The protocol owns its credentials, so this app only receives the limits.
fn requestCodexUsage(model: *Model, fx: *Effects) void {
    _ = fx;
    var response: [64 * 1024]u8 = undefined;
    const text = codex_usage.fetch(&response) orelse {
        model.clearCodexUsage();
        model.setCodexUsageStatus("Open Codex CLI and sign in to view usage");
        return;
    };
    var snap: codex_usage.Snapshot = .{};
    if (!codex_usage.parseResponse(text, &snap)) {
        model.clearCodexUsage();
        model.setCodexUsageStatus("Codex did not return rate limits");
        return;
    }
    model.applyCodexUsage(snap, win32_fs.nowEpochMs());
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
    if (usage_fx.transportStatus(response.outcome, "Usage")) |msg| {
        model.setUsageStatus(msg);
        return;
    }
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
        model.setUsageStatus(usage_fx.httpStatusMsg(response.status, &buf, "Billing"));
        return;
    }
    var body_buf: [16 * 1024]u8 = undefined;
    const body = usage_fx.copyBody(response, &body_buf);
    var snap: grok_usage.Snapshot = .{};
    if (!grok_usage.parseBilling(body, &snap)) {
        model.setUsageStatus("Could not parse billing response");
        return;
    }
    model.applyUsage(snap, fx.wallMs());
}

fn handleRefreshResponse(model: *Model, fx: *Effects, response: native_sdk.EffectResponse) void {
    g_usage_phase = .idle;
    if (response.outcome != .ok or response.status != 200) {
        model.setUsageStatus("Token refresh failed — run grok login");
        return;
    }
    var body_buf: [8 * 1024]u8 = undefined;
    const body = usage_fx.copyBody(response, &body_buf);
    if (!grok_usage.applyRefreshResponse(&g_auth, body)) {
        model.setUsageStatus("Refresh response missing access_token");
        return;
    }
    g_usage_allow_refresh = false;
    requestBilling(model, fx);
}

fn requestCursorUsage(model: *Model, fx: *Effects) void {
    if (g_cursor.phase != .idle) return;
    g_cursor.tried_alt = false;
    if (!cursor_usage.loadAuth(&g_cursor.auth)) {
        model.clearCursorUsage();
        model.setCursorUsageStatus("Not signed in — open Cursor desktop and sign in");
        return;
    }
    g_cursor.reloadMembership();
    fireCursorPeriod(model, fx);
}

fn fireCursorPeriod(model: *Model, fx: *Effects) void {
    var bearer_buf: [16 + 4096]u8 = undefined;
    var headers_buf: [4]std.http.Header = undefined;
    const headers = cursor_usage.buildPeriodHeaders(&g_cursor.auth, &bearer_buf, &headers_buf) orelse {
        // Token too large for period headers — try legacy (Authorization only).
        fireCursorLegacy(model, fx);
        return;
    };

    g_cursor.phase = .period;
    model.setCursorUsageStatus("Fetching Cursor usage…");
    fx.fetch(.{
        .key = EffectKeys.cursor_period,
        .method = .POST,
        .url = cursor_usage.period_usage_url,
        .headers = headers,
        .body = cursor_usage.period_body,
        .timeout_ms = 15_000,
        .on_response = Effects.responseMsg(.cursor_usage_fetched),
    });
}

fn fireCursorLegacy(model: *Model, fx: *Effects) void {
    var bearer_buf: [16 + 4096]u8 = undefined;
    var headers_buf: [2]std.http.Header = undefined;
    const headers = cursor_usage.buildLegacyHeaders(&g_cursor.auth, &bearer_buf, &headers_buf) orelse {
        model.setCursorUsageStatus("Access token too large for fetch header budget");
        g_cursor.phase = .idle;
        return;
    };
    g_cursor.phase = .legacy;
    model.setCursorUsageStatus("Fetching Cursor usage (legacy)…");
    fx.fetch(.{
        .key = EffectKeys.cursor_legacy,
        .method = .GET,
        .url = cursor_usage.legacy_usage_url,
        .headers = headers,
        .timeout_ms = 15_000,
        .on_response = Effects.responseMsg(.cursor_legacy_fetched),
    });
}

fn tryCursorAltAuth(model: *Model, fx: *Effects) bool {
    if (g_cursor.tried_alt) return false;
    const prev = g_cursor.auth.source;
    if (!cursor_usage.loadAuthAlternate(&g_cursor.auth, prev)) return false;
    g_cursor.tried_alt = true;
    g_cursor.reloadMembership();
    fireCursorPeriod(model, fx);
    return true;
}

fn finishCursorSnap(model: *Model, fx: *Effects, snap: *cursor_usage.Snapshot) void {
    g_cursor.applyMembership(snap);
    model.applyCursorUsage(snap.*, fx.wallMs());
    g_cursor.phase = .idle;
}

fn handleCursorPeriodResponse(model: *Model, fx: *Effects, response: native_sdk.EffectResponse) void {
    if (usage_fx.transportStatus(response.outcome, "Cursor usage")) |msg| {
        g_cursor.phase = .idle;
        model.setCursorUsageStatus(msg);
        return;
    }
    if (response.status == 401) {
        if (tryCursorAltAuth(model, fx)) return;
        g_cursor.phase = .idle;
        model.clearCursorUsage();
        model.setCursorUsageStatus("Cursor auth expired — sign in again in Cursor");
        return;
    }
    if (response.status != 200) {
        fireCursorLegacy(model, fx);
        return;
    }
    var body_buf: [32 * 1024]u8 = undefined;
    const body = usage_fx.copyBody(response, &body_buf);
    var snap: cursor_usage.Snapshot = .{};
    if (!cursor_usage.parsePeriodUsage(body, &snap)) {
        fireCursorLegacy(model, fx);
        return;
    }
    finishCursorSnap(model, fx, &snap);
}

fn handleCursorLegacyResponse(model: *Model, fx: *Effects, response: native_sdk.EffectResponse) void {
    g_cursor.phase = .idle;
    if (usage_fx.transportStatus(response.outcome, "Cursor usage")) |msg| {
        model.setCursorUsageStatus(msg);
        return;
    }
    if (response.status == 401) {
        if (tryCursorAltAuth(model, fx)) return;
        model.clearCursorUsage();
        model.setCursorUsageStatus("Cursor auth expired — sign in again in Cursor");
        return;
    }
    if (response.status != 200) {
        var buf: [64]u8 = undefined;
        model.setCursorUsageStatus(usage_fx.httpStatusMsg(response.status, &buf, "Cursor usage"));
        return;
    }
    var body_buf: [32 * 1024]u8 = undefined;
    const body = usage_fx.copyBody(response, &body_buf);
    var snap: cursor_usage.Snapshot = .{};
    if (!cursor_usage.parseLegacyUsage(body, &snap)) {
        model.setCursorUsageStatus("Could not parse Cursor usage response");
        return;
    }
    finishCursorSnap(model, fx, &snap);
}

fn linkedFlags(codex: ?codex_session.SessionInfo, grok: ?grok_session.SessionInfo) struct { codex: bool, grok: bool, cursor: bool } {
    return .{
        .codex = codex_session.isInstalled() or codex != null,
        .grok = g_auth.hasAccess() or g_auth.hasRefresh() or grok != null,
        .cursor = cursor_session.isInstalled() or cursor_usage.looksSignedIn(),
    };
}

fn scanCursorThrottled(force: bool) ?cursor_session.SessionInfo {
    if (force or g_poll_n % 3 == 0) {
        g_cached_cursor = cursor_session.scan();
    }
    return g_cached_cursor;
}

fn refreshUi(model: *Model, now_ms: i64) void {
    _ = grok_usage.loadAuth(&g_auth);
    const codex = codex_session.scan();
    const grok = grok_session.scan();
    const cursor = scanCursorThrottled(model.selected_agent == .cursor);
    const sharing: ?AgentKind = switch (model.presence_mode) {
        .codex_auto => .codex,
        .grok_auto => .grok,
        .cursor_auto => .cursor,
        else => null,
    };
    const linked = linkedFlags(codex, grok);
    model.applySessions(codex, grok, cursor, now_ms, sharing, linked.codex, linked.grok, linked.cursor);
}

fn syncPresence(model: *Model, now_ms: i64) void {
    _ = grok_usage.loadAuth(&g_auth);
    g_poll_n +%= 1;
    const codex = codex_session.scan();
    const grok = grok_session.scan();
    const cursor = scanCursorThrottled(false);
    const linked = linkedFlags(codex, grok);

    var scratch: presence.Scratch = .{};
    const decision = presence.decide(
        model.presence_mode,
        model.auto_presence,
        model.presence_paused,
        model.ready,
        .{ .codex = codex, .grok = grok, .cursor = cursor },
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
        .codex_auto => .codex,
        .grok_auto => .grok,
        .cursor_auto => .cursor,
        else => null,
    };
    model.applySessions(codex, grok, cursor, now_ms, sharing, linked.codex, linked.grok, linked.cursor);
}

fn boot(model: *Model, fx: *Effects) void {
    model.setStatus("Disconnected");
    model.setDetail("Starting…");
    model.setUsageStatus("Loading usage…");
    model.setCursorUsageStatus("Loading Cursor usage…");
    model.setCodexUsageStatus("Loading Codex usage...");
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
    requestCodexUsage(model, fx);
    requestBilling(model, fx);
    requestCursorUsage(model, fx);
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
    _ = @import("cursor_usage.zig");
    _ = @import("usage_fx.zig");
    _ = @import("app_model.zig");
    _ = @import("grok_usage.zig");
    _ = @import("json_lite.zig");
    _ = @import("presence.zig");
    _ = @import("tests.zig");
}
