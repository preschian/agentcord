//
//  Settings.swift
//  AgentCord
//
//  User-configurable settings, persisted in UserDefaults. Exposed as an
//  ObservableObject so both the SwiftUI views and the PresenceController can
//  observe changes.
//

import Foundation
import Combine
import SwiftUI

final class SettingsStore: ObservableObject {

    private enum Key {
        static let clientID = "clientID"
        static let presenceEnabled = "presenceEnabled"
        static let showModel = "showModel"
        static let showTokens = "showTokens"
        static let showProject = "showProject"
        static let showMenuBarStatus = "showMenuBarStatus"
        static let showUsageInMenuBar = "showUsageInMenuBar"
        static let unifiedUsage = "unifiedUsage"
        static let doNotDisturb = "doNotDisturb"
        static let preventSleep = "preventSleep"
        static let largeImageKey = "largeImageKey"
        static let smallImageKey = "smallImageKey"
        static let activityType = "activityType"
        static let idleWindowSeconds = "idleWindowSeconds"
        static let selectedAgent = "selectedAgent"
        static let agentClaudeEnabled = "agentClaudeEnabled"
        static let agentCursorEnabled = "agentCursorEnabled"
        static let agentCodexEnabled = "agentCodexEnabled"
        static let agentGrokEnabled = "agentGrokEnabled"
    }

    /// The Discord Application ID this app reports as. Not a secret; safe to
    /// ship. Override by writing a `clientID` value into UserDefaults.
    static let defaultClientID = "1517099756063686677"

    private let defaults: UserDefaults

    @Published var clientID: String { didSet { defaults.set(clientID, forKey: Key.clientID) } }
    @Published var presenceEnabled: Bool { didSet { defaults.set(presenceEnabled, forKey: Key.presenceEnabled) } }
    @Published var showModel: Bool { didSet { defaults.set(showModel, forKey: Key.showModel) } }
    @Published var showTokens: Bool { didSet { defaults.set(showTokens, forKey: Key.showTokens) } }
    @Published var showProject: Bool { didSet { defaults.set(showProject, forKey: Key.showProject) } }
    @Published var showMenuBarStatus: Bool { didSet { defaults.set(showMenuBarStatus, forKey: Key.showMenuBarStatus) } }
    @Published var showUsageInMenuBar: Bool { didSet { defaults.set(showUsageInMenuBar, forKey: Key.showUsageInMenuBar) } }
    /// Show one usage card covering every connected agent instead of the
    /// selected agent's card.
    @Published var unifiedUsage: Bool { didSet { defaults.set(unifiedUsage, forKey: Key.unifiedUsage) } }
    @Published var doNotDisturb: Bool { didSet { defaults.set(doNotDisturb, forKey: Key.doNotDisturb) } }
    @Published var preventSleep: Bool { didSet { defaults.set(preventSleep, forKey: Key.preventSleep) } }
    @Published var largeImageKey: String { didSet { defaults.set(largeImageKey, forKey: Key.largeImageKey) } }
    @Published var smallImageKey: String { didSet { defaults.set(smallImageKey, forKey: Key.smallImageKey) } }
    @Published var activityType: Int { didSet { defaults.set(activityType, forKey: Key.activityType) } }
    @Published var idleWindowSeconds: Double { didSet { defaults.set(idleWindowSeconds, forKey: Key.idleWindowSeconds) } }

