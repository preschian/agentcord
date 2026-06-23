//! System-tray app and status popover, built on `eframe`/`egui` (with
//! `tray-icon` for the notification-area icon) so the popover can match the
//! macOS `MenuBarExtra` look: rounded cards, a status pill, colored usage bars.
//!
//! The presence controller and usage poller run on background threads and
//! publish into [`SharedState`]; the egui UI reads that each frame and renders.
//! The window lives hidden and is shown (bottom-right, above the taskbar) on a
//! left-click of the tray icon, dismissing itself when it loses focus.

use std::sync::Arc;
use std::time::Duration;

use eframe::egui;
use eframe::egui::{Color32, RichText};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};

use windows_sys::Win32::Foundation::RECT;
use windows_sys::Win32::UI::WindowsAndMessaging::{SystemParametersInfoW, SPI_GETWORKAREA};

use crate::claude_session::now_ms;
use crate::presence_controller::{PresenceController, SharedState};
use crate::settings::Settings;

const WIDTH: f32 = 300.0;
const HEIGHT: f32 = 384.0;

const SECONDARY: Color32 = Color32::from_rgb(0x6b, 0x6b, 0x72);
const BLUE: Color32 = Color32::from_rgb(0x58, 0x65, 0xf2);
const GREEN: Color32 = Color32::from_rgb(0x2e, 0xa0, 0x43);
const ORANGE: Color32 = Color32::from_rgb(0xd1, 0x8b, 0x16);
const RED: Color32 = Color32::from_rgb(0xcf, 0x3b, 0x3b);

pub fn run() {
    let shared = Arc::new(SharedState::new(Settings::load()));

    let controller_shared = Arc::clone(&shared);
    std::thread::spawn(move || PresenceController::new(controller_shared).run());

    let usage_shared = Arc::clone(&shared);
    std::thread::spawn(move || loop {
        if let Some(info) = crate::claude_usage::fetch() {
            *usage_shared.usage.lock().unwrap() = Some(info);
        }
        std::thread::sleep(crate::claude_usage::POLL_INTERVAL);
    });

    // Starts hidden; shown (bottom-right) on a tray left-click.
    let mut viewport = egui::ViewportBuilder::default()
        .with_inner_size([WIDTH, HEIGHT])
        .with_decorations(false)
        .with_resizable(false)
        .with_always_on_top()
        .with_taskbar(false)
        .with_visible(false);
    if let Some((rgba, w, h)) = load_rgba(include_bytes!("../assets/icon_256.png")) {
        viewport = viewport.with_icon(Arc::new(egui::IconData { rgba, width: w, height: h }));
    }

    let options = eframe::NativeOptions { viewport, ..Default::default() };
    let app_shared = Arc::clone(&shared);
    let _ = eframe::run_native(
        "AgentCord",
        options,
        Box::new(move |cc| {
            // Force light regardless of the OS theme (eframe otherwise follows
            // the system theme and would override a one-shot set_visuals).
            cc.egui_ctx.options_mut(|o| o.theme_preference = egui::ThemePreference::Light);
            cc.egui_ctx.set_visuals(egui::Visuals::light());
            Ok(Box::new(AgentApp::new(app_shared)) as Box<dyn eframe::App>)
        }),
    );
}

struct AgentApp {
    shared: Arc<SharedState>,
    _tray: Option<TrayIcon>,
    visible: bool,
    /// We only start dismissing on focus loss once the window has actually
    /// gained focus, so the show transition doesn't immediately hide it.
    seen_focus: bool,
    /// Cached so we don't shell out to `reg.exe` every frame.
    autostart_on: bool,
}

impl AgentApp {
    fn new(shared: Arc<SharedState>) -> Self {
        let tray = load_rgba(include_bytes!("../assets/icon_32.png"))
            .and_then(|(rgba, w, h)| Icon::from_rgba(rgba, w, h).ok())
            .and_then(|icon| {
                TrayIconBuilder::new()
                    .with_tooltip("AgentCord")
                    .with_icon(icon)
                    .build()
                    .ok()
            });
        Self {
            shared,
            _tray: tray,
            visible: false,
            seen_focus: false,
            autostart_on: false,
        }
    }

