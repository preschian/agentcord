//
//  CodexUsage.swift
//  AgentCord
//
//  Polls ChatGPT / Codex subscription rate limits (5-hour + weekly windows)
//  using the OAuth tokens Codex CLI stores in ~/.codex/auth.json.
//
//  Endpoint: GET https://chatgpt.com/backend-api/wham/usage
//  Auth:     Bearer access_token + ChatGPT-Account-Id
//  Refresh:  POST https://auth.openai.com/oauth/token (Codex CLI client_id)
//
//  Best-effort: missing auth, expired refresh, or a moved endpoint just leaves
//  `current` nil (or the last cached snapshot while still fresh).
//

import Foundation
import Combine

final class CodexUsage: ObservableObject {

    /// Latest usage snapshot, or nil when it could not be fetched.
    @Published private(set) var current: CodexUsageInfo?

    /// True when ~/.codex/auth.json has ChatGPT OAuth tokens we can use.
    @Published private(set) var isAuthenticated = false

    var pollInterval: TimeInterval = 300
    var minFetchInterval: TimeInterval = 60
    var maxStaleness: TimeInterval = 1800

    private var lastSuccess: Date = .distantPast
    private var lastAttempt: Date = .distantPast

    /// In-memory access token after a refresh. Not written back to auth.json so
    /// we never race Codex CLI's own credential writer.
    private var cachedAccessToken: String?
    private var cachedAccountID: String?
    private var cachedRefreshToken: String?

    private let urlSession: URLSession
    private let queue = DispatchQueue(label: "com.agentcord.codex-usage", qos: .utility)
    private var timer: DispatchSourceTimer?

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// Public Codex CLI OAuth client id (same one `codex login` uses).
    private static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AgentCord", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("codex-usage-cache.json")
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
        isAuthenticated = Self.authFileURL() != nil && Self.readAuthFile() != nil
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

        requestUsage(allowRefresh: true)
    }

    private func requestUsage(allowRefresh: Bool) {
        guard let access = cachedAccessToken else {
            if allowRefresh {
                refreshAccessToken { [weak self] ok in
                    guard let self else { return }
                    if ok { self.requestUsage(allowRefresh: false) }
                    else { self.handleFailure() }
                }
            } else {
                handleFailure()
            }
            return
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        if let account = cachedAccountID, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        urlSession.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            self.queue.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if status == 401, allowRefresh {
                    self.refreshAccessToken { [weak self] ok in
                        guard let self else { return }
                        if ok { self.requestUsage(allowRefresh: false) }
                        else { self.handleFailure() }
                    }
                    return
                }
                guard status == 200, let data,
                      let decoded = try? JSONDecoder().decode(WhamUsageResponse.self, from: data),
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
        guard let refresh = cachedRefreshToken, !refresh.isEmpty else {
            completion(false)
            return
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": Self.oauthClientID
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

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

    private func publish(_ info: CodexUsageInfo?) {
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
        // Always re-read auth.json so a mid-session `codex login` is picked up.
        // Prefer a freshly written disk token; keep an in-memory refresh result
        // only when the file is missing the access token.
        guard let auth = Self.readAuthFile() else {
            cachedAccessToken = nil
            cachedRefreshToken = nil
            cachedAccountID = nil
            return
        }
        cachedAccountID = auth.accountID
        cachedRefreshToken = auth.refreshToken
        // If disk still has a non-empty access token, use it (Codex may have
        // refreshed more recently than we have). Otherwise keep our memory token.
        if let diskAccess = auth.accessToken, !diskAccess.isEmpty {
            cachedAccessToken = diskAccess
        }
    }

    private struct AuthTokens {
        var accessToken: String?
        var refreshToken: String?
        var accountID: String?
    }

    private static func authFileURL() -> URL? {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            let url = URL(fileURLWithPath: env, isDirectory: true)
                .appendingPathComponent("auth.json")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        return FileManager.default.fileExists(atPath: home.path) ? home : nil
    }

    private static func readAuthFile() -> AuthTokens? {
        guard let url = authFileURL(),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Shape: { "tokens": { "access_token", "refresh_token", "account_id" } }
        let tokens = (obj["tokens"] as? [String: Any]) ?? obj
        let access = tokens["access_token"] as? String
        let refresh = tokens["refresh_token"] as? String
        let account = tokens["account_id"] as? String
        if (access == nil || access?.isEmpty == true),
           (refresh == nil || refresh?.isEmpty == true) {
            return nil
        }
        return AuthTokens(accessToken: access, refreshToken: refresh, accountID: account)
    }

    // MARK: Disk cache

    private struct CachePayload: Codable {
        var fetchedAt: Date
        var info: CodexUsageInfo
    }

    private static func loadCache() -> CachePayload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(CachePayload.self, from: data)
    }

    private static func saveCache(_ info: CodexUsageInfo, fetchedAt: Date) {
        let payload = CachePayload(fetchedAt: fetchedAt, info: info)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }
}

// MARK: - Wire format

private struct WhamUsageResponse: Decodable {
    struct RateLimit: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Int?
            let reset_after_seconds: Int?
            let reset_at: Double?
        }

        let primary_window: Window?
        let secondary_window: Window?
        let limit_reached: Bool?
    }

    let plan_type: String?
    let rate_limit: RateLimit?

    func toUsageInfo() -> CodexUsageInfo? {
        guard let primary = rate_limit?.primary_window else { return nil }
        let primaryWindow = Self.makeWindow(primary, limitReached: rate_limit?.limit_reached == true)
        let primaryLabel = Self.label(forSeconds: primary.limit_window_seconds, fallback: "Primary limit")

        var secondary: UsageInfo.Window?
        var secondaryLabel: String?
        if let sec = rate_limit?.secondary_window {
            secondary = Self.makeWindow(sec, limitReached: false)
            secondaryLabel = Self.label(forSeconds: sec.limit_window_seconds, fallback: "Secondary limit")
        }

        return CodexUsageInfo(
            primary: primaryWindow,
            primaryLabel: primaryLabel,
            secondary: secondary,
            secondaryLabel: secondaryLabel,
            planType: plan_type
        )
    }

    private static func makeWindow(_ w: RateLimit.Window, limitReached: Bool) -> UsageInfo.Window {
        let percent = min(100, max(0, Int((w.used_percent ?? 0).rounded())))
        let severity: String
        if limitReached || percent >= 90 { severity = "critical" }
        else if percent >= 70 { severity = "warning" }
        else { severity = "normal" }

        var resetsAt: Date?
        if let reset = w.reset_at {
            // API returns unix seconds (sometimes fractional).
            resetsAt = Date(timeIntervalSince1970: reset)
        } else if let after = w.reset_after_seconds {
            resetsAt = Date().addingTimeInterval(TimeInterval(after))
        }

        return UsageInfo.Window(percent: percent, severity: severity, resetsAt: resetsAt)
    }

    private static func label(forSeconds seconds: Int?, fallback: String) -> String {
        guard let seconds, seconds > 0 else { return fallback }
        // ~5 hours (Codex Plus/Pro primary window)
        if seconds <= 6 * 3600 { return "5-hour session" }
        // ~7 days
        if seconds <= 8 * 24 * 3600 { return "Weekly limit" }
        // ~30 days (free-plan primary window observed)
        if seconds <= 40 * 24 * 3600 { return "Monthly limit" }
        return fallback
    }
}