    /// Which agent tab is selected in the popover.
    @Published var selectedAgent: AgentKind {
        didSet { defaults.set(selectedAgent.rawValue, forKey: Key.selectedAgent) }
    }
    /// Agents enabled in Settings (shown in the segmented switcher when on).
    @Published var agentClaudeEnabled: Bool { didSet { defaults.set(agentClaudeEnabled, forKey: Key.agentClaudeEnabled) } }
    @Published var agentCursorEnabled: Bool { didSet { defaults.set(agentCursorEnabled, forKey: Key.agentCursorEnabled) } }
    @Published var agentCodexEnabled: Bool { didSet { defaults.set(agentCodexEnabled, forKey: Key.agentCodexEnabled) } }
    @Published var agentGrokEnabled: Bool { didSet { defaults.set(agentGrokEnabled, forKey: Key.agentGrokEnabled) } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.clientID: Self.defaultClientID,
            Key.presenceEnabled: true,
            Key.showModel: true,
            Key.showTokens: true,
            Key.showProject: true,
            Key.showMenuBarStatus: true,
            Key.showUsageInMenuBar: false,
            Key.unifiedUsage: false,
            Key.doNotDisturb: false,
            Key.preventSleep: false,
            Key.largeImageKey: "claude-color",
            Key.smallImageKey: "discord-presence-icon",
            Key.activityType: 0,
            Key.idleWindowSeconds: 300.0,
            Key.selectedAgent: AgentKind.claude.rawValue,
            Key.agentClaudeEnabled: true,
            Key.agentCursorEnabled: true,
            // Codex defaults on; Connect card shows if not signed in.
            Key.agentCodexEnabled: true,
            Key.agentGrokEnabled: true
        ])

        clientID = defaults.string(forKey: Key.clientID) ?? Self.defaultClientID
        presenceEnabled = defaults.bool(forKey: Key.presenceEnabled)
        showModel = defaults.bool(forKey: Key.showModel)
        showTokens = defaults.bool(forKey: Key.showTokens)
        showProject = defaults.bool(forKey: Key.showProject)
        showMenuBarStatus = defaults.bool(forKey: Key.showMenuBarStatus)
        showUsageInMenuBar = defaults.bool(forKey: Key.showUsageInMenuBar)
        unifiedUsage = defaults.bool(forKey: Key.unifiedUsage)
        doNotDisturb = defaults.bool(forKey: Key.doNotDisturb)
        preventSleep = defaults.bool(forKey: Key.preventSleep)
        largeImageKey = defaults.string(forKey: Key.largeImageKey) ?? "claude-color"
        smallImageKey = defaults.string(forKey: Key.smallImageKey) ?? "discord-presence-icon"
        activityType = defaults.integer(forKey: Key.activityType)
        idleWindowSeconds = defaults.double(forKey: Key.idleWindowSeconds)
        selectedAgent = AgentKind(rawValue: defaults.string(forKey: Key.selectedAgent) ?? "") ?? .claude
        agentClaudeEnabled = defaults.bool(forKey: Key.agentClaudeEnabled)
        agentCursorEnabled = defaults.bool(forKey: Key.agentCursorEnabled)
        agentCodexEnabled = defaults.bool(forKey: Key.agentCodexEnabled)
        agentGrokEnabled = defaults.bool(forKey: Key.agentGrokEnabled)
    }

    /// Agents the user has toggled on in Settings.
    var enabledAgents: [AgentKind] {
        AgentKind.allCases.filter { isAgentEnabled($0) }
    }

    func isAgentEnabled(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claude: return agentClaudeEnabled
        case .cursor: return agentCursorEnabled
        case .codex: return agentCodexEnabled
        case .grok: return agentGrokEnabled
        }
    }

    func setAgentEnabled(_ agent: AgentKind, _ enabled: Bool) {
        switch agent {
        case .claude: agentClaudeEnabled = enabled
        case .cursor: agentCursorEnabled = enabled
        case .codex: agentCodexEnabled = enabled
        case .grok: agentGrokEnabled = enabled
        }
        // Keep the selected tab pointing at an enabled agent.
        if !isAgentEnabled(selectedAgent), let first = enabledAgents.first {
            selectedAgent = first
        }
    }

    func bindingForAgent(_ agent: AgentKind) -> Binding<Bool> {
        Binding(
            get: { self.isAgentEnabled(agent) },
            set: { self.setAgentEnabled(agent, $0) }
        )
    }

    /// Activity types Discord permits for RPC updates.
    /// Streaming (1) and Custom (4) are intentionally excluded.
    static let allowedActivityTypes: [(value: Int, name: String)] = [
        (0, "Playing"),
        (2, "Listening"),
        (3, "Watching"),
        (5, "Competing")
    ]
}
