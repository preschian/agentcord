//! Minimal AgentCord on GPUI (Windows): Claude, Codex, Cursor, Grok → Discord Rich Presence.
//! Popover chrome matches the production light iOS-style card.
#![windows_subsystem = "windows"]

use agentcord_gpui::discord::{Client, ConnState};
use agentcord_gpui::session::{
    build_activity, format_clock, format_tokens, now_ms, pick_winner, AgentKind, LiveSessions,
    ScanHandle, ScanWanted, SessionInfo, DISCORD_CLIENT_ID,
};
use agentcord_gpui::settings::{self, Settings};
use agentcord_gpui::status::{self, StatusInfo};
use agentcord_gpui::usage::{
    self, capitalize_plan, format_window_value, masked_email, UsageSnapshot, UsageWindow,
};
use gpui::{
    div, prelude::*, px, relative, rgb, rgba, size, App, Application, Bounds, Context, FontWeight,
    MouseButton, SharedString, TitlebarOptions, Window, WindowBounds, WindowDecorations,
    WindowKind, WindowOptions,
};
use std::borrow::Cow;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

mod ui;

const SHELL: u32 = 0xf2f2f5;
const TEXT: u32 = 0x1d1d1f;
const SEC: u32 = 0x6d6d73;
const SEC_SOFT: u32 = 0xa0a0a4;
const SEC_FAINT: u32 = 0xb8b8bb;
const WHITE: u32 = 0xffffff;
const CARD_SOFT: u32 = 0xf8f8fa;
const HAIR: u32 = 0xe5e5e7;
const GREEN: u32 = 0x34c759;
const GREEN_TEXT: u32 = 0x1d8a3a;
const GREEN_PILL: u32 = 0xeaf8ee;
const GREEN_PILL_BORDER: u32 = 0xc5ebce;
const YELLOW: u32 = 0xe6b300;
const YELLOW_TEXT: u32 = 0x997300;
const YELLOW_PILL: u32 = 0xfbf6e0;
const YELLOW_PILL_BORDER: u32 = 0xf0e3a8;
const OFF_PILL: u32 = 0xe8e8ea;
const OFF_PILL_BORDER: u32 = 0xd8d8dc;
const TRACK: u32 = 0xd5d5d7;
const DISCORD: u32 = 0x5865f2;
const LOGO: u32 = 0x1b1b1d;
const WINDOW_WIDTH: f32 = 307.;
const ICON_FONT: &str = "FluentSystemIcons-Regular";
const ICON_SETTINGS: char = '\u{f6a9}';
const ICON_CHEVRON_RIGHT: char = '\u{f2b0}';
const ICON_CHEVRON_LEFT: char = '\u{f2aa}';
const ICON_CHEVRON_DOWN: char = '\u{f2a3}';
const ICON_FOLDER: char = '\u{f418}';
const ICON_SPARKLE: char = '\u{eb33}';

static EXITING: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Screen {
    Main,
    Settings,
    Detail(AgentKind),
    Usage,
}

struct AgentCord {
    discord: Arc<Client>,
    settings: Settings,
    sessions: LiveSessions,
    claude_is_linked: bool,
    codex_is_linked: bool,
    grok_is_linked: bool,
    cursor_is_linked: bool,
    cursor_today_ms: i64,
    screen: Screen,
    usage: Arc<Mutex<UsageSnapshot>>,
    status: Arc<Mutex<Option<StatusInfo>>>,
    scans: ScanHandle,
    expand_status: bool,
    revealed_email: bool,
    _tray: Option<ui::tray::Tray>,
}

impl AgentCord {
    fn new(cx: &mut Context<Self>, tray: Option<ui::tray::Tray>) -> Self {
        let settings = Settings::load();
        let discord = Arc::new(Client::new());
        if settings.presence_enabled {
            discord.connect(DISCORD_CLIENT_ID);
        }
        cx.spawn(async move |this, cx| loop {
            gpui::Timer::after(Duration::from_secs(1)).await;
            this.update(cx, |this, cx| {
                this.tick();
                cx.notify();
            })
            .ok();
        })
        .detach();
        let scans = ScanHandle::spawn(ScanWanted::from_settings(&settings));
        let mut app = Self {
            discord,
            settings,
            sessions: LiveSessions::default(),
            claude_is_linked: false,
            codex_is_linked: false,
            grok_is_linked: false,
            cursor_is_linked: false,
            cursor_today_ms: 0,
            screen: Screen::Main,
            usage: usage::spawn(),
            status: status::spawn(),
            scans,
            expand_status: false,
            revealed_email: false,
            _tray: tray,
        };
        app.tick();
        app
    }

    fn persist(&mut self) {
        self.settings.save();
    }

    fn tick(&mut self) {
        self.scans
            .set_wanted(ScanWanted::from_settings(&self.settings));
        let snap = self.scans.snapshot();
        self.sessions = snap.sessions;
        self.claude_is_linked = snap.claude_linked;
        self.codex_is_linked = snap.codex_linked;
        self.grok_is_linked = snap.grok_linked;
        self.cursor_is_linked = snap.cursor_linked;
        self.cursor_today_ms = snap.cursor_today_ms;

        let discord_snap = self.discord.snapshot();
        let winner = pick_winner(&self.sessions).cloned();
        if self.settings.presence_enabled {
            self.discord.connect(DISCORD_CLIENT_ID);
            if discord_snap.ready {
                self.discord.set_activity(
                    winner
                        .as_ref()
                        .map(|w| build_activity(w, &self.settings))
                        .as_ref(),
                );
            }
        }
        let discord = if discord_snap.ready || discord_snap.state == ConnState::Connected {
            "Connected"
        } else if discord_snap.state == ConnState::Connecting {
            "Connecting"
        } else {
            "Disconnected"
        };
        let usage = self.usage.lock().map(|g| g.clone()).unwrap_or_default();
        let enabled = self.enabled_agents();
        if let Some(tray) = &self._tray {
            tray.set_tip(&usage::tray_tip(
                winner.as_ref(),
                discord,
                discord_snap.last_error.as_deref(),
                &usage,
                &enabled,
                &self.settings,
                now_ms(),
            ));
        }
    }

