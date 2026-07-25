//! AgentCord native-sdk prototype — Discord Rich Presence + Codex/Cursor/Grok sessions.

const std = @import("std");
const builtin = @import("builtin");
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
const usage_cache = @import("usage_cache.zig");
const usage_fx = @import("usage_fx.zig");
const presence = @import("presence.zig");
const app_model = @import("app_model.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 405;
const window_height: f32 = 720;
const window_title = "AgentCord";

/// Baked-in Application ID from the production AgentCord app (not a secret).
const discord_client_id = "1517099756063686677";

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "AgentCord presence", .accessibility_label = "AgentCord", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = window_title,
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

const ProviderLogoId = struct {
    const app: u64 = 99;
};

const UsagePhase = enum { idle, fetching, refreshing };

const CodexFetchPending = enum { none, ok, fail };

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
/// Last successful provider snapshots. Persisted without any credentials.
var g_usage_cache: usage_cache.Data = .{};
var g_usage_cache_dirty: bool = false;

/// Background Codex usage fetch (process spawn must not block the UI thread).
var g_codex_mutex: std.atomic.Mutex = .unlocked;
var g_codex_running: bool = false;
var g_codex_pending: CodexFetchPending = .none;
var g_codex_snap: codex_usage.Snapshot = .{};

const main_window_label = "main";

/// Tray dropdown: Open (show window) + Quit. Static for the prototype.
const tray_menu_items = [_]native_sdk.TrayMenuItem{
    .{ .id = 1, .label = "Open AgentCord", .command = "app.open" },
    .{ .separator = true },
    .{ .id = 2, .label = "Quit", .command = "app.quit" },
};

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    refresh_usage,
    toggle_presence,
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
    provider_logo_loaded: native_sdk.EffectImageResult,

    pub const view_unbound = .{
        "refresh_usage", "toggle_presence",
        "poll", "usage_tick", "usage_fetched", "usage_refreshed", "cursor_usage_fetched", "cursor_legacy_fetched", "provider_logo_loaded", "show_window", "quit",
    };
};


pub const Effects = native_sdk.Effects(Msg);

fn spinLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) {
        if (builtin.os.tag == .windows) win32_fs.Sleep(1) else std.atomic.spinLoopHint();
    }
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .refresh_usage => {
            g_usage_allow_refresh = true;
            requestCodexUsage(model);
            requestBilling(model, fx);
            requestCursorUsage(model, fx);
        },
        .toggle_presence => {
            if (model.presence_enabled()) {
                model.auto_presence = false;
                model.presence_paused = true;
                g_discord.setActivity(null);
                model.presence_mode = .cleared;
                model.setDetail("Presence off — Discord status cleared.");
            } else {
                model.auto_presence = true;
                model.presence_paused = false;
                model.setDetail("Presence on — waiting for a live session.");
                syncPresence(model, fx.wallMs());
            }
            model.applyDiscordSnapshot(g_discord.snapshot());
        },
        .show_window => {
            fx.showWindow(main_window_label);
            model.setDetail("Window shown from tray.");
        },
        .quit => {
            flushUsageCache();
            g_discord.setActivity(null);
            g_discord.disconnect();
            fx.quitApp();
        },
        .poll => |timer| {
            if (timer.outcome != .fired) return;
            applyPendingCodexUsage(model, fx.wallMs());
            flushUsageCache();
            model.applyDiscordSnapshot(g_discord.snapshot());
            syncPresence(model, fx.wallMs());
        },
        .usage_tick => |timer| {
            if (timer.outcome != .fired) return;
            g_usage_allow_refresh = true;
            requestCodexUsage(model);
            requestBilling(model, fx);
            requestCursorUsage(model, fx);
        },
        .usage_fetched => |response| handleBillingResponse(model, fx, response),
        .usage_refreshed => |response| handleRefreshResponse(model, fx, response),
        .cursor_usage_fetched => |response| handleCursorPeriodResponse(model, fx, response),
        .cursor_legacy_fetched => |response| handleCursorLegacyResponse(model, fx, response),
        .provider_logo_loaded => |result| {
            if (result.outcome != .loaded) return;
            if (result.id == ProviderLogoId.app) model.app_icon_image = result.id;
        },
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
    // Fetching is not a stale-cache condition.
    model.usage_stale = false;
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
/// Spawning that process is done on a worker thread so the UI stays responsive.
fn requestCodexUsage(model: *Model) void {
    spinLock(&g_codex_mutex);
    const busy = g_codex_running;
    if (!busy) g_codex_running = true;
    g_codex_mutex.unlock();
    if (busy) return;

    model.setCodexUsageStatus("Fetching Codex usage…");
    model.codex_usage_stale = false;
    _ = std.Thread.spawn(.{}, codexUsageWorker, .{}) catch {
        spinLock(&g_codex_mutex);
        g_codex_running = false;
        g_codex_pending = .fail;
        g_codex_mutex.unlock();
        model.setCodexUsageStatus("Could not start Codex usage fetch");
    };
}

