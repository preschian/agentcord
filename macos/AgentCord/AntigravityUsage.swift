//
//  AntigravityUsage.swift
//  AgentCord
//
//  Polls Antigravity CLI 5-hour and weekly usage via
//  `agy -p "/usage" --output-format json` at most every 5 minutes.
//  Falls back to rolling transcript token estimation if `agy` cannot be run.
//

import Foundation
import Combine

final class AntigravityUsage: ObservableObject {

    /// Latest billing/usage snapshot, or nil when it could not be fetched.
    @Published private(set) var current: AntigravityUsageInfo?

    /// True when the user is signed in to Google / Antigravity.
    @Published private(set) var isAuthenticated = false

    /// Email of the signed-in Google account.
    @Published private(set) var accountEmail: String?

    var pollInterval: TimeInterval = 300
    var minFetchInterval: TimeInterval = 60
    /// How long a disk-cached snapshot may still be shown after the last
    /// successful fetch (24h).
    var maxStaleness: TimeInterval = 86_400

    private var lastSuccess: Date = .distantPast
    private var lastAttempt: Date = .distantPast

    private let baseDir: URL
    private let queue = DispatchQueue(label: "com.agentcord.antigravity-usage", qos: .utility)
    private var timer: DispatchSourceTimer?

    private static let defaultFiveHourCapacity: Double = 500_000
    private static let defaultWeeklyCapacity: Double = 4_500_000

    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AgentCord", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("antigravity-usage-cache.json")
    }()

    private struct StepRecord {
        var date: Date
        var tokens: Int
    }
    private var fileStepsCache: [URL: (mtime: Date, steps: [StepRecord])] = [:]

    init(baseDir: URL? = nil) {
        self.baseDir = AntigravitySession.resolveBaseDir(custom: baseDir)

        if let cached = Self.loadCache(), Date().timeIntervalSince(cached.fetchedAt) <= maxStaleness {
            current = cached.info
            accountEmail = cached.email
            lastSuccess = cached.fetchedAt
        }
        isAuthenticated = AntigravitySession.readAuthenticated(baseDir: self.baseDir)
    }

    func start() {
        guard timer == nil else { return }
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
        let now = Date()
        guard now.timeIntervalSince(lastAttempt) >= minFetchInterval else { return }
        lastAttempt = now

        let (email, plan) = scanAccountAndPlan()
        let auth = (email != nil) || AntigravitySession.readAuthenticated(baseDir: baseDir)
        publishAuth(auth)
        publishEmail(email)

        let planLabel = plan ?? "Google AI Pro"

        // 1. Try official CLI JSON
        if let agyExe = Self.findAgyExecutable(customHome: baseDir),
           let json = Self.queryOfficialAgyUsage(executable: agyExe),
           let info = Self.parseAgyUsageJson(json, planLabel: planLabel) {
            lastSuccess = Date()
            Self.saveCache(info, fetchedAt: lastSuccess, email: email)
            publish(info)
            return
        }

        // 2. Fallback to rolling transcript token estimation
        if let fallback = computeFallbackUsage(planLabel: planLabel) {
            lastSuccess = Date()
            Self.saveCache(fallback, fetchedAt: lastSuccess, email: email)
            publish(fallback)
            return
        }

        handleFailure()
    }

    private func handleFailure() {
        if Date().timeIntervalSince(lastSuccess) > maxStaleness {
            Self.clearCache()
            publish(nil)
        }
    }

    private func publish(_ info: AntigravityUsageInfo?) {
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

    private func publishEmail(_ email: String?) {
        let cleaned = (email?.isEmpty == false) ? email : nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.accountEmail != cleaned { self.accountEmail = cleaned }
        }
    }

    // MARK: Binary execution

    static func findAgyExecutable(customHome: URL? = nil) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let localBin = home.appendingPathComponent(".local/bin/agy").path
        if FileManager.default.isExecutableFile(atPath: localBin) { return localBin }

        let geminiHome = customHome ?? home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        let geminiBin = geminiHome.appendingPathComponent("bin/agy").path
        if FileManager.default.isExecutableFile(atPath: geminiBin) { return geminiBin }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("agy").path
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    static func queryOfficialAgyUsage(executable: String, timeout: TimeInterval = 7.0) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", "/usage", "--output-format", "json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        var outputData = Data()
        let group = DispatchGroup()
        group.enter()

        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            outputData = data
            group.leave()
        }

        let result = group.wait(timeout: .now() + timeout)
        if result == .timedOut {
            process.terminate()
            let pid = process.processIdentifier
            if pid > 0 {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0, !outputData.isEmpty else { return nil }
        return String(data: outputData, encoding: .utf8)
    }

    // MARK: Parsing official JSON

    static func parseAgyUsageJson(_ jsonString: String, planLabel: String = "Google AI Pro") -> AntigravityUsageInfo? {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = root["command"] as? [String: Any],
              let cmdData = cmd["data"] as? [String: Any],
              let groups = cmdData["groups"] as? [[String: Any]]
        else { return nil }

        var fiveHour: UsageInfo.Window?
        var weekly: UsageInfo.Window?

        for group in groups {
            let groupName = group["name"] as? String
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }

            for bucket in buckets {
                let window = bucket["window"] as? String
                let remainingFraction: Double = {
                    if let n = bucket["remaining_fraction"] as? Double { return n }
                    if let n = bucket["remaining_fraction"] as? Int { return Double(n) }
                    return 1.0
                }()
                let resetTime = bucket["reset_time"] as? String

                let usedFraction = max(0.0, min(1.0, 1.0 - remainingFraction))
                let percent = Int((usedFraction * 100.0).rounded())
                let resetDate = parseISO(resetTime)

                let usageWindow = UsageInfo.Window(
                    percent: percent,
                    severity: severityFor(percent),
                    resetsAt: resetDate
                )

                let isGeminiGroup = groupName?.localizedCaseInsensitiveContains("Gemini") == true
                let bucketId = (bucket["id"] as? String) ?? ""

                if isGeminiGroup || fiveHour == nil {
                    if window == "5h" || bucketId.localizedCaseInsensitiveContains("5h") {
                        fiveHour = usageWindow
                    } else if window == "weekly" || bucketId.localizedCaseInsensitiveContains("weekly") {
                        weekly = usageWindow
                    }
                }
            }
        }

        guard fiveHour != nil || weekly != nil else { return nil }

        return AntigravityUsageInfo(
            fiveHour: fiveHour ?? UsageInfo.Window(percent: 0, severity: "normal", resetsAt: nil),
            weekly: weekly ?? UsageInfo.Window(percent: 0, severity: "normal", resetsAt: nil),
            planName: planLabel
        )
    }

    private static func severityFor(_ percent: Int) -> String {
        if percent >= 90 { return "critical" }
        if percent >= 70 { return "warning" }
        return "normal"
    }

    // MARK: Fallback estimation

    private func computeFallbackUsage(planLabel: String) -> AntigravityUsageInfo? {
        let (exhausted, exhaustResetsAt) = scanQuotaExhaustion()
        let now = Date()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86400)

        let steps = scanAllSteps()

        var fiveHourTokens = 0
        var oldestInFiveHour: Date?
        var weeklyTokens = 0
        var oldestInWeekly: Date?

        for step in steps {
            if step.date >= fiveHoursAgo {
                fiveHourTokens += step.tokens
                if oldestInFiveHour == nil || step.date < oldestInFiveHour! {
                    oldestInFiveHour = step.date
                }
            }
            if step.date >= sevenDaysAgo {
                weeklyTokens += step.tokens
                if oldestInWeekly == nil || step.date < oldestInWeekly! {
                    oldestInWeekly = step.date
                }
            }
        }

        let fiveHourPercent = min(100, max(0, Int(round(Double(fiveHourTokens) / Self.defaultFiveHourCapacity * 100.0))))
        let fiveHourResetsAt = oldestInFiveHour?.addingTimeInterval(5 * 3600) ?? now.addingTimeInterval(5 * 3600)
        let fiveHour = UsageInfo.Window(
            percent: fiveHourPercent,
            severity: Self.severityFor(fiveHourPercent),
            resetsAt: fiveHourResetsAt
        )

        let weeklyPercent = exhausted ? 100 : min(100, max(0, Int(round(Double(weeklyTokens) / Self.defaultWeeklyCapacity * 100.0))))
        let weeklyResetsAt = exhaustResetsAt ?? (oldestInWeekly?.addingTimeInterval(7 * 86400) ?? now.addingTimeInterval(7 * 86400))
        let weekly = UsageInfo.Window(
            percent: weeklyPercent,
            severity: exhausted ? "critical" : Self.severityFor(weeklyPercent),
            resetsAt: weeklyResetsAt
        )

        return AntigravityUsageInfo(
            fiveHour: fiveHour,
            weekly: weekly,
            planName: planLabel
        )
    }

    private func scanAllSteps() -> [StepRecord] {
        let brain = baseDir.appendingPathComponent("brain", isDirectory: true)
        guard FileManager.default.fileExists(atPath: brain.path) else { return [] }

        var transcriptURLs: [URL] = []
        let fm = FileManager.default
        if let convDirs = try? fm.contentsOfDirectory(at: brain, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for conv in convDirs where conv.isDirectory {
                let transcript = conv.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                if fm.fileExists(atPath: transcript.path) {
                    transcriptURLs.append(transcript)
                }
            }
        }

        var results: [StepRecord] = []
        for url in transcriptURLs {
            guard let mtime = url.resourceModificationDate else { continue }
            if let cached = fileStepsCache[url], cached.mtime == mtime {
                results.append(contentsOf: cached.steps)
                continue
            }
            let steps = parseTranscriptSteps(url)
            fileStepsCache[url] = (mtime, steps)
            results.append(contentsOf: steps)
        }

        let liveSet = Set(transcriptURLs)
        fileStepsCache = fileStepsCache.filter { liveSet.contains($0.key) }
        return results
    }

    private func parseTranscriptSteps(_ url: URL) -> [StepRecord] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var steps: [StepRecord] = []
        for line in text.components(separatedBy: .newlines) {
            guard line.count >= 10,
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let createdAt = obj["created_at"] as? String,
                  let date = Self.parseISO(createdAt)
            else { continue }

            var len = 0
            if let c = obj["content"] as? String { len += c.count }
            if let th = obj["thinking"] as? String { len += th.count }
            let estTokens = max(1, Int(round(Double(len) / 4.0)))
            steps.append(StepRecord(date: date, tokens: estTokens))
        }
        return steps
    }

    // MARK: Identity & Quota

    private func scanAccountAndPlan() -> (email: String?, plan: String?) {
        let mainLog = baseDir.appendingPathComponent("cli.log")
        let logDir = baseDir.appendingPathComponent("log", isDirectory: true)
        var logFiles: [URL] = []
        if FileManager.default.fileExists(atPath: mainLog.path) {
            logFiles.append(mainLog)
        }
        if let files = try? FileManager.default.contentsOfDirectory(
            at: logDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let sorted = files
                .filter { $0.lastPathComponent.hasPrefix("cli-") && $0.pathExtension == "log" }
                .sorted { ($0.resourceModificationDate ?? .distantPast) > ($1.resourceModificationDate ?? .distantPast) }
            logFiles.append(contentsOf: sorted)
        }

        var email: String?
        var plan: String?

        let emailRegex = try? NSRegularExpression(pattern: #"(?:applyAuthResult:\s*email=|authenticated successfully as\s+|email=)([a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+)"#)
        let planRegex = try? NSRegularExpression(pattern: #"(?:authMethod|tier|plan)=([a-zA-Z0-9_-]+)"#)

        for logFile in logFiles {
            guard let content = try? String(contentsOf: logFile, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                if email == nil, let emailRegex {
                    let range = NSRange(line.startIndex..., in: line)
                    if let match = emailRegex.firstMatch(in: line, range: range),
                       let r = Range(match.range(at: 1), in: line) {
                        email = String(line[r])
                    }
                }
                if plan == nil, let planRegex {
                    let range = NSRange(line.startIndex..., in: line)
                    if let match = planRegex.firstMatch(in: line, range: range),
                       let r = Range(match.range(at: 1), in: line) {
                        plan = Self.formatPlan(String(line[r]))
                    }
                }
                if email != nil && plan != nil { break }
            }
            if email != nil && plan != nil { break }
        }

        if email == nil {
            email = Self.readGoogleAccountsEmail()
        }
        if email != nil && plan == nil {
            plan = "Google AI Pro"
        }
        return (email, plan)
    }

    private static func readGoogleAccountsEmail() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".gemini/google_accounts.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let active = obj["active"] as? String, !active.isEmpty {
            return active
        }
        return nil
    }

    private func scanQuotaExhaustion() -> (exhausted: Bool, resetsAt: Date?) {
        let logDir = baseDir.appendingPathComponent("log", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return (false, nil) }

        guard let latestLog = files
            .filter({ $0.lastPathComponent.hasPrefix("cli-") && $0.pathExtension == "log" })
            .sorted(by: { ($0.resourceModificationDate ?? .distantPast) > ($1.resourceModificationDate ?? .distantPast) })
            .first,
            let mtime = latestLog.resourceModificationDate,
            Date().timeIntervalSince(mtime) <= 3600
        else { return (false, nil) }

        guard let content = try? String(contentsOf: latestLog, encoding: .utf8) else { return (false, nil) }
        var lastQuotaLine: String?
        for line in content.components(separatedBy: .newlines) {
            if line.localizedCaseInsensitiveContains("RESOURCE_EXHAUSTED") || line.localizedCaseInsensitiveContains("Individual quota reached") {
                lastQuotaLine = line
            }
        }

        if let line = lastQuotaLine,
           let regex = try? NSRegularExpression(pattern: #"Resets in (?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?"#),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            var hours = 0
            var minutes = 0
            var seconds = 0
            if let r1 = Range(match.range(at: 1), in: line), let h = Int(line[r1]) { hours = h }
            if let r2 = Range(match.range(at: 2), in: line), let m = Int(line[r2]) { minutes = m }
            if let r3 = Range(match.range(at: 3), in: line), let s = Int(line[r3]) { seconds = s }
            let remaining = TimeInterval(hours * 3600 + minutes * 60 + seconds)
            let resetDate = mtime.addingTimeInterval(remaining)
            if resetDate > Date() {
                return (true, resetDate)
            }
        }
        return (false, nil)
    }

    static func formatPlan(_ raw: String) -> String {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Google AI Pro" }
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lower {
        case "consumer", "pro":
            return "Google AI Pro"
        case "ultra", "advanced":
            return "Google AI Ultra"
        case "enterprise":
            return "Gemini Enterprise"
        case "workforce":
            return "Google Workspace"
        case "gcp", "cloud":
            return "Google Cloud"
        case "api_key":
            return "API Key"
        default:
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    // MARK: Disk cache

    private struct CachePayload: Codable {
        var fetchedAt: Date
        var info: AntigravityUsageInfo
        var email: String?
    }

    private static func loadCache() -> CachePayload? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(CachePayload.self, from: data)
    }

    private static func saveCache(_ info: AntigravityUsageInfo, fetchedAt: Date, email: String?) {
        let payload = CachePayload(fetchedAt: fetchedAt, info: info, email: email)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: Helpers

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

// MARK: - Models

/// Antigravity 5-hour and weekly subscription usage.
struct AntigravityUsageInfo: Equatable, Codable {
    var fiveHour: UsageInfo.Window
    var weekly: UsageInfo.Window
    var planName: String?
}

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    var resourceModificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
