//
//  MuseSession.swift
//  AgentCord
//
//  Detects the currently active Muse session by watching
//  ~/.local/share/muse/sessions/**//session.jsonl (or $XDG_DATA_HOME/muse)
//  and parsing the most recently modified transcript. The on-disk schema is
//  undocumented, so all parsing is defensive. Token totals are summed from
//  model_completed events in the active JSONL.
//

import Foundation
import Combine

final class MuseSession: ObservableObject {

    @Published private(set) var current: SessionInfo?
    @Published private(set) var isInstalled: Bool

    var activeWindowSeconds: TimeInterval = 60

    private let museDataHome: URL
    private let sessionsURL: URL
    private let dbURL: URL
    private let queue = DispatchQueue(label: "com.agentcord.muse-session", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var repoNameCache: [String: String] = [:]

    init(museDataHome: URL? = nil) {
        if let museDataHome {
            self.museDataHome = museDataHome
        } else if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            self.museDataHome = URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("muse", isDirectory: true)
        } else {
            self.museDataHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/muse", isDirectory: true)
        }
        sessionsURL = self.museDataHome.appendingPathComponent("sessions", isDirectory: true)
        dbURL = self.museDataHome.appendingPathComponent("session-index.db")
        let fm = FileManager.default
        isInstalled = fm.fileExists(atPath: sessionsURL.path) || fm.fileExists(atPath: dbURL.path)
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
        guard FileManager.default.fileExists(atPath: museDataHome.path) else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let session = Unmanaged<MuseSession>.fromOpaque(info).takeUnretainedValue()
            session.queue.async { session.scan() }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [museDataHome.path] as CFArray,
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

    private func scan() {
        let fm = FileManager.default
        let installed = fm.fileExists(atPath: sessionsURL.path) || fm.fileExists(atPath: dbURL.path)
        guard installed else {
            publish(installed: false, session: nil)
            return
        }
        // Also update isInstalled if it changed
        guard fm.fileExists(atPath: sessionsURL.path) else {
            // DB exists but no sessions directory yet - still installed but idle
            publish(installed: true, session: nil)
            return
        }

        guard let enumerator = fm.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            publish(installed: true, session: nil)
            return
        }

        var files: [(url: URL, date: Date)] = []
        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "session.jsonl" else { continue }
            // Skip subagent transcripts and tool outputs
            if url.pathComponents.contains("subagent") { continue }
            if url.pathComponents.contains("tool-outputs") { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
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

        let info = parseSession(url: newest.url, mtime: newest.date)
        publish(installed: true, session: info)
    }

    private func publish(installed: Bool, session: SessionInfo?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isInstalled != installed { self.isInstalled = installed }
            if self.current != session { self.current = session }
        }
    }

    // MARK: Parsing

    private func parseSession(url: URL, mtime: Date) -> SessionInfo? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var workspaceRoot: String?
        var modelID: String?
        var cwd: String?
        var firstRecordedAtUs: Int64?
        var lastRecordedAtUs: Int64?
        var inputTokens = 0
        var outputTokens = 0

        content.enumerateLines { line, _ in
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            if let recorded = obj["recorded_at"] as? Int64 {
                if firstRecordedAtUs == nil || recorded < firstRecordedAtUs! {
                    firstRecordedAtUs = recorded
                }
                if lastRecordedAtUs == nil || recorded > lastRecordedAtUs! {
                    lastRecordedAtUs = recorded
                }
            } else if let recorded = obj["recorded_at"] as? Int {
                let v = Int64(recorded)
                if firstRecordedAtUs == nil || v < firstRecordedAtUs! { firstRecordedAtUs = v }
                if lastRecordedAtUs == nil || v > lastRecordedAtUs! { lastRecordedAtUs = v }
            } else if let recorded = obj["recorded_at"] as? Double {
                let v = Int64(recorded)
                if firstRecordedAtUs == nil || v < firstRecordedAtUs! { firstRecordedAtUs = v }
                if lastRecordedAtUs == nil || v > lastRecordedAtUs! { lastRecordedAtUs = v }
            }

            guard let payloadType = obj["payload_type"] as? String else { return }
            if payloadType == "runtime.session.metadata",
               let payload = obj["payload"] as? [String: Any],
               let record = payload["record"] as? [String: Any] {
                if workspaceRoot == nil, let ws = record["workspace_root"] as? String, !ws.isEmpty {
                    workspaceRoot = ws
                }
                if modelID == nil, let m = record["model_id"] as? String, !m.isEmpty {
                    modelID = m
                }
            } else if payloadType == "runtime.session.route_facts",
                      let payload = obj["payload"] as? [String: Any],
                      let record = payload["record"] as? [String: Any] {
                if cwd == nil, let c = record["cwd"] as? String, !c.isEmpty {
                    cwd = c
                }
            } else if payloadType == "runtime.session",
                      let payload = obj["payload"] as? [String: Any],
                      payload["kind"] as? String == "run",
                      let event = payload["event"] as? [String: Any],
                      event["kind"] as? String == "model_completed",
                      let usage = event["usage"] as? [String: Any] {
                let input = (usage["input_tokens"] as? Int) ?? (usage["input_tokens"] as? Double).map(Int.init) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? (usage["output_tokens"] as? Double).map(Int.init) ?? 0
                inputTokens += input
                outputTokens += output
            }
        }

