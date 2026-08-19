//
//  CursorSession.swift
//  AgentCord
//
//  Detects the currently active Cursor agent session from today's hook file
//  (`$TMPDIR/AgentCord/yyyy-MM-dd-uptime.json`). Cursor is live only while a
//  turn is open (unmatched `start`). Today's clock is the sum of start/end
//  diffs.
//

import Foundation
import Combine

final class CursorSession: ObservableObject {

    @Published private(set) var current: SessionInfo?
    @Published private(set) var todayMs: Int64 = 0
    @Published private(set) var isLinked = false

    /// Unused: Cursor ignores the idle window and uses hook turns only.
    var activeWindowSeconds: TimeInterval = SessionDuration.idleWindowSeconds

    var isInstalled: Bool { isLinked }

    private let cursorHome: URL
    private let queue = DispatchQueue(label: "com.agentcord.cursor-session", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var monitoring = false
    private var repoNameCache: [String: String] = [:]

    init(cursorHome: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.cursorHome = cursorHome ?? home.appendingPathComponent(".cursor", isDirectory: true)
        isLinked = Self.homeLinked(self.cursorHome)
    }

    static func defaultUptimeFile(now: Date = Date()) -> URL {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["AGENTCORD_CURSOR_UPTIME_DIR"],
           !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("AgentCord", isDirectory: true)
        }
        let day = Self.localYMD(now)
        return dir.appendingPathComponent("\(day)-uptime.json")
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
        queue.async { [weak self] in
            self?.monitoring = true
            self?.scan()
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.monitoring = false
            self.publish(.init(), linked: Self.homeLinked(self.cursorHome))
        }
    }

    private func scan() {
        guard monitoring else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let file = Self.defaultUptimeFile()
        let scan = scanAt(path: file, nowMs: nowMs)
        guard monitoring else { return }
        publish(scan, linked: Self.homeLinked(cursorHome))
    }

    func scanAt(path: URL, nowMs: Int64) -> AgentScan {
        let day = parseDay(path: path, nowMs: nowMs)
        if !day.open {
            return AgentScan(todayMs: day.totalMs, session: nil)
        }
        let project = day.project.isEmpty ? "Cursor" : day.project
        return AgentScan(todayMs: day.totalMs, session: SessionInfo(
            projectName: project,
            model: nil,
            startEpochMs: nowMs - day.totalMs,
            totalTokens: 0,
            lastModified: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000),
            agent: .cursor
        ))
    }

    private struct Day {
        var totalMs: Int64 = 0
        var open = false
        var project = ""
    }

    private func parseDay(path: URL, nowMs: Int64) -> Day {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return Day() }
        var open: [String: [Int64]] = [:]
        var total: Int64 = 0
        var project = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = obj["e"] as? String
            else { continue }
            guard let ms = Self.int64(obj["ms"]) else { continue }
            let id = obj["id"] as? String ?? ""
            if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                project = repoName(forCwd: cwd)
            }
            if kind == "start" {
                open[id, default: []].append(ms)
            } else if kind == "end", var ends = open[id], !ends.isEmpty {
                let start = ends.removeLast()
                open[id] = ends
                if ms > start { total += ms - start }
            }
        }
        var live = false
        for starts in open.values {
            for start in starts {
                live = true
                if nowMs > start { total += nowMs - start }
            }
        }
        return Day(totalMs: max(0, total), open: live, project: project)
    }

    private static func homeLinked(_ cursorHome: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: cursorHome.appendingPathComponent("projects", isDirectory: true).path)
            || fm.fileExists(atPath: cursorHome.appendingPathComponent("chats", isDirectory: true).path)
    }

    private static func localYMD(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? Double { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        return nil
    }

    private func publish(_ scan: AgentScan, linked: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isLinked != linked { self.isLinked = linked }
            if self.todayMs != scan.todayMs { self.todayMs = scan.todayMs }
            if self.current != scan.session { self.current = scan.session }
        }
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

    /// `grok-4.5` → `Grok 4.5`, `default` → `Auto`.
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
}
