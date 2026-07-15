//
//  CodexUsage.swift
//  AgentCord
//
//  Reads ChatGPT / Codex subscription rate limits through Codex's stable
//  `codex app-server` JSONL interface. Codex remains the sole owner of its
//  credentials and refresh-token lifecycle; AgentCord never reads or refreshes
//  OAuth tokens directly.
//

import Foundation
import Combine

final class CodexUsage: ObservableObject {

    /// Latest usage snapshot, or nil when it could not be fetched.
    @Published private(set) var current: CodexUsageInfo?

    /// True when app-server reports a ChatGPT-backed Codex account.
    @Published private(set) var isAuthenticated = false

    var pollInterval: TimeInterval = 300
    var minFetchInterval: TimeInterval = 60
    var maxStaleness: TimeInterval = 1800
    var requestTimeout: TimeInterval = 15

    private var lastSuccess: Date = .distantPast
    private var lastAttempt: Date = .distantPast

    private let queue = DispatchQueue(label: "com.agentcord.codex-usage", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Only one short-lived app-server probe may be active at a time.
    private var activeProcess: Process?
    private var activeInput: FileHandle?
    private var activeOutput: FileHandle?
    private var responseBuffer = Data()
    private var activeAuthenticated: Bool?
    private var requestGeneration = 0

    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AgentCord", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("codex-usage-cache.json")
    }()

    init() {
        if let cached = Self.loadCache(), Date().timeIntervalSince(cached.fetchedAt) <= maxStaleness {
            current = cached.info
            lastSuccess = cached.fetchedAt
        }
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
        queue.async { [weak self] in self?.cancelActiveRequest() }
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            guard Date().timeIntervalSince(self.lastAttempt) >= self.minFetchInterval else { return }
            self.fetch()
        }
    }

    // MARK: - App-server fetch

    private func fetch() {
        guard activeProcess == nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAttempt) >= minFetchInterval else { return }
        lastAttempt = now

        guard let executable = Self.codexExecutableURL() else {
            publishAuth(false)
            handleFailure()
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        // Never merge diagnostics into stdout: stdout is JSONL protocol data.
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        if environment["CODEX_HOME"]?.isEmpty != false {
            environment["CODEX_HOME"] = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true).path
        }
        process.environment = environment

        requestGeneration += 1
        let generation = requestGeneration
        activeProcess = process
        activeInput = input.fileHandleForWriting
        activeOutput = output.fileHandleForReading
        activeAuthenticated = nil
        responseBuffer.removeAll(keepingCapacity: true)

        output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self, let process else { return }
            self.queue.async {
                guard self.activeProcess === process, self.requestGeneration == generation else { return }
                self.responseBuffer.append(data)
                self.consumeResponseLines(from: process)
            }
        }

        process.terminationHandler = { [weak self, weak process] _ in
            guard let self, let process else { return }
            self.queue.async {
                guard self.activeProcess === process, self.requestGeneration == generation else { return }
                self.finishRequest(process, info: nil, authenticated: self.activeAuthenticated)
            }
        }

        do {
            try process.run()
        } catch {
            finishRequest(process, info: nil, authenticated: false)
            return
        }

        guard let messages = Self.appServerMessages() else {
            finishRequest(process, info: nil, authenticated: nil)
            return
        }
        input.fileHandleForWriting.write(messages)

        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak self, weak process] in
            guard let self, let process,
                  self.activeProcess === process,
                  self.requestGeneration == generation else { return }
            self.finishRequest(process, info: nil, authenticated: self.activeAuthenticated)
        }
    }

    /// Parses complete JSONL records while retaining a partial final record.
    private func consumeResponseLines(from process: Process) {
        let newline = Data([0x0A])
        while let range = responseBuffer.range(of: newline) {
            let line = responseBuffer.subdata(in: responseBuffer.startIndex..<range.lowerBound)
            responseBuffer.removeSubrange(responseBuffer.startIndex...range.lowerBound)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? Int else { continue }

            switch id {
            case 1:
                if let envelope = try? JSONDecoder().decode(AccountEnvelope.self, from: line) {
                    let type = envelope.result?.account?.type
                    activeAuthenticated = type == "chatgpt" || type == "personalAccessToken"
                    publishAuth(activeAuthenticated == true)
                }
            case 2:
                guard object["error"] == nil,
                      let envelope = try? JSONDecoder().decode(RateLimitsEnvelope.self, from: line),
                      let result = envelope.result,
                      let info = result.toUsageInfo() else {
                    finishRequest(process, info: nil, authenticated: activeAuthenticated)
                    return
                }
                finishRequest(process, info: info, authenticated: true)
                return
            default:
                continue
            }
        }
    }

    private func finishRequest(
        _ process: Process, info: CodexUsageInfo?, authenticated: Bool?
    ) {
        guard activeProcess === process else { return }

        activeOutput?.readabilityHandler = nil
        activeInput?.closeFile()
        activeInput = nil
        activeOutput = nil
        activeProcess = nil
        activeAuthenticated = nil
        responseBuffer.removeAll(keepingCapacity: true)
        if process.isRunning { process.terminate() }

        if let authenticated { publishAuth(authenticated) }
        if let info {
            lastSuccess = Date()
            Self.saveCache(info, fetchedAt: lastSuccess)
            publish(info)
        } else {
            handleFailure()
        }
    }

    private func cancelActiveRequest() {
        guard let process = activeProcess else { return }
        activeOutput?.readabilityHandler = nil
        activeInput?.closeFile()
        activeInput = nil
        activeOutput = nil
        activeProcess = nil
        activeAuthenticated = nil
        responseBuffer.removeAll(keepingCapacity: true)
        if process.isRunning { process.terminate() }
    }

    private static func appServerMessages() -> Data? {
        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "agentcord",
                        "title": "AgentCord",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                    ]
                ]
            ],
            ["method": "initialized", "params": [:]],
            ["method": "account/read", "id": 1, "params": ["refreshToken": false]],
            ["method": "account/rateLimits/read", "id": 2]
        ]

        var payload = Data()
        for message in messages {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
            payload.append(data)
            payload.append(0x0A)
        }
        return payload
    }

    /// GUI apps often receive a minimal PATH, so check the inherited PATH and
    /// the standard Codex install locations explicitly.
    private static func codexExecutableURL() -> URL? {
        let fm = FileManager.default
        var paths: [String] = []
        if let configured = ProcessInfo.processInfo.environment["CODEX_BINARY"], !configured.isEmpty {
            paths.append(configured)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        let home = fm.homeDirectoryForCurrentUser.path
        paths.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/bin/codex"
        ])

        for path in paths where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - State and cache

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

