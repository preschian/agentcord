//
//  App.swift
//  ClaudeCodeRPC
//
//  Menu bar entry point. No Dock icon (LSUIElement / accessory policy).
//

import SwiftUI
import AppKit

@main
struct ClaudeCodeRPCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appDelegate.settings)
                .environmentObject(appDelegate.controller)
                .environmentObject(appDelegate.loginItem)
        } label: {
            MenuBarLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    let loginItem = LoginItem()
    lazy var controller = PresenceController(settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and suspenders: ensure no Dock icon even without LSUIElement.
        NSApp.setActivationPolicy(.accessory)
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

// MARK: - Menu bar label

struct MenuBarLabel: View {
    @ObservedObject var controller: PresenceController

    var body: some View {
        Image(systemName: "sparkles")
            .symbolVariant(controller.discordState == .connected ? .none : .slash)
    }
}

// MARK: - Popover content

struct MenuContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: PresenceController
    @EnvironmentObject private var loginItem: LoginItem
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statusSection
            Divider()
            toggles
            DisclosureGroup("Settings", isExpanded: $showAdvanced) {
                settingsForm
                    .padding(.top, 6)
            }
            Divider()
            Button("Quit Claude Code RPC") {
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
            Text("Claude Code RPC")
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
        }
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

            Picker("Activity type", selection: $settings.activityType) {
                ForEach(SettingsStore.allowedActivityTypes, id: \.value) { type in
                    Text(type.name).tag(type.value)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Idle window: \(Int(settings.idleWindowSeconds))s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.idleWindowSeconds, in: 15...300, step: 15)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Large image key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("large_image", text: $settings.largeImageKey)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Small image key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("small_image", text: $settings.smallImageKey)
                    .textFieldStyle(.roundedBorder)
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
