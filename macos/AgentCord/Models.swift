//
//  Models.swift
//  AgentCord
//
//  Codable payload structs for the Discord Rich Presence IPC protocol,
//  plus the value type that describes a detected Claude Code session.
//

import Foundation

// MARK: - Rich Presence payload

/// A Discord activity (Rich Presence). All fields are optional so we only
/// encode what we actually want to display.
struct RichPresence: Codable, Equatable {
    /// Activity type. 0 Playing, 2 Listening, 3 Watching, 5 Competing.
    /// Types 1 (Streaming) and 4 (Custom) are not allowed for RPC updates.
    var type: Int?
    /// The bold title line. Discord honors this for the activity header.
    var name: String?
    var details: String?
    var state: String?
    var timestamps: Timestamps?
    var assets: Assets?
    var buttons: [PresenceButton]?
}

struct Timestamps: Codable, Equatable {
    /// Epoch milliseconds. Setting `start` makes Discord show an elapsed counter.
    var start: Int64?
    var end: Int64?
}

struct Assets: Codable, Equatable {
    var large_image: String?
    var large_text: String?
    var small_image: String?
    var small_text: String?
}

struct PresenceButton: Codable, Equatable {
    var label: String
    var url: String
}

// MARK: - IPC command payloads

/// Sent as opcode 0 immediately after connecting.
struct HandshakePayload: Encodable {
    let v: Int
    let client_id: String
}

/// Sent as opcode 1 to set (or clear) the presence.
struct SetActivityCommand: Encodable {
    let cmd = "SET_ACTIVITY"
    let nonce: String
    let args: SetActivityArgs

    private enum CodingKeys: String, CodingKey {
        case cmd, nonce, args
    }
}

struct SetActivityArgs: Encodable {
    let pid: Int32
    /// When nil we must encode an explicit JSON `null` to clear the presence.
    let activity: RichPresence?

    private enum CodingKeys: String, CodingKey {
        case pid, activity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        if let activity {
            try container.encode(activity, forKey: .activity)
        } else {
            try container.encodeNil(forKey: .activity)
        }
    }
}

// MARK: - Claude Code session

/// A snapshot of the currently active Claude Code session.
struct SessionInfo: Equatable {
    var projectName: String
    var model: String?
    var startEpochMs: Int64
    var totalTokens: Int
    var lastModified: Date
}

// MARK: - Claude subscription usage

/// The user's current subscription usage, as shown by Claude Code's `/usage`.
struct UsageInfo: Equatable {

    /// One rate-limit window: how much of it is used and when it resets.
    struct Window: Equatable {
        var percent: Int
        /// Raw severity from the API ("normal", "warning", ...). Drives color.
        var severity: String
        var resetsAt: Date?

        /// True once the window is past "normal", so the UI can highlight it.
        var isElevated: Bool { severity.lowercased() != "normal" }
    }

    /// The rolling 5-hour session limit.
    var fiveHour: Window
    /// The weekly (all-models) limit.
    var weekly: Window
}
