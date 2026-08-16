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
/// `now - start`, so backdating `start` by the summed active gaps makes the
/// counter show 1pm–2pm + 5pm–6pm as two hours, not five.
enum SessionDuration {
    /// A gap longer than this between consecutive stamps is idle, not work.
    static let gapToleranceMs: Int64 = 5 * 60 * 1000
    /// Rolling window for the combined duration shown on Discord / in the UI.
    static let lookbackMs: Int64 = 24 * 60 * 60 * 1000

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

    /// Discord `timestamps.start` that makes elapsed time equal the summed work.
    static func startMs(totalActiveMs: Int64, lastMs: Int64?, nowMs: Int64) -> Int64 {
        var elapsed = totalActiveMs
        if let lastMs {
            let tail = nowMs - lastMs
            if tail > 0 && tail <= gapToleranceMs { elapsed += tail }
        }
        return nowMs - elapsed
    }
}
