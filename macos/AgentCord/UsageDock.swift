//
//  UsageDock.swift
//  AgentCord
//
//  A hot-corner usage panel. Push the pointer into the top-right corner of a
//  screen and a compact card slides in from the right edge with every enabled
//  agent's rate-limit windows; move the pointer away and it slides back out.
//
//  The panel is a borderless, non-activating `NSPanel`, so peeking at usage
//  never steals focus from the editor. Pointer tracking is a global
//  `mouseMoved` monitor that only does a rect check per event — there is no
//  timer, so an idle pointer costs nothing. Mouse-move monitors don't need the
//  Accessibility permission (only keyboard monitors do).
//

import AppKit
import SwiftUI
import Combine

// MARK: - Layout

enum UsageDockLayout {
    static let width: CGFloat = 228
    /// Gap between the menu bar (or screen top) and the panel.
    static let topInset: CGFloat = 12
    static let cornerRadius: CGFloat = 12
    /// How far from the right edge the pointer counts as "in the corner".
    static let hotZoneWidth: CGFloat = 4
    /// How far down from the top of the screen the hot strip extends. Covers
    /// the menu bar plus the area the panel itself occupies.
    static let hotZoneHeight: CGFloat = 160
    /// Pointer slack around the shown panel before it starts hiding, so a
    /// slightly overshooting pointer doesn't dismiss it.
    static let dismissMargin: CGFloat = 28
    static let showDwell: TimeInterval = 0.12
    static let hideDelay: TimeInterval = 0.45
    static let slideDuration: TimeInterval = 0.22
}

// MARK: - Controller

/// Owns the hot-corner detection and the sliding panel. Enable/disable follows
/// the `usageDockEnabled` setting; the AppDelegate wires the hooks.
final class UsageDockController {

    /// Called right before the panel slides in, so usage can be refreshed.
    var onWillShow: (() -> Void)?
    /// Called when the user asks for the full popover from the dock header.
    var onOpenPopover: (() -> Void)?

    private let makeContent: (UsageDockController) -> AnyView

    private var panel: NSPanel?
    private var host: SizingHostingController<AnyView>?
    private var monitors: [Any] = []
    private var dwellTimer: Timer?
    private var hideTimer: Timer?
    private var isAnimating = false
    private(set) var isShown = false
    private var screen: NSScreen?

    init(makeContent: @escaping (UsageDockController) -> AnyView) {
        self.makeContent = makeContent
    }

