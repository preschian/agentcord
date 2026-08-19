//
//  GrokSession.swift
//  AgentCord
//
//  Detects the currently active Grok (xAI) coding session by watching
//  ~/.grok/active_sessions.json and per-session summary/signals files under
//  ~/.grok/sessions/. Grok stores sessions grouped by URL-encoded cwd rather
//  than a single transcript, so activity comes from summary.json last_active_at
//  plus event-log mtimes. A live PID is not enough: an idle TUI stays idle.
//  Elapsed time is today's working duration (idle gaps excluded). An open
//  turn (events.jsonl last type is not turn_ended) stays live even if files
//  pause mid-think.
//

import Foundation
import Combine

final class GrokSession: ObservableObject {

    /// The current active session, or nil when none is active.
    @Published private(set) var current: SessionInfo?
    @Published private(set) var todayMs: Int64 = 0

    /// True when the user has signed into Grok (auth.json has at least one entry).
    @Published private(set) var isAuthenticated = false
    /// True when auth.json or active_sessions.json exists.
    @Published private(set) var isLinked = false

    /// A session counts as active if it was touched within this window.
    var activeWindowSeconds: TimeInterval = SessionDuration.idleWindowSeconds

    private let grokHome: URL
    private let queue = DispatchQueue(label: "com.agentcord.grok.scan", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var scanWorkItem: DispatchWorkItem?
    private var monitoring = false
    private static let scanCoalesce: TimeInterval = 0.35
    /// Session summaries are stored at sessions/<encoded-cwd>/<session-id>.
    /// Build this fixed-depth index on demand instead of recursively walking an
    /// ever-growing history on every five-second poll.
    private var summaryURLsBySessionID: [String: URL] = [:]
    private var hasBuiltSummaryIndex = false
    /// Preserves the just-closed session during the configured idle grace
    /// period without rescanning every historical summary.
    private var lastKnownSession: (info: SessionInfo, activity: Date)?
    /// Incremental event-log stamps per session dir, reused while mtime is
    /// unchanged so the daily duration sum stays cheap.
    private var durationCache: [URL: DurationCacheEntry] = [:]
    private var eventTail: [URL: (mtime: Date?, length: Int64, type: String?)] = [:]

    init(grokHome: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.grokHome = grokHome ?? home.appendingPathComponent(".grok", isDirectory: true)
        isLinked = FileManager.default.fileExists(atPath: self.grokHome.appendingPathComponent("auth.json").path)
            || FileManager.default.fileExists(atPath: self.grokHome.appendingPathComponent("active_sessions.json").path)
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
            self.publish(authenticated: self.readAuthenticated(), scan: .init())
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
            let session = Unmanaged<GrokSession>.fromOpaque(info).takeUnretainedValue()
            session.requestScan()
        }
        let paths = [grokHome.path] as CFArray
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

    private struct LiveEntry {
        let sessionID: String
        let cwd: String
        let pid: Int32
        let openedAt: Date
    }

    private func scan() {
        guard monitoring else { return }
        let auth = readAuthenticated()
        let live = readActiveSessions().filter { processIsAlive($0.pid) }

        var best: (info: SessionInfo, activity: Date)?
        let now = Date()

        // A live PID only means the TUI is open. Require recent last_active_at
        // or event-log writes so an idle prompt is not treated as working, while
        // a long tool run that keeps appending events stays active.
        for entry in live {
            let summaryURL = findSummary(sessionID: entry.sessionID)
            let summary = summaryURL.flatMap { readSummary($0) }
            let activity = activityDate(summary: summary, summaryURL: summaryURL, fallback: entry.openedAt)
            let liveNow = now.timeIntervalSince(activity) <= activeWindowSeconds
                || isOpenTurn(summaryURL?.deletingLastPathComponent())
            guard liveNow else { continue }
            let signals = summaryURL.flatMap { readSignals($0.deletingLastPathComponent()) }
            let tokens = signals?.contextTokensUsed ?? 0
            let modelRaw = summary?.modelID ?? signals?.primaryModelID
            let project = repoName(forCwd: entry.cwd)
            let info = SessionInfo(
                projectName: project.isEmpty ? "Grok" : project,
                model: modelRaw.map(Self.prettyModel),
                startEpochMs: 0,
                totalTokens: tokens,
                lastModified: liveNow && now.timeIntervalSince(activity) > activeWindowSeconds
                    ? now : activity,
                contextWindowTokens: signals?.contextWindowTokens,
                agent: .grok
            )
            if best == nil || info.lastModified > best!.activity {
                best = (info, info.lastModified)
            }
        }

        // Fall back to the session we just observed when active_sessions.json
        // is cleared mid-quit. On first launch, discover the newest recent
        // summary once; subsequent timer ticks reuse the in-memory snapshot.
        if best == nil {
            if let known = lastKnownSession,
               now.timeIntervalSince(known.activity) <= activeWindowSeconds {
                best = known
            } else if !hasBuiltSummaryIndex,
                      let fallback = newestRecentSession(within: activeWindowSeconds) {
                best = fallback
            }
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
        let linked = FileManager.default.fileExists(atPath: grokHome.appendingPathComponent("auth.json").path)
            || FileManager.default.fileExists(atPath: grokHome.appendingPathComponent("active_sessions.json").path)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isAuthenticated != authenticated { self.isAuthenticated = authenticated }
            if self.isLinked != linked { self.isLinked = linked }
            if self.todayMs != scan.todayMs { self.todayMs = scan.todayMs }
            if self.current != scan.session { self.current = scan.session }
        }
    }

    // MARK: Auth / active sessions

    private func readAuthenticated() -> Bool {
        let url = grokHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        // Any non-empty map of account → credentials counts as signed in.
        return !obj.isEmpty
    }

    private func readActiveSessions() -> [LiveEntry] {
        let url = grokHome.appendingPathComponent("active_sessions.json")
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return arr.compactMap { item in
            guard let sid = item["session_id"] as? String, !sid.isEmpty,
                  let cwd = item["cwd"] as? String, !cwd.isEmpty
            else { return nil }
            let pid: Int32
            if let n = item["pid"] as? Int { pid = Int32(n) }
            else if let n = item["pid"] as? Int64 { pid = Int32(n) }
            else { return nil }
            let opened = parseISO(item["opened_at"] as? String) ?? Date()
            return LiveEntry(sessionID: sid, cwd: cwd, pid: pid, openedAt: opened)
        }
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    // MARK: Session files

    private struct SummaryMeta {
        var modelID: String?
        var lastActive: Date?
        var createdAt: Date?
        var cwd: String?
    }

    private struct DurationCacheEntry {
        var eventsMtime: Date?
        var summaryMtime: Date?
        var cursor = JSONLCursor()
        var stampsMs: [Int64] = []
        var createdAtMs: Int64?
        var lastActiveMs: Int64?
    }

    private struct SignalsMeta {
        var contextTokensUsed: Int?
        var contextWindowTokens: Int?
        var primaryModelID: String?
    }

    private func findSummary(sessionID: String) -> URL? {
        if let cached = summaryURLsBySessionID[sessionID],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        rebuildSummaryIndex()
        return summaryURLsBySessionID[sessionID]
    }

    private func rebuildSummaryIndex() {
        let fm = FileManager.default
        let sessions = grokHome.appendingPathComponent("sessions", isDirectory: true)
        let groupDirectories = (try? fm.contentsOfDirectory(
            at: sessions,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var index: [String: URL] = [:]
        for group in groupDirectories where group.isDirectory {
            let sessionDirectories = (try? fm.contentsOfDirectory(
                at: group,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for session in sessionDirectories where session.isDirectory {
                let summary = session.appendingPathComponent("summary.json")
                if fm.fileExists(atPath: summary.path) {
                    index[session.lastPathComponent] = summary
                }
            }
        }
        summaryURLsBySessionID = index
        hasBuiltSummaryIndex = true
    }

    private func readSummary(_ url: URL) -> SummaryMeta? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var meta = SummaryMeta()
        meta.modelID = obj["current_model_id"] as? String
        meta.lastActive = parseISO(obj["last_active_at"] as? String)
            ?? parseISO(obj["updated_at"] as? String)
        meta.createdAt = parseISO(obj["created_at"] as? String)
        if let info = obj["info"] as? [String: Any] {
            meta.cwd = info["cwd"] as? String
        }
        return meta
    }

    private func readSignals(_ sessionDir: URL) -> SignalsMeta? {
        let url = sessionDir.appendingPathComponent("signals.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var meta = SignalsMeta()
        if let n = obj["contextTokensUsed"] as? Int { meta.contextTokensUsed = n }
        else if let n = obj["contextTokensUsed"] as? Double { meta.contextTokensUsed = Int(n) }
        if let n = obj["contextWindowTokens"] as? Int { meta.contextWindowTokens = n }
        else if let n = obj["contextWindowTokens"] as? Double { meta.contextWindowTokens = Int(n) }
        meta.primaryModelID = obj["primaryModelId"] as? String
        return meta
    }

    private static let activityFiles = ["events.jsonl", "updates.jsonl", "chat_history.jsonl"]

    private func activityDate(summary: SummaryMeta?, summaryURL: URL?, fallback: Date?) -> Date {
        if let last = summary?.lastActive, Date().timeIntervalSince(last) <= activeWindowSeconds {
            return last
        }
        var best: Date?
        func consider(_ date: Date?) {
            guard let date else { return }
            if best == nil || date > best! { best = date }
        }
        consider(summary?.lastActive)
        consider(summaryURL?.resourceModificationDate)
        if let dir = summaryURL?.deletingLastPathComponent() {
            for name in Self.activityFiles {
                consider(dir.appendingPathComponent(name).resourceModificationDate)
            }
        }
        if let best, Date().timeIntervalSince(best) <= activeWindowSeconds {
            return best
        }
        // Mid-turn thinking can pause file writes. A live events.jsonl whose
        // last event is not turn_ended still counts as work.
        if isOpenTurn(summaryURL?.deletingLastPathComponent()) {
            return Date()
        }
        return best ?? fallback ?? .distantPast
    }

    private func isOpenTurn(_ sessionDir: URL?) -> Bool {
        guard let sessionDir else { return false }
        let type = lastEventType(sessionDir.appendingPathComponent("events.jsonl"))
        guard let type, !type.isEmpty else { return false }
        let lower = type.lowercased()
        return lower != "turn_ended" && lower != "session_end" && lower != "session_ended"
    }

    private func lastEventType(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let mtime = url.resourceModificationDate
        let length = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        if let cached = eventTail[url], cached.mtime == mtime, cached.length == length {
            return cached.type
        }
        let type = Self.tailEventType(url: url, length: length)
        eventTail[url] = (mtime, length, type)
        return type
    }

    /// Last complete JSONL event `type`, reading only the tail.
    private static func tailEventType(url: URL, length: Int64) -> String? {
        guard length > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let take = min(length, 8192)
        do {
            try handle.seek(toOffset: UInt64(length - take))
        } catch {
            return nil
        }
        let data = (try? handle.readToEnd()) ?? Data()
        guard !data.isEmpty, var text = String(data: data, encoding: .utf8) else { return nil }
        if length > take, let cut = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: cut)...])
        }
        let last = text.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard let last,
              let data = String(last).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }
        return type
    }

    private func newestRecentSession(within window: TimeInterval) -> (SessionInfo, Date)? {
        if !hasBuiltSummaryIndex { rebuildSummaryIndex() }

        var best: (SessionInfo, Date)?
        let now = Date()
        for url in summaryURLsBySessionID.values {
            let summary = readSummary(url)
            let activity = summary?.lastActive
                ?? url.resourceModificationDate
                ?? .distantPast
            if now.timeIntervalSince(activity) > window { continue }

            let dir = url.deletingLastPathComponent()
            let signals = readSignals(dir)
            let cwd = summary?.cwd ?? decodeCwd(fromEncoded: dir.deletingLastPathComponent().lastPathComponent)
            let project = repoName(forCwd: cwd)
            let info = SessionInfo(
                projectName: project.isEmpty ? "Grok" : project,
                model: (summary?.modelID ?? signals?.primaryModelID).map(Self.prettyModel),
                startEpochMs: 0,
                totalTokens: signals?.contextTokensUsed ?? 0,
                lastModified: activity,
                contextWindowTokens: signals?.contextWindowTokens,
                agent: .grok
            )
            if best == nil || activity > best!.1 {
                best = (info, activity)
            }
        }
        return best
    }

    /// Session group folders are URL-encoded cwds, e.g. `%2FUsers%2F…`.
    private func decodeCwd(fromEncoded encoded: String) -> String {
        encoded.removingPercentEncoding ?? encoded
    }

    // MARK: Daily duration

    /// Combined working time across every Grok session that touched today.
    /// Summaries are stat'd first so historical dirs are skipped without
    /// opening their event logs.
    private func rollingActive(nowMs: Int64) -> (Int64, Int64?) {
        if !hasBuiltSummaryIndex { rebuildSummaryIndex() }

        let cutoffMs = SessionDuration.localMidnightMs()
        let cutoffDate = Date(timeIntervalSince1970: TimeInterval(cutoffMs) / 1000)
        var total: Int64 = 0
        var newestLast: Int64?
        var liveDirs = Set<URL>()

        for summaryURL in summaryURLsBySessionID.values {
            let dir = summaryURL.deletingLastPathComponent()
            liveDirs.insert(dir)

            let eventsURL = dir.appendingPathComponent("events.jsonl")
            let eventsMtime = eventsURL.resourceModificationDate
            let summaryMtime = summaryURL.resourceModificationDate
            var entry = durationCache[dir] ?? DurationCacheEntry()

            if entry.summaryMtime != summaryMtime {
                let summary = readSummary(summaryURL)
                entry.createdAtMs = summary?.createdAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                entry.lastActiveMs = summary?.lastActive.map { Int64($0.timeIntervalSince1970 * 1000) }
                entry.summaryMtime = summaryMtime
            }

            let hint = [eventsMtime, summaryMtime]
                .compactMap { $0 }
                .max()
                ?? (entry.lastActiveMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } ?? .distantPast)
            if hint < cutoffDate {
                durationCache[dir] = entry
                continue
            }

            if FileManager.default.fileExists(atPath: eventsURL.path),
               entry.eventsMtime != eventsMtime {
                let pulled = entry.cursor.pullLines(from: eventsURL)
                if pulled.didReset { entry.stampsMs.removeAll(keepingCapacity: true) }
                for line in pulled.lines {
                    if let ms = Self.eventTimestamp(inJSONLLine: line) {
                        entry.stampsMs.append(ms)
                    }
                }
                entry.eventsMtime = eventsMtime
            }
            durationCache[dir] = entry

            let (activeMs, lastMs) = SessionDuration.activeMs(
                stamps: entry.stampsMs,
                createdAtMs: entry.createdAtMs,
                updatedAtMs: entry.lastActiveMs,
                cutoffMs: cutoffMs,
                nowMs: nowMs
            )
            total += activeMs
            if let lastMs, newestLast == nil || lastMs > newestLast! {
                newestLast = lastMs
            }
        }

        durationCache = durationCache.filter { liveDirs.contains($0.key) }
        return (total, newestLast)
    }

    private static func eventTimestamp(inJSONLLine line: String) -> Int64? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let ts = (obj["timestamp"] as? String) ?? (obj["ts"] as? String)
        guard let ts else { return nil }
        let parsed = isoWithFraction.date(from: ts) ?? isoPlain.date(from: ts)
        return parsed.map { Int64($0.timeIntervalSince1970 * 1000) }
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

    /// Turn a raw model id such as "grok-4.5" into "Grok 4.5".
    static func prettyModel(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("grok-") {
            let rest = String(raw.dropFirst(5))
            return rest.isEmpty ? "Grok" : "Grok \(rest)"
        }
        if lower.contains("grok") { return raw.replacingOccurrences(of: "-", with: " ").capitalized }
        return raw
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
