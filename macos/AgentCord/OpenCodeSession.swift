//
//  OpenCodeSession.swift
//  AgentCord
//
//  Detects active opencode sessions. Unlike the other agents, opencode keeps
//  its state in a SQLite database (`~/.local/share/opencode/opencode.db`,
//  WAL mode) instead of JSONL transcripts. We open it read-only via the system
//  libsqlite3 and poll cheaply: a single scalar query gates all further work,
//  so an idle opencode costs one MAX() per tick.
//
//  Live status comes from the `part` table: opencode streams message parts
//  (text deltas, tool calls) into it while a turn runs, so its timestamps are
//  fresh even when `session_v2.time_updated` has not been rewritten yet.
//  Elapsed time is today's working duration (idle gaps excluded).
//

import Foundation
import Combine
import SQLite3

final class OpenCodeSession: ObservableObject {

    @Published private(set) var current: SessionInfo?
    @Published private(set) var todayMs: Int64 = 0
    @Published private(set) var isInstalled: Bool
    /// True when the opencode database exists.
    @Published private(set) var isLinked: Bool

    var activeWindowSeconds: TimeInterval = SessionDuration.idleWindowSeconds

    private let databaseURL: URL?
    private let queue = DispatchQueue(label: "com.agentcord.opencode-session", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var scanWorkItem: DispatchWorkItem?
    private var monitoring = false
    /// Newest unarchived `time_updated` from the previous pass. When the next
    /// scalar check returns the same value, nothing changed and we skip work.
    private var lastMaxUpdatedMs: Int64 = -1

    private static let pollInterval: TimeInterval = 5

    private struct SessionRow {
        let id: String
        let directory: String?
        let modelJSON: String?
        let totalTokens: Int
        let createdAtMs: Int64
        /// Max of `session_v2.time_updated` and the session's newest `part`
        /// write — the real "last active" moment.
        let activityMs: Int64
    }

    init(dataDir: URL? = nil) {
        let fm = FileManager.default
        let dir: URL
        if let dataDir {
            dir = dataDir
        } else if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            dir = URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
        } else {
            dir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/opencode", isDirectory: true)
        }
        let url = dir.appendingPathComponent("opencode.db")
        databaseURL = fm.fileExists(atPath: url.path) ? url : nil
        isLinked = databaseURL != nil
        isInstalled = Self.opencodeExecutableURL() != nil
    }

