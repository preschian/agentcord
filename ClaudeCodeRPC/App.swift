//
//  App.swift
//  ClaudeCodeRPC
//
//  Menu bar entry point. No Dock icon (LSUIElement / accessory policy).
//

import SwiftUI
import AppKit
import Combine

@main
struct ClaudeCodeRPCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The UI lives entirely in an NSStatusItem + NSPopover managed by the
    // delegate (see below for why). This empty Settings scene just gives the
    // App a Scene to satisfy the protocol; it never shows for an accessory app.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// We drive the menu bar item with AppKit (`NSStatusItem`) rather than
/// SwiftUI's `MenuBarExtra`. A `MenuBarExtra` whose label updates every second
/// (to tick the elapsed timer) recreates its status item on each update, which
/// drops clicks so the popover can't be opened. An `NSStatusItem` lets us
/// refresh just the button title on a timer while clicks stay reliable.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    let loginItem = LoginItem()
    let usage = ClaudeUsage()
    lazy var controller = PresenceController(settings: settings)

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private lazy var connectedIcon = Self.icon(connected: true)
    private lazy var disconnectedIcon = Self.icon(connected: false)
    private var lastConnected: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and suspenders: ensure no Dock icon even without LSUIElement.
        NSApp.setActivationPolicy(.accessory)
        controller.start()
        usage.start()

        setupStatusItem()
        setupPopover()
        startRefreshTimer()

        // The per-tick refresh leaves the menu bar untouched while the popover is
        // open (so it doesn't jitter). But a deliberate settings change — e.g.
        // toggling "Show usage in menu bar" — should reflect right away even with
        // the popover still open, so force a refresh on any settings change.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshStatusButton(force: true) }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }
        refreshStatusButton()
    }

    private func setupPopover() {
        popover.behavior = .transient
        // Don't animate the popover's open/close.
        popover.animates = false
        let content = MenuContentView()
            .environmentObject(settings)
            .environmentObject(controller)
            .environmentObject(loginItem)
            .environmentObject(usage)
        // Size the popover ourselves instead of using `.preferredContentSize`.
        // That automatic path animates the resize, so expanding/collapsing the
        // Settings section made the popover wobble. Pushing the size through a
        // zero-duration animation context makes it snap instantly instead.
        let host = SizingHostingController(rootView: content)
        host.onContentSizeChange = { [weak self] size in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                self.popover.contentSize = size
            }
        }
        popover.contentViewController = host
    }

    private func startRefreshTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStatusButton()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Pull fresh usage numbers as the popover opens so they're current.
            usage.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Updates the icon (only when the connection state flips) and the title
    /// (every tick, so the elapsed timer counts up live).
    private func refreshStatusButton(force: Bool = false) {
        guard let button = statusItem.button else { return }

        // While the popover is open, leave the button untouched. Re-setting its
        // title/image changes the status item's width, which nudges the anchored
        // popover every tick and makes its contents jitter. A forced refresh
        // (from a deliberate settings change) bypasses this so the result shows
        // immediately.
        guard force || !popover.isShown else { return }

        let connected = controller.discordState == .connected
        if lastConnected != connected {
            button.image = connected ? connectedIcon : disconnectedIcon
            lastConnected = connected
        }

        // Monospaced digits keep the elapsed timer and percentages from
        // jittering as the title refreshes each tick.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)
        let title = NSMutableAttributedString()

        if settings.showMenuBarStatus, let info = controller.session.current {
            title.append(NSAttributedString(
                string: Self.statusText(for: info, settings: settings),
                attributes: [.font: font]
            ))
        }

        if settings.showUsageInMenuBar, let snapshot = usage.current {
            if title.length > 0 {
                title.append(NSAttributedString(
                    string: " · ",
                    attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
                ))
            }
            Self.appendUsage(snapshot, to: title, font: font)
        }

        if title.length > 0 {
            // Leading space keeps the text off the icon.
            let full = NSMutableAttributedString(string: " ", attributes: [.font: font])
            full.append(title)
            button.attributedTitle = full
        } else {
            button.title = ""
        }
    }

    // MARK: Formatting

    /// Builds the menu bar string, e.g. "Opus 4.8 · 10m · 48.0K tokens".
    /// Honors the same Show model / Show tokens toggles as the Discord presence.
    static func statusText(for info: SessionInfo, settings: SettingsStore) -> String {
        var parts: [String] = []
        if settings.showModel, let model = info.model { parts.append(model) }

        let elapsedMs = Int64(Date().timeIntervalSince1970 * 1000) - info.startEpochMs
        parts.append(formatElapsed(elapsedMs))

        if settings.showTokens, info.totalTokens > 0 {
            parts.append("\(PresenceController.formatTokens(info.totalTokens)) tokens")
        }
        return parts.joined(separator: " · ")
    }

    /// Appends a compact "5h NN% · Wk NN%" usage readout, tinting each figure by
    /// its severity so an elevated limit stands out even in the menu bar.
    static func appendUsage(_ usage: UsageInfo, to title: NSMutableAttributedString, font: NSFont) {
        func color(_ window: UsageInfo.Window) -> NSColor {
            switch window.severity.lowercased() {
            case "normal": return .labelColor
            case "warning", "warn", "low": return .systemOrange
            default: return .systemRed
            }
        }
        title.append(NSAttributedString(
            string: "5h \(usage.fiveHour.percent)%",
            attributes: [.font: font, .foregroundColor: color(usage.fiveHour)]
        ))
        // Tie the 5-hour reset countdown to its figure, e.g. "5h 46% (1h 23m)".
        if let reset = MenuContentView.timeUntilReset(usage.fiveHour) {
            title.append(NSAttributedString(
                string: " (\(reset))",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        title.append(NSAttributedString(
            string: " · ",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        ))
        title.append(NSAttributedString(
            string: "Wk \(usage.weekly.percent)%",
            attributes: [.font: font, .foregroundColor: color(usage.weekly)]
        ))
    }

    /// Formats a duration without seconds: "Hh Mm" once it reaches an hour,
    /// otherwise "Mm" (e.g. "1h 05m", "10m").
    static func formatElapsed(_ ms: Int64) -> String {
        let totalMinutes = max(0, Int(ms / 60000))
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return h > 0
            ? String(format: "%dh %02dm", h, m)
            : String(format: "%dm", m)
    }

    /// The sparkles icon, dimmed when Discord is not connected (mirrors the old
    /// "slash" treatment without needing a dedicated slashed symbol).
    static func icon(connected: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "agentcord") else {
            return nil
        }
        base.isTemplate = true
        guard !connected else { return base }

        let dimmed = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.35)
            return true
        }
        dimmed.isTemplate = true
        return dimmed
    }
}

