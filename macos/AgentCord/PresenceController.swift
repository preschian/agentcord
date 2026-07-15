//
//  PresenceController.swift
//  AgentCord
//
//  Observes active Claude Code and Codex sessions, builds the Rich Presence payload
//  from the user's settings, debounces updates, and drives DiscordIPC. Clears
//  the presence when the session goes idle or the app quits.
//

import Foundation
import Combine
import AppKit

final class PresenceController: ObservableObject {

    @Published private(set) var discordState: DiscordIPC.State = .disconnected
    @Published private(set) var lastError: String?
    @Published private(set) var currentSession: SessionInfo?
    @Published private(set) var activeAgent: AgentKind?

    let session = ClaudeSession()
    let codexSession = CodexSession()
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.selectActiveSession() }
            .store(in: &cancellables)

        codexSession.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.selectActiveSession() }
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
        session.activeWindowSeconds = settings.idleWindowSeconds
        codexSession.activeWindowSeconds = settings.idleWindowSeconds
        session.start()
        codexSession.start()
        selectActiveSession()
        connectIfPossible()
    }

    func shutdown() {
        ipc.clearActivitySync()
        session.stop()
        codexSession.stop()
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

    private func handleSettingsChange() {
        session.activeWindowSeconds = settings.idleWindowSeconds
        codexSession.activeWindowSeconds = settings.idleWindowSeconds
        selectActiveSession()
        rebuild()
    }

    private func selectActiveSession() {
        var candidates: [SessionInfo] = []
        if settings.agentClaudeEnabled, let claude = session.current { candidates.append(claude) }
        if settings.agentCodexEnabled, let codex = codexSession.current { candidates.append(codex) }
        let selected = candidates.max { $0.lastModified < $1.lastModified }
        if currentSession != selected { currentSession = selected }
        let agent = selected?.agent
        if activeAgent != agent { activeAgent = agent }
        rebuild()
    }

    // MARK: Presence building

    private func rebuild() {
        guard settings.presenceEnabled else { return }

        if settings.doNotDisturb {
            scheduleClear()
            return
        }
        guard let info = currentSession else {
            scheduleClear()
            return
        }
        scheduleUpdate(buildPresence(from: info))
    }

    private func buildPresence(from info: SessionInfo) -> RichPresence {
        // Header (bold title): the model, e.g. "Opus 4.8".
        let name = (settings.showModel ? info.model : nil) ?? "agentcord"

        // details: the repository being worked on.
        let details = settings.showProject ? "Working on: \(info.projectName)" : nil

        // state: token usage.
        let state: String?
        if settings.showTokens, info.totalTokens > 0 {
            state = "\(Self.formatTokens(info.totalTokens)) tokens"
        } else {
            state = nil
        }

        let assets = Assets(
            large_image: settings.largeImageKey.isEmpty ? nil : settings.largeImageKey,
            large_text: "agentcord",
            small_image: settings.smallImageKey.isEmpty ? nil : settings.smallImageKey,
            small_text: "Active \(info.agent.displayName) session"
        )

        let type = SettingsStore.allowedActivityTypes.map(\.value).contains(settings.activityType)
            ? settings.activityType : 0

        return RichPresence(
            type: type,
            name: name,
            details: details,
            state: state,
            timestamps: Timestamps(start: info.startEpochMs, end: nil),
            assets: assets,
            buttons: [Self.presenceButton(for: info.agent)]
        )
    }

    private static func presenceButton(for agent: AgentKind) -> PresenceButton {
        switch agent {
        case .codex:
            return PresenceButton(label: "What is Codex", url: "https://developers.openai.com/codex")
        case .claude:
            return PresenceButton(label: "What is Claude Code", url: "https://www.anthropic.com")
        case .cursor:
            return PresenceButton(label: "What is Cursor", url: "https://cursor.com")
        case .grok:
            return PresenceButton(label: "What is Grok", url: "https://grok.com")
        }
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