    fn toggle_presence(&mut self, cx: &mut Context<Self>) {
        self.settings.presence_enabled = !self.settings.presence_enabled;
        if self.settings.presence_enabled {
            self.discord.connect(DISCORD_CLIENT_ID);
        } else {
            self.discord.set_activity(None);
            self.discord.disconnect();
        }
        self.persist();
        self.tick();
        cx.notify();
    }

    fn session_for(&self, agent: AgentKind) -> Option<&SessionInfo> {
        match agent {
            AgentKind::Claude => self.sessions.claude.as_ref(),
            AgentKind::Codex => self.sessions.codex.as_ref(),
            AgentKind::Grok => self.sessions.grok.as_ref(),
            AgentKind::Cursor => self.sessions.cursor.as_ref(),
        }
    }

    fn linked(&self, agent: AgentKind) -> bool {
        match agent {
            AgentKind::Claude => self.claude_is_linked,
            AgentKind::Codex => self.codex_is_linked,
            AgentKind::Grok => self.grok_is_linked,
            AgentKind::Cursor => self.cursor_is_linked,
        }
    }

    fn enabled_agents(&self) -> Vec<AgentKind> {
        let mut out = Vec::new();
        if self.settings.agent_claude_enabled {
            out.push(AgentKind::Claude);
        }
        if self.settings.agent_codex_enabled {
            out.push(AgentKind::Codex);
        }
        if self.settings.agent_cursor_enabled {
            out.push(AgentKind::Cursor);
        }
        if self.settings.agent_grok_enabled {
            out.push(AgentKind::Grok);
        }
        out
    }
}

impl Render for AgentCord {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let body = match self.screen {
            Screen::Main => main_screen(self, cx).into_any_element(),
            Screen::Settings => settings_screen(self, cx).into_any_element(),
            Screen::Detail(agent) => detail_screen(self, agent, cx).into_any_element(),
            Screen::Usage => usage_screen(self, cx).into_any_element(),
        };

        div()
            .flex()
            .flex_col()
            .w_full()
            .bg(rgb(SHELL))
            .text_color(rgb(TEXT))
            .font_family("Consolas")
            .on_children_prepainted(|children, window, cx| {
                let Some(child) = children.first() else {
                    return;
                };
                fit_window_height(window, cx, child.size.height);
            })
            .child(
                div()
                    .flex()
                    .flex_col()
                    .w_full()
                    .flex_shrink_0()
                    .p(px(13.))
                    .child(body),
            )
    }
}

fn fit_window_height(window: &mut Window, cx: &mut App, height: gpui::Pixels) {
    if height < px(80.) {
        return;
    }
    let current = window.viewport_size().height;
    if (current - height).abs() < px(1.) {
        return;
    }
    window.defer(cx, move |window, _| {
        let current = window.viewport_size().height;
        if (current - height).abs() < px(1.) {
            return;
        }
        window.resize(size(px(WINDOW_WIDTH), height));
    });
}

fn main_screen(app: &AgentCord, cx: &mut Context<AgentCord>) -> impl IntoElement {
    let agents = app.enabled_agents();
    let active = agents
        .iter()
        .filter(|a| app.session_for(**a).is_some())
        .count();
    let snap = app.discord.snapshot();

    div()
        .flex()
        .flex_col()
        .w_full()
        .flex_shrink_0()
        .child(header(app.settings.presence_enabled, &snap, agents.len(), active, cx))
        .child(unified_usage(app, &agents, cx))
        .child(agent_list(app, &agents, cx))
        .child(settings_row(agents.len(), cx))
        .child(div().h(px(1.)).bg(rgb(HAIR)).my(px(11.)))
        .child(quit_row(cx))
}

fn unified_usage(
    app: &AgentCord,
    agents: &[AgentKind],
    cx: &mut Context<AgentCord>,
) -> impl IntoElement {
    if agents.len() <= 1 || !app.settings.unified_usage {
        return div().into_any_element();
    }
    let snap = app.usage.lock().map(|g| g.clone()).unwrap_or_default();
    let rows = primary_windows(&snap, agents);
    let mut body = div().flex().flex_col();
    if rows.is_empty() {
        body = body.child(
            div()
                .text_size(px(12.5))
                .italic()
                .text_color(rgb(SEC_SOFT))
                .child("No connected agents"),
        );
    } else {
        for (i, (agent, window)) in rows.into_iter().enumerate() {
            if i > 0 {
                body = body.child(div().h(px(7.)));
            }
            body = body.child(compact_usage_row(agent.display_name(), &window));
        }
    }
    white_card()
        .id("unified-usage-card")
        .mb(px(11.))
        .px(px(12.))
        .py(px(11.))
        .cursor_pointer()
        .on_click(cx.listener(|this, _, _, cx| {
            this.screen = Screen::Usage;
            cx.notify();
        }))
        .child(body)
        .into_any_element()
}

