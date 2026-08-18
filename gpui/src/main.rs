//! Minimal AgentCord on GPUI (Windows): Claude, Codex, Cursor, Grok → Discord Rich Presence.
//! Popover chrome matches the production light iOS-style card.
#![windows_subsystem = "windows"]

use agentcord_gpui::discord::{Client, ConnState};
use agentcord_gpui::session::{
    AgentKind, DISCORD_CLIENT_ID, LiveSessions, SessionInfo, build_activity, claude_linked,
    codex_linked, cursor_linked, format_clock, format_tokens, grok_linked, now_ms, pick_winner,
    scan_claude, scan_codex, scan_cursor, scan_grok, within_idle,
};
use gpui::{
    App, Application, Bounds, Context, FontWeight, MouseButton, SharedString, TitlebarOptions,
    Window, WindowBounds, WindowDecorations, WindowKind, WindowOptions, div, prelude::*, px, rgb,
    rgba, size,
};
use std::sync::Arc;
use std::time::Duration;

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


#[derive(Clone, Copy, PartialEq, Eq)]
enum Screen {
    Main,
    Settings,
    Detail(AgentKind),
}

struct AgentCord {
    discord: Arc<Client>,
    presence_on: bool,
    claude_on: bool,
    codex_on: bool,
    grok_on: bool,
    cursor_on: bool,
    sessions: LiveSessions,
    last_grok: Option<SessionInfo>,
    claude_is_linked: bool,
    codex_is_linked: bool,
    grok_is_linked: bool,
    cursor_is_linked: bool,
    screen: Screen,
}

impl AgentCord {
    fn new(cx: &mut Context<Self>) -> Self {
        let discord = Arc::new(Client::new());
        discord.connect(DISCORD_CLIENT_ID);
        cx.spawn(async move |this, cx| {
            loop {
                gpui::Timer::after(Duration::from_secs(1)).await;
                this.update(cx, |this, cx| {
                    this.tick();
                    cx.notify();
                })
                .ok();
            }
        })
        .detach();
        let mut app = Self {
            discord,
            presence_on: true,
            claude_on: true,
            codex_on: true,
            grok_on: true,
            cursor_on: true,
            sessions: LiveSessions::default(),
            last_grok: None,
            claude_is_linked: false,
            codex_is_linked: false,
            grok_is_linked: false,
            cursor_is_linked: false,
            screen: Screen::Main,
        };
        app.tick();
        app
    }

    fn tick(&mut self) {
        self.claude_is_linked = claude_linked();
        self.codex_is_linked = codex_linked();
        self.grok_is_linked = grok_linked();
        self.cursor_is_linked = cursor_linked();

        let mut sessions = LiveSessions::default();
        if self.claude_on {
            sessions.claude = scan_claude();
        }
        if self.codex_on {
            sessions.codex = scan_codex();
        }
        if self.grok_on {
            sessions.grok = scan_grok();
            if sessions.grok.is_none() {
                if let Some(prev) = &self.last_grok {
                    if within_idle(prev.activity_ms, now_ms()) {
                        sessions.grok = Some(prev.clone());
                    }
                }
            }
            if let Some(g) = &sessions.grok {
                self.last_grok = Some(g.clone());
            }
        }
        if self.cursor_on {
            sessions.cursor = scan_cursor();
        }
        self.sessions = sessions;

        let snap = self.discord.snapshot();
        let winner = pick_winner(&self.sessions).cloned();
        if self.presence_on {
            self.discord.connect(DISCORD_CLIENT_ID);
            if snap.ready {
                self.discord
                    .set_activity(winner.as_ref().map(build_activity).as_ref());
            }
        }
    }

    fn toggle_presence(&mut self, cx: &mut Context<Self>) {
        self.presence_on = !self.presence_on;
        if self.presence_on {
            self.discord.connect(DISCORD_CLIENT_ID);
        } else {
            self.discord.set_activity(None);
            self.discord.disconnect();
        }
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
        if self.claude_on {
            out.push(AgentKind::Claude);
        }
        if self.codex_on {
            out.push(AgentKind::Codex);
        }
        if self.cursor_on {
            out.push(AgentKind::Cursor);
        }
        if self.grok_on {
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
        };

        div()
            .flex()
            .flex_col()
            .w_full()
            .bg(rgb(SHELL))
            .text_color(rgb(TEXT))
            .font_family("Segoe UI")
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
        .child(header(app.presence_on, &snap, agents.len(), active, cx))
        .child(agent_list(app, &agents, cx))
        .child(settings_row(agents.len(), cx))
        .child(div().h(px(1.)).bg(rgb(HAIR)).my(px(11.)))
        .child(quit_row(cx))
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
            app.presence_on,
            cx.listener(|this, _, _, cx| this.toggle_presence(cx)),
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
                    app.claude_on,
                    cx.listener(|this, _, _, cx| {
                        this.claude_on = !this.claude_on;
                        this.tick();
                        cx.notify();
                    }),
                ))
                .child(div().h(px(1.)).bg(rgb(HAIR)))
                .child(agent_toggle(
                    "codex-toggle",
                    AgentKind::Codex,
                    0x10a37f,
                    app.codex_on,
                    cx.listener(|this, _, _, cx| {
                        this.codex_on = !this.codex_on;
                        this.tick();
                        cx.notify();
                    }),
                ))
                .child(div().h(px(1.)).bg(rgb(HAIR)))
                .child(agent_toggle(
                    "cursor-toggle",
                    AgentKind::Cursor,
                    0x111111,
                    app.cursor_on,
                    cx.listener(|this, _, _, cx| {
                        this.cursor_on = !this.cursor_on;
                        this.tick();
                        cx.notify();
                    }),
                ))
                .child(div().h(px(1.)).bg(rgb(HAIR)))
                .child(agent_toggle(
                    "grok-toggle",
                    AgentKind::Grok,
                    0x1d1d1f,
                    app.grok_on,
                    cx.listener(|this, _, _, cx| {
                        this.grok_on = !this.grok_on;
                        this.tick();
                        cx.notify();
                    }),
                )),
        )
}

