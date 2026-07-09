//
//  CursorUsage.swift
//  AgentCord
//
//  Polls the user's Cursor subscription usage limits — the included spend for
//  the current billing period (Pro/Team/Ultra) or request buckets (legacy
//  Enterprise).
//
//  These numbers are not in local project files. They come from undocumented
//  endpoints that the Cursor app itself calls. We reuse Cursor's own access
//  token (read from state.vscdb) and hit the same endpoints. Everything here
//  is best-effort: any failure (no token, expired token, endpoint changed) just
//  leaves `current` nil, so the popover hides the Cursor rows rather than
//  showing something wrong.
//

import Foundation
import Combine

final class CursorUsage: ObservableObject {

    /// The latest usage snapshot, or nil when it could not be fetched.
    @Published private(set) var current: CursorUsageInfo?

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

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        urlSession = URLSession(configuration: config)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: pollInterval)
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
            handleFailure()
            return
        }

        fetchPeriodUsage(token: token) { [weak self] info in
            guard let self else { return }
            if let info {
                self.lastSuccess = Date()
                self.publish(info)
            } else {
                self.fetchLegacyUsage(token: token) { [weak self] legacy in
                    guard let self else { return }
                    if let legacy {
                        self.lastSuccess = Date()
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
            publish(nil)
        }
    }

    private func publish(_ info: CursorUsageInfo?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.current != info { self.current = info }
        }
    }

    // MARK: Token

    /// Reads Cursor's OAuth access token from the local SQLite state database.
    /// The database is opened read-only via the `sqlite3` CLI so we don't need
    /// to link libsqlite3 or hold a long-lived handle on Cursor's store.
    private static func readAccessToken() -> String? {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: dbPath.path) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            dbPath.path,
            "SELECT value FROM ItemTable WHERE key = '\(accessTokenKey)';"
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
}

// MARK: - Wire format

private struct PeriodUsageResponse: Decodable {

    struct PlanUsage: Decodable {
        let totalSpend: Int?
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

    let billingCycleEnd: String?
    let planUsage: PlanUsage?
    let spendLimitUsage: SpendLimitUsage?

    func toUsageInfo() -> CursorUsageInfo? {
        guard let plan = planUsage, plan.limit != nil || plan.totalPercentUsed != nil else {
            return nil
        }

        let totalPercent = Int((plan.totalPercentUsed ?? 0).rounded())
        let resetsAt = Self.parseEpochMillis(billingCycleEnd)
        let detail = Self.dollarDetail(usedCents: plan.totalSpend, limitCents: plan.limit)

        var auto: CursorUsageInfo.Window?
        if let autoPercent = plan.autoPercentUsed,
           Int(autoPercent.rounded()) != totalPercent,
           autoPercent > 0 {
            auto = Self.makeWindow(percent: Int(autoPercent.rounded()), resetsAt: resetsAt)
        }

        var api: CursorUsageInfo.Window?
        if let apiPercent = plan.apiPercentUsed,
           Int(apiPercent.rounded()) != totalPercent,
           apiPercent > 0 {
            api = Self.makeWindow(percent: Int(apiPercent.rounded()), resetsAt: resetsAt)
        }

        var onDemand: CursorUsageInfo.Window?
        if let limit = spendLimitUsage?.individualLimit, limit > 0 {
            let remaining = spendLimitUsage?.individualRemaining ?? limit
            let used = max(0, limit - remaining)
            let percent = Int((Double(used) / Double(limit) * 100).rounded())
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
        return Date(timeIntervalSince1970: millis / 1000)
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
            } else {
                buckets[key.stringValue] = try container.decode(Bucket.self, forKey: key)
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
        let percent = Int((Double(best.used) / Double(best.max) * 100).rounded())
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
