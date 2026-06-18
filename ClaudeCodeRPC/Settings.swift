//
//  Settings.swift
//  ClaudeCodeRPC
//
//  User-configurable settings, persisted in UserDefaults. Exposed as an
//  ObservableObject so both the SwiftUI views and the PresenceController can
//  observe changes.
//

import Foundation
import Combine

final class SettingsStore: ObservableObject {

    private enum Key {
        static let clientID = "clientID"
        static let presenceEnabled = "presenceEnabled"
        static let showModel = "showModel"
        static let showTokens = "showTokens"
        static let showProject = "showProject"
        static let showMenuBarStatus = "showMenuBarStatus"
        static let doNotDisturb = "doNotDisturb"
        static let largeImageKey = "largeImageKey"
        static let smallImageKey = "smallImageKey"
        static let activityType = "activityType"
        static let idleWindowSeconds = "idleWindowSeconds"
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
    @Published var doNotDisturb: Bool { didSet { defaults.set(doNotDisturb, forKey: Key.doNotDisturb) } }
    @Published var largeImageKey: String { didSet { defaults.set(largeImageKey, forKey: Key.largeImageKey) } }
    @Published var smallImageKey: String { didSet { defaults.set(smallImageKey, forKey: Key.smallImageKey) } }
    @Published var activityType: Int { didSet { defaults.set(activityType, forKey: Key.activityType) } }
    @Published var idleWindowSeconds: Double { didSet { defaults.set(idleWindowSeconds, forKey: Key.idleWindowSeconds) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.clientID: Self.defaultClientID,
            Key.presenceEnabled: true,
            Key.showModel: true,
            Key.showTokens: true,
            Key.showProject: true,
            Key.showMenuBarStatus: true,
            Key.doNotDisturb: false,
            Key.largeImageKey: "claude-color",
            Key.smallImageKey: "discord-presence-icon",
            Key.activityType: 0,
            Key.idleWindowSeconds: 300.0
        ])

        clientID = defaults.string(forKey: Key.clientID) ?? Self.defaultClientID
        presenceEnabled = defaults.bool(forKey: Key.presenceEnabled)
        showModel = defaults.bool(forKey: Key.showModel)
        showTokens = defaults.bool(forKey: Key.showTokens)
        showProject = defaults.bool(forKey: Key.showProject)
        showMenuBarStatus = defaults.bool(forKey: Key.showMenuBarStatus)
        doNotDisturb = defaults.bool(forKey: Key.doNotDisturb)
        largeImageKey = defaults.string(forKey: Key.largeImageKey) ?? "claude-color"
        smallImageKey = defaults.string(forKey: Key.smallImageKey) ?? "discord-presence-icon"
        activityType = defaults.integer(forKey: Key.activityType)
        idleWindowSeconds = defaults.double(forKey: Key.idleWindowSeconds)
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
