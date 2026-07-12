//
//  GrokUsage.swift
//  AgentCord
//
//  Polls Grok CLI / SuperGrok weekly credit usage via
//  GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
//  using the OIDC tokens stored in ~/.grok/auth.json (same source as the
//  Grok CLI `/usage` view and Orca's grok-fetcher).
//
//  This is weekly included credits (`creditUsagePercent`) — NOT the per-session
//  context window fill (that still lives on GrokSession for the session card).
//

import Foundation
import Combine

final class GrokUsage: ObservableObject {

    /// Latest billing snapshot, or nil when it could not be fetched.
    @Published private(set) var current: GrokUsageInfo?

    /// True when ~/.grok/auth.json has usable OIDC credentials.
    @Published private(set) var isAuthenticated = false

    var pollInterval: TimeInterval = 300
    var minFetchInterval: TimeInterval = 60
    var maxStaleness: TimeInterval = 1800

    private var lastSuccess: Date = .distantPast
    private var lastAttempt: Date = .distantPast

    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?
    private var cachedClientID: String?
    private var cachedIssuer: String?
    private var cachedUserID: String?

    private let urlSession: URLSession
    private let queue = DispatchQueue(label: "com.agentcord.grok-usage", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Must match Grok CLI / Orca: credits format returns `creditUsagePercent`.
    private static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let cliAuthHeader = "xai-grok-cli"

    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AgentCord", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("grok-usage-cache.json")
    }()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        urlSession = URLSession(configuration: config)

        if let cached = Self.loadCache(), Date().timeIntervalSince(cached.fetchedAt) <= maxStaleness {
            current = cached.info
            lastSuccess = cached.fetchedAt
        }
        isAuthenticated = Self.readAuthFile() != nil
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        let firstDelay: TimeInterval = (current != nil) ? 5 : 2
        t.schedule(deadline: .now() + firstDelay, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.fetch() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

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
        loadCredentialsFromDiskIfNeeded()

        guard cachedAccessToken != nil || cachedRefreshToken != nil else {
            publishAuth(false)
            handleFailure()
            return
        }
        publishAuth(true)
        requestBilling(allowRefresh: true)
    }

    private func requestBilling(allowRefresh: Bool) {
        guard let access = cachedAccessToken, !access.isEmpty else {
            if allowRefresh {
                refreshAccessToken { [weak self] ok in
                    guard let self else { return }
                    if ok { self.requestBilling(allowRefresh: false) }
                    else { self.handleFailure() }
                }
            } else {
                handleFailure()
            }
            return
        }

        var request = URLRequest(url: Self.billingURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.cliAuthHeader, forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("GrokCLI", forHTTPHeaderField: "User-Agent")
        if let userID = cachedUserID, !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "x-userid")
        }