    // MARK: Enable / disable

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard monitors.isEmpty else { return }
            installMonitors()
        } else {
            removeMonitors()
            cancelTimers()
            hide(animated: false)
        }
    }

    private func installMonitors() {
        // The global monitor never sees events over our own windows, so a local
        // one covers the pointer while it's on the panel itself.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.pointerMoved()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func cancelTimers() {
        dwellTimer?.invalidate(); dwellTimer = nil
        hideTimer?.invalidate(); hideTimer = nil
    }

    // MARK: Pointer tracking

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        if isShown {
            trackWhileShown(point)
        } else {
            trackWhileHidden(point)
        }
    }

    private func trackWhileHidden(_ point: NSPoint) {
        guard let target = Self.screenWithHotZone(containing: point) else {
            dwellTimer?.invalidate(); dwellTimer = nil
            return
        }
        // A short dwell filters out pointers just skimming the corner on the
        // way to a menu bar item.
        guard dwellTimer == nil else { return }
        let timer = Timer(timeInterval: UsageDockLayout.showDwell, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.dwellTimer = nil
            guard Self.screenWithHotZone(containing: NSEvent.mouseLocation) === target else { return }
            self.show(on: target)
        }
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    private func trackWhileShown(_ point: NSPoint) {
        guard let panel, let screen else { return }
        let keepOpen = panel.frame.insetBy(dx: -UsageDockLayout.dismissMargin, dy: -UsageDockLayout.dismissMargin)
        let inside = keepOpen.contains(point) || Self.hotZone(of: screen).contains(point)
        if inside {
            hideTimer?.invalidate(); hideTimer = nil
        } else if hideTimer == nil {
            let timer = Timer(timeInterval: UsageDockLayout.hideDelay, repeats: false) { [weak self] _ in
                self?.hideTimer = nil
                self?.hide(animated: true)
            }
            RunLoop.main.add(timer, forMode: .common)
            hideTimer = timer
        }
    }

    /// The strip along the right edge at the top of `screen`, in global
    /// screen coordinates. Uses the full frame (not `visibleFrame`) so the
    /// corner next to the menu bar counts too. A pointer pinned to the edge
    /// reports exactly `maxX` / `maxY`, which `NSRect.contains` treats as
    /// outside, so the zone overhangs the screen by a point.
    private static func hotZone(of screen: NSScreen) -> NSRect {
        let frame = screen.frame
        return NSRect(
            x: frame.maxX - UsageDockLayout.hotZoneWidth,
            y: frame.maxY - UsageDockLayout.hotZoneHeight,
            width: UsageDockLayout.hotZoneWidth + 1,
            height: UsageDockLayout.hotZoneHeight + 1
        )
    }

    private static func screenWithHotZone(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { hotZone(of: $0).contains(point) }
    }

    // MARK: Panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: UsageDockLayout.width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Same fixed light palette as the popover.
        panel.appearance = NSAppearance(named: .aqua)

        let host = SizingHostingController(rootView: makeContent(self))
        host.fixedWidth = UsageDockLayout.width
        host.onContentSizeChange = { [weak self] size in
            self?.contentSizeChanged(size)
        }
        panel.contentViewController = host
        self.host = host
        self.panel = panel
        return panel
    }

    /// Frame for a fully slid-in panel on `screen`: flush with the right edge,
    /// just under the menu bar.
    private func restingFrame(on screen: NSScreen, size: NSSize) -> NSRect {
        let top = screen.visibleFrame.maxY - UsageDockLayout.topInset
        return NSRect(
            x: screen.frame.maxX - size.width,
            y: top - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func contentSizeChanged(_ size: NSSize) {
        guard let panel, let screen, isShown, !isAnimating else { return }
        panel.setFrame(restingFrame(on: screen, size: size), display: true)
    }

    private func show(on screen: NSScreen) {
        guard !isShown else { return }
        onWillShow?()
        let panel = ensurePanel()
        self.screen = screen
        isShown = true

        panel.layoutIfNeeded()
        let size = NSSize(
            width: UsageDockLayout.width,
            height: max(panel.contentView?.fittingSize.height ?? 0, 60).rounded(.up)
        )
        let resting = restingFrame(on: screen, size: size)
        var offscreen = resting
        offscreen.origin.x = screen.frame.maxX
        panel.setFrame(offscreen, display: false)
        panel.orderFrontRegardless()

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = UsageDockLayout.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(resting, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.isAnimating = false
            // Content may have relaid out during the slide; settle to its size.
            if let host = self.host {
                self.contentSizeChanged(NSSize(
                    width: UsageDockLayout.width,
                    height: host.view.fittingSize.height.rounded(.up)
                ))
            }
        })
    }

    func hide(animated: Bool) {
        guard isShown, let panel, let screen else { return }
        isShown = false
        hideTimer?.invalidate(); hideTimer = nil

        var offscreen = panel.frame
        offscreen.origin.x = screen.frame.maxX
        guard animated else {
            panel.orderOut(nil)
            return
        }
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = UsageDockLayout.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(offscreen, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.isAnimating = false
            // Re-shown during the slide-out? Leave it on screen.
            if !self.isShown { panel.orderOut(nil) }
        })
    }

    /// Header action: dismiss the dock and hand off to the main popover.
    func openPopover() {
        hide(animated: false)
        onOpenPopover?()
    }
}

// MARK: - Usage summary

/// Maps every agent's provider-specific snapshot onto plain
/// `UsageInfo.Window`s so the unified card and the dock render one way.
enum UsageSummary {

    struct Row: Identifiable {
        let label: String
        let window: UsageInfo.Window
        var id: String { label }
    }

    /// The single window that best summarizes an agent (used by the unified
    /// usage card). `window` is nil until that agent has reported.
    static func primaryWindow(
        for agent: AgentKind,
        claude: UsageInfo?,
        cursor: CursorUsageInfo?,
        codex: CodexUsageInfo?,
        grok: GrokUsageInfo?,
        antigravity: AntigravityUsageInfo?
    ) -> (label: String, window: UsageInfo.Window?) {
        switch agent {
        case .claude:
            return (agent.displayName, claude?.fiveHour)
        case .cursor:
            return (agent.displayName, cursor.map { mapped($0.included) })
        case .codex:
            return (agent.displayName, codex?.primary)
        case .grok:
            return (agent.displayName, grok?.weekly)
        case .antigravity:
            return ("Agy", antigravity?.fiveHour)
        }
    }

    /// Every window worth a bar in the dock, primary first. Empty until the
    /// agent has reported.
    static func rows(
        for agent: AgentKind,
        claude: UsageInfo?,
        cursor: CursorUsageInfo?,
        codex: CodexUsageInfo?,
        grok: GrokUsageInfo?,
        antigravity: AntigravityUsageInfo?
    ) -> [Row] {
        switch agent {
        case .claude:
            guard let info = claude else { return [] }
            return [Row(label: "Session", window: info.fiveHour), Row(label: "Weekly", window: info.weekly)]
        case .cursor:
            guard let info = cursor else { return [] }
            // Total spend, then the Auto/Composer ("Cursor models") and named
            // API ("Other models") splits the dashboard reports when they
            // differ from the total.
            var rows = [Row(label: "Total", window: mapped(info.included))]
            if let auto = info.auto { rows.append(Row(label: "Cursor", window: mapped(auto))) }
            if let api = info.api { rows.append(Row(label: "Other", window: mapped(api))) }
            return rows
        case .codex:
            guard let info = codex else { return [] }
            var rows = [Row(label: shortLabel(info.primaryLabel), window: info.primary)]
            if let secondary = info.secondary {
                rows.append(Row(label: shortLabel(info.secondaryLabel ?? "Secondary"), window: secondary))
            }
            return rows
        case .grok:
            guard let info = grok else { return [] }
            var rows = [Row(label: "Weekly", window: info.weekly)]
            if let onDemand = info.onDemand { rows.append(Row(label: "Extra", window: onDemand)) }
            return rows
        case .antigravity:
            guard let info = antigravity else { return [] }
            return [Row(label: "5-hour", window: info.fiveHour), Row(label: "Weekly", window: info.weekly)]
        }
    }

