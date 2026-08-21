//
//  AntigravitySession.swift
//  AgentCord
//
//  Detects the currently active Antigravity CLI session by watching
//  ~/.gemini/antigravity-cli/ (brain/, presence/, history.jsonl).
//  Transcripts live at brain/<conversation-id>/.system_generated/logs/transcript.jsonl.
//  Activity comes from transcript events, presence lock mtimes, and history stamps.
//  Elapsed time is today's working duration (idle gaps excluded).
//

import Foundation
import Combine

final class AntigravitySession: ObservableObject {

    /// The current active session, or nil when none is active.
    @Published private(set) var current: SessionInfo?
    @Published private(set) var todayMs: Int64 = 0

    /// True when the user has signed in (google_accounts.json or logs).
    @Published private(set) var isAuthenticated = false
    /// True when the Antigravity base directory exists.
    @Published private(set) var isLinked = false

    /// A session counts as active if it was touched within this window.
    var activeWindowSeconds: TimeInterval = SessionDuration.idleWindowSeconds

    private let baseDir: URL
    private let queue = DispatchQueue(label: "com.agentcord.antigravity.scan", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var scanWorkItem: DispatchWorkItem?
    private var monitoring = false
    private static let scanCoalesce: TimeInterval = 0.35

    /// Fixed-depth index: convID -> transcript URL
    private var transcriptURLsByConvID: [String: URL] = [:]
    private var hasBuiltTranscriptIndex = false

    /// Preserves the just-closed session during the configured idle grace period.
    private var lastKnownSession: (info: SessionInfo, activity: Date)?

    /// Incremental parse state per transcript file.
    private struct TranscriptCacheEntry {
        var mtime: Date?
        var cursor = JSONLCursor()
        var stampsMs: [Int64] = []
        var startedAtMs: Int64?
        var lastEventAtMs: Int64?
        var model: String?
        var cwd: String?
        var totalTokens: Int = 0
    }
    private var transcriptCache: [URL: TranscriptCacheEntry] = [:]

    /// History by conversation ID: convId -> (workspace, timestamp)
    private var historyByConvID: [String: (workspace: String, timestamp: Int64)] = [:]
    private var historyCacheMtime: Date?

    private static let modelRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:Model Selection[`'"\s]*(?:from\s+[^`'"]+\s+)?to\s+|model[:=\s]+['"]?)(Gemini[^\r\n`'"<]+|gemini-[a-z0-9.-]+)"#)
    private static let cwdRegex = try? NSRegularExpression(
        pattern: #"([A-Za-z]:\\[^-\r\n\t]+|\/[^-\r\n\t]+)\s*->"#)

    init(baseDir: URL? = nil) {
        self.baseDir = Self.resolveBaseDir(custom: baseDir)
        isLinked = FileManager.default.fileExists(atPath: self.baseDir.path)
        isAuthenticated = Self.readAuthenticated(baseDir: self.baseDir)
    }

    static func resolveBaseDir(custom: URL? = nil) -> URL {
        if let custom { return custom }
        let env = ProcessInfo.processInfo.environment
        if let home = env["ANTIGRAVITY_CLI_HOME"] ?? env["ANTIGRAVITY_HOME"] ?? env["GEMINI_CLI_HOME"] ?? env["GEMINI_HOME"],
           !home.isEmpty {
            let url = URL(fileURLWithPath: home, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let defaultGemini = userHome.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        if FileManager.default.fileExists(atPath: defaultGemini.path) { return defaultGemini }
        let altAntigravity = userHome.appendingPathComponent(".antigravity", isDirectory: true)
        if FileManager.default.fileExists(atPath: altAntigravity.path) { return altAntigravity }
        return defaultGemini
    }

    func start() {
        guard timer == nil else { return }
        startFSEvents()
        startTimer()
        queue.async { [weak self] in
            self?.monitoring = true
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
        scanWorkItem?.cancel()
        scanWorkItem = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.monitoring = false
            self.publish(authenticated: Self.readAuthenticated(baseDir: self.baseDir), scan: .init())
        }
    }

    // MARK: File system monitoring

    private func startFSEvents() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let session = Unmanaged<AntigravitySession>.fromOpaque(info).takeUnretainedValue()
            session.hasBuiltTranscriptIndex = false
            session.requestScan()
        }
        let paths = [baseDir.path] as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    private func requestScan() {
        scanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        scanWorkItem = work
        queue.asyncAfter(deadline: .now() + Self.scanCoalesce, execute: work)
    }

    // MARK: Scanning

    private func scan() {
        guard monitoring else { return }
        let auth = Self.readAuthenticated(baseDir: baseDir)
        refreshHistory()

        if !hasBuiltTranscriptIndex { rebuildTranscriptIndex() }

        let presenceLocks = readPresenceLocks()
        var best: (info: SessionInfo, activity: Date)?
        let now = Date()

        for (convID, transcriptURL) in transcriptURLsByConvID {
            updateTranscriptCache(for: transcriptURL, convID: convID)
            guard let entry = transcriptCache[transcriptURL] else { continue }

            let fileMtime = transcriptURL.resourceModificationDate ?? .distantPast
            let fileActivityMs = entry.lastEventAtMs ?? Int64(fileMtime.timeIntervalSince1970 * 1000)
            var activityMs = fileActivityMs

            if let lockDate = presenceLocks[convID] {
                let lockMs = Int64(lockDate.timeIntervalSince1970 * 1000)
                if lockMs > activityMs { activityMs = lockMs }
            }

            let activityDate = Date(timeIntervalSince1970: TimeInterval(activityMs) / 1000)
            let isLive = now.timeIntervalSince(activityDate) <= activeWindowSeconds

            guard isLive else { continue }

            let workspace = entry.cwd ?? historyByConvID[convID]?.workspace ?? ""
            let project = repoName(forCwd: workspace)
            let model = (entry.model).map(Self.prettyModel)

            let info = SessionInfo(
                projectName: project.isEmpty ? "Antigravity" : project,
                model: model,
                startEpochMs: 0,
                totalTokens: entry.totalTokens,
                lastModified: activityDate,
                agent: .antigravity
            )

            if best == nil || activityDate > best!.activity {
                best = (info, activityDate)
            }
        }

        if best == nil, let known = lastKnownSession, now.timeIntervalSince(known.activity) <= activeWindowSeconds {
            best = known
        }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let (activeMs, lastMs) = rollingActive(nowMs: nowMs)
        let isLive = best != nil
        let todayMs = SessionDuration.withLiveTail(
            totalActiveMs: activeMs, lastMs: lastMs, nowMs: nowMs, live: isLive)
        var scan = AgentScan(todayMs: todayMs, session: nil)
        if let found = best {
            var info = found.info
            info.startEpochMs = nowMs - todayMs
            lastKnownSession = (info, found.activity)
            scan.session = info
        }
        guard monitoring else { return }
        publish(authenticated: auth, scan: scan)
    }

    private func publish(authenticated: Bool, scan: AgentScan) {
        let linked = FileManager.default.fileExists(atPath: baseDir.path)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isAuthenticated != authenticated { self.isAuthenticated = authenticated }
            if self.isLinked != linked { self.isLinked = linked }
            if self.todayMs != scan.todayMs { self.todayMs = scan.todayMs }
            if self.current != scan.session { self.current = scan.session }
        }
    }

    static func readAuthenticated(baseDir: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let googleAcc = home.appendingPathComponent(".gemini/google_accounts.json")
        if let data = try? Data(contentsOf: googleAcc),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let active = obj["active"] as? String, !active.isEmpty {
            return true
        }
        let oauthCreds = home.appendingPathComponent(".gemini/oauth_creds.json")
        if FileManager.default.fileExists(atPath: oauthCreds.path) {
            return true
        }
        return false
    }

    private func rebuildTranscriptIndex() {
        let fm = FileManager.default
        let brain = baseDir.appendingPathComponent("brain", isDirectory: true)
        let convDirs = (try? fm.contentsOfDirectory(
            at: brain,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var index: [String: URL] = [:]
        for conv in convDirs where conv.isDirectory {
            let transcript = conv.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            if fm.fileExists(atPath: transcript.path) {
                index[conv.lastPathComponent] = transcript
            }
        }
        transcriptURLsByConvID = index
        hasBuiltTranscriptIndex = true
    }

    private func readPresenceLocks() -> [String: Date] {
        let fm = FileManager.default
        let presenceDir = baseDir.appendingPathComponent("presence", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(
            at: presenceDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var locks: [String: Date] = [:]
        for file in files where file.pathExtension == "lock" {
            let convID = file.deletingPathExtension().lastPathComponent
            if !convID.isEmpty, let mtime = file.resourceModificationDate {
                locks[convID] = mtime
            }
        }
        return locks
    }

    private func refreshHistory() {
        let historyURL = baseDir.appendingPathComponent("history.jsonl")
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        let mtime = historyURL.resourceModificationDate
        if historyCacheMtime == mtime { return }

        guard let handle = try? FileHandle(forReadingFrom: historyURL) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return }

        var map: [String: (workspace: String, timestamp: Int64)] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let convId = obj["conversationId"] as? String, !convId.isEmpty
            else { continue }

            let ws = (obj["workspace"] as? String) ?? ""
            let ts: Int64 = {
                if let n = obj["timestamp"] as? Int64 { return n }
                if let n = obj["timestamp"] as? Int { return Int64(n) }
                return 0
            }()
            map[convId] = (workspace: ws, timestamp: ts)
        }
        historyByConvID = map
        historyCacheMtime = mtime
    }

    private func updateTranscriptCache(for url: URL, convID: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            transcriptCache.removeValue(forKey: url)
            return
        }
        let mtime = url.resourceModificationDate
        var entry = transcriptCache[url] ?? TranscriptCacheEntry()

        if entry.cwd == nil, let hist = historyByConvID[convID], !hist.workspace.isEmpty {
            entry.cwd = hist.workspace
            if hist.timestamp > 0 {
                entry.startedAtMs = entry.startedAtMs ?? hist.timestamp
                entry.lastEventAtMs = max(entry.lastEventAtMs ?? hist.timestamp, hist.timestamp)
            }
        }

        if entry.mtime != mtime {
            let pulled = entry.cursor.pullLines(from: url)
            if pulled.didReset {
                entry.stampsMs.removeAll(keepingCapacity: true)
                entry.startedAtMs = nil
                entry.lastEventAtMs = nil
                entry.model = nil
                entry.cwd = historyByConvID[convID]?.workspace
                entry.totalTokens = 0
            }

            for line in pulled.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if let createdAt = obj["created_at"] as? String,
                   let date = parseISO(createdAt) {
                    let ms = Int64(date.timeIntervalSince1970 * 1000)
                    entry.startedAtMs = entry.startedAtMs ?? ms
                    entry.lastEventAtMs = max(entry.lastEventAtMs ?? ms, ms)
                    entry.stampsMs.append(ms)
                }

                if let content = obj["content"] as? String, !content.isEmpty {
                    if entry.model == nil, let regex = Self.modelRegex {
                        let range = NSRange(content.startIndex..., in: content)
                        if let match = regex.firstMatch(in: content, range: range),
                           let r = Range(match.range(at: 1), in: content) {
                            entry.model = String(content[r])
                        }
                    }
                    if entry.cwd == nil, let regex = Self.cwdRegex {
                        let range = NSRange(content.startIndex..., in: content)
                        if let match = regex.firstMatch(in: content, range: range),
                           let r = Range(match.range(at: 1), in: content) {
                            entry.cwd = String(content[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }

                if entry.cwd == nil, let toolCalls = obj["tool_calls"] as? [[String: Any]] {
                    for tool in toolCalls {
                        if let args = tool["args"] as? [String: Any] {
                            let dir = (args["DirectoryPath"] as? String)
                                ?? (args["SearchPath"] as? String)
                                ?? (args["Cwd"] as? String)
                            if let dir, !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                entry.cwd = dir.trimmingCharacters(in: .whitespacesAndNewlines)
                                break
                            }
                        }
                    }
                }

                if let usage = obj["usage"] as? [String: Any] {
                    var total = (usage["total_tokens"] as? Int) ?? 0
                    if total == 0 {
                        let inTokens = (usage["input_tokens"] as? Int) ?? 0
                        let outTokens = (usage["output_tokens"] as? Int) ?? 0
                        total = inTokens + outTokens
                    }
                    if total > 0 {
                        entry.totalTokens += total
                    }
                }
            }
            entry.mtime = mtime
        }
        transcriptCache[url] = entry
    }

    // MARK: Daily duration

    private func rollingActive(nowMs: Int64) -> (Int64, Int64?) {
        if !hasBuiltTranscriptIndex { rebuildTranscriptIndex() }

        let cutoffMs = SessionDuration.localMidnightMs()
        let cutoffDate = Date(timeIntervalSince1970: TimeInterval(cutoffMs) / 1000)
        var total: Int64 = 0
        var newestLast: Int64?
        var liveURLs = Set<URL>()

        for (convID, transcriptURL) in transcriptURLsByConvID {
            liveURLs.insert(transcriptURL)
            let mtime = transcriptURL.resourceModificationDate ?? .distantPast
            if mtime < cutoffDate && (transcriptCache[transcriptURL]?.lastEventAtMs ?? 0) < cutoffMs {
                continue
            }

            updateTranscriptCache(for: transcriptURL, convID: convID)
            guard let entry = transcriptCache[transcriptURL] else { continue }

            let (activeMs, lastMs) = SessionDuration.activeMs(
                stamps: entry.stampsMs,
                createdAtMs: entry.startedAtMs,
                updatedAtMs: entry.lastEventAtMs,
                cutoffMs: cutoffMs,
                nowMs: nowMs
            )
            total += activeMs
            if let lastMs, newestLast == nil || lastMs > newestLast! {
                newestLast = lastMs
            }
        }

        transcriptCache = transcriptCache.filter { liveURLs.contains($0.key) }
        return (total, newestLast)
    }

    // MARK: Project name

    private var repoNameCache: [String: String] = [:]

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

    private func runGit(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty == false) ? output : nil
    }

    // MARK: Helpers

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func parseISO(_ string: String?) -> Date? {
        guard let string else { return nil }
        return Self.isoWithFraction.date(from: string) ?? Self.isoPlain.date(from: string)
    }

    /// Turn a raw model id such as "gemini-3.7-flash" or "Gemini 3.7 Flash (High)" into "Gemini 3.7 Flash".
    static func prettyModel(_ raw: String) -> String {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Gemini" }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paren = trimmed.firstIndex(of: "(") {
            let before = String(trimmed[..<paren]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { trimmed = before }
        }
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let lower = trimmed.lowercased()
        if lower.contains("gemini") {
            if let regex = try? NSRegularExpression(pattern: #"(?i)gemini(?:[- ](\d+(?:\.\d+)?))?(?:[- ]([a-z0-9 -]+))?"#),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                var parts = ["Gemini"]
                if let r1 = Range(match.range(at: 1), in: trimmed) {
                    let version = String(trimmed[r1]).replacingOccurrences(of: "-", with: ".")
                    if !version.isEmpty { parts.append(version) }
                }
                if let r2 = Range(match.range(at: 2), in: trimmed) {
                    let variant = String(trimmed[r2])
                    let words = variant.split { $0 == "-" || $0 == "_" || $0 == " " }
                        .map { word -> String in
                            guard let first = word.first else { return "" }
                            return String(first).uppercased() + String(word.dropFirst()).lowercased()
                        }
                        .filter { !$0.isEmpty }
                    if !words.isEmpty { parts.append(contentsOf: words) }
                }
                return parts.joined(separator: " ")
            }
            return "Gemini"
        }
        return trimmed
    }
}

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    var resourceModificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
