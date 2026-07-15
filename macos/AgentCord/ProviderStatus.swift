//
//  ProviderStatus.swift
//  AgentCord
//
//  Polls each provider's public status page so the popover can surface when a
//  coding agent's backend is having trouble:
//
//    - Claude  -> https://status.claude.com   (Atlassian Statuspage JSON)
//    - Codex   -> https://status.openai.com   (Statuspage-compatible JSON)
//    - Cursor  -> https://status.cursor.com   (Atlassian Statuspage JSON)
//    - Grok    -> https://status.x.ai         (custom page; RSS feed only)
//
//  The three Statuspage-style pages expose an unauthed JSON summary at
//  `/api/v2/summary.json` carrying the overall indicator, each component's
//  status, and any unresolved incidents. xAI's page is a custom Next.js app
//  with no JSON API, but it publishes incidents at `/feed.xml`, so Grok gets
//  incident-driven status with no component breakdown.
//
//  Unlike the usage pollers there is no background timer: status is only
//  rendered inside the popover, so fetching is driven by the popover opening
//  (`refresh()`), throttled per provider so reopening can't hammer the
//  endpoints. The last snapshot stays cached, so a reopened popover shows it
//  immediately while the refresh runs.
//
//  Best-effort like the usage pollers: any failure (offline, endpoint moved,
//  bad payload) just leaves that provider's entry nil and the popover hides
//  the card rather than showing something stale or wrong.
//

import Foundation
import Combine

// MARK: - Per-agent status sources

extension AgentKind {

    /// How this agent's provider publishes status.
    enum StatusSource {
        /// Atlassian Statuspage (or compatible) `/api/v2/summary.json`.
        case statuspage(URL)
        /// xAI's custom status page: incidents only, via its RSS feed.
        case xaiFeed(URL)
    }

    var statusSource: StatusSource {
        switch self {
        case .claude:
            return .statuspage(URL(string: "https://status.claude.com/api/v2/summary.json")!)
        case .codex:
            return .statuspage(URL(string: "https://status.openai.com/api/v2/summary.json")!)
        case .cursor:
            return .statuspage(URL(string: "https://status.cursor.com/api/v2/summary.json")!)
        case .grok:
            return .xaiFeed(URL(string: "https://status.x.ai/feed.xml")!)
        }
    }

    /// The human-facing page the status card footer links to.
    var statusPageURL: URL {
        switch self {
        case .claude: return URL(string: "https://status.claude.com")!
        case .codex: return URL(string: "https://status.openai.com")!
        case .cursor: return URL(string: "https://status.cursor.com")!
        case .grok: return URL(string: "https://status.x.ai")!
        }
    }

    /// Name on the status card title, e.g. "Claude status". Differs from
    /// `providerName` for Claude, whose status page is branded Claude rather
    /// than Anthropic.
    var statusProviderLabel: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "OpenAI"
        case .cursor: return "Cursor"
        case .grok: return "xAI"
        }
    }
}

// MARK: - Hub

/// Owns one poller per agent and republishes their snapshots keyed by agent,
/// so the popover can look up whichever tab is selected through a single
/// environment object.
final class ProviderStatusHub: ObservableObject {

    /// The latest snapshot per agent. An agent is absent until its first
    /// successful fetch (and again once a failure ages past staleness).
    @Published private(set) var statuses: [AgentKind: StatusInfo] = [:]

    private var pollers: [ProviderStatusPoller] = []

    init() {
        pollers = AgentKind.allCases.map { agent in
            ProviderStatusPoller(agent: agent) { [weak self] agent, info in
                guard let self else { return }
                if self.statuses[agent] != info {
                    if let info {
                        self.statuses[agent] = info
                    } else {
                        self.statuses.removeValue(forKey: agent)
                    }
                }
            }
        }
    }

    /// Request a refresh of every provider (called when the popover opens).
    /// Each fetcher throttles itself, so this can't hammer the endpoints.
    func refresh() { pollers.forEach { $0.refresh() } }

    func info(for agent: AgentKind) -> StatusInfo? { statuses[agent] }
}

// MARK: - Poller

/// Fetch/staleness state machine for a single provider, factored out of the
/// original Anthropic-only implementation.
final class ProviderStatusPoller {

    /// Lower bound between fetches. `refresh()` fires on every popover open,
    /// so this is what keeps repeated opens from hammering the endpoint.
    var minFetchInterval: TimeInterval = 60

    /// How long to keep showing the last good snapshot after fetches start
    /// failing, so a transient blip doesn't make the card flicker away.
    var maxStaleness: TimeInterval = 1800

    private let agent: AgentKind

    /// Delivers snapshots on the main queue. `nil` means "no usable data".
    private let onUpdate: (AgentKind, StatusInfo?) -> Void

    /// When the last successful fetch landed. Only touched on `queue`.
    private var lastSuccess: Date = .distantPast

    /// When the last fetch was *attempted*. Only touched on `queue`.
    private var lastAttempt: Date = .distantPast

    private let urlSession: URLSession
    private let queue: DispatchQueue

    init(agent: AgentKind, onUpdate: @escaping (AgentKind, StatusInfo?) -> Void) {
        self.agent = agent
        self.onUpdate = onUpdate
        queue = DispatchQueue(label: "com.agentcord.status.\(agent.rawValue)", qos: .utility)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        urlSession = URLSession(configuration: config)
    }

