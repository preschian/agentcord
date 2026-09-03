//
//  PresenceController.swift
//  AgentCord
//
//  Observes active Claude Code, Codex, Cursor, and Grok sessions, builds the Rich
//  Presence payload from the user's settings, debounces updates, and drives
//  DiscordIPC. Clears the presence when the session goes idle or the app quits.
//

import Foundation
import Combine
import AppKit

final class PresenceController: ObservableObject {

    @Published private(set) var discordState: DiscordIPC.State = .disconnected
    @Published private(set) var lastError: String?
    @Published private(set) var currentSession: SessionInfo?
    @Published private(set) var activeAgent: AgentKind?

    @Published private(set) var claudeTodayMs: Int64 = 0
    @Published private(set) var codexTodayMs: Int64 = 0
    @Published private(set) var cursorTodayMs: Int64 = 0
    @Published private(set) var grokTodayMs: Int64 = 0
    @Published private(set) var antigravityTodayMs: Int64 = 0
    @Published private(set) var opencodeTodayMs: Int64 = 0

    let session = ClaudeSession()
    let codexSession = CodexSession()
    let cursorSession = CursorSession()
    let grokSession = GrokSession()
    let antigravitySession = AntigravitySession()
    let opencodeSession = OpenCodeSession()
    let settings: SettingsStore

    private let ipc = DiscordIPC()
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    // Debounce / throttle bookkeeping.
    private var lastPayloadSignature: String?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastUpdateTime: Date = .distantPast
    private let minUpdateInterval: TimeInterval = 3