        // Include subagent sessions under this main session's subagent/ dir
        // — they hold the reminder/judge/tool work that still counts toward
        // the user's spend. Summing them brings main(19.1M) + sub(4M) ≈ 24M
        // for the active session, and main+sub across all sessions ≈ 42M
        // which matches the expected ~40M total.
        let subagentDir = url.deletingLastPathComponent().appendingPathComponent("subagent", isDirectory: true)
        if let subEnum = FileManager.default.enumerator(at: subagentDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let subURL as URL in subEnum where subURL.lastPathComponent == "session.jsonl" {
                guard let subContent = try? String(contentsOf: subURL, encoding: .utf8) else { continue }
                subContent.enumerateLines { line, _ in
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let payloadType = obj["payload_type"] as? String,
                          payloadType == "runtime.session",
                          let payload = obj["payload"] as? [String: Any],
                          payload["kind"] as? String == "run",
                          let event = payload["event"] as? [String: Any],
                          event["kind"] as? String == "model_completed",
                          let usage = event["usage"] as? [String: Any]
                    else { return }
                    let input = (usage["input_tokens"] as? Int) ?? (usage["input_tokens"] as? Double).map(Int.init) ?? 0
                    let output = (usage["output_tokens"] as? Int) ?? (usage["output_tokens"] as? Double).map(Int.init) ?? 0
                    inputTokens += input
                    outputTokens += output
                }
            }
        }

        let projectCwd = workspaceRoot ?? cwd
        let projectName: String
        if let c = projectCwd, !c.isEmpty {
            projectName = repoName(forCwd: c)
        } else {
            // Fallback to file's parent directory name
            projectName = url.deletingLastPathComponent().lastPathComponent
        }

        let startMs: Int64
        if let first = firstRecordedAtUs {
            startMs = first / 1000
        } else {
            startMs = Int64(mtime.timeIntervalSince1970 * 1000)
        }

        let lastModified: Date
        if let last = lastRecordedAtUs {
            lastModified = Date(timeIntervalSince1970: TimeInterval(last) / 1_000_000)
        } else {
            lastModified = mtime
        }

        let totalTokens = inputTokens + outputTokens
        return SessionInfo(
            projectName: projectName.isEmpty ? "Muse" : projectName,
            model: modelID.map(Self.prettyModel),
            startEpochMs: startMs,
            totalTokens: totalTokens,
            lastModified: lastModified,
            agent: .muse,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    static func prettyModel(_ raw: String) -> String {
        // "muse-spark-1.2-contributor" -> "Muse Spark 1.2"
        var value = raw
        // Strip trailing "-contributor" style suffix for display brevity if present
        if value.hasSuffix("-contributor") {
            value = String(value.dropLast("-contributor".count))
        }
        // Split by - and title-case each segment, keep numeric segments as-is
        return value.split(separator: "-").map { part -> String in
            let s = String(part)
            if s.first?.isNumber == true { return s }
            return s.prefix(1).uppercased() + s.dropFirst()
        }.joined(separator: " ")
    }

    // MARK: Project name

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
