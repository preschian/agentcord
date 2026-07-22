//! AgentCord native-sdk prototype — Discord Rich Presence + Grok session detection.
//!
//! Phase 2: auto-set Discord presence from a live Grok CLI session
//! (`~/.grok/active_sessions.json` + summary/signals). Phase 1 Discord IPC remains.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const discord_ipc = @import("discord_ipc.zig");
const grok_session = @import("grok_session.zig");

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
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

var g_discord: discord_ipc.Client = .{};

const poll_timer_key: u64 = 1;

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    connect,
    disconnect,
    toggle_auto,
    set_test_presence,
    clear_presence,
    poll: native_sdk.EffectTimer,

    pub const view_unbound = .{"poll"};
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
    grok_session_line: [80]u8 = .{0} ** 80,
    grok_session_len: usize = 0,

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
    pub fn grok_session_text(model: *const Model) []const u8 {
        return model.grok_session_line[0..model.grok_session_len];
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
            const line = std.fmt.bufPrint(&line_buf, "{s} tokens", .{tok}) catch "tokens";
            setBuf(&model.grok_tokens_line, &model.grok_tokens_len, line);

            const sid = s.sessionId();
            const short = if (sid.len > 8) sid[0..8] else sid;
            var sess_buf: [80]u8 = undefined;
            const sess_line = std.fmt.bufPrint(&sess_buf, "session {s}…", .{short}) catch "session";
            setBuf(&model.grok_session_line, &model.grok_session_len, sess_line);
        } else {
            model.grok_active = false;
            model.grok_model_len = 0;
            model.grok_project_len = 0;
            setBuf(&model.grok_tokens_line, &model.grok_tokens_len, "no live session");
            setBuf(&model.grok_session_line, &model.grok_session_len, "check ~/.grok/active_sessions.json");
        }
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
        .poll => |timer| {
            if (timer.outcome != .fired) return;
            model.applyDiscordSnapshot(g_discord.snapshot());
            syncPresence(model, fx);
        },
    }
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
    fx.startTimer(.{
        .key = poll_timer_key,
        .interval_ms = 2000,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.poll),
    });
    g_discord.connect(discord_client_id);
    model.applyDiscordSnapshot(g_discord.snapshot());
    syncPresence(model, fx);
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
    _ = @import("tests.zig");
}