fn usage_screen(app: &AgentCord, cx: &mut Context<AgentCord>) -> impl IntoElement {
    let agents = app.enabled_agents();
    let snap = app.usage.lock().map(|g| g.clone()).unwrap_or_default();
    let rows = primary_windows(&snap, &agents);
    let mut col = div().flex().flex_col();
    if rows.is_empty() {
        col = col.child(
            div()
                .text_size(px(12.5))
                .italic()
                .text_color(rgb(SEC_SOFT))
                .child("No connected agents"),
        );
    } else {
        for (i, (agent, window)) in rows.into_iter().enumerate() {
            if i > 0 {
                col = col.child(div().h(px(10.)));
            }
            col = col.child(usage_row(agent.display_name(), Some(&window)));
        }
    }
    div()
        .flex()
        .flex_col()
        .w_full()
        .flex_shrink_0()
        .child(nav_header(
            "Unified usage",
            cx.listener(|this, _, _, cx| {
                this.screen = Screen::Main;
                cx.notify();
            }),
            cx,
        ))
        .child(white_card().px(px(12.)).py(px(11.)).child(col))
}

fn primary_windows(snap: &UsageSnapshot, agents: &[AgentKind]) -> Vec<(AgentKind, UsageWindow)> {
    agents
        .iter()
        .copied()
        .filter_map(|agent| snap.primary(agent).map(|window| (agent, window)))
        .collect()
}

fn compact_usage_row(label: impl Into<SharedString>, window: &UsageWindow) -> impl IntoElement {
    let fill = (window.percent as f32 / 100.0).clamp(0.015, 1.0);
    div()
        .flex()
        .items_center()
        .child(
            div()
                .w(px(52.))
                .text_size(px(12.5))
                .text_color(rgb(TEXT))
                .child(label.into()),
        )
        .child(
            div()
                .flex_1()
                .h(px(6.))
                .rounded(px(3.))
                .bg(rgba(0x78788029))
                .overflow_hidden()
                .child(
                    div()
                        .h_full()
                        .w(relative(fill))
                        .rounded(px(3.))
                        .bg(rgb(window.severity.color())),
                ),
        )
        .child(
            div()
                .ml(px(8.))
                .text_size(px(12.5))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(rgb(TEXT))
                .child(format!("{}%", window.percent)),
        )
}

fn usage_row(label: impl Into<SharedString>, window: Option<&UsageWindow>) -> impl IntoElement {
    let (value, fill, color) = match window {
        Some(w) => (
            format_window_value(w),
            (w.percent as f32 / 100.0).clamp(0.015, 1.0),
            w.severity.color(),
        ),
        None => ("—".into(), 0.015, TRACK),
    };
    div()
        .flex()
        .flex_col()
        .child(
            div()
                .flex()
                .items_center()
                .child(
                    div()
                        .flex_1()
                        .text_size(px(12.5))
                        .text_color(rgb(TEXT))
                        .child(label.into()),
                )
                .child(
                    div()
                        .text_size(px(12.5))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(rgb(TEXT))
                        .child(value),
                ),
        )
        .child(
            div()
                .mt(px(5.))
                .h(px(6.))
                .rounded(px(3.))
                .bg(rgba(0x78788029))
                .overflow_hidden()
                .child(
                    div()
                        .h_full()
                        .w(relative(fill))
                        .rounded(px(3.))
                        .bg(rgb(color)),
                ),
        )
}