        urlSession.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            self.queue.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if status == 401, allowRefresh {
                    self.refreshAccessToken { [weak self] ok in
                        guard let self else { return }
                        if ok { self.requestBilling(allowRefresh: false) }
                        else { self.handleFailure() }
                    }
                    return
                }
                guard status == 200, let data,
                      let decoded = try? JSONDecoder().decode(BillingResponse.self, from: data),
                      let info = decoded.toUsageInfo() else {
                    self.handleFailure()
                    return
                }
                self.lastSuccess = Date()
                Self.saveCache(info, fetchedAt: self.lastSuccess)
                self.publish(info)
            }
        }.resume()
    }

    private func refreshAccessToken(completion: @escaping (Bool) -> Void) {
        guard let refresh = cachedRefreshToken, !refresh.isEmpty,
              let clientID = cachedClientID, !clientID.isEmpty else {
            completion(false)
            return
        }

        let issuer = (cachedIssuer?.isEmpty == false) ? cachedIssuer! : "https://auth.x.ai"
        guard let url = URL(string: issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/oauth2/token") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID
        ]
        .map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
        }
        .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        urlSession.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            self.queue.async {
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let access = obj["access_token"] as? String, !access.isEmpty else {
                    completion(false)
                    return
                }
                self.cachedAccessToken = access
                if let newRefresh = obj["refresh_token"] as? String, !newRefresh.isEmpty {
                    self.cachedRefreshToken = newRefresh
                }
                completion(true)
            }
        }.resume()
    }

    private func handleFailure() {
        if Date().timeIntervalSince(lastSuccess) > maxStaleness {
            Self.clearCache()
            publish(nil)
        }
    }

    private func publish(_ info: GrokUsageInfo?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.current != info { self.current = info }
        }
    }

    private func publishAuth(_ authenticated: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isAuthenticated != authenticated { self.isAuthenticated = authenticated }
        }
    }

    // MARK: Credentials

    private func loadCredentialsFromDiskIfNeeded() {
        guard let auth = Self.readAuthFile() else {
            cachedAccessToken = nil
            cachedRefreshToken = nil
            cachedClientID = nil
            cachedIssuer = nil
            cachedUserID = nil
            return
        }
        cachedRefreshToken = auth.refreshToken
        cachedClientID = auth.clientID
        cachedIssuer = auth.issuer
        cachedUserID = auth.userID
        if let access = auth.accessToken, !access.isEmpty {
            cachedAccessToken = access
        }
    }

    private struct AuthTokens {
        var accessToken: String?
        var refreshToken: String?
        var clientID: String?
        var issuer: String?
        var userID: String?
    }

    private static func authFileURL() -> URL? {
        if let env = ProcessInfo.processInfo.environment["GROK_HOME"], !env.isEmpty {
            let url = URL(fileURLWithPath: env, isDirectory: true)
                .appendingPathComponent("auth.json")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
        return FileManager.default.fileExists(atPath: home.path) ? home : nil
    }

    /// auth.json is a map of account-key → credential object.
    private static func readAuthFile() -> AuthTokens? {
        guard let url = authFileURL(),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Prefer the first object that looks like an OIDC credential entry.
        for (_, value) in root {
            guard let obj = value as? [String: Any] else { continue }
            let access = obj["key"] as? String
            let refresh = obj["refresh_token"] as? String
            if (access == nil || access?.isEmpty == true),
               (refresh == nil || refresh?.isEmpty == true) {
                continue
            }
            return AuthTokens(
                accessToken: access,
                refreshToken: refresh,
                clientID: obj["oidc_client_id"] as? String,
                issuer: obj["oidc_issuer"] as? String,
                userID: obj["user_id"] as? String
            )
        }
        return nil
    }

    // MARK: Disk cache

    private struct CachePayload: Codable {
        var fetchedAt: Date
        var info: GrokUsageInfo
    }

    private static func loadCache() -> CachePayload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(CachePayload.self, from: data)
    }

    private static func saveCache(_ info: GrokUsageInfo, fetchedAt: Date) {
        let payload = CachePayload(fetchedAt: fetchedAt, info: info)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }
}

// MARK: - Models

/// Grok weekly subscription credit usage (CLI / SuperGrok billing).
struct GrokUsageInfo: Equatable, Codable {
    /// Weekly included credits window (`creditUsagePercent`).
    var weekly: UsageInfo.Window
    /// On-demand window when a cap is set.
    var onDemand: UsageInfo.Window?
    var billingPeriodStart: Date?
    var billingPeriodEnd: Date?
}

// MARK: - Wire format

private struct BillingResponse: Decodable {
    struct MoneyVal: Decodable {
        let val: Double?
    }

    struct Period: Decodable {
        let type: String?
        let start: String?
        let end: String?
    }

    struct Config: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: Period?
        let onDemandCap: MoneyVal?
        let onDemandUsed: MoneyVal?
        let billingPeriodStart: String?
        let billingPeriodEnd: String?
    }

    let config: Config?
    /// Some responses flatten credit fields at the top level.
    let creditUsagePercent: Double?

    func toUsageInfo() -> GrokUsageInfo? {
        let cfg = config
        let percentRaw = cfg?.creditUsagePercent ?? creditUsagePercent
        guard let percentRaw, percentRaw.isFinite else { return nil }

        let percent = min(100, max(0, Int(percentRaw.rounded())))
        let periodEnd = Self.parseISO(cfg?.currentPeriod?.end ?? cfg?.billingPeriodEnd)
        let periodStart = Self.parseISO(cfg?.currentPeriod?.start ?? cfg?.billingPeriodStart)

        let weekly = UsageInfo.Window(
            percent: percent,
            severity: Self.severity(for: percent),
            resetsAt: periodEnd
        )

        var onDemand: UsageInfo.Window?
        if let cap = cfg?.onDemandCap?.val, cap > 0 {
            let odUsed = cfg?.onDemandUsed?.val ?? 0
            let odPercent = min(100, max(0, Int((odUsed / cap * 100).rounded())))
            onDemand = UsageInfo.Window(
                percent: odPercent,
                severity: Self.severity(for: odPercent),
                resetsAt: periodEnd
            )
        }

        return GrokUsageInfo(
            weekly: weekly,
            onDemand: onDemand,
            billingPeriodStart: periodStart,
            billingPeriodEnd: periodEnd
        )
    }

    private static func severity(for percent: Int) -> String {
        if percent >= 95 { return "critical" }
        if percent >= 80 { return "warning" }
        return "normal"
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

    private static func parseISO(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}
