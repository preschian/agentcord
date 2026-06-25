//
//  AnthropicStatus.swift
//  AgentCord
//
//  Polls Anthropic's public status page (https://status.claude.com) so the
//  popover can surface when Claude Code / the API / claude.ai are having
//  trouble. The page is an Atlassian Statuspage, which exposes an unauthed
//  JSON summary at `/api/v2/summary.json` carrying the overall indicator, each
//  component's status, and any unresolved incidents.
//
//  Best-effort like ClaudeUsage: any failure (offline, endpoint moved, bad
//  JSON) just leaves `current` nil and the popover hides the card rather than
//  showing something stale or wrong.
//

import Foundation
import Combine

final class AnthropicStatus: ObservableObject {

    /// The latest status snapshot, or nil when it could not be fetched.
    @Published private(set) var current: StatusInfo?

    /// How often to refresh while the app runs. The page moves slowly, so poll
    /// sparingly.
    var pollInterval: TimeInterval = 300

    /// Lower bound between fetches. Guards the on-demand `refresh()` (popover
    /// opens) so repeatedly opening the popover can't hammer the endpoint.
    var minFetchInterval: TimeInterval = 60

    /// How long to keep showing the last good snapshot after fetches start
    /// failing, so a transient blip doesn't make the card flicker away.
    var maxStaleness: TimeInterval = 1800

    /// When the last successful fetch landed. Only touched on `queue`.
    private var lastSuccess: Date = .distantPast

    /// When the last fetch was *attempted*. Only touched on `queue`.
    private var lastAttempt: Date = .distantPast

    private let urlSession: URLSession
    private let queue = DispatchQueue(label: "com.agentcord.status", qos: .utility)
    private var timer: DispatchSourceTimer?

    private static let endpoint = URL(string: "https://status.claude.com/api/v2/summary.json")!

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        urlSession = URLSession(configuration: config)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.fetch() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Request a refresh (e.g. when the popover opens). Throttled by
    /// `minFetchInterval` so it can't be used to hammer the endpoint.
    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            guard Date().timeIntervalSince(self.lastAttempt) >= self.minFetchInterval else { return }
            self.fetch()
        }
    }

    // MARK: Fetch

    private func fetch() {
        lastAttempt = Date()

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        urlSession.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            // Hop back onto `queue` so all `lastSuccess` access is serialized.
            self.queue.async {
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let decoded = try? JSONDecoder().decode(SummaryResponse.self, from: data) else {
                    self.handleFailure()
                    return
                }
                self.lastSuccess = Date()
                self.publish(decoded.toStatusInfo(fetchedAt: Date()))
            }
        }.resume()
    }

    /// A failed fetch keeps the last good snapshot until it ages past
    /// `maxStaleness`. Runs on `queue`.
    private func handleFailure() {
        if Date().timeIntervalSince(lastSuccess) > maxStaleness {
            publish(nil)
        }
    }

    private func publish(_ info: StatusInfo?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.current != info { self.current = info }
        }
    }
}

// MARK: - Snapshot

/// What the popover renders: the overall indicator, every component's status,
/// any unresolved incidents, and when the snapshot was fetched (for the
/// "updated …" line).
struct StatusInfo: Equatable {

    /// Overall severity, mapped from the page's `status.indicator`.
    enum Level: String {
        case none, minor, major, critical, maintenance, unknown

        init(indicator: String?) {
            self = Level(rawValue: indicator ?? "") ?? .unknown
        }
    }

    /// A component's status, mapped from Statuspage's raw status strings.
    enum ComponentStatus {
        case operational, degraded, partialOutage, majorOutage, maintenance, unknown

        init(raw: String) {
            switch raw {
            case "operational": self = .operational
            case "degraded_performance": self = .degraded
            case "partial_outage": self = .partialOutage
            case "major_outage": self = .majorOutage
            case "under_maintenance": self = .maintenance
            default: self = .unknown
            }
        }

        var isOperational: Bool { self == .operational }

        /// Short label shown in the breakdown, e.g. "Degraded".
        var label: String {
            switch self {
            case .operational: return "Operational"
            case .degraded: return "Degraded"
            case .partialOutage: return "Partial Outage"
            case .majorOutage: return "Major Outage"
            case .maintenance: return "Maintenance"
            case .unknown: return "Unknown"
            }
        }
    }

    struct Component: Equatable {
        /// Display name with the Statuspage parenthetical stripped, e.g.
        /// "Claude API" rather than "Claude API (api.anthropic.com)".
        let name: String
        let status: ComponentStatus
    }

    struct Incident: Equatable {
        let name: String
        /// "investigating" / "identified" / "monitoring" / …
        let status: String
        let impact: String
        let startedAt: Date?
    }

    let level: Level
    /// Short pill label for the overall state, e.g. "Operational" / "Degraded".
    let summaryLabel: String
    let components: [Component]
    /// Unresolved incidents (the page only lists active ones here).
    let incidents: [Incident]
    let fetchedAt: Date

    /// Number of components that aren't fully operational.
    var degradedCount: Int { components.filter { !$0.status.isOperational }.count }
}

// MARK: - Wire format

/// The subset of `/api/v2/summary.json` we care about. Every field is optional
/// so decoding never throws on a renamed or missing key.
private struct SummaryResponse: Decodable {

    struct Status: Decodable {
        let indicator: String?
    }

    struct Component: Decodable {
        let name: String?
        let status: String?
        /// Statuspage marks container rows with `group: true`; skip those.
        let group: Bool?
    }

    struct Incident: Decodable {
        let name: String?
        let status: String?
        let impact: String?
        let started_at: String?
    }

    let status: Status?
    let components: [Component]?
    let incidents: [Incident]?

    func toStatusInfo(fetchedAt: Date) -> StatusInfo {
        let components: [StatusInfo.Component] = (self.components ?? []).compactMap { c in
            guard c.group != true, let name = c.name, let status = c.status else { return nil }
            return StatusInfo.Component(
                name: Self.shortName(name),
                status: StatusInfo.ComponentStatus(raw: status)
            )
        }

        let incidents: [StatusInfo.Incident] = (self.incidents ?? []).compactMap { i in
            guard let name = i.name else { return nil }
            return StatusInfo.Incident(
                name: name,
                status: i.status ?? "investigating",
                impact: i.impact ?? "none",
                startedAt: Self.parseDate(i.started_at)
            )
        }

        let level = StatusInfo.Level(indicator: status?.indicator)
        return StatusInfo(
            level: level,
            summaryLabel: Self.summaryLabel(for: level),
            components: components,
            incidents: incidents,
            fetchedAt: fetchedAt
        )
    }

    /// Drops the trailing parenthetical so names stay compact in the popover,
    /// e.g. "Claude API (api.anthropic.com)" -> "Claude API".
    private static func shortName(_ name: String) -> String {
        guard let paren = name.firstIndex(of: "(") else { return name }
        return name[..<paren].trimmingCharacters(in: .whitespaces)
    }

    private static func summaryLabel(for level: StatusInfo.Level) -> String {
        switch level {
        case .none: return "Operational"
        case .minor: return "Degraded"
        case .major: return "Partial Outage"
        case .critical: return "Major Outage"
        case .maintenance: return "Maintenance"
        case .unknown: return "Unknown"
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses timestamps like "2026-06-13T00:50:43.823Z", tolerating the
    /// presence or absence of fractional seconds.
    private static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}