fn settings_screen(app: &AgentCord, cx: &mut Context<AgentCord>) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .w_full()
        .flex_shrink_0()
        .child(nav_header(
            "Settings",
            cx.listener(|this, _, _, cx| {
                this.screen = Screen::Main;
                cx.notify();
            }),
            cx,
        ))
        .child(switch_row(
            "presence",
            "Enable presence",
            app.settings.presence_enabled,
            cx.listener(|this, _, _, cx| this.toggle_presence(cx)),
        ))
        .child(switch_row(
            "autostart",
            "Launch at login",
            settings::autostart_enabled(),
            cx.listener(|this, _, _, cx| {
                settings::set_autostart(!settings::autostart_enabled());
                this.tick();
                cx.notify();
            }),
        ))
        .child(
            soft_card()
                .mt(px(11.))
                .px(px(11.))
                .py(px(5.))
                .child(
                    div()
                        .text_size(px(10.5))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(rgb(SEC))
                        .mt(px(1.))
                        .mb(px(4.))
                        .child("AGENTS"),
                )
                .child(agent_toggle(
                    "claude-toggle",
                    AgentKind::Claude,
                    0xd97757,
                    app.settings.agent_claude_enabled,
                    cx.listener(|this, _, _, cx| {
                        this.settings.agent_claude_enabled = !this.settings.agent_claude_enabled;
                        this.persist();
                        this.tick();
                        cx.notify();
                    }),
                ))
                .child(div().h(px(1.)).bg(rgb(HAIR)))
                .child(agent_toggle(
                    "codex-toggle",
                    AgentKind::Codex,
                    0x10a37f,
                    app.settings.agent_codex_enabled,
                    cx.listener(|this, _, _, cx| {
                        this.settings.agent_codex_enabled = !this.settings.agent_codex_enabled;
                        this.persist();
                        this.tick();
                        cx.notify();
                    }),
                ))
                .child(div().h(px(1.)).bg(rgb(HAIR)))
                .child(agent_toggle(
                    "cursor-toggle",
                    AgentKind::Cursor,
                    0x111111,
                    app.settings.agent_cursor_enabled,
                    cx.listener(|this, _, _, cx| {
                        this.settings.agent_cursor_enabled = !this.settings.agent_cursor_enabled;
                        this.persist();
                        this.tick();
                        cx.notify();
                    }),
                ))
                .child(div().h(px(1.)).bg(rgb(HAIR)))
                .child(agent_toggle(
                    "grok-toggle",
                    AgentKind::Grok,
                    0x1d1d1f,
                    app.settings.agent_grok_enabled,
                    cx.listener(|this, _, _, cx| {
                        this.settings.agent_grok_enabled = !this.settings.agent_grok_enabled;
                        this.persist();
                        this.tick();
                        cx.notify();
                    }),
                )),
        )
        .child(
            soft_card()
                .mt(px(11.))
                .px(px(11.))
                .py(px(5.))
                .child(
                    div()
                        .text_size(px(10.5))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(rgb(SEC))
                        .mt(px(1.))
                        .mb(px(4.))
                        .child("DISPLAY"),
                )
                .child(switch_row(
                    "unified-usage",
                    "Show unified usage",
                    app.settings.unified_usage,
                    cx.listener(|this, _, _, cx| {
                        this.settings.unified_usage = !this.settings.unified_usage;
                        this.persist();
                        cx.notify();
                    }),
                ))
                .child(div().h(px(1.)).bg(rgb(HAIR)))
                .child(switch_row(
                    "show-project",
                    "Show project",
                    app.settings.show_project,
                    cx.listener(|this, _, _, cx| {
                        this.settings.show_project = !this.settings.show_project;
                        this.persist();
                        this.tick();
                        cx.notify();
                    }),
                ))
                .child(div().h(px(1.)).bg(rgb(HAIR)))
                .child(switch_row(
                    "show-model",
                    "Show model",
                    app.settings.show_model,
                    cx.listener(|this, _, _, cx| {
                        this.settings.show_model = !this.settings.show_model;
                        this.persist();
                        this.tick();
                        cx.notify();
                    }),
                ))
                .child(div().h(px(1.)).bg(rgb(HAIR)))
                .child(switch_row(
                    "show-tokens",
                    "Show tokens",
                    app.settings.show_tokens,
                    cx.listener(|this, _, _, cx| {
                        this.settings.show_tokens = !this.settings.show_tokens;
                        this.persist();
                        this.tick();
                        cx.notify();
                    }),
                )),
        )
        .child(
            soft_card()
                .mt(px(11.))
                .child(
                    div()
                        .id("activity-type")
                        .flex()
                        .items_center()
                        .px(px(11.))
                        .py(px(8.))
                        .cursor_pointer()
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.settings.cycle_activity();
                            this.persist();
                            this.tick();
                            cx.notify();
                        }))
                        .child(div().flex_1().text_size(px(13.)).child("Activity type"))
                        .child(
                            div()
                                .rounded(px(6.))
                                .px(px(7.))
                                .py(px(3.))
                                .bg(rgba(0x7878801a))
                                .border_1()
                                .border_color(rgba(0x0000001f))
                                .text_size(px(12.5))
                                .child(app.settings.activity_label().to_string()),
                        ),
                )
                .child(div().h(px(1.)).bg(rgb(HAIR)))
                .child(
                    div()
                        .px(px(11.))
                        .py(px(8.))
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .child(div().flex_1().text_size(px(13.)).child("Idle window"))
                                .child(
                                    div()
                                        .text_size(px(12.5))
                                        .text_color(rgb(SEC))
                                        .child(app.settings.idle_label()),
                                ),
                        )
                        .child({
                            let selected = app.settings.idle_minutes();
                            let mut row = div().flex().justify_between().mt(px(6.));
                            for &mins in &settings::IDLE_MINUTES {
                                let on = selected == mins;
                                row = row.child(
                                    div()
                                        .id(SharedString::from(format!("idle-{mins}")))
                                        .cursor_pointer()
                                        .px(px(3.))
                                        .py(px(2.))
                                        .rounded(px(4.))
                                        .when(on, |d| {
                                            d.bg(rgba(0x7878801a)).font_weight(FontWeight::SEMIBOLD)
                                        })
                                        .text_size(px(11.))
                                        .text_color(rgb(if on { TEXT } else { SEC }))
                                        .on_click(cx.listener(move |this, _, _, cx| {
                                            this.settings.set_idle_minutes(mins);
                                            this.persist();
                                            this.tick();
                                            cx.notify();
                                        }))
                                        .child(format!("{mins}m")),
                                );
                            }
                            row
                        }),
                ),
        )
}