    private static func mapped(_ window: CursorUsageInfo.Window) -> UsageInfo.Window {
        UsageInfo.Window(percent: window.percent, severity: window.severity, resetsAt: window.resetsAt)
    }

    /// "5-hour session" → "5-hour", "Weekly limit" → "Weekly". The dock's
    /// label column is narrow.
    private static func shortLabel(_ label: String) -> String {
        var s = label
        for suffix in [" session", " limit"] where s.lowercased().hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        return s
    }
}

// MARK: - Content

struct UsageDockView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: PresenceController
    @EnvironmentObject private var usage: ClaudeUsage
    @EnvironmentObject private var cursorUsage: CursorUsage
    @EnvironmentObject private var codexUsage: CodexUsage
    @EnvironmentObject private var grokUsage: GrokUsage
    @EnvironmentObject private var antigravityUsage: AntigravityUsage

    let onOpen: () -> Void

    private var agents: [AgentKind] {
        let enabled = settings.enabledAgents
        return enabled.isEmpty ? [.claude] : enabled
    }

    private func rows(for agent: AgentKind) -> [UsageSummary.Row] {
        UsageSummary.rows(
            for: agent,
            claude: usage.current,
            cursor: cursorUsage.current,
            codex: codexUsage.current,
            grok: grokUsage.current,
            antigravity: antigravityUsage.current
        )
    }

    var body: some View {
        let sections = agents.map { ($0, rows(for: $0)) }.filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            if sections.isEmpty {
                Text("No usage data yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary.opacity(0.45))
                    .italic()
                    .padding(.bottom, 2)
            } else {
                ForEach(Array(sections.enumerated()), id: \.element.0.id) { index, section in
                    agentSection(section.0, rows: section.1, divider: index > 0)
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .frame(width: UsageDockLayout.width, alignment: .topLeading)
        .background(LeftRoundedRect(radius: UsageDockLayout.cornerRadius).fill(Color(.sRGB, white: 0.965, opacity: 1)))
        .overlay(LeftRoundedRect(radius: UsageDockLayout.cornerRadius).stroke(.black.opacity(0.1), lineWidth: 0.5))
        .foregroundStyle(Palette.text)
        .fontDesign(.monospaced)
        .contentShape(Rectangle())
        // No chrome on the card; clicking anywhere on it opens the full popover.
        .onTapGesture(perform: onOpen)
    }

    private func agentSection(_ agent: AgentKind, rows: [UsageSummary.Row], divider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(agent.displayName)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                if let primary = rows.first {
                    Text("\(primary.window.percent)%")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(severityColor(primary.window))
                }
            }
            ForEach(rows) { row in
                usageRow(row)
            }
        }
        .padding(.top, divider ? 8 : 0)
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(.black.opacity(0.07)).frame(height: 0.5) }
        }
    }

    private func usageRow(_ row: UsageSummary.Row) -> some View {
        HStack(spacing: 8) {
            Text(row.label)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.secondary.opacity(0.6))
                .frame(width: 58, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track.opacity(0.16))
                    Capsule()
                        .fill(severityColor(row.window))
                        .frame(width: geo.size.width * barFraction(row.window))
                }
            }
            .frame(height: 5)
            // Countdown ticks while the dock is open.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(detail(row.window, now: context.date))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }

    private func detail(_ window: UsageInfo.Window, now: Date) -> String {
        guard let reset = MenuContentView.formatResetDuration(window, now: now) else {
            return "\(window.percent)%"
        }
        return reset
    }

    private func barFraction(_ window: UsageInfo.Window) -> CGFloat {
        max(CGFloat(window.percent) / 100, 0.015)
    }

    private func severityColor(_ window: UsageInfo.Window) -> Color {
        switch window.severity.lowercased() {
        case "normal": return Palette.blue
        case "warning", "warn", "low": return Palette.orange
        default: return Palette.red
        }
    }

}

/// Card shape with rounded corners on the left only, so the panel reads as
/// attached to the right screen edge.
struct LeftRoundedRect: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        p.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
            startAngle: .degrees(-90), endAngle: .degrees(-180), clockwise: true
        )
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        p.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius,
            startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