    /// Request a refresh (when the popover opens). Throttled by
    /// `minFetchInterval` so it can't be used to hammer the endpoint.
    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            guard Date().timeIntervalSince(self.lastAttempt) >= self.minFetchInterval else { return }
            self.fetch()
        }
    }

    // MARK: Fetch

    private var endpoint: URL {
        switch agent.statusSource {
        case .statuspage(let url), .xaiFeed(let url): return url
        }
    }

    private func fetch() {
        lastAttempt = Date()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json, application/rss+xml", forHTTPHeaderField: "Accept")

        urlSession.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            // Hop back onto `queue` so all `lastSuccess` access is serialized.
            self.queue.async {
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let info = self.parse(data) else {
                    self.handleFailure()
                    return
                }
                self.lastSuccess = Date()
                self.publish(info)
            }
        }.resume()
    }

    private func parse(_ data: Data) -> StatusInfo? {
        switch agent.statusSource {
        case .statuspage:
            guard let decoded = try? JSONDecoder().decode(SummaryResponse.self, from: data) else {
                return nil
            }
            return decoded.toStatusInfo(fetchedAt: Date())
        case .xaiFeed:
            return XAIStatusFeed.parse(data, fetchedAt: Date())
        }
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
            self.onUpdate(self.agent, info)
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

        /// Short pill label for the overall state, e.g. "Operational".
        var summaryLabel: String {
            switch self {
            case .none: return "Operational"
            case .minor: return "Degraded"
            case .major: return "Partial Outage"
            case .critical: return "Major Outage"
            case .maintenance: return "Maintenance"
            case .unknown: return "Unknown"
            }
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
    /// Unresolved incidents (the pages only list active ones here).
    let incidents: [Incident]
    let fetchedAt: Date

    /// Number of components that aren't fully operational.
    var degradedCount: Int { components.filter { !$0.status.isOperational }.count }
}

// MARK: - Statuspage wire format

/// The subset of `/api/v2/summary.json` we care about. Every field is optional
/// so decoding never throws on a renamed or missing key. (OpenAI's page omits
/// `incidents` entirely when there are none.)
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
            summaryLabel: level.summaryLabel,
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

// MARK: - xAI feed format

/// Maps xAI's incident RSS feed onto a `StatusInfo`. The feed lists incident
/// history; items without a "resolved" category are still active. Each item
/// carries the affected surface in its title (e.g. "[API (us-west-2.api.x.ai)]
/// …") and a severity category ("available" / "degraded" / "unavailable"), so
/// the snapshot has incidents and an overall level but no component list.
enum XAIStatusFeed {

    static func parse(_ data: Data, fetchedAt: Date) -> StatusInfo? {
        guard let items = RSSParser().parse(data) else { return nil }

        let active = items.filter { item in
            !item.categories.contains("resolved")
                && item.statusHeading?.lowercased() != "resolved"
        }

        let incidents: [StatusInfo.Incident] = active.map { item in
            StatusInfo.Incident(
                name: item.title,
                status: item.statusHeading?.lowercased() ?? "investigating",
                impact: Self.impact(for: item.categories),
                startedAt: item.pubDate
            )
        }

        let level = active
            .map { Self.level(for: $0.categories) }
            .max { Self.rank($0) < Self.rank($1) } ?? StatusInfo.Level.none

        return StatusInfo(
            level: level,
            summaryLabel: level.summaryLabel,
            components: [],
            incidents: incidents,
            fetchedAt: fetchedAt
        )
    }

    /// The feed tags each incident with its monitor severity as a category.
    private static func level(for categories: [String]) -> StatusInfo.Level {
        if categories.contains("unavailable") || categories.contains("outage") { return .critical }
        if categories.contains("degraded") { return .major }
        if categories.contains("maintenance") { return .maintenance }
        return .minor   // "available" and anything unrecognized
    }

    /// Same mapping expressed in Statuspage impact terms for the incident tint.
    private static func impact(for categories: [String]) -> String {
        switch level(for: categories) {
        case .critical: return "critical"
        case .major: return "major"
        case .maintenance: return "maintenance"
        default: return "minor"
        }
    }

    private static func rank(_ level: StatusInfo.Level) -> Int {
        switch level {
        case .none: return 0
        case .unknown: return 1
        case .maintenance: return 2
        case .minor: return 3
        case .major: return 4
        case .critical: return 5
        }
    }
}

/// Minimal RSS `<item>` reader for the xAI feed. Collects each item's title,
/// categories, publish date, and the "Status: X" heading embedded in the HTML
/// description.
private final class RSSParser: NSObject, XMLParserDelegate {

    struct Item {
        var title = ""
        var categories: [String] = []
        var pubDate: Date?
        /// The "X" from the description's leading "<h3>Status: X</h3>".
        var statusHeading: String?
    }

    private var items: [Item] = []
    private var current: Item?
    private var buffer = ""

    func parse(_ data: Data) -> [Item]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        return items
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
    ) {
        if elementName == "item" {
            current = Item()
        }
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        buffer += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        guard current != nil else { return }
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title":
            current?.title = text
        case "category":
            current?.categories.append(text.lowercased())
        case "pubDate":
            current?.pubDate = Self.rfc822.date(from: text)
        case "description":
            current?.statusHeading = Self.statusHeading(in: text)
        case "item":
            if let item = current { items.append(item) }
            current = nil
        default:
            break
        }
    }

    /// Extracts "RESOLVED" from '<h3>Status: RESOLVED</h3>' at the top of the
    /// item's HTML description.
    private static func statusHeading(in html: String) -> String? {
        guard let range = html.range(of: #"Status:\s*([A-Za-z ]+)"#, options: .regularExpression) else {
            return nil
        }
        return html[range]
            .replacingOccurrences(of: "Status:", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Feed dates look like "Tue, 07 Jul 2026 15:40:26 GMT".
    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
}