fn detail_screen(
    app: &AgentCord,
    agent: AgentKind,
    cx: &mut Context<AgentCord>,
) -> impl IntoElement {
    let session = app.session_for(agent);
    let sharing = session.is_some()
        && app.settings.presence_enabled
        && pick_winner(&app.sessions).is_some_and(|w| w.agent == agent);
    let project = match session {
        Some(s) if app.settings.show_project => s.project.clone(),
        Some(_) => "Project hidden".into(),
        None => "No active session".into(),
    };
    let meta = match session {
        Some(s) => {
            let mut bits = Vec::new();
            if app.settings.show_model && !s.model.is_empty() {
                bits.push(s.model.clone());
            }
            if app.settings.show_tokens && s.tokens > 0 {
                bits.push(format!("{} tokens", format_tokens(s.tokens)));
            }
            if bits.is_empty() {
                if app.settings.show_model || app.settings.show_tokens {
                    "Waiting for a session".into()
                } else {
                    "Model & tokens hidden".into()
                }
            } else {
                bits.join("  ·  ")
            }
        }
        None => "Waiting for a session".into(),
    };
    let broadcast = if !app.settings.presence_enabled {
        "Presence is off"
    } else if sharing {
        "Sharing to Discord as your status"
    } else if session.is_some() {
        "A newer agent session is sharing"
    } else {
        "Waiting for a session"
    };

    div()
        .flex()
        .flex_col()
        .w_full()
        .flex_shrink_0()
        .child(nav_header(
            agent.display_name(),
            cx.listener(|this, _, _, cx| {
                this.screen = Screen::Main;
                this.expand_status = false;
                this.revealed_email = false;
                cx.notify();
            }),
            cx,
        ))
        .child(
            white_card()
                .px(px(12.))
                .py(px(11.))
                .child(account_row(app, agent, cx))
                .child(div().h(px(1.)).bg(rgb(HAIR)).mt(px(10.)).mb(px(10.)))
                .child(
                    div()
                        .flex()
                        .items_center()
                        .child(
                            div()
                                .text_color(rgb(SEC))
                                .mr(px(7.))
                                .child(icon(ICON_FOLDER, 12.)),
                        )
                        .child(
                            div()
                                .flex_1()
                                .text_size(px(13.))
                                .text_color(if session.is_some() && app.settings.show_project {
                                    rgb(TEXT)
                                } else {
                                    rgb(SEC)
                                })
                                .when(session.is_none() || !app.settings.show_project, |d| d.italic())
                                .child(project),
                        )
                        .child(
                            div()
                                .text_size(px(12.))
                                .text_color(rgb(SEC_SOFT))
                                .child(if session.is_some() { "active" } else { "idle" }),
                        ),
                )
                .child(
                    div()
                        .mt(px(4.))
                        .ml(px(20.))
                        .text_size(px(11.))
                        .italic()
                        .text_color(rgb(SEC_SOFT))
                        .child(meta),
                )
                .child(
                    div()
                        .flex()
                        .items_center()
                        .mt(px(4.))
                        .ml(px(20.))
                        .child(dot(if sharing { DISCORD } else { 0xc5c5c9 }))
                        .child(
                            div()
                                .ml(px(6.))
                                .text_size(px(11.))
                                .text_color(rgb(SEC))
                                .child(broadcast),
                        ),
                ),
        )
        .child(agent_usage(app, agent))
        .when(agent == AgentKind::Claude, |d| {
            d.child(claude_status(app, cx))
        })
}

fn agent_usage(app: &AgentCord, agent: AgentKind) -> impl IntoElement {
    let snap = app.usage.lock().map(|g| g.clone()).unwrap_or_default();
    let rows = snap.rows(agent);
    let mut col = div().flex().flex_col();
    if rows.is_empty() {
        col = col.child(
            div()
                .text_size(px(12.5))
                .italic()
                .text_color(rgb(SEC_SOFT))
                .child(format!("Waiting for {} usage…", agent.display_name())),
        );
    } else {
        for (i, (label, window)) in rows.into_iter().enumerate() {
            if i > 0 {
                col = col.child(div().h(px(10.)));
            }
            col = col.child(usage_row(label, window.as_ref()));
        }
    }
    white_card().mt(px(11.)).px(px(12.)).py(px(11.)).child(col)
}

fn account_row(app: &AgentCord, agent: AgentKind, cx: &mut Context<AgentCord>) -> impl IntoElement {
    let (email, plan) = app
        .usage
        .lock()
        .ok()
        .map(|g| g.identity(agent))
        .unwrap_or((None, None));
    let label = match &email {
        Some(e) if app.revealed_email => e.clone(),
        Some(e) => masked_email(e),
        None => agent.provider_name().to_string(),
    };
    let clickable = email.is_some();
    let mut row = div().flex().items_center().child(
        div()
            .id("account")
            .flex_1()
            .text_size(px(13.))
            .when(clickable, |d| {
                d.cursor_pointer().on_click(cx.listener(|this, _, _, cx| {
                    this.revealed_email = !this.revealed_email;
                    cx.notify();
                }))
            })
            .child(label),
    );
    if let Some(plan) = plan.filter(|p| !p.trim().is_empty()) {
        row = row.child(
            div()
                .ml(px(8.))
                .rounded(px(6.))
                .px(px(6.))
                .py(px(1.))
                .bg(rgb(0xf0f0f2))
                .text_size(px(10.5))
                .text_color(rgb(SEC))
                .child(capitalize_plan(&plan)),
        );
    }
    row
}

