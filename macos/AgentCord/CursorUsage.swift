//
//  CursorUsage.swift
//  AgentCord
//
//  Polls the user's Cursor subscription usage limits — included spend for the
//  current billing period (Pro/Team/Ultra) or request buckets (legacy).
//
//  Numbers come from undocumented endpoints the Cursor app itself calls. We
//  reuse Cursor's access token from state.vscdb and hit the same endpoints.
//  Best-effort: missing token / expired auth / endpoint change leaves `current`
//  nil (or the last cached snapshot while still fresh).
//

import Foundation
import Combine

final class CursorUsage: ObservableObject {

    /// Latest usage snapshot, or nil when it could not be fetched.
    @Published private(set) var current: CursorUsageInfo?

    /// True when a Cursor access token is present in the local state DB.
    @Published private(set) var isAuthenticated = false

    var pollInterval: TimeInterval = 300
    var minFetchInterval: TimeInterval = 60
    var maxStaleness: TimeInterval = 1800

    private var lastSuccess: Date = .distantPast
    private var lastAttempt: Date = .distantPast

    private let urlSession: URLSession
    private let queue = DispatchQueue(label: "com.agentcord.cursor-usage", qos: .utility)
    private var timer: DispatchSourceTimer?

    private static let periodUsageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!
    private static let legacyUsageURL = URL(string: "https://api2.cursor.sh/auth/usage")!
    private static let accessTokenKey = "cursorAuth/accessToken"
    private static let membershipKey = "cursorAuth/stripeMembershipType"

    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AgentCord", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cursor-usage-cache.json")
    }()

    private static var stateDBPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        urlSession = URLSession(configuration: config)

        if let cached = Self.loadCache(), Date().timeIntervalSince(cached.fetchedAt) <= maxStaleness {
            current = cached.info
            lastSuccess = cached.fetchedAt
        }
        isAuthenticated = Self.readAccessToken() != nil
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
        guard let token = Self.readAccessToken() else {
            publishAuth(false)
            handleFailure()
            return
        }
        publishAuth(true)

        let membership = Self.readMembershipType()

        fetchPeriodUsage(token: token) { [weak self] info in
            guard let self else { return }
            if var info {
                if info.planName == nil { info.planName = membership }
                self.lastSuccess = Date()
                Self.saveCache(info, fetchedAt: self.lastSuccess)
                self.publish(info)
            } else {
                self.fetchLegacyUsage(token: token) { [weak self] legacy in
                    guard let self else { return }
                    if var legacy {
                        if legacy.planName == nil { legacy.planName = membership }
                        self.lastSuccess = Date()
                        Self.saveCache(legacy, fetchedAt: self.lastSuccess)
                        self.publish(legacy)
                    } else {
                        self.handleFailure()
                    }
                }
            }
        }
    }

    private func fetchPeriodUsage(token: String, completion: @escaping (CursorUsageInfo?) -> Void) {
        var request = URLRequest(url: Self.periodUsageURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("AgentCord", forHTTPHeaderField: "User-Agent")

        urlSession.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            self.queue.async {
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let decoded = try? JSONDecoder().decode(PeriodUsageResponse.self, from: data),
                      let info = decoded.toUsageInfo() else {
                    completion(nil)
                    return
                }
                completion(info)
            }
        }.resume()
    }

    private func fetchLegacyUsage(token: String, completion: @escaping (CursorUsageInfo?) -> Void) {
        var request = URLRequest(url: Self.legacyUsageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("AgentCord", forHTTPHeaderField: "User-Agent")

        urlSession.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            self.queue.async {
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let decoded = try? JSONDecoder().decode(LegacyUsageResponse.self, from: data),
                      let info = decoded.toUsageInfo() else {
                    completion(nil)
                    return
                }
                completion(info)
            }
        }.resume()
    }

    private func handleFailure() {
        if Date().timeIntervalSince(lastSuccess) > maxStaleness {
            Self.clearCache()
            publish(nil)
        }
    }

    private func publish(_ info: CursorUsageInfo?) {
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

    // MARK: Token

    /// Reads Cursor's OAuth access token from the local SQLite state database
    /// via the `sqlite3` CLI (read-only, no libsqlite link).
    private static func readAccessToken() -> String? {
        readStateValue(forKey: accessTokenKey)
    }

    private static func readMembershipType() -> String? {
        readStateValue(forKey: membershipKey)
    }

    private static func readStateValue(forKey key: String) -> String? {
        guard FileManager.default.fileExists(atPath: stateDBPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        // Quote the key safely for SQL (keys are fixed app constants).
        let escaped = key.replacingOccurrences(of: "'", with: "''")
        process.arguments = [
            stateDBPath,
            "SELECT value FROM ItemTable WHERE key = '\(escaped)';"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    // MARK: Disk cache

    private struct CachePayload: Codable {
        var fetchedAt: Date
        var info: CursorUsageInfo
    }

    private static func loadCache() -> CachePayload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(CachePayload.self, from: data)
    }

    private static func saveCache(_ info: CursorUsageInfo, fetchedAt: Date) {
        let payload = CachePayload(fetchedAt: fetchedAt, info: info)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }
}

// MARK: - Wire format

private struct PeriodUsageResponse: Decodable {

    struct PlanUsage: Decodable {
        let totalSpend: Int?
        let includedSpend: Int?
        let limit: Int?
        let remaining: Int?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }

    struct SpendLimitUsage: Decodable {
        let individualLimit: Int?
        let individualRemaining: Int?
    }

    /// API sometimes returns millis as a JSON string, sometimes as a number.
    let billingCycleEnd: FlexibleString?
    let planUsage: PlanUsage?
    let spendLimitUsage: SpendLimitUsage?
    let displayMessage: String?

    func toUsageInfo() -> CursorUsageInfo? {
        guard let plan = planUsage else { return nil }
        guard plan.limit != nil || plan.totalPercentUsed != nil || plan.includedSpend != nil else {
            return nil
        }

        let totalPercent: Int
        if let p = plan.totalPercentUsed {
            totalPercent = min(100, max(0, Int(p.rounded())))
        } else if let limit = plan.limit, limit > 0, let used = plan.includedSpend ?? plan.totalSpend {
            totalPercent = min(100, max(0, Int((Double(used) / Double(limit) * 100).rounded())))
        } else {
            return nil
        }

        let resetsAt = Self.parseEpochMillis(billingCycleEnd?.value)
        let detail = Self.dollarDetail(usedCents: plan.totalSpend, limitCents: plan.limit)

        var auto: CursorUsageInfo.Window?
        if let autoPercent = plan.autoPercentUsed {
            let pct = min(100, max(0, Int(autoPercent.rounded())))
            if pct != totalPercent, autoPercent > 0 {
                auto = Self.makeWindow(percent: pct, resetsAt: resetsAt)
            }
        }

        var api: CursorUsageInfo.Window?
        if let apiPercent = plan.apiPercentUsed {
            let pct = min(100, max(0, Int(apiPercent.rounded())))
            if pct != totalPercent, apiPercent > 0 {
                api = Self.makeWindow(percent: pct, resetsAt: resetsAt)
            }
        }

        var onDemand: CursorUsageInfo.Window?
        if let limit = spendLimitUsage?.individualLimit, limit > 0 {
            let remaining = spendLimitUsage?.individualRemaining ?? limit
            let used = max(0, limit - remaining)
            let percent = min(100, max(0, Int((Double(used) / Double(limit) * 100).rounded())))
            onDemand = Self.makeWindow(
                percent: percent,
                resetsAt: resetsAt,
                detail: String(format: "$%.2f / $%.2f", Double(used) / 100, Double(limit) / 100)
            )
        }

        return CursorUsageInfo(
            included: Self.makeWindow(percent: totalPercent, resetsAt: resetsAt, detail: detail),
            auto: auto,
            api: api,
            onDemand: onDemand,
            planName: nil
        )
    }

    private static func makeWindow(
        percent: Int,
        resetsAt: Date?,
        detail: String? = nil
    ) -> CursorUsageInfo.Window {
        CursorUsageInfo.Window(
            percent: percent,
            severity: severity(for: percent),
            resetsAt: resetsAt,
            detail: detail
        )
    }

    private static func dollarDetail(usedCents: Int?, limitCents: Int?) -> String? {
        guard let used = usedCents, let limit = limitCents, limit > 0 else { return nil }
        return String(format: "$%.2f / $%.2f", Double(used) / 100, Double(limit) / 100)
    }

    private static func severity(for percent: Int) -> String {
        if percent >= 95 { return "critical" }
        if percent >= 80 { return "warning" }
        return "normal"
    }

    private static func parseEpochMillis(_ raw: String?) -> Date? {
        guard let raw, let millis = Double(raw) else { return nil }
        // Accept seconds or milliseconds.
        let seconds = millis > 1_000_000_000_000 ? millis / 1000 : millis
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Decodes a JSON string or number into a String.
private struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            value = s
        } else if let i = try? container.decode(Int64.self) {
            value = String(i)
        } else if let d = try? container.decode(Double.self) {
            value = String(Int64(d))
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected string or number")
            )
        }
    }
}