    fn show(&mut self, ctx: &egui::Context) {
        let wa = work_area();
        let ppp = ctx.pixels_per_point();
        let x = wa.right as f32 / ppp - WIDTH - 12.0;
        let y = wa.bottom as f32 / ppp - HEIGHT - 12.0;
        self.autostart_on = crate::autostart::is_enabled();
        self.seen_focus = false;
        self.visible = true;
        ctx.send_viewport_cmd(egui::ViewportCommand::OuterPosition(egui::pos2(x, y)));
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
        ctx.send_viewport_cmd(egui::ViewportCommand::Focus);

        // Pull fresh usage numbers (throttled) for next time.
        let shared = Arc::clone(&self.shared);
        std::thread::spawn(move || {
            if let Some(info) = crate::claude_usage::fetch_throttled(60) {
                *shared.usage.lock().unwrap() = Some(info);
            }
        });
    }

    fn hide(&mut self, ctx: &egui::Context) {
        self.visible = false;
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
    }
}

impl eframe::App for AgentApp {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        // Light window background regardless of the OS theme.
        [0.95, 0.95, 0.96, 1.0]
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        // Force light every frame — eframe otherwise follows the (dark) OS theme.
        ctx.set_theme(egui::ThemePreference::Light);
        ctx.set_visuals(egui::Visuals::light());

        while let Ok(ev) = TrayIconEvent::receiver().try_recv() {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = ev
            {
                self.show(&ctx);
            }
        }

        if self.visible {
            match ctx.input(|i| i.viewport().focused) {
                Some(true) => self.seen_focus = true,
                Some(false) if self.seen_focus => self.hide(&ctx),
                _ => {}
            }
            self.render(ui, &ctx);
        }

        // Heartbeat so we keep polling tray clicks and ticking the timer.
        ctx.request_repaint_after(Duration::from_millis(250));
    }
}

impl AgentApp {
    fn render(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        // The framework panel has ~no margin, so add our own padding.
        egui::Frame::default()
            .inner_margin(egui::Margin::same(13))
            .show(ui, |ui| self.render_inner(ui, ctx));
    }

    fn render_inner(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        let (conn, line1, line2, start_ms) = {
            let s = self.shared.status.lock().unwrap();
            (s.connection.clone(), s.line1.clone(), s.line2.clone(), s.session_start_ms)
        };
        let usage = self.shared.usage.lock().unwrap().clone();
        let mut presence_on = self.shared.settings.lock().unwrap().presence_enabled;

        ui.spacing_mut().item_spacing = egui::vec2(8.0, 8.0);

        // Header: title + status pill.
        ui.horizontal(|ui| {
            ui.label(RichText::new("agentcord").size(15.0).strong());
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let (label, color) = status_pill(presence_on, &conn);
                ui.label(RichText::new(label).size(11.5).color(color));
                // Painted dot (the "●" glyph isn't in egui's default font).
                let (r, _) = ui.allocate_exact_size(egui::vec2(11.0, 11.0), egui::Sense::hover());
                ui.painter().circle_filled(r.center(), 4.0, color);
            });
        });

        // Active session card.
        egui::Frame::group(ui.style()).show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal(|ui| {
                ui.label(RichText::new("ACTIVE SESSION").size(10.5).color(SECONDARY).strong());
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.label(RichText::new(elapsed(start_ms)).size(11.5).monospace().color(SECONDARY));
                });
            });
            ui.add_space(2.0);
            let project = if line1.is_empty() { "No active session".to_string() } else { line1 };
            ui.label(RichText::new(project).size(13.5).strong());
            if !line2.is_empty() {
                ui.label(RichText::new(line2).size(12.0).color(SECONDARY));
            }
        });

        // Usage card.
        egui::Frame::group(ui.style()).show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.label(RichText::new("USAGE").size(10.5).color(SECONDARY).strong());
            ui.add_space(4.0);
            match &usage {
                Some(info) => {
                    usage_row(ui, "5-hour session", &info.five_hour);
                    ui.add_space(8.0);
                    usage_row(ui, "Weekly limit", &info.weekly);
                }
                None => {
                    ui.label(RichText::new("Usage unavailable").size(12.0).color(SECONDARY));
                }
            }
        });

        ui.add_space(2.0);

        // Toggles.
        if ui.checkbox(&mut presence_on, "Presence enabled").changed() {
            let mut s = self.shared.settings.lock().unwrap();
            s.presence_enabled = presence_on;
            let _ = s.save();
        }
        if ui.checkbox(&mut self.autostart_on, "Launch at login").changed() {
            crate::autostart::set_enabled(self.autostart_on);
            self.autostart_on = crate::autostart::is_enabled();
        }

        ui.add_space(2.0);

        // Buttons.
        ui.horizontal(|ui| {
            if ui.button("Open settings").clicked() {
                {
                    let s = self.shared.settings.lock().unwrap();
                    let _ = s.save();
                }
                let _ = crate::util::command("notepad").arg(Settings::config_path()).spawn();
                self.hide(ctx);
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button("Quit").clicked() {
                    self.shared.quit.store(true, std::sync::atomic::Ordering::Relaxed);
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
            });
        });
    }
}

