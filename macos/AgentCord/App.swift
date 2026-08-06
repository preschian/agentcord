//
//  App.swift
//  AgentCord
//
//  Menu bar entry point. No Dock icon (LSUIElement / accessory policy).
//

import SwiftUI
import AppKit
import Combine

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
    let cursorUsage = CursorUsage()
    let codexUsage = CodexUsage()
    let grokUsage = GrokUsage()
    let providerStatus = ProviderStatusHub()
    let sleepGuard = SleepGuard()
    lazy var controller = PresenceController(settings: settings)

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private lazy var connectedIcon = Self.icon(connected: true)
    private lazy var disconnectedIcon = Self.icon(connected: false)
    private var lastConnected: Bool?
    private var lastStatusTitle = NSAttributedString()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and suspenders: ensure no Dock icon even without LSUIElement.
        NSApp.setActivationPolicy(.accessory)
        controller.start()
        usage.start()
        cursorUsage.start()
        codexUsage.start()
        grokUsage.start()
        // Provider status has no background poller — it's popover-only UI, so
        // it fetches on popover open (see togglePopover) with a cached snapshot.

        // Keep the Mac awake whenever "Prevent sleep" is on, and follow the
        // toggle thereafter. `setEnabled` is idempotent, so the initial apply
        // plus every published change is safe.
        sleepGuard.setEnabled(settings.preventSleep)
        settings.$preventSleep
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.sleepGuard.setEnabled(enabled) }
            .store(in: &cancellables)

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
            .environmentObject(cursorUsage)
            .environmentObject(codexUsage)
            .environmentObject(controller.codexSession)
            .environmentObject(controller.cursorSession)
            .environmentObject(grokUsage)
            .environmentObject(controller.grokSession)
            .environmentObject(controller.museSession)
            .environmentObject(providerStatus)
        // Size the popover ourselves instead of using `.preferredContentSize`.
        // That automatic path animates the resize, so expanding/collapsing the
        // Settings section made the popover wobble. Pushing the size through a
        // zero-duration animation context makes it snap instantly instead.
        let host = SizingHostingController(rootView: content)
        host.fixedWidth = PopoverLayout.width
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
            // Pull fresh usage numbers and provider status as the popover
            // opens so they're current.
            usage.refresh()
            cursorUsage.refresh()
            codexUsage.refresh()
            grokUsage.refresh()
            providerStatus.refresh()
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

        if settings.showMenuBarStatus, let info = controller.currentSession {
            title.append(NSAttributedString(
                string: Self.statusText(for: info, settings: settings),
                attributes: [.font: font]
            ))
        }

        if settings.showUsageInMenuBar {
            Self.appendMultiAgentUsage(
                to: title,
                font: font,
                settings: settings,
                claudeUsage: usage.current,
                cursorUsage: cursorUsage.current,
                codexUsage: codexUsage.current,
                grokUsage: grokUsage.current
            )
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

        if settings.showTokens {
            if info.agent == .muse, (info.inputTokens > 0 || info.outputTokens > 0) {
                parts.append("\(PresenceController.formatTokens(info.inputTokens)) in · \(PresenceController.formatTokens(info.outputTokens)) out")
            } else if info.totalTokens > 0 {
                parts.append("\(PresenceController.formatTokens(info.totalTokens)) tokens")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Appends usage for every enabled agent that has data, when
    /// "Show usage in menu bar" is on.
    static func appendMultiAgentUsage(
        to title: NSMutableAttributedString,
        font: NSFont,
        settings: SettingsStore,
        claudeUsage: UsageInfo?,
        cursorUsage: CursorUsageInfo?,
        codexUsage: CodexUsageInfo?,
        grokUsage: GrokUsageInfo?
    ) {
        let claudeSnapshot = settings.isAgentEnabled(.claude) ? claudeUsage : nil
        let cursorSnapshot = settings.isAgentEnabled(.cursor) ? cursorUsage : nil
        let codexSnapshot = settings.isAgentEnabled(.codex) ? codexUsage : nil
        let grokSnapshot = settings.isAgentEnabled(.grok) ? grokUsage : nil

        let contributing =
            (claudeSnapshot != nil ? 1 : 0)
            + (cursorSnapshot != nil ? 1 : 0)
            + (codexSnapshot != nil ? 1 : 0)
            + (grokSnapshot != nil ? 1 : 0)
        // When more than one agent contributes, drop the "5h" tag and label
        // each percentage with the agent name so the title stays scannable.
        let multi = contributing > 1

        if let snapshot = claudeSnapshot {
            Self.appendMenuBarSegment(to: title, font: font) {
                Self.appendClaudeUsage(snapshot, to: $0, font: font, labeled: multi)
            }
        }
        if let snapshot = codexSnapshot {
            Self.appendMenuBarSegment(to: title, font: font) {
                Self.appendCodexUsage(snapshot, to: $0, font: font, labeled: multi)
            }
        }
        if let snapshot = cursorSnapshot {
            Self.appendMenuBarSegment(to: title, font: font) {
                Self.appendCursorUsage(snapshot, to: $0, font: font, labeled: multi)
            }
        }
        if let snapshot = grokSnapshot {
            Self.appendMenuBarSegment(to: title, font: font) {
                Self.appendGrokUsage(snapshot, to: $0, font: font, labeled: multi)
            }
        }
    }

    private static func appendMenuBarSegment(
        to title: NSMutableAttributedString,
        font: NSFont,
        append: (NSMutableAttributedString) -> Void
    ) {
        if title.length > 0 {
            title.append(NSAttributedString(
                string: " · ",
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            ))
        }
        append(title)
    }

    /// Appends a compact Claude readout. Alone: "5h NN% (2h 17m)". Shared
    /// with other agents: "Claude NN%" (no "5h" — the label already disambiguates).
    static func appendClaudeUsage(
        _ usage: UsageInfo, to title: NSMutableAttributedString, font: NSFont, labeled: Bool
    ) {
        let window = usage.fiveHour
        let color = severityNSColor(window.severity)
        let text = labeled ? "Claude \(window.percent)%" : "5h \(window.percent)%"
        title.append(NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        ))
        // Only attach the reset countdown when Claude is alone — with multi-agent
        // the title gets crowded quickly.
        if !labeled, let reset = MenuContentView.formatResetDuration(window) {
            title.append(NSAttributedString(
                string: " (\(reset))",
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            ))
        }
    }

    /// Appends a compact Cursor readout: always "Cursor NN%" (no 5h tag).
    /// Reset date only when Cursor is the sole usage segment.
    static func appendCursorUsage(
        _ usage: CursorUsageInfo, to title: NSMutableAttributedString, font: NSFont, labeled: Bool
    ) {
        let window = usage.included
        let color = severityNSColor(window.severity)
        title.append(NSAttributedString(
            string: "Cursor \(window.percent)%",
            attributes: [.font: font, .foregroundColor: color]
        ))
        // Alone in the menu bar: attach billing-cycle reset. Multi-agent: skip.
        if !labeled, let reset = MenuContentView.formatCursorResetDuration(window) {
            title.append(NSAttributedString(
                string: " (\(reset))",
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            ))
        }
    }

    /// Appends a compact Codex readout. Alone: "Codex 5h NN%" (or monthly).
    /// Shared: "Codex NN%".
    static func appendCodexUsage(
        _ usage: CodexUsageInfo, to title: NSMutableAttributedString, font: NSFont, labeled: Bool
    ) {
        let window = usage.primary
        let color = severityNSColor(window.severity)
        let text: String
        if labeled {
            text = "Codex \(window.percent)%"
        } else if usage.primaryLabel.lowercased().contains("5-hour") {
            text = "Codex 5h \(window.percent)%"
        } else {
            text = "Codex \(window.percent)%"
        }
        title.append(NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        ))
        if !labeled, let reset = MenuContentView.formatResetDuration(window) {
            title.append(NSAttributedString(
                string: " (\(reset))",
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            ))
        }
    }

    /// Appends a compact Grok weekly-credits readout. Alone: "Grok NN% (reset)".
    /// Shared: "Grok NN%".
    static func appendGrokUsage(
        _ usage: GrokUsageInfo, to title: NSMutableAttributedString, font: NSFont, labeled: Bool
    ) {
        let window = usage.weekly
        let color = severityNSColor(window.severity)
        title.append(NSAttributedString(
            string: "Grok \(window.percent)%",
            attributes: [.font: font, .foregroundColor: color]
        ))
        if !labeled, let reset = MenuContentView.formatResetDuration(window) {
            title.append(NSAttributedString(
                string: " (\(reset))",
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            ))
        }
    }

    private static func severityNSColor(_ severity: String) -> NSColor {
        switch severity.lowercased() {
        case "normal": return .labelColor
        case "warning", "warn", "low": return .systemOrange
        default: return .systemRed
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

// MARK: - Popover layout

private enum PopoverLayout {
    static let width: CGFloat = 300
    static let padding: CGFloat = 13
}

// MARK: - Popover sizing

/// Hosting controller that reports its content's fitting size whenever it lays
/// out, so the popover can be resized manually and instantly. Avoids the
/// animated resize that `NSHostingController.sizingOptions = .preferredContentSize`
/// triggers, which made the popover wobble when the Settings section toggled.
final class SizingHostingController<Content: View>: NSHostingController<Content> {
    /// When set, popover width stays fixed while height follows content.
    var fixedWidth: CGFloat?
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
        let width = (fixedWidth ?? raw.width).rounded(.up)
        let size = NSSize(width: width, height: raw.height.rounded(.up))
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
    @EnvironmentObject private var cursorUsage: CursorUsage
    @EnvironmentObject private var codexUsage: CodexUsage
    @EnvironmentObject private var codexSession: CodexSession
    @EnvironmentObject private var cursorSession: CursorSession
    @EnvironmentObject private var grokUsage: GrokUsage
    @EnvironmentObject private var grokSession: GrokSession
    @EnvironmentObject private var museSession: MuseSession
    @EnvironmentObject private var providerStatus: ProviderStatusHub

    @State private var showSettings = false
    @State private var expandDisplay = false
    @State private var expandActivity = false
    /// Which agent's row is expanded in the accordion. Nil collapses them all.
    @State private var expandedAgent: AgentKind?
    /// Agents whose account email is currently shown in the clear. Masked by
    /// default so a peek at the menu bar doesn't leak the address.
    @State private var revealedAccountEmails: Set<AgentKind> = []

    private let idleSteps = [5, 10, 15, 20, 25, 30]

    /// Agents currently listed in the popover.
    private var visibleAgents: [AgentKind] {
        let enabled = settings.enabledAgents
        return enabled.isEmpty ? [.claude] : enabled
    }

    private func isAgentLinked(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claude: return true
        case .cursor: return cursorUsage.isAuthenticated || cursorSession.isInstalled
        // A fresh cache is still useful while the short-lived app-server probe
        // starts (or if Codex is temporarily unavailable), so do not hide it
        // behind the authentication flag.
        case .codex:
            return codexUsage.isAuthenticated || codexUsage.current != nil || codexSession.isInstalled
        case .grok: return grokUsage.isAuthenticated || grokSession.isAuthenticated
        case .muse: return museSession.isInstalled
        }
    }

    /// The live session for one agent, if it has one.
    private func session(for agent: AgentKind) -> SessionInfo? {
        switch agent {
        case .claude: return controller.session.current
        case .cursor: return cursorSession.current
        case .codex: return codexSession.current
        case .grok: return grokSession.current
        case .muse: return museSession.current
        }
    }

    private var activeAgentCount: Int {
        visibleAgents.filter { isAgentLinked($0) && session(for: $0) != nil }.count
    }

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
        .padding(PopoverLayout.padding)
        .frame(width: PopoverLayout.width, alignment: .top)
        .clipped()
        .foregroundStyle(Palette.text)
        .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.32), value: showSettings)
        .onAppear {
            // Open the last-selected agent so the popover doesn't come up as a
            // list of closed rows. Only on first appearance — after that the
            // user's collapse choice stands.
            if expandedAgent == nil, visibleAgents.contains(settings.selectedAgent) {
                expandedAgent = settings.selectedAgent
            }
        }
    }

    // MARK: Screens

    private var mainScreen: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            // With a single agent the summary would just repeat that agent's
            // own rows, so it only earns its space once there are several.
            if settings.unifiedUsage && visibleAgents.count > 1 {
                unifiedUsageCard
            }
            agentListCard
            settingsNavRow
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, -PopoverLayout.padding)
            quitButton
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var settingsScreen: some View {
        VStack(alignment: .leading, spacing: 11) {
            settingsHeader
            agentsSettingsSection
            primaryToggles
            advancedSections
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
                .lineLimit(1)
            Spacer(minLength: 6)
            statusPill
        }
        .frame(maxWidth: .infinity)
    }

    private var statusPill: some View {
        // Multi-agent design: how many enabled agents are running right now.
        // The connected count is already implicit in the list below, so the pill
        // only carries what's live. Falls back to the Discord connection state
        // when only one agent is on.
        let total = max(visibleAgents.count, 1)
        let accent: Color
        let textColor: Color
        let label: String
        if total > 1 {
            let active = activeAgentCount
            accent = active > 0 ? Palette.green : Palette.track
            textColor = active > 0 ? Palette.greenText : Palette.secondary.opacity(0.7)
            label = active > 0 ? "\(active) active" : "Idle"
        } else if !settings.presenceEnabled {
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
            Circle().fill(accent).frame(width: 6, height: 6).fixedSize()
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textColor)
                // "N active · M connected" is the widest label the pill carries.
                // Without this the header squeezes it and it wraps to two lines.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 2)
        .background(Capsule().fill(accent.opacity(0.12)))
        .overlay(Capsule().stroke(accent.opacity(0.28), lineWidth: 0.5))
    }

    // MARK: Agent list (accordion)

    /// Every enabled agent as one row. Tapping a row expands it in place to show
    /// that agent's plan, session, usage and provider status — so several agents
    /// stay visible at once instead of one at a time behind a tab switcher.
    private var agentListCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(visibleAgents.enumerated()), id: \.element.id) { index, agent in
                agentRow(agent, divider: index > 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.black.opacity(0.06), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func agentRow(_ agent: AgentKind, divider: Bool) -> some View {
        let linked = isAgentLinked(agent)
        let session = session(for: agent)
        let expanded = expandedAgent == agent

        return VStack(spacing: 0) {
            Button {
                toggleExpanded(agent)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(linked ? Palette.text : Palette.secondary.opacity(0.5))
                            .lineLimit(1)
                        Text(rowSubtitle(agent, linked: linked, session: session))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.secondary.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    agentRowTrailing(linked: linked, session: session)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.secondary.opacity(0.3))
                        // Pin the slot: chevron.down and chevron.right differ in
                        // width, so without it the row shifts as it toggles.
                        .frame(width: 9, alignment: .center)
                }
                .padding(.horizontal, 11).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(expanded ? Palette.track.opacity(0.04) : Color.clear)

            if expanded {
                agentDetail(agent, linked: linked, session: session)
            }
        }
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(.black.opacity(0.06)).frame(height: 0.5) }
        }
    }

    /// Right side of a collapsed row: a live timer, an idle marker, or a
    /// call to action when the agent has no linked account.
    @ViewBuilder
    private func agentRowTrailing(linked: Bool, session: SessionInfo?) -> some View {
        if let session {
            HStack(spacing: 5) {
                SessionDot(active: true)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedClock(session, now: context.date))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                }
            }
            .fixedSize()
        } else if linked {
            Text("idle")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary.opacity(0.45))
                .fixedSize()
        } else {
            Text("Connect")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.blue)
                .fixedSize()
        }
    }

    private func rowSubtitle(_ agent: AgentKind, linked: Bool, session: SessionInfo?) -> String {
        guard linked else { return "Not connected" }
        guard let session else { return "Connected" }
        return settings.showProject ? session.projectName : "Project hidden"
    }

    private func toggleExpanded(_ agent: AgentKind) {
        if expandedAgent == agent {
            expandedAgent = nil
            revealedAccountEmails.remove(agent)
        } else {
            if let previouslyExpanded = expandedAgent {
                revealedAccountEmails.remove(previouslyExpanded)
            }
            expandedAgent = agent
            // Keep the persisted selection in step so the same agent reopens
            // expanded the next time the popover is shown.
            settings.selectedAgent = agent
        }
    }

    // MARK: Agent detail

    @ViewBuilder
    private func agentDetail(_ agent: AgentKind, linked: Bool, session: SessionInfo?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if linked {
                accountRow(agent)
                sessionSection(agent, session: session)
                usageRows(for: agent)
                statusSection(agent)
            } else {
                connectPrompt(agent)
            }
        }
        .padding(.horizontal, 11).padding(.top, 2).padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.track.opacity(0.04))
        .overlay(alignment: .top) {
            Rectangle().fill(.black.opacity(0.05)).frame(height: 0.5)
        }
    }

    /// The signed-in account plus the plan tag, when the usage API reported one.
    /// Email starts masked; tap to reveal (and tap again to hide).
    private func accountRow(_ agent: AgentKind) -> some View {
        let email = accountEmail(for: agent)
        let revealed = revealedAccountEmails.contains(agent)
        let label: String = {
            guard let email else { return agent.providerName }
            return revealed ? email : maskedEmail(email)
        }()

        return HStack(spacing: 8) {
            if email != nil {
                Button {
                    if revealed {
                        revealedAccountEmails.remove(agent)
                    } else {
                        revealedAccountEmails.insert(agent)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(label)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.secondary.opacity(0.45))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(revealed ? "Hide email" : "Show email")
            } else {
                Text(label)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let plan = planName(for: agent), !plan.isEmpty {
                Text(plan.capitalized)
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.track.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.black.opacity(0.08), lineWidth: 0.5))
                    .fixedSize()
            }
        }
        .padding(.top, 9)
    }

    /// Who the agent is signed in as. Nil until the provider surfaces it —
    /// each one reports on a different schedule.
    private func accountEmail(for agent: AgentKind) -> String? {
        switch agent {
        case .claude: return usage.accountEmail
        case .cursor: return cursorUsage.accountEmail
        case .codex: return codexUsage.accountEmail
        case .grok: return grokUsage.accountEmail
        case .muse: return nil
        }
    }

    /// `pres@example.com` → `p•••@e••••••.com`. Keeps the shape readable while
    /// hiding the address until the user taps to reveal.
    private func maskedEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else {
            return String(repeating: "•", count: max(email.count, 4))
        }
        let local = String(email[..<at])
        let domain = String(email[email.index(after: at)...])

        let maskedLocal: String = {
            guard let first = local.first else { return "•••" }
            return String(first) + String(repeating: "•", count: max(3, local.count - 1))
        }()

        let maskedDomain: String = {
            guard let dot = domain.lastIndex(of: ".") else {
                return String(repeating: "•", count: max(3, domain.count))
            }
            let name = domain[..<dot]
            let tld = domain[dot...]
            guard let first = name.first else { return "••" + tld }
            return String(first) + String(repeating: "•", count: max(2, name.count - 1)) + tld
        }()

        return maskedLocal + "@" + maskedDomain
    }

    private func planName(for agent: AgentKind) -> String? {
        switch agent {
        case .claude: return usage.current?.planName
        case .cursor: return cursorUsage.current?.planName
        case .codex: return codexUsage.current?.planType
        case .grok: return nil
        case .muse: return nil
        }
    }

    /// Project, model/tokens and what Discord is currently broadcasting.
    private func sessionSection(_ agent: AgentKind, session: SessionInfo?) -> some View {
        let active = session != nil
        let sharing = active && settings.presenceEnabled && controller.activeAgent == agent
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary.opacity(0.55))
                Text(projectText(session))
                    .font(.system(size: 12.5, weight: .semibold))
                    .italic(!active || !settings.showProject)
                    .foregroundStyle(active ? Palette.text : Palette.secondary.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(active ? "active" : "idle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary.opacity(0.5))
            }
            Text(metaLine(session))
                .font(.system(size: 11.5))
                .italic(metaBits(session).isEmpty)
                .foregroundStyle(Palette.secondary.opacity(metaBits(session).isEmpty ? 0.4 : 0.6))
                .padding(.leading, 20)
            HStack(spacing: 6) {
                Circle()
                    .fill(sharing ? Palette.discord : Palette.track.opacity(0.6))
                    .frame(width: 5, height: 5)
                Text(broadcastText(hasSession: active, presenceOn: settings.presenceEnabled, sharing: sharing))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.leading, 20)
        }
        .padding(.top, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(.black.opacity(0.06)).frame(height: 0.5)
        }
    }

    /// Detail-pane empty state when the agent has no linked account.
    private func connectPrompt(_ agent: AgentKind) -> some View {
        VStack(spacing: 9) {
            Text("Link your \(agent.providerName) account to track sessions, usage and status here.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { openConnectHelp(for: agent) }) {
                Text("Connect \(agent.displayName)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.blue))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12).padding(.bottom, 2).padding(.horizontal, 8)
    }

    private func openConnectHelp(for agent: AgentKind) {
        let urlString: String
        switch agent {
        case .claude: urlString = "https://docs.anthropic.com/en/docs/claude-code"
        case .cursor: urlString = "https://cursor.com"
        case .codex: urlString = "https://developers.openai.com/codex/auth"
        case .grok: urlString = "https://grok.x.ai"
        case .muse: urlString = "https://www.meta.ai"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
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
                Text(settingsSummary)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsSummary: String {
        let n = settings.enabledAgents.count
        if n == 0 { return "No agents" }
        return "\(n) of \(AgentKind.allCases.count) on"
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
        if settings.showTokens {
            if session.agent == .muse, (session.inputTokens > 0 || session.outputTokens > 0) {
                bits.append("\(PresenceController.formatTokens(session.inputTokens)) in · \(PresenceController.formatTokens(session.outputTokens)) out")
                bits.append("\(PresenceController.formatTokens(session.totalTokens)) total")
            } else if session.totalTokens > 0 {
                bits.append("\(PresenceController.formatTokens(session.totalTokens)) tokens")
            }
        }
        return bits
    }

    private func metaLine(_ session: SessionInfo?) -> String {
        let bits = metaBits(session)
        if bits.isEmpty { return session == nil ? "Waiting for a session" : "Model & tokens hidden" }
        return bits.joined(separator: "  ·  ")
    }

    private func broadcastText(hasSession: Bool, presenceOn: Bool, sharing: Bool) -> String {
        if !presenceOn { return "Presence is off" }
        if sharing { return "Sharing to Discord as your status" }
        if hasSession, let active = controller.activeAgent {
            return "Active — Discord is sharing \(active.displayName)"
        }
        return "Waiting for a session"
    }

    // MARK: Unified usage

    /// Top-of-popover summary: one headline bar per connected agent, so the
    /// tightest limit across every agent is visible without expanding a row.
    private var unifiedUsageCard: some View {
        let agents = visibleAgents.filter { isAgentLinked($0) }
        let entries = agents.map { (agent: $0, entry: unifiedUsageEntry(for: $0)) }
        return VStack(alignment: .leading, spacing: 9) {
            Text("UNIFIED USAGE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Palette.secondary.opacity(0.55))
            if entries.isEmpty {
                Text("No connected agents")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.secondary.opacity(0.45))
                    .italic()
            } else {
                ForEach(entries, id: \.agent.id) { item in
                    // Dim the bar for agents that aren't running right now, so
                    // the live ones read first.
                    let live = session(for: item.agent) != nil
                    usageRow(
                        item.entry.label,
                        item.entry.window,
                        accent: Palette.blue.opacity(live ? 1 : 0.55)
                    )
                }
            }
        }
        .padding(.vertical, 11).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.black.opacity(0.06), lineWidth: 0.5))
    }

    /// Each agent's primary window, so the unified card stays one row per agent.
    private func unifiedUsageEntry(for agent: AgentKind) -> (label: String, window: UsageInfo.Window?) {
        switch agent {
        case .claude:
            return (agent.displayName, usage.current?.fiveHour)
        case .cursor:
            let mapped = cursorUsage.current.map {
                UsageInfo.Window(
                    percent: $0.included.percent,
                    severity: $0.included.severity,
                    resetsAt: $0.included.resetsAt
                )
            }
            return (agent.displayName, mapped)
        case .codex:
            return (agent.displayName, codexUsage.current?.primary)
        case .grok:
            return (agent.displayName, grokUsage.current?.weekly)
        case .muse:
            return (agent.displayName, nil)
        }
    }

    // MARK: Per-agent usage rows

    /// Every usage window one agent reports, rendered bare so an expanded
    /// accordion row can host them without a nested card.
    @ViewBuilder
    private func usageRows(for agent: AgentKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch agent {
            case .claude: claudeUsageRows
            case .cursor: cursorUsageRows
            case .codex: codexUsageRows
            case .grok: grokUsageRows
            case .muse: museUsageRows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var claudeUsageRows: some View {
        if usage.current == nil {
            usagePlaceholder("Waiting for Claude usage…")
        } else {
            // Severity colors (blue / orange / red) rather than brand accents —
            // an approaching limit should read the same for every agent.
            usageRow("Current session", usage.current?.fiveHour)
            usageRow("All models", usage.current?.weekly)
            ForEach(usage.current?.modelWeekly ?? [], id: \.modelName) { scoped in
                usageRow(scoped.modelName, scoped.window)
            }
        }
        if let error = controller.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(Palette.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var cursorUsageRows: some View {
        if let info = cursorUsage.current {
            cursorUsageRow("Included usage", info.included)
            if let auto = info.auto { cursorUsageRow("Auto + Composer", auto) }
            if let api = info.api { cursorUsageRow("API models", api) }
            if let onDemand = info.onDemand { cursorUsageRow("On-demand", onDemand) }
        } else {
            usagePlaceholder("Waiting for Cursor usage…")
        }
    }

    private func cursorUsageRow(_ label: String, _ window: CursorUsageInfo.Window) -> some View {
        // Percent + reset only — no dollar amounts.
        let mapped = UsageInfo.Window(
            percent: window.percent,
            severity: window.severity,
            resetsAt: window.resetsAt
        )
        return usageRow(label, mapped)
    }

    @ViewBuilder
    private var codexUsageRows: some View {
        if let info = codexUsage.current {
            usageRow(info.primaryLabel, info.primary)
            if let secondary = info.secondary {
                usageRow(info.secondaryLabel ?? "Secondary limit", secondary)
            }
            ForEach(info.additionalWindows) { scoped in
                usageRow(scoped.label, scoped.window)
            }
        } else {
            usagePlaceholder("Waiting for Codex usage…")
        }
    }

    /// Weekly SuperGrok / CLI credits from `/v1/billing?format=credits`.
    @ViewBuilder
    private var grokUsageRows: some View {
        if let info = grokUsage.current {
            usageRow("Weekly credits", info.weekly)
            if let onDemand = info.onDemand { usageRow("On-demand", onDemand) }
        } else if grokUsage.isAuthenticated {
            usagePlaceholder("Waiting for Grok usage…")
        } else {
            usagePlaceholder("Not signed in — run grok login")
        }
    }

    @ViewBuilder
    private var museUsageRows: some View {
        usagePlaceholder("Muse usage coming soon")
    }

    private func usagePlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.secondary.opacity(0.45))
            .italic()
    }

    private func agentAccent(_ agent: AgentKind) -> Color {
        let c = agent.accentHex
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    private func usageRow(
        _ label: String, _ window: UsageInfo.Window?,
        accent: Color? = nil
    ) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                // Countdown ticks while the popover stays open; without the
                // TimelineView it would only update when the usage data polls.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(usageDetail(window, now: context.date))
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track.opacity(0.16))
                    Capsule()
                        .fill(accent ?? severityColor(window))
                        .frame(width: geo.size.width * barFraction(window))
                }
            }
            .frame(height: 6)
        }
    }

    private func usageDetail(_ window: UsageInfo.Window?, now: Date) -> String {
        guard let window else { return "—" }
        if let reset = Self.formatResetDuration(window, now: now) {
            return reset == "now"
                ? "\(window.percent)% · resets now"
                : "\(window.percent)% · resets in \(reset)"
        }
        return "\(window.percent)%"
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

    /// Formats the time remaining until a window resets, e.g. "6d 22h" or
    /// "2h 17m". Returns nil when there's no reset time and "now" once due.
    static func formatResetDuration(_ window: UsageInfo.Window, now: Date = Date()) -> String? {
        formatResetDuration(until: window.resetsAt, now: now)
    }

    static func formatCursorResetDuration(_ window: CursorUsageInfo.Window) -> String? {
        formatResetDuration(until: window.resetsAt, now: Date())
    }

    private static func formatResetDuration(until reset: Date?, now: Date) -> String? {
        guard let reset else { return nil }
        let remaining = reset.timeIntervalSince(now)
        let totalMinutes = Int(remaining / 60)
        guard totalMinutes > 0 else {
            return remaining > 0 ? "<1m" : "now"
        }
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes / 60 % 24
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    // MARK: Provider status

    /// One line at the foot of an expanded agent: overall provider health, any
    /// active incident, and a link out to the full status page. Hidden until
    /// the first successful fetch so a brief offline moment shows nothing
    /// rather than a broken row.
    @ViewBuilder
    private func statusSection(_ agent: AgentKind) -> some View {
        if let status = providerStatus.info(for: agent) {
            VStack(alignment: .leading, spacing: 5) {
                Link(destination: agent.statusPageURL) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusPillStyle(status.level).dot)
                            .frame(width: 6, height: 6)
                        Text("\(agent.statusProviderLabel) · \(status.summaryLabel)")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondary.opacity(0.7))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        HStack(spacing: 3) {
                            Text("Status")
                                .font(.system(size: 11))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(Palette.secondary.opacity(0.4))
                        .fixedSize()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Only the newest incident — the full list lives on the status page.
                if let incident = status.incidents.first {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(incident.name)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(incidentMeta(incident))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Palette.secondary.opacity(0.5))
                    }
                    .padding(.leading, 14)
                }
            }
            .padding(.top, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(.black.opacity(0.06)).frame(height: 0.5)
            }
        }
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

    // MARK: Agents settings

    private var agentsSettingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AGENTS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Palette.secondary.opacity(0.55))
                .padding(.horizontal, 2)

            VStack(spacing: 0) {
                ForEach(Array(AgentKind.allCases.enumerated()), id: \.element.id) { index, agent in
                    agentToggleRow(agent, divider: index > 0)
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.black.opacity(0.06), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func agentToggleRow(_ agent: AgentKind, divider: Bool) -> some View {
        let linked = isAgentLinked(agent)
        let sub = agent.providerName + (linked ? " · connected" : " · not connected")
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(agentAccent(agent))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.displayName).font(.system(size: 13))
                    Text(sub)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.secondary.opacity(0.45))
                }
            }
            Spacer()
            ToggleSwitch(isOn: settings.bindingForAgent(agent))
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(.black.opacity(0.05)).frame(height: 0.5) }
        }
    }

    // MARK: Primary toggles

    private var primaryToggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PRESENCE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Palette.secondary.opacity(0.55))
                .padding(.horizontal, 2)

            VStack(spacing: 0) {
                toggleRow("Enable presence", presenceBinding, divider: false)
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.black.opacity(0.06), lineWidth: 0.5))

            Text("GENERAL")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Palette.secondary.opacity(0.55))
                .padding(.horizontal, 2)
                .padding(.top, 5)

            VStack(spacing: 0) {
                toggleRow("Launch at login", launchBinding, divider: false)
                toggleRow("Prevent sleep", $settings.preventSleep, divider: true)
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.black.opacity(0.06), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    toggleRow("Show unified usage", $settings.unifiedUsage, size: 12.5, divider: false)
                    toggleRow("Show project", $settings.showProject, size: 12.5, divider: true)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displaySummary: String {
        let count = [
            settings.unifiedUsage, settings.showProject, settings.showModel,
            settings.showTokens, settings.showMenuBarStatus, settings.showUsageInMenuBar
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
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.65)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.black.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
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