    init(settings: SettingsStore) {
        self.settings = settings

        ipc.onStateChange = { [weak self] newState in self?.discordState = newState }
        ipc.onError = { [weak self] message in self?.lastError = message }
        ipc.onReady = { [weak self] in self?.lastError = nil }

        session.$current
            .combineLatest(session.$todayMs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, today in
                self?.claudeTodayMs = today
                self?.selectActiveSession()
            }
            .store(in: &cancellables)

        codexSession.$current
            .combineLatest(codexSession.$todayMs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, today in
                self?.codexTodayMs = today
                self?.selectActiveSession()
            }
            .store(in: &cancellables)

        cursorSession.$current
            .combineLatest(cursorSession.$todayMs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, today in
                self?.cursorTodayMs = today
                self?.selectActiveSession()
            }
            .store(in: &cancellables)

        grokSession.$current
            .combineLatest(grokSession.$todayMs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, today in
                self?.grokTodayMs = today
                self?.selectActiveSession()
            }
            .store(in: &cancellables)

        antigravitySession.$current
            .combineLatest(antigravitySession.$todayMs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, today in
                self?.antigravityTodayMs = today
                self?.selectActiveSession()
            }
            .store(in: &cancellables)

        opencodeSession.$current
            .combineLatest(opencodeSession.$todayMs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, today in
                self?.opencodeTodayMs = today
                self?.selectActiveSession()
            }
            .store(in: &cancellables)

        // Display-affecting settings (toggles, DND, image keys) only need a
        // rebuild. Deferred to the next runloop tick so the new value is set.
        settings.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async { self?.handleSettingsChange() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.shutdown()
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        applyIdleWindow()
        syncMonitors()
        selectActiveSession()
        connectIfPossible()
    }

    func shutdown() {
        ipc.clearActivitySync()
        session.stop()
        codexSession.stop()
        cursorSession.stop()
        grokSession.stop()
        antigravitySession.stop()
        opencodeSession.stop()
        ipc.disconnect()
    }

    // MARK: User actions

    func setEnabled(_ enabled: Bool) {
        settings.presenceEnabled = enabled
        if enabled {
            connectIfPossible()
        } else {
            lastPayloadSignature = nil
            ipc.disconnect()
        }
    }

    /// Called when the user commits a new Application ID.
    func applyClientID() {
        guard settings.presenceEnabled else { return }
        ipc.disconnect()
        connectIfPossible()
    }

    private func connectIfPossible() {
        let id = settings.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.presenceEnabled, !id.isEmpty else { return }
        lastPayloadSignature = nil
        ipc.connect(clientID: id)
        rebuild()
    }

    private func applyIdleWindow() {
        let idle = SessionDuration.idleWindowSeconds
        session.activeWindowSeconds = idle
        codexSession.activeWindowSeconds = idle
        cursorSession.activeWindowSeconds = idle
        grokSession.activeWindowSeconds = idle
        antigravitySession.activeWindowSeconds = idle
        opencodeSession.activeWindowSeconds = idle
    }

    /// Only watch agents the user has enabled. Each scanner walks a large
    /// on-disk tree; leaving a disabled agent running is wasted I/O.
    private func syncMonitors() {
        if settings.agentClaudeEnabled { session.start() } else { session.stop() }
        if settings.agentCodexEnabled { codexSession.start() } else { codexSession.stop() }
        if settings.agentCursorEnabled { cursorSession.start() } else { cursorSession.stop() }
        if settings.agentGrokEnabled { grokSession.start() } else { grokSession.stop() }
        if settings.agentAntigravityEnabled { antigravitySession.start() } else { antigravitySession.stop() }
        if settings.agentOpencodeEnabled { opencodeSession.start() } else { opencodeSession.stop() }
    }

    private func handleSettingsChange() {
        applyIdleWindow()
        syncMonitors()
        selectActiveSession()
        rebuild()
    }

    private func selectActiveSession() {
        var candidates: [SessionInfo] = []
        if settings.agentClaudeEnabled, let claude = session.current { candidates.append(claude) }
        if settings.agentCodexEnabled, let codex = codexSession.current { candidates.append(codex) }
        if settings.agentCursorEnabled, let cursor = cursorSession.current { candidates.append(cursor) }
        if settings.agentGrokEnabled, let grok = grokSession.current { candidates.append(grok) }
        if settings.agentAntigravityEnabled, let antigravity = antigravitySession.current { candidates.append(antigravity) }
        if settings.agentOpencodeEnabled, let opencode = opencodeSession.current { candidates.append(opencode) }
        let selected = candidates.max { $0.lastModified < $1.lastModified }
        if currentSession != selected { currentSession = selected }
        let agent = selected?.agent
        if activeAgent != agent { activeAgent = agent }
        rebuild()
    }

    // MARK: Presence building

    private func rebuild() {
        guard settings.presenceEnabled else { return }

        guard let info = currentSession else {
            scheduleClear()
            return
        }
        scheduleUpdate(buildPresence(from: info))
    }

    private func buildPresence(from info: SessionInfo) -> RichPresence {
        // Match Windows: agent name as the bold title, model on the second
        // line, project + tokens combined on the third.
        let name = info.agent.displayName
        let details = settings.showModel ? info.model : nil

        var stateParts: [String] = []
        if settings.showProject {
            stateParts.append("Working on: \(info.projectName)")
        }
        if settings.showTokens, info.totalTokens > 0 {
            stateParts.append("\(Self.formatTokens(info.totalTokens)) tokens")
        }
        let state = stateParts.isEmpty ? nil : stateParts.joined(separator: " · ")

        let assets = Assets(
            large_image: Self.logoAsset(for: info.agent),
            large_text: "agentcord",
            small_image: settings.smallImageKey.isEmpty ? nil : settings.smallImageKey,
            small_text: "Active \(info.agent.displayName) session"
        )

        let type = SettingsStore.allowedActivityTypes.map(\.value).contains(settings.activityType)
            ? settings.activityType : 0

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return RichPresence(
            type: type,
            name: name,
            details: details,
            state: state,
                timestamps: Timestamps(
                    start: Self.presenceStartMs(
                        nowMs: nowMs,
                        claude: claudeTodayMs,
                        codex: codexTodayMs,
                        cursor: cursorTodayMs,
                        grok: grokTodayMs,
                        antigravity: antigravityTodayMs,
                        opencode: opencodeTodayMs
                    ),
                    end: nil
                ),
            assets: assets,
            buttons: [Self.repoButton]
        )
    }

    /// Discord art-asset key for the large image, one per agent.
    private static func logoAsset(for agent: AgentKind) -> String {
        switch agent {
        case .codex: return "logo-chatgpt"
        case .claude: return "logo-claude"
        case .cursor: return "logo-cursor"
        case .grok: return "logo-grok"
        case .antigravity: return "logo-antigravity"
        case .opencode: return "logo-opencode"
        }
    }

    private static let repoButton = PresenceButton(
        label: "AgentCord on GitHub",
        url: "https://github.com/preschian/agentcord"
    )

    func todayMs(for agent: AgentKind) -> Int64 {
        switch agent {
        case .claude: return claudeTodayMs
        case .codex: return codexTodayMs
        case .cursor: return cursorTodayMs
        case .grok: return grokTodayMs
        case .antigravity: return antigravityTodayMs
        case .opencode: return opencodeTodayMs
        }
    }

    func isLinked(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claude: return session.isLinked
        case .codex: return codexSession.isLinked
        case .cursor: return cursorSession.isLinked
        case .grok: return grokSession.isLinked
        case .antigravity: return antigravitySession.isLinked
        case .opencode: return opencodeSession.isLinked
        }
    }

    /// Discord elapsed is `now - start`. Backdate by the daily totals so
    /// switching the winning agent does not jump the clock. Disabled agents
    /// publish `0` from `stop()`, so they drop out of the sum.
    static func presenceStartMs(
        nowMs: Int64,
        claude: Int64,
        codex: Int64,
        cursor: Int64,
        grok: Int64,
        antigravity: Int64,
        opencode: Int64
    ) -> Int64 {
        nowMs - (max(0, claude) + max(0, codex) + max(0, cursor) + max(0, grok)
            + max(0, antigravity) + max(0, opencode))
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    // MARK: Debounced dispatch

    private func scheduleUpdate(_ presence: RichPresence) {
        let signature = signature(for: presence)
        guard signature != lastPayloadSignature else { return }

        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastPayloadSignature = signature
            self.lastUpdateTime = Date()
            self.ipc.setActivity(presence)
        }
        debounceWorkItem = work

        let elapsed = Date().timeIntervalSince(lastUpdateTime)
        let delay = max(0, minUpdateInterval - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleClear() {
        let signature = "CLEARED"
        guard signature != lastPayloadSignature else { return }

        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastPayloadSignature = signature
            self.lastUpdateTime = Date()
            self.ipc.clearActivity()
        }
        debounceWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func signature(for presence: RichPresence) -> String {
        guard let data = try? JSONEncoder().encode(presence),
              let string = String(data: data, encoding: .utf8) else {
            return UUID().uuidString
        }
        return string
    }
}
