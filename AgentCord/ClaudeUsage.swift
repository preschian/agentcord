//
//  ClaudeUsage.swift
//  AgentCord
//
//  Polls the user's Claude subscription usage limits — the rolling 5-hour
//  "session" quota and the weekly quota shown by Claude Code's `/usage`.
//
//  Unlike token counts, these numbers are NOT in the local transcripts. They
//  come from an undocumented OAuth endpoint that Claude Code itself calls. We
//  reuse Claude Code's own access token (read from the login keychain) and hit
//  the same endpoint. Everything here is best-effort: any failure (no token,
//  expired token, keychain access denied, endpoint changed) just leaves
//  `current` nil, so the popover hides the row rather than showing something
//  wrong. The token is read fresh on every poll, so while Claude Code keeps it
//  refreshed we stay current without implementing the OAuth refresh flow.
//

import Foundation
import Combine
import Security

final class ClaudeUsage: ObservableObject {

    /// The latest usage snapshot, or nil when it could not be fetched.
    @Published private(set) var current: UsageInfo?

    /// How often to refresh while the app runs. The numbers move slowly and the
    /// endpoint rate-limits aggressively (HTTP 429), so we poll sparingly.
    var pollInterval: TimeInterval = 300

    /// Lower bound between fetches. Guards the on-demand `refresh()` (popover
    /// opens) so repeatedly opening the popover can't hammer the endpoint.
    var minFetchInterval: TimeInterval = 60

    /// How long to keep showing the last good snapshot after fetches start
    /// failing. A failed poll (a 429, network blip, token refresh in flight,
    /// keychain hiccup) shouldn't make the readout vanish; only give up once the
    /// data is clearly stale.
    var maxStaleness: TimeInterval = 1800

    /// When the last successful fetch landed. Only touched on `queue`.
    private var lastSuccess: Date = .distantPast

    /// When the last fetch was *attempted*. Only touched on `queue`.
    private var lastAttempt: Date = .distantPast

    private let urlSession: URLSession
    private let queue = DispatchQueue(label: "com.agentcord.usage", qos: .utility)
    private var timer: DispatchSourceTimer?

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

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
        guard let token = Self.readAccessToken() else {
            handleFailure()
            return
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        urlSession.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            // Hop back onto `queue` so all `lastSuccess` access is serialized.
            self.queue.async {
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
                    self.handleFailure()
                    return
                }
                self.lastSuccess = Date()
                self.publish(decoded.toUsageInfo())
            }
        }.resume()
    }

    /// A failed fetch keeps the last good snapshot until it ages past
    /// `maxStaleness`, so a transient hiccup doesn't make the readout flicker
    /// away. Runs on `queue`.
    private func handleFailure() {
        if Date().timeIntervalSince(lastSuccess) > maxStaleness {
            publish(nil)
        }
    }

    private func publish(_ info: UsageInfo?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.current != info { self.current = info }
        }
    }

    // MARK: Keychain

    /// Reads Claude Code's OAuth access token from the login keychain. The item
    /// belongs to Claude Code, so the first read may prompt the user to allow
    /// access; choosing "Always Allow" adds us to the item's ACL and silences
    /// the prompt thereafter. A denial or missing item simply returns nil.
    private static func readAccessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }
}

// MARK: - Wire format

/// The subset of the `/api/oauth/usage` response we care about. The endpoint is
/// undocumented, so every field is optional and decoding never throws on a
/// missing or renamed key — we fall back to the older top-level windows or to
/// zero rather than failing the whole refresh.
private struct UsageResponse: Decodable {

    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    struct Limit: Decodable {
        let kind: String?
        let group: String?
        let percent: Double?
        let severity: String?
        let resets_at: String?
    }

    let five_hour: Window?
    let seven_day: Window?
    let limits: [Limit]?

    func toUsageInfo() -> UsageInfo {
        let limits = self.limits ?? []
        // Prefer the structured `limits` array (it carries severity); fall back
        // to the flat top-level windows for the raw percentage and reset time.
        let session = limits.first { $0.kind == "session" || $0.group == "session" }
        let weekly = limits.first { $0.kind == "weekly_all" }
            ?? limits.first { $0.group == "weekly" }

        return UsageInfo(
            fiveHour: UsageInfo.Window(
                percent: Self.percent(session?.percent, fallback: five_hour?.utilization),
                severity: session?.severity ?? "normal",
                resetsAt: Self.parseDate(session?.resets_at ?? five_hour?.resets_at)
            ),
            weekly: UsageInfo.Window(
                percent: Self.percent(weekly?.percent, fallback: seven_day?.utilization),
                severity: weekly?.severity ?? "normal",
                resetsAt: Self.parseDate(weekly?.resets_at ?? seven_day?.resets_at)
            )
        )
    }

    private static func percent(_ primary: Double?, fallback: Double?) -> Int {
        Int((primary ?? fallback ?? 0).rounded())
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

    /// Parses timestamps like "2026-06-26T04:59:59.083560+00:00". The API uses
    /// microsecond precision, which the fractional-seconds formatter can reject,
    /// so as a fallback we strip the fractional component and parse plain.
    private static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = isoFractional.date(from: string) { return date }
        if let dot = string.firstIndex(of: "."),
           let tz = string[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let stripped = String(string[..<dot]) + String(string[tz...])
            if let date = isoPlain.date(from: stripped) { return date }
        }
        return isoPlain.date(from: string)
    }
}