fn status_pill(presence_on: bool, conn: &str) -> (&'static str, Color32) {
    if !presence_on {
        ("Off", SECONDARY)
    } else if conn == "Connected" {
        ("Connected", GREEN)
    } else if conn.starts_with("Connecting") {
        ("Connecting", ORANGE)
    } else {
        ("Disconnected", SECONDARY)
    }
}

fn usage_row(ui: &mut egui::Ui, label: &str, w: &crate::models::UsageWindow) {
    ui.horizontal(|ui| {
        ui.label(RichText::new(label).size(12.5));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            ui.label(RichText::new(usage_detail(w)).size(12.5).strong().monospace());
        });
    });
    ui.add_space(4.0);
    let frac = (w.percent as f32 / 100.0).clamp(0.015, 1.0);
    let (rect, _) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 6.0), egui::Sense::hover());
    let painter = ui.painter();
    painter.rect_filled(rect, 3.0, Color32::from_rgb(0xe2, 0xe2, 0xe6));
    let fill = egui::Rect::from_min_size(rect.min, egui::vec2(rect.width() * frac, rect.height()));
    painter.rect_filled(fill, 3.0, severity_color(w));
}

fn usage_detail(w: &crate::models::UsageWindow) -> String {
    match w.resets_at_ms {
        Some(ms) => format!("{}% · {}", w.percent, format_reset(ms)),
        None => format!("{}%", w.percent),
    }
}

fn severity_color(w: &crate::models::UsageWindow) -> Color32 {
    match w.severity.to_lowercase().as_str() {
        "normal" => BLUE,
        s if s.contains("warn") => ORANGE,
        _ => RED,
    }
}

fn elapsed(start_ms: Option<i64>) -> String {
    let Some(start) = start_ms else { return "—".to_string() };
    let total = ((now_ms() - start) / 1000).max(0);
    let (h, m, s) = (total / 3600, total / 60 % 60, total % 60);
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

fn format_reset(resets_at_ms: i64) -> String {
    let secs = (resets_at_ms - now_ms()) / 1000;
    if secs <= 0 {
        return "now".to_string();
    }
    let (m, h, d) = (secs / 60 % 60, secs / 3600 % 24, secs / 86_400);
    if d > 0 {
        format!("in {d}d {h}h")
    } else if h > 0 {
        format!("in {h}h {m}m")
    } else {
        format!("in {m}m")
    }
}

fn load_rgba(png: &[u8]) -> Option<(Vec<u8>, u32, u32)> {
    let img = image::load_from_memory(png).ok()?.to_rgba8();
    let (w, h) = img.dimensions();
    Some((img.into_raw(), w, h))
}

fn work_area() -> RECT {
    let mut r = RECT { left: 0, top: 0, right: 0, bottom: 0 };
    unsafe {
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &mut r as *mut RECT as *mut _, 0);
    }
    r
}
