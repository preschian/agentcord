//
//  CursorSession.swift
//  AgentCord
//
//  Detects the currently active Cursor agent session by watching
//  ~/.cursor/projects/**/agent-transcripts/*.jsonl and enriching with
//  ~/.cursor/chats/**/<session-id>/meta.json (cwd, createdAtMs) plus the
//  sibling store.db (`lastUsedModel`). Elapsed time is the summed working
//  duration across transcripts that touched the last 24 hours (idle gaps
//  excluded), matching ClaudeSession's daily total idea. The on-disk schema
//  is undocumented, so all parsing is defensive.
//

import Foundation
import Combine

final class CursorSession: ObservableObject {

    /// The current active session, or nil when none is active.
    @Published private(set) var current: SessionInfo?

    /// True when Cursor's local project data directory exists.
    @Published private(set) var isInstalled: Bool

    /// A transcript counts as active if it was modified within this window.
    var activeWindowSeconds: TimeInterval = 60

    /// When summing working time, a gap longer than this between consecutive
    /// activity stamps is treated as idle (same idea as ClaudeSession).
    private static let activeGapToleranceMs: Int64 = 5 * 60 * 1000
    /// Rolling window for the combined duration shown on Discord / in the UI.
    private static let lookbackMs: Int64 = 24 * 60 * 60 * 1000

    private let cursorHome: URL
    private let projectsURL: URL
    private let chatsURL: URL
    private let queue = DispatchQueue(label: "com.agentcord.cursor-session", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var metaBySessionID: [String: URL] = [:]
    private var repoNameCache: [String: String] = [:]
    /// Last-used model per chat `store.db`, keyed by mtime so we don't spawn
    /// `sqlite3` on every idle scan.
    private var modelCache: [URL: (mtime: Date?, model: String?)] = [:]
    /// Parsed conversational timestamps per transcript, reused while mtime is
    /// unchanged so the 24h duration sum stays cheap.
    private var transcriptCache: [URL: TranscriptCacheEntry] = [:]

    init(cursorHome: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.cursorHome = cursorHome ?? home.appendingPathComponent(".cursor", isDirectory: true)
        projectsURL = self.cursorHome.appendingPathComponent("projects", isDirectory: true)
        chatsURL = self.cursorHome.appendingPathComponent("chats", isDirectory: true)
        isInstalled = FileManager.default.fileExists(atPath: projectsURL.path)
    }

    func start() {
        startFSEvents()
        startTimer()
        queue.async { [weak self] in self?.scan() }
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
            let session = Unmanaged<CursorSession>.fromOpaque(info).takeUnretainedValue()
            session.queue.async { session.scan() }
        }
        let paths = [cursorHome.path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
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

    // MARK: Scanning

    private struct SessionMeta {
        var cwd: String?
        var createdAtMs: Int64?
        var updatedAtMs: Int64?
        var model: String?
    }

    private struct TranscriptCacheEntry {
        let mtime: Date
        /// Epoch ms from `<timestamp>` tags embedded in user messages.
        let conversationalStampsMs: [Int64]
        let createdAtMs: Int64?
        let updatedAtMs: Int64?
    }

    private func scan() {
        let installed = FileManager.default.fileExists(atPath: projectsURL.path)
        guard installed else {
            publish(installed: false, session: nil)
            return
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            publish(installed: true, session: nil)
            return
        }

        var files: [(url: URL, date: Date)] = []
        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.pathComponents.contains("agent-transcripts") else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            files.append((url, date))
            if newest == nil || date > newest!.date {
                newest = (url, date)
            }
        }

        guard let newest else {
            publish(installed: true, session: nil)
            return
        }
        if Date().timeIntervalSince(newest.date) > activeWindowSeconds {
            publish(installed: true, session: nil)
            return
        }

        rebuildMetaIndex()

        // Combined working time across every Cursor transcript that touched the
        // last 24 hours — Discord's elapsed timer then shows the rolling sum,
        // not just the age of the current chat.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let cutoffMs = nowMs - Self.lookbackMs
        let cutoffDate = Date(timeIntervalSince1970: TimeInterval(cutoffMs) / 1000)
        // Skip historical transcripts before parsing — otherwise a long-lived
        // Cursor install re-reads every JSONL on each active scan.
        let recentFiles = files.filter { $0.date >= cutoffDate }
        var totalActiveMs: Int64 = 0
        var activeLastMs: Int64?

        for file in recentFiles {
            let entry = transcriptAggregate(url: file.url, mtime: file.date)
            let (activeMs, lastMs) = Self.activeDuration(
                conversationalStamps: entry.conversationalStampsMs,
                createdAtMs: entry.createdAtMs,
                updatedAtMs: entry.updatedAtMs,
                cutoffMs: cutoffMs,
                nowMs: nowMs
            )
            totalActiveMs += activeMs
            if file.url == newest.url {
                activeLastMs = lastMs
            }
        }

        let recentURLs = Set(recentFiles.map(\.url))
        transcriptCache = transcriptCache.filter { recentURLs.contains($0.key) }

        var elapsedMs = totalActiveMs
        if let last = activeLastMs {
            let tail = nowMs - last
            if tail > 0 && tail <= Self.activeGapToleranceMs {
                elapsedMs += tail
            }
        }
        let startMs = nowMs - elapsedMs

        let sessionID = newest.url.deletingPathExtension().lastPathComponent
        let meta = readMeta(sessionID: sessionID, includeModel: true)
        let activity = metaActivityDate(meta: meta, transcriptModified: newest.date)
        let projectName = resolveProjectName(cwd: meta?.cwd, transcriptURL: newest.url)

        let info = SessionInfo(
            projectName: projectName.isEmpty ? "Cursor" : projectName,
            model: meta?.model.map(Self.prettyModel),
            startEpochMs: startMs,
            totalTokens: 0,
            lastModified: activity,
            agent: .cursor
        )
        publish(installed: true, session: info)
    }

    private func publish(installed: Bool, session: SessionInfo?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isInstalled != installed { self.isInstalled = installed }
            if self.current != session { self.current = session }
        }
    }

