//
//  App.swift
//  AgentCord
//
//  Menu bar entry point. No Dock icon (LSUIElement / accessory policy).
//

import SwiftUI
import AppKit

@main
struct AgentCordApp: App {
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let settings = SettingsStore()
    let loginItem = LoginItem()
    let usage = ClaudeUsage()
    let anthropicStatus = AnthropicStatus()
    lazy var controller = PresenceController(settings: settings)

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var refreshTimer: Timer?
    private lazy var connectedIcon = Self.icon(connected: true)
    private lazy var disconnectedIcon = Self.icon(connected: false)
    private var lastConnected: Bool?
    private var lastStatusTitle = NSAttributedString()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and suspenders: ensure no Dock icon even without LSUIElement.
        NSApp.setActivationPolicy(.accessory)
        controller.start()
        usage.start()
        anthropicStatus.start()

        setupStatusItem()
        setupPopover()
        startRefreshTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    // MARK: NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Apply any menu-bar-affecting settings now that the popover is gone, so
        // the title width change can't move a still-open popover.
        refreshStatusButton()
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
        // The redesigned content uses a fixed light palette, so pin the popover
        // to the light appearance for consistent rendering in either system mode.
        popover.appearance = NSAppearance(named: .aqua)
        // Refresh the menu bar once the popover closes: settings changed inside
        // it (e.g. "Show status in menu bar") alter the title width, so applying
        // them while the popover is open would move the anchored popover.
        popover.delegate = self
        let content = MenuContentView()
            .environmentObject(settings)
            .environmentObject(controller)
            .environmentObject(loginItem)
            .environmentObject(usage)
            .environmentObject(anthropicStatus)
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
            // Pull fresh usage numbers and Anthropic status as the popover
            // opens so they're current.
            usage.refresh()
            anthropicStatus.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Updates the icon (only when the connection state flips) and the title
    /// (every tick, so the elapsed timer counts up live).
    private func refreshStatusButton() {
        guard let button = statusItem.button else { return }

        // While the popover is open, leave the button untouched. Re-setting its
        // title/image changes the status item's width, which nudges the anchored
        // popover and makes it move. The popover's delegate refreshes the title
        // once it closes, and the timer keeps it current thereafter.
        guard !popover.isShown else { return }

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
                    attributes: [.font: font, .foregroundColor: NSColor.labelColor]
                ))
            }
            Self.appendUsage(snapshot, to: title, font: font)
        }

        // Leading space keeps the text off the icon.
        let full = NSMutableAttributedString()
        if title.length > 0 {
            full.append(NSAttributedString(string: " ", attributes: [.font: font]))
            full.append(title)
        }

        // The title is minute-granular, so on most of the per-second ticks it's
        // identical. Skip touching the button then — assigning the title relays
        // out the status item every second for nothing.
        guard !full.isEqual(to: lastStatusTitle) else { return }
        lastStatusTitle = full
        if full.length > 0 {
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

    /// Appends a compact "5h NN% (1h 23m)" usage readout, tinting the figure by
    /// its severity so an elevated limit stands out even in the menu bar. Only
    /// the 5-hour window is shown here.
    static func appendUsage(_ usage: UsageInfo, to title: NSMutableAttributedString, font: NSFont) {
        let window = usage.fiveHour
        let color: NSColor
        switch window.severity.lowercased() {
        case "normal": color = .labelColor
        case "warning", "warn", "low": color = .systemOrange
        default: color = .systemRed
        }
        title.append(NSAttributedString(
            string: "5h \(window.percent)%",
            attributes: [.font: font, .foregroundColor: color]
        ))
        // Tie the 5-hour reset time to its figure, e.g. "5h 46% (12.29 pm)".
        if let reset = MenuContentView.formatResetTime(window, style: .time) {
            title.append(NSAttributedString(
                string: " (\(reset))",
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            ))
        }
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
    @EnvironmentObject private var anthropicStatus: AnthropicStatus

    @State private var showSettings = false
    @State private var expandDisplay = false
    @State private var expandActivity = false
    @State private var expandStatus = false

    private let idleSteps = [5, 10, 15, 20, 25, 30]

    // Screens slide horizontally: going to Settings pushes left, going back
    // pushes right. Using `.transition(.move)` (rather than animating an explicit
    // height) keeps the popover height constant for the whole slide and lets it
    // snap once at the end — that's what kept the earlier version from looking
    // messy, where the height interpolated and the popover resized every frame.
    var body: some View {
        ZStack(alignment: .top) {
            if showSettings {
                settingsScreen
                    .transition(.move(edge: .trailing))
            } else {
                mainScreen
                    .transition(.move(edge: .leading))
            }
        }
        .frame(width: 300, alignment: .top)
        .clipped()
        .foregroundStyle(Palette.text)
        .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.32), value: showSettings)
    }

    // MARK: Screens

    private var mainScreen: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            activeSessionCard
            usageCard
            statusCard
            settingsNavRow
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, -13)
            quitButton
        }
        .padding(13)
        .frame(width: 300, alignment: .topLeading)
    }

    private var settingsScreen: some View {
        VStack(alignment: .leading, spacing: 11) {
            settingsHeader
            primaryToggles
            advancedSections
        }
        .padding(13)
        .frame(width: 300, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color(.sRGB, red: 0.227, green: 0.227, blue: 0.235),
                        Color(.sRGB, red: 0.106, green: 0.106, blue: 0.114)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                )
                .shadow(color: .black.opacity(0.28), radius: 1, y: 1)

            Text("agentcord")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        let accent: Color
        let textColor: Color
        let label: String
        if !settings.presenceEnabled {
            accent = Palette.track
            textColor = Palette.secondary.opacity(0.7)
            label = "Off"
        } else if controller.discordState == .connected {
            accent = Palette.green
            textColor = Palette.greenText
            label = "Connected"
        } else {
            accent = Palette.yellow
            textColor = Color(.sRGB, red: 0.6, green: 0.45, blue: 0.0)
            label = "Connecting"
        }
        return HStack(spacing: 5) {
            Circle().fill(accent).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(textColor)
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 2)
        .background(Capsule().fill(accent.opacity(0.12)))
        .overlay(Capsule().stroke(accent.opacity(0.28), lineWidth: 0.5))
    }

    /// Settings screen header: a back chevron that returns to the main screen,
    /// plus the title.
    private var settingsHeader: some View {
        HStack(spacing: 9) {
            Button {
                showSettings = false
            } label: {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.track.opacity(0.14))
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Palette.text)
                    )
            }
            .buttonStyle(.plain)

            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
    }

    /// Main-screen row that slides over to the settings screen. Mirrors the
    /// collapsible-section styling and summarizes presence state.
    private var settingsNavRow: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary.opacity(0.65))
                Text("Settings").font(.system(size: 13))
                Spacer()
                Text(settings.presenceEnabled ? "Presence on" : "Presence off")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary.opacity(0.4))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.secondary.opacity(0.3))
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.black.opacity(0.07), lineWidth: 0.5))
    }

    // MARK: Active session card

    private var activeSessionCard: some View {
        let session = controller.session.current
        let hasSession = session != nil
        let presenceOn = settings.presenceEnabled
        let active = hasSession && presenceOn

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("ACTIVE SESSION")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Palette.secondary.opacity(0.55))
                Spacer()
                HStack(spacing: 5) {
                    SessionDot(active: active).id(active)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsedClock(session, now: context.date))
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(active ? Palette.text : Palette.secondary.opacity(0.45))
                    }
                }
                .padding(.leading, 7).padding(.trailing, 8).padding(.vertical, 2)
                .background(Capsule().fill(Palette.track.opacity(0.1)))
            }

            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary.opacity(0.55))
                Text(projectText(session))
                    .font(.system(size: 13.5, weight: .semibold))
                    .italic(!hasSession || !settings.showProject)
                    .foregroundStyle((active && hasSession && settings.showProject) ? Palette.text : Palette.secondary.opacity(0.45))
            }

            Text(metaLine(session))
                .font(.system(size: 12.5))
                .italic(metaBits(session).isEmpty)
                .foregroundStyle(active && !metaBits(session).isEmpty ? Palette.secondary.opacity(0.7) : Palette.secondary.opacity(0.4))
                .padding(.leading, 21)

            HStack(spacing: 6) {
                Circle()
                    .fill(active ? Palette.discord : Palette.track.opacity(0.6))
                    .frame(width: 5, height: 5)
                Text(broadcastText(hasSession: hasSession, presenceOn: presenceOn))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary.opacity(0.5))
            }
            .padding(.top, 8)
            .overlay(alignment: .top) {
                Rectangle().fill(.black.opacity(0.06)).frame(height: 0.5)
            }
        }
        .padding(.vertical, 11).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.black.opacity(0.06), lineWidth: 0.5))
    }

    private func elapsedClock(_ session: SessionInfo?, now: Date) -> String {
        guard let session else { return "—" }
        let ms = Int64(now.timeIntervalSince1970 * 1000) - session.startEpochMs
        let total = max(0, Int(ms / 1000))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func projectText(_ session: SessionInfo?) -> String {
        guard let session else { return "No active session" }
        return settings.showProject ? session.projectName : "Project hidden"
    }

    private func metaBits(_ session: SessionInfo?) -> [String] {
        guard let session else { return [] }
        var bits: [String] = []
        if settings.showModel, let model = session.model { bits.append(model) }
        if settings.showTokens, session.totalTokens > 0 {
            bits.append("\(PresenceController.formatTokens(session.totalTokens)) tokens")
        }
        return bits
    }

    private func metaLine(_ session: SessionInfo?) -> String {
        let bits = metaBits(session)
        if bits.isEmpty { return session == nil ? "Waiting for a session" : "Model & tokens hidden" }
        return bits.joined(separator: "  ·  ")
    }

    private func broadcastText(hasSession: Bool, presenceOn: Bool) -> String {
        if !presenceOn { return "Presence is off" }
        return hasSession ? "Sharing to Discord as your status" : "Waiting for a session"
    }

    // MARK: Usage card

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("USAGE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Palette.secondary.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
            usageRow("5-hour session", usage.current?.fiveHour, resetStyle: .time)
            usageRow("Weekly limit", usage.current?.weekly, resetStyle: .date)

            if let error = controller.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 11).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.black.opacity(0.06), lineWidth: 0.5))
    }

    private func usageRow(_ label: String, _ window: UsageInfo.Window?, resetStyle: ResetDisplayStyle) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(label).font(.system(size: 12.5))
                Spacer()
                Text(usageDetail(window, resetStyle: resetStyle))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track.opacity(0.16))
                    Capsule()
                        .fill(severityColor(window))
                        .frame(width: geo.size.width * barFraction(window))
                }
            }
            .frame(height: 6)
        }
    }

    private func usageDetail(_ window: UsageInfo.Window?, resetStyle: ResetDisplayStyle) -> String {
        guard let window else { return "—" }
        if let reset = Self.formatResetTime(window, style: resetStyle) {
            return "\(window.percent)% · resets \(reset)"
        }
        return "\(window.percent)%"
    }

    enum ResetDisplayStyle {
        case time   // e.g. "12.29 pm"
        case date   // e.g. "Jun 29"
    }

    private func barFraction(_ window: UsageInfo.Window?) -> CGFloat {
        guard let window else { return 0 }
        // Keep a faint sliver visible even at 0% so the track reads as a bar.
        return max(CGFloat(window.percent) / 100, 0.015)
    }

    private func severityColor(_ window: UsageInfo.Window?) -> Color {
        guard let window else { return Palette.blue }
        switch window.severity.lowercased() {
        case "normal": return Palette.blue
        case "warning", "warn", "low": return Palette.orange
        default: return Palette.red
        }
    }

    /// Formats when a window resets as a clock time or calendar date, e.g.
    /// "12.29 pm" or "Jun 29". Returns nil when there's no reset time, "now"
    /// once it's due.
    static func formatResetTime(_ window: UsageInfo.Window, style: ResetDisplayStyle) -> String? {
        guard let reset = window.resetsAt else { return nil }
        guard reset.timeIntervalSinceNow > 0 else { return "now" }
        switch style {
        case .time: return formatResetClock(reset)
        case .date: return resetDateFormatter.string(from: reset)
        }
    }

    private static func formatResetClock(_ date: Date) -> String {
        resetClockFormatter.string(from: date).lowercased()
    }

    private static let resetClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h.mm a"
        return f
    }()

    private static let resetDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    // MARK: Claude status card

    /// Surfaces status.claude.com as a compact collapsible row: a severity pill
    /// in the header that expands to any active incident plus a per-component
    /// breakdown. Hidden entirely until the first successful fetch, so a brief
    /// offline moment shows nothing rather than a broken card.
    @ViewBuilder
    private var statusCard: some View {
        if let status = anthropicStatus.current {
            VStack(spacing: 0) {
                statusHeader(status)

                if expandStatus {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(status.incidents.enumerated()), id: \.offset) { _, incident in
                            incidentCallout(incident)
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(status.components.enumerated()), id: \.offset) { _, comp in
                                componentRow(comp)
                            }
                        }

                        statusFooter(status)
                    }
                    .padding(.horizontal, 11).padding(.top, 9).padding(.bottom, 10)
                    .overlay(alignment: .top) {
                        Rectangle().fill(.black.opacity(0.06)).frame(height: 0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.black.opacity(0.07), lineWidth: 0.5))
        }
    }

    /// Collapsed row: "Claude status" label, severity pill, and expand chevron.
    /// The whole row toggles the per-component breakdown.
    private func statusHeader(_ status: StatusInfo) -> some View {
        let pill = statusPillStyle(status.level)
        return Button {
            expandStatus.toggle()
        } label: {
            HStack(spacing: 6) {
                Text("Claude status").font(.system(size: 13))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(pill.dot).frame(width: 6, height: 6)
                    Text(status.summaryLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(pill.text)
                }
                .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 2)
                .background(Capsule().fill(pill.bg))
                .overlay(Capsule().stroke(pill.border, lineWidth: 0.5))
                Image(systemName: expandStatus ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.secondary.opacity(0.35))
                    // Pin the chevron's slot: chevron.down and chevron.right have
                    // different widths, so without a fixed frame the pill beside
                    // it shifts a pixel each time the section toggles.
                    .frame(width: 10, alignment: .center)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// An active incident, tinted by its impact.
    private func incidentCallout(_ incident: StatusInfo.Incident) -> some View {
        let tint = impactColor(incident.impact)
        return HStack(alignment: .top, spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(incident.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                Text(incidentMeta(incident))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.opacity(0.2), lineWidth: 0.5))
    }

    /// One row of the per-component breakdown.
    private func componentRow(_ comp: StatusInfo.Component) -> some View {
        let color = componentColor(comp.status)
        return HStack(spacing: 10) {
            Text(comp.name)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(comp.status.label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(color)
                    .fixedSize()
            }
        }
    }

    /// Footer summary line plus a link out to the full status page.
    private func statusFooter(_ status: StatusInfo) -> some View {
        let count = status.degradedCount
        let summary = count > 0
            ? "\(count) of \(status.components.count) degraded · updated \(relativeUpdated(status.fetchedAt))"
            : "All systems operational · updated \(relativeUpdated(status.fetchedAt))"
        return Link(destination: URL(string: "https://status.claude.com")!) {
            HStack {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary.opacity(0.5))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.secondary.opacity(0.35))
            }
            .padding(.top, 8)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Rectangle().fill(.black.opacity(0.06)).frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Status formatting

    private func statusPillStyle(_ level: StatusInfo.Level) -> (bg: Color, border: Color, dot: Color, text: Color) {
        switch level {
        case .none:
            return (Palette.green.opacity(0.12), Palette.green.opacity(0.28), Palette.green, Palette.greenText)
        case .minor, .major:
            return (Palette.orange.opacity(0.12), Palette.orange.opacity(0.3), Palette.orange, Palette.orangeText)
        case .critical:
            return (Palette.red.opacity(0.12), Palette.red.opacity(0.3), Palette.red, Palette.redText)
        case .maintenance:
            return (Palette.blue.opacity(0.12), Palette.blue.opacity(0.3), Palette.blue, Palette.blueText)
        case .unknown:
            return (Palette.track.opacity(0.14), Palette.track.opacity(0.28), Palette.track, Palette.secondary.opacity(0.7))
        }
    }

    private func componentColor(_ status: StatusInfo.ComponentStatus) -> Color {
        switch status {
        case .operational: return Palette.green
        case .degraded, .partialOutage: return Palette.orange
        case .majorOutage: return Palette.red
        case .maintenance: return Palette.blue
        case .unknown: return Palette.track
        }
    }

    private func impactColor(_ impact: String) -> Color {
        switch impact {
        case "critical": return Palette.red
        case "minor": return Palette.yellow
        case "maintenance": return Palette.blue
        default: return Palette.orange   // "major" and anything else
        }
    }

    /// Capitalized incident status plus how long ago it started, e.g.
    /// "Monitoring · started 22m ago".
    private func incidentMeta(_ incident: StatusInfo.Incident) -> String {
        let status = incident.status.prefix(1).uppercased() + incident.status.dropFirst()
        guard let started = incident.startedAt else { return status }
        return "\(status) · started \(compactDuration(since: started)) ago"
    }

    /// Compact "since" duration: "45s", "22m", "1h 12m", "3d".
    private func compactDuration(since date: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 {
            let h = secs / 3600, m = (secs % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(secs / 86400)d"
    }

    /// Relative freshness for the footer: "just now", "5m ago", "2h ago".
    private func relativeUpdated(_ date: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    // MARK: Primary toggles

    private var primaryToggles: some View {
        VStack(spacing: 0) {
            toggleRow("Enable presence", presenceBinding, divider: false)
            toggleRow("Launch at login", launchBinding, divider: true)
        }
    }

    private var presenceBinding: Binding<Bool> {
        Binding(get: { settings.presenceEnabled }, set: { controller.setEnabled($0) })
    }

    private var launchBinding: Binding<Bool> {
        Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })
    }

    private func toggleRow(_ title: String, _ isOn: Binding<Bool>, size: CGFloat = 13, divider: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: size))
            Spacer()
            ToggleSwitch(isOn: isOn)
        }
        .padding(.vertical, size < 13 ? 5 : 6)
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(.black.opacity(0.05)).frame(height: 0.5) }
        }
    }

    // MARK: Advanced (collapsible)

    private var advancedSections: some View {
        VStack(spacing: 7) {
            collapsible(title: "Display & menu bar", summary: displaySummary, expanded: $expandDisplay) {
                VStack(spacing: 0) {
                    toggleRow("Show project", $settings.showProject, size: 12.5, divider: false)
                    toggleRow("Show model", $settings.showModel, size: 12.5, divider: true)
                    toggleRow("Show tokens", $settings.showTokens, size: 12.5, divider: true)
                    toggleRow("Show status in menu bar", $settings.showMenuBarStatus, size: 12.5, divider: true)
                    toggleRow("Show usage in menu bar", $settings.showUsageInMenuBar, size: 12.5, divider: true)
                }
                .padding(.horizontal, 11).padding(.top, 3).padding(.bottom, 8)
            }

            collapsible(title: "Activity & idle", summary: activitySummary, expanded: $expandActivity) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Activity type").font(.system(size: 12.5))
                        Spacer()
                        Button(action: cycleActivity) {
                            HStack(spacing: 6) {
                                Text(activityLabel).font(.system(size: 12.5))
                                VStack(spacing: 1) {
                                    Image(systemName: "chevron.up")
                                    Image(systemName: "chevron.down")
                                }
                                .font(.system(size: 6, weight: .semibold))
                                .foregroundStyle(Palette.secondary.opacity(0.45))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.track.opacity(0.1)))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.black.opacity(0.12), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    idleSlider
                }
                .padding(.horizontal, 11).padding(.top, 8).padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func collapsible<Content: View>(
        title: String, summary: String, expanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13))
                    Spacer()
                    Text(summary).font(.system(size: 12)).foregroundStyle(Palette.secondary.opacity(0.4))
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.secondary.opacity(0.35))
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.wrappedValue {
                content()
                    .overlay(alignment: .top) {
                        Rectangle().fill(.black.opacity(0.06)).frame(height: 0.5)
                    }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.black.opacity(0.07), lineWidth: 0.5))
    }

    private var displaySummary: String {
        let count = [
            settings.showProject, settings.showModel, settings.showTokens,
            settings.showMenuBarStatus, settings.showUsageInMenuBar
        ].filter { $0 }.count
        return "\(count) on"
    }

    private var activitySummary: String {
        "\(activityLabel) · \(idleMin) min"
    }

    private var activityLabel: String {
        SettingsStore.allowedActivityTypes.first { $0.value == settings.activityType }?.name ?? "Playing"
    }

    private func cycleActivity() {
        let types = SettingsStore.allowedActivityTypes
        let idx = types.firstIndex { $0.value == settings.activityType } ?? 0
        settings.activityType = types[(idx + 1) % types.count].value
    }

    // MARK: Idle slider

    private var idleMin: Int { Int(settings.idleWindowSeconds / 60) }

    private var idleFraction: CGFloat {
        let i = idleSteps.firstIndex(of: idleMin) ?? 0
        return CGFloat(i) / CGFloat(idleSteps.count - 1)
    }

    private func setIdle(fraction: CGFloat) {
        let clamped = max(0, min(1, fraction))
        let idx = Int((clamped * CGFloat(idleSteps.count - 1)).rounded())
        settings.idleWindowSeconds = Double(idleSteps[idx] * 60)
    }

    private var idleSlider: some View {
        VStack(spacing: 7) {
            HStack {
                Text("Idle window").font(.system(size: 12.5))
                Spacer()
                Text("\(idleMin) min")
                    .font(.system(size: 12.5)).monospacedDigit()
                    .foregroundStyle(Palette.secondary.opacity(0.6))
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track.opacity(0.2)).frame(height: 4)
                    Capsule().fill(Palette.blue).frame(width: max(w * idleFraction, 4), height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: 15, height: 15)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                        .offset(x: w * idleFraction - 7.5)
                }
                .frame(height: 15)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    setIdle(fraction: value.location.x / max(w, 1))
                })
            }
            .frame(height: 15)
            HStack {
                ForEach(idleSteps, id: \.self) { step in
                    Text("\(step)")
                        .font(.system(size: 9.5)).monospacedDigit()
                        .foregroundStyle(Palette.secondary.opacity(0.38))
                    if step != idleSteps.last { Spacer() }
                }
            }
        }
    }

    // MARK: Quit

    private var quitButton: some View {
        Button {
            controller.shutdown()
            NSApplication.shared.terminate(nil)
        } label: {
            HStack {
                Text("Quit agentcord").font(.system(size: 13))
                Spacer()
                Text("⌘Q").font(.system(size: 12)).foregroundStyle(Palette.secondary.opacity(0.4))
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.65)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.black.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
    }
}

