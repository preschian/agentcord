//
//  JSONLTail.swift
//  AgentCord
//
//  Incremental reader for append-only JSONL transcripts. Session files grow
//  continuously while an agent is working; re-reading the whole file on every
//  mtime change is the expensive path. This cursor keeps the byte offset and
//  any incomplete trailing line so each refresh only parses new bytes.
//

import Foundation

struct JSONLCursor {
    var offset: Int64 = 0
    var leftover = Data()

    mutating func reset() {
        offset = 0
        leftover.removeAll(keepingCapacity: true)
    }

    /// Newly completed UTF-8 lines since the last pull. `didReset` is true when
    /// the file shrank (rotated / rewritten) and the caller must drop any
    /// aggregate built from earlier bytes.
    mutating func pullLines(from url: URL) -> (lines: [String], didReset: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ([], false)
        }
        defer { try? handle.close() }

        let size: Int64
        do {
            size = Int64(try handle.seekToEnd())
        } catch {
            return ([], false)
        }

        var didReset = false
        if size < offset {
            reset()
            didReset = true
        }

        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            return ([], didReset)
        }

        let chunk = (try? handle.readToEnd()) ?? Data()
        if chunk.isEmpty && leftover.isEmpty {
            return ([], didReset)
        }
        leftover.append(chunk)
        offset = size

        var lines: [String] = []
        let newline = Data([0x0A])
        while let range = leftover.range(of: newline) {
            let lineData = leftover.subdata(in: leftover.startIndex..<range.lowerBound)
            leftover.removeSubrange(leftover.startIndex..<range.upperBound)
            if lineData.isEmpty { continue }
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return (lines, didReset)
    }
}

/// Combined working time across sessions. Discord's elapsed timer is
/// `now - start`, so backdating `start` by today's summed active gaps makes
/// the counter match the row clock.
enum SessionDuration {
    /// A gap longer than this between consecutive stamps is idle, not work.
    static let gapToleranceMs: Int64 = 5 * 60 * 1000
    /// File-retention bound for tree walks, not the clock cutoff.
    static let lookbackMs: Int64 = 24 * 60 * 60 * 1000
    /// Presence idle timeout. Scans ignore Settings.idleWindowSeconds.
    static let idleWindowSeconds: TimeInterval = 60

    /// Local calendar-day start, used as the work-clock cutoff.
    static func localMidnightMs(now: Date = Date()) -> Int64 {
        Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000)
    }

    /// Add `now - last` only while the session is live, so idle clocks freeze.
    static func withLiveTail(totalActiveMs: Int64, lastMs: Int64?, nowMs: Int64, live: Bool) -> Int64 {
        var total = totalActiveMs
        if live, let lastMs, nowMs > lastMs {
            total += nowMs - lastMs
        }
        return max(0, total)
    }

    /// Ticking clock like GPUI / Windows: "1:02:03" / "2:03".
    static func formatClock(_ ms: Int64) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func rowTrailing(linked: Bool, live: Bool, todayMs: Int64) -> String {
        if !linked { return "Connect" }
        if live || todayMs > 0 { return formatClock(todayMs) }
        return "idle"
    }

    /// Working time inside the lookback window for one session.
    static func activeMs(
        stamps: [Int64],
        createdAtMs: Int64? = nil,
        updatedAtMs: Int64? = nil,
        cutoffMs: Int64,
        nowMs: Int64
    ) -> (activeMs: Int64, lastMs: Int64?) {
        let inWindow = stamps.filter { $0 >= cutoffMs && $0 <= nowMs }

        // No event timestamps — fall back to wall-clock overlap of the
        // session's created/updated range with the lookback window.
        if inWindow.isEmpty {
            guard let createdAtMs, let updatedAtMs else { return (0, nil) }
            let start = max(createdAtMs, cutoffMs)
            let end = min(updatedAtMs, nowMs)
            guard end > start else { return (0, nil) }
            return (end - start, end)
        }

        var points = Set(inWindow)
        if let createdAtMs, createdAtMs >= cutoffMs && createdAtMs <= nowMs {
            points.insert(createdAtMs)
        }
        if let updatedAtMs, updatedAtMs >= cutoffMs && updatedAtMs <= nowMs {
            points.insert(updatedAtMs)
        }
        if let createdAtMs, let updatedAtMs, createdAtMs < cutoffMs, updatedAtMs >= cutoffMs {
            points.insert(cutoffMs)
            points.insert(min(updatedAtMs, nowMs))
        }

        let unique = points.sorted()
        guard let last = unique.last else { return (0, nil) }

        var active: Int64 = 0
        for index in 1..<unique.count {
            let delta = unique[index] - unique[index - 1]
            if delta > 0 && delta <= gapToleranceMs {
                active += delta
            }
        }
        return (active, last)
    }
}