fn detail_screen(
    app: &AgentCord,
    agent: AgentKind,
    cx: &mut Context<AgentCord>,
) -> impl IntoElement {
    let session = app.session_for(agent);
    let sharing = session.is_some()
        && app.presence_on
        && pick_winner(&app.sessions).is_some_and(|w| w.agent == agent);
    let project = match session {
        Some(s) => s.project.clone(),
        None => "No active session".into(),
    };
    let meta = match session {
        Some(s) => {
            let mut bits = Vec::new();
            if !s.model.is_empty() {
                bits.push(s.model.clone());
            }
            if s.tokens > 0 {
                bits.push(format!("{} tokens", format_tokens(s.tokens)));
            }
            if bits.is_empty() {
                "Waiting for a session".into()
            } else {
                bits.join("  ·  ")
            }
        }
        None => "Waiting for a session".into(),
    };
    let broadcast = if !app.presence_on {
        "Presence is off"
    } else if sharing {
        "Sharing to Discord as your status"
    } else if session.is_some() {
        "A newer agent session is sharing"
    } else {
        "Waiting for a session"
    };
    let provider = agent.provider_name();

    div()
        .flex()
        .flex_col()
        .w_full()
        .flex_shrink_0()
        .child(nav_header(
            agent.display_name(),
            cx.listener(|this, _, _, cx| {
                this.screen = Screen::Main;
                cx.notify();
            }),
            cx,
        ))
        .child(
            white_card()
                .px(px(12.))
                .py(px(11.))
                .child(
                    div()
                        .text_size(px(13.))
                        .child(provider),
                )
                .child(div().h(px(1.)).bg(rgb(HAIR)).mt(px(10.)).mb(px(10.)))
                .child(
                    div()
                        .flex()
                        .items_center()
                        .child(
                            div()
                                .text_size(px(12.))
                                .text_color(rgb(SEC))
                                .mr(px(7.))
                                .child("⊞"),
                        )
                        .child(
                            div()
                                .flex_1()
                                .text_size(px(13.))
                                .text_color(if session.is_some() {
                                    rgb(TEXT)
                                } else {
                                    rgb(SEC)
                                })
                                .when(session.is_none(), |d| d.italic())
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
}

fn header(
    presence_on: bool,
    snap: &agentcord_gpui::discord::Snapshot,
    enabled: usize,
    active: usize,
    cx: &mut Context<AgentCord>,
) -> impl IntoElement {
    let (pill_bg, pill_border, pill_dot, pill_text, label) = if !presence_on {
        (OFF_PILL, OFF_PILL_BORDER, 0x787880, SEC, SharedString::from("Off"))
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
        .on_mouse_down(MouseButton::Left, cx.listener(|_, _, _, cx| start_native_drag(cx)))
        .child(
            div()
                .size(px(26.))
                .rounded(px(7.))
                .bg(rgb(LOGO))
                .flex()
                .items_center()
                .justify_center()
                .text_color(rgb(WHITE))
                .text_size(px(13.))
                .child("✦"),
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
        col = col.child(agent_row(agent, linked, session, cx));
    }
    white_card().mb(px(11.)).child(col)
}

fn agent_row(
    agent: AgentKind,
    linked: bool,
    session: Option<SessionInfo>,
    cx: &mut Context<AgentCord>,
) -> impl IntoElement {
    let name_color = if linked { TEXT } else { SEC };
    let subtitle: SharedString = if !linked {
        "Not connected".into()
    } else if let Some(s) = &session {
        s.project.clone().into()
    } else {
        "Connected".into()
    };
    let live = session.is_some();
    let trailing: SharedString = if let Some(s) = &session {
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
                        .text_size(px(12.))
                        .text_color(rgb(SEC_FAINT))
                        .child("›"),
                ),
        )
}

fn settings_row(enabled: usize, cx: &mut Context<AgentCord>) -> impl IntoElement {
    let summary = if enabled == 1 {
        "1 agent on".to_string()
    } else {
        format!("{enabled} agents on")
    };
    soft_card()
        .mb(px(0.))
        .child(
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
                        .text_size(px(13.))
                        .text_color(rgb(SEC))
                        .mr(px(7.))
                        .child("⚙"),
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
                        .text_size(px(12.))
                        .text_color(rgb(SEC_FAINT))
                        .child("›"),
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
        .on_mouse_down(MouseButton::Left, cx.listener(|_, _, _, cx| start_native_drag(cx)))
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
                .text_size(px(16.))
                .font_weight(FontWeight::BOLD)
                .child("‹"),
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
    let hwnd = native::active_hwnd();
    cx.defer(move |_| native::start_move(hwnd));
}

mod native {
    extern "system" {
        fn GetActiveWindow() -> isize;
        fn ReleaseCapture() -> i32;
        fn PostMessageW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> i32;
    }

    const WM_SYSCOMMAND: u32 = 0x0112;
    const SC_MOVE: usize = 0xF010;
    const HTCAPTION: usize = 2;

    pub(super) fn active_hwnd() -> isize {
        unsafe { GetActiveWindow() }
    }

    pub(super) fn start_move(hwnd: isize) {
        if hwnd == 0 {
            return;
        }
        unsafe {
            ReleaseCapture();
            PostMessageW(hwnd, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
        }
    }
}

fn main() {
    Application::new().run(|cx: &mut App| {
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
            |_, cx| cx.new(AgentCord::new),
        )
        .unwrap();
        cx.activate(true);
    });
}