fn claude_status(app: &AgentCord, cx: &mut Context<AgentCord>) -> impl IntoElement {
    let Some(info) = app.status.lock().ok().and_then(|g| g.clone()) else {
        return div().into_any_element();
    };
    let expand = app.expand_status;
    let (pill_bg, pill_border, pill_dot, pill_text) = status_pill_colors(&info.indicator);
    let mut card = white_card()
        .mt(px(11.))
        .px(px(12.))
        .py(px(11.))
        .child(
            div()
                .id("status-toggle")
                .flex()
                .items_center()
                .cursor_pointer()
                .on_click(cx.listener(|this, _, _, cx| {
                    this.expand_status = !this.expand_status;
                    cx.notify();
                }))
                .child(
                    div()
                        .flex_1()
                        .text_size(px(12.5))
                        .child("Claude status"),
                )
                .child(
                    div()
                        .flex()
                        .items_center()
                        .rounded(px(9.))
                        .px(px(6.))
                        .py(px(2.))
                        .bg(rgb(pill_bg))
                        .border_1()
                        .border_color(rgb(pill_border))
                        .child(dot(pill_dot))
                        .child(
                            div()
                                .ml(px(5.))
                                .text_size(px(11.))
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(rgb(pill_text))
                                .child(info.summary_label.clone()),
                        ),
                )
                .child(
                    div()
                        .ml(px(6.))
                        .text_color(rgb(SEC_FAINT))
                        .child(icon(
                            if expand {
                                ICON_CHEVRON_DOWN
                            } else {
                                ICON_CHEVRON_RIGHT
                            },
                            12.,
                        )),
                ),
        );
    if expand {
        let mut body = div().flex().flex_col().mt(px(8.));
        for incident in &info.incidents {
            let tint = match incident.impact.as_str() {
                "critical" => 0xff3b30,
                "minor" => YELLOW,
                "maintenance" => 0x007aff,
                _ => 0xff9500,
            };
            body = body.child(
                div()
                    .mb(px(7.))
                    .px(px(8.))
                    .py(px(6.))
                    .rounded(px(6.))
                    .bg(rgb(CARD_SOFT))
                    .child(div().text_size(px(12.5)).child(incident.name.clone()))
                    .child(
                        div()
                            .mt(px(2.))
                            .text_size(px(11.))
                            .text_color(rgb(tint))
                            .child(capitalize_plan(&incident.status)),
                    ),
            );
        }
        for component in &info.components {
            let (color, label) = component_status(&component.status);
            body = body.child(
                div()
                    .flex()
                    .items_center()
                    .mb(px(7.))
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(12.5))
                            .child(component.name.clone()),
                    )
                    .child(dot(color))
                    .child(
                        div()
                            .ml(px(5.))
                            .text_size(px(11.5))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(color))
                            .child(label),
                    ),
            );
        }
        let footer = info.footer();
        body = body.child(
            div()
                .id("status-open")
                .cursor_pointer()
                .on_click(|_, _, _| open_url(StatusInfo::page_url()))
                .text_size(px(11.))
                .text_color(rgb(SEC_SOFT))
                .child(footer),
        );
        card = card.child(body);
    }
    card.into_any_element()
}

fn status_pill_colors(indicator: &str) -> (u32, u32, u32, u32) {
    match indicator {
        "none" => (GREEN_PILL, GREEN_PILL_BORDER, GREEN, GREEN_TEXT),
        "minor" | "major" => (0xfff4e5, 0xf5d5a6, 0xff9500, 0xc2660a),
        "critical" => (0xffecea, 0xf5c4c0, 0xff3b30, 0xc0271f),
        "maintenance" => (0xe8f3ff, 0xb5d4f5, 0x007aff, 0x0057b6),
        _ => (OFF_PILL, OFF_PILL_BORDER, TRACK, SEC),
    }
}

fn component_status(status: &str) -> (u32, &'static str) {
    match status {
        "operational" => (GREEN, "Operational"),
        "degraded_performance" => (0xff9500, "Degraded"),
        "partial_outage" => (0xff9500, "Partial Outage"),
        "major_outage" => (0xff3b30, "Major Outage"),
        "under_maintenance" => (0x007aff, "Maintenance"),
        _ => (TRACK, "Unknown"),
    }
}

fn open_url(url: &str) {
    let _ = Command::new("explorer").arg(url).spawn();
}

