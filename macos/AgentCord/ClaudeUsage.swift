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

    /// Disk cache so a relaunch right after a 429 (or any transient failure)
    /// still shows the last good numbers instead of blank "—" rows.
    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AgentCord", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("claude-usage-cache.json")
    }()

    /// The service name Claude Code stores its credentials under. Older versions
    /// use exactly this; newer ones (v2.1.52+) append a per-install suffix, e.g.
    /// "Claude Code-credentials-<hash>", so we match by prefix.
    private static let keychainServicePrefix = "Claude Code-credentials"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        urlSession = URLSession(configuration: config)

        // Restore a still-fresh snapshot before the first network round-trip so
        // the popover isn't empty while we wait (or while the API rate-limits).
        if let cached = Self.loadCache(), Date().timeIntervalSince(cached.fetchedAt) <= maxStaleness {
            current = cached.info
            lastSuccess = cached.fetchedAt
        }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Prefer a slightly longer first delay when we already have a cache hit,
        // so we don't immediately burn a rate-limit slot on every relaunch.
        let firstDelay: TimeInterval = (current != nil) ? 5 : 1
        t.schedule(deadline: .now() + firstDelay, repeating: pollInterval)
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
                let info = decoded.toUsageInfo()
                self.lastSuccess = Date()
                Self.saveCache(info, fetchedAt: self.lastSuccess)
                self.publish(info)
            }
        }.resume()
    }

    /// A failed fetch keeps the last good snapshot until it ages past
    /// `maxStaleness`, so a transient hiccup doesn't make the readout flicker
    /// away. Runs on `queue`.
    private func handleFailure() {
        if Date().timeIntervalSince(lastSuccess) > maxStaleness {
            Self.clearCache()
            publish(nil)
        }
        // else: keep showing `current` (in-memory and/or restored from disk)
    }

    private func publish(_ info: UsageInfo?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.current != info { self.current = info }
        }
    }

    // MARK: Disk cache

    private struct CachePayload: Codable {
        var fetchedAt: Date
        var info: UsageInfo
    }

    private static func loadCache() -> CachePayload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(CachePayload.self, from: data)
    }

    private static func saveCache(_ info: UsageInfo, fetchedAt: Date) {
        let payload = CachePayload(fetchedAt: fetchedAt, info: info)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: Keychain

    /// Reads Claude Code's OAuth access token from the login keychain without
    /// spamming the keychain access dialog.
    ///
    /// The item belongs to Claude Code, not us, so two rules keep this quiet:
    ///
    ///  - We never fetch the secret through the Security framework
    ///    (`SecItemCopyMatching` + `kSecReturnData`): for an item we don't own
    ///    that call re-prompts on *every* read, so "Always Allow" only silences a
    ///    single cycle. We use it solely for a metadata list query (attributes,
    ///    no data), which does not prompt, to discover which service names exist.
    ///  - The secret itself is read by shelling out to `/usr/bin/security`. That
    ///    binary is stable and Apple-signed, so a one-time "Always Allow" sticks
    ///    permanently rather than breaking every time our app is rebuilt.
    ///
    /// Newer Claude Code versions store the item under a suffixed service name
    /// and may keep several entries, so we scan every `Claude Code-credentials*`
    /// service and return the token that expires latest. Any failure yields nil.
    private static func readAccessToken() -> String? {
        var best: (token: String, expiresAt: Double)?
        for (service, account) in discoverCredentialServices() {
            guard let oauth = readOAuthViaSecurityCLI(service: service, account: account),
                  let token = oauth["accessToken"] as? String, !token.isEmpty else {
                continue
            }
            let expiresAt = oauth["expiresAt"] as? Double ?? 0
            if best == nil || expiresAt > best!.expiresAt {
                best = (token, expiresAt)
            }
        }
        return best?.token
    }

    /// Enumerate the keychain for every generic-password item whose service name
    /// starts with `keychainServicePrefix`, returning their (service, account)
    /// pairs. This list query returns attributes only — no secret data — so it
    /// does not trigger the keychain access dialog. If the query fails (some
    /// legacy login keychains reject it), fall back to the bare service name.
    private static func discoverCredentialServices() -> [(service: String, account: String?)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var raw: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &raw) == errSecSuccess,
              let items = raw as? [[String: Any]] else {
            return [(keychainServicePrefix, nil)]
        }

        var result: [(service: String, account: String?)] = []
        for item in items {
            guard let service = item[kSecAttrService as String] as? String,
                  service.hasPrefix(keychainServicePrefix) else { continue }
            let account = item[kSecAttrAccount as String] as? String
            result.append((service, (account?.isEmpty == false) ? account : nil))
        }
        return result.isEmpty ? [(keychainServicePrefix, nil)] : result
    }

    /// Read one credential item's `claudeAiOauth` dictionary via the `security`
    /// CLI. Returns nil on any failure (missing item, denied access, bad JSON).
    private static func readOAuthViaSecurityCLI(service: String, account: String?) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var args = ["find-generic-password", "-s", service]
        if let account { args.append(contentsOf: ["-a", account]) }
        args.append("-w")
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        return oauth
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
        struct Scope: Decodable {
            struct Model: Decodable {
                let id: String?
                let display_name: String?
            }
            let model: Model?
        }

        let kind: String?
        let group: String?
        let percent: Double?
        let severity: String?
        let resets_at: String?
        let scope: Scope?
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
            ?? limits.first { $0.group == "weekly" && $0.scope == nil }

        // Weekly limits scoped to a single model (e.g. Fable on some plans)
        // arrive as extra "weekly_scoped" entries carrying the model's name.
        let modelWeekly: [UsageInfo.ModelWindow] = limits.compactMap { limit in
            guard limit.group == "weekly",
                  let name = limit.scope?.model?.display_name, !name.isEmpty else {
                return nil
            }
            return UsageInfo.ModelWindow(
                modelName: name,
                window: UsageInfo.Window(
                    percent: Self.percent(limit.percent, fallback: nil),
                    severity: limit.severity ?? "normal",
                    resetsAt: Self.parseDate(limit.resets_at)
                )
            )
        }

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
            ),
            modelWeekly: modelWeekly
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
