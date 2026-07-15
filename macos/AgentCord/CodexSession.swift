//
//  CodexSession.swift
//  AgentCord
//
//  Detects active Codex sessions. A running Codex app-server daemon is the
//  authoritative source for runtime thread status. Standalone CLI processes do
//  not share that runtime, so recent ~/.codex/sessions transcripts are used as
//  a defensive fallback and to enrich runtime threads with model/token data.
//

import Foundation
import Combine

final class CodexSession: ObservableObject {

    @Published private(set) var current: SessionInfo?
    @Published private(set) var isInstalled: Bool

    var activeWindowSeconds: TimeInterval = 60

    private let codexHome: URL
    private let sessionsURL: URL
    private let queue = DispatchQueue(label: "com.agentcord.codex-session", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    /// Accessed only on `queue`; prevents a late FSEvent from restarting the
    /// runtime probe after shutdown.
    private var monitoring = false

    // MARK: App-server runtime probe

    private var runtimeProcess: Process?
    private var runtimeInput: FileHandle?
    private var runtimeOutput: FileHandle?
    private var runtimeBuffer = Data()
    private var runtimeReady = false
    private var runtimeRequestID = 1
    private var lastRuntimeAttempt = Date.distantPast
    private var lastRuntimeListRequest = Date.distantPast
    private var runtimeThread: RuntimeThread?

    private struct RuntimeThread {
        let path: URL?
        let cwd: String
        let createdAt: Date
        let updatedAt: Date
    }

    // MARK: Transcript cache

    private struct TranscriptState {
        var cwd: String?
        var model: String?
        var startedAt: Date?
        var lastEventAt: Date?
        var totalTokens = 0
    }

    private struct CacheEntry {
        let mtime: Date
        let state: TranscriptState
    }

    private var transcriptCache: [URL: CacheEntry] = [:]
    private var repoNameCache: [String: String] = [:]

    init(codexHome: URL? = nil) {
        let fm = FileManager.default
        if let codexHome {
            self.codexHome = codexHome
        } else if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            self.codexHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            self.codexHome = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        sessionsURL = self.codexHome.appendingPathComponent("sessions", isDirectory: true)
        isInstalled = Self.codexExecutableURL() != nil
    }

    func start() {
        startFSEvents()
        startTimer()
        queue.async { [weak self] in
            self?.monitoring = true
            self?.startRuntimeProbeIfNeeded()
            self?.scan()
        }
    }

    func stop() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
        timer?.cancel()
        timer = nil
        queue.async { [weak self] in
            self?.monitoring = false
            self?.stopRuntimeProbe()
        }
    }

    // MARK: Monitoring

    private func startFSEvents() {
        guard FileManager.default.fileExists(atPath: codexHome.path) else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let session = Unmanaged<CodexSession>.fromOpaque(info).takeUnretainedValue()
            session.queue.async { session.scan() }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [codexHome.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 5, repeating: 5)
        source.setEventHandler { [weak self] in self?.scan() }
        source.resume()
        timer = source
    }

    private func scan() {
        guard monitoring else { return }
        startRuntimeProbeIfNeeded()
        requestRuntimeThreadsIfNeeded()
        scanTranscripts()
    }

    // MARK: App-server

    /// Connect to Codex's managed daemon when one exists. `proxy` never starts
    /// a second daemon, so AgentCord cannot accidentally take ownership of or
    /// interfere with the user's Codex lifecycle.
    private func startRuntimeProbeIfNeeded() {
        guard runtimeProcess == nil,
              Date().timeIntervalSince(lastRuntimeAttempt) >= 30,
              let executable = Self.codexExecutableURL() else { return }

        lastRuntimeAttempt = Date()

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "proxy"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment

        runtimeProcess = process
        runtimeInput = input.fileHandleForWriting
        runtimeOutput = output.fileHandleForReading
        runtimeBuffer.removeAll(keepingCapacity: true)
        runtimeReady = false

        output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self, let process else { return }
            self.queue.async {
                guard self.runtimeProcess === process else { return }
                self.runtimeBuffer.append(data)
                self.consumeRuntimeLines()
            }
        }

