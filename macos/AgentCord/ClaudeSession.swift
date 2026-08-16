//
//  ClaudeSession.swift
//  AgentCord
//
//  Detects the currently active Claude Code session by watching
//  ~/.claude/projects/ and parsing the most recently modified .jsonl
//  transcript. Tokens are summed across transcripts touched today (local
//  calendar day). Elapsed time is the summed working duration across
//  transcripts that touched the last 24 hours (idle gaps excluded), matching
//  Grok / Codex / Cursor. The transcript schema is undocumented, so all
//  parsing is defensive: malformed or unexpected lines are skipped, never fatal.
//

import Foundation
import Combine

final class ClaudeSession: ObservableObject {

    /// The current active session, or nil when none is active.
    @Published private(set) var current: SessionInfo?

    /// A transcript counts as active if it was modified within this window.
    var activeWindowSeconds: TimeInterval = 60

    private let projectsURL: URL
    private let queue = DispatchQueue(label: "com.agentcord.session.scan", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var scanWorkItem: DispatchWorkItem?
    /// Queue-only. Start/stop flip this so an in-flight walk cannot republish
    /// after the monitor has been torn down.
    private var monitoring = false
    private var lastFullScan = Date.distantPast
    private var lastNewestDate: Date?
    private static let fullScanInterval: TimeInterval = 30
    private static let scanCoalesce: TimeInterval = 0.35

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        projectsURL = home.appendingPathComponent(".claude/projects", isDirectory: true)
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
            self?.monitoring = false
            self?.lastNewestDate = nil
            self?.publish(nil)
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
            let session = Unmanaged<ClaudeSession>.fromOpaque(info).takeUnretainedValue()
            session.requestScan()
        }
        let paths = [projectsURL.path] as CFArray
        // Directory-level, coalesced events. FileEvents+NoDefer would fire a
        // full walk on every transcript append while Claude is working.
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
        // Cheap idle expiry plus a slow safety walk. FSEvents drive updates
        // while a session is active; walking the whole tree every 5s is waste.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func requestScan() {
        scanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        scanWorkItem = work
        queue.asyncAfter(deadline: .now() + Self.scanCoalesce, execute: work)
    }

    private func tick() {
        guard monitoring else { return }
        if let newest = lastNewestDate, Date().timeIntervalSince(newest) > activeWindowSeconds {
            lastNewestDate = nil
            publish(nil)
            return
        }
        if Date().timeIntervalSince(lastFullScan) >= Self.fullScanInterval {
            scan()
        }
    }

    // MARK: Scanning (runs on `queue`)

    private func scan() {
        guard monitoring else { return }
        lastFullScan = Date()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            publish(nil)
            return
        }

        var files: [(url: URL, date: Date)] = []
        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, date))
            if newest == nil || date > newest!.date {
                newest = (url, date)
            }
        }

        guard let newest else {
            lastNewestDate = nil
            publish(nil)
            return
        }
        // A fresh mtime is only a hint to parse. Orca/Claude Code can append a
        // timestamp-less `bridge-session` heartbeat and bump mtime on a dead
        // workspace; activity must come from parseable event timestamps.
        lastNewestDate = newest.date
        if Date().timeIntervalSince(newest.date) > activeWindowSeconds {
            publish(nil)
            return
        }

        // Tokens stay on the local calendar day. Elapsed time is a rolling 24h
        // sum of working gaps, same window as Grok / Codex / Cursor.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let cutoffMs = nowMs - SessionDuration.lookbackMs
        let dayStartMs = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)

        var totalTokensToday = 0
        var totalActiveMs: Int64 = 0
        var newestLast: Int64?
        var best: (url: URL, date: Date, agg: DayAggregate, activity: Date)?
        for file in files {
            let agg = aggregate(url: file.url, mtime: file.date, dayStartMs: dayStartMs)
            totalTokensToday += agg.tokensToday
            let (activeMs, lastMs) = SessionDuration.activeMs(
                stamps: agg.stampsMs, cutoffMs: cutoffMs, nowMs: nowMs)
            totalActiveMs += activeMs
            if let lastMs, newestLast == nil || lastMs > newestLast! {
                newestLast = lastMs
            }
            let activity = agg.lastEventMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
                ?? file.date
            if best == nil || activity > best!.activity {
                best = (file.url, file.date, agg, activity)
            }
        }

        // Drop cache entries for transcripts that no longer exist.
        let liveURLs = Set(files.map { $0.url })
        aggregateCache = aggregateCache.filter { liveURLs.contains($0.key) }

        guard let best else {
            publish(nil)
            return
        }
        if Date().timeIntervalSince(best.activity) > activeWindowSeconds {
            publish(nil)
            return
        }

        guard monitoring else { return }
        publish(makeSessionInfo(
            newest: (best.url, best.activity),
            active: best.agg,
            totalTokensToday: totalTokensToday,
            startEpochMs: SessionDuration.startMs(
                totalActiveMs: totalActiveMs, lastMs: newestLast, nowMs: nowMs)
        ))
    }

    private func publish(_ info: SessionInfo?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.current != info { self.current = info }
        }
    }

    // MARK: Parsing

    /// Per-transcript figures extracted from one `.jsonl`.
    private struct DayAggregate {
        var cwd: String?
        var model: String?
        /// Newest parseable event timestamp in the transcript (any day), used
        /// for idle detection so a heartbeat that only bumps mtime stays idle.
        var lastEventMs: Int64?
        /// Event timestamps, used to sum working time inside the 24h window.
        var stampsMs: [Int64] = []
        var tokensToday = 0
    }

    private struct CacheEntry {
        var mtime: Date
        var dayStartMs: Int64
        var cursor = JSONLCursor()
        var aggregate = DayAggregate()
    }

    /// Parsing every transcript on each scan would be wasteful, so results are
    /// memoized per file. Unchanged files reuse the last aggregate; a growing
    /// file only parses newly appended JSONL lines. Keyed access is safe:
    /// scanning is serialized on `queue`.
    private var aggregateCache: [URL: CacheEntry] = [:]

    private func aggregate(url: URL, mtime: Date, dayStartMs: Int64) -> DayAggregate {
        var entry = aggregateCache[url] ?? CacheEntry(mtime: mtime, dayStartMs: dayStartMs)
        if entry.mtime == mtime, entry.dayStartMs == dayStartMs {
            return entry.aggregate
        }

        if entry.dayStartMs != dayStartMs {
            entry = CacheEntry(mtime: mtime, dayStartMs: dayStartMs)
        }

        let pulled = entry.cursor.pullLines(from: url)
        if pulled.didReset {
            entry.aggregate = DayAggregate()
        }

        for line in pulled.lines {
            consumeAggregateLine(line, into: &entry.aggregate, dayStartMs: dayStartMs)
        }

        entry.mtime = mtime
        entry.dayStartMs = dayStartMs
        aggregateCache[url] = entry
        return entry.aggregate
    }

    private func consumeAggregateLine(
        _ line: String,
        into agg: inout DayAggregate,
        dayStartMs: Int64
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        if agg.cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty {
            agg.cwd = c
        }

        var lineMs: Int64?
        if let ts = obj["timestamp"] as? String { lineMs = Self.epochMs(fromISO: ts) }
        if let ms = lineMs {
            agg.lastEventMs = max(agg.lastEventMs ?? ms, ms)
            if ms >= dayStartMs - SessionDuration.lookbackMs {
                agg.stampsMs.append(ms)
            }
        }
        let isToday = (lineMs ?? .min) >= dayStartMs

        if let message = obj["message"] as? [String: Any] {
            if let m = message["model"] as? String, !m.isEmpty, m != "<synthetic>" {
                agg.model = m
            }
            if isToday, let usage = message["usage"] as? [String: Any] {
                agg.tokensToday += (usage["input_tokens"] as? Int ?? 0)
                agg.tokensToday += (usage["output_tokens"] as? Int ?? 0)
            }
        }
    }

    private func makeSessionInfo(
        newest: (url: URL, date: Date),
        active: DayAggregate,
        totalTokensToday: Int,
        startEpochMs: Int64
    ) -> SessionInfo {
        var projectName = deriveProjectName(fromDirectory: newest.url.deletingLastPathComponent().lastPathComponent)
        if let cwd = active.cwd { projectName = repoName(forCwd: cwd) }

        return SessionInfo(
            projectName: projectName.isEmpty ? "Claude Code" : projectName,
            model: active.model.map(Self.prettyModel),
            startEpochMs: startEpochMs,
            totalTokens: totalTokensToday,
            lastModified: newest.date
        )
    }

    /// Claude Code encodes the project's cwd into the directory name by
    /// replacing path separators with hyphens. As a fallback (when no `cwd`
    /// field is present) we take the trailing segment.
    private func deriveProjectName(fromDirectory dir: String) -> String {
        let parts = dir.split(separator: "-").filter { !$0.isEmpty }
        return parts.last.map(String.init) ?? dir
    }

    private var repoNameCache: [String: String] = [:]

    /// Resolve the repository name for a working directory. Prefers the git
    /// remote (so a Conductor worktree like ".../agentcord/abuja" still reports
    /// "agentcord"), then the git toplevel, then the directory name.
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

    // MARK: Static helpers

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

    static func epochMs(fromISO string: String) -> Int64? {
        if let date = isoWithFraction.date(from: string) ?? isoPlain.date(from: string) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }

    /// Turn a raw model id such as "claude-opus-4-5-20260101" into "Opus 4.5".
    static func prettyModel(_ raw: String) -> String {
        let lower = raw.lowercased()
        let family: String
        if lower.contains("opus") { family = "Opus" }
        else if lower.contains("sonnet") { family = "Sonnet" }
        else if lower.contains("haiku") { family = "Haiku" }
        else if lower.contains("fable") { family = "Fable" }
        else { return raw }

        if let range = raw.range(of: "[0-9]+([.-][0-9]+)?", options: .regularExpression) {
            let version = raw[range].replacingOccurrences(of: "-", with: ".")
            return "\(family) \(version)"
        }
        return family
    }
}