    func start() {
        guard timer == nil else { return }
        startTimer()
        queue.async { [weak self] in
            self?.monitoring = true
            self?.scan()
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        scanWorkItem?.cancel()
        scanWorkItem = nil
        queue.async { [weak self] in
            guard let self else { return }
            monitoring = false
            lastMaxUpdatedMs = -1
            publish(.init(todayMs: 0, session: nil), linked: false)
        }
    }

    // MARK: Monitoring

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: Self.pollInterval)
        source.setEventHandler { [weak self] in self?.scan() }
        source.resume()
        timer = source
    }

    private func scan() {
        guard monitoring else { return }
        let linked = databaseURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        guard linked, let url = databaseURL else {
            publish(.init(todayMs: 0, session: nil), linked: false)
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }

        // Cheap gate: one scalar read answers "did anything change?".
        // Active sessions may live in either table depending on the opencode
        // version (newer builds migrate to `session_v2`), so watch both.
        let maxUpdatedMs = Self.scalar(
            db,
            """
            SELECT COALESCE(MAX(t), 0) FROM (
                SELECT time_updated AS t FROM session WHERE time_archived IS NULL
                UNION ALL
                SELECT time_updated AS t FROM session_v2 WHERE time_archived IS NULL
                UNION ALL
                SELECT time_updated FROM part
            )
            """
        ) ?? 0
        guard maxUpdatedMs != lastMaxUpdatedMs else { return }
        lastMaxUpdatedMs = maxUpdatedMs

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let cutoffMs = SessionDuration.localMidnightMs()

        // Sessions touched today drive both the live detection and the clock.
        // Activity is the newer of the session row's own update stamp and its
        // newest streamed `part` write.
        var sessions: [SessionRow] = []
        Self.eachRow(
            db,
            """
            SELECT * FROM (
                \(Self.sessionSelect(table: "session"))
                UNION ALL
                \(Self.sessionSelect(table: "session_v2"))
            )
            WHERE activity >= ?
            ORDER BY activity DESC
            LIMIT 100
            """,
            bind: { cutoffMs },
            read: { row in
                sessions.append(SessionRow(
                    id: Self.text(row, 0),
                    directory: Self.optionalText(row, 1),
                    modelJSON: Self.optionalText(row, 2),
                    totalTokens: Int(Self.int(row, 3)),
                    createdAtMs: Self.int(row, 4),
                    activityMs: Self.int(row, 5)
                ))
            }
        )

        // Per-part stamps give the same activity points the JSONL agents get,
        // but at streaming granularity (text deltas, tool calls).
        var stampsBySession: [String: [Int64]] = [:]
        Self.eachRow(
            db,
            "SELECT session_id, time_updated FROM part WHERE time_updated >= ?",
            bind: { cutoffMs },
            read: { row in
                stampsBySession[Self.text(row, 0), default: []].append(Self.int(row, 1))
            }
        )

        var totalActive: Int64 = 0
        var newestLast: Int64?
        for row in sessions {
            let (activeMs, lastMs) = SessionDuration.activeMs(
                stamps: stampsBySession[row.id] ?? [],
                createdAtMs: row.createdAtMs,
                updatedAtMs: row.activityMs,
                cutoffMs: cutoffMs,
                nowMs: nowMs
            )
            totalActive += activeMs
            if let lastMs, newestLast == nil || lastMs > newestLast! {
                newestLast = lastMs
            }
        }

        let newest = sessions.first
        let live = newest.map { nowMs - $0.activityMs <= Int64(activeWindowSeconds * 1000) } ?? false
        let todayMs = SessionDuration.withLiveTail(
            totalActiveMs: totalActive, lastMs: newestLast, nowMs: nowMs, live: live)

        var session: SessionInfo?
        if live, let newest {
            let project = newest.directory.map(repoName(forCwd:))
                ?? newest.directory.map { ($0 as NSString).lastPathComponent }
                ?? "OpenCode"
            session = SessionInfo(
                projectName: project.isEmpty ? "OpenCode" : project,
                model: newest.modelJSON.map(Self.prettyModel),
                startEpochMs: nowMs - todayMs,
                totalTokens: newest.totalTokens,
                lastModified: Date(timeIntervalSince1970: Double(newest.activityMs) / 1000),
                agent: .opencode
            )
        }

        publish(.init(todayMs: todayMs, session: session), linked: linked)
    }

    private func publish(_ scan: AgentScan, linked: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isLinked != linked { isLinked = linked }
            if todayMs != scan.todayMs { todayMs = scan.todayMs }
            if current != scan.session { current = scan.session }
        }
    }

    // MARK: SQLite helpers

    /// One arm of the session union: metadata plus the real last-active stamp
    /// (newest streamed `part` write, falling back to the row's own update).
    private static func sessionSelect(table: String) -> String {
        """
        SELECT s.id, s.directory, s.model,
               s.tokens_input + s.tokens_output + s.tokens_reasoning,
               s.time_created,
               MAX(COALESCE((SELECT MAX(p.time_updated) FROM part p WHERE p.session_id = s.id), 0),
                   s.time_updated) AS activity
        FROM \(table) s
        WHERE s.time_archived IS NULL
        """
    }

    private static func scalar(_ db: OpaquePointer?, _ sql: String) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private static func eachRow(
        _ db: OpaquePointer?,
        _ sql: String,
        bind: () -> Int64,
        read: (OpaquePointer?) -> Void
    ) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, bind())
        while sqlite3_step(statement) == SQLITE_ROW {
            read(statement)
        }
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        optionalText(statement, index) ?? ""
    }

    private static func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func int(_ statement: OpaquePointer?, _ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    // MARK: Helpers

    private func repoName(forCwd cwd: String) -> String {
        var name = (cwd as NSString).lastPathComponent
        if let remote = runGit(["-C", cwd, "config", "--get", "remote.origin.url"]) {
            var base = (remote as NSString).lastPathComponent
            if base.hasSuffix(".git") { base = String(base.dropLast(4)) }
            if !base.isEmpty { name = base }
        } else if let top = runGit(["-C", cwd, "rev-parse", "--show-toplevel"]) {
            let base = (top as NSString).lastPathComponent
            if !base.isEmpty { name = base }
        }
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

    private static func opencodeExecutableURL() -> URL? {
        let fm = FileManager.default
        var paths: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map { "\($0)/opencode" })
        }
        let home = fm.homeDirectoryForCurrentUser.path
        paths.append(contentsOf: [
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            "\(home)/.opencode/bin/opencode",
            "\(home)/.local/bin/opencode"
        ])
        return paths.first(where: fm.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    /// `{"id":"claude-opus-4-5","providerID":"anthropic"}` → "Anthropic Claude Opus 4 5".
    static func prettyModel(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return raw }
        let id = (object["id"] as? String) ?? raw
        var words = id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        if let provider = object["providerID"] as? String, !provider.isEmpty {
            words.insert(provider.prefix(1).uppercased() + provider.dropFirst(), at: 0)
        }
        return words.joined(separator: " ")
    }
}
