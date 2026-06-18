//
//  ClaudeSession.swift
//  ClaudeCodeRPC
//
//  Detects the currently active Claude Code session by watching
//  ~/.claude/projects/ and parsing the most recently modified .jsonl
//  transcript. The transcript schema is undocumented, so all parsing is
//  defensive: malformed or unexpected lines are skipped, never fatal.
//

import Foundation
import Combine

final class ClaudeSession: ObservableObject {

    /// The current active session, or nil when none is active.
    @Published private(set) var current: SessionInfo?

    /// A transcript counts as active if it was modified within this window.
    var activeWindowSeconds: TimeInterval = 60

    private let projectsURL: URL
    private let queue = DispatchQueue(label: "com.claudecoderpc.session.scan", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        projectsURL = home.appendingPathComponent(".claude/projects", isDirectory: true)
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
            let session = Unmanaged<ClaudeSession>.fromOpaque(info).takeUnretainedValue()
            session.queue.async { session.scan() }
        }
        let paths = [projectsURL.path] as CFArray
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
        // A periodic re-scan also catches the active -> idle transition, which
        // produces no file system event of its own.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    // MARK: Scanning (runs on `queue`)

    private func scan() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            publish(nil)
            return
        }

        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if newest == nil || date > newest!.date {
                newest = (url, date)
            }
        }

        guard let newest else {
            publish(nil)
            return
        }
        if Date().timeIntervalSince(newest.date) > activeWindowSeconds {
            publish(nil)
            return
        }
        publish(parse(url: newest.url, modified: newest.date))
    }

    private func publish(_ info: SessionInfo?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.current != info { self.current = info }
        }
    }

    // MARK: Parsing

    private func parse(url: URL, modified: Date) -> SessionInfo {
        var projectName = deriveProjectName(fromDirectory: url.deletingLastPathComponent().lastPathComponent)
        var cwd: String?
        var model: String?
        var earliestMs: Int64?
        var totalTokens = 0

        if let content = try? String(contentsOf: url, encoding: .utf8) {
            content.enumerateLines { line, _ in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
                guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

                if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty {
                    cwd = c
                }
                if let ts = obj["timestamp"] as? String, let ms = Self.epochMs(fromISO: ts) {
                    if earliestMs == nil || ms < earliestMs! { earliestMs = ms }
                }
                if let message = obj["message"] as? [String: Any] {
                    if let m = message["model"] as? String, !m.isEmpty, m != "<synthetic>" {
                        model = m
                    }
                    if let usage = message["usage"] as? [String: Any] {
                        totalTokens += (usage["input_tokens"] as? Int ?? 0)
                        totalTokens += (usage["output_tokens"] as? Int ?? 0)
                    }
                }
            }
        }

        if let cwd { projectName = repoName(forCwd: cwd) }
        let startMs = earliestMs ?? Int64(modified.timeIntervalSince1970 * 1000)

        return SessionInfo(
            projectName: projectName.isEmpty ? "Claude Code" : projectName,
            model: model.map(Self.prettyModel),
            startEpochMs: startMs,
            totalTokens: totalTokens,
            lastModified: modified
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