fn codexUsageWorker() void {
    var response: [64 * 1024]u8 = undefined;
    var snap: codex_usage.Snapshot = .{};
    var ok = false;
    if (codex_usage.fetch(&response)) |text| {
        if (codex_usage.parseResponse(text, &snap)) ok = true;
    }
    if (!ok) {
        // Codex CLI on Windows can close app-server stdout without a reply.
        // Its authenticated usage endpoint remains available as a safe fallback.
        if (codex_usage.fetchWhamUsage(&response)) |text| {
            if (codex_usage.parseWhamUsage(text, &snap)) ok = true;
        }
    }

    spinLock(&g_codex_mutex);
    g_codex_snap = snap;
    g_codex_pending = if (ok) .ok else .fail;
    g_codex_running = false;
    g_codex_mutex.unlock();
}

fn applyPendingCodexUsage(model: *Model, now_ms: i64) void {
    spinLock(&g_codex_mutex);
    const pending = g_codex_pending;
    const snap = g_codex_snap;
    g_codex_pending = .none;
    g_codex_mutex.unlock();

    switch (pending) {
        .none => {},
        .ok => applyCodexSnapshot(model, snap, now_ms),
        .fail => model.setCodexUsageStatus("Could not fetch Codex usage"),
    }
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
    model.usage_stale = false;
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
    applyGrokSnapshot(model, snap, fx.wallMs());
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
    model.cursor_usage_stale = false;
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
    model.cursor_usage_stale = false;
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
    applyCursorSnapshot(model, snap.*, fx.wallMs());
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

const LinkedFlags = struct { codex: bool, grok: bool, cursor: bool };

fn linkedFlags(codex: ?codex_session.SessionInfo, grok: ?grok_session.SessionInfo) LinkedFlags {
    return .{
        .codex = codex_session.isInstalled() or codex != null,
        .grok = g_auth.hasAccess() or g_auth.hasRefresh() or grok != null,
        .cursor = cursor_session.isInstalled() or cursor_usage.looksSignedIn(),
    };
}

fn scanCursorThrottled() ?cursor_session.SessionInfo {
    if (g_cached_cursor == null or g_poll_n % 3 == 0) {
        g_cached_cursor = cursor_session.scan();
    }
    return g_cached_cursor;
}

const LiveScan = struct {
    codex: ?codex_session.SessionInfo,
    grok: ?grok_session.SessionInfo,
    cursor: ?cursor_session.SessionInfo,
    linked: LinkedFlags,
};

fn scanLive() LiveScan {
    _ = grok_usage.loadAuth(&g_auth);
    const codex = codex_session.scan();
    const grok = grok_session.scan();
    const cursor = scanCursorThrottled();
    return .{
        .codex = codex,
        .grok = grok,
        .cursor = cursor,
        .linked = linkedFlags(codex, grok),
    };
}

fn syncPresence(model: *Model, now_ms: i64) void {
    g_poll_n +%= 1;
    const live = scanLive();

    var scratch: presence.Scratch = .{};
    const decision = presence.decide(
        model.presence_mode,
        model.auto_presence,
        model.presence_paused,
        model.ready,
        .{ .codex = live.codex, .grok = live.grok, .cursor = live.cursor },
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
    model.applySessions(
        live.codex,
        live.grok,
        live.cursor,
        now_ms,
        live.linked.codex,
        live.linked.grok,
        live.linked.cursor,
    );
}

fn applyCodexSnapshot(model: *Model, snap: codex_usage.Snapshot, now_ms: i64) void {
    model.applyCodexUsage(snap, now_ms);
    g_usage_cache.codex = snap;
    g_usage_cache_dirty = true;
}

fn applyCursorSnapshot(model: *Model, snap: cursor_usage.Snapshot, now_ms: i64) void {
    model.applyCursorUsage(snap, now_ms);
    g_usage_cache.cursor = snap;
    g_usage_cache_dirty = true;
}

fn applyGrokSnapshot(model: *Model, snap: grok_usage.Snapshot, now_ms: i64) void {
    model.applyUsage(snap, now_ms);
    g_usage_cache.grok = snap;
    g_usage_cache_dirty = true;
}

fn flushUsageCache() void {
    if (!g_usage_cache_dirty) return;
    if (usage_cache.save(&g_usage_cache)) g_usage_cache_dirty = false;
}

fn restoreUsageCache(model: *Model, now_ms: i64) void {
    if (!usage_cache.load(&g_usage_cache)) return;
    if (g_usage_cache.codex) |snap| {
        model.applyCodexUsage(snap, now_ms);
        model.setCodexUsageStatus("Showing cached Codex usage");
        model.codex_usage_stale = true;
    }
    if (g_usage_cache.cursor) |snap| {
        model.applyCursorUsage(snap, now_ms);
        model.setCursorUsageStatus("Showing cached Cursor usage");
        model.cursor_usage_stale = true;
    }
    if (g_usage_cache.grok) |snap| {
        model.applyUsage(snap, now_ms);
        model.setUsageStatus("Showing cached Grok usage");
        model.usage_stale = true;
    }
}

fn boot(model: *Model, fx: *Effects) void {
    model.setStatus("Disconnected");
    model.setDetail("Starting…");
    model.setUsageStatus("Loading usage…");
    model.usage_stale = false;
    model.setCursorUsageStatus("Loading Cursor usage…");
    model.cursor_usage_stale = false;
    model.setCodexUsageStatus("Loading Codex usage...");
    model.codex_usage_stale = false;
    restoreUsageCache(model, fx.wallMs());
    _ = win32_fs.setWindowIcon(window_title, "assets/icon.ico");
    loadProviderLogos(fx);
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
    requestCodexUsage(model);
    requestBilling(model, fx);
    requestCursorUsage(model, fx);
}

/// App icon from shipped assets. Provider avatars use initials when no image is set.
fn loadProviderLogos(fx: *Effects) void {
    fx.loadImage(.{
        .id = ProviderLogoId.app,
        .path = "assets/icon-ui.png",
        .on_result = Effects.imageMsg(.provider_logo_loaded),
    });
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
            .icon_path = "assets/icon.ico",
            .tooltip = "AgentCord",
            .items = &tray_menu_items,
        },
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer {
        flushUsageCache();
        g_discord.disconnect();
        app_state.destroy();
    }
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "agentcord-native",
        .window_title = window_title,
        .bundle_id = "dev.agentcord.native",
        .icon_path = "assets/icon.ico",
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
    _ = @import("usage_cache.zig");
    _ = @import("app_model.zig");
    _ = @import("grok_usage.zig");
    _ = @import("json_lite.zig");
    _ = @import("presence.zig");
    _ = @import("tests.zig");
}