// MARK: - Popover sizing

/// Hosting controller that reports its content's fitting size whenever it lays
/// out, so the popover can be resized manually and instantly. Avoids the
/// animated resize that `NSHostingController.sizingOptions = .preferredContentSize`
/// triggers, which made the popover wobble when the Settings section toggled.
final class SizingHostingController<Content: View>: NSHostingController<Content> {
    var onContentSizeChange: ((NSSize) -> Void)?
    private var lastReportedSize: NSSize = .zero

    override func viewDidLayout() {
        super.viewDidLayout()
        // Round up to whole points. `fittingSize` can wobble by a sub-point each
        // layout pass (text-heavy rows especially), and since setting the popover
        // size triggers another layout, those fractional differences would loop
        // forever and make the contents jitter. Rounding collapses that to a
        // stable integer size.
        let raw = view.fittingSize
        let size = NSSize(width: raw.width.rounded(.up), height: raw.height.rounded(.up))
        guard size.width > 0, size.height > 0, size != lastReportedSize else { return }
        lastReportedSize = size
        onContentSizeChange?(size)
    }
}

// MARK: - Popover content

struct MenuContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: PresenceController
    @EnvironmentObject private var loginItem: LoginItem
    @EnvironmentObject private var usage: ClaudeUsage

    var body: some View {
        // Everything is shown at once. The popover used to have a collapsible
        // "Settings" section, but expanding/collapsing it resized the popover and
        // made the contents jump. A fixed layout never resizes, so nothing moves.
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statusSection
            Divider()
            toggles
            Divider()
            Text("Settings")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            settingsForm
            Divider()
            Button("Quit agentcord") {
                controller.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
            Text("agentcord")
                .font(.headline)
            Spacer()
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text("Discord: \(controller.discordState.description)")
                    .font(.subheadline)
            }

            if let session = controller.session.current {
                Text("Project: \(session.projectName)")
                    .font(.subheadline)
                if let model = session.model {
                    Text("Model: \(model)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No active session")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let usage = usage.current {
                HStack(spacing: 6) {
                    Text("Usage")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    usageBadge("5h", usage.fiveHour)
                    Text("·")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    usageBadge("Week", usage.weekly)
                }
                .padding(.top, 2)

                if let resets = usageResetText(usage) {
                    Text(resets)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One usage figure, e.g. "5h 46%", tinted by severity. The reset time rides
    /// along as a tooltip to keep the row compact.
    private func usageBadge(_ label: String, _ window: UsageInfo.Window) -> some View {
        Text("\(label) \(window.percent)%")
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(usageColor(window))
            .help(usageTooltip(window))
    }

    private func usageColor(_ window: UsageInfo.Window) -> Color {
        switch window.severity.lowercased() {
        case "normal": return .primary
        case "warning", "warn", "low": return .orange
        default: return .red
        }
    }

    private func usageTooltip(_ window: UsageInfo.Window) -> String {
        guard let reset = window.resetsAt else { return "\(window.percent)% used" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(window.percent)% used · resets \(formatter.localizedString(for: reset, relativeTo: Date()))"
    }

    /// A compact "Resets · 5h in 1h 23m · weekly in 6d" line for whichever
    /// windows report a reset time. Recomputed each time the popover renders.
    private func usageResetText(_ usage: UsageInfo) -> String? {
        let parts = [
            Self.timeUntilReset(usage.fiveHour).map { "5h in \($0)" },
            Self.timeUntilReset(usage.weekly).map { "weekly in \($0)" }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : "Resets · " + parts.joined(separator: " · ")
    }

    /// Formats the time remaining until a window resets, e.g. "1h 23m", "45m",
    /// "6d 4h". Returns nil when there's no reset time, "now" once it's due.
    static func timeUntilReset(_ window: UsageInfo.Window) -> String? {
        guard let reset = window.resetsAt else { return nil }
        let seconds = Int(reset.timeIntervalSinceNow)
        guard seconds > 0 else { return "now" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable presence", isOn: Binding(
                get: { settings.presenceEnabled },
                set: { controller.setEnabled($0) }
            ))
            Toggle("Do not disturb (pause updates)", isOn: $settings.doNotDisturb)
            Toggle("Launch at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
        }
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show project", isOn: $settings.showProject)
            Toggle("Show model", isOn: $settings.showModel)
            Toggle("Show tokens", isOn: $settings.showTokens)
            Toggle("Show status in menu bar", isOn: $settings.showMenuBarStatus)
            Toggle("Show usage in menu bar", isOn: $settings.showUsageInMenuBar)

            Picker("Activity type", selection: $settings.activityType) {
                ForEach(SettingsStore.allowedActivityTypes, id: \.value) { type in
                    Text(type.name).tag(type.value)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Idle window: \(Int(settings.idleWindowSeconds / 60)) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.idleWindowSeconds, in: 300...1800, step: 300)
            }
        }
    }

    private var statusColor: Color {
        switch controller.discordState {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        }
    }
}
