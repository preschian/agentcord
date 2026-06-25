//
//  AnthropicStatus.swift
//  AgentCord
//
//  Polls Anthropic's public status page (https://status.claude.com) so the
//  popover can surface when Claude Code / the API / claude.ai are having
//  trouble. The page is an Atlassian Statuspage, which exposes an unauthbed
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
                self.publish(decoded.toStatusInfo())
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

/// What the popover renders: the overall indicator/description, the components
/// that are *not* operational, and any unresolved incidents.
struct StatusInfo: Equatable {

    enum Level: String {
        case none, minor, major, critical, maintenance, unknown

        init(indicator: String?) {
            self = Level(rawValue: indicator ?? "") ?? .unknown
        }
    }

    struct Component: Equatable {
        let name: String
        /// Raw Statuspage status, e.g. "degraded_performance".
        let status: String

        /// Human-readable, e.g. "Degraded Performance".
        var statusText: String {
            status.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    struct Incident: Equatable {
        let name: String
        let impact: String
    }

    /// Overall severity, mapped from the page's `status.indicator`.
    let level: Level
    /// Overall description, e.g. "All Systems Operational".
    let description: String
    /// Components whose status is anything other than "operational".
    let problems: [Component]
    /// Unresolved incidents (the page only lists active ones here).
    let incidents: [Incident]
}

// MARK: - Wire format

/// The subset of `/api/v2/summary.json` we care about. Every field is optional
/// so decoding never throws on a renamed or missing key.
private struct SummaryResponse: Decodable {

    struct Status: Decodable {
        let indicator: String?
        let description: String?
    }

    struct Component: Decodable {
        let name: String?
        let status: String?
        /// Statuspage marks container rows with `group: true`; skip those.
        let group: Bool?
    }

    struct Incident: Decodable {
        let name: String?
        let impact: String?
    }

    let status: Status?
    let components: [Component]?
    let incidents: [Incident]?

    func toStatusInfo() -> StatusInfo {
        let problems: [StatusInfo.Component] = (components ?? []).compactMap { c in
            guard c.group != true,
                  let name = c.name,
                  let status = c.status,
                  status != "operational" else { return nil }
            return StatusInfo.Component(name: name, status: status)
        }

        let incidents: [StatusInfo.Incident] = (incidents ?? []).compactMap { i in
            guard let name = i.name else { return nil }
            return StatusInfo.Incident(name: name, impact: i.impact ?? "none")
        }

        return StatusInfo(
            level: StatusInfo.Level(indicator: status?.indicator),
            description: status?.description ?? "Status unknown",
            problems: problems,
            incidents: incidents
        )
    }
}
