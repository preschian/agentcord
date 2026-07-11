//
//  GrokSession.swift
//  AgentCord
//
//  Detects the currently active Grok (xAI) coding session by watching
//  ~/.grok/active_sessions.json and per-session summary/signals files under
//  ~/.grok/sessions/. Grok stores sessions grouped by URL-encoded cwd rather
//  than a single transcript, so activity comes from the live PID list plus
//  summary.json last_active_at / updated_at.
//

import Foundation
import Combine

final class GrokSession: ObservableObject {

    /// The current active session, or nil when none is active.
    @Published private(set) var current: SessionInfo?

    /// True when the user has signed into Grok (auth.json has at least one entry).
    @Published private(set) var isAuthenticated = false

    /// A session counts as active if it was touched within this window.
    var activeWindowSeconds: TimeInterval = 60

    private let grokHome: URL
    private let queue = DispatchQueue(label: "com.agentcord.grok.scan", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?

    init(grokHome: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.grokHome = grokHome ?? home.appendingPathComponent(".grok", isDirectory: true)
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
            let session = Unmanaged<GrokSession>.fromOpaque(info).takeUnretainedValue()
            session.queue.async { session.scan() }
        }
        let paths = [grokHome.path] as CFArray
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

    private struct LiveEntry {
        let sessionID: String
        let cwd: String
        let pid: Int32
        let openedAt: Date
    }

    private func scan() {
        let auth = readAuthenticated()
        let live = readActiveSessions().filter { processIsAlive($0.pid) }

        var best: (info: SessionInfo, activity: Date)?

        // A live PID in active_sessions.json means the Grok TUI is open. Prefer
        // the most recently touched open session; don't drop it solely because
        // last_active_at lagged during a long tool run.
        for entry in live {
            let summaryURL = findSummary(sessionID: entry.sessionID)
            let summary = summaryURL.flatMap { readSummary($0) }
            let activity = summary?.lastActive
                ?? summaryURL?.resourceModificationDate
                ?? entry.openedAt
            let signals = summaryURL.flatMap { readSignals($0.deletingLastPathComponent()) }
            let tokens = signals?.contextTokensUsed ?? 0
            let modelRaw = summary?.modelID ?? signals?.primaryModelID
            let project = repoName(forCwd: entry.cwd)
            let startMs = Int64(entry.openedAt.timeIntervalSince1970 * 1000)

            let info = SessionInfo(
                projectName: project.isEmpty ? "Grok" : project,
                model: modelRaw.map(Self.prettyModel),
                startEpochMs: startMs,
                totalTokens: tokens,
                lastModified: activity
            )
            if best == nil || activity > best!.activity {
                best = (info, activity)
            }
        }

        // Fall back to the most recently updated session that is still within
        // the idle window, even if active_sessions.json was cleared mid-quit.
        if best == nil {
            if let fallback = newestRecentSession(within: activeWindowSeconds) {
                best = fallback
            }
        }

        publish(authenticated: auth, session: best?.info)
    }

    private func publish(authenticated: Bool, session: SessionInfo?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isAuthenticated != authenticated { self.isAuthenticated = authenticated }
            if self.current != session { self.current = session }
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
        var cwd: String?
    }

    private struct SignalsMeta {
        var contextTokensUsed: Int?
        var contextWindowTokens: Int?
        var primaryModelID: String?
    }

    private func findSummary(sessionID: String) -> URL? {
        let sessions = grokHome.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            if url.lastPathComponent == "summary.json",
               url.deletingLastPathComponent().lastPathComponent == sessionID {
                return url
            }
        }
        return nil
    }

    private func readSummary(_ url: URL) -> SummaryMeta? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var meta = SummaryMeta()
        meta.modelID = obj["current_model_id"] as? String
        meta.lastActive = parseISO(obj["last_active_at"] as? String)
            ?? parseISO(obj["updated_at"] as? String)
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

    private func newestRecentSession(within window: TimeInterval) -> (SessionInfo, Date)? {
        let sessions = grokHome.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (SessionInfo, Date)?
        let now = Date()
        for case let url as URL in enumerator where url.lastPathComponent == "summary.json" {
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
                startEpochMs: Int64(activity.timeIntervalSince1970 * 1000),
                totalTokens: signals?.contextTokensUsed ?? 0,
                lastModified: activity
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
    var resourceModificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