    // MARK: 24h duration

    private func transcriptAggregate(url: URL, mtime: Date) -> TranscriptCacheEntry {
        if let cached = transcriptCache[url], cached.mtime == mtime {
            return cached
        }

        let sessionID = url.deletingPathExtension().lastPathComponent
        let meta = readMeta(sessionID: sessionID, includeModel: false)
        var stamps: [Int64] = []
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            content.enumerateLines { line, _ in
                stamps.append(contentsOf: Self.timestamps(inJSONLLine: line))
            }
        }
        stamps.sort()
        let entry = TranscriptCacheEntry(
            mtime: mtime,
            conversationalStampsMs: stamps,
            createdAtMs: meta?.createdAtMs,
            updatedAtMs: meta?.updatedAtMs
        )
        transcriptCache[url] = entry
        return entry
    }

    /// Working time inside the lookback window for one transcript.
    private static func activeDuration(
        conversationalStamps: [Int64],
        createdAtMs: Int64?,
        updatedAtMs: Int64?,
        cutoffMs: Int64,
        nowMs: Int64
    ) -> (activeMs: Int64, lastMs: Int64?) {
        let inWindowConversational = conversationalStamps.filter { $0 >= cutoffMs && $0 <= nowMs }

        // No user-turn timestamps — fall back to wall-clock overlap of the
        // chat's created/updated range with the lookback window.
        if inWindowConversational.isEmpty {
            guard let createdAtMs, let updatedAtMs else { return (0, nil) }
            let start = max(createdAtMs, cutoffMs)
            let end = min(updatedAtMs, nowMs)
            guard end > start else { return (0, nil) }
            return (end - start, end)
        }

        var points = inWindowConversational
        if let createdAtMs, createdAtMs >= cutoffMs && createdAtMs <= nowMs {
            points.append(createdAtMs)
        }
        if let updatedAtMs, updatedAtMs >= cutoffMs && updatedAtMs <= nowMs {
            points.append(updatedAtMs)
        }
        if let createdAtMs, let updatedAtMs, createdAtMs < cutoffMs, updatedAtMs >= cutoffMs {
            points.append(cutoffMs)
            points.append(min(updatedAtMs, nowMs))
        }

        let unique = Array(Set(points)).sorted()
        guard let last = unique.last else { return (0, nil) }

        var active: Int64 = 0
        for index in 1..<unique.count {
            let delta = unique[index] - unique[index - 1]
            if delta > 0 && delta <= activeGapToleranceMs {
                active += delta
            }
        }
        return (active, last)
    }

    private static let timestampRegex: NSRegularExpression = {
        // Cursor embeds a human-readable stamp in user turns, e.g.
        // <timestamp>Tuesday, Jul 28, 2026, 1:13 PM (UTC+7)</timestamp>
        try! NSRegularExpression(pattern: #"<timestamp>(.*?)</timestamp>"#, options: [.dotMatchesLineSeparators])
    }()

    private static func timestamps(inJSONLLine line: String) -> [Int64] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any]
        else { return [] }

        var texts: [String] = []
        if let content = message["content"] as? String {
            texts.append(content)
        } else if let content = message["content"] as? [[String: Any]] {
            for part in content {
                if let text = part["text"] as? String { texts.append(text) }
            }
        }

        var result: [Int64] = []
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            timestampRegex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match,
                      let capture = Range(match.range(at: 1), in: text),
                      let ms = parseEmbeddedTimestamp(String(text[capture]))
                else { return }
                result.append(ms)
            }
        }
        return result
    }

    private static func parseEmbeddedTimestamp(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let utc = trimmed.range(of: "(UTC", options: [.backwards]),
              trimmed.hasSuffix(")")
        else { return nil }

        let offsetBody = trimmed[utc.upperBound..<trimmed.index(before: trimmed.endIndex)]
        guard let offsetSeconds = parseUTCOffsetSeconds(offsetBody) else { return nil }
        let body = trimmed[..<utc.lowerBound].trimmingCharacters(in: .whitespaces)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
        for format in ["EEEE, MMM d, yyyy, h:mm a", "EEEE, MMMM d, yyyy, h:mm a"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: String(body)) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }

    /// Parses Cursor's UTC offset forms: `+7`, `-3`, `+05:30`, `+5:45`, `-3:30`.
    private static func parseUTCOffsetSeconds(_ raw: Substring) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signChar = trimmed.first, signChar == "+" || signChar == "-" else { return nil }
        let sign = signChar == "-" ? -1 : 1
        let body = trimmed.dropFirst()
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let hours = Int(parts[0]), hours >= 0, hours <= 18 else { return nil }
        let minutes: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), (0...59).contains(parsed) else { return nil }
            minutes = parsed
        } else {
            minutes = 0
        }
        return sign * (hours * 3600 + minutes * 60)
    }

    // MARK: Meta lookup

    private func readMeta(sessionID: String, includeModel: Bool) -> SessionMeta? {
        guard let url = metaBySessionID[sessionID],
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        return SessionMeta(
            cwd: obj["cwd"] as? String,
            createdAtMs: obj["createdAtMs"] as? Int64 ?? (obj["createdAtMs"] as? Int).map(Int64.init),
            updatedAtMs: obj["updatedAtMs"] as? Int64 ?? (obj["updatedAtMs"] as? Int).map(Int64.init),
            model: includeModel ? readLastUsedModel(chatDir: url.deletingLastPathComponent()) : nil
        )
    }

    /// Cursor keeps the chat's last model in `store.db` meta (hex-encoded JSON
    /// with `lastUsedModel`), not in meta.json. Read via the sqlite3 CLI the
    /// same way CursorUsage reads the auth state DB — no libsqlite link.
    private func readLastUsedModel(chatDir: URL) -> String? {
        let dbURL = chatDir.appendingPathComponent("store.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }

        let dbMtime = (try? dbURL.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate)
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let walMtime = (try? walURL.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate)
        let stamp = [dbMtime, walMtime].compactMap { $0 }.max()

        if let cached = modelCache[dbURL], cached.mtime == stamp {
            return cached.model
        }

        let model = Self.queryLastUsedModel(dbPath: dbURL.path)
        modelCache[dbURL] = (stamp, model)
        return model
    }

    private static func queryLastUsedModel(dbPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            dbPath,
            "SELECT value FROM meta WHERE key = 0 LIMIT 1;"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let hex = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !hex.isEmpty,
              let jsonData = Data(hexString: hex),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let model = obj["lastUsedModel"] as? String,
              !model.isEmpty
        else { return nil }
        return model
    }

    /// `grok-4.5` → `Grok 4.5`, `composer-2.5-fast` → `Composer 2.5 Fast`,
    /// `default` → `Auto` (Cursor's automatic model picker).
    static func prettyModel(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower == "default" { return "Auto" }

        var value = raw
        if lower.hasPrefix("cursor-") {
            value = String(raw.dropFirst("cursor-".count))
        }

        return value.split(separator: "-").map { part -> String in
            let s = String(part)
            if s.first?.isNumber == true { return s }
            if s.lowercased() == "gpt" { return "GPT" }
            return s.prefix(1).uppercased() + s.dropFirst()
        }.joined(separator: " ")
    }


    private func rebuildMetaIndex() {
        metaBySessionID.removeAll(keepingCapacity: true)
        guard let enumerator = FileManager.default.enumerator(
            at: chatsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator where url.lastPathComponent == "meta.json" {
            let sessionID = url.deletingLastPathComponent().lastPathComponent
            if !sessionID.isEmpty { metaBySessionID[sessionID] = url }
        }
    }

    private func metaActivityDate(meta: SessionMeta?, transcriptModified: Date) -> Date {
        if let updatedMs = meta?.updatedAtMs {
            return Date(timeIntervalSince1970: Double(updatedMs) / 1000)
        }
        return transcriptModified
    }

    // MARK: Project name

    private func resolveProjectName(cwd: String?, transcriptURL: URL) -> String {
        if let cwd, !cwd.isEmpty { return repoName(forCwd: cwd) }
        let encoded = transcriptURL.pathComponents.first { $0.hasPrefix("Users-") }
            ?? transcriptURL.pathComponents.reversed().first { $0 != "agent-transcripts" && $0 != transcriptURL.deletingPathExtension().lastPathComponent }
            ?? ""
        let parts = encoded.split(separator: "-").filter { !$0.isEmpty }
        return parts.last.map(String.init) ?? encoded
    }

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
}

private extension Data {
    /// Decode an even-length hex string into raw bytes. Returns nil on any
    /// malformed nibble so callers can treat bad Cursor store rows as missing.
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count.isMultiple(of: 2), !hex.isEmpty else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