        process.terminationHandler = { [weak self, weak process] _ in
            guard let self, let process else { return }
            self.queue.async {
                guard self.runtimeProcess === process else { return }
                self.clearRuntimeProcess()
                self.runtimeThread = nil
                self.scanTranscripts()
            }
        }

        do {
            try process.run()
            sendRuntime([
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "agentcord",
                        "title": "AgentCord",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                    ]
                ]
            ])
            sendRuntime(["method": "initialized", "params": [:]])
        } catch {
            clearRuntimeProcess()
        }
    }

    private func requestRuntimeThreadsIfNeeded(force: Bool = false) {
        guard runtimeReady,
              force || Date().timeIntervalSince(lastRuntimeListRequest) >= 5 else { return }
        lastRuntimeListRequest = Date()
        runtimeRequestID += 1
        sendRuntime([
            "method": "thread/list",
            "id": runtimeRequestID,
            "params": ["limit": 50, "sortKey": "updated_at"]
        ])
    }

    private func sendRuntime(_ object: [String: Any]) {
        guard let process = runtimeProcess, process.isRunning,
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A)
        try? runtimeInput?.write(contentsOf: line)
    }

    private func consumeRuntimeLines() {
        let newline = Data([0x0A])
        while let range = runtimeBuffer.range(of: newline) {
            let line = runtimeBuffer.subdata(in: runtimeBuffer.startIndex..<range.lowerBound)
            runtimeBuffer.removeSubrange(runtimeBuffer.startIndex...range.lowerBound)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }

            if (object["id"] as? Int) == 0, object["error"] == nil {
                runtimeReady = true
                requestRuntimeThreadsIfNeeded(force: true)
                continue
            }

            if let method = object["method"] as? String,
               method == "turn/started" || method == "turn/completed" {
                requestRuntimeThreadsIfNeeded(force: true)
                continue
            }

            guard let result = object["result"] as? [String: Any],
                  let threads = result["data"] as? [[String: Any]] else { continue }
            updateRuntimeThread(from: threads)
        }
    }

    private func updateRuntimeThread(from threads: [[String: Any]]) {
        let active = threads.compactMap { thread -> RuntimeThread? in
            guard let status = thread["status"] as? [String: Any],
                  status["type"] as? String == "active",
                  let cwd = thread["cwd"] as? String else { return nil }
            let created = Self.date(fromEpochSeconds: thread["createdAt"]) ?? Date()
            let updated = Self.date(fromEpochSeconds: thread["updatedAt"]) ?? created
            let path = (thread["path"] as? String).map { URL(fileURLWithPath: $0) }
            return RuntimeThread(path: path, cwd: cwd, createdAt: created, updatedAt: updated)
        }.max { $0.updatedAt < $1.updatedAt }

        runtimeThread = active
        scanTranscripts()
    }

    private func stopRuntimeProbe() {
        let process = runtimeProcess
        clearRuntimeProcess()
        if process?.isRunning == true { process?.terminate() }
        runtimeThread = nil
    }

    private func clearRuntimeProcess() {
        runtimeOutput?.readabilityHandler = nil
        runtimeInput?.closeFile()
        runtimeOutput?.closeFile()
        runtimeInput = nil
        runtimeOutput = nil
        runtimeProcess = nil
        runtimeReady = false
        runtimeBuffer.removeAll(keepingCapacity: true)
    }

    // MARK: Transcript fallback and enrichment

    private func scanTranscripts() {
        let fm = FileManager.default
        var files: [(url: URL, date: Date)] = []
        if let enumerator = fm.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                files.append((url, date))
            }
        }
        files.sort { $0.date > $1.date }

        if let runtime = runtimeThread {
            let runtimeFile = runtime.path.flatMap { path in
                files.first(where: { $0.url.standardizedFileURL == path.standardizedFileURL })
            }
            publish(makeSessionInfo(
                url: runtimeFile?.url ?? runtime.path,
                mtime: runtimeFile?.date ?? runtime.updatedAt,
                runtime: runtime
            ))
            return
        }

        // Standalone Codex CLI sessions are not loaded into another app-server
        // process. Recent transcript activity is therefore the compatibility
        // fallback, matching AgentCord's existing configurable idle semantics.
        guard let newest = files.first,
              Date().timeIntervalSince(newest.date) <= activeWindowSeconds else {
            publish(nil)
            return
        }
        publish(makeSessionInfo(url: newest.url, mtime: newest.date, runtime: nil))

        // Avoid retaining cache entries forever as Codex history grows.
        let live = Set(files.prefix(100).map(\.url))
        transcriptCache = transcriptCache.filter { live.contains($0.key) }
    }

    private func makeSessionInfo(url: URL?, mtime: Date, runtime: RuntimeThread?) -> SessionInfo {
        let state = url.map { transcriptState(at: $0, mtime: mtime) } ?? TranscriptState()
        let cwd = state.cwd ?? runtime?.cwd
        let project = cwd.map(repoName(forCwd:))
            ?? url?.deletingLastPathComponent().lastPathComponent
            ?? "Codex"
        let started = state.startedAt ?? runtime?.createdAt ?? mtime
        let activity = max(state.lastEventAt ?? .distantPast, runtime?.updatedAt ?? mtime)

        return SessionInfo(
            projectName: project.isEmpty ? "Codex" : project,
            model: state.model.map(Self.prettyModel),
            startEpochMs: Int64(started.timeIntervalSince1970 * 1000),
            totalTokens: state.totalTokens,
            lastModified: activity,
            agent: .codex
        )
    }

    private func transcriptState(at url: URL, mtime: Date) -> TranscriptState {
        if let cached = transcriptCache[url], cached.mtime == mtime { return cached.state }

        var state = TranscriptState()
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return state }
        content.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            if let timestamp = object["timestamp"] as? String,
               let date = Self.date(fromISO: timestamp) {
                state.lastEventAt = max(state.lastEventAt ?? .distantPast, date)
            }
            guard let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { return }

            switch type {
            case "session_meta":
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty { state.cwd = cwd }
                if let timestamp = payload["timestamp"] as? String {
                    state.startedAt = Self.date(fromISO: timestamp)
                }
            case "turn_context":
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty { state.cwd = cwd }
                if let model = payload["model"] as? String, !model.isEmpty { state.model = model }
            case "event_msg":
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = info["total_token_usage"] as? [String: Any]
                else { return }
                if let total = Self.intValue(usage["total_tokens"]) {
                    state.totalTokens = max(state.totalTokens, total)
                } else {
                    let input = Self.intValue(usage["input_tokens"]) ?? 0
                    let output = Self.intValue(usage["output_tokens"]) ?? 0
                    state.totalTokens = max(state.totalTokens, input + output)
                }
            default:
                break
            }
        }

        transcriptCache[url] = CacheEntry(mtime: mtime, state: state)
        return state
    }

    private func publish(_ info: SessionInfo?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.current != info { self.current = info }
        }
    }

    // MARK: Helpers

    private func repoName(forCwd cwd: String) -> String {
        if let cached = repoNameCache[cwd] { return cached }

        var name = (cwd as NSString).lastPathComponent
        if let remote = runGit(["-C", cwd, "config", "--get", "remote.origin.url"]) {
            var base = (remote as NSString).lastPathComponent
            if base.hasSuffix(".git") { base = String(base.dropLast(4)) }
            if !base.isEmpty { name = base }
        } else if let top = runGit(["-C", cwd, "rev-parse", "--show-toplevel"]) {
            let base = (top as NSString).lastPathComponent
            if !base.isEmpty { name = base }
        }
        repoNameCache[cwd] = name
        return name
    }

    private func runGit(_ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

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
        return paths.first(where: fm.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func date(fromISO value: String) -> Date? {
        isoWithFraction.date(from: value) ?? isoPlain.date(from: value)
    }

    private static func date(fromEpochSeconds value: Any?) -> Date? {
        if let value = value as? Double { return Date(timeIntervalSince1970: value) }
        if let value = value as? Int { return Date(timeIntervalSince1970: Double(value)) }
        if let value = value as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    static func prettyModel(_ raw: String) -> String {
        var value = raw
            .replacingOccurrences(of: "-codex", with: " Codex", options: [.caseInsensitive])
            .replacingOccurrences(of: "-", with: ".")
        if value.lowercased().hasPrefix("gpt.") {
            value = "GPT-" + value.dropFirst(4)
        }
        return value
    }
}