fn header(
    presence_on: bool,
    snap: &agentcord_gpui::discord::Snapshot,
    enabled: usize,
    active: usize,
    cx: &mut Context<AgentCord>,
) -> impl IntoElement {
    let (pill_bg, pill_border, pill_dot, pill_text, label) = if !presence_on {
        (
            OFF_PILL,
            OFF_PILL_BORDER,
            0x787880,
            SEC,
            SharedString::from("Off"),
        )
    } else if enabled > 1 {
        if active > 0 {
            (
                GREEN_PILL,
                GREEN_PILL_BORDER,
                GREEN,
                GREEN_TEXT,
                SharedString::from(if active == 1 {
                    "1 active".to_string()
                } else {
                    format!("{active} active")
                }),
            )
        } else {
            (
                YELLOW_PILL,
                YELLOW_PILL_BORDER,
                YELLOW,
                YELLOW_TEXT,
                SharedString::from("0 active"),
            )
        }
    } else if snap.ready || snap.state == ConnState::Connected {
        (
            GREEN_PILL,
            GREEN_PILL_BORDER,
            GREEN,
            GREEN_TEXT,
            SharedString::from("Connected"),
        )
    } else {
        (
            YELLOW_PILL,
            YELLOW_PILL_BORDER,
            YELLOW,
            YELLOW_TEXT,
            SharedString::from("Connecting"),
        )
    };

    div()
        .id("header")
        .flex()
        .items_center()
        .mb(px(11.))
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(|_, _, _, cx| start_native_drag(cx)),
        )
        .child(
            div()
                .size(px(26.))
                .rounded(px(7.))
                .bg(rgb(LOGO))
                .flex()
                .items_center()
                .justify_center()
                .text_color(rgb(WHITE))
                .child(icon(ICON_SPARKLE, 13.)),
        )
        .child(
            div()
                .flex_1()
                .ml(px(9.))
                .text_size(px(15.))
                .font_weight(FontWeight::SEMIBOLD)
                .child("agentcord"),
        )
        .child(
            div()
                .flex()
                .items_center()
                .rounded(px(9.))
                .px(px(8.))
                .py(px(2.))
                .bg(rgb(pill_bg))
                .border_1()
                .border_color(rgb(pill_border))
                .child(dot(pill_dot))
                .child(
                    div()
                        .ml(px(5.))
                        .text_size(px(11.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(rgb(pill_text))
                        .child(label),
                ),
        )
}

fn agent_list(
    app: &AgentCord,
    agents: &[AgentKind],
    cx: &mut Context<AgentCord>,
) -> impl IntoElement {
    let mut col = div().flex().flex_col();
    for (i, agent) in agents.iter().copied().enumerate() {
        if i > 0 {
            col = col.child(div().h(px(1.)).bg(rgb(HAIR)).mx(px(11.)));
        }
        let session = app.session_for(agent).cloned();
        let linked = app.linked(agent);
        col = col.child(agent_row(
            agent,
            linked,
            session,
            app.settings.show_project,
            app.cursor_today_ms,
            cx,
        ));
    }
    white_card().mb(px(11.)).child(col)
}

fn agent_row(
    agent: AgentKind,
    linked: bool,
    session: Option<SessionInfo>,
    show_project: bool,
    cursor_today_ms: i64,
    cx: &mut Context<AgentCord>,
) -> impl IntoElement {
    let name_color = if linked { TEXT } else { SEC };
    let subtitle: SharedString = if !linked {
        "Not connected".into()
    } else if let Some(s) = &session {
        if show_project {
            s.project.clone().into()
        } else {
            "Project hidden".into()
        }
    } else {
        "Connected".into()
    };
    let live = session.is_some();
    let trailing: SharedString = if agent == AgentKind::Cursor && linked && (live || cursor_today_ms > 0)
    {
        format_clock(cursor_today_ms).into()
    } else if let Some(s) = &session {
        format_clock(now_ms() - s.start_epoch_ms).into()
    } else if linked {
        "idle".into()
    } else {
        "Connect".into()
    };
    let trailing_color = if live {
        TEXT
    } else if linked {
        SEC_SOFT
    } else {
        0x007aff
    };

    div()
        .id(agent.display_name())
        .flex()
        .items_center()
        .px(px(11.))
        .py(px(9.))
        .cursor_pointer()
        .hover(|s| s.bg(rgb(0xf7f7f8)))
        .on_click(cx.listener(move |this, _, _, cx| {
            this.screen = Screen::Detail(agent);
            this.expand_status = false;
            this.revealed_email = false;
            cx.notify();
        }))
        .child(
            div()
                .flex()
                .flex_col()
                .flex_1()
                .min_w_0()
                .child(
                    div()
                        .text_size(px(13.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(rgb(name_color))
                        .child(agent.display_name()),
                )
                .child(
                    div()
                        .text_size(px(10.5))
                        .text_color(rgb(SEC_SOFT))
                        .child(subtitle),
                ),
        )
        .child(
            div()
                .flex()
                .items_center()
                .when(live, |d| d.child(dot(GREEN).mr(px(5.))))
                .child(
                    div()
                        .text_size(px(11.5))
                        .font_weight(if live {
                            FontWeight::MEDIUM
                        } else {
                            FontWeight::NORMAL
                        })
                        .text_color(rgb(trailing_color))
                        .child(trailing),
                )
                .child(
                    div()
                        .ml(px(6.))
                        .text_color(rgb(SEC_FAINT))
                        .child(icon(ICON_CHEVRON_RIGHT, 12.)),
                ),
        )
}

fn settings_row(enabled: usize, cx: &mut Context<AgentCord>) -> impl IntoElement {
    let summary = if enabled == 1 {
        "1 agent on".to_string()
    } else {
        format!("{enabled} agents on")
    };
    soft_card().mb(px(0.)).child(
        div()
            .id("settings")
            .flex()
            .items_center()
            .px(px(11.))
            .py(px(8.))
            .cursor_pointer()
            .hover(|s| s.bg(rgb(0xf3f3f5)))
            .on_click(cx.listener(|this, _, _, cx| {
                this.screen = Screen::Settings;
                cx.notify();
            }))
            .child(
                div()
                    .text_color(rgb(SEC))
                    .mr(px(7.))
                    .child(icon(ICON_SETTINGS, 13.)),
            )
            .child(div().flex_1().text_size(px(13.)).child("Settings"))
            .child(
                div()
                    .text_size(px(12.))
                    .text_color(rgb(SEC_SOFT))
                    .child(summary),
            )
            .child(
                div()
                    .ml(px(6.))
                    .text_color(rgb(SEC_FAINT))
                    .child(icon(ICON_CHEVRON_RIGHT, 12.)),
            ),
    )
}

fn quit_row(cx: &mut Context<AgentCord>) -> impl IntoElement {
    div()
        .rounded(px(7.))
        .bg(rgb(0xf9f9fb))
        .border_1()
        .border_color(rgb(HAIR))
        .child(
            div()
                .id("quit")
                .flex()
                .items_center()
                .px(px(11.))
                .py(px(6.))
                .cursor_pointer()
                .hover(|s| s.bg(rgb(0xf3f3f5)))
                .on_click(cx.listener(|this, _, _, cx| {
                    EXITING.store(true, Ordering::SeqCst);
                    this.discord.disconnect();
                    cx.quit();
                }))
                .child(div().flex_1().text_size(px(13.)).child("Quit agentcord"))
                .child(
                    div()
                        .text_size(px(12.))
                        .text_color(rgb(SEC_SOFT))
                        .child("Alt+F4"),
                ),
        )
}

fn nav_header(
    title: &'static str,
    on_back: impl Fn(&gpui::ClickEvent, &mut Window, &mut App) + 'static,
    cx: &mut Context<AgentCord>,
) -> impl IntoElement {
    div()
        .id("nav-header")
        .flex()
        .items_center()
        .mb(px(11.))
        .on_mouse_down(
            MouseButton::Left,
            cx.listener(|_, _, _, cx| start_native_drag(cx)),
        )
        .child(
            div()
                .id("back")
                .size(px(26.))
                .rounded(px(7.))
                .bg(rgb(0xe4e4e7))
                .flex()
                .items_center()
                .justify_center()
                .cursor_pointer()
                .hover(|s| s.bg(rgb(0xd8d8dc)))
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .on_click(on_back)
                .child(icon(ICON_CHEVRON_LEFT, 16.)),
        )
        .child(
            div()
                .ml(px(9.))
                .text_size(px(15.))
                .font_weight(FontWeight::SEMIBOLD)
                .child(title),
        )
}

fn switch_row(
    id: &'static str,
    label: &'static str,
    on: bool,
    on_click: impl Fn(&gpui::ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    div()
        .id(id)
        .flex()
        .items_center()
        .py(px(6.))
        .cursor_pointer()
        .on_click(on_click)
        .child(div().flex_1().text_size(px(13.)).child(label))
        .child(ios_switch(on))
}

fn agent_toggle(
    id: &'static str,
    agent: AgentKind,
    dot_color: u32,
    on: bool,
    on_click: impl Fn(&gpui::ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    div()
        .id(id)
        .flex()
        .items_center()
        .py(px(5.))
        .cursor_pointer()
        .on_click(on_click)
        .child(dot(dot_color))
        .child(
            div()
                .flex_1()
                .ml(px(7.))
                .text_size(px(12.5))
                .child(agent.display_name()),
        )
        .child(ios_switch(on))
}

fn ios_switch(on: bool) -> impl IntoElement {
    div()
        .w(px(28.))
        .h(px(17.))
        .rounded(px(8.5))
        .bg(rgb(if on { GREEN } else { TRACK }))
        .flex()
        .items_center()
        .when(on, |d| d.justify_end())
        .when(!on, |d| d.justify_start())
        .px(px(1.5))
        .child(div().size(px(14.)).rounded_full().bg(rgb(WHITE)))
}

fn white_card() -> gpui::Div {
    div()
        .bg(rgb(WHITE))
        .rounded(px(10.))
        .border_1()
        .border_color(rgba(0x0000000f))
}

fn soft_card() -> gpui::Div {
    div()
        .bg(rgb(CARD_SOFT))
        .rounded(px(9.))
        .border_1()
        .border_color(rgba(0x00000012))
}

fn dot(color: u32) -> gpui::Div {
    div().size(px(6.)).rounded_full().bg(rgb(color))
}

/// Native Windows move: SC_MOVE after this mouse handler returns.
/// GPUI's start_window_move is Wayland/X11-only; SendMessage re-enters GPUI and crashes.
fn start_native_drag(cx: &mut Context<AgentCord>) {
    let hwnd = ui::native::active_hwnd();
    cx.defer(move |_| ui::native::start_move(hwnd));
}

fn icon(glyph: char, size: f32) -> impl IntoElement {
    div()
        .font_family(ICON_FONT)
        .font_weight(FontWeight::NORMAL)
        .text_size(px(size))
        .line_height(px(size))
        .child(glyph.to_string())
}

fn main() {
    let Some(_instance) = settings::acquire_instance() else {
        return;
    };
    agentcord_gpui::cursor_hooks::ensure();
    Application::new().run(|cx: &mut App| {
        let _ = cx
            .text_system()
            .add_fonts(vec![Cow::Borrowed(include_bytes!(
                "../assets/FluentSystemIcons-Regular.ttf"
            ))]);
        // Width is fixed; height starts large enough to measure, then fits content.
        let bounds = Bounds::centered(None, size(px(WINDOW_WIDTH), px(500.)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(TitlebarOptions {
                    title: Some("agentcord".into()),
                    appears_transparent: true,
                    traffic_light_position: None,
                }),
                window_decorations: Some(WindowDecorations::Client),
                kind: WindowKind::Normal,
                is_resizable: false,
                ..Default::default()
            },
            |window, cx| {
                let hwnd = ui::native::active_hwnd();
                let tray = ui::tray::Tray::attach(hwnd);
                let view = cx.new(|cx| AgentCord::new(cx, tray));
                view.update(cx, |app, _| {
                    ui::tray::hook_session_end(hwnd, app.discord.clone());
                });
                window.on_window_should_close(cx, move |_, _| {
                    if EXITING.load(Ordering::SeqCst) {
                        true
                    } else {
                        ui::native::hide(hwnd);
                        false
                    }
                });
                view
            },
        )
        .unwrap();
        cx.activate(true);
    });
}
