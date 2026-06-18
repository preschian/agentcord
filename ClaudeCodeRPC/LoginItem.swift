//
//  LoginItem.swift
//  ClaudeCodeRPC
//
//  Thin wrapper around SMAppService for "launch at login" (macOS 13+).
//

import Foundation
import ServiceManagement

final class LoginItem: ObservableObject {

    /// Whether the app is registered to launch at login.
    @Published var isEnabled: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the app as a login item. Returns the resulting
    /// state; on failure the published value is left reflecting reality.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("LoginItem: failed to \(enabled ? "register" : "unregister"): \(error.localizedDescription)")
        }
        refresh()
    }
}