// MARK: - App-server wire format

private struct AccountEnvelope: Decodable {
    struct Result: Decodable {
        struct Account: Decodable { let type: String }
        let account: Account?
    }
    let result: Result?
}

private struct RateLimitsEnvelope: Decodable {
    struct Result: Decodable {
        struct Snapshot: Decodable {
            struct Window: Decodable {
                let usedPercent: Double?
                let windowDurationMins: Int?
                let resetsAt: Double?
            }

            let limitId: String?
            let limitName: String?
            let primary: Window?
            let secondary: Window?
            let planType: String?
            let rateLimitReachedType: String?
        }

        let rateLimits: Snapshot
        let rateLimitsByLimitId: [String: Snapshot]?

        func toUsageInfo() -> CodexUsageInfo? {
            guard let primary = rateLimits.primary else { return nil }
            let reached = rateLimits.rateLimitReachedType != nil
            let primaryLabel = Self.label(forMinutes: primary.windowDurationMins, fallback: "Primary limit")

            let secondary = rateLimits.secondary.map { Self.makeWindow($0, limitReached: false) }
            let secondaryLabel = rateLimits.secondary.map {
                Self.label(forMinutes: $0.windowDurationMins, fallback: "Secondary limit")
            }

            var additionalWindows: [CodexUsageInfo.NamedWindow] = []
            for (key, snapshot) in (rateLimitsByLimitId ?? [:]).sorted(by: { $0.key < $1.key }) {
                let id = snapshot.limitId ?? key
                guard id != (rateLimits.limitId ?? "codex"), id != "codex" else { continue }
                let baseLabel = Self.displayName(snapshot.limitName ?? id)
                if let window = snapshot.primary {
                    additionalWindows.append(.init(
                        id: "\(id)-primary",
                        label: baseLabel,
                        window: Self.makeWindow(window, limitReached: snapshot.rateLimitReachedType != nil)
                    ))
                }
                if let window = snapshot.secondary {
                    additionalWindows.append(.init(
                        id: "\(id)-secondary",
                        label: "\(baseLabel) · \(Self.label(forMinutes: window.windowDurationMins, fallback: "Secondary"))",
                        window: Self.makeWindow(window, limitReached: false)
                    ))
                }
            }

            return CodexUsageInfo(
                primary: Self.makeWindow(primary, limitReached: reached),
                primaryLabel: primaryLabel,
                secondary: secondary,
                secondaryLabel: secondaryLabel,
                planType: rateLimits.planType,
                additionalWindows: additionalWindows
            )
        }

        private static func makeWindow(_ window: Snapshot.Window, limitReached: Bool) -> UsageInfo.Window {
            let percent = min(100, max(0, Int((window.usedPercent ?? 0).rounded())))
            let severity: String
            if limitReached || percent >= 90 { severity = "critical" }
            else if percent >= 70 { severity = "warning" }
            else { severity = "normal" }
            let resetsAt = window.resetsAt.map { Date(timeIntervalSince1970: $0) }
            return UsageInfo.Window(percent: percent, severity: severity, resetsAt: resetsAt)
        }

        private static func label(forMinutes minutes: Int?, fallback: String) -> String {
            guard let minutes, minutes > 0 else { return fallback }
            if minutes <= 6 * 60 { return "5-hour session" }
            if minutes <= 8 * 24 * 60 { return "Weekly limit" }
            if minutes <= 40 * 24 * 60 { return "Monthly limit" }
            return fallback
        }

        private static func displayName(_ raw: String) -> String {
            raw.replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    let result: Result?
}