private struct LegacyUsageResponse: Decodable {

    struct Bucket: Decodable {
        let numRequests: Int?
        let maxRequestUsage: Int?
    }

    let startOfMonth: String?
    let buckets: [String: Bucket]

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var buckets: [String: Bucket] = [:]
        var startOfMonth: String?
        for key in container.allKeys {
            if key.stringValue == "startOfMonth" {
                startOfMonth = try container.decode(String.self, forKey: key)
            } else if let bucket = try? container.decode(Bucket.self, forKey: key) {
                buckets[key.stringValue] = bucket
            }
        }
        self.startOfMonth = startOfMonth
        self.buckets = buckets
    }

    func toUsageInfo() -> CursorUsageInfo? {
        var best: (key: String, used: Int, max: Int)?
        for (key, bucket) in buckets {
            guard let max = bucket.maxRequestUsage, max > 0 else { continue }
            let used = bucket.numRequests ?? 0
            if best == nil || max > best!.max {
                best = (key, used, max)
            }
        }

        guard let best else { return nil }
        let percent = min(100, max(0, Int((Double(best.used) / Double(best.max) * 100).rounded())))
        let resetsAt = Self.parseMonthStart(startOfMonth)
        return CursorUsageInfo(
            included: CursorUsageInfo.Window(
                percent: percent,
                severity: percent >= 95 ? "critical" : (percent >= 80 ? "warning" : "normal"),
                resetsAt: resetsAt,
                detail: "\(best.used)/\(best.max) requests"
            ),
            auto: nil,
            api: nil,
            onDemand: nil,
            planName: best.key
        )
    }

    private static func parseMonthStart(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }
}
