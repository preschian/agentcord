//
//  CursorSession.swift
//  AgentCord
//
//  Detects the currently active Cursor agent session by watching
//  ~/.cursor/projects/**/agent-transcripts/*.jsonl and enriching with
//  ~/.cursor/chats/**/<session-id>/meta.json (cwd, createdAtMs). The on-disk
//  schema is undocumented, so all parsing is defensive.
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

    private let cursorHome: URL
    private let projectsURL: URL
    private let chatsURL: URL
    private let queue = DispatchQueue(label: "com.agentcord.cursor-session", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var metaBySessionID: [String: URL] = [:]
    private var repoNameCache: [String: String] = [:]

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

        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.pathComponents.contains("agent-transcripts") else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
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

        let sessionID = newest.url.deletingPathExtension().lastPathComponent
        rebuildMetaIndex()
        let meta = readMeta(sessionID: sessionID)
        let activity = metaActivityDate(meta: meta, transcriptModified: newest.date)
        let projectName = resolveProjectName(cwd: meta?.cwd, transcriptURL: newest.url)
        let startMs = meta?.createdAtMs ?? Int64(newest.date.timeIntervalSince1970 * 1000)

        let info = SessionInfo(
            projectName: projectName.isEmpty ? "Cursor" : projectName,
            model: nil,
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

    // MARK: Meta lookup

    private func readMeta(sessionID: String) -> SessionMeta? {
        guard let url = metaBySessionID[sessionID],
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        return SessionMeta(
            cwd: obj["cwd"] as? String,
            createdAtMs: obj["createdAtMs"] as? Int64 ?? (obj["createdAtMs"] as? Int).map(Int64.init),
            updatedAtMs: obj["updatedAtMs"] as? Int64 ?? (obj["updatedAtMs"] as? Int).map(Int64.init)
        )
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