// MARK: - Design primitives

/// Fixed light palette pulled from the popover design spec.
private enum Palette {
    static let text = Color(.sRGB, red: 0.114, green: 0.114, blue: 0.122)
    static let secondary = Color(.sRGB, red: 0.235, green: 0.235, blue: 0.263)
    static let blue = Color(.sRGB, red: 0.0, green: 0.478, blue: 1.0)
    static let green = Color(.sRGB, red: 0.204, green: 0.78, blue: 0.349)
    static let greenText = Color(.sRGB, red: 0.114, green: 0.541, blue: 0.227)
    static let track = Color(.sRGB, red: 0.471, green: 0.471, blue: 0.502)
    static let discord = Color(.sRGB, red: 0.345, green: 0.396, blue: 0.949)
    static let yellow = Color(.sRGB, red: 0.9, green: 0.7, blue: 0.0)
    static let orange = Color(.sRGB, red: 1.0, green: 0.584, blue: 0.0)
    static let orangeText = Color(.sRGB, red: 0.761, green: 0.4, blue: 0.039)
    static let red = Color(.sRGB, red: 1.0, green: 0.231, blue: 0.188)
    static let redText = Color(.sRGB, red: 0.753, green: 0.153, blue: 0.122)
    static let blueText = Color(.sRGB, red: 0.0, green: 0.341, blue: 0.714)
}

/// iOS-style toggle switch matching the design (28×17, green when on).
struct ToggleSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Palette.green : Palette.track.opacity(0.24))
            .frame(width: 28, height: 17)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 0.75, y: 0.5)
                    .padding(.horizontal, 1.5)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { isOn.toggle() }
            }
    }
}

/// The session's status dot — a steady green with an expanding pulse ring while
/// active, or a quiet gray when there's no live session / presence is off.
struct SessionDot: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(active ? Palette.green : Palette.track.opacity(0.7))
            .frame(width: 6, height: 6)
            .overlay {
                if active {
                    Circle()
                        .stroke(Palette.green, lineWidth: 2)
                        .scaleEffect(pulse ? 2.4 : 1)
                        .opacity(pulse ? 0 : 0.5)
                }
            }
            .onAppear {
                guard active else { return }
                withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
    }
}
